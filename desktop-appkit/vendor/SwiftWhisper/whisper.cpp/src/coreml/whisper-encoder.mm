#if !__has_feature(objc_arc)
#error This file must be compiled with automatic reference counting enabled (-fobjc-arc)
#endif

#import "whisper-encoder.h"
#import "whisper-encoder-impl.h"

#import <CoreML/CoreML.h>

#include <stdlib.h>

#if __cplusplus
extern "C" {
#endif

struct whisper_coreml_context {
    const void * model;
    const void * input_name;
    const void * output_name;
    int input_rank;
    int input_data_type;
    int output_data_type;
};

static uint16_t whisper_coreml_float_to_fp16(float value) {
    __fp16 half = (__fp16) value;
    uint16_t bits = 0;
    memcpy(&bits, &half, sizeof(bits));
    return bits;
}

static float whisper_coreml_fp16_to_float(uint16_t bits) {
    __fp16 half = 0;
    memcpy(&half, &bits, sizeof(bits));
    return (float) half;
}

static MLComputeUnits whisper_coreml_compute_units(void) {
    const char * raw = getenv("SCRIBBY_COREML_COMPUTE_UNITS");
    if (raw == NULL) {
        return MLComputeUnitsCPUAndGPU;
    }

    NSString * value = [[[NSString alloc] initWithUTF8String:raw] lowercaseString];
    if ([value isEqualToString:@"all"]) {
        return MLComputeUnitsAll;
    }
    if ([value isEqualToString:@"cpu_only"] || [value isEqualToString:@"cpuonly"]) {
        return MLComputeUnitsCPUOnly;
    }
    if ([value isEqualToString:@"cpu_and_ne"]
        || [value isEqualToString:@"cpu_and_neural_engine"]
        || [value isEqualToString:@"ne"]) {
        return MLComputeUnitsCPUAndNeuralEngine;
    }

    return MLComputeUnitsCPUAndGPU;
}

static const char * whisper_coreml_compute_units_name(MLComputeUnits units) {
    switch (units) {
        case MLComputeUnitsCPUOnly:
            return "CPU_ONLY";
        case MLComputeUnitsCPUAndGPU:
            return "CPU_AND_GPU";
        case MLComputeUnitsCPUAndNeuralEngine:
            return "CPU_AND_NE";
        case MLComputeUnitsAll:
            return "ALL";
    }

    return "UNKNOWN";
}

static NSURL * whisper_coreml_resolve_model_url(NSURL * requestedURL, NSError ** error) {
    NSFileManager * fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:requestedURL.path]) {
        return requestedURL;
    }

    NSString * modelPath = requestedURL.path;
    if (![modelPath hasSuffix:@".mlmodelc"]) {
        return requestedURL;
    }

    NSString * packagePath = [[modelPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mlpackage"];
    if (![fileManager fileExistsAtPath:packagePath]) {
        return requestedURL;
    }

    NSURL * packageURL = [NSURL fileURLWithPath:packagePath];
    NSURL * compiledURL = [MLModel compileModelAtURL:packageURL error:error];
    if (compiledURL == nil) {
        return nil;
    }

    if ([fileManager fileExistsAtPath:requestedURL.path]) {
        return requestedURL;
    }

    [fileManager createDirectoryAtURL:[requestedURL URLByDeletingLastPathComponent]
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];

    if ([fileManager copyItemAtURL:compiledURL toURL:requestedURL error:nil]) {
        return requestedURL;
    }

    return compiledURL;
}

struct whisper_coreml_context * whisper_coreml_init(const char * path_model) {
    NSString * path_model_str = [[NSString alloc] initWithUTF8String:path_model];

    NSURL * requestedURL = [NSURL fileURLWithPath:path_model_str];
    NSError * modelError = nil;
    NSURL * url_model = whisper_coreml_resolve_model_url(requestedURL, &modelError);
    if (url_model == nil) {
        return NULL;
    }

    // select which device to run the Core ML model on
    MLModelConfiguration *config = [[MLModelConfiguration alloc] init];
    config.computeUnits = whisper_coreml_compute_units();
    fprintf(stderr, "whisper_coreml_init: compute units = %s\n",
            whisper_coreml_compute_units_name(config.computeUnits));

    NSError * loadError = nil;
    whisper_encoder_impl * wrapper = [[whisper_encoder_impl alloc] initWithContentsOfURL:url_model configuration:config error:&loadError];
    MLModel * model = wrapper.model;

    if (model == nil) {
        return NULL;
    }

    NSDictionary<NSString *, MLFeatureDescription *> * inputs = model.modelDescription.inputDescriptionsByName;
    NSDictionary<NSString *, MLFeatureDescription *> * outputs = model.modelDescription.outputDescriptionsByName;

    NSString * inputName = nil;
    NSString * outputName = nil;
    NSInteger inputRank = 0;
    MLMultiArrayDataType inputDataType = MLMultiArrayDataTypeFloat32;
    MLMultiArrayDataType outputDataType = MLMultiArrayDataTypeFloat32;

    if (inputs[@"logmel_data"] != nil) {
        inputName = @"logmel_data";
    } else if (inputs[@"melspectrogram_features"] != nil) {
        inputName = @"melspectrogram_features";
    } else {
        inputName = inputs.allKeys.firstObject;
    }

    if (outputs[@"output"] != nil) {
        outputName = @"output";
    } else if (outputs[@"encoder_output_embeds"] != nil) {
        outputName = @"encoder_output_embeds";
    } else {
        outputName = outputs.allKeys.firstObject;
    }

    if (inputName == nil || outputName == nil) {
        return NULL;
    }

    MLFeatureDescription * inputDescription = inputs[inputName];
    if (inputDescription.multiArrayConstraint.shape != nil) {
        inputRank = inputDescription.multiArrayConstraint.shape.count;
    }
    inputDataType = inputDescription.multiArrayConstraint.dataType;

    MLFeatureDescription * outputDescription = outputs[outputName];
    outputDataType = outputDescription.multiArrayConstraint.dataType;

    fprintf(stderr,
            "whisper_coreml_init: resolved input=%s output=%s rank=%ld inputType=%ld outputType=%ld\n",
            inputName.UTF8String,
            outputName.UTF8String,
            (long)inputRank,
            (long)inputDataType,
            (long)outputDataType);

    whisper_coreml_context * ctx = new whisper_coreml_context;
    ctx->model = CFBridgingRetain(model);
    ctx->input_name = CFBridgingRetain(inputName);
    ctx->output_name = CFBridgingRetain(outputName);
    ctx->input_rank = (int) inputRank;
    ctx->input_data_type = (int) inputDataType;
    ctx->output_data_type = (int) outputDataType;

    return ctx;
}

void whisper_coreml_free(struct whisper_coreml_context * ctx) {
    CFRelease(ctx->model);
    CFRelease(ctx->input_name);
    CFRelease(ctx->output_name);
    delete ctx;
}

void whisper_coreml_encode(
        const whisper_coreml_context * ctx,
                             int64_t   n_ctx,
                             int64_t   n_mel,
                               float * mel,
                               float * out) {
    @autoreleasepool {
        NSString * inputName = (__bridge NSString *) ctx->input_name;
        NSString * outputName = (__bridge NSString *) ctx->output_name;
        MLModel * model = (__bridge MLModel *) ctx->model;

        NSArray<NSNumber *> * shape;
        NSArray<NSNumber *> * strides;
        if (ctx->input_rank == 4) {
            shape = @[@1, @(n_mel), @1, @(n_ctx)];
            strides = @[@(n_mel * n_ctx), @(n_ctx), @(n_ctx), @1];
        } else {
            shape = @[@1, @(n_mel), @(n_ctx)];
            strides = @[@(n_mel * n_ctx), @(n_ctx), @1];
        }

        NSError * inputError = nil;
        MLMultiArray * inMultiArray = nil;
        NSMutableData * fp16InputData = nil;
        if (ctx->input_data_type == MLMultiArrayDataTypeFloat16) {
            const size_t elementCount = (size_t) (n_mel * n_ctx);
            fp16InputData = [NSMutableData dataWithLength:elementCount * sizeof(uint16_t)];
            uint16_t * fp16Input = (uint16_t *) fp16InputData.mutableBytes;
            for (size_t i = 0; i < elementCount; ++i) {
                fp16Input[i] = whisper_coreml_float_to_fp16(mel[i]);
            }
            inMultiArray = [[MLMultiArray alloc] initWithDataPointer:fp16Input
                                                               shape:shape
                                                            dataType:MLMultiArrayDataTypeFloat16
                                                             strides:strides
                                                         deallocator:nil
                                                               error:&inputError];
        } else {
            inMultiArray = [[MLMultiArray alloc] initWithDataPointer:mel
                                                               shape:shape
                                                            dataType:MLMultiArrayDataTypeFloat32
                                                             strides:strides
                                                         deallocator:nil
                                                               error:&inputError];
        }
        if (inMultiArray == nil) {
            fprintf(stderr, "whisper_coreml_encode: failed to create MLMultiArray: %s\n", inputError.localizedDescription.UTF8String);
            memset(out, 0, sizeof(float) * (size_t) (n_ctx * n_mel));
            return;
        }

        MLFeatureValue * inputValue = [MLFeatureValue featureValueWithMultiArray:inMultiArray];
        NSDictionary<NSString *, MLFeatureValue *> * features = @{ inputName: inputValue };
        NSError * providerError = nil;
        MLDictionaryFeatureProvider * provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:features error:&providerError];
        if (provider == nil) {
            fprintf(stderr, "whisper_coreml_encode: failed to create feature provider: %s\n", providerError.localizedDescription.UTF8String);
            memset(out, 0, sizeof(float) * (size_t) (n_ctx * n_mel));
            return;
        }

        NSError * predictionError = nil;
        id<MLFeatureProvider> outFeatures = [model predictionFromFeatures:provider error:&predictionError];
        if (outFeatures == nil) {
            fprintf(stderr, "whisper_coreml_encode: prediction failed: %s\n", predictionError.localizedDescription.UTF8String);
            memset(out, 0, sizeof(float) * (size_t) (n_ctx * n_mel));
            return;
        }

        MLMultiArray * outputArray = (MLMultiArray *) [outFeatures featureValueForName:outputName].multiArrayValue;
        if (outputArray == nil) {
            fprintf(stderr, "whisper_coreml_encode: missing output feature '%s'\n", outputName.UTF8String);
            memset(out, 0, sizeof(float) * (size_t) (n_ctx * n_mel));
            return;
        }

        NSArray<NSNumber *> * outputShape = outputArray.shape;
        NSArray<NSNumber *> * outputStrides = outputArray.strides;
        if (outputShape.count == 4) {
            const int64_t batch = outputShape[0].longLongValue;
            const int64_t channels = outputShape[1].longLongValue;
            const int64_t height = outputShape[2].longLongValue;
            const int64_t width = outputShape[3].longLongValue;
            const int64_t strideBatch = outputStrides[0].longLongValue;
            const int64_t strideChannel = outputStrides[1].longLongValue;
            const int64_t strideHeight = outputStrides[2].longLongValue;
            const int64_t strideWidth = outputStrides[3].longLongValue;

            if (batch == 1 && height == 1) {
                if (ctx->output_data_type == MLMultiArrayDataTypeFloat16) {
                    const uint16_t * src = (const uint16_t *) outputArray.dataPointer;
                    for (int64_t t = 0; t < width; ++t) {
                        for (int64_t c = 0; c < channels; ++c) {
                            const int64_t sourceIndex = 0 * strideBatch + c * strideChannel + 0 * strideHeight + t * strideWidth;
                            out[t * channels + c] = whisper_coreml_fp16_to_float(src[sourceIndex]);
                        }
                    }
                } else {
                    const float * src = (const float *) outputArray.dataPointer;
                    for (int64_t t = 0; t < width; ++t) {
                        for (int64_t c = 0; c < channels; ++c) {
                            const int64_t sourceIndex = 0 * strideBatch + c * strideChannel + 0 * strideHeight + t * strideWidth;
                            out[t * channels + c] = src[sourceIndex];
                        }
                    }
                }
                return;
            }
        }

        if (ctx->output_data_type == MLMultiArrayDataTypeFloat16) {
            const uint16_t * src = (const uint16_t *) outputArray.dataPointer;
            for (NSInteger i = 0; i < outputArray.count; ++i) {
                out[i] = whisper_coreml_fp16_to_float(src[i]);
            }
            return;
        }

        memcpy(out, outputArray.dataPointer, outputArray.count * sizeof(float));
    }
}

#if __cplusplus
}
#endif

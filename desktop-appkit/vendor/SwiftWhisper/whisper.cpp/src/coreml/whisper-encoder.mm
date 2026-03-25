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
    const void * data;
};

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
    // config.computeUnits = MLComputeUnitsCPUAndGPU;
    //config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
    config.computeUnits = MLComputeUnitsAll;

    NSError * loadError = nil;
    whisper_encoder_impl * model = [[whisper_encoder_impl alloc] initWithContentsOfURL:url_model configuration:config error:&loadError];
    const void * data = CFBridgingRetain(model);

    if (data == NULL) {
        return NULL;
    }

    whisper_coreml_context * ctx = new whisper_coreml_context;

    ctx->data = data;

    return ctx;
}

void whisper_coreml_free(struct whisper_coreml_context * ctx) {
    CFRelease(ctx->data);
    delete ctx;
}

void whisper_coreml_encode(
        const whisper_coreml_context * ctx,
                             int64_t   n_ctx,
                             int64_t   n_mel,
                               float * mel,
                               float * out) {
    MLMultiArray * inMultiArray = [
        [MLMultiArray alloc] initWithDataPointer: mel
                                           shape: @[@1, @(n_mel), @(n_ctx)]
                                        dataType: MLMultiArrayDataTypeFloat32
                                         strides: @[@(n_ctx*n_mel), @(n_ctx), @1]
                                     deallocator: nil
                                           error: nil
    ];

    @autoreleasepool {
        whisper_encoder_implOutput * outCoreML = [(__bridge id) ctx->data predictionFromLogmel_data:inMultiArray error:nil];

        memcpy(out, outCoreML.output.dataPointer, outCoreML.output.count * sizeof(float));
    }
}

#if __cplusplus
}
#endif

import Foundation

enum WhisperModelPreset: String, CaseIterable, Equatable {
    case tiny
    case largeV3Turbo = "large-v3-turbo"
    case largeV3 = "large-v3"

    static let `default`: WhisperModelPreset = .largeV3

    var filename: String {
        switch self {
        case .tiny:
            return "ggml-tiny.bin"
        case .largeV3Turbo:
            return "ggml-large-v3-turbo.bin"
        case .largeV3:
            return "ggml-large-v3.bin"
        }
    }

    var remoteURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)"
    }

    var displayName: String {
        switch self {
        case .tiny:
            return "Tiny（快速、低精度）"
        case .largeV3Turbo:
            return "Large V3 Turbo（快速、高精度）"
        case .largeV3:
            return "Large V3（最高精度）"
        }
    }

    var sizeHint: String {
        switch self {
        case .tiny:
            return "~75 MB"
        case .largeV3Turbo:
            return "~1.5 GB"
        case .largeV3:
            return "~2.9 GB"
        }
    }

    var coreMLEncoderRemoteURL: URL? {
        switch self {
        case .tiny:
            return nil
        case .largeV3Turbo:
            return URL(string: "https://huggingface.co/souminei/scribby-coreml-encoders/resolve/main/ggml-large-v3-turbo-encoder.mlmodelc.zip")
        case .largeV3:
            return URL(string: "https://huggingface.co/souminei/scribby-coreml-encoders/resolve/main/ggml-large-v3-encoder.mlmodelc.zip")
        }
    }
}

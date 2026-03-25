import Foundation

enum WhisperModelPreset: String, CaseIterable, Equatable {
    case tiny
    case largeV3Turbo = "large-v3-turbo"
    case largeV3 = "large-v3"

    static let `default`: WhisperModelPreset = .largeV3Turbo

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
        filename
    }
}

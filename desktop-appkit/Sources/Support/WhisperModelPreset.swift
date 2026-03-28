import Foundation

enum CoreMLEncoderProvisioning: Equatable {
    case none
    case compiledArchive
    case packageFirst
}

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

    var onboardingDescription: String {
        switch self {
        case .tiny:
            return "下載最小、速度最快，適合先快速確認內容，但精度明顯較低。"
        case .largeV3Turbo:
            return "推薦預設。速度、精度和首次體驗平衡最好，適合大多數錄音。"
        case .largeV3:
            return "精度最高，但模型更大，首次下載與 Core ML / Neural Engine 準備也最久。"
        }
    }

    var onboardingBadge: String? {
        switch self {
        case .largeV3Turbo:
            return "推薦"
        case .tiny, .largeV3:
            return nil
        }
    }

    var coreMLEncoderProvisioning: CoreMLEncoderProvisioning {
        switch self {
        case .tiny:
            return .none
        case .largeV3Turbo:
            return .packageFirst
        case .largeV3:
            return .packageFirst
        }
    }

    var coreMLRuntimeEnabled: Bool {
        switch self {
        case .tiny:
            return false
        case .largeV3Turbo, .largeV3:
            return true
        }
    }

    var remoteCompiledCoreMLArchiveURL: URL? {
        nil
    }

    var remoteCoreMLPackageArchiveURL: URL? {
        switch self {
        case .tiny:
            return nil
        case .largeV3Turbo:
            return URL(string: "https://huggingface.co/souminei/scribby-coreml-encoders/resolve/main/ggml-large-v3-turbo-encoder.mlpackage.zip")
        case .largeV3:
            return URL(string: "https://huggingface.co/souminei/scribby-coreml-encoders/resolve/main/ggml-large-v3-encoder.mlpackage.zip")
        }
    }
}

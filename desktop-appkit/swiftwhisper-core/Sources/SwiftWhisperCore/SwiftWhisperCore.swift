import AVFoundation
import Foundation
import SwiftWhisper

public struct SwiftWhisperModelSpec: Sendable, Codable, Equatable {
    public let preset: String
    public let filename: String
    public let remoteURL: URL

    public init(preset: String, filename: String, remoteURL: URL) {
        self.preset = preset
        self.filename = filename
        self.remoteURL = remoteURL
    }

    public static let tiny = SwiftWhisperModelSpec(
        preset: "tiny",
        filename: "ggml-tiny.bin",
        remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!
    )

    public static let largeV3Turbo = SwiftWhisperModelSpec(
        preset: "large-v3-turbo",
        filename: "ggml-large-v3-turbo.bin",
        remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    )

    public static let largeV3 = SwiftWhisperModelSpec(
        preset: "large-v3",
        filename: "ggml-large-v3.bin",
        remoteURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!
    )

    public static func resolveFromEnvironment() -> SwiftWhisperModelSpec {
        let environment = ProcessInfo.processInfo.environment
        if let explicitFilename = environment["SCRIBBY_SWIFTWHISPER_MODEL_FILENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitFilename.isEmpty,
           let explicitURLText = environment["SCRIBBY_SWIFTWHISPER_MODEL_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitURLText.isEmpty,
           let explicitURL = URL(string: explicitURLText)
        {
            return SwiftWhisperModelSpec(
                preset: environment["SCRIBBY_SWIFTWHISPER_MODEL_PRESET"] ?? "custom",
                filename: explicitFilename,
                remoteURL: explicitURL
            )
        }

        switch environment["SCRIBBY_SWIFTWHISPER_MODEL_PRESET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "large-v3-turbo":
            return .largeV3Turbo
        case "large-v3":
            return .largeV3
        default:
            return .largeV3Turbo
        }
    }
}

public struct SwiftWhisperRequest: Sendable, Codable {
    public var audioFileURL: URL
    public var languageCode: String
    public var diarize: Bool

    public init(audioFileURL: URL, languageCode: String = "zh", diarize: Bool = false) {
        self.audioFileURL = audioFileURL
        self.languageCode = languageCode
        self.diarize = diarize
    }
}

public struct SwiftWhisperSegmentResult: Sendable, Codable {
    public var startTimeMs: Int
    public var endTimeMs: Int
    public var text: String
    public var speakerLabel: String?
}

public struct SwiftWhisperResult: Sendable, Codable {
    public var text: String
    public var language: String
    public var count: Int
    public var suggestedFilename: String
    public var segments: [SwiftWhisperSegmentResult]
    public var modelName: String
}

public enum SwiftWhisperEvent: Sendable, Codable {
    case progress(Double)
    case partial([SwiftWhisperSegmentResult])
    case completed(SwiftWhisperResult)
    case failed(String)
}

public struct SwiftWhisperEventEnvelope: Sendable, Codable {
    public var kind: String
    public var progress: Double?
    public var segments: [SwiftWhisperSegmentResult]?
    public var result: SwiftWhisperResult?
    public var message: String?

    public init(event: SwiftWhisperEvent) {
        switch event {
        case .progress(let value):
            kind = "progress"
            progress = value
            segments = nil
            result = nil
            message = nil
        case .partial(let newSegments):
            kind = "partial_segments"
            progress = nil
            segments = newSegments
            result = nil
            message = nil
        case .completed(let finalResult):
            kind = "completed"
            progress = nil
            segments = nil
            result = finalResult
            message = nil
        case .failed(let errorMessage):
            kind = "failed"
            progress = nil
            segments = nil
            result = nil
            message = errorMessage
        }
    }
}

public enum SwiftWhisperCoreError: LocalizedError {
    case missingAudioFile(URL)
    case unsupportedLanguage(String)
    case failedToCreateTempDirectory
    case modelDownloadFailed(String)
    case emptyTranscription
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .missingAudioFile(let url):
            return "找不到音訊檔：\(url.path)"
        case .unsupportedLanguage(let code):
            return "目前 headless SwiftWhisper 僅支援固定語言設定，無法使用：\(code)"
        case .failedToCreateTempDirectory:
            return "無法建立 SwiftWhisper 模型快取資料夾"
        case .modelDownloadFailed(let message):
            return "SwiftWhisper 模型下載失敗：\(message)"
        case .emptyTranscription:
            return "SwiftWhisper 沒有產生任何可用文字"
        case .invalidRequest(let message):
            return message
        }
    }
}

public actor SwiftWhisperCore {
    private let modelStore: ModelStore
    private let modelSpec: SwiftWhisperModelSpec

    public init(
        modelStore: ModelStore = ModelStore(),
        modelSpec: SwiftWhisperModelSpec = .resolveFromEnvironment()
    ) {
        self.modelStore = modelStore
        self.modelSpec = modelSpec
    }

    public func ensureModel() async throws -> URL {
        try await modelStore.ensureModel(
            named: modelSpec.filename,
            remoteURL: modelSpec.remoteURL
        )
    }

    public func transcribe(_ request: SwiftWhisperRequest) async throws -> SwiftWhisperResult {
        try await transcribeStreaming(request) { _ in }
    }

    public func transcribeStreaming(
        _ request: SwiftWhisperRequest,
        onEvent: @escaping @Sendable (SwiftWhisperEvent) -> Void
    ) async throws -> SwiftWhisperResult {
        guard FileManager.default.fileExists(atPath: request.audioFileURL.path) else {
            throw SwiftWhisperCoreError.missingAudioFile(request.audioFileURL)
        }

        guard request.languageCode == "zh" else {
            throw SwiftWhisperCoreError.unsupportedLanguage(request.languageCode)
        }

        Diagnostics.log("swiftwhisper: ensuring model")
        let modelURL = try await ensureModel()
        Diagnostics.log("swiftwhisper: model ready at \(modelURL.path)")
        let decodedAudio = try AudioDecoder.decodeAudio(from: request.audioFileURL, diarize: request.diarize)
        Diagnostics.log("swiftwhisper: decoded \(decodedAudio.monoFrames.count) PCM frames")

        let params = WhisperParams()
        params.language = .chinese
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false

        Diagnostics.log("swiftwhisper: creating whisper context")
        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        let delegate = StreamingDelegate { event in
            onEvent(event)
        }
        whisper.delegate = delegate
        Diagnostics.log("swiftwhisper: starting transcription")
        let segments = try await whisper.transcribe(audioFrames: decodedAudio.monoFrames)
        Diagnostics.log("swiftwhisper: received \(segments.count) segments")

        let speakerLabels = Self.inferSpeakerLabels(
            for: segments,
            stereoChannels: request.diarize ? decodedAudio.stereoChannels : nil
        )

        let mappedSegments = segments.enumerated().map { index, segment in
            SwiftWhisperSegmentResult(
                startTimeMs: segment.startTime,
                endTimeMs: segment.endTime,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speakerLabel: speakerLabels[index]
            )
        }.filter { !$0.text.isEmpty }

        let fullText = mappedSegments
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullText.isEmpty else {
            throw SwiftWhisperCoreError.emptyTranscription
        }

        let baseName = request.audioFileURL.deletingPathExtension().lastPathComponent
        let finalResult = SwiftWhisperResult(
            text: fullText,
            language: request.languageCode,
            count: mappedSegments.count,
            suggestedFilename: "\(baseName)-swiftwhisper.txt",
            segments: mappedSegments,
            modelName: modelSpec.filename
        )
        onEvent(.completed(finalResult))
        return finalResult
    }

    private static func inferSpeakerLabels(
        for segments: [Segment],
        stereoChannels: [[Float]]?
    ) -> [String?] {
        guard
            let stereoChannels,
            stereoChannels.count == 2,
            stereoChannels[0].count == stereoChannels[1].count,
            !stereoChannels[0].isEmpty
        else {
            return Array(repeating: nil, count: segments.count)
        }

        let left = stereoChannels[0]
        let right = stereoChannels[1]
        let sampleCount = left.count

        return segments.map { segment in
            let start = max(0, min(sampleCount, Int(Double(segment.startTime) * 16.0)))
            let end = max(start, min(sampleCount, Int(Double(segment.endTime) * 16.0)))
            guard end > start else { return nil }

            var leftEnergy = 0.0
            var rightEnergy = 0.0
            for index in start..<end {
                leftEnergy += Double(abs(left[index]))
                rightEnergy += Double(abs(right[index]))
            }

            if leftEnergy > 1.1 * rightEnergy {
                return "說話者 A"
            }
            if rightEnergy > 1.1 * leftEnergy {
                return "說話者 B"
            }
            return "說話者 ?"
        }
    }
}

private final class StreamingDelegate: WhisperDelegate {
    private let onEvent: @Sendable (SwiftWhisperEvent) -> Void

    init(onEvent: @escaping @Sendable (SwiftWhisperEvent) -> Void) {
        self.onEvent = onEvent
    }

    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
        onEvent(.progress(progress))
    }

    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {
        let mapped = segments
            .map {
                SwiftWhisperSegmentResult(
                    startTimeMs: $0.startTime,
                    endTimeMs: $0.endTime,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    speakerLabel: nil
                )
            }
            .filter { !$0.text.isEmpty }
        guard !mapped.isEmpty else { return }
        onEvent(.partial(mapped))
    }

    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {
        onEvent(.failed(error.localizedDescription))
    }
}

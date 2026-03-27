import Foundation
import SwiftUI

enum StatusTone {
    case neutral
    case success
    case error
}

struct TranscriptSegment: Equatable {
    var startTimeMs: Int
    var endTimeMs: Int
    var text: String
    var speakerLabel: String?
}

struct TranscriptResult: Equatable {
    var text: String
    var language: String?
    var count: Int
    var hasSpeakers: Bool
    var suggestedFilename: String
    var segments: [TranscriptSegment]
}

enum ProcessingPhase: String, Equatable, CaseIterable {
    case downloading
    case enhancing
    case transcribing
    case diarizing
    case proofreading

    var color: Color {
        switch self {
        case .downloading:  return Color(red: 0.23, green: 0.51, blue: 0.96)   // #3B82F6
        case .enhancing:    return Color(red: 0.55, green: 0.36, blue: 0.96)   // #8B5CF6
        case .transcribing: return Color(red: 0.96, green: 0.62, blue: 0.04)   // #F59E0B
        case .diarizing:    return Color(red: 0.06, green: 0.73, blue: 0.51)   // #10B981
        case .proofreading: return Color(red: 0.12, green: 0.62, blue: 0.67)   // #1E9EAB
        }
    }

    var label: String {
        switch self {
        case .downloading:  return "下載模型"
        case .enhancing:    return "人聲加強"
        case .transcribing: return "轉寫"
        case .diarizing:    return "語者辨識"
        case .proofreading: return "AI 校稿"
        }
    }
}

enum ProofreadingMode: String, CaseIterable, Codable {
    case off
    case conservative
    case standard
    case readable

    var displayName: String {
        switch self {
        case .off:          return "關閉"
        case .conservative: return "保守校正"
        case .standard:     return "一般校正"
        case .readable:     return "可讀版整理"
        }
    }

    var description: String {
        switch self {
        case .off:          return "不啟用校稿"
        case .conservative: return "只修明顯的辨識錯字和缺失標點，不改文意"
        case .standard:     return "修錯字、補標點、改語境不通順的地方"
        case .readable:     return "清理口語冗詞、重複語句，讓文字更流暢"
        }
    }
}

struct DownloadProgress: Equatable {
    var filename: String
    var bytesDownloaded: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double

    var fractionCompleted: Double {
        totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0
    }
    var formattedDownloaded: String {
        ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
    }
    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
    var formattedSpeed: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
    var estimatedSecondsRemaining: Double? {
        guard bytesPerSecond > 0 else { return nil }
        return Double(totalBytes - bytesDownloaded) / bytesPerSecond
    }
}

enum QueueItemStatus: String, Equatable {
    case pending
    case processing
    case done
    case error
    case stopped
}

struct QueueItemModel: Identifiable, Equatable {
    let id: String
    let fileId: String
    var sourcePath: String
    var filename: String
    var size: Int64
    var status: QueueItemStatus
    var progress: Int
    var message: String
    var error: String?
    var result: TranscriptResult?
    var phase: ProcessingPhase?
    var activePhases: [ProcessingPhase] = []
    var downloadProgress: DownloadProgress?
}

struct FloatingLineModel: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let startXOffset: CGFloat
    let endXOffset: CGFloat
    let riseDistance: CGFloat
    let fontSize: CGFloat
    let delay: Double
}

struct ProviderSnapshot: Equatable {
    var items: [QueueItemModel]
    var isProcessing: Bool
    var isPaused: Bool
    var stopRequested: Bool
    var supportsHardStop: Bool
    var currentFileId: String?

    static let empty = ProviderSnapshot(
        items: [],
        isProcessing: false,
        isPaused: false,
        stopRequested: false,
        supportsHardStop: false,
        currentFileId: nil
    )
}

struct ProviderInfo: Equatable {
    var engine: String
    var model: String
    var device: String
    var supportsHardStop: Bool
    var snapshot: ProviderSnapshot
}

struct TokenVerificationResult: Codable, Equatable {
    var ok: Bool
    var message: String
}

struct StopRequestResult: Equatable {
    var accepted: Bool
    var hardStopped: Bool
    var supportsHardStop: Bool
    var message: String
    var snapshot: ProviderSnapshot
}

struct TranscriptionRequest: Equatable {
    var language: String
    var diarize: Bool
    var speakers: Int
    var token: String
    var enhance: Bool
    var proofreadingMode: ProofreadingMode
}

enum ProviderEvent: Equatable {
    case backendReady(ProviderInfo)
    case queueUpdated(ProviderSnapshot)
    case queuePaused(String)
    case queueResumed(String)
    case taskStarted(fileId: String, filename: String)
    case taskProgress(fileId: String, message: String, progress: Int?)
    case taskLog(fileId: String, message: String)
    case taskPartialText(fileId: String, text: String)
    case taskCompleted(fileId: String, filename: String, result: TranscriptResult)
    case taskFailed(fileId: String, message: String)
    case taskStopped(fileId: String, message: String)
    case taskPhaseChanged(fileId: String, phase: ProcessingPhase, activePhases: [ProcessingPhase])
    case taskDownloadProgress(fileId: String, info: DownloadProgress)
    case backendError(String)
}

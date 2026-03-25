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

struct QueueItemModel: Identifiable, Equatable {
    let id: String
    let fileId: String
    var filename: String
    var size: Int64
    var status: String
    var progress: Int
    var message: String
    var error: String?
    var result: TranscriptResult?
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
    case backendError(String)
}

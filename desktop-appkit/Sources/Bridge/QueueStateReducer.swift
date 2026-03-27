import Foundation

enum ControlAction: Equatable {
    case pause
    case sleepPause
    case stop
    case shutdown
}

enum QueueStateReducer {
    static func enqueue(paths: [String], into snapshot: inout ProviderSnapshot) throws {
        var occupiedNames = Set(snapshot.items.map(\.filename))
        let newItems = try paths.map { path in
            try makeQueueItem(path: path, occupiedNames: &occupiedNames)
        }
        snapshot.items.append(contentsOf: newItems)
    }

    static func beginTranscription(request: TranscriptionRequest?, snapshot: inout ProviderSnapshot) throws {
        guard !snapshot.isProcessing else {
            throw providerError("純 Swift 核心版正在轉譯中")
        }

        if let request,
           request.diarize,
           request.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw providerError("已開啟語者辨識，請先輸入並驗證 HuggingFace Token")
        }

        let pendingIndex = snapshot.items.firstIndex { $0.status == .pending || $0.status == .error }
        guard pendingIndex != nil else {
            throw providerError("目前沒有可轉譯的檔案")
        }

        snapshot.isProcessing = true
        snapshot.isPaused = false
        snapshot.stopRequested = false
    }

    static func pauseRequested(snapshot: inout ProviderSnapshot) {
        snapshot.isPaused = true
        snapshot.stopRequested = snapshot.isProcessing
    }

    static func resumeRequested(snapshot: inout ProviderSnapshot) {
        snapshot.isPaused = false
        snapshot.stopRequested = false
    }

    static func stopRequested(snapshot: inout ProviderSnapshot) -> StopRequestResult {
        guard snapshot.isProcessing, snapshot.currentFileId != nil else {
            return StopRequestResult(
                accepted: false,
                hardStopped: false,
                supportsHardStop: true,
                message: "目前沒有可停止的檔案",
                snapshot: snapshot
            )
        }

        snapshot.stopRequested = true
        return StopRequestResult(
            accepted: true,
            hardStopped: true,
            supportsHardStop: true,
            message: "正在停止目前檔案...",
            snapshot: snapshot
        )
    }

    static func clearQueue(snapshot: inout ProviderSnapshot) throws {
        guard !snapshot.isProcessing else {
            throw providerError("轉譯中無法清除序列")
        }
        snapshot = .empty
    }

    static func removeQueueItem(fileId: String, snapshot: inout ProviderSnapshot) throws {
        guard let index = snapshot.items.firstIndex(where: { $0.fileId == fileId }) else {
            return
        }
        if snapshot.items[index].status == .processing || snapshot.currentFileId == fileId {
            throw providerError("轉譯中的檔案無法刪除")
        }
        snapshot.items.remove(at: index)
        if snapshot.items.isEmpty {
            resetToIdle(snapshot: &snapshot)
        }
    }

    static func updateProcessingState(
        for index: Int,
        snapshot: inout ProviderSnapshot,
        message: String,
        phase: ProcessingPhase? = nil,
        activePhases: [ProcessingPhase] = []
    ) {
        for itemIndex in snapshot.items.indices {
            if itemIndex == index {
                snapshot.items[itemIndex].status = .processing
                snapshot.items[itemIndex].message = message
                snapshot.items[itemIndex].progress = 5
                snapshot.items[itemIndex].phase = phase
                snapshot.items[itemIndex].activePhases = activePhases
                snapshot.items[itemIndex].downloadProgress = nil
                snapshot.currentFileId = snapshot.items[itemIndex].fileId
            } else if snapshot.items[itemIndex].status == .processing {
                snapshot.items[itemIndex].status = .pending
                snapshot.items[itemIndex].message = ""
                snapshot.items[itemIndex].progress = 0
                snapshot.items[itemIndex].phase = nil
                snapshot.items[itemIndex].activePhases = []
                snapshot.items[itemIndex].downloadProgress = nil
            }
        }
        snapshot.isProcessing = true
    }

    static func updatePyannoteState(
        for index: Int,
        snapshot: inout ProviderSnapshot,
        activePhases: [ProcessingPhase] = []
    ) {
        snapshot.items[index].status = .processing
        snapshot.items[index].message = "正在使用 pyannote 進行多語者辨識..."
        snapshot.items[index].progress = 70
        snapshot.items[index].phase = .diarizing
        snapshot.items[index].activePhases = activePhases
        snapshot.items[index].downloadProgress = nil
    }

    static func applyResult(
        _ result: HeadlessResult,
        to index: Int,
        snapshot: inout ProviderSnapshot,
        diarizeRequested: Bool,
        usedPyannote: Bool
    ) {
        let mappedSegments = result.segments.map {
            TranscriptSegment(
                startTimeMs: $0.startTimeMs,
                endTimeMs: $0.endTimeMs,
                text: $0.text,
                speakerLabel: $0.speakerLabel
            )
        }
        let hasSpeakers = mappedSegments.contains { $0.speakerLabel != nil }

        snapshot.items[index].status = .done
        snapshot.items[index].progress = 100
        snapshot.items[index].message = diarizeRequested
            ? (hasSpeakers
                ? (usedPyannote ? "SwiftWhisper 轉譯完成，pyannote 已標記多語者" : "SwiftWhisper 轉譯完成，已標記說話者")
                : "SwiftWhisper 轉譯完成，但未取得語者標籤")
            : "SwiftWhisper 轉譯完成"
        snapshot.items[index].error = nil
        snapshot.items[index].result = TranscriptResult(
            text: result.text,
            language: result.language,
            count: result.count,
            hasSpeakers: hasSpeakers,
            suggestedFilename: result.suggestedFilename,
            segments: mappedSegments
        )
    }

    static func applyFailure(_ error: Error, to index: Int, snapshot: inout ProviderSnapshot) {
        snapshot.items[index].status = .error
        snapshot.items[index].progress = 0
        snapshot.items[index].message = ""
        snapshot.items[index].error = error.localizedDescription
        snapshot.items[index].result = nil
        snapshot.items[index].phase = nil
        snapshot.items[index].activePhases = []
        snapshot.items[index].downloadProgress = nil
    }

    @discardableResult
    static func handleControlAction(
        _ action: ControlAction,
        at index: Int,
        snapshot: inout ProviderSnapshot
    ) -> (shouldBreakLoop: Bool, event: ProviderEvent?) {
        switch action {
        case .pause:
            snapshot.items[index].status = .pending
            snapshot.items[index].progress = 0
            snapshot.items[index].message = ""
            snapshot.items[index].error = nil
            snapshot.items[index].phase = nil
            snapshot.items[index].activePhases = []
            snapshot.items[index].downloadProgress = nil
            snapshot.currentFileId = nil
            snapshot.isProcessing = false
            snapshot.isPaused = true
            snapshot.stopRequested = false
            return (true, .queuePaused("已暫停，恢復後會重新開始目前檔案"))
        case .sleepPause:
            snapshot.items[index].status = .pending
            snapshot.items[index].progress = 0
            snapshot.items[index].message = ""
            snapshot.items[index].error = nil
            snapshot.items[index].phase = nil
            snapshot.items[index].activePhases = []
            snapshot.items[index].downloadProgress = nil
            snapshot.currentFileId = nil
            snapshot.isProcessing = false
            snapshot.isPaused = true
            snapshot.stopRequested = false
            return (true, .queuePaused("系統即將睡眠，已自動暫停目前佇列"))
        case .stop:
            snapshot.items[index].status = .stopped
            snapshot.items[index].progress = 0
            snapshot.items[index].message = ""
            snapshot.items[index].error = nil
            snapshot.items[index].result = nil
            snapshot.items[index].phase = nil
            snapshot.items[index].activePhases = []
            snapshot.items[index].downloadProgress = nil
            snapshot.currentFileId = nil
            snapshot.isProcessing = false
            snapshot.isPaused = false
            snapshot.stopRequested = false
            return (true, .taskStopped(fileId: snapshot.items[index].fileId, message: "已停止目前檔案"))
        case .shutdown:
            snapshot.currentFileId = nil
            snapshot.isProcessing = false
            snapshot.stopRequested = false
            return (true, nil)
        }
    }

    static func finalizeProcessing(snapshot: inout ProviderSnapshot) {
        if !snapshot.items.contains(where: { $0.status == .processing }) {
            snapshot.isProcessing = false
            snapshot.currentFileId = nil
            snapshot.stopRequested = false
        }
    }

    static func providerError(_ message: String) -> Error {
        NSError(
            domain: "SwiftWhisperProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func resetToIdle(snapshot: inout ProviderSnapshot) {
        snapshot.currentFileId = nil
        snapshot.isProcessing = false
        snapshot.isPaused = false
        snapshot.stopRequested = false
    }

    private static func makeQueueItem(path: String, occupiedNames: inout Set<String>) throws -> QueueItemModel {
        let url = URL(fileURLWithPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attributes?[.size] as? NSNumber
        let fileId = UUID().uuidString
        let filename = uniqueDisplayName(for: url.lastPathComponent, occupiedNames: &occupiedNames)
        return QueueItemModel(
            id: fileId,
            fileId: fileId,
            sourcePath: path,
            filename: filename,
            size: size?.int64Value ?? 0,
            status: .pending,
            progress: 0,
            message: "",
            error: nil,
            result: nil
        )
    }

    private static func uniqueDisplayName(for original: String, occupiedNames: inout Set<String>) -> String {
        if !occupiedNames.contains(original) {
            occupiedNames.insert(original)
            return original
        }

        let url = URL(fileURLWithPath: original)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        for index in 2...999 {
            let candidate: String
            if ext.isEmpty {
                candidate = "\(stem) (\(index))"
            } else {
                candidate = "\(stem) (\(index)).\(ext)"
            }
            if !occupiedNames.contains(candidate) {
                occupiedNames.insert(candidate)
                return candidate
            }
        }

        let fallback = "\(stem)-\(UUID().uuidString.prefix(6))" + (ext.isEmpty ? "" : ".\(ext)")
        occupiedNames.insert(fallback)
        return fallback
    }
}

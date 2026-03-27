import Foundation

@MainActor
final class SwiftWhisperProvider: TranscriptionProvider {
    var onEvent: ((ProviderEvent) -> Void)?

    private var snapshot = ProviderSnapshot.empty
    private var workerTask: Task<Void, Never>?
    private let modelPreset: WhisperModelPreset
    private let processSupervisor = ProcessSupervisor()
    private var pendingControlAction: ControlAction?
    private var lastTranscriptionRequest: TranscriptionRequest?
    private var chunkStates: [String: ChunkedTaskState] = [:]
    private var info = ProviderInfo(
        engine: "swiftwhisper",
        model: WhisperModelPreset.default.displayName,
        device: "native-swift",
        supportsHardStop: true,
        snapshot: .empty
    )

    init(modelPreset: WhisperModelPreset = .default) {
        self.modelPreset = modelPreset
        self.info.model = modelPreset.displayName
    }

    func start() throws {
        _ = try PathResolver.swiftWhisperExecutable()
        _ = try PathResolver.swiftWhisperModelDirectory()
        syncInfo()
    }

    func shutdown() {
        pendingControlAction = .shutdown
        workerTask?.cancel()
        workerTask = nil
        Task {
            await processSupervisor.terminateAll()
            await processSupervisor.cleanupAllTemporaryFiles()
            await PythonEnvironmentManager.shared.cancelCurrentWork()
        }
        chunkStates.removeAll()
    }

    func getInfo() async throws -> ProviderInfo {
        syncInfo()
        return info
    }

    func verifyToken(_ token: String) async throws -> TokenVerificationResult {
        try await PythonEnvironmentManager.shared.ensureReady(for: .diarization) { _ in }
        return try await TranscriptionPipelineRunner.verifyHuggingFaceToken(token)
    }

    func enqueue(paths: [String]) async throws -> ProviderSnapshot {
        try QueueStateReducer.enqueue(paths: paths, into: &snapshot)
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
        return snapshot
    }

    func startTranscription(_ request: TranscriptionRequest) async throws -> ProviderSnapshot {
        try QueueStateReducer.beginTranscription(request: request, snapshot: &snapshot)
        lastTranscriptionRequest = request
        pendingControlAction = nil
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
        startWorker(for: request)
        return snapshot
    }

    func setPaused(_ paused: Bool) async throws -> ProviderSnapshot {
        if paused {
            guard !snapshot.isPaused else { return snapshot }
            QueueStateReducer.pauseRequested(snapshot: &snapshot)
            pendingControlAction = .pause
            syncInfo()
            onEvent?(.queueUpdated(snapshot))

            if snapshot.isProcessing {
                workerTask?.cancel()
                await processSupervisor.terminateAll()
                await PythonEnvironmentManager.shared.cancelCurrentWork()
            } else {
                onEvent?(.queuePaused(pauseMessage(for: snapshot.currentFileId)))
                onEvent?(.queueUpdated(snapshot))
            }
            return snapshot
        }

        guard snapshot.isPaused else { return snapshot }
        guard let request = lastTranscriptionRequest else {
            throw QueueStateReducer.providerError("目前沒有可恢復的轉譯任務")
        }

        QueueStateReducer.resumeRequested(snapshot: &snapshot)
        pendingControlAction = nil
        syncInfo()
        onEvent?(.queueResumed("已恢復轉譯"))
        onEvent?(.queueUpdated(snapshot))

        if snapshot.items.contains(where: { $0.status == .pending }) {
            snapshot.isProcessing = true
            syncInfo()
            onEvent?(.queueUpdated(snapshot))
            startWorker(for: request)
        }
        return snapshot
    }

    func stopCurrent() async throws -> StopRequestResult {
        let result = QueueStateReducer.stopRequested(snapshot: &snapshot)
        guard result.accepted else { return result }

        pendingControlAction = .stop
        syncInfo()
        onEvent?(.queueUpdated(snapshot))

        workerTask?.cancel()
        await processSupervisor.terminateAll()
        await PythonEnvironmentManager.shared.cancelCurrentWork()

        return StopRequestResult(
            accepted: true,
            hardStopped: true,
            supportsHardStop: true,
            message: "正在停止目前檔案...",
            snapshot: snapshot
        )
    }

    func clearQueue() async throws -> ProviderSnapshot {
        try QueueStateReducer.clearQueue(snapshot: &snapshot)
        await cleanupAllChunkStates()
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
        return snapshot
    }

    func removeQueueItem(fileId: String) async throws -> ProviderSnapshot {
        try QueueStateReducer.removeQueueItem(fileId: fileId, snapshot: &snapshot)
        await cleanupChunkState(for: fileId)
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
        return snapshot
    }

    func saveResult(fileId: String, destinationPath: String) async throws {
        guard let item = snapshot.items.first(where: { $0.fileId == fileId }),
              let result = item.result else {
            throw QueueStateReducer.providerError("找不到可儲存的逐字稿")
        }
        let body = formattedTranscriptText(for: item.filename, result: result)
        try body.write(to: URL(fileURLWithPath: destinationPath), atomically: true, encoding: .utf8)
    }

    private func startWorker(for request: TranscriptionRequest) {
        workerTask?.cancel()
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.processPending(request: request)
        }
    }

    private func processPending(request: TranscriptionRequest) async {
        while let index = snapshot.items.firstIndex(where: { $0.status == .pending }) {
            if Task.isCancelled || snapshot.isPaused {
                break
            }

            let item = snapshot.items[index]
            var activePhases: [ProcessingPhase] = []
            if request.enhance { activePhases.append(.enhancing) }
            activePhases.append(.transcribing)
            if request.diarize { activePhases.append(.diarizing) }
            if request.proofreadingMode != .off { activePhases.append(.proofreading) }

            let initialPhase: ProcessingPhase = request.enhance ? .enhancing : .transcribing
            let progressMessage = initialPhase.label + "..."

            QueueStateReducer.updateProcessingState(
                for: index,
                snapshot: &snapshot,
                message: progressMessage,
                phase: initialPhase,
                activePhases: activePhases
            )
            syncInfo()
            DebugLogger.shared.write("[task] started: \(item.filename) phases=\(activePhases.map(\.rawValue))")
            onEvent?(.taskStarted(fileId: item.fileId, filename: item.filename))
            onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: initialPhase, activePhases: activePhases))
            onEvent?(.taskProgress(fileId: item.fileId, message: progressMessage, progress: 5))
            onEvent?(.queueUpdated(snapshot))

            var enhancedTempURL: URL?
            var shouldBreakLoop = false

            do {
                var chunkState = chunkStates[item.fileId]

                if chunkState == nil, request.enhance {
                    onEvent?(.taskProgress(fileId: item.fileId, message: "正在準備人聲加強環境...", progress: nil))
                    try await PythonEnvironmentManager.shared.ensureReady(
                        for: .enhancement,
                        log: { _ in },
                        pipProgress: { [weak self] info in
                            Task { @MainActor in
                                guard let self else { return }
                                self.handlePipProgress(info, fileId: item.fileId, itemIndex: index, activePhases: activePhases)
                            }
                        }
                    )
                    snapshot.items[index].downloadProgress = nil
                    snapshot.items[index].phase = initialPhase
                    onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: initialPhase, activePhases: activePhases))
                    onEvent?(.queueUpdated(snapshot))

                    if let action = pendingControlAction {
                        shouldBreakLoop = handleControlAction(action, at: index)
                        throw CancellationError()
                    }
                }

                if chunkState == nil, request.diarize {
                    onEvent?(.taskProgress(fileId: item.fileId, message: "正在準備語者辨識環境...", progress: nil))
                    try await PythonEnvironmentManager.shared.ensureReady(
                        for: .diarization,
                        log: { _ in },
                        pipProgress: { [weak self] info in
                            Task { @MainActor in
                                guard let self else { return }
                                self.handlePipProgress(info, fileId: item.fileId, itemIndex: index, activePhases: activePhases)
                            }
                        }
                    )
                    snapshot.items[index].downloadProgress = nil
                    snapshot.items[index].phase = initialPhase
                    onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: initialPhase, activePhases: activePhases))
                    onEvent?(.queueUpdated(snapshot))

                    if let action = pendingControlAction {
                        shouldBreakLoop = handleControlAction(action, at: index)
                        throw CancellationError()
                    }
                }

                if chunkState == nil {
                    let pipelineSourcePath: String
                    if request.enhance {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension("wav")
                        enhancedTempURL = tempURL
                        await processSupervisor.trackTemporaryFile(tempURL)

                        try await TranscriptionPipelineRunner.runSpeechEnhancement(
                            filePath: item.sourcePath,
                            outputPath: tempURL.path,
                            processSupervisor: processSupervisor,
                            log: { line in DebugLogger.shared.write("[enhance] \(line)") },
                            downloadProgress: { [weak self] filename, downloaded, total in
                                Task { @MainActor in
                                    guard let self else { return }
                                    let info = Self.makeDownloadProgress(filename: filename, downloaded: downloaded, total: total)
                                    self.onEvent?(.taskDownloadProgress(fileId: item.fileId, info: info))
                                }
                            }
                        )
                        pipelineSourcePath = tempURL.path
                    } else {
                        pipelineSourcePath = item.sourcePath
                    }

                    let prepared = try await AudioChunker.prepareChunkedTranscription(
                        inputPath: pipelineSourcePath,
                        processSupervisor: processSupervisor
                    )
                    chunkState = ChunkedTaskState(
                        prepared: prepared,
                        diarizationRequested: request.diarize
                    )
                    chunkStates[item.fileId] = chunkState
                    if let tempURL = enhancedTempURL {
                        await processSupervisor.cleanupTemporaryFile(tempURL)
                        enhancedTempURL = nil
                    }
                }

                guard var activeChunkState = chunkState else {
                    throw QueueStateReducer.providerError("無法建立 chunk 轉譯狀態")
                }

                snapshot.items[index].message = chunkProgressMessage(for: activeChunkState)
                snapshot.items[index].progress = chunkProgressValue(for: activeChunkState)
                snapshot.items[index].phase = .transcribing
                snapshot.items[index].downloadProgress = nil
                syncInfo()
                onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: .transcribing, activePhases: activePhases))
                onEvent?(.taskProgress(fileId: item.fileId, message: chunkProgressMessage(for: activeChunkState), progress: chunkProgressValue(for: activeChunkState)))
                onEvent?(.queueUpdated(snapshot))

                while activeChunkState.nextChunkIndex < activeChunkState.prepared.chunks.count {
                    try Task.checkCancellation()

                    let chunk = activeChunkState.prepared.chunks[activeChunkState.nextChunkIndex]
                    let chunkMessage = chunkProgressMessage(for: activeChunkState)
                    snapshot.items[index].message = chunkMessage
                    snapshot.items[index].progress = chunkProgressValue(for: activeChunkState)
                    snapshot.items[index].phase = .transcribing
                    snapshot.items[index].downloadProgress = nil
                    syncInfo()
                    onEvent?(.taskProgress(fileId: item.fileId, message: chunkMessage, progress: chunkProgressValue(for: activeChunkState)))
                    onEvent?(.queueUpdated(snapshot))

                    let chunkResult = try await TranscriptionPipelineRunner.runHeadless(
                        filePath: chunk.url.path,
                        language: request.language,
                        diarize: false,
                        modelPreset: modelPreset,
                        processSupervisor: processSupervisor,
                        event: { [weak self] streamEvent in
                            Task { @MainActor in
                                guard let self else { return }
                                self.handleStreamEvent(streamEvent, itemIndex: index, fileId: item.fileId, chunkState: activeChunkState)
                            }
                        },
                        log: { line in DebugLogger.shared.write("[whisper] \(line)") },
                        downloadProgress: { [weak self] filename, downloaded, total in
                            Task { @MainActor in
                                guard let self else { return }
                                let info = Self.makeDownloadProgress(filename: filename, downloaded: downloaded, total: total)
                                if !self.snapshot.items[index].activePhases.contains(.downloading) {
                                    self.snapshot.items[index].activePhases.insert(.downloading, at: 0)
                                }
                                self.snapshot.items[index].phase = .downloading
                                self.onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: .downloading, activePhases: self.snapshot.items[index].activePhases))
                                self.onEvent?(.taskDownloadProgress(fileId: item.fileId, info: info))
                            }
                        }
                    )

                    let transcription = ChunkTranscription(chunk: chunk, result: chunkResult)
                    activeChunkState.mergedSegments = TranscriptChunkMerger.append(
                        existing: activeChunkState.mergedSegments,
                        chunkResult: transcription
                    )
                    activeChunkState.nextChunkIndex += 1
                    activeChunkState.language = chunkResult.language
                    activeChunkState.suggestedFilename = chunkResult.suggestedFilename
                    activeChunkState.modelName = chunkResult.modelName
                    chunkStates[item.fileId] = activeChunkState
                }

                let mergedResult = activeChunkState.mergedAsrResult
                guard let result = mergedResult else {
                    throw QueueStateReducer.providerError("無法合併 chunk 轉譯結果")
                }

                let finalResult: HeadlessResult
                if activeChunkState.diarizationRequested && !activeChunkState.diarizationCompleted {
                    QueueStateReducer.updatePyannoteState(for: index, snapshot: &snapshot, activePhases: activePhases)
                    syncInfo()
                    onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: .diarizing, activePhases: activePhases))
                    onEvent?(.taskProgress(fileId: item.fileId, message: "正在使用 pyannote 進行多語者辨識...", progress: 70))
                    onEvent?(.queueUpdated(snapshot))

                    let diarizedSegments = try await TranscriptionPipelineRunner.runPyannoteDiarization(
                        filePath: activeChunkState.prepared.normalizedAudioURL.path,
                        token: request.token,
                        speakers: request.speakers,
                        segments: result.segments,
                        processSupervisor: processSupervisor,
                        log: { line in DebugLogger.shared.write("[diarize] \(line)") }
                    )
                    activeChunkState.diarizationCompleted = true
                    chunkStates[item.fileId] = activeChunkState
                    finalResult = HeadlessResult(
                        text: result.text,
                        language: result.language,
                        count: diarizedSegments.count,
                        suggestedFilename: result.suggestedFilename,
                        segments: diarizedSegments,
                        modelName: result.modelName
                    )
                } else {
                    finalResult = result
                }

                // AI 校稿（失敗時 fallback 到原始轉寫結果，不中斷流程）
                let proofreadResult: HeadlessResult
                if request.proofreadingMode != .off {
                    do {
                        try await PythonEnvironmentManager.shared.ensureReady(
                            for: .proofreading,
                            log: { line in DebugLogger.shared.write("[proofread-env] \(line)") },
                            pipProgress: { [weak self] info in
                                Task { @MainActor in
                                    guard let self else { return }
                                    self.handlePipProgress(info, fileId: item.fileId, itemIndex: index, activePhases: activePhases)
                                }
                            }
                        )
                        snapshot.items[index].downloadProgress = nil
                        snapshot.items[index].phase = .proofreading
                        snapshot.items[index].message = "正在 AI 校稿..."
                        syncInfo()
                        onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: .proofreading, activePhases: activePhases))
                        onEvent?(.taskProgress(fileId: item.fileId, message: "正在 AI 校稿...", progress: 90))
                        onEvent?(.queueUpdated(snapshot))

                        DebugLogger.shared.write("[proofread] start mode=\(request.proofreadingMode.rawValue) segments=\(finalResult.segments.count) lang=\(finalResult.language)")
                        proofreadResult = try await TranscriptionPipelineRunner.runProofreading(
                            result: finalResult,
                            mode: request.proofreadingMode,
                            processSupervisor: processSupervisor,
                            log: { line in DebugLogger.shared.write("[proofread] \(line)") }
                        )
                        DebugLogger.shared.write("[proofread] done segments=\(proofreadResult.segments.count)")
                    } catch {
                        let errMsg = "AI 校稿失敗，使用原始轉寫結果：\(error.localizedDescription)"
                        DebugLogger.shared.write("[proofread] ERROR: \(errMsg)")
                        onEvent?(.taskLog(fileId: item.fileId, message: errMsg))
                        proofreadResult = finalResult
                    }
                } else {
                    proofreadResult = finalResult
                }

                QueueStateReducer.applyResult(
                    proofreadResult,
                    to: index,
                    snapshot: &snapshot,
                    diarizeRequested: request.diarize,
                    usedPyannote: request.diarize
                )
                syncInfo()
                if let result = snapshot.items[index].result {
                    DebugLogger.shared.write("[task] completed: \(item.filename) segments=\(result.segments.count) lang=\(result.language ?? "-")")
                    onEvent?(.taskCompleted(fileId: item.fileId, filename: item.filename, result: result))
                }
                onEvent?(.queueUpdated(snapshot))
                await cleanupChunkState(for: item.fileId)

                if let action = pendingControlAction {
                    pendingControlAction = nil
                    snapshot.currentFileId = nil
                    snapshot.isProcessing = false
                    snapshot.stopRequested = false
                    if action == .pause {
                        snapshot.isPaused = true
                        syncInfo()
                        onEvent?(.queuePaused(pauseMessage(for: snapshot.currentFileId)))
                        onEvent?(.queueUpdated(snapshot))
                    } else if action == .sleepPause {
                        snapshot.isPaused = true
                        syncInfo()
                        onEvent?(.queuePaused("系統即將睡眠，已自動暫停目前佇列"))
                        onEvent?(.queueUpdated(snapshot))
                    } else {
                        snapshot.isPaused = false
                        syncInfo()
                        onEvent?(.queueUpdated(snapshot))
                    }
                    shouldBreakLoop = true
                }
            } catch {
                if shouldBreakLoop {
                    // control action already handled
                } else if let action = pendingControlAction {
                    shouldBreakLoop = handleControlAction(action, at: index)
                } else {
                    DebugLogger.shared.write("[task] failed: \(item.filename) — \(error.localizedDescription)")
                    await cleanupChunkState(for: item.fileId)
                    QueueStateReducer.applyFailure(error, to: index, snapshot: &snapshot)
                    syncInfo()
                    onEvent?(.taskFailed(fileId: item.fileId, message: error.localizedDescription))
                    onEvent?(.queueUpdated(snapshot))
                }
            }

            if let tempURL = enhancedTempURL {
                await processSupervisor.cleanupTemporaryFile(tempURL)
            }

            if shouldBreakLoop || Task.isCancelled || snapshot.isPaused {
                break
            }
        }

        QueueStateReducer.finalizeProcessing(snapshot: &snapshot)
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
    }

    private func handlePipProgress(_ info: PipDownloadInfo, fileId: String, itemIndex: Int, activePhases: [ProcessingPhase]) {
        guard itemIndex < snapshot.items.count else { return }

        if !snapshot.items[itemIndex].activePhases.contains(.downloading) {
            snapshot.items[itemIndex].activePhases.insert(.downloading, at: 0)
        }
        snapshot.items[itemIndex].phase = .downloading

        let statusLabel: String
        switch info.status {
        case "Downloading": statusLabel = "正在下載套件..."
        case "Installing": statusLabel = "正在安裝套件..."
        case "Collecting": statusLabel = "正在收集套件..."
        case "Done": statusLabel = "安裝完成"
        default: statusLabel = "正在準備環境..."
        }

        let dlInfo = DownloadProgress(
            filename: statusLabel,
            bytesDownloaded: info.downloadedBytes,
            totalBytes: info.totalBytes,
            bytesPerSecond: 0
        )
        snapshot.items[itemIndex].downloadProgress = dlInfo
        syncInfo()

        onEvent?(.taskPhaseChanged(fileId: fileId, phase: .downloading, activePhases: snapshot.items[itemIndex].activePhases))
        onEvent?(.taskDownloadProgress(fileId: fileId, info: dlInfo))
        onEvent?(.queueUpdated(snapshot))
    }

    private func handleStreamEvent(_ event: HeadlessStreamEvent, itemIndex: Int, fileId: String, chunkState: ChunkedTaskState? = nil) {
        guard itemIndex < snapshot.items.count,
              snapshot.items[itemIndex].phase == .transcribing || snapshot.items[itemIndex].phase == nil
        else { return }

        switch event {
        case .progress(let progress):
            let percentage = Int((progress * 100.0).rounded())
            let chunkPrefix = chunkState.map(chunkProgressMessage(for:)) ?? "正在使用 SwiftWhisper 轉寫..."
            let overallProgress = chunkState.map { state in
                let perChunk = (Double(state.nextChunkIndex) + progress) / Double(max(state.prepared.chunks.count, 1))
                return Int((perChunk * 100).rounded())
            } ?? percentage
            snapshot.items[itemIndex].progress = max(snapshot.items[itemIndex].progress, min(overallProgress, 96))
            snapshot.items[itemIndex].message = chunkPrefix
            syncInfo()
            onEvent?(.taskProgress(fileId: fileId, message: chunkPrefix, progress: overallProgress))
            onEvent?(.queueUpdated(snapshot))
        case .partial(let segments):
            let text = segments
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onEvent?(.taskPartialText(fileId: fileId, text: text))
        case .completed:
            break
        case .failed(let message):
            onEvent?(.taskLog(fileId: fileId, message: message))
        }
    }

    @discardableResult
    private func handleControlAction(_ action: ControlAction, at index: Int) -> Bool {
        pendingControlAction = nil
        let fileId = snapshot.items[index].fileId
        let resolution = QueueStateReducer.handleControlAction(action, at: index, snapshot: &snapshot)
        switch action {
        case .pause:
            onEvent?(.queuePaused(pauseMessage(for: fileId)))
        case .sleepPause:
            onEvent?(.queuePaused("系統即將睡眠，已自動暫停目前佇列"))
        case .stop, .shutdown:
            Task {
                await self.cleanupChunkState(for: fileId)
            }
        }
        syncInfo()
        if let event = resolution.event, action != .pause, action != .sleepPause {
            onEvent?(event)
        }
        onEvent?(.queueUpdated(snapshot))
        return resolution.shouldBreakLoop
    }

    private func syncInfo() {
        info.supportsHardStop = true
        info.snapshot = snapshot
    }

    private func formattedTranscriptText(for filename: String, result: TranscriptResult) -> String {
        let header = [
            "檔案：\(filename)",
            "模型：\(info.model)",
            "語言：\(result.language ?? "unknown")",
            "段數：\(result.count)",
        ].joined(separator: "\n")

        let segmentBody = result.segments.enumerated().map { index, segment in
            let order = String(format: "%02d", index + 1)
            let speakerPrefix = segment.speakerLabel.map { "\($0) · " } ?? ""
            return "[\(order)] \(speakerPrefix)\(formatTime(segment.startTimeMs)) - \(formatTime(segment.endTimeMs))\n\(segment.text)"
        }
        .joined(separator: "\n\n")

        return """
        \(header)

        ----

        \(segmentBody)
        """
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds / 1000, 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func makeDownloadProgress(filename: String, downloaded: Int64, total: Int64) -> DownloadProgress {
        DownloadProgress(
            filename: filename,
            bytesDownloaded: downloaded,
            totalBytes: totalBytesOrZero(total),
            bytesPerSecond: 0
        )
    }

    private static func totalBytesOrZero(_ total: Int64) -> Int64 {
        max(total, 0)
    }

    private func pauseMessage(for fileId: String?) -> String {
        guard let fileId, let state = chunkStates[fileId] else {
            return "已暫停，恢復後會重新開始目前檔案"
        }
        if state.nextChunkIndex < state.prepared.chunks.count {
            return "已暫停，恢復後會從第 \(state.nextChunkIndex + 1) / \(state.prepared.chunks.count) 段繼續"
        }
        if state.diarizationRequested && !state.diarizationCompleted {
            return "已暫停，恢復後會重新進行語者辨識"
        }
        return "已暫停，恢復後會重新開始目前檔案"
    }

    private func chunkProgressMessage(for state: ChunkedTaskState) -> String {
        let current = min(state.nextChunkIndex + 1, max(state.prepared.chunks.count, 1))
        return "正在轉寫第 \(current) / \(state.prepared.chunks.count) 段..."
    }

    private func chunkProgressValue(for state: ChunkedTaskState) -> Int {
        guard !state.prepared.chunks.isEmpty else { return 15 }
        return Int((Double(state.nextChunkIndex) / Double(state.prepared.chunks.count) * 100).rounded())
    }

    private func cleanupChunkState(for fileId: String) async {
        guard let state = chunkStates.removeValue(forKey: fileId) else { return }
        await processSupervisor.cleanupTemporaryFile(state.prepared.normalizedAudioURL)
        for chunk in state.prepared.chunks {
            await processSupervisor.cleanupTemporaryFile(chunk.url)
        }
    }

    private func cleanupAllChunkStates() async {
        let keys = Array(chunkStates.keys)
        for key in keys {
            await cleanupChunkState(for: key)
        }
    }
}

private struct ChunkedTaskState {
    let prepared: PreparedChunkedTranscription
    let diarizationRequested: Bool
    var nextChunkIndex: Int = 0
    var mergedSegments: [HeadlessSegment] = []
    var language: String?
    var suggestedFilename: String?
    var modelName: String?
    var diarizationCompleted: Bool = false

    var mergedAsrResult: HeadlessResult? {
        guard let language, let suggestedFilename, let modelName else { return nil }
        return TranscriptChunkMerger.buildResult(
            from: mergedSegments,
            language: language,
            suggestedFilename: suggestedFilename,
            modelName: modelName
        )
    }
}

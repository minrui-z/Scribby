import AVFoundation
import Foundation

@MainActor
final class SwiftWhisperProvider: TranscriptionProvider {
    var onEvent: ((ProviderEvent) -> Void)?

    private var snapshot = ProviderSnapshot.empty
    private var workerTask: Task<Void, Never>?
    private let modelPreset: WhisperModelPreset
    private var info = ProviderInfo(
        engine: "swiftwhisper",
        model: WhisperModelPreset.default.displayName,
        device: "native-swift",
        supportsHardStop: false,
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
        workerTask?.cancel()
        workerTask = nil
    }

    func getInfo() async throws -> ProviderInfo {
        syncInfo()
        return info
    }

    func subscribeEvents() async throws {}

    func verifyToken(_ token: String) async throws -> TokenVerificationResult {
        try await PythonEnvironmentManager.shared.ensureReady(for: .diarization) { _ in }
        return try await Self.verifyHuggingFaceToken(token)
    }

    func enqueue(paths: [String]) async throws -> ProviderSnapshot {
        let newItems = try paths.map(Self.makeQueueItem)
        snapshot.items.append(contentsOf: newItems)
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
        return snapshot
    }

    func startTranscription(_ request: TranscriptionRequest) async throws -> ProviderSnapshot {
        guard !snapshot.isProcessing else {
            throw unsupported("純 Swift 核心版正在轉譯中")
        }

        if request.diarize && request.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw unsupported("已開啟語者辨識，請先輸入並驗證 HuggingFace Token")
        }

        let pendingIndex = snapshot.items.firstIndex { $0.status == "pending" || $0.status == "error" }
        guard pendingIndex != nil else {
            throw unsupported("目前沒有可轉譯的檔案")
        }

        snapshot.isProcessing = true
        snapshot.isPaused = false
        snapshot.stopRequested = false
        syncInfo()
        onEvent?(.queueUpdated(snapshot))

        workerTask?.cancel()
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.processPending(request: request)
        }
        return snapshot
    }

    func setPaused(_ paused: Bool) async throws -> ProviderSnapshot {
        throw unsupported("純 Swift 核心版第一階段不支援暫停")
    }

    func stopCurrent() async throws -> StopRequestResult {
        throw unsupported("純 Swift 核心版第一階段不支援停止")
    }

    func clearQueue() async throws -> ProviderSnapshot {
        guard !snapshot.isProcessing else {
            throw unsupported("轉譯中無法清除序列")
        }
        snapshot = .empty
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
        return snapshot
    }

    func removeQueueItem(fileId: String) async throws -> ProviderSnapshot {
        guard let index = snapshot.items.firstIndex(where: { $0.fileId == fileId }) else {
            return snapshot
        }
        if snapshot.items[index].status == "processing" || snapshot.currentFileId == fileId {
            throw unsupported("轉譯中的檔案無法刪除")
        }
        snapshot.items.remove(at: index)
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
        return snapshot
    }

    func saveResult(fileId: String, destinationPath: String) async throws {
        guard let item = snapshot.items.first(where: { $0.fileId == fileId }),
              let result = item.result else {
            throw unsupported("找不到可儲存的逐字稿")
        }
        let body = formattedTranscriptText(for: item.filename, result: result)
        try body.write(to: URL(fileURLWithPath: destinationPath), atomically: true, encoding: .utf8)
    }

    func saveAllResults(fileIds: [String], destinationPath: String) async throws {
        throw unsupported("純 Swift 核心版第一階段不支援全部匯出")
    }

    private func processPending(request: TranscriptionRequest) async {
        while let index = snapshot.items.firstIndex(where: { $0.status == "pending" }) {
            let item = snapshot.items[index]

            // Determine active phases for this task
            var activePhases: [ProcessingPhase] = []
            if request.enhance { activePhases.append(.enhancing) }
            activePhases.append(.transcribing)
            if request.diarize { activePhases.append(.diarizing) }

            let initialPhase: ProcessingPhase = request.enhance ? .enhancing : .transcribing
            let progressMessage = initialPhase.label + "..."

            updateProcessingState(for: index, message: progressMessage, phase: initialPhase, activePhases: activePhases)
            onEvent?(.taskStarted(fileId: item.fileId, filename: item.filename))
            onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: initialPhase, activePhases: activePhases))
            onEvent?(.taskProgress(fileId: item.fileId, message: progressMessage, progress: 5))
            onEvent?(.queueUpdated(snapshot))

            var enhancedTempURL: URL?


            do {
                // Ensure Python environment is ready for required features
                if request.enhance {
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
                }
                if request.diarize {
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
                }

                let audioPath: String
                if request.enhance {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("wav")
                    enhancedTempURL = tempURL

                    // Python outputs 16kHz mono PCM WAV directly
                    try await Self.runSpeechEnhancement(
                        filePath: item.id,
                        outputPath: tempURL.path,
                        log: { [weak self] line in
                            Task { @MainActor in
                                guard let self else { return }
                                self.onEvent?(.taskLog(fileId: item.fileId, message: line))
                                self.onEvent?(.taskProgress(fileId: item.fileId, message: line, progress: nil))
                            }
                        },
                        downloadProgress: { [weak self] filename, downloaded, total in
                            Task { @MainActor in
                                guard let self else { return }
                                let info = Self.makeDownloadProgress(filename: filename, downloaded: downloaded, total: total)
                                self.onEvent?(.taskDownloadProgress(fileId: item.fileId, info: info))
                            }
                        }
                    )
                    audioPath = tempURL.path

                    // Transition to transcribing phase
                    snapshot.items[index].message = "正在使用 SwiftWhisper 轉寫..."
                    snapshot.items[index].progress = 15
                    snapshot.items[index].phase = .transcribing
                    snapshot.items[index].downloadProgress = nil
                    syncInfo()
                    onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: .transcribing, activePhases: activePhases))
                    onEvent?(.taskProgress(fileId: item.fileId, message: "正在使用 SwiftWhisper 轉寫...", progress: 15))
                    onEvent?(.queueUpdated(snapshot))
                } else {
                    // Pass the original file directly — headless has its own
                    // fallback chain: AVFoundation → direct WAV parse → ffmpeg.
                    audioPath = item.id
                }

                let result = try await Self.runHeadless(
                    filePath: audioPath,
                    language: request.language,
                    diarize: false,
                    modelPreset: modelPreset,
                    event: { [weak self] streamEvent in
                        Task { @MainActor in
                            guard let self else { return }
                            self.handleStreamEvent(streamEvent, itemIndex: index, fileId: item.fileId)
                        }
                    },
                    log: { [weak self] line in
                        Task { @MainActor in
                            guard let self else { return }
                            self.onEvent?(.taskLog(fileId: item.fileId, message: line))
                            self.onEvent?(.taskProgress(fileId: item.fileId, message: line, progress: nil))
                        }
                    },
                    downloadProgress: { [weak self] filename, downloaded, total in
                        Task { @MainActor in
                            guard let self else { return }
                            let info = Self.makeDownloadProgress(filename: filename, downloaded: downloaded, total: total)
                            // Insert downloading phase if not already present
                            if !self.snapshot.items[index].activePhases.contains(.downloading) {
                                self.snapshot.items[index].activePhases.insert(.downloading, at: 0)
                            }
                            self.snapshot.items[index].phase = .downloading
                            self.onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: .downloading, activePhases: self.snapshot.items[index].activePhases))
                            self.onEvent?(.taskDownloadProgress(fileId: item.fileId, info: info))
                        }
                    }
                )
                let finalResult: HeadlessResult
                if request.diarize {
                    updatePyannoteState(for: index, activePhases: activePhases)
                    onEvent?(.taskPhaseChanged(fileId: item.fileId, phase: .diarizing, activePhases: activePhases))
                    onEvent?(.taskProgress(fileId: item.fileId, message: "正在使用 pyannote 進行多語者辨識...", progress: 70))
                    onEvent?(.queueUpdated(snapshot))

                    let diarizedSegments = try await Self.runPyannoteDiarization(
                        filePath: audioPath,
                        token: request.token,
                        speakers: request.speakers,
                        segments: result.segments,
                        log: { [weak self] line in
                            Task { @MainActor in
                                guard let self else { return }
                                self.onEvent?(.taskLog(fileId: item.fileId, message: line))
                            }
                        }
                    )
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
                applyResult(finalResult, to: index, diarizeRequested: request.diarize, usedPyannote: request.diarize)
                onEvent?(.taskCompleted(fileId: item.fileId, filename: item.filename, result: snapshot.items[index].result!))
                onEvent?(.queueUpdated(snapshot))
            } catch {
                applyFailure(error, to: index)
                onEvent?(.taskFailed(fileId: item.fileId, message: error.localizedDescription))
                onEvent?(.queueUpdated(snapshot))
            }

            if let tempURL = enhancedTempURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        snapshot.isProcessing = false
        snapshot.currentFileId = nil
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
    }

    private func updateProcessingState(for index: Int, message: String, phase: ProcessingPhase? = nil, activePhases: [ProcessingPhase] = []) {
        for itemIndex in snapshot.items.indices {
            if itemIndex == index {
                snapshot.items[itemIndex].status = "processing"
                snapshot.items[itemIndex].message = message
                snapshot.items[itemIndex].progress = 5
                snapshot.items[itemIndex].phase = phase
                snapshot.items[itemIndex].activePhases = activePhases
                snapshot.items[itemIndex].downloadProgress = nil
                snapshot.currentFileId = snapshot.items[itemIndex].fileId
            } else if snapshot.items[itemIndex].status == "processing" {
                snapshot.items[itemIndex].status = "pending"
                snapshot.items[itemIndex].message = ""
                snapshot.items[itemIndex].progress = 0
                snapshot.items[itemIndex].phase = nil
                snapshot.items[itemIndex].activePhases = []
                snapshot.items[itemIndex].downloadProgress = nil
            }
        }
        snapshot.isProcessing = true
        syncInfo()
    }

    private func updatePyannoteState(for index: Int, activePhases: [ProcessingPhase] = []) {
        snapshot.items[index].status = "processing"
        snapshot.items[index].message = "正在使用 pyannote 進行多語者辨識..."
        snapshot.items[index].progress = 70
        snapshot.items[index].phase = .diarizing
        snapshot.items[index].activePhases = activePhases
        snapshot.items[index].downloadProgress = nil
        syncInfo()
    }

    private static func makeDownloadProgress(filename: String, downloaded: Int64, total: Int64) -> DownloadProgress {
        DownloadProgress(
            filename: filename,
            bytesDownloaded: downloaded,
            totalBytes: total,
            bytesPerSecond: 0
        )
    }

    private func applyResult(_ result: HeadlessResult, to index: Int, diarizeRequested: Bool, usedPyannote: Bool) {
        let mappedSegments = result.segments.map {
            TranscriptSegment(
                startTimeMs: $0.startTimeMs,
                endTimeMs: $0.endTimeMs,
                text: $0.text,
                speakerLabel: $0.speakerLabel
            )
        }
        let hasSpeakers = mappedSegments.contains { $0.speakerLabel != nil }

        snapshot.items[index].status = "done"
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
        syncInfo()
    }

    private func handlePipProgress(_ info: PipDownloadInfo, fileId: String, itemIndex: Int, activePhases: [ProcessingPhase]) {
        guard itemIndex < snapshot.items.count else { return }

        // Show download phase in segmented bar
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

    private func handleStreamEvent(_ event: HeadlessStreamEvent, itemIndex: Int, fileId: String) {
        // Ignore stale events if we've already moved past the transcribing phase
        guard itemIndex < snapshot.items.count,
              snapshot.items[itemIndex].phase == .transcribing || snapshot.items[itemIndex].phase == nil
        else { return }

        switch event {
        case .progress(let progress):
            let percentage = Int((progress * 100.0).rounded())
            snapshot.items[itemIndex].progress = max(snapshot.items[itemIndex].progress, min(percentage, 96))
            snapshot.items[itemIndex].message = "正在使用 SwiftWhisper 轉寫..."
            syncInfo()
            onEvent?(.taskProgress(fileId: fileId, message: "正在使用 SwiftWhisper 轉寫...", progress: percentage))
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

    private func applyFailure(_ error: Error, to index: Int) {
        snapshot.items[index].status = "error"
        snapshot.items[index].progress = 0
        snapshot.items[index].message = ""
        snapshot.items[index].error = error.localizedDescription
        snapshot.items[index].result = nil
        syncInfo()
    }

    private func syncInfo() {
        info.snapshot = snapshot
    }

    private func unsupported(_ message: String) -> Error {
        NSError(
            domain: "SwiftWhisperProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
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

    private static func makeQueueItem(path: String) throws -> QueueItemModel {
        let url = URL(fileURLWithPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attributes?[.size] as? NSNumber
        let fileId = UUID().uuidString
        return QueueItemModel(
            id: path,
            fileId: fileId,
            filename: url.lastPathComponent,
            size: size?.int64Value ?? 0,
            status: "pending",
            progress: 0,
            message: "",
            error: nil,
            result: nil
        )
    }

    private static func runHeadless(
        filePath: String,
        language: String,
        diarize: Bool,
        modelPreset: WhisperModelPreset,
        event: @escaping @Sendable (HeadlessStreamEvent) -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in },
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }
    ) async throws -> HeadlessResult {
        // Download CoreML encoder if needed (async, with progress)
        let modelDir = try PathResolver.swiftWhisperModelDirectory()
        try await syncCoreMLAssetsIfAvailable(for: modelPreset, into: modelDir, downloadProgress: downloadProgress)

        return try await Task.detached(priority: .userInitiated) {
            let executable = try PathResolver.swiftWhisperExecutable()

            let process = Process()
            process.executableURL = executable
            process.arguments = diarize ? [filePath, language, "--diarize"] : [filePath, language]

            var environment = ProcessInfo.processInfo.environment
            environment["SCRIBBY_SWIFTWHISPER_MODEL_DIR"] = modelDir.path
            environment["SCRIBBY_SWIFTWHISPER_MODEL_PRESET"] = modelPreset.rawValue
            environment["SCRIBBY_SWIFTWHISPER_MODEL_FILENAME"] = modelPreset.filename
            environment["SCRIBBY_SWIFTWHISPER_MODEL_URL"] = modelPreset.remoteURL
            if let ffmpeg = PathResolver.ffmpegBinary() {
                environment["SCRIBBY_FFMPEG"] = ffmpeg.path
            }
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stdoutHandle = stdout.fileHandleForReading
            let streamCollector = StreamCollector()

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines = streamCollector.append(data)

                let decoder = JSONDecoder()
                for line in lines {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let lineData = line.data(using: .utf8) else { continue }
                    if let envelope = try? decoder.decode(HeadlessStreamEnvelope.self, from: lineData),
                       let streamEvent = envelope.toEvent() {
                        switch streamEvent {
                        case .completed(let result):
                            streamCollector.setCompletedResult(result)
                        default:
                            break
                        }
                        event(streamEvent)
                    }
                }
            }

            let collectedStderr = StderrCollector()
            let stderrHandle = stderr.fileHandleForReading
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                collectedStderr.append(text)
                for line in text.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let dl = Self.parseDownloadLine(trimmed) {
                        downloadProgress(dl.0, dl.1, dl.2)
                    } else if trimmed.contains("downloading model") {
                        log("正在下載模型...")
                    } else if trimmed.contains("model ready") || trimmed.contains("model stored") {
                        log("模型已就緒")
                    } else if trimmed.contains("ensuring model") {
                        log("正在準備模型...")
                    } else {
                        log(trimmed)
                    }
                }
            }

            try process.run()
            process.waitUntilExit()
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            let remainingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
            if !remainingStdout.isEmpty {
                let lines = streamCollector.appendFinal(remainingStdout)
                let decoder = JSONDecoder()
                for line in lines {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let lineData = line.data(using: .utf8) else { continue }
                    if let envelope = try? decoder.decode(HeadlessStreamEnvelope.self, from: lineData),
                       let streamEvent = envelope.toEvent() {
                        switch streamEvent {
                        case .completed(let result):
                            streamCollector.setCompletedResult(result)
                        default:
                            break
                        }
                        event(streamEvent)
                    }
                }
            }

            guard process.terminationStatus == 0 else {
                let errText = collectedStderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = errText.isEmpty ? "SwiftWhisper 轉譯失敗" : errText
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }

            guard let completedResult = streamCollector.completedResult() else {
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "SwiftWhisper 沒有回傳最終結果"]
                )
            }
            return completedResult
        }.value
    }

    // MARK: - CoreML Encoder Auto-Download

    private static func syncCoreMLAssetsIfAvailable(
        for modelPreset: WhisperModelPreset,
        into modelDir: URL,
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void
    ) async throws {
        let fileManager = FileManager.default

        let modelcName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc")
        let destinationModelc = modelDir.appendingPathComponent(modelcName, isDirectory: true)
        let partialDestination = modelDir.appendingPathComponent(modelcName + ".downloading", isDirectory: true)

        // Clean up incomplete downloads from previous crash
        if fileManager.fileExists(atPath: partialDestination.path) {
            try? fileManager.removeItem(at: partialDestination)
        }

        // 1. Already exists locally
        if fileManager.fileExists(atPath: destinationModelc.path) { return }

        // 2. Bundle / dev path
        if let source = PathResolver.swiftWhisperCoreMLCompiledModel(named: modelcName) {
            try? fileManager.removeItem(at: destinationModelc)
            try fileManager.copyItem(at: source, to: destinationModelc)
            return
        }

        // 3. .mlpackage fallback from bundle / dev path
        let packageName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlpackage")
        let destinationPackage = modelDir.appendingPathComponent(packageName, isDirectory: true)
        if fileManager.fileExists(atPath: destinationPackage.path) { return }
        if let source = PathResolver.swiftWhisperCoreMLPackage(named: packageName) {
            try? fileManager.removeItem(at: destinationPackage)
            try fileManager.copyItem(at: source, to: destinationPackage)
            return
        }

        // 4. Download .mlmodelc.zip from HuggingFace
        guard let remoteURL = modelPreset.coreMLEncoderRemoteURL else { return }

        let zipFilename = "\(modelcName).zip"
        let tempZip = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")

        try await downloadFile(from: remoteURL, to: tempZip, progressHandler: { downloaded, total in
            downloadProgress(zipFilename, downloaded, total)
        })

        defer { try? fileManager.removeItem(at: tempZip) }

        // Unzip
        let tempExtract = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempExtract, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempExtract) }

        try await Task.detached {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", tempZip.path, "-d", tempExtract.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: Int(unzip.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "CoreML encoder 解壓失敗"]
                )
            }
        }.value

        let extracted = tempExtract.appendingPathComponent(modelcName, isDirectory: true)
        if fileManager.fileExists(atPath: extracted.path) {
            // Move to .downloading first, then rename — atomic guarantee
            try? fileManager.removeItem(at: partialDestination)
            try fileManager.moveItem(at: extracted, to: partialDestination)
            try? fileManager.removeItem(at: destinationModelc)
            try fileManager.moveItem(at: partialDestination, to: destinationModelc)
        }
    }

    // MARK: - Generic Download Helper

    private static func downloadFile(
        from url: URL,
        to destination: URL,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = FileDownloadDelegate(
                destination: destination,
                progressHandler: progressHandler,
                continuation: continuation
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: - Stderr Download Line Parser

    nonisolated private static func parseDownloadLine(_ line: String) -> (String, Int64, Int64)? {
        // Format: [DOWNLOAD] <filename> <downloaded> <total>
        // Also handles: [swiftwhisper] [DOWNLOAD] <filename> <downloaded> <total>
        let trimmed: String
        if line.hasPrefix("[swiftwhisper] [DOWNLOAD] ") {
            trimmed = String(line.dropFirst("[swiftwhisper] [DOWNLOAD] ".count))
        } else if line.hasPrefix("[DOWNLOAD] ") {
            trimmed = String(line.dropFirst("[DOWNLOAD] ".count))
        } else {
            return nil
        }
        let parts = trimmed.split(separator: " ")
        guard parts.count >= 3,
              let downloaded = Int64(parts[parts.count - 2]),
              let total = Int64(parts[parts.count - 1]) else { return nil }
        let filename = parts[0..<(parts.count - 2)].joined(separator: " ")
        return (filename, downloaded, total)
    }

    // MARK: - Speech Enhancement

    private static func runSpeechEnhancement(
        filePath: String,
        outputPath: String,
        log: @escaping @Sendable (String) -> Void,
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }
    ) async throws {
        // MLX only works on Apple Silicon
        #if !arch(arm64)
        throw NSError(
            domain: "SwiftWhisperProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "人聲加強功能需要 Apple Silicon（M1 以上）"]
        )
        #endif

        try await Task.detached(priority: .userInitiated) {
            let python = try PathResolver.pythonExecutable()
            let helper = try PathResolver.enhancementHelperScript()

            let process = Process()
            process.executableURL = python
            process.arguments = [helper.path, "enhance", filePath, outputPath]
            process.environment = try PathResolver.backendEnvironment()

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let collectedStderr = StderrCollector()
            let stderrHandle = stderr.fileHandleForReading
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                collectedStderr.append(text)
                for line in text.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let dl = parseDownloadLine(trimmed) {
                        downloadProgress(dl.0, dl.1, dl.2)
                    } else {
                        log(trimmed)
                    }
                }
            }

            try process.run()
            process.waitUntilExit()
            stderrHandle.readabilityHandler = nil

            guard process.terminationStatus == 0 else {
                let errText = collectedStderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "人聲加強失敗（exit code \(process.terminationStatus)）" : errText]
                )
            }
        }.value
    }

    private static func verifyHuggingFaceToken(_ token: String) async throws -> TokenVerificationResult {
        try await Task.detached(priority: .userInitiated) {
            let python = try PathResolver.pythonExecutable()
            let helper = try PathResolver.diarizationHelperScript()

            let process = Process()
            process.executableURL = python
            process.arguments = [helper.path, "verify-token", token]
            process.environment = try PathResolver.backendEnvironment()

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: stderrText.isEmpty ? "Token 驗證失敗" : stderrText]
                )
            }

            if stdoutData.isEmpty {
                return TokenVerificationResult(ok: true, message: "Token 驗證完成")
            }

            let decoded = try JSONDecoder().decode(TokenVerificationResult.self, from: stdoutData)
            return decoded
        }.value
    }

    /// Convert any audio file to 16kHz mono 16-bit PCM WAV using AVFoundation (no ffmpeg needed).
    private static func convertToWAV(inputPath: String, outputPath: String) async throws {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outputURL)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.convertWithAVAsset(inputURL: inputURL, outputURL: outputURL) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func convertWithAVAsset(inputURL: URL, outputURL: URL, completion: @escaping (Error?) -> Void) {
        let asset = AVURLAsset(url: inputURL)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            completion(NSError(domain: "SwiftWhisperProvider", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "無法讀取音訊檔案"]))
            return
        }

        guard let track = asset.tracks(withMediaType: .audio).first else {
            completion(NSError(domain: "SwiftWhisperProvider", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "音訊檔案沒有音軌"]))
            return
        }

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(readerOutput)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .wav) else {
            completion(NSError(domain: "SwiftWhisperProvider", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "無法建立 WAV 寫入器"]))
            return
        }

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writer.add(writerInput)

        reader.startReading()

        // Check if reader actually started
        guard reader.status == .reading else {
            let desc = reader.error?.localizedDescription ?? "未知錯誤"
            completion(NSError(domain: "SwiftWhisperProvider", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "無法讀取音訊：\(desc)"]))
            return
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "wav-convert")) {
            while writerInput.isReadyForMoreMediaData {
                // Check reader status before calling copyNextSampleBuffer
                // to avoid ObjC exception crash when reader is in failed/cancelled state
                guard reader.status == .reading else {
                    writerInput.markAsFinished()
                    if reader.status == .failed {
                        writer.cancelWriting()
                        let desc = reader.error?.localizedDescription ?? "音訊讀取失敗"
                        completion(NSError(domain: "SwiftWhisperProvider", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: desc]))
                    } else {
                        writer.finishWriting {
                            completion(writer.error)
                        }
                    }
                    return
                }

                if let buffer = readerOutput.copyNextSampleBuffer() {
                    writerInput.append(buffer)
                } else {
                    writerInput.markAsFinished()
                    writer.finishWriting {
                        completion(writer.error)
                    }
                    return
                }
            }
        }
    }

    private static func runPyannoteDiarization(
        filePath: String,
        token: String,
        speakers: Int,
        segments: [HeadlessSegment],
        log: @escaping @Sendable (String) -> Void
    ) async throws -> [HeadlessSegment] {
        // Convert audio to WAV using AVFoundation (no ffmpeg needed)
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        log("正在將音訊轉換為 WAV 格式...")
        try await convertToWAV(inputPath: filePath, outputPath: wavURL.path)

        return try await Task.detached(priority: .userInitiated) {
            let python = try PathResolver.pythonExecutable()
            let helper = try PathResolver.diarizationHelperScript()

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("json")

            let segmentPayload = DatasetsPayload(
                segments: segments.map {
                    DatasetsSegment(
                        start: Double($0.startTimeMs) / 1000.0,
                        end: Double($0.endTimeMs) / 1000.0,
                        text: $0.text
                    )
                }
            )

            do {
                let data = try JSONEncoder().encode(segmentPayload)
                try data.write(to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                let process = Process()
                process.executableURL = python
                // Pass --wav flag so Python script reads WAV directly without ffmpeg
                var args = [helper.path, "diarize", wavURL.path, token, tempURL.path, "--wav"]
                if speakers > 0 {
                    args.append(String(speakers))
                }
                process.arguments = args
                process.environment = try PathResolver.backendEnvironment()

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                let collectedStderr = StderrCollector()
                let stderrHandle = stderr.fileHandleForReading
                stderrHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let text = String(decoding: data, as: UTF8.self)
                    collectedStderr.append(text)
                    for line in text.split(whereSeparator: \.isNewline) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            log(trimmed)
                        }
                    }
                }

                try process.run()
                process.waitUntilExit()
                stderrHandle.readabilityHandler = nil

                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()

                guard process.terminationStatus == 0 else {
                    let errText = collectedStderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw NSError(
                        domain: "SwiftWhisperProvider",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "pyannote diarization 失敗" : errText]
                    )
                }

                let decoded = try JSONDecoder().decode(PyannoteResult.self, from: stdoutData)
                return decoded.segments
            } catch {
                throw error
            }
        }.value
    }
}

/// Thread-safe collector for stderr output so error messages survive readabilityHandler consumption.
private final class StderrCollector: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    func append(_ text: String) {
        lock.lock()
        buffer += text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

private enum HeadlessStreamEvent {
    case progress(Double)
    case partial([HeadlessSegment])
    case completed(HeadlessResult)
    case failed(String)
}

private struct HeadlessStreamEnvelope: Codable {
    let kind: String
    let progress: Double?
    let segments: [HeadlessSegment]?
    let result: HeadlessResult?
    let message: String?

    func toEvent() -> HeadlessStreamEvent? {
        switch kind {
        case "progress":
            guard let progress else { return nil }
            return .progress(progress)
        case "partial_segments":
            return .partial(segments ?? [])
        case "completed":
            guard let result else { return nil }
            return .completed(result)
        case "failed":
            return .failed(message ?? "SwiftWhisper 失敗")
        default:
            return nil
        }
    }
}

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var result: HeadlessResult?

    func append(_ data: Data) -> [String] {
        lock.withLock {
            buffer.append(data)
            return consumeLines(includePartial: false)
        }
    }

    func appendFinal(_ data: Data) -> [String] {
        lock.withLock {
            buffer.append(data)
            return consumeLines(includePartial: true)
        }
    }

    func setCompletedResult(_ result: HeadlessResult) {
        lock.withLock {
            self.result = result
        }
    }

    func completedResult() -> HeadlessResult? {
        lock.withLock { result }
    }

    private func consumeLines(includePartial: Bool) -> [String] {
        var lines: [String] = []
        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
            buffer.removeSubrange(0...newlineRange.lowerBound)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        if includePartial, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        return lines
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private struct HeadlessSegment: Codable {
    let startTimeMs: Int
    let endTimeMs: Int
    let text: String
    let speakerLabel: String?
}

private struct HeadlessResult: Codable {
    let text: String
    let language: String
    let count: Int
    let suggestedFilename: String
    let segments: [HeadlessSegment]
    let modelName: String
}

private struct DatasetsPayload: Codable {
    let segments: [DatasetsSegment]
}

private struct DatasetsSegment: Codable {
    let start: Double
    let end: Double
    let text: String
}

private struct PyannoteResult: Codable {
    let segments: [HeadlessSegment]
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progressHandler: (Int64, Int64) -> Void
    private let continuation: CheckedContinuation<Void, Error>
    private var resumed = false
    private var lastReportTime: TimeInterval = 0

    init(destination: URL, progressHandler: @escaping (Int64, Int64) -> Void, continuation: CheckedContinuation<Void, Error>) {
        self.destination = destination
        self.progressHandler = progressHandler
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReportTime >= 0.3 else { return }
        lastReportTime = now
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        progressHandler(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !resumed else { return }
        resumed = true
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.resume()
        } catch {
            continuation.resume(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !resumed else { return }
        resumed = true
        if let error {
            continuation.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation.resume(throwing: NSError(
                domain: "SwiftWhisperProvider",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "下載失敗 HTTP \(http.statusCode)"]
            ))
        }
        session.finishTasksAndInvalidate()
    }
}

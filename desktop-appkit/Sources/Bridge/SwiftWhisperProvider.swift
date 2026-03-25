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
        while let index = snapshot.items.firstIndex(where: { $0.status == "pending" || $0.status == "error" }) {
            let item = snapshot.items[index]
            let progressMessage = request.diarize
                ? "正在使用 SwiftWhisper 轉寫，稍後交給 pyannote 做多語者辨識..."
                : "正在使用 SwiftWhisper 轉寫..."
            updateProcessingState(for: index, message: progressMessage)
            onEvent?(.taskStarted(fileId: item.fileId, filename: item.filename))
            onEvent?(.taskProgress(fileId: item.fileId, message: progressMessage, progress: nil))
            onEvent?(.queueUpdated(snapshot))

            do {
                let result = try await Self.runHeadless(
                    filePath: item.id,
                    language: request.language,
                    diarize: false,
                    modelPreset: modelPreset,
                    event: { [weak self] streamEvent in
                        Task { @MainActor in
                            guard let self else { return }
                            self.handleStreamEvent(streamEvent, itemIndex: index, fileId: item.fileId)
                        }
                    }
                )
                let finalResult: HeadlessResult
                if request.diarize {
                    updatePyannoteState(for: index)
                    onEvent?(.taskProgress(fileId: item.fileId, message: "正在使用 pyannote 進行多語者辨識...", progress: 70))
                    onEvent?(.queueUpdated(snapshot))

                    let diarizedSegments = try await Self.runPyannoteDiarization(
                        filePath: item.id,
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
        }

        snapshot.isProcessing = false
        snapshot.currentFileId = nil
        syncInfo()
        onEvent?(.queueUpdated(snapshot))
    }

    private func updateProcessingState(for index: Int, message: String) {
        for itemIndex in snapshot.items.indices {
            if itemIndex == index {
                snapshot.items[itemIndex].status = "processing"
                snapshot.items[itemIndex].message = message
                snapshot.items[itemIndex].progress = 15
                snapshot.currentFileId = snapshot.items[itemIndex].fileId
            } else if snapshot.items[itemIndex].status == "processing" {
                snapshot.items[itemIndex].status = "pending"
                snapshot.items[itemIndex].message = ""
                snapshot.items[itemIndex].progress = 0
            }
        }
        snapshot.isProcessing = true
        syncInfo()
    }

    private func updatePyannoteState(for index: Int) {
        snapshot.items[index].status = "processing"
        snapshot.items[index].message = "正在使用 pyannote 進行多語者辨識..."
        snapshot.items[index].progress = 70
        syncInfo()
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

    private func handleStreamEvent(_ event: HeadlessStreamEvent, itemIndex: Int, fileId: String) {
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
        event: @escaping @Sendable (HeadlessStreamEvent) -> Void
    ) async throws -> HeadlessResult {
        try await Task.detached(priority: .userInitiated) {
            let executable = try PathResolver.swiftWhisperExecutable()
            let modelDir = try PathResolver.swiftWhisperModelDirectory()
            try syncCoreMLAssetsIfAvailable(for: modelPreset, into: modelDir)

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

            try process.run()
            process.waitUntilExit()
            stdoutHandle.readabilityHandler = nil

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
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                let message = stderrText.isEmpty ? "SwiftWhisper 轉譯失敗" : stderrText
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

    nonisolated private static func syncCoreMLAssetsIfAvailable(for modelPreset: WhisperModelPreset, into modelDir: URL) throws {
        let fileManager = FileManager.default
        let packageName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlpackage")

        guard let sourcePackage = PathResolver.swiftWhisperCoreMLPackage(named: packageName) else {
            return
        }

        let destinationPackage = modelDir.appendingPathComponent(packageName, isDirectory: true)
        if fileManager.fileExists(atPath: destinationPackage.path) {
            return
        }

        try? fileManager.removeItem(at: destinationPackage)
        try fileManager.copyItem(at: sourcePackage, to: destinationPackage)
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

    private static func runPyannoteDiarization(
        filePath: String,
        token: String,
        speakers: Int,
        segments: [HeadlessSegment],
        log: @escaping @Sendable (String) -> Void
    ) async throws -> [HeadlessSegment] {
        try await Task.detached(priority: .userInitiated) {
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
                var args = [helper.path, "diarize", filePath, token, tempURL.path]
                if speakers > 0 {
                    args.append(String(speakers))
                }
                process.arguments = args
                process.environment = try PathResolver.backendEnvironment()

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                let stderrHandle = stderr.fileHandleForReading
                stderrHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let text = String(decoding: data, as: UTF8.self)
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
                let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard process.terminationStatus == 0 else {
                    throw NSError(
                        domain: "SwiftWhisperProvider",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: stderrText.isEmpty ? "pyannote diarization 失敗" : stderrText]
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

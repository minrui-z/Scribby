import AVFoundation
import Foundation

private enum CoreMLExecutionMode: String, Equatable {
    case disabled
    case cpuAndGpu = "cpu_and_gpu"
    case cpuAndNe = "cpu_and_ne"

    var usesCoreML: Bool {
        self != .disabled
    }

    var environmentValue: String? {
        switch self {
        case .disabled:
            return nil
        case .cpuAndGpu:
            return "cpu_and_gpu"
        case .cpuAndNe:
            return "cpu_and_ne"
        }
    }

    var displayName: String {
        switch self {
        case .disabled:
            return "CPU-only"
        case .cpuAndGpu:
            return "CPU_AND_GPU"
        case .cpuAndNe:
            return "CPU_AND_NE"
        }
    }

    var loadTimeout: TimeInterval {
        switch self {
        case .disabled:
            return 0
        case .cpuAndGpu:
            return 20
        case .cpuAndNe:
            return 240
        }
    }
}

enum TranscriptionPipelineRunner {
    private static let coreMLStallErrorCode = 70_001

    static func prepareWhisperAssets(
        modelPreset: WhisperModelPreset,
        log: @escaping @Sendable (String) -> Void = { _ in },
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }
    ) async throws {
        let fileManager = FileManager.default
        let modelDir = try PathResolver.swiftWhisperModelDirectory()
        let modelURL = modelDir.appendingPathComponent(modelPreset.filename, isDirectory: false)

        if fileManager.fileExists(atPath: modelURL.path) {
            log("Whisper 模型已就緒")
        } else {
            log("正在下載 Whisper 模型...")
            let tempModel = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fileManager.removeItem(at: tempModel) }

            try await downloadFile(
                from: URL(string: modelPreset.remoteURL)!,
                to: tempModel,
                progressHandler: { downloaded, total in
                    downloadProgress(modelPreset.filename, downloaded, total)
                }
            )

            guard let attributes = try? fileManager.attributesOfItem(atPath: tempModel.path),
                  let size = attributes[.size] as? Int64,
                  size >= 1_000_000 else {
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: 73_201,
                    userInfo: [NSLocalizedDescriptionKey: "Whisper 模型下載後檔案大小異常"]
                )
            }

            try? fileManager.removeItem(at: modelURL)
            try fileManager.moveItem(at: tempModel, to: modelURL)
            log("Whisper 模型已就緒")
        }

        guard modelPreset.coreMLEncoderProvisioning != .none else { return }

        log("正在準備 Core ML encoder...")
        _ = try await prepareCoreMLAssetsIfAvailable(
            for: modelPreset,
            into: modelDir,
            preferredMode: preferredCoreMLExecutionMode(for: modelPreset),
            log: log,
            downloadProgress: downloadProgress
        )
        log("Core ML encoder 已就緒")
    }

    static func prepareProofreadingAssets(
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        let python = try PathResolver.pythonExecutable()
        let helper = try PathResolver.proofreadingHelperScript()
        let cacheDir = try await ModelCatalog.shared.llmModelCacheDirectory()

        let process = Process()
        process.executableURL = python
        process.arguments = [helper.path, "--warmup"]

        var env = try PathResolver.backendEnvironment()
        env["SCRIBBY_MLX_MODEL_CACHE"] = cacheDir.path
        process.environment = env

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
                log(trimmed)
            }
        }

        try process.run()
        process.waitUntilExit()
        stderrHandle.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let errText = collectedStderr.tail(maxLines: 20)
            throw NSError(
                domain: "SwiftWhisperProvider",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errText.isEmpty
                    ? "AI 校稿模型準備失敗（exit \(process.terminationStatus)）"
                    : errText]
            )
        }
    }

    static func runChunkedHeadless(
        filePath: String,
        language: String,
        modelPreset: WhisperModelPreset,
        processSupervisor: ProcessSupervisor,
        event: @escaping @Sendable (HeadlessStreamEvent) -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in },
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }
    ) async throws -> HeadlessResult {
        let normalizedURL = try await AudioChunker.normalizeForASR(
            inputPath: filePath,
            processSupervisor: processSupervisor,
            log: log
        )
        defer { Task { await processSupervisor.cleanupTemporaryFile(normalizedURL) } }

        let chunks = try await AudioChunker.createChunks(
            from: normalizedURL,
            processSupervisor: processSupervisor,
            log: log
        )

        var chunkResults: [ChunkTranscription] = []
        chunkResults.reserveCapacity(chunks.count)

        for chunk in chunks {
            try Task.checkCancellation()
            log("正在轉寫第 \(chunk.index + 1) / \(chunk.total) 段...")

            let result = try await runHeadless(
                filePath: chunk.url.path,
                language: language,
                diarize: false,
                modelPreset: modelPreset,
                processSupervisor: processSupervisor,
                event: { streamEvent in
                    switch streamEvent {
                    case .progress(let progress):
                        let overall = (Double(chunk.index) + progress) / Double(max(chunk.total, 1))
                        event(.progress(overall))
                    case .partial(let segments):
                        event(.partial(segments))
                    case .completed:
                        break
                    case .failed(let message):
                        event(.failed(message))
                    }
                },
                log: log,
                downloadProgress: downloadProgress
            )

            chunkResults.append(ChunkTranscription(chunk: chunk, result: result))
            log("chunk \(chunk.index + 1) / \(chunk.total) 完成，segments=\(result.segments.count)")
        }

        let merged = try TranscriptChunkMerger.merge(chunkResults)
        log("chunk 合併完成：\(chunkResults.count) 段 -> \(merged.segments.count) segments")
        event(.completed(merged))
        return merged
    }

    static func runHeadless(
        filePath: String,
        language: String,
        diarize: Bool,
        modelPreset: WhisperModelPreset,
        processSupervisor: ProcessSupervisor,
        event: @escaping @Sendable (HeadlessStreamEvent) -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in },
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }
    ) async throws -> HeadlessResult {
        let modelDir = try PathResolver.swiftWhisperModelDirectory()
        let supportsCoreML = modelPreset.coreMLRuntimeEnabled && modelPreset.coreMLEncoderProvisioning != .none
        let sessionRegistry = CoreMLEncoderSessionRegistry.shared
        let coreMLDisabledForSession = sessionRegistry.isDisabled(modelPreset)
        let coreMLMode: CoreMLExecutionMode

        if supportsCoreML && !sessionRegistry.isDisabled(modelPreset) {
            let preferredMode = preferredCoreMLExecutionMode(for: modelPreset)
            let requestedMode: CoreMLExecutionMode
            if preferredMode == .cpuAndNe && sessionRegistry.isNeDisabled(modelPreset) {
                requestedMode = .cpuAndGpu
            } else {
                requestedMode = preferredMode
            }

            let preparedMode = try await prepareCoreMLAssetsIfAvailable(
                for: modelPreset,
                into: modelDir,
                preferredMode: requestedMode,
                log: log,
                downloadProgress: downloadProgress
            )
            if requestedMode == .cpuAndNe && preparedMode == .cpuAndGpu {
                sessionRegistry.disableNe(modelPreset)
            }
            coreMLMode = preparedMode
        } else if supportsCoreML && coreMLDisabledForSession {
            log("已停用 \(modelPreset.rawValue) Core ML encoder，改走 CPU-only fallback")
            try purgeCoreMLAssets(for: modelPreset, into: modelDir, log: log)
            coreMLMode = .disabled
        } else {
            if modelPreset.coreMLEncoderProvisioning != .none && !modelPreset.coreMLRuntimeEnabled {
                log("已暫時停用 \(modelPreset.rawValue) Core ML runtime：目前 encoder 資產會導致轉寫內容異常，改走 CPU-only")
            }
            coreMLMode = .disabled
        }

        do {
            return try await runHeadlessProcess(
                filePath: filePath,
                language: language,
                diarize: diarize,
                modelPreset: modelPreset,
                modelDir: modelDir,
                processSupervisor: processSupervisor,
                event: event,
                log: log,
                downloadProgress: downloadProgress,
                coreMLMode: coreMLMode
            )
        } catch let error as NSError
        where error.domain == "SwiftWhisperProvider"
            && error.code == coreMLStallErrorCode
            && coreMLMode.usesCoreML {
            if coreMLMode == .cpuAndNe {
                log("偵測到 \(modelPreset.rawValue) 的 CPU_AND_NE Core ML 載入逾時，改走 CPU_AND_GPU fallback")
                sessionRegistry.disableNe(modelPreset)
                return try await runHeadlessProcess(
                    filePath: filePath,
                    language: language,
                    diarize: diarize,
                    modelPreset: modelPreset,
                    modelDir: modelDir,
                    processSupervisor: processSupervisor,
                    event: event,
                    log: log,
                    downloadProgress: downloadProgress,
                    coreMLMode: .cpuAndGpu
                )
            }

            log("偵測到 \(modelPreset.rawValue) 的 CPU_AND_GPU Core ML 載入逾時，清除 encoder 快取並改走 CPU-only fallback")
            sessionRegistry.disable(modelPreset)
            try purgeCoreMLAssets(for: modelPreset, into: modelDir, log: log)
            return try await runHeadlessProcess(
                filePath: filePath,
                language: language,
                diarize: diarize,
                modelPreset: modelPreset,
                modelDir: modelDir,
                processSupervisor: processSupervisor,
                event: event,
                log: log,
                downloadProgress: downloadProgress,
                coreMLMode: .disabled
            )
        }
    }

    private static func runHeadlessProcess(
        filePath: String,
        language: String,
        diarize: Bool,
        modelPreset: WhisperModelPreset,
        modelDir: URL,
        processSupervisor: ProcessSupervisor,
        event: @escaping @Sendable (HeadlessStreamEvent) -> Void,
        log: @escaping @Sendable (String) -> Void = { _ in },
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void = { _, _, _ in },
        coreMLMode: CoreMLExecutionMode
    ) async throws -> HeadlessResult {
        return try await Task.detached(priority: .userInitiated) {
            let executable = try PathResolver.swiftWhisperExecutable()
            log("headless 啟動：preset=\(modelPreset.rawValue) language=\(language) diarize=\(diarize) coreMLMode=\(coreMLMode.rawValue) file=\((filePath as NSString).lastPathComponent)")

            let process = Process()
            process.executableURL = executable
            var arguments = [filePath, language]
            if diarize {
                arguments.append("--diarize")
            }
            if !coreMLMode.usesCoreML {
                arguments.append("--no-coreml")
            }
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            environment["SCRIBBY_SWIFTWHISPER_MODEL_DIR"] = modelDir.path
            environment["SCRIBBY_SWIFTWHISPER_MODEL_PRESET"] = modelPreset.rawValue
            environment["SCRIBBY_SWIFTWHISPER_MODEL_FILENAME"] = modelPreset.filename
            environment["SCRIBBY_SWIFTWHISPER_MODEL_URL"] = modelPreset.remoteURL
            if let computeUnits = coreMLMode.environmentValue {
                environment["SCRIBBY_COREML_COMPUTE_UNITS"] = computeUnits
            } else {
                environment.removeValue(forKey: "SCRIBBY_COREML_COMPUTE_UNITS")
            }
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
            let stdoutEOF = EOFWaiter()
            let stderrEOF = EOFWaiter()
            let executionState = HeadlessExecutionState()

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    stdoutEOF.signal()
                    return
                }
                let lines = streamCollector.append(data)

                let decoder = JSONDecoder()
                for line in lines {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let lineData = line.data(using: .utf8) else { continue }
                    if let envelope = try? decoder.decode(HeadlessStreamEnvelope.self, from: lineData),
                       let streamEvent = envelope.toEvent() {
                        executionState.stopCoreMLWatchdog()
                        if case .completed(let result) = streamEvent {
                            streamCollector.setCompletedResult(result)
                        }
                        event(streamEvent)
                    }
                }
            }

            let collectedStderr = StderrCollector()
            let stderrHandle = stderr.fileHandleForReading
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    stderrEOF.signal()
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                collectedStderr.append(text)
                for line in text.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let dl = parseDownloadLine(trimmed) {
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
                    executionState.noteCoreMLLogLine(trimmed)
                }
            }

            try process.run()
            await processSupervisor.register(pid: process.processIdentifier, for: .headless)
            if coreMLMode.usesCoreML {
                DispatchQueue.global(qos: .userInitiated).async {
                    while !executionState.isProcessFinished() {
                        Thread.sleep(forTimeInterval: 1)
                        guard executionState.shouldTriggerCoreMLTimeout(after: coreMLMode.loadTimeout) else { continue }
                        let error = NSError(
                            domain: "SwiftWhisperProvider",
                            code: coreMLStallErrorCode,
                            userInfo: [NSLocalizedDescriptionKey: "\(modelPreset.displayName) 的 \(coreMLMode.displayName) Core ML encoder 載入逾時，已停止本次嘗試"]
                        )
                        guard executionState.setCoreMLStallErrorIfNeeded(error) else { return }
                        log("偵測到 \(coreMLMode.displayName) Core ML encoder 載入逾時（\(Int(coreMLMode.loadTimeout)) 秒），正在中止 headless process")
                        process.interrupt()
                        Thread.sleep(forTimeInterval: 0.5)
                        if process.isRunning {
                            process.terminate()
                        }
                        for _ in 0..<10 {
                            if !process.isRunning { return }
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                        return
                    }
                }
            }
            process.waitUntilExit()
            executionState.markProcessFinished()
            await processSupervisor.clear(.headless, matching: process.processIdentifier)
            log("headless 結束：exit=\(process.terminationStatus) file=\((filePath as NSString).lastPathComponent)")

            // Wait for EOF on both pipes — ensures all in-flight
            // readabilityHandler callbacks have finished processing
            // before we check completedResult.
            await stdoutEOF.wait()
            await stderrEOF.wait()
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            // Process any data remaining in the StreamCollector buffer
            // (partial line without trailing newline)
            let finalLines = streamCollector.drainBuffer()
            if !finalLines.isEmpty {
                let decoder = JSONDecoder()
                for line in finalLines {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let lineData = line.data(using: .utf8) else { continue }
                    if let envelope = try? decoder.decode(HeadlessStreamEnvelope.self, from: lineData),
                       let streamEvent = envelope.toEvent() {
                        if case .completed(let result) = streamEvent {
                            streamCollector.setCompletedResult(result)
                        }
                        event(streamEvent)
                    }
                }
            }

            if let stallError = executionState.coreMLStallError() {
                throw stallError
            }

            guard process.terminationStatus == 0 else {
                let errText = collectedStderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = errText.isEmpty ? "SwiftWhisper 轉譯失敗" : errText
                log("headless 失敗：\(message)")
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }

            guard let completedResult = streamCollector.completedResult() else {
                let stderrTail = collectedStderr.tail(maxLines: 20)
                let stdoutTail = streamCollector.tail(maxLines: 20)
                log("headless 缺少最終結果：exit=0 file=\((filePath as NSString).lastPathComponent)")
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: """
                    SwiftWhisper 沒有回傳最終結果（exit=0）
                    stderr:
                    \(stderrTail.isEmpty ? "（空）" : stderrTail)
                    stdout:
                    \(stdoutTail.isEmpty ? "（空）" : stdoutTail)
                    """]
                )
            }
            return completedResult
        }.value
    }

    static func runSpeechEnhancement(
        filePath: String,
        outputPath: String,
        processSupervisor: ProcessSupervisor,
        log: @escaping @Sendable (String) -> Void,
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void = { _, _, _ in }
    ) async throws {
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
            await processSupervisor.register(pid: process.processIdentifier, for: .enhancement)
            process.waitUntilExit()
            await processSupervisor.clear(.enhancement, matching: process.processIdentifier)
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

    static func verifyHuggingFaceToken(_ token: String) async throws -> TokenVerificationResult {
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

            return try JSONDecoder().decode(TokenVerificationResult.self, from: stdoutData)
        }.value
    }

    static func runPyannoteDiarization(
        filePath: String,
        token: String,
        speakers: Int,
        segments: [HeadlessSegment],
        processSupervisor: ProcessSupervisor,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> [HeadlessSegment] {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        await processSupervisor.trackTemporaryFile(wavURL)
        defer { Task { await processSupervisor.cleanupTemporaryFile(wavURL) } }

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
                await processSupervisor.trackTemporaryFile(tempURL)
                let data = try JSONEncoder().encode(segmentPayload)
                try data.write(to: tempURL)
                defer { Task { await processSupervisor.cleanupTemporaryFile(tempURL) } }

                let process = Process()
                process.executableURL = python
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
                await processSupervisor.register(pid: process.processIdentifier, for: .diarization)
                process.waitUntilExit()
                await processSupervisor.clear(.diarization, matching: process.processIdentifier)
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

    static func runProofreading(
        result: HeadlessResult,
        mode: ProofreadingMode,
        processSupervisor: ProcessSupervisor,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (ProofreadProgress) -> Void = { _ in },
        streamedText: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> HeadlessResult {
        guard mode != .off else { return result }

        #if !arch(arm64)
        throw NSError(
            domain: "SwiftWhisperProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "AI 校稿功能需要 Apple Silicon（M1 以上）"]
        )
        #endif

        return try await Task.detached(priority: .userInitiated) {
            let python = try PathResolver.pythonExecutable()
            let helper = try PathResolver.proofreadingHelperScript()
            let cacheDir = try await ModelCatalog.shared.llmModelCacheDirectory()
            let proofreadingLanguage = resolvedProofreadingLanguage(for: result)
            log("AI 校稿語言：\(proofreadingLanguage)（原始=\(result.language)）")

            let payload = ProofreadingPayload(
                segments: result.segments,
                mode: mode.rawValue,
                language: proofreadingLanguage
            )
            let inputData = try JSONEncoder().encode(payload)

            let process = Process()
            process.executableURL = python
            process.arguments = [helper.path]

            var env = try PathResolver.backendEnvironment()
            env["SCRIBBY_MLX_MODEL_CACHE"] = cacheDir.path
            process.environment = env

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
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
                    if let proofreadProgress = parseProofreadProgressLine(trimmed) {
                        progress(proofreadProgress)
                    } else if let proofreadText = parseProofreadTextLine(trimmed) {
                        streamedText(proofreadText)
                    }
                    log(trimmed)
                }
            }

            try process.run()
            await processSupervisor.register(pid: process.processIdentifier, for: .proofreading)

            stdin.fileHandleForWriting.write(inputData)
            stdin.fileHandleForWriting.closeFile()

            process.waitUntilExit()
            await processSupervisor.clear(.proofreading, matching: process.processIdentifier)
            stderrHandle.readabilityHandler = nil

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()

            guard process.terminationStatus == 0 else {
                let errText = collectedStderr.tail(maxLines: 20)
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errText.isEmpty
                        ? "AI 校稿失敗（exit \(process.terminationStatus)）"
                        : errText]
                )
            }

            let proofreadResult = try JSONDecoder().decode(ProofreadingResult.self, from: stdoutData)

            let correctedSegments = zip(result.segments, proofreadResult.segments).map { original, corrected in
                HeadlessSegment(
                    startTimeMs: original.startTimeMs,
                    endTimeMs: original.endTimeMs,
                    text: corrected.text,
                    speakerLabel: original.speakerLabel
                )
            }
            let correctedText = correctedSegments.map(\.text).joined(separator: "\n")

            return HeadlessResult(
                text: correctedText,
                language: proofreadingLanguage,
                count: result.count,
                suggestedFilename: result.suggestedFilename,
                segments: correctedSegments,
                modelName: result.modelName
            )
        }.value
    }

    private static func resolvedProofreadingLanguage(for result: HeadlessResult) -> String {
        let normalized = normalizeLanguageCode(result.language)
        if normalized != "auto" {
            return normalized
        }
        return inferLanguageCode(from: result.segments) ?? "auto"
    }

    private static func normalizeLanguageCode(_ code: String) -> String {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        guard !normalized.isEmpty else { return "auto" }
        if normalized == "auto" { return "auto" }

        if normalized.hasPrefix("zh") { return "zh" }
        if normalized.hasPrefix("ja") { return "ja" }
        if normalized.hasPrefix("ko") { return "ko" }
        if normalized.hasPrefix("en") { return "en" }
        if normalized.hasPrefix("es") { return "es" }
        if normalized.hasPrefix("fr") { return "fr" }
        if normalized.hasPrefix("de") { return "de" }
        if normalized.hasPrefix("pt") { return "pt" }
        if normalized.hasPrefix("it") { return "it" }
        if normalized.hasPrefix("ru") { return "ru" }
        if normalized.hasPrefix("ar") { return "ar" }
        if normalized.hasPrefix("th") { return "th" }
        if normalized.hasPrefix("vi") { return "vi" }
        if normalized.hasPrefix("id") { return "id" }
        if normalized.hasPrefix("ms") { return "ms" }
        return normalized
    }

    private static func inferLanguageCode(from segments: [HeadlessSegment]) -> String? {
        let sample = segments
            .prefix(20)
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sample.isEmpty else { return nil }

        var cjkCount = 0
        var kanaCount = 0
        var hangulCount = 0
        var arabicCount = 0
        var thaiCount = 0
        var cyrillicCount = 0
        var latinCount = 0

        for scalar in sample.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                cjkCount += 1
            case 0x3040...0x309F, 0x30A0...0x30FF:
                kanaCount += 1
            case 0xAC00...0xD7AF:
                hangulCount += 1
            case 0x0600...0x06FF:
                arabicCount += 1
            case 0x0E00...0x0E7F:
                thaiCount += 1
            case 0x0400...0x04FF:
                cyrillicCount += 1
            case 0x0041...0x005A, 0x0061...0x007A,
                 0x00C0...0x00D6, 0x00D8...0x00F6, 0x00F8...0x024F:
                latinCount += 1
            default:
                break
            }
        }

        if kanaCount > 0 { return "ja" }
        if hangulCount > 0 { return "ko" }
        if arabicCount > 0 { return "ar" }
        if thaiCount > 0 { return "th" }
        if cyrillicCount > 0 { return "ru" }
        if cjkCount > 0 { return "zh" }

        guard latinCount > 0 else { return nil }

        let lowercased = sample.lowercased()
        if lowercased.contains(where: { "¿¡ñáéíóúü".contains($0) }) { return "es" }
        if lowercased.contains("ß") || lowercased.contains(where: { "äöü".contains($0) }) { return "de" }
        if lowercased.contains(where: { "àâæçéèêëîïôœùûüÿ".contains($0) }) { return "fr" }
        if lowercased.contains(where: { "ãõ".contains($0) }) { return "pt" }
        if lowercased.contains(where: { "àèéìíîòóù".contains($0) }) { return "it" }
        return "en"
    }

    private static func prepareCoreMLAssetsIfAvailable(
        for modelPreset: WhisperModelPreset,
        into modelDir: URL,
        preferredMode: CoreMLExecutionMode,
        log: @escaping @Sendable (String) -> Void,
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void
    ) async throws -> CoreMLExecutionMode {
        let fileManager = FileManager.default

        let modelcName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc")
        let destinationModelc = modelDir.appendingPathComponent(modelcName, isDirectory: true)
        if fileManager.fileExists(atPath: destinationModelc.path) {
            return try await selectValidatedCoreMLMode(
                at: destinationModelc,
                for: modelPreset,
                preferredMode: preferredMode,
                log: log
            )
        }

        if let source = PathResolver.swiftWhisperCoreMLCompiledModel(named: modelcName) {
            try? fileManager.removeItem(at: destinationModelc)
            try fileManager.copyItem(at: source, to: destinationModelc)
            log("[coreml-package] 使用現有 Core ML encoder：\(modelcName)")
            return try await selectValidatedCoreMLMode(
                at: destinationModelc,
                for: modelPreset,
                preferredMode: preferredMode,
                log: log
            )
        }

        let packageName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlpackage")
        let destinationPackage = modelDir.appendingPathComponent(packageName, isDirectory: true)
        if fileManager.fileExists(atPath: destinationPackage.path) {
            log("[coreml-package] 使用現有 encoder package：\(packageName)")
            log("[coreml-compile] 正在編譯 Core ML encoder...")
            try compileCoreMLPackage(at: destinationPackage, into: destinationModelc)
            return try await selectValidatedCoreMLMode(
                at: destinationModelc,
                for: modelPreset,
                preferredMode: preferredMode,
                log: log
            )
        }
        if let source = PathResolver.swiftWhisperCoreMLPackage(named: packageName) {
            try? fileManager.removeItem(at: destinationPackage)
            try fileManager.copyItem(at: source, to: destinationPackage)
            log("[coreml-package] 找到本機 Core ML encoder package：\(packageName)")
            log("[coreml-compile] 正在編譯 Core ML encoder...")
            try compileCoreMLPackage(at: destinationPackage, into: destinationModelc)
            return try await selectValidatedCoreMLMode(
                at: destinationModelc,
                for: modelPreset,
                preferredMode: preferredMode,
                log: log
            )
        }

        switch modelPreset.coreMLEncoderProvisioning {
        case .none:
            return .disabled
        case .compiledArchive:
            guard let remoteURL = modelPreset.remoteCompiledCoreMLArchiveURL else { return .disabled }
            let partialDestination = modelDir.appendingPathComponent(modelcName + ".downloading", isDirectory: true)
            if fileManager.fileExists(atPath: partialDestination.path) {
                try? fileManager.removeItem(at: partialDestination)
            }

            let zipFilename = "\(modelcName).zip"
            let tempZip = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("zip")

            try await downloadFile(from: remoteURL, to: tempZip, progressHandler: { downloaded, total in
                downloadProgress(zipFilename, downloaded, total)
            })

            defer { try? fileManager.removeItem(at: tempZip) }

            let tempExtract = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempExtract, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempExtract) }

            try await Task.detached {
                try extractZipArchive(at: tempZip, to: tempExtract, errorContext: "CoreML encoder 解壓失敗")
            }.value

            let extracted = tempExtract.appendingPathComponent(modelcName, isDirectory: true)
            if fileManager.fileExists(atPath: extracted.path) {
                try? fileManager.removeItem(at: partialDestination)
                try fileManager.moveItem(at: extracted, to: partialDestination)
                try? fileManager.removeItem(at: destinationModelc)
                try fileManager.moveItem(at: partialDestination, to: destinationModelc)
                return try await selectValidatedCoreMLMode(
                    at: destinationModelc,
                    for: modelPreset,
                    preferredMode: preferredMode,
                    log: log
                )
            }
            return .disabled
        case .packageFirst:
            guard let remoteURL = modelPreset.remoteCoreMLPackageArchiveURL else {
                log("[coreml-package] \(modelPreset.rawValue) 目前沒有可下載的 Core ML encoder package，改走 CPU-only")
                return .disabled
            }

            let zipFilename = "\(packageName).zip"
            let tempZip = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("zip")

            log("[coreml-package] 正在下載 encoder package...")
            try await downloadFile(from: remoteURL, to: tempZip, progressHandler: { downloaded, total in
                downloadProgress(zipFilename, downloaded, total)
            })

            defer { try? fileManager.removeItem(at: tempZip) }

            let tempExtract = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: tempExtract, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempExtract) }

            try await Task.detached {
                try extractZipArchive(at: tempZip, to: tempExtract, errorContext: "CoreML encoder package 解壓失敗")
            }.value

            let extracted = tempExtract.appendingPathComponent(packageName, isDirectory: true)
            guard fileManager.fileExists(atPath: extracted.path) else {
                log("[coreml-package] 找不到解壓後的 encoder package，改走 CPU-only")
                return .disabled
            }

            try? fileManager.removeItem(at: destinationPackage)
            try fileManager.moveItem(at: extracted, to: destinationPackage)
            log("[coreml-compile] 正在編譯 Core ML encoder...")
            try compileCoreMLPackage(at: destinationPackage, into: destinationModelc)
            return try await selectValidatedCoreMLMode(
                at: destinationModelc,
                for: modelPreset,
                preferredMode: preferredMode,
                log: log
            )
        }
    }

    private static func selectValidatedCoreMLMode(
        at modelcURL: URL,
        for modelPreset: WhisperModelPreset,
        preferredMode: CoreMLExecutionMode,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> CoreMLExecutionMode {
        guard preferredMode.usesCoreML else { return .disabled }

        if try await validatePreparedCoreMLModel(
            at: modelcURL,
            for: modelPreset,
            mode: preferredMode,
            log: log
        ) {
            return preferredMode
        }

        if preferredMode == .cpuAndNe {
            CoreMLEncoderSessionRegistry.shared.disableNe(modelPreset)
            log("[coreml-load] CPU_AND_NE 驗證未通過，改試 CPU_AND_GPU")
            if try await validatePreparedCoreMLModel(
                at: modelcURL,
                for: modelPreset,
                mode: .cpuAndGpu,
                log: log
            ) {
                return .cpuAndGpu
            }
        }

        CoreMLEncoderSessionRegistry.shared.disable(modelPreset)
        return .disabled
    }

    private static func validatePreparedCoreMLModel(
        at modelcURL: URL,
        for modelPreset: WhisperModelPreset,
        mode: CoreMLExecutionMode,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> Bool {
        guard mode.usesCoreML else { return false }
        if CoreMLEncoderSessionRegistry.shared.isValidated(modelPreset, mode: mode) {
            return true
        }

        let loadStart = Date()
        log("[coreml-load] 正在驗證 \(mode.displayName) Core ML encoder 載入...")

        do {
            try await validateCoreMLModelLoad(
                at: modelcURL,
                timeout: mode.loadTimeout,
                computeUnits: mode
            )
            let duration = Date().timeIntervalSince(loadStart)
            log(String(format: "[coreml-load] %@ 載入驗證成功（%.1f 秒）", mode.displayName, duration))
            CoreMLEncoderSessionRegistry.shared.markValidated(modelPreset, mode: mode)
            return true
        } catch {
            let duration = Date().timeIntervalSince(loadStart)
            log(String(format: "[coreml-load] %@ 載入驗證失敗（%.1f 秒）：%@", mode.displayName, duration, error.localizedDescription))
            try purgeCoreMLAssets(for: modelPreset, into: modelcURL.deletingLastPathComponent(), log: log)
            CoreMLEncoderSessionRegistry.shared.clearValidation(modelPreset, mode: mode)
            return false
        }
    }

    private static func compileCoreMLPackage(at packageURL: URL, into destinationModelc: URL) throws {
        let outputDirectory = destinationModelc.deletingLastPathComponent()
        let compiledName = packageURL.deletingPathExtension().lastPathComponent + ".mlmodelc"
        let compiledURL = outputDirectory.appendingPathComponent(compiledName, isDirectory: true)
        let compilerURL = try PathResolver.coreMLCompilerExecutable()
        try? FileManager.default.removeItem(at: compiledURL)
        try? FileManager.default.removeItem(at: destinationModelc)

        let compile = Process()
        compile.executableURL = compilerURL
        compile.arguments = ["compile", packageURL.path, outputDirectory.path]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            throw NSError(
                domain: "SwiftWhisperProvider",
                code: Int(compile.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Core ML encoder 編譯失敗"]
            )
        }

        guard FileManager.default.fileExists(atPath: compiledURL.path) else {
            throw NSError(
                domain: "SwiftWhisperProvider",
                code: 73_001,
                userInfo: [NSLocalizedDescriptionKey: "Core ML encoder 編譯後找不到輸出檔"]
            )
        }
        try FileManager.default.moveItem(at: compiledURL, to: destinationModelc)
    }

    private static func extractZipArchive(at zipURL: URL, to destinationDirectory: URL, errorContext: String) throws {
        let tryCommands: [(URL, [String])] = [
            (URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zipURL.path, destinationDirectory.path]),
            (URL(fileURLWithPath: "/usr/bin/unzip"), ["-o", zipURL.path, "-d", destinationDirectory.path]),
        ]

        var failureMessages: [String] = []

        for (executableURL, arguments) in tryCommands {
            guard FileManager.default.fileExists(atPath: executableURL.path) else { continue }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice

            let stderr = Pipe()
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                failureMessages.append("\(executableURL.lastPathComponent): \(error.localizedDescription)")
                continue
            }

            if process.terminationStatus == 0 {
                return
            }

            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderrText?.isEmpty == false
                ? stderrText!
                : "exit \(process.terminationStatus)"
            failureMessages.append("\(executableURL.lastPathComponent): \(message)")
        }

        throw NSError(
            domain: "SwiftWhisperProvider",
            code: 73_101,
            userInfo: [NSLocalizedDescriptionKey: "\(errorContext)（\(failureMessages.joined(separator: " | "))）"]
        )
    }

    private static func validateCoreMLModelLoad(
        at modelcURL: URL,
        timeout: TimeInterval,
        computeUnits: CoreMLExecutionMode
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let diagnoseExecutable = try PathResolver.swiftWhisperCoreMLDiagnoseExecutable()

            let process = Process()
            process.executableURL = diagnoseExecutable
            process.arguments = [
                "--load-only",
                modelcURL.path,
                "--compute-units",
                computeUnits.rawValue
            ]

            let stderr = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr

            try process.run()

            DispatchQueue.global(qos: .userInitiated).async {
                Thread.sleep(forTimeInterval: timeout)
                guard process.isRunning else { return }
                process.interrupt()
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning {
                    process.terminate()
                }
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }

            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationReason == .uncaughtSignal {
                    throw NSError(
                        domain: "SwiftWhisperProvider",
                        code: coreMLStallErrorCode,
                        userInfo: [NSLocalizedDescriptionKey: "\(computeUnits.displayName) Core ML encoder 載入驗證逾時"]
                    )
                }

                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errorText?.isEmpty == false ? errorText! : "\(computeUnits.displayName) Core ML encoder 載入驗證失敗"]
                )
            }
        }.value
    }

    private static func preferredCoreMLExecutionMode(for modelPreset: WhisperModelPreset) -> CoreMLExecutionMode {
        switch modelPreset {
        case .tiny:
            return .disabled
        case .largeV3Turbo:
            return .cpuAndNe
        case .largeV3:
            return .cpuAndNe
        }
    }

    private static func purgeCoreMLAssets(
        for modelPreset: WhisperModelPreset,
        into modelDir: URL,
        removePackage: Bool = false,
        log: @escaping @Sendable (String) -> Void
    ) throws {
        let fileManager = FileManager.default
        let modelcName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc")
        let packageName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlpackage")
        let modelcURL = modelDir.appendingPathComponent(modelcName, isDirectory: true)
        let packageURL = modelDir.appendingPathComponent(packageName, isDirectory: true)

        if fileManager.fileExists(atPath: modelcURL.path) {
            try? fileManager.removeItem(at: modelcURL)
            log("已移除 encoder 快取：\(modelcName)")
            CoreMLEncoderSessionRegistry.shared.clearValidation(modelPreset)
        }
        if removePackage, fileManager.fileExists(atPath: packageURL.path) {
            try? fileManager.removeItem(at: packageURL)
            log("已移除 encoder 套件：\(packageName)")
        }
    }

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

    nonisolated private static func parseDownloadLine(_ line: String) -> (String, Int64, Int64)? {
        if let parsed = parsePrefixedDownloadLine(line, prefix: "[swiftwhisper] [DOWNLOAD] ") {
            return parsed
        }
        return parsePrefixedDownloadLine(line, prefix: "[DOWNLOAD] ")
    }

    nonisolated private static func parsePrefixedDownloadLine(_ line: String, prefix: String) -> (String, Int64, Int64)? {
        guard line.hasPrefix(prefix) else { return nil }
        let trimmed = String(line.dropFirst(prefix.count))
        let parts = trimmed.split(separator: " ")
        guard parts.count >= 3,
              let downloaded = Int64(parts[parts.count - 2]),
              let total = Int64(parts[parts.count - 1]) else { return nil }
        let filename = parts[0..<(parts.count - 2)].joined(separator: " ")
        return (filename, downloaded, total)
    }

    static func convertToWAV(inputPath: String, outputPath: String) async throws {
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outputURL)

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

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "SwiftWhisperProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "音訊檔案沒有音軌"])
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writer.add(writerInput)

        reader.startReading()

        guard reader.status == .reading else {
            let desc = reader.error?.localizedDescription ?? "未知錯誤"
            throw NSError(domain: "SwiftWhisperProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "無法讀取音訊：\(desc)"])
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ctx = UncheckedSendableBox((reader, writer, writerInput, readerOutput))
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "wav-convert")) {
                let (reader, writer, writerInput, readerOutput) = ctx.value
                while writerInput.isReadyForMoreMediaData {
                    guard reader.status == .reading else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            let desc = reader.error?.localizedDescription ?? "音訊讀取失敗"
                            continuation.resume(throwing: NSError(
                                domain: "SwiftWhisperProvider", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: desc]))
                        } else {
                            writer.finishWriting {
                                if let err = writer.error {
                                    continuation.resume(throwing: err)
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                        return
                    }

                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(buffer)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if let err = writer.error {
                                continuation.resume(throwing: err)
                            } else {
                                continuation.resume()
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}

enum ProofreadProgressPhase: String {
    case start
    case done
    case finished
}

struct ProofreadProgress {
    let currentBatch: Int
    let totalBatches: Int
    let phase: ProofreadProgressPhase
}

private func parseProofreadProgressLine(_ line: String) -> ProofreadProgress? {
    guard line.hasPrefix("PROOFREAD_PROGRESS ") else { return nil }
    let payload = line.dropFirst("PROOFREAD_PROGRESS ".count)
    var currentBatch: Int?
    var totalBatches: Int?
    var phase: ProofreadProgressPhase?

    for token in payload.split(separator: " ") {
        let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "current":
            currentBatch = Int(parts[1])
        case "total":
            totalBatches = Int(parts[1])
        case "phase":
            phase = ProofreadProgressPhase(rawValue: parts[1])
        default:
            break
        }
    }

    guard let currentBatch,
          let totalBatches,
          let phase else { return nil }
    return ProofreadProgress(currentBatch: currentBatch, totalBatches: totalBatches, phase: phase)
}

private func parseProofreadTextLine(_ line: String) -> String? {
    guard line.hasPrefix("PROOFREAD_TEXT ") else { return nil }
    let payload = line.dropFirst("PROOFREAD_TEXT ".count)
    guard let data = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = object["text"] as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

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

    func tail(maxLines: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let lines = buffer
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum HeadlessStreamEvent {
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
    private var history: [String] = []

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
            let line = String(decoding: lineData, as: UTF8.self)
            lines.append(line)
            history.append(line)
        }
        if includePartial, !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            lines.append(line)
            history.append(line)
            buffer.removeAll()
        }
        if history.count > 24 {
            history.removeFirst(history.count - 24)
        }
        return lines
    }

    /// Flush any partial line remaining in the buffer after EOF.
    func drainBuffer() -> [String] {
        lock.withLock {
            consumeLines(includePartial: true)
        }
    }

    func tail(maxLines: Int) -> String {
        lock.withLock {
            history.suffix(maxLines).joined(separator: "\n")
        }
    }
}

private final class EOFWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var didSignal = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        var pending: CheckedContinuation<Void, Never>?
        lock.lock()
        if didSignal {
            lock.unlock()
            return
        }
        didSignal = true
        pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        let alreadySignaled = lock.withLock { didSignal }
        if alreadySignaled { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didSignal {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private final class CoreMLEncoderSessionRegistry: @unchecked Sendable {
    static let shared = CoreMLEncoderSessionRegistry()

    private let lock = NSLock()
    private var disabledPresets: Set<String> = []
    private var neDisabledPresets: Set<String> = []
    private var validatedModes: [String: Set<String>] = [:]

    func isDisabled(_ preset: WhisperModelPreset) -> Bool {
        lock.withLock { disabledPresets.contains(preset.rawValue) }
    }

    func disable(_ preset: WhisperModelPreset) {
        lock.withLock {
            disabledPresets.insert(preset.rawValue)
            neDisabledPresets.insert(preset.rawValue)
            validatedModes.removeValue(forKey: preset.rawValue)
        }
    }

    func isNeDisabled(_ preset: WhisperModelPreset) -> Bool {
        lock.withLock { neDisabledPresets.contains(preset.rawValue) }
    }

    func disableNe(_ preset: WhisperModelPreset) {
        lock.withLock {
            neDisabledPresets.insert(preset.rawValue)
            validatedModes[preset.rawValue]?.remove(CoreMLExecutionMode.cpuAndNe.rawValue)
        }
    }

    func isValidated(_ preset: WhisperModelPreset, mode: CoreMLExecutionMode) -> Bool {
        lock.withLock { validatedModes[preset.rawValue]?.contains(mode.rawValue) == true }
    }

    func markValidated(_ preset: WhisperModelPreset, mode: CoreMLExecutionMode) {
        lock.withLock {
            disabledPresets.remove(preset.rawValue)
            validatedModes[preset.rawValue, default: []].insert(mode.rawValue)
            if mode == .cpuAndNe {
                neDisabledPresets.remove(preset.rawValue)
            }
        }
    }

    func clearValidation(_ preset: WhisperModelPreset, mode: CoreMLExecutionMode) {
        lock.withLock {
            validatedModes[preset.rawValue]?.remove(mode.rawValue)
            if validatedModes[preset.rawValue]?.isEmpty == true {
                validatedModes.removeValue(forKey: preset.rawValue)
            }
        }
    }

    func clearValidation(_ preset: WhisperModelPreset) {
        _ = lock.withLock {
            validatedModes.removeValue(forKey: preset.rawValue)
        }
    }
}

private final class HeadlessExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var coreMLLoading = false
    private var lastCoreMLActivityAt: Date?
    private var processFinished = false
    private var stallError: NSError?

    func noteCoreMLLogLine(_ line: String) {
        lock.withLock {
            if line.contains("loading Core ML model from") {
                coreMLLoading = true
                lastCoreMLActivityAt = Date()
                return
            }

            guard coreMLLoading else { return }

            lastCoreMLActivityAt = Date()
            if line.contains("whisper_full_with_state:") ||
                line.contains("auto-detected language") ||
                line.contains("completed event flushed") {
                coreMLLoading = false
                lastCoreMLActivityAt = nil
            }
        }
    }

    func stopCoreMLWatchdog() {
        lock.withLock {
            coreMLLoading = false
            lastCoreMLActivityAt = nil
        }
    }

    func shouldTriggerCoreMLTimeout(after timeout: TimeInterval) -> Bool {
        lock.withLock {
            guard coreMLLoading, let lastCoreMLActivityAt else { return false }
            return Date().timeIntervalSince(lastCoreMLActivityAt) >= timeout
        }
    }

    func setCoreMLStallErrorIfNeeded(_ error: NSError) -> Bool {
        lock.withLock {
            guard stallError == nil else { return false }
            stallError = error
            coreMLLoading = false
            lastCoreMLActivityAt = nil
            return true
        }
    }

    func coreMLStallError() -> NSError? {
        lock.withLock { stallError }
    }

    func markProcessFinished() {
        lock.withLock {
            processFinished = true
            coreMLLoading = false
            lastCoreMLActivityAt = nil
        }
    }

    func isProcessFinished() -> Bool {
        lock.withLock { processFinished }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

struct HeadlessSegment: Codable {
    let startTimeMs: Int
    let endTimeMs: Int
    let text: String
    let speakerLabel: String?
}

struct HeadlessResult: Codable {
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

private struct ProofreadingPayload: Codable {
    let segments: [HeadlessSegment]
    let mode: String
    let language: String
}

private struct ProofreadingResult: Codable {
    let segments: [ProofreadingSegment]
}

private struct ProofreadingSegment: Codable {
    let text: String
}

private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progressHandler: (Int64, Int64) -> Void
    private let continuation: CheckedContinuation<Void, Error>
    private let lock = NSLock()
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
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
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
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
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

import AVFoundation
import Foundation

enum TranscriptionPipelineRunner {
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
            processSupervisor: processSupervisor
        )
        defer { Task { await processSupervisor.cleanupTemporaryFile(normalizedURL) } }

        let chunks = try await AudioChunker.createChunks(
            from: normalizedURL,
            processSupervisor: processSupervisor
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
        }

        let merged = try TranscriptChunkMerger.merge(chunkResults)
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
                guard !data.isEmpty else { return }
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
                }
            }

            try process.run()
            await processSupervisor.register(pid: process.processIdentifier, for: .headless)
            process.waitUntilExit()
            await processSupervisor.clear(.headless, matching: process.processIdentifier)
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
                        if case .completed(let result) = streamEvent {
                            streamCollector.setCompletedResult(result)
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
                let stderrTail = collectedStderr.tail(maxLines: 8)
                let stdoutTail = streamCollector.tail(maxLines: 8)
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

    private static func syncCoreMLAssetsIfAvailable(
        for modelPreset: WhisperModelPreset,
        into modelDir: URL,
        downloadProgress: @escaping @Sendable (String, Int64, Int64) -> Void
    ) async throws {
        let fileManager = FileManager.default

        let modelcName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc")
        let destinationModelc = modelDir.appendingPathComponent(modelcName, isDirectory: true)
        let partialDestination = modelDir.appendingPathComponent(modelcName + ".downloading", isDirectory: true)

        if fileManager.fileExists(atPath: partialDestination.path) {
            try? fileManager.removeItem(at: partialDestination)
        }

        if fileManager.fileExists(atPath: destinationModelc.path) { return }

        if let source = PathResolver.swiftWhisperCoreMLCompiledModel(named: modelcName) {
            try? fileManager.removeItem(at: destinationModelc)
            try fileManager.copyItem(at: source, to: destinationModelc)
            return
        }

        let packageName = modelPreset.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlpackage")
        let destinationPackage = modelDir.appendingPathComponent(packageName, isDirectory: true)
        if fileManager.fileExists(atPath: destinationPackage.path) { return }
        if let source = PathResolver.swiftWhisperCoreMLPackage(named: packageName) {
            try? fileManager.removeItem(at: destinationPackage)
            try fileManager.copyItem(at: source, to: destinationPackage)
            return
        }

        guard let remoteURL = modelPreset.coreMLEncoderRemoteURL else { return }

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
            try? fileManager.removeItem(at: partialDestination)
            try fileManager.moveItem(at: extracted, to: partialDestination)
            try? fileManager.removeItem(at: destinationModelc)
            try fileManager.moveItem(at: partialDestination, to: destinationModelc)
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

    func tail(maxLines: Int) -> String {
        lock.withLock {
            history.suffix(maxLines).joined(separator: "\n")
        }
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

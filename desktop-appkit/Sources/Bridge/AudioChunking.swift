import AVFoundation
import Foundation

struct AudioChunk {
    let url: URL
    let index: Int
    let total: Int
    let actualStartSeconds: Double
    let actualEndSeconds: Double
    let nominalStartSeconds: Double
    let nominalEndSeconds: Double
}

struct PreparedChunkedTranscription {
    let normalizedAudioURL: URL
    let chunks: [AudioChunk]
}

enum AudioChunker {
    static let chunkDurationSeconds: Double = 120
    static let overlapSeconds: Double = 1.5
    static let targetSampleRate: Double = 16_000

    static func normalizeForASR(
        inputPath: String,
        processSupervisor: ProcessSupervisor,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> URL {
        let normalizedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        await processSupervisor.trackTemporaryFile(normalizedURL)
        do {
            try await TranscriptionPipelineRunner.convertToWAV(inputPath: inputPath, outputPath: normalizedURL.path)
            log("標準化完成：\(normalizedURL.lastPathComponent)（16kHz mono WAV）")
            return normalizedURL
        } catch {
            await processSupervisor.cleanupTemporaryFile(normalizedURL)
            throw error
        }
    }

    static func createChunks(
        from normalizedWav: URL,
        processSupervisor: ProcessSupervisor,
        chunkDurationSeconds: Double = chunkDurationSeconds,
        overlapSeconds: Double = overlapSeconds,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> [AudioChunk] {
        let sourceFile = try AVAudioFile(forReading: normalizedWav)
        let format = sourceFile.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFramePosition(sourceFile.length)
        let totalDurationSeconds = totalFrames > 0 ? Double(totalFrames) / sampleRate : 0

        guard totalDurationSeconds > 0 else {
            throw NSError(
                domain: "SwiftWhisperProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "標準化後的音訊檔為空"]
            )
        }

        var nominalRanges: [(start: Double, end: Double)] = []
        var cursor = 0.0
        while cursor < totalDurationSeconds {
            let end = min(cursor + chunkDurationSeconds, totalDurationSeconds)
            nominalRanges.append((start: cursor, end: end))
            cursor += chunkDurationSeconds
        }

        let total = nominalRanges.count
        var chunks: [AudioChunk] = []
        chunks.reserveCapacity(total)

        for (index, nominal) in nominalRanges.enumerated() {
            let actualStart = max(0, nominal.start - (index == 0 ? 0 : overlapSeconds))
            let actualEnd = min(totalDurationSeconds, nominal.end + (index == total - 1 ? 0 : overlapSeconds))
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")

            await processSupervisor.trackTemporaryFile(chunkURL)
            try writeChunk(
                from: sourceFile,
                to: chunkURL,
                format: format,
                sampleRate: sampleRate,
                actualStartSeconds: actualStart,
                actualEndSeconds: actualEnd
            )

            chunks.append(
                AudioChunk(
                    url: chunkURL,
                    index: index,
                    total: total,
                    actualStartSeconds: actualStart,
                    actualEndSeconds: actualEnd,
                    nominalStartSeconds: nominal.start,
                    nominalEndSeconds: nominal.end
                )
            )
            log("chunk \(index + 1)/\(total) nominal=\(formatTime(nominal.start))-\(formatTime(nominal.end)) actual=\(formatTime(actualStart))-\(formatTime(actualEnd))")
        }

        log("chunk 準備完成：總共 \(total) 段，chunk=\(Int(chunkDurationSeconds))s overlap=\(String(format: "%.1f", overlapSeconds))s")
        return chunks
    }

    static func prepareChunkedTranscription(
        inputPath: String,
        processSupervisor: ProcessSupervisor,
        chunkDurationSeconds: Double = chunkDurationSeconds,
        overlapSeconds: Double = overlapSeconds,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> PreparedChunkedTranscription {
        let normalizedAudioURL = try await normalizeForASR(
            inputPath: inputPath,
            processSupervisor: processSupervisor,
            log: log
        )
        let chunks = try await createChunks(
            from: normalizedAudioURL,
            processSupervisor: processSupervisor,
            chunkDurationSeconds: chunkDurationSeconds,
            overlapSeconds: overlapSeconds,
            log: log
        )
        return PreparedChunkedTranscription(normalizedAudioURL: normalizedAudioURL, chunks: chunks)
    }

    static let shorterFallbackChunkDurationSeconds: Double = 90

    private static func formatTime(_ seconds: Double) -> String {
        let totalMilliseconds = Int((seconds * 1000).rounded())
        let totalSeconds = max(totalMilliseconds / 1000, 0)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d.%03d", minutes, remainingSeconds, milliseconds)
    }

    private static func writeChunk(
        from sourceFile: AVAudioFile,
        to destinationURL: URL,
        format: AVAudioFormat,
        sampleRate: Double,
        actualStartSeconds: Double,
        actualEndSeconds: Double
    ) throws {
        let startFrame = max(0, AVAudioFramePosition((actualStartSeconds * sampleRate).rounded(.down)))
        let endFrame = max(startFrame, AVAudioFramePosition((actualEndSeconds * sampleRate).rounded(.up)))
        let frameCount = AVAudioFrameCount(endFrame - startFrame)

        guard frameCount > 0 else {
            throw NSError(
                domain: "SwiftWhisperProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "切段後的音訊長度為零"]
            )
        }

        sourceFile.framePosition = startFrame
        let destination = try AVAudioFile(forWriting: destinationURL, settings: format.settings)
        let bufferCapacity = min(frameCount, AVAudioFrameCount(65_536))

        while sourceFile.framePosition < endFrame {
            let remaining = AVAudioFrameCount(endFrame - sourceFile.framePosition)
            let readFrames = min(remaining, bufferCapacity)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else {
                throw NSError(
                    domain: "SwiftWhisperProvider",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "無法建立切段 buffer"]
                )
            }
            try sourceFile.read(into: buffer, frameCount: readFrames)
            if buffer.frameLength == 0 { break }
            try destination.write(from: buffer)
        }
    }
}

struct ChunkTranscription {
    let chunk: AudioChunk
    let result: HeadlessResult
}

enum TranscriptChunkMerger {
    static func merge(_ chunkResults: [ChunkTranscription]) throws -> HeadlessResult {
        guard let first = chunkResults.first else {
            throw NSError(
                domain: "SwiftWhisperProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "沒有可合併的 chunk 結果"]
            )
        }

        var mergedSegments: [HeadlessSegment] = []

        for entry in chunkResults.sorted(by: { $0.chunk.index < $1.chunk.index }) {
            for segment in shiftedSegments(for: entry) {
                if let last = mergedSegments.last, shouldCollapse(last: last, next: segment) {
                    let replacement = mergedSegment(last: last, next: segment)
                    mergedSegments[mergedSegments.count - 1] = replacement
                } else {
                    mergedSegments.append(segment)
                }
            }
        }

        let mergedText = mergedSegments
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HeadlessResult(
            text: mergedText,
            language: first.result.language,
            count: mergedSegments.count,
            suggestedFilename: first.result.suggestedFilename,
            segments: mergedSegments,
            modelName: first.result.modelName
        )
    }

    static func append(
        existing: [HeadlessSegment],
        chunkResult: ChunkTranscription
    ) -> [HeadlessSegment] {
        let shiftedSegments = shiftedSegments(for: chunkResult)
        var mergedSegments = existing
        for segment in shiftedSegments {
            if let last = mergedSegments.last, shouldCollapse(last: last, next: segment) {
                mergedSegments[mergedSegments.count - 1] = mergedSegment(last: last, next: segment)
            } else {
                mergedSegments.append(segment)
            }
        }
        return mergedSegments
    }

    static func buildResult(
        from segments: [HeadlessSegment],
        language: String,
        suggestedFilename: String,
        modelName: String
    ) -> HeadlessResult {
        let mergedText = segments
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return HeadlessResult(
            text: mergedText,
            language: language,
            count: segments.count,
            suggestedFilename: suggestedFilename,
            segments: segments,
            modelName: modelName
        )
    }

    private static func shiftedSegments(for entry: ChunkTranscription) -> [HeadlessSegment] {
        let chunk = entry.chunk
        let offsetMs = Int((chunk.actualStartSeconds * 1000.0).rounded())
        return entry.result.segments.compactMap { segment -> HeadlessSegment? in
            let shifted = HeadlessSegment(
                startTimeMs: segment.startTimeMs + offsetMs,
                endTimeMs: segment.endTimeMs + offsetMs,
                text: segment.text,
                speakerLabel: segment.speakerLabel
            )

            let midpointSeconds = Double(shifted.startTimeMs + shifted.endTimeMs) / 2000.0
            guard midpointSeconds >= chunk.nominalStartSeconds - 0.001,
                  midpointSeconds <= chunk.nominalEndSeconds + 0.001 else {
                return nil
            }
            return shifted
        }
    }

    private static func shouldCollapse(last: HeadlessSegment, next: HeadlessSegment) -> Bool {
        let overlapping = min(last.endTimeMs, next.endTimeMs) - max(last.startTimeMs, next.startTimeMs)
        guard overlapping >= 0 else { return false }
        let normalizedLast = normalize(last.text)
        let normalizedNext = normalize(next.text)
        guard !normalizedLast.isEmpty, !normalizedNext.isEmpty else { return false }
        return normalizedLast == normalizedNext
    }

    private static func mergedSegment(last: HeadlessSegment, next: HeadlessSegment) -> HeadlessSegment {
        let keepNext = next.text.count >= last.text.count || (next.endTimeMs - next.startTimeMs) >= (last.endTimeMs - last.startTimeMs)
        let preferred = keepNext ? next : last
        return HeadlessSegment(
            startTimeMs: min(last.startTimeMs, next.startTimeMs),
            endTimeMs: max(last.endTimeMs, next.endTimeMs),
            text: preferred.text,
            speakerLabel: preferred.speakerLabel ?? last.speakerLabel ?? next.speakerLabel
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }
}

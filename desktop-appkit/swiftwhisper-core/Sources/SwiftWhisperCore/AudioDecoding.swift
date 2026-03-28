@preconcurrency import AVFoundation
import Foundation

enum AudioDecodingError: LocalizedError {
    case unsupportedFormat
    case converterCreationFailed
    case readFailed
    case ffmpegUnavailable
    case ffmpegFailed(String)
    case unsupportedWaveEncoding(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "無法解碼這個音訊格式成 16kHz PCM"
        case .converterCreationFailed:
            return "建立音訊轉換器失敗"
        case .readFailed:
            return "讀取音訊資料失敗"
        case .ffmpegUnavailable:
            return "找不到可用的 ffmpeg，無法做音訊轉換"
        case .ffmpegFailed(let message):
            return "ffmpeg 音訊轉換失敗：\(message)"
        case .unsupportedWaveEncoding(let message):
            return "WAV 音訊格式不支援：\(message)"
        }
    }
}

struct DecodedAudio {
    let monoFrames: [Float]
    let stereoChannels: [[Float]]?
}

private struct ParsedWaveAudio {
    let sampleRate: Int
    let channelFrames: [[Float]]
    let bitsPerSample: Int

    var channelCount: Int { channelFrames.count }
    var frameCount: Int { channelFrames.first?.count ?? 0 }
}

enum AudioDecoder {
    static func decodeAudio(from url: URL, diarize: Bool) throws -> DecodedAudio {
        // Our app normalizes most transcription inputs into PCM WAV first.
        // For those files, direct parsing is both simpler and more reliable
        // than routing through AVFoundation and then falling back anyway.
        if url.pathExtension.lowercased() == "wav" {
            let decoded = try decodePCMWave(url, diarize: diarize)
            Diagnostics.log("swiftwhisper: direct WAV parse succeeded")
            return decoded
        }

        do {
            return try decodeWithAVFoundation(from: url, diarize: diarize)
        } catch {
            Diagnostics.log("swiftwhisper: AVFoundation decode failed, fallback to direct WAV / ffmpeg: \(error.localizedDescription)")

            return try decodeWithFFmpeg(from: url, diarize: diarize)
        }
    }

    private static func decodeWithAVFoundation(
        from url: URL,
        diarize: Bool
    ) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let preserveStereo = diarize && inputFormat.channelCount >= 2
        let outputChannels: AVAudioChannelCount = preserveStereo ? 2 : 1
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: outputChannels,
            interleaved: false
        ) else {
            throw AudioDecodingError.unsupportedFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioDecodingError.converterCreationFailed
        }

        let inputFrameCapacity: AVAudioFrameCount = 4_096
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCapacity
        ) else {
            throw AudioDecodingError.readFailed
        }

        final class DecodeState: @unchecked Sendable {
            var reachedEnd = false
            var storedReadError: Error?
        }

        let state = DecodeState()
        var monoCollected: [Float] = []
        var leftCollected: [Float] = []
        var rightCollected: [Float] = []

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 4_096
            ) else {
                throw AudioDecodingError.readFailed
            }

            var nsError: NSError?
            let status = converter.convert(to: outputBuffer, error: &nsError) { _, outStatus in
                if state.reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try file.read(into: inputBuffer, frameCount: inputFrameCapacity)
                    if inputBuffer.frameLength == 0 {
                        state.reachedEnd = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    state.storedReadError = error
                    state.reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let storedReadError = state.storedReadError {
                throw storedReadError
            }
            if let nsError {
                throw nsError
            }

            if outputBuffer.frameLength > 0,
               let channelData = outputBuffer.floatChannelData {
                let frameCount = Int(outputBuffer.frameLength)
                if preserveStereo {
                    let left = UnsafeBufferPointer(start: channelData[0], count: frameCount)
                    let right = UnsafeBufferPointer(start: channelData[1], count: frameCount)
                    leftCollected.append(contentsOf: left)
                    rightCollected.append(contentsOf: right)
                    for index in 0..<frameCount {
                        monoCollected.append((left[index] + right[index]) * 0.5)
                    }
                } else {
                    let channel = UnsafeBufferPointer(start: channelData[0], count: frameCount)
                    monoCollected.append(contentsOf: channel)
                }
            }

            if status == .endOfStream {
                break
            }
        }

        return DecodedAudio(
            monoFrames: monoCollected,
            stereoChannels: preserveStereo ? [leftCollected, rightCollected] : nil
        )
    }

    private static func decodeWithFFmpeg(from url: URL, diarize: Bool) throws -> DecodedAudio {
        let ffmpeg = try resolveFFmpeg()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let preserveStereo = diarize && ((try? AVAudioFile(forReading: url).processingFormat.channelCount) ?? 1) >= 2

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y",
            "-i", url.path,
            "-ar", "16000",
            "-ac", preserveStereo ? "2" : "1",
            "-c:a", "pcm_s16le",
            tempURL.path,
        ]

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw AudioDecodingError.ffmpegFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try decodePCMWave(tempURL, diarize: diarize)
    }

    private static func decodePCMWave(_ url: URL, diarize: Bool) throws -> DecodedAudio {
        let parsed = try parseWaveFile(url)
        Diagnostics.log(
            "swiftwhisper: direct WAV metadata sampleRate=\(parsed.sampleRate) channels=\(parsed.channelCount) bitsPerSample=\(parsed.bitsPerSample) frames=\(parsed.frameCount)"
        )
        let decoded = normalizeWaveAudio(parsed, diarize: diarize)
        let stereoInfo = decoded.stereoChannels.map { " stereoChannels=\($0.count)x\($0.first?.count ?? 0)" } ?? ""
        Diagnostics.log(
            "swiftwhisper: normalized WAV targetSampleRate=16000 monoFrames=\(decoded.monoFrames.count)\(stereoInfo)"
        )
        return decoded
    }

    private static func parseWaveFile(_ url: URL) throws -> ParsedWaveAudio {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw AudioDecodingError.readFailed
        }

        func littleEndianUInt16(at offset: Int) -> UInt16 {
            data[offset..<(offset + 2)].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        }

        func littleEndianUInt32(at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        }

        guard String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw AudioDecodingError.readFailed
        }

        var offset = 12
        var audioFormat: Int?
        var channelCount: Int?
        var sampleRate: Int?
        var bitsPerSample: Int?
        var dataOffset: Int?
        var dataSize: Int?

        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = Int(littleEndianUInt32(at: offset + 4))
            let chunkDataStart = offset + 8
            let nextOffset = chunkDataStart + chunkSize + (chunkSize % 2)

            guard nextOffset <= data.count else { break }

            if chunkID == "fmt " {
                if chunkSize >= 16 {
                    audioFormat = Int(littleEndianUInt16(at: chunkDataStart))
                    channelCount = Int(littleEndianUInt16(at: chunkDataStart + 2))
                    sampleRate = Int(littleEndianUInt32(at: chunkDataStart + 4))
                    bitsPerSample = Int(littleEndianUInt16(at: chunkDataStart + 14))
                    if audioFormat == 0xFFFE, chunkSize >= 40 {
                        // WAVE_FORMAT_EXTENSIBLE: the first 16 bits of the subformat
                        // identify PCM (1) / IEEE float (3).
                        audioFormat = Int(littleEndianUInt16(at: chunkDataStart + 24))
                    }
                }
            } else if chunkID == "data" {
                dataOffset = chunkDataStart
                dataSize = chunkSize
            }

            offset = nextOffset
        }

        guard
            let audioFormat,
            let channelCount,
            let sampleRate,
            let bitsPerSample,
            let dataOffset,
            let dataSize,
            sampleRate > 0,
            channelCount > 0
        else {
            throw AudioDecodingError.readFailed
        }

        let pcmData = data[dataOffset..<min(dataOffset + dataSize, data.count)]
        let bytesPerSample = bitsPerSample / 8
        guard bytesPerSample > 0 else {
            throw AudioDecodingError.readFailed
        }

        let frameStride = channelCount * bytesPerSample
        let sampleCount = pcmData.count / frameStride
        guard sampleCount > 0 else {
            throw AudioDecodingError.readFailed
        }

        var channelFrames = Array(repeating: [Float](), count: channelCount)
        for index in 0..<channelCount {
            channelFrames[index].reserveCapacity(sampleCount)
        }

        func readInt16(_ buffer: Data, at offset: Int) -> Int16 {
            let start = buffer.startIndex + offset
            let low = UInt16(buffer[start])
            let high = UInt16(buffer[start + 1]) << 8
            return Int16(bitPattern: low | high)
        }

        func readInt32(_ buffer: Data, at offset: Int) -> Int32 {
            let start = buffer.startIndex + offset
            let b0 = UInt32(buffer[start])
            let b1 = UInt32(buffer[start + 1]) << 8
            let b2 = UInt32(buffer[start + 2]) << 16
            let b3 = UInt32(buffer[start + 3]) << 24
            return Int32(bitPattern: b0 | b1 | b2 | b3)
        }

        func readFloat32(_ buffer: Data, at offset: Int) -> Float32 {
            Float32(bitPattern: UInt32(bitPattern: readInt32(buffer, at: offset)))
        }

        for frameIndex in 0..<sampleCount {
            let frameOffset = frameIndex * frameStride
            for channelIndex in 0..<channelCount {
                let sampleOffset = frameOffset + (channelIndex * bytesPerSample)
                let value: Float

                switch (audioFormat, bitsPerSample) {
                case (1, 16):
                    value = Float(readInt16(pcmData, at: sampleOffset)) / 32767.0
                case (1, 32):
                    value = Float(readInt32(pcmData, at: sampleOffset)) / 2147483647.0
                case (3, 32):
                    value = readFloat32(pcmData, at: sampleOffset)
                default:
                    throw AudioDecodingError.unsupportedWaveEncoding(
                        "audioFormat=\(audioFormat), bitsPerSample=\(bitsPerSample), channels=\(channelCount), sampleRate=\(sampleRate)"
                    )
                }

                channelFrames[channelIndex].append(max(-1.0, min(value, 1.0)))
            }
        }

        return ParsedWaveAudio(
            sampleRate: sampleRate,
            channelFrames: channelFrames,
            bitsPerSample: bitsPerSample
        )
    }

    private static func normalizeWaveAudio(_ parsed: ParsedWaveAudio, diarize: Bool) -> DecodedAudio {
        let normalizedChannels = parsed.channelFrames.map {
            resample($0, from: parsed.sampleRate, to: 16_000)
        }

        let monoFrames = mixdownToMono(normalizedChannels)
        let stereoChannels: [[Float]]? = {
            guard diarize, normalizedChannels.count >= 2 else { return nil }
            return [normalizedChannels[0], normalizedChannels[1]]
        }()

        return DecodedAudio(
            monoFrames: monoFrames,
            stereoChannels: stereoChannels
        )
    }

    private static func mixdownToMono(_ channels: [[Float]]) -> [Float] {
        guard let frameCount = channels.map(\.count).min(), frameCount > 0 else {
            return []
        }
        guard channels.count > 1 else {
            return channels.first ?? []
        }

        var mono = [Float](repeating: 0, count: frameCount)
        let divisor = Float(channels.count)
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channel in channels {
                sum += channel[frameIndex]
            }
            mono[frameIndex] = sum / divisor
        }
        return mono
    }

    private static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else {
            return samples
        }
        guard sourceRate != targetRate else {
            return samples
        }

        let outputCount = max(1, Int((Double(samples.count) * Double(targetRate) / Double(sourceRate)).rounded()))
        guard outputCount > 1, samples.count > 1 else {
            return [samples[0]]
        }

        let lastIndex = samples.count - 1
        let ratio = Double(sourceRate) / Double(targetRate)
        var output = [Float](repeating: 0, count: outputCount)

        for outputIndex in 0..<outputCount {
            let sourcePosition = min(Double(lastIndex), Double(outputIndex) * ratio)
            let lowerIndex = Int(sourcePosition.rounded(.down))
            let upperIndex = min(lowerIndex + 1, lastIndex)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            let lowerSample = samples[lowerIndex]
            let upperSample = samples[upperIndex]
            output[outputIndex] = lowerSample + ((upperSample - lowerSample) * fraction)
        }

        return output
    }

    private static func resolveFFmpeg() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["SCRIBBY_FFMPEG"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw AudioDecodingError.ffmpegUnavailable
    }
}

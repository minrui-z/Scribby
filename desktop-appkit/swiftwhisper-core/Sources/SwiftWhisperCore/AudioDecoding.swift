@preconcurrency import AVFoundation
import Foundation

enum AudioDecodingError: LocalizedError {
    case unsupportedFormat
    case converterCreationFailed
    case readFailed
    case ffmpegUnavailable
    case ffmpegFailed(String)

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
        }
    }
}

struct DecodedAudio {
    let monoFrames: [Float]
    let stereoChannels: [[Float]]?
}

enum AudioDecoder {
    static func decodeAudio(from url: URL, diarize: Bool) throws -> DecodedAudio {
        do {
            return try decodeWithAVFoundation(from: url, diarize: diarize)
        } catch {
            Diagnostics.log("swiftwhisper: AVFoundation decode failed, fallback to direct WAV / ffmpeg: \(error.localizedDescription)")

            // If the file is already a PCM WAV (e.g. pre-converted by the main app),
            // parse it directly without AVFoundation or ffmpeg.
            if url.pathExtension.lowercased() == "wav" {
                do {
                    let decoded = try decodePCM16Wave(url)
                    Diagnostics.log("swiftwhisper: direct WAV parse succeeded")
                    return decoded
                } catch {
                    Diagnostics.log("swiftwhisper: direct WAV parse failed: \(error.localizedDescription)")
                }
            }

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
        return try decodePCM16Wave(tempURL)
    }

    private static func decodePCM16Wave(_ url: URL) throws -> DecodedAudio {
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
        var channelCount: Int?
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
                    channelCount = Int(littleEndianUInt16(at: chunkDataStart + 2))
                    bitsPerSample = Int(littleEndianUInt16(at: chunkDataStart + 14))
                }
            } else if chunkID == "data" {
                dataOffset = chunkDataStart
                dataSize = chunkSize
            }

            offset = nextOffset
        }

        guard
            let channelCount,
            let bitsPerSample,
            let dataOffset,
            let dataSize,
            bitsPerSample == 16,
            channelCount == 1 || channelCount == 2
        else {
            throw AudioDecodingError.readFailed
        }

        let pcmData = data[dataOffset..<min(dataOffset + dataSize, data.count)]
        let sampleCount = pcmData.count / 2 / channelCount
        guard sampleCount > 0 else {
            throw AudioDecodingError.readFailed
        }

        var monoFrames: [Float] = []
        monoFrames.reserveCapacity(sampleCount)
        var leftFrames: [Float] = []
        var rightFrames: [Float] = []

        if channelCount == 2 {
            leftFrames.reserveCapacity(sampleCount)
            rightFrames.reserveCapacity(sampleCount)
        }

        pcmData.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<sampleCount {
                if channelCount == 1 {
                    let value = max(-1.0, min(Float(Int16(littleEndian: samples[index])) / 32767.0, 1.0))
                    monoFrames.append(value)
                } else {
                    let left = max(-1.0, min(Float(Int16(littleEndian: samples[index * 2])) / 32767.0, 1.0))
                    let right = max(-1.0, min(Float(Int16(littleEndian: samples[index * 2 + 1])) / 32767.0, 1.0))
                    leftFrames.append(left)
                    rightFrames.append(right)
                    monoFrames.append((left + right) * 0.5)
                }
            }
        }

        return DecodedAudio(
            monoFrames: monoFrames,
            stereoChannels: channelCount == 2 ? [leftFrames, rightFrames] : nil
        )
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

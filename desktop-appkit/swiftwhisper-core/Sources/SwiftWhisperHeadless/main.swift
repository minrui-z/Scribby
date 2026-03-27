import Foundation
import SwiftWhisperCore

@main
struct SwiftWhisperHeadlessCLI {
    static func main() async {
        let writer = EventStreamWriter()
        do {
            let request = try resolveRequest(arguments: CommandLine.arguments)
            let core = SwiftWhisperCore()
            _ = try await core.transcribeStreaming(request) { event in
                writer.write(event)
            }
        } catch {
            let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
            writer.write(.failed(message))
            FileHandle.standardError.write(Data("SwiftWhisper headless failed: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func resolveRequest(arguments: [String]) throws -> SwiftWhisperRequest {
        guard arguments.count > 1 else {
            throw SwiftWhisperCoreError.invalidRequest("用法：scribby-swiftwhisper-headless <audio_file> [language] [--diarize]")
        }
        let language = arguments.count > 2 ? arguments[2] : "zh"
        let diarize = arguments.dropFirst(3).contains("--diarize")
        return SwiftWhisperRequest(
            audioFileURL: URL(fileURLWithPath: arguments[1]),
            languageCode: language,
            diarize: diarize
        )
    }
}

final class EventStreamWriter: @unchecked Sendable {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let lock = NSLock()

    func write(_ event: SwiftWhisperEvent) {
        lock.lock()
        defer { lock.unlock() }

        switch event {
        case .completed:
            FileHandle.standardError.write(Data("swiftwhisper: emitting completed event\n".utf8))
        case .failed:
            FileHandle.standardError.write(Data("swiftwhisper: emitting failed event\n".utf8))
        default:
            break
        }

        do {
            let envelope = SwiftWhisperEventEnvelope(event: event)
            let data = try encoder.encode(envelope)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            switch event {
            case .completed:
                FileHandle.standardError.write(Data("swiftwhisper: completed event flushed\n".utf8))
            case .failed:
                FileHandle.standardError.write(Data("swiftwhisper: failed event flushed\n".utf8))
            default:
                break
            }
        } catch {
            let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
            FileHandle.standardError.write(Data("SwiftWhisper stream encode failed: \(message)\n".utf8))
        }
    }
}

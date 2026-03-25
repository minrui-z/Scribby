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
                Task {
                    await writer.write(event)
                }
            }
        } catch {
            let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
            await writer.write(.failed(message))
            FileHandle.standardError.write(Data("SwiftWhisper headless failed: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func resolveRequest(arguments: [String]) throws -> SwiftWhisperRequest {
        if arguments.count > 1 {
            let language = arguments.count > 2 ? arguments[2] : "zh"
            let diarize = arguments.dropFirst(3).contains("--diarize")
            return SwiftWhisperRequest(
                audioFileURL: URL(fileURLWithPath: arguments[1]),
                languageCode: language,
                diarize: diarize
            )
        }

        let defaultURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../../testvocal.m4a")
            .standardizedFileURL
        return SwiftWhisperRequest(audioFileURL: defaultURL)
    }
}

actor EventStreamWriter {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func write(_ event: SwiftWhisperEvent) {
        do {
            let envelope = SwiftWhisperEventEnvelope(event: event)
            let data = try encoder.encode(envelope)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
            FileHandle.standardError.write(Data("SwiftWhisper stream encode failed: \(message)\n".utf8))
        }
    }
}

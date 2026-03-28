import CoreML
import Foundation
import SwiftWhisperCore

private struct Options {
    let preset: String
    let modelDirectory: URL
    let timeout: TimeInterval
    let computeUnits: MLComputeUnits

    init(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw CLIError.usage
        }

        self.preset = arguments[1]

        var timeout: TimeInterval = 20
        var modelDirectory: URL?
        var computeUnits: MLComputeUnits = .cpuAndGPU
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--model-dir":
                index += 1
                guard index < arguments.count else { throw CLIError.usage }
                modelDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--timeout":
                index += 1
                guard index < arguments.count, let seconds = TimeInterval(arguments[index]) else {
                    throw CLIError.usage
                }
                timeout = seconds
            case "--compute-units":
                index += 1
                guard index < arguments.count else { throw CLIError.usage }
                computeUnits = try Self.parseComputeUnits(arguments[index])
            default:
                throw CLIError.usage
            }
            index += 1
        }

        self.modelDirectory = modelDirectory ?? Self.defaultModelDirectory()
        self.timeout = timeout
        self.computeUnits = computeUnits
    }

    private static func defaultModelDirectory() -> URL {
        if let environmentPath = ProcessInfo.processInfo.environment["SCRIBBY_SWIFTWHISPER_MODEL_DIR"],
           !environmentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: environmentPath, isDirectory: true)
        }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.minrui.scribby", isDirectory: true)
            .appendingPathComponent("swiftwhisper-models", isDirectory: true)
    }

    static func parseComputeUnits(_ rawValue: String) throws -> MLComputeUnits {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "all":
            return .all
        case "cpu_only", "cpuonly":
            return .cpuOnly
        case "cpu_and_gpu", "cpuandgpu", "gpu":
            return .cpuAndGPU
        case "cpu_and_ne", "cpu_and_neural_engine", "ne":
            return .cpuAndNeuralEngine
        default:
            throw CLIError.usage
        }
    }
}

private enum CLIError: LocalizedError {
    case usage
    case unknownPreset(String)
    case compilerNotFound
    case packageMissing(String)
    case compileFailed(String)
    case compiledOutputMissing(String)
    case loadTimedOut(TimeInterval)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "用法：scribby-coreml-diagnose <large-v3|large-v3-turbo> [--model-dir <path>] [--timeout <seconds>] [--compute-units <cpu_and_gpu|cpu_and_ne|cpu_only|all>]"
        case .unknownPreset(let preset):
            return "不支援的 preset：\(preset)"
        case .compilerNotFound:
            return "找不到 coremlc 編譯器"
        case .packageMissing(let path):
            return "找不到 encoder package：\(path)"
        case .compileFailed(let message):
            return "Core ML encoder 編譯失敗：\(message)"
        case .compiledOutputMissing(let path):
            return "找不到編譯輸出：\(path)"
        case .loadTimedOut(let timeout):
            return "Core ML encoder 載入逾時（\(Int(timeout)) 秒）"
        case .loadFailed(let message):
            return "Core ML encoder 載入失敗：\(message)"
        }
    }
}

private struct CoreMLDiagnosisReport: Codable {
    struct Stage: Codable {
        let status: String
        let durationMs: Int?
        let path: String?
        let message: String?
    }

    let preset: String
    let modelDirectory: String
    let package: Stage
    let compile: Stage
    let load: Stage
}

@main
struct CoreMLDiagnoseCLI {
    static func main() async {
        do {
            if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--load-only" {
                let modelURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                let computeUnits: MLComputeUnits
                if CommandLine.arguments.count >= 5, CommandLine.arguments[3] == "--compute-units" {
                    computeUnits = try Options.parseComputeUnits(CommandLine.arguments[4])
                } else {
                    computeUnits = .cpuAndGPU
                }
                let configuration = MLModelConfiguration()
                configuration.computeUnits = computeUnits
                _ = try MLModel(contentsOf: modelURL, configuration: configuration)
                exit(0)
            }

            let options = try Options(arguments: CommandLine.arguments)
            let report = try await diagnose(options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(report.load.status == "ok" ? 0 : 1)
        } catch {
            let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
            FileHandle.standardError.write(Data("scribby-coreml-diagnose failed: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func diagnose(options: Options) async throws -> CoreMLDiagnosisReport {
        let spec = try resolveModelSpec(for: options.preset)
        let packageName = spec.filename.replacingOccurrences(of: ".bin", with: "-encoder.mlpackage")
        let packageURL = options.modelDirectory.appendingPathComponent(packageName, isDirectory: true)

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw CLIError.packageMissing(packageURL.path)
        }

        let packageStage = CoreMLDiagnosisReport.Stage(
            status: "ok",
            durationMs: nil,
            path: packageURL.path,
            message: "找到 encoder package"
        )

        let compileWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribby-coreml-diagnose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: compileWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: compileWorkspace) }

        let compiler = try locateCoreMLCompiler()
        let compileStart = Date()
        let compileProcess = Process()
        compileProcess.executableURL = compiler.executableURL
        compileProcess.arguments = compiler.argumentsPrefix + ["compile", packageURL.path, compileWorkspace.path]
        let compileError = Pipe()
        compileProcess.standardOutput = FileHandle.nullDevice
        compileProcess.standardError = compileError
        try compileProcess.run()
        compileProcess.waitUntilExit()

        let compileDuration = Int(Date().timeIntervalSince(compileStart) * 1000)
        let compiledName = packageURL.deletingPathExtension().lastPathComponent + ".mlmodelc"
        let compiledURL = compileWorkspace.appendingPathComponent(compiledName, isDirectory: true)

        guard compileProcess.terminationStatus == 0 else {
            let stderr = String(data: compileError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(compileProcess.terminationStatus)"
            throw CLIError.compileFailed(stderr)
        }

        guard FileManager.default.fileExists(atPath: compiledURL.path) else {
            throw CLIError.compiledOutputMissing(compiledURL.path)
        }

        let compileStage = CoreMLDiagnosisReport.Stage(
            status: "ok",
            durationMs: compileDuration,
            path: compiledURL.path,
            message: "coremlc compile 成功"
        )

        let loadStart = Date()
        do {
            try await validateLoad(
                of: compiledURL,
                timeout: options.timeout,
                executableURL: URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false),
                computeUnits: options.computeUnits
            )
            let loadStage = CoreMLDiagnosisReport.Stage(
                status: "ok",
                durationMs: Int(Date().timeIntervalSince(loadStart) * 1000),
                path: compiledURL.path,
                message: "MLModel 載入成功"
            )
            return CoreMLDiagnosisReport(
                preset: spec.preset,
                modelDirectory: options.modelDirectory.path,
                package: packageStage,
                compile: compileStage,
                load: loadStage
            )
        } catch {
            let loadStage = CoreMLDiagnosisReport.Stage(
                status: "failed",
                durationMs: Int(Date().timeIntervalSince(loadStart) * 1000),
                path: compiledURL.path,
                message: error.localizedDescription
            )
            return CoreMLDiagnosisReport(
                preset: spec.preset,
                modelDirectory: options.modelDirectory.path,
                package: packageStage,
                compile: compileStage,
                load: loadStage
            )
        }
    }

    private static func resolveModelSpec(for preset: String) throws -> SwiftWhisperModelSpec {
        switch preset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "large-v3":
            return .largeV3
        case "large-v3-turbo":
            return .largeV3Turbo
        default:
            throw CLIError.unknownPreset(preset)
        }
    }

    private static func locateCoreMLCompiler() throws -> CompilerInvocation {
        let directCandidates = [
            URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/coremlc"),
            URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/coremlc"),
        ]

        for candidate in directCandidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return CompilerInvocation(executableURL: candidate, argumentsPrefix: [])
        }

        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        if FileManager.default.isExecutableFile(atPath: xcrun.path) {
            return CompilerInvocation(executableURL: xcrun, argumentsPrefix: ["coremlc"])
        }
        throw CLIError.compilerNotFound
    }

    private static func validateLoad(
        of modelURL: URL,
        timeout: TimeInterval,
        executableURL: URL,
        computeUnits: MLComputeUnits
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [
                "--load-only",
                modelURL.path,
                "--compute-units",
                computeUnits.cliValue
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
            }

            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == SIGTERM || process.terminationStatus == SIGINT {
                    throw CLIError.loadTimedOut(timeout)
                }
                throw CLIError.loadFailed(errorText?.isEmpty == false ? errorText! : "exit \(process.terminationStatus)")
            }
        }.value
    }
}

private struct CompilerInvocation {
    let executableURL: URL
    let argumentsPrefix: [String]
}

private extension MLComputeUnits {
    var cliValue: String {
        switch self {
        case .all:
            return "all"
        case .cpuOnly:
            return "cpu_only"
        case .cpuAndGPU:
            return "cpu_and_gpu"
        case .cpuAndNeuralEngine:
            return "cpu_and_ne"
        @unknown default:
            return "cpu_and_gpu"
        }
    }
}

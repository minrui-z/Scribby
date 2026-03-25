import Foundation

enum ResolverError: Error, LocalizedError {
    case missingPath(String)

    var errorDescription: String? {
        switch self {
        case .missingPath(let message):
            return message
        }
    }
}

enum PathResolver {
    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func workspaceRoot() -> URL {
        repoRoot().appendingPathComponent("desktop-appkit", isDirectory: true)
    }

    static func appSupportDirectory() throws -> URL {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ResolverError.missingPath("找不到 Application Support")
        }

        let currentDirectory = base.appendingPathComponent("com.minrui.scribby", isDirectory: true)
        let legacyDirectory = base.appendingPathComponent("com.minrui.scribby.native", isDirectory: true)

        if !fileManager.fileExists(atPath: currentDirectory.path) {
            if fileManager.fileExists(atPath: legacyDirectory.path) {
                try fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)

                let legacyModels = legacyDirectory.appendingPathComponent("swiftwhisper-models", isDirectory: true)
                let currentModels = currentDirectory.appendingPathComponent("swiftwhisper-models", isDirectory: true)
                if fileManager.fileExists(atPath: legacyModels.path),
                   !fileManager.fileExists(atPath: currentModels.path) {
                    try? fileManager.copyItem(at: legacyModels, to: currentModels)
                }
            } else {
                try fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
            }
        }
        return currentDirectory
    }

    static func downloadsDirectory() throws -> URL {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ResolverError.missingPath("找不到 Downloads 資料夾")
        }
        return base
    }

    static func uniqueDownloadDestination(suggestedName: String) throws -> URL {
        let fileManager = FileManager.default
        let downloads = try downloadsDirectory()

        let trimmed = suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = trimmed.isEmpty ? "transcript.txt" : trimmed
        let originalURL = downloads.appendingPathComponent(fallbackName, isDirectory: false)
        if !fileManager.fileExists(atPath: originalURL.path) {
            return originalURL
        }

        let ext = originalURL.pathExtension
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let parent = originalURL.deletingLastPathComponent()

        for index in 2...999 {
            let filename: String
            if ext.isEmpty {
                filename = "\(stem)-\(index)"
            } else {
                filename = "\(stem)-\(index).\(ext)"
            }
            let candidate = parent.appendingPathComponent(filename, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw ResolverError.missingPath("找不到可用的下載檔名")
    }

    static func pythonExecutable() throws -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("desktop/runtime/python/bin/python3", isDirectory: false)
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let workspace = workspaceRoot().appendingPathComponent(".venv/bin/python", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: workspace.path) {
            return workspace
        }

        let repo = repoRoot().appendingPathComponent("venv/bin/python", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: repo.path) {
            return repo
        }

        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3.11") {
            return URL(fileURLWithPath: "/opt/homebrew/bin/python3.11")
        }

        throw ResolverError.missingPath("找不到 Python 執行檔")
    }

    static func backendScript() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("desktop/python_backend.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        let dev = repoRoot().appendingPathComponent("desktop/python_backend.py", isDirectory: false)
        guard FileManager.default.fileExists(atPath: dev.path) else {
            throw ResolverError.missingPath("找不到桌面版 backend 腳本")
        }
        return dev
    }

    static func diarizationHelperScript() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("python/pyannote_diarize.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        let dev = repoRoot().appendingPathComponent("desktop-appkit/python/pyannote_diarize.py", isDirectory: false)
        guard FileManager.default.fileExists(atPath: dev.path) else {
            throw ResolverError.missingPath("找不到 pyannote diarization helper")
        }
        return dev
    }

    static func desktopWorkingDirectory() -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("desktop", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return repoRoot().appendingPathComponent("desktop", isDirectory: true)
    }

    static func swiftWhisperExecutable() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/scribby-swiftwhisper-headless"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let packageRoot = repoRoot().appendingPathComponent("desktop-appkit/swiftwhisper-core", isDirectory: true)
        let binPath = packageRoot.appendingPathComponent(".build/apple/Products/Release/scribby-swiftwhisper-headless")
        if FileManager.default.isExecutableFile(atPath: binPath.path) {
            return binPath
        }

        throw ResolverError.missingPath("找不到 SwiftWhisper headless 執行檔")
    }

    static func swiftWhisperModelDirectory() throws -> URL {
        let directory = try appSupportDirectory().appendingPathComponent("swiftwhisper-models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func swiftWhisperCoreMLPackage(named packageName: String) -> URL? {
        let fileManager = FileManager.default

        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("swiftwhisper-models/\(packageName)", isDirectory: true),
           fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }

        let dev = repoRoot()
            .appendingPathComponent("desktop-appkit/vendor/SwiftWhisper/whisper.cpp/models/\(packageName)", isDirectory: true)
        if fileManager.fileExists(atPath: dev.path) {
            return dev
        }

        return nil
    }

    static func ffmpegBinary() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("desktop/runtime/bin/ffmpeg"),
            Bundle.main.resourceURL?.appendingPathComponent("desktop/runtime/python/bin/ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        ].compactMap { $0 }

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    static func backendEnvironment() throws -> [String: String] {
        let python = try pythonExecutable()
        var env = ProcessInfo.processInfo.environment

        var pathEntries: [String] = []
        pathEntries.append(python.deletingLastPathComponent().path)
        if let ffmpeg = ffmpegBinary()?.deletingLastPathComponent().path {
            pathEntries.append(ffmpeg)
        }
        pathEntries.append(env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        env["PATH"] = pathEntries.joined(separator: ":")

        if let ffmpeg = ffmpegBinary() {
            env["FFMPEG_BINARY"] = ffmpeg.path
            env["IMAGEIO_FFMPEG_EXE"] = ffmpeg.path
        }

        if let resourceURL = Bundle.main.resourceURL {
            let pythonHome = resourceURL.appendingPathComponent("desktop/runtime/python", isDirectory: true)
            if FileManager.default.fileExists(atPath: pythonHome.path) {
                env["PYTHONHOME"] = pythonHome.path
                env["PYTHONPATH"] = pythonHome.appendingPathComponent("lib/python3.10/site-packages").path
                env["PYTHONNOUSERSITE"] = "1"
            }
        }

        return env
    }
}

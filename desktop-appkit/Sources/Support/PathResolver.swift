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
    /// Whether the app is running from a .app bundle (vs Xcode/dev build).
    private static var isRunningFromBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Dev-only: repo root derived from source file path. Returns nil when running from bundle.
    private static func devRepoRoot() -> URL? {
        guard !isRunningFromBundle else { return nil }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    // MARK: - Python

    static func managedPythonVenv() throws -> URL {
        try appSupportDirectory()
            .appendingPathComponent("python-env/bin/python3", isDirectory: false)
    }

    static func pythonExecutable() throws -> URL {
        // 1. Managed venv (auto-created by PythonEnvironmentManager)
        if let managed = try? managedPythonVenv(),
           FileManager.default.isExecutableFile(atPath: managed.path) {
            return managed
        }

        // 2. Standalone Python (downloaded by PythonEnvironmentManager)
        let standalone = try appSupportDirectory()
            .appendingPathComponent("python-standalone/python/bin/python3", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: standalone.path) {
            return standalone
        }

        // 3. Dev-only: workspace venv
        if let root = devRepoRoot() {
            let workspace = root.appendingPathComponent("desktop-appkit/.venv/bin/python", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: workspace.path) {
                return workspace
            }
        }

        // 4. System Python
        let systemFallbacks = [
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.10",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/usr/bin/python3",
        ]
        for path in systemFallbacks {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        throw ResolverError.missingPath("找不到 Python 環境")
    }

    // MARK: - Scripts

    static func diarizationHelperScript() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("python/pyannote_diarize.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        if let dev = devRepoRoot()?.appendingPathComponent("desktop-appkit/python/pyannote_diarize.py", isDirectory: false),
           FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }

        throw ResolverError.missingPath("找不到 pyannote diarization helper")
    }

    static func enhancementHelperScript() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("python/speech_enhance.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        if let dev = devRepoRoot()?.appendingPathComponent("desktop-appkit/python/speech_enhance.py", isDirectory: false),
           FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }

        throw ResolverError.missingPath("找不到 speech enhancement helper")
    }

    // MARK: - Binaries

    static func swiftWhisperExecutable() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/scribby-swiftwhisper-headless"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        if let dev = devRepoRoot()?
            .appendingPathComponent("desktop-appkit/swiftwhisper-core/.build/apple/Products/Release/scribby-swiftwhisper-headless"),
           FileManager.default.isExecutableFile(atPath: dev.path) {
            return dev
        }

        throw ResolverError.missingPath("找不到 SwiftWhisper headless 執行檔")
    }

    // MARK: - Models

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

        if let dev = devRepoRoot()?
            .appendingPathComponent("desktop-appkit/vendor/SwiftWhisper/whisper.cpp/models/\(packageName)", isDirectory: true),
           fileManager.fileExists(atPath: dev.path) {
            return dev
        }

        return nil
    }

    static func swiftWhisperCoreMLCompiledModel(named modelcName: String) -> URL? {
        let fileManager = FileManager.default

        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("swiftwhisper-models/\(modelcName)", isDirectory: true),
           fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }

        if let dev = devRepoRoot()?
            .appendingPathComponent("desktop-appkit/vendor/SwiftWhisper/whisper.cpp/models/\(modelcName)", isDirectory: true),
           fileManager.fileExists(atPath: dev.path) {
            return dev
        }

        return nil
    }

    // MARK: - Optional Tools

    static func ffmpegBinary() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        ].compactMap { $0 }

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: - Environment

    static func backendEnvironment() throws -> [String: String] {
        let python = try pythonExecutable()
        var env = ProcessInfo.processInfo.environment

        var pathEntries: [String] = []
        pathEntries.append(python.deletingLastPathComponent().path)
        pathEntries.append(env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        env["PATH"] = pathEntries.joined(separator: ":")

        // Clear any inherited Python env vars that could break the managed venv
        // (e.g. from Anaconda, Miniconda, pyenv, or other Python managers)
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "VIRTUAL_ENV")
        env.removeValue(forKey: "CONDA_PREFIX")
        env.removeValue(forKey: "CONDA_DEFAULT_ENV")
        env["PYTHONNOUSERSITE"] = "1"

        return env
    }
}

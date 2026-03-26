import Foundation

enum PythonDependencyGroup: String, CaseIterable {
    case enhancement
    case diarization

    var packages: [String] {
        switch self {
        case .enhancement:
            return [
                "mlx==0.31.1",
                "mlx-audio==0.4.1",
                "soundfile==0.13.1",
                "huggingface_hub==1.8.0",
            ]
        case .diarization:
            return ["torch", "pyannote.audio", "pandas", "huggingface_hub"]
        }
    }

    /// Version check script: verifies the package can be imported AND the pinned
    /// version matches.  Returns a Python one-liner suitable for `python -c`.
    var versionCheckScript: String {
        switch self {
        case .enhancement:
            // Check that mlx_audio is importable and its version matches the pin.
            return """
            import mlx_audio; \
            assert mlx_audio.__version__ == '0.4.1', \
            f'want 0.4.1 got {mlx_audio.__version__}'
            """
        case .diarization:
            return "import pyannote.audio"
        }
    }

    /// Expected package versions keyed by pip package name.
    /// Used for the environment manifest / fingerprint.
    var expectedVersions: [String: String] {
        switch self {
        case .enhancement:
            return [
                "mlx": "0.31.1",
                "mlx-audio": "0.4.1",
                "soundfile": "0.13.1",
                "huggingface_hub": "1.8.0",
            ]
        case .diarization:
            // Diarization packages are not pinned to exact versions.
            return [:]
        }
    }

    var label: String {
        switch self {
        case .enhancement: return "人聲加強"
        case .diarization: return "語者辨識"
        }
    }
}

/// Progress info for a pip package download.
struct PipDownloadInfo: Sendable {
    var packageName: String
    var downloadedBytes: Int64
    var totalBytes: Int64
    var status: String  // e.g. "Downloading", "Installing", "Collecting"
}

// MARK: - Environment Manifest

/// Persisted alongside `python-env/` to detect version drift or corruption.
private struct EnvironmentManifest: Codable {
    var pythonVersion: String
    var groups: [String: [String: String]]  // group.rawValue → { package: version }

    static let fileName = "env-manifest.json"
}

actor PythonEnvironmentManager {
    static let shared = PythonEnvironmentManager()

    private var readyGroups: Set<PythonDependencyGroup> = []

    private var venvDirectory: URL {
        get throws {
            try PathResolver.appSupportDirectory()
                .appendingPathComponent("python-env", isDirectory: true)
        }
    }

    private var venvPython: URL {
        get throws {
            try venvDirectory.appendingPathComponent("bin/python3", isDirectory: false)
        }
    }

    private var manifestURL: URL {
        get throws {
            try PathResolver.appSupportDirectory()
                .appendingPathComponent(EnvironmentManifest.fileName, isDirectory: false)
        }
    }

    func pythonExecutable() throws -> URL {
        try venvPython
    }

    func ensureReady(
        for group: PythonDependencyGroup,
        log: @escaping @Sendable (String) -> Void,
        pipProgress: @escaping @Sendable (PipDownloadInfo) -> Void = { _ in }
    ) async throws {
        if readyGroups.contains(group) { return }

        #if !arch(arm64)
        if group == .enhancement {
            throw ResolverError.missingPath("人聲加強功能需要 Apple Silicon（M1 以上）")
        }
        #endif

        let venvDir = try venvDirectory
        let python = try venvPython
        let manifest = readManifest()

        // 1. Check if venv exists
        let venvExists = FileManager.default.fileExists(atPath: python.path)

        // 2. If venv exists, check manifest for version drift
        if venvExists, let manifest = manifest {
            let drifted = isManifestDrifted(manifest, for: group, python: python)
            if drifted {
                log("偵測到環境版本不符，正在重建...")
                try destroyVenv(at: venvDir)
                readyGroups = []  // All groups invalidated
            }
        } else if venvExists, manifest == nil {
            // Venv exists but no manifest — legacy env, rebuild to be safe
            // only if this group has pinned versions worth checking
            if !group.expectedVersions.isEmpty {
                let versionOK = await checkCapability(python: python, group: group)
                if !versionOK {
                    log("舊環境缺少版本記錄且驗證失敗，正在重建...")
                    try destroyVenv(at: venvDir)
                    readyGroups = []
                }
            }
        }

        // 3. Create venv if needed
        if !FileManager.default.fileExists(atPath: python.path) {
            log("正在建立 Python 虛擬環境...")
            try await createVenv(at: venvDir, log: log)
        }

        // 4. Check capability (import + version)
        if await checkCapability(python: python, group: group) {
            try updateManifest(for: group, python: python)
            readyGroups.insert(group)
            return
        }

        // 5. Install packages
        log("正在安裝\(group.label)所需的 Python 套件...")
        try await installPackages(group.packages, python: python, log: log, pipProgress: pipProgress)

        // 6. Verify
        guard await checkCapability(python: python, group: group) else {
            throw ResolverError.missingPath("安裝 \(group.label) 依賴後仍無法通過能力驗證")
        }

        try updateManifest(for: group, python: python)
        readyGroups.insert(group)
        log("\(group.label)環境就緒")
    }

    // MARK: - Private

    /// Build a clean environment for running Python subprocesses,
    /// stripping vars that could interfere with the managed venv
    /// (e.g. Anaconda, Miniconda, pyenv).
    private func cleanEnvironment(python: URL? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "VIRTUAL_ENV")
        env.removeValue(forKey: "CONDA_PREFIX")
        env.removeValue(forKey: "CONDA_DEFAULT_ENV")
        env["PYTHONNOUSERSITE"] = "1"
        if let python = python {
            let binDir = python.deletingLastPathComponent().path
            let existing = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = binDir + ":" + existing
        }
        return env
    }

    private func createVenv(at directory: URL, log: @escaping @Sendable (String) -> Void) async throws {
        let basePython = try await findSystemPython(log: log)

        let process = Process()
        process.executableURL = basePython
        process.arguments = ["-m", "venv", directory.path]
        process.environment = cleanEnvironment()

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ResolverError.missingPath("建立 Python venv 失敗：\(errText)")
        }

        log("正在升級 pip...")
        let venvPy = directory.appendingPathComponent("bin/python3")
        let pip = Process()
        pip.executableURL = venvPy
        pip.arguments = ["-m", "pip", "install", "--upgrade", "pip"]
        pip.environment = cleanEnvironment(python: venvPy)
        pip.standardOutput = FileHandle.nullDevice
        pip.standardError = FileHandle.nullDevice
        try pip.run()
        pip.waitUntilExit()
    }

    private func findSystemPython(log: @escaping @Sendable (String) -> Void) async throws -> URL {
        if let found = locateExistingPython() {
            return found
        }

        // No Python found — install via Xcode Command Line Tools
        log("正在安裝環境...")
        try await installCommandLineTools(log: log)

        // After installation, check again
        if let found = locateExistingPython() {
            return found
        }

        throw ResolverError.missingPath("環境安裝未完成，請完成系統彈出的安裝視窗後重試")
    }

    private func locateExistingPython() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                // /usr/bin/python3 is a shim — verify it actually works
                if path == "/usr/bin/python3" {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = ["--version"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        process.waitUntilExit()
                        if process.terminationStatus != 0 { continue }
                    } catch {
                        continue
                    }
                }
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func installCommandLineTools(log: @escaping @Sendable (String) -> Void) async throws {
        // Trigger the macOS install dialog
        let trigger = Process()
        trigger.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        trigger.arguments = ["--install"]
        trigger.standardOutput = FileHandle.nullDevice
        trigger.standardError = FileHandle.nullDevice
        try trigger.run()
        trigger.waitUntilExit()

        log("正在安裝環境，請稍候...")

        // Poll until python3 becomes available (or timeout after 10 minutes)
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            // Check if CLT installation finished
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            check.arguments = ["-p"]
            check.standardOutput = FileHandle.nullDevice
            check.standardError = FileHandle.nullDevice
            do {
                try check.run()
                check.waitUntilExit()
                if check.terminationStatus == 0 {
                    // CLT installed, verify python3
                    if locateExistingPython() != nil {
                        log("環境安裝完成")
                        return
                    }
                }
            } catch {
                continue
            }
        }

        throw ResolverError.missingPath("環境安裝逾時，請完成系統彈出的安裝視窗後重試")
    }

    /// Check that the group's packages are importable AND at the expected version.
    private func checkCapability(python: URL, group: PythonDependencyGroup) async -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", group.versionCheckScript]
        process.environment = cleanEnvironment(python: python)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Manifest

    private func readManifest() -> EnvironmentManifest? {
        guard let url = try? manifestURL,
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(EnvironmentManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    private func updateManifest(for group: PythonDependencyGroup, python: URL) throws {
        let url = try manifestURL
        var manifest = readManifest() ?? EnvironmentManifest(pythonVersion: "", groups: [:])

        // Record Python version
        manifest.pythonVersion = pythonVersion(python: python) ?? manifest.pythonVersion

        // Record installed versions for this group
        manifest.groups[group.rawValue] = group.expectedVersions

        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private func isManifestDrifted(
        _ manifest: EnvironmentManifest,
        for group: PythonDependencyGroup,
        python: URL
    ) -> Bool {
        // Check Python major.minor hasn't changed
        if let currentPy = pythonVersion(python: python) {
            let manifestMajorMinor = manifest.pythonVersion.components(separatedBy: ".").prefix(2).joined(separator: ".")
            let currentMajorMinor = currentPy.components(separatedBy: ".").prefix(2).joined(separator: ".")
            if !manifestMajorMinor.isEmpty, manifestMajorMinor != currentMajorMinor {
                return true
            }
        }

        // Check group package versions
        let expected = group.expectedVersions
        guard !expected.isEmpty else { return false }

        guard let recorded = manifest.groups[group.rawValue] else {
            return false  // Not recorded yet — not a drift, just first install
        }

        for (pkg, version) in expected {
            if recorded[pkg] != version {
                return true
            }
        }

        return false
    }

    private func destroyVenv(at directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        // Also remove the manifest
        if let url = try? manifestURL,
           FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func pythonVersion(python: URL) -> String? {
        let process = Process()
        process.executableURL = python
        process.arguments = ["--version"]
        process.environment = cleanEnvironment(python: python)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // "Python 3.12.3\n" → "3.12.3"
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "Python ", with: "")
        } catch {
            return nil
        }
    }

    private func installPackages(
        _ packages: [String],
        python: URL,
        log: @escaping @Sendable (String) -> Void,
        pipProgress: @escaping @Sendable (PipDownloadInfo) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "pip", "install", "--progress-bar=on"] + packages
        process.environment = cleanEnvironment(python: python)

        let stderr = Pipe()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Track current downloading package
        let state = PipParserState()
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
                // pip writes download progress to stderr
                if let info = Self.parsePipLine(trimmed, state: state) {
                    pipProgress(info)
                }
                log(trimmed)
            }
        }

        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let info = Self.parsePipLine(trimmed, state: state) {
                    pipProgress(info)
                }
                if trimmed.hasPrefix("Collecting") || trimmed.hasPrefix("Downloading") ||
                   trimmed.hasPrefix("Installing") || trimmed.hasPrefix("Successfully") {
                    log(trimmed)
                }
            }
        }

        try process.run()
        process.waitUntilExit()
        stderrHandle.readabilityHandler = nil
        stdoutHandle.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let errText = collectedStderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ResolverError.missingPath("pip install 失敗：\(errText)")
        }
    }

    // MARK: - Pip Output Parsing

    /// Parse pip output lines to extract download progress.
    /// pip outputs lines like:
    ///   "Collecting torch"
    ///   "Downloading torch-2.3.0-...-macosx_14_0_arm64.whl (62.4 MB)"
    ///   "   ━━━━━━━━━╸━━━━━━━━━━━   45.2/62.4 MB  12.3 MB/s  eta 0:00:01"
    ///   "Installing collected packages: torch, ..."
    ///   "Successfully installed torch-2.3.0 ..."
    private static func parsePipLine(_ line: String, state: PipParserState) -> PipDownloadInfo? {
        // "Collecting <package>"
        if line.hasPrefix("Collecting ") {
            let pkg = String(line.dropFirst("Collecting ".count).prefix(while: { !$0.isWhitespace }))
            state.currentPackage = pkg
            return PipDownloadInfo(packageName: pkg, downloadedBytes: 0, totalBytes: 0, status: "Collecting")
        }

        // "Downloading <filename> (<size>)"
        // e.g. "Downloading torch-2.3.0-cp312-cp312-macosx_14_0_arm64.whl (62.4 MB)"
        if line.hasPrefix("Downloading ") {
            let rest = String(line.dropFirst("Downloading ".count))
            let pkg = state.currentPackage ?? String(rest.prefix(while: { !$0.isWhitespace && $0 != "-" }))
            state.currentPackage = pkg

            // Extract total size from parentheses
            if let parenStart = rest.lastIndex(of: "("),
               let parenEnd = rest.lastIndex(of: ")") {
                let sizeStr = String(rest[rest.index(after: parenStart)..<parenEnd])
                let totalBytes = Self.parseSize(sizeStr)
                state.currentTotalBytes = totalBytes
                return PipDownloadInfo(packageName: pkg, downloadedBytes: 0, totalBytes: totalBytes, status: "Downloading")
            }
            return PipDownloadInfo(packageName: pkg, downloadedBytes: 0, totalBytes: 0, status: "Downloading")
        }

        // Progress bar line: "   ━━━━━━━━━╸━━━━━━━━━━━   45.2/62.4 MB  12.3 MB/s  eta 0:00:01"
        // Or: "   ━━━━━━━━━━━━━━━━━━━━━━  62.4/62.4 MB  15.0 MB/s  eta 0:00:00"
        if line.contains("━") || line.contains("╸") || line.contains("╺") {
            if let pkg = state.currentPackage {
                // Try to parse "X.X/Y.Y MB" pattern
                if let (downloaded, total) = Self.parseProgressFraction(line) {
                    state.currentTotalBytes = total
                    return PipDownloadInfo(packageName: pkg, downloadedBytes: downloaded, totalBytes: total, status: "Downloading")
                }
            }
            return nil
        }

        // "Installing collected packages: ..."
        if line.hasPrefix("Installing collected packages:") {
            state.currentPackage = nil
            state.currentTotalBytes = 0
            return PipDownloadInfo(packageName: "安裝中", downloadedBytes: 0, totalBytes: 0, status: "Installing")
        }

        // "Successfully installed ..."
        if line.hasPrefix("Successfully installed") {
            return PipDownloadInfo(packageName: "完成", downloadedBytes: 1, totalBytes: 1, status: "Done")
        }

        return nil
    }

    /// Parse size string like "62.4 MB", "1.2 GB", "450 kB" into bytes.
    private static func parseSize(_ str: String) -> Int64 {
        let parts = str.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return 0 }
        let unit = parts[1].uppercased()
        switch unit {
        case "KB": return Int64(value * 1_000)
        case "MB": return Int64(value * 1_000_000)
        case "GB": return Int64(value * 1_000_000_000)
        default: return Int64(value)
        }
    }

    /// Parse "45.2/62.4 MB" from a progress bar line.
    private static func parseProgressFraction(_ line: String) -> (downloaded: Int64, total: Int64)? {
        // Look for pattern like "45.2/62.4 MB" or "1.2/3.5 GB"
        let pattern = #"(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\s*(kB|MB|GB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 4 else { return nil }

        let downloadedStr = String(line[Range(match.range(at: 1), in: line)!])
        let totalStr = String(line[Range(match.range(at: 2), in: line)!])
        let unit = String(line[Range(match.range(at: 3), in: line)!])

        guard let downloadedVal = Double(downloadedStr),
              let totalVal = Double(totalStr) else { return nil }

        let multiplier: Double
        switch unit.uppercased() {
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        default: multiplier = 1
        }

        return (Int64(downloadedVal * multiplier), Int64(totalVal * multiplier))
    }
}

/// Mutable state for tracking pip's current download across lines.
private final class PipParserState: @unchecked Sendable {
    var currentPackage: String?
    var currentTotalBytes: Int64 = 0
}

/// Thread-safe collector for stderr output.
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
}

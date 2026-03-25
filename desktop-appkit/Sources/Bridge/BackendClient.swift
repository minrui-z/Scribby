import Foundation

struct BackendEvent {
    let name: String
    let data: [String: Any]
}

final class BackendClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var requestCounter: UInt64 = 1
    private var pending: [String: (Result<Any, Error>) -> Void] = [:]
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private(set) var isStarted = false

    var onEvent: ((BackendEvent) -> Void)?

    func start() throws {
        guard !isStarted else { return }

        let python = try PathResolver.pythonExecutable()
        let script = try PathResolver.backendScript()
        NativeLogger.log("Backend start: python=\(python.path)")
        NativeLogger.log("Backend start: script=\(script.path)")

        process.executableURL = python
        process.arguments = [script.path]
        process.currentDirectoryURL = PathResolver.desktopWorkingDirectory()
        process.environment = try PathResolver.backendEnvironment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] process in
            NativeLogger.log("Backend terminated: status=\(process.terminationStatus)")
            self?.emitEvent(name: "backend_error", data: [
                "message": "桌面 backend 已結束（status \(process.terminationStatus)）",
            ])
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }

        try process.run()
        isStarted = true
    }

    func shutdown() {
        guard isStarted else { return }
        send(command: "shutdown", args: [:]) { _ in }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if self.process.isRunning {
                self.process.terminate()
            }
        }
    }

    func sendAsync(command: String, args: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            send(command: command, args: args) { result in
                continuation.resume(with: result)
            }
        }
    }

    func send(command: String, args: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        let requestId: String = lock.withLock {
            defer { requestCounter += 1 }
            let id = String(requestCounter)
            pending[id] = completion
            return id
        }

        let payload: [String: Any] = [
            "kind": "command",
            "id": requestId,
            "command": command,
            "payload": args,
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            stdinPipe.fileHandleForWriting.write(data)
            stdinPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
        } catch {
            finish(requestId: requestId, result: .failure(error))
        }
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)

        while let range = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)
            handleStdoutLine(line)
        }
    }

    private func handleStdoutLine(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else {
            return
        }

        if kind == "response" {
            let requestId = object["request_id"] as? String ?? ""
            let ok = object["ok"] as? Bool ?? false
            if ok {
                finish(requestId: requestId, result: .success(object["result"] as Any))
            } else {
                let message = (object["error"] as? [String: Any])?["message"] as? String
                    ?? object["error"] as? String
                    ?? "未知錯誤"
                finish(
                    requestId: requestId,
                    result: .failure(NSError(domain: "BackendClient", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                )
            }
            return
        }

        if kind == "event",
           let name = object["event"] as? String {
            let data = object["data"] as? [String: Any] ?? object["payload"] as? [String: Any] ?? [:]
            emitEvent(name: name, data: data)
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)

        while let range = stderrBuffer.firstRange(of: Data([0x0A])) {
            let line = stderrBuffer.subdata(in: stderrBuffer.startIndex..<range.lowerBound)
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...range.lowerBound)
            guard let text = String(data: line, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            NativeLogger.log("backend stderr: \(text)")
            emitEvent(name: "backend_error", data: ["message": text])
        }
    }

    private func emitEvent(name: String, data: [String: Any]) {
        onEvent?(BackendEvent(name: name, data: data))
    }

    private func finish(requestId: String, result: Result<Any, Error>) {
        let callback = lock.withLock { pending.removeValue(forKey: requestId) }
        callback?(result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

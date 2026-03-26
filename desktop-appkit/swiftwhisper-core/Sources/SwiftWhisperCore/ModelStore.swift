import Foundation

public actor ModelStore {
    private let fileManager = FileManager.default
    private let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let environmentPath = ProcessInfo.processInfo.environment["SCRIBBY_SWIFTWHISPER_MODEL_DIR"],
                  !environmentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.baseDirectory = URL(fileURLWithPath: environmentPath, isDirectory: true)
        } else {
            self.baseDirectory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".models", isDirectory: true)
        }
    }

    public func ensureModel(named filename: String, remoteURL: URL) async throws -> URL {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            do {
                try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            } catch {
                throw SwiftWhisperCoreError.failedToCreateTempDirectory
            }
        }

        let destination = baseDirectory.appendingPathComponent(filename)
        let partialDestination = baseDirectory.appendingPathComponent(filename + ".downloading")

        // Clean up incomplete downloads from previous crash
        if fileManager.fileExists(atPath: partialDestination.path) {
            try? fileManager.removeItem(at: partialDestination)
        }

        if fileManager.fileExists(atPath: destination.path) {
            Diagnostics.log("swiftwhisper: using cached model \(destination.path)")
            return destination
        }

        Diagnostics.log("swiftwhisper: downloading model from \(remoteURL.absoluteString)")
        let localURL = try await downloadWithProgress(from: remoteURL, filename: filename)
        guard fileManager.fileExists(atPath: localURL.path) else {
            throw SwiftWhisperCoreError.modelDownloadFailed("下載檔案不存在")
        }

        do {
            // Move to .downloading first, then rename — atomic guarantee
            try? fileManager.removeItem(at: partialDestination)
            try fileManager.moveItem(at: localURL, to: partialDestination)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: partialDestination, to: destination)
            Diagnostics.log("swiftwhisper: model stored at \(destination.path)")
            return destination
        } catch {
            try? fileManager.removeItem(at: partialDestination)
            throw SwiftWhisperCoreError.modelDownloadFailed(error.localizedDescription)
        }
    }

    private func downloadWithProgress(from url: URL, filename: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(filename: filename, continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let filename: String
    private let continuation: CheckedContinuation<URL, Error>
    private var resumed = false
    private var lastLogTime: TimeInterval = 0
    private let throttleInterval: TimeInterval = 0.3

    init(filename: String, continuation: CheckedContinuation<URL, Error>) {
        self.filename = filename
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLogTime >= throttleInterval else { return }
        lastLogTime = now
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        Diagnostics.log("[DOWNLOAD] \(filename) \(totalBytesWritten) \(total)")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !resumed else { return }
        resumed = true

        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(URL(fileURLWithPath: filename).pathExtension)
        do {
            try FileManager.default.moveItem(at: location, to: tempCopy)
            Diagnostics.log("[DOWNLOAD] \(filename) done")
            continuation.resume(returning: tempCopy)
        } catch {
            continuation.resume(throwing: SwiftWhisperCoreError.modelDownloadFailed(error.localizedDescription))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !resumed else { return }
        resumed = true

        if let error {
            continuation.resume(throwing: SwiftWhisperCoreError.modelDownloadFailed(error.localizedDescription))
        } else if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation.resume(throwing: SwiftWhisperCoreError.modelDownloadFailed("HTTP \(http.statusCode)"))
        }
        session.finishTasksAndInvalidate()
    }
}

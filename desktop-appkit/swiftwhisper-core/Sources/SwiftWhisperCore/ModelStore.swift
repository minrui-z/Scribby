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
        if fileManager.fileExists(atPath: destination.path) {
            Diagnostics.log("swiftwhisper: using cached model \(destination.path)")
            return destination
        }

        Diagnostics.log("swiftwhisper: downloading model from \(remoteURL.absoluteString)")
        let (localURL, response) = try await URLSession.shared.download(from: remoteURL)
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else {
            throw SwiftWhisperCoreError.modelDownloadFailed("HTTP 回應無效")
        }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: localURL, to: destination)
            Diagnostics.log("swiftwhisper: model stored at \(destination.path)")
            return destination
        } catch {
            throw SwiftWhisperCoreError.modelDownloadFailed(error.localizedDescription)
        }
    }
}

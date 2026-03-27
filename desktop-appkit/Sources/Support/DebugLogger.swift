import Foundation

/// 將所有 debug log 寫入 App Support/debug-logs/ 下的獨立檔案。
/// 每次 app 啟動建立新檔案，最多保留 maxFiles 個，超過時刪除最舊的。
/// 每次寫入後立即 synchronizeFile()，確保 crash 也能保留 log。
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    private static let maxFiles = 5

    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.minrui.scribby.debug-log", qos: .utility)

    private init() {
        guard let dir = makeDirectory() else { return }
        rotate(in: dir)
        let url = newFileURL(in: dir)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        writeRaw("=== Session Start \(ISO8601DateFormatter().string(from: Date())) ===\n")
    }

    deinit {
        fileHandle?.closeFile()
    }

    /// 寫入一行 log，帶 HH:mm:ss.SSS 時間戳。crash-safe（每次 flush）。
    func write(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        queue.async { [weak self] in
            self?.writeRaw(line)
        }
    }

    // MARK: - Private

    private func writeRaw(_ text: String) {
        guard let fh = fileHandle,
              let data = text.data(using: .utf8) else { return }
        fh.write(data)
        fh.synchronizeFile()
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private func makeDirectory() -> URL? {
        guard let appSupport = try? PathResolver.appSupportDirectory() else { return nil }
        let dir = appSupport.appendingPathComponent("debug-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func rotate(in dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let sorted = contents
            .filter { $0.pathExtension == "log" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }

        // 保留 maxFiles-1 個舊檔，加上本次新建的 = maxFiles 個
        let excess = sorted.count - (Self.maxFiles - 1)
        guard excess > 0 else { return }
        sorted.prefix(excess).forEach { try? fm.removeItem(at: $0) }
    }

    private func newFileURL(in dir: URL) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return dir.appendingPathComponent("debug-\(f.string(from: Date())).log")
    }
}

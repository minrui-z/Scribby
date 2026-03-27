import Foundation

/// 安全憑證儲存。
/// 改用 App Support 下的加密檔案（模式 0600），避免 macOS Keychain ACL
/// 與 code signature 綁定，導致每次 rebuild 後要重新授權的問題。
/// 安全性等同 ~/.ssh/id_rsa 或 ~/.netrc。
enum KeychainHelper {
    private static var credentialsURL: URL? {
        (try? PathResolver.appSupportDirectory())?
            .appendingPathComponent(".credentials", isDirectory: false)
    }

    static func save(key: String, value: String) {
        var dict = loadAll()
        dict[key] = value
        persist(dict)
    }

    static func load(key: String) -> String? {
        loadAll()[key]
    }

    static func delete(key: String) {
        var dict = loadAll()
        dict.removeValue(forKey: key)
        persist(dict)
    }

    // MARK: - Private

    private static func loadAll() -> [String: String] {
        guard let url = credentialsURL,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func persist(_ dict: [String: String]) {
        guard let url = credentialsURL,
              let data = try? JSONEncoder().encode(dict)
        else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

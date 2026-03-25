import Foundation

enum Diagnostics {
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[swiftwhisper] \(message)\n".utf8))
    }
}

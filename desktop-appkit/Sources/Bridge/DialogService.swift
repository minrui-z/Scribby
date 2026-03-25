import AppKit
import UniformTypeIdentifiers

@MainActor
final class DialogService {
    weak var presentingWindow: NSWindow?

    func attach(window: NSWindow?) {
        presentingWindow = window
    }

    func pickAudioFiles() async -> [String] {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.message = "選取音訊檔"
            panel.prompt = "加入"
            panel.allowsMultipleSelection = true
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.resolvesAliases = true
            panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio, .aiff, .audio, .movie, .data, .mpeg4Movie]

            NativeLogger.log("DialogService: open audio picker")
            prepareForDialogPresentation()
            NativeLogger.log("DialogService: runModal audio picker")
            let paths = panel.runModal() == .OK ? panel.urls.map(\.path) : []
            NativeLogger.log("DialogService: picker finished count=\(paths.count)")
            continuation.resume(returning: paths)
        }
    }

    func pickSavePath(prompt: String, suggestedName: String) async -> String? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.message = prompt
            panel.prompt = "儲存"
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true

            NativeLogger.log("DialogService: open save panel prompt=\(prompt)")
            prepareForDialogPresentation()
            NativeLogger.log("DialogService: runModal save panel")
            let path = panel.runModal() == .OK ? panel.url?.path : nil
            NativeLogger.log("DialogService: save panel finished hasPath=\(path != nil)")
            continuation.resume(returning: path)
        }
    }

    private func resolvedWindow() -> NSWindow? {
        if let presentingWindow, presentingWindow.isVisible {
            return presentingWindow
        }
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow.isVisible {
            return mainWindow
        }
        return NSApp.windows.first { $0.isVisible }
    }

    private func prepareForDialogPresentation() {
        let window = resolvedWindow()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

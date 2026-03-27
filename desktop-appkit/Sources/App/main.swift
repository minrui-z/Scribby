import AppKit

@MainActor
final class NativeAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: NativeWindowController?
    private let model = NativeAppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeLogger.log("applicationDidFinishLaunching")
        NSApp.mainMenu = buildMainMenu()
        let controller = NativeWindowController(model: model)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController = controller
        model.bootstrap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NativeLogger.log("applicationWillTerminate")
        model.shutdown()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openSettingsAction):
            return true
        case #selector(openAudioFilesAction):
            return true
        case #selector(startTranscriptionAction):
            return model.canStart
        case #selector(togglePauseAction):
            if model.isProcessing {
                menuItem.title = "暫停"
                return true
            }
            if model.canResume {
                menuItem.title = "繼續"
                return true
            }
            menuItem.title = "暫停"
            return false
        case #selector(stopCurrentAction):
            return model.isProcessing && model.supportsHardStop
        case #selector(clearQueueAction):
            return !model.queueItems.isEmpty
        case #selector(showHelpAction):
            return true
        default:
            return true
        }
    }

    @objc private func showAboutAction() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openSettingsAction() {
        model.openSettings()
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAudioFilesAction() {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.presentAudioPicker()
    }

    @objc private func startTranscriptionAction() {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.startTranscription()
    }

    @objc private func togglePauseAction() {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.togglePause()
    }

    @objc private func stopCurrentAction() {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.stopCurrent()
    }

    @objc private func clearQueueAction() {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.clearQueue()
    }

    @objc private func showHelpAction() {
        guard let url = URL(string: "https://github.com/minrui-z/Scribby") else { return }
        NSWorkspace.shared.open(url)
    }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: ProcessInfo.processInfo.processName, action: nil, keyEquivalent: "")
        appMenuItem.submenu = buildAppMenu()
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem(title: "檔案", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = buildFileMenu()
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem(title: "編輯", action: nil, keyEquivalent: "")
        editMenuItem.submenu = buildEditMenu()
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "視窗", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = buildWindowMenu()
        mainMenu.addItem(windowMenuItem)

        let helpMenuItem = NSMenuItem(title: "說明", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = buildHelpMenu()
        mainMenu.addItem(helpMenuItem)

        return mainMenu
    }

    private func buildAppMenu() -> NSMenu {
        let title = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: title)
        menu.addItem(NSMenuItem(title: "關於 \(title)", action: #selector(showAboutAction), keyEquivalent: ""))
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "設定…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "隱藏 \(title)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let hideOthers = NSMenuItem(title: "隱藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "全部顯示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 \(title)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func buildFileMenu() -> NSMenu {
        let menu = NSMenu(title: "檔案")

        let openItem = NSMenuItem(title: "新增音訊檔案…", action: #selector(openAudioFilesAction), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let startItem = NSMenuItem(title: "開始轉譯", action: #selector(startTranscriptionAction), keyEquivalent: "r")
        startItem.target = self
        menu.addItem(startItem)

        let pauseItem = NSMenuItem(title: "暫停", action: #selector(togglePauseAction), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let stopItem = NSMenuItem(title: "停止目前檔案", action: #selector(stopCurrentAction), keyEquivalent: ".")
        stopItem.target = self
        menu.addItem(stopItem)

        let clearItem = NSMenuItem(title: "清除全部", action: #selector(clearQueueAction), keyEquivalent: "k")
        clearItem.keyEquivalentModifierMask = [.command, .shift]
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: "編輯")
        menu.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private func buildWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "視窗")
        menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "縮放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let fullScreenItem = NSMenuItem(title: "切換全螢幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreenItem)
        menu.addItem(withTitle: "全部移到最前", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }

    private func buildHelpMenu() -> NSMenu {
        let menu = NSMenu(title: "說明")
        let helpItem = NSMenuItem(title: "Scribby GitHub", action: #selector(showHelpAction), keyEquivalent: "?")
        helpItem.target = self
        menu.addItem(helpItem)
        return menu
    }
}

@main
struct ScribbyNativeMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = NativeAppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

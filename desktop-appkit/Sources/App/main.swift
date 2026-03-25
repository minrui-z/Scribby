import AppKit

@MainActor
final class NativeAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NativeWindowController?
    private let model = NativeAppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeLogger.log("applicationDidFinishLaunching")
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

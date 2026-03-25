import AppKit
import SwiftUI

final class NativeWindowController: NSWindowController {
    let model: NativeAppModel

    init(model: NativeAppModel) {
        self.model = model

        let contentRect = NSRect(x: 0, y: 0, width: 1210, height: 940)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "逐字搞定 Beta"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 940, height: 800)
        window.isReleasedWhenClosed = false

        let rootView = RootView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        window.contentViewController = hostingController
        model.attach(window: window)

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

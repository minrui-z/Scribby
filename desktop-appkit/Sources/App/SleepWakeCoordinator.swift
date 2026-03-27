import AppKit

@MainActor
final class SleepWakeCoordinator {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var workspaceObservers: [NSObjectProtocol] = []

    func start() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        let willSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onWillSleep?()
            }
        }

        let didWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onDidWake?()
            }
        }

        workspaceObservers = [willSleep, didWake]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }
}

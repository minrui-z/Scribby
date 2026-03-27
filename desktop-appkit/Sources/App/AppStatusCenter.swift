import Foundation
import SwiftUI

@MainActor
final class AppStatusCenter: ObservableObject {
    static let idleReadyMessage = "桌面版已就緒"

    @Published private(set) var pickerStatus = AppStatusCenter.idleReadyMessage
    @Published private(set) var pickerStatusTone: StatusTone = .neutral
    @Published private(set) var actionStatus = ""
    @Published private(set) var actionStatusTone: StatusTone = .neutral
    @Published private(set) var diagnosticLogLines: [String] = []
    @Published private(set) var floatingLines: [FloatingLineModel] = []

    private var pendingFloatingFragments: [String] = []
    private var floatingDrainTask: Task<Void, Never>?

    var visibleActionStatus: String? {
        guard !actionStatus.isEmpty else { return nil }
        if actionStatusTone == .error {
            return actionStatus
        }
        if actionStatus.contains("已刪除")
            || actionStatus.contains("已複製")
            || actionStatus.contains("已下載")
            || actionStatus.contains("已加入") {
            return actionStatus
        }
        return nil
    }

    var visiblePickerStatus: String? {
        guard !pickerStatus.isEmpty else { return nil }
        guard pickerStatus != Self.idleReadyMessage else { return nil }
        if pickerStatusTone == .error || pickerStatus.contains("已取消") {
            return pickerStatus
        }
        return nil
    }

    var shouldShowDiagnostics: Bool {
        actionStatusTone == .error && !diagnosticLogLines.isEmpty
    }

    func markReady() {
        setPickerStatus(Self.idleReadyMessage, tone: .success)
    }

    func resetToIdle(clearVisibleFloating: Bool = true) {
        stopFloatingTranscript(clearVisible: clearVisibleFloating)
        setPickerStatus(Self.idleReadyMessage, tone: .success)
        setActionStatus("", tone: .neutral)
    }

    func setPickerStatus(_ message: String, tone: StatusTone) {
        pickerStatus = message
        pickerStatusTone = tone
    }

    func setActionStatus(_ message: String, tone: StatusTone) {
        actionStatus = message
        actionStatusTone = tone
    }

    func appendDiagnosticLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        diagnosticLogLines.append(trimmed)
        while diagnosticLogLines.count > 8 {
            diagnosticLogLines.removeFirst()
        }
    }

    func addFloatingText(_ text: String) {
        let fragments = timedFragments(from: text)
        guard !fragments.isEmpty else { return }
        pendingFloatingFragments.append(contentsOf: fragments)
        if floatingDrainTask == nil {
            startFloatingDrainLoop()
        }
    }

    func stopFloatingTranscript(clearVisible: Bool) {
        pendingFloatingFragments.removeAll()
        floatingDrainTask?.cancel()
        floatingDrainTask = nil
        if clearVisible {
            floatingLines.removeAll()
        }
    }

    private func timedFragments(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: "，。！？；、,.!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func startFloatingDrainLoop() {
        floatingDrainTask?.cancel()
        floatingDrainTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if pendingFloatingFragments.isEmpty {
                    floatingDrainTask = nil
                    return
                }

                let next = pendingFloatingFragments.removeFirst()
                pushFloatingFragment(next)
                let backlog = pendingFloatingFragments.count
                let delayNs: UInt64
                switch backlog {
                case 12...:
                    delayNs = 110_000_000
                case 7...11:
                    delayNs = 170_000_000
                case 4...6:
                    delayNs = 230_000_000
                case 2...3:
                    delayNs = 290_000_000
                default:
                    delayNs = 340_000_000
                }
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
    }

    private func pushFloatingFragment(_ text: String) {
        let startX = CGFloat(Double.random(in: -120...120))
        let endX = startX + CGFloat(Double.random(in: -42...42))
        let riseDistance = CGFloat(Double.random(in: 260...360))
        let fontSize = CGFloat(Double.random(in: 17...21))
        let item = FloatingLineModel(
            text: text,
            startXOffset: startX,
            endXOffset: endX,
            riseDistance: riseDistance,
            fontSize: fontSize,
            delay: 0
        )
        floatingLines.append(item)
        let removeID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            guard let self else { return }
            self.floatingLines.removeAll { $0.id == removeID }
        }
        while floatingLines.count > 10 {
            floatingLines.removeFirst()
        }
    }
}

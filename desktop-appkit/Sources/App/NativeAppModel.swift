import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NativeAppModel: ObservableObject {
    @Published var queueItems: [QueueItemModel] = []
    @Published var isProcessing = false
    @Published var isPaused = false
    @Published var stopRequested = false
    @Published var currentFileId: String?
    @Published var supportsHardStop = false
    @Published var tokenVerified = false
    @Published var showSettings = false
    @Published var isDraggingFiles = false
    @Published var isFileImporterPresented = false
    @Published var diarizeEnabled = false
    @Published var enhancementEnabled = false
    @Published var speakers = 0
    @Published var token = ""
    @Published var tokenStatus = ""
    @Published var tokenStatusTone: StatusTone = .neutral
    @Published var pickerStatus = "桌面版已就緒"
    @Published var pickerStatusTone: StatusTone = .neutral
    @Published var actionStatus = ""
    @Published var actionStatusTone: StatusTone = .neutral
    @Published var diagnosticLogLines: [String] = []
    @Published var floatingLines: [FloatingLineModel] = []
    @Published private(set) var providerInfo: ProviderInfo?
    @Published var selectedModelPreset: WhisperModelPreset = .default

    private var provider: TranscriptionProvider
    private let dialogs: DialogService
    private weak var window: NSWindow?
    private var pendingFloatingFragments: [String] = []
    private var floatingDrainTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    convenience init() {
        self.init(
            provider: SwiftWhisperProvider(modelPreset: .default),
            dialogs: DialogService()
        )
    }

    init(
        provider: TranscriptionProvider,
        dialogs: DialogService
    ) {
        self.provider = provider
        self.dialogs = dialogs

        self.provider.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
    }

    var doneItems: [QueueItemModel] {
        queueItems.filter { ["done", "error", "stopped"].contains($0.status) }
    }

    var finishedResults: [QueueItemModel] {
        queueItems.filter { $0.status == "done" && $0.result != nil }
    }

    var canStart: Bool {
        queueItems.contains { !["done", "error", "stopped"].contains($0.status) } && !isProcessing
    }

    var canResume: Bool {
        isPaused && queueItems.contains { $0.status == "pending" }
    }

    var showCompactAddButton: Bool {
        isProcessing || isPaused
    }

    var showLiveHeader: Bool {
        isProcessing || isPaused
    }

    var currentProcessingItem: QueueItemModel? {
        guard let currentFileId else { return nil }
        return queueItems.first(where: { $0.fileId == currentFileId })
    }

    var batchNote: String {
        diarizeEnabled
            ? "已開啟語者辨識。這條路只走 pyannote 多語者 diarization，需要 HuggingFace Token。首次執行可能因模型下載而較久。"
            : "純 Swift 核心版支援單檔或批次順序轉譯，可安全暫停或停止目前檔案。"
    }

    func bootstrap() {
        NativeLogger.clear()
        NativeLogger.log("Native app bootstrap")
        do {
            try provider.start()
            Task {
                do {
                    try await provider.subscribeEvents()
                    let info = try await provider.getInfo()
                    providerInfo = info
                    applySnapshot(info.snapshot)
                    supportsHardStop = info.supportsHardStop
                    setPickerStatus("桌面版已就緒", tone: .success)
                    setActionStatus("SwiftWhisper 純 Swift 核心已就緒", tone: .success)
                    startObservingSystemSleep()
                } catch {
                    setActionStatus("啟動 backend 失敗: \(error.localizedDescription)", tone: .error)
                }
            }
        } catch {
            setPickerStatus("啟動 backend 失敗: \(error.localizedDescription)", tone: .error)
            setActionStatus("啟動 backend 失敗: \(error.localizedDescription)", tone: .error)
        }
    }

    func shutdown() {
        stopObservingSystemSleep()
        floatingDrainTask?.cancel()
        floatingDrainTask = nil
        provider.shutdown()
    }

    func attach(window: NSWindow?) {
        self.window = window
        dialogs.attach(window: window)
    }

    func toggleSettings() {
        withAnimation(.linear(duration: 0.22)) {
            showSettings.toggle()
        }
    }

    func closeSettings() {
        withAnimation(.easeInOut(duration: 0.28)) {
            showSettings = false
        }
    }

    func setWindowBackgroundMovable(_ movable: Bool) {
        window?.isMovableByWindowBackground = movable
    }

    func switchModel(to preset: WhisperModelPreset) {
        guard preset != selectedModelPreset else { return }
        guard !isProcessing else {
            setActionStatus("轉譯中無法切換模型", tone: .error)
            return
        }

        provider.shutdown()
        selectedModelPreset = preset

        let newProvider = SwiftWhisperProvider(modelPreset: preset)
        newProvider.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        self.provider = newProvider

        do {
            try provider.start()
            Task {
                let info = try await provider.getInfo()
                providerInfo = info
                setActionStatus("已切換到 \(preset.displayName)", tone: .success)
            }
        } catch {
            setActionStatus("切換模型失敗: \(error.localizedDescription)", tone: .error)
        }
    }

    func pickAudioFiles() {
        presentAudioPicker()
    }

    func presentAudioPicker() {
        setPickerStatus("正在開啟音訊檔案選取器...", tone: .neutral)
        isFileImporterPresented = true
    }

    func handleDroppedFiles(_ paths: [String]) {
        Task {
            await enqueue(paths: paths, sourceLabel: "拖放檔案")
        }
    }

    func handlePickedFiles(urls: [URL]) {
        isFileImporterPresented = false
        let paths = urls.map(\.path)
        guard !paths.isEmpty else {
            setPickerStatus("已取消選取音訊檔", tone: .neutral)
            return
        }
        Task {
            await enqueue(paths: paths, sourceLabel: "選取音訊檔")
        }
    }

    func handlePickerCancellation() {
        isFileImporterPresented = false
        setPickerStatus("已取消選取音訊檔", tone: .neutral)
    }

    func handlePickerFailure(_ message: String) {
        isFileImporterPresented = false
        setPickerStatus("選取音訊檔失敗: \(message)", tone: .error)
        setActionStatus("加入音訊檔案失敗: \(message)", tone: .error)
    }

    func verifyToken() {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            tokenVerified = false
            tokenStatus = "請先輸入 HuggingFace Token"
            tokenStatusTone = .error
            return
        }

        tokenStatus = "正在驗證 HuggingFace Token..."
        tokenStatusTone = .neutral
        Task {
            do {
                let result = try await provider.verifyToken(normalized)
                tokenVerified = result.ok
                tokenStatus = result.message
                tokenStatusTone = result.ok ? .success : .error
            } catch {
                tokenVerified = false
                tokenStatus = error.localizedDescription
                tokenStatusTone = .error
            }
        }
    }

    func startTranscription() {
        setActionStatus("正在啟動轉譯...", tone: .neutral)
        Task {
            do {
                let snapshot = try await provider.startTranscription(
                    TranscriptionRequest(
                        language: "zh",
                        diarize: diarizeEnabled,
                        speakers: speakers,
                        token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                        enhance: enhancementEnabled
                    )
                )
                applySnapshot(snapshot)
            } catch {
                setActionStatus("開始轉譯失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    func togglePause() {
        if isPaused {
            setActionStatus("正在恢復轉譯...", tone: .neutral)
        } else {
            setActionStatus("正在暫停目前佇列...", tone: .neutral)
        }
        Task {
            do {
                let snapshot = try await provider.setPaused(!isPaused)
                applySnapshot(snapshot)
            } catch {
                setActionStatus(error.localizedDescription, tone: .error)
            }
        }
    }

    func stopCurrent() {
        setActionStatus("正在停止目前檔案...", tone: .neutral)
        Task {
            do {
                let result = try await provider.stopCurrent()
                applySnapshot(result.snapshot)
                if !result.accepted {
                    setActionStatus(result.message, tone: .neutral)
                }
            } catch {
                setActionStatus(error.localizedDescription, tone: .error)
            }
        }
    }

    func clearQueue() {
        setActionStatus("", tone: .neutral)
        Task {
            do {
                let snapshot = try await provider.clearQueue()
                applySnapshot(snapshot)
                if snapshot.items.isEmpty {
                    stopFloatingTranscript(clearVisible: true)
                    isProcessing = false
                    isPaused = false
                    stopRequested = false
                    currentFileId = nil
                    setPickerStatus("桌面版已就緒", tone: .success)
                }
                setActionStatus("", tone: .neutral)
            } catch {
                setActionStatus("清除全部失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    func removeQueueItem(_ item: QueueItemModel) {
        Task {
            do {
                let snapshot = try await provider.removeQueueItem(fileId: item.fileId)
                applySnapshot(snapshot)
                if snapshot.items.isEmpty {
                    stopFloatingTranscript(clearVisible: true)
                    isProcessing = false
                    isPaused = false
                    stopRequested = false
                    currentFileId = nil
                    setPickerStatus("桌面版已就緒", tone: .success)
                    setActionStatus("", tone: .neutral)
                    return
                }
                setActionStatus("已刪除 \(item.filename)", tone: .success)
            } catch {
                setActionStatus("刪除失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    func saveResult(for item: QueueItemModel) {
        guard let result = item.result else { return }
        Task {
            do {
                let destination = try PathResolver.uniqueDownloadDestination(suggestedName: result.suggestedFilename)
                try await provider.saveResult(fileId: item.fileId, destinationPath: destination.path)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                setActionStatus("已下載：\(destination.lastPathComponent)", tone: .success)
                setPickerStatus("已在 Finder 顯示下載檔案", tone: .success)
            } catch {
                setActionStatus("下載失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    func copyResult(for item: QueueItemModel) {
        guard let result = item.result else { return }
        let body = result.segments.enumerated().map { index, segment in
            let order = String(format: "%02d", index + 1)
            let speakerPrefix = segment.speakerLabel.map { "\($0) · " } ?? ""
            return "[\(order)] \(speakerPrefix)\(formatTime(segment.startTimeMs)) - \(formatTime(segment.endTimeMs))\n\(segment.text)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        setActionStatus("已複製逐字稿內容", tone: .success)
    }

    func saveAllResults() {
        setActionStatus("純 Swift 核心版第一階段不支援全部匯出", tone: .error)
    }

    private func enqueue(paths: [String], sourceLabel: String) async {
        let normalized = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }

        setPickerStatus("", tone: .neutral)
        setActionStatus("正在把 \(normalized.count) 個音訊檔加入序列...", tone: .neutral)

        do {
            let snapshot = try await provider.enqueue(paths: normalized)
            applySnapshot(snapshot)
            setActionStatus("已加入 \(normalized.count) 個音訊檔", tone: .success)
        } catch {
            setPickerStatus("加入音訊檔案失敗: \(error.localizedDescription)", tone: .error)
            setActionStatus("加入音訊檔案失敗: \(error.localizedDescription)", tone: .error)
        }
    }

    private func handle(event: ProviderEvent) {
        switch event {
        case .backendReady(let info):
            providerInfo = info
            supportsHardStop = info.supportsHardStop
            applySnapshot(info.snapshot)
            setPickerStatus("桌面版已就緒", tone: .success)
        case .queueUpdated(let snapshot):
            applySnapshot(snapshot)
        case .queuePaused(let message):
            stopFloatingTranscript(clearVisible: true)
            setActionStatus(message, tone: .neutral)
        case .queueResumed(let message):
            setActionStatus(message, tone: .success)
        case .taskStarted(_, let filename):
            stopFloatingTranscript(clearVisible: true)
            setActionStatus("開始轉譯 \(filename)", tone: .neutral)
        case .taskProgress(_, let message, _):
            setActionStatus(message, tone: .neutral)
        case .taskLog(_, let message):
            appendDiagnosticLog(message)
        case .taskPartialText(_, let text):
            addFloatingText(text)
        case .taskCompleted(_, let filename, _):
            stopFloatingTranscript(clearVisible: true)
            setActionStatus("\(filename) 已完成", tone: .success)
        case .taskFailed(_, let message):
            stopFloatingTranscript(clearVisible: true)
            setActionStatus(message, tone: .error)
        case .taskStopped(_, let message):
            stopFloatingTranscript(clearVisible: true)
            setActionStatus(message, tone: .neutral)
        case .taskPhaseChanged(let fileId, let phase, let activePhases):
            if let idx = queueItems.firstIndex(where: { $0.fileId == fileId }) {
                queueItems[idx].phase = phase
                queueItems[idx].activePhases = activePhases
                queueItems[idx].downloadProgress = nil
            }
        case .taskDownloadProgress(let fileId, let info):
            if let idx = queueItems.firstIndex(where: { $0.fileId == fileId }) {
                queueItems[idx].downloadProgress = info
                if !queueItems[idx].activePhases.contains(.downloading) {
                    queueItems[idx].activePhases.insert(.downloading, at: 0)
                }
                queueItems[idx].phase = .downloading
            }
        case .backendError(let message):
            stopFloatingTranscript(clearVisible: true)
            setActionStatus(message, tone: .error)
        }
    }

    private func applySnapshot(_ snapshot: ProviderSnapshot) {
        let previousProcessing = isProcessing
        let previousCount = queueItems.count
        let previousDoneCount = doneItems.count
        let nextDoneCount = snapshot.items.filter { ["done", "error", "stopped"].contains($0.status) }.count
        let shouldAnimate =
            previousProcessing != snapshot.isProcessing ||
            previousCount != snapshot.items.count ||
            previousDoneCount != nextDoneCount ||
            currentFileId != snapshot.currentFileId

        let updateState = {
            self.queueItems = snapshot.items
            self.isProcessing = snapshot.isProcessing
            self.isPaused = snapshot.isPaused
            self.stopRequested = snapshot.stopRequested
            self.currentFileId = snapshot.currentFileId
            self.supportsHardStop = snapshot.supportsHardStop
        }

        if shouldAnimate {
            withAnimation(.easeInOut(duration: 0.28)) {
                updateState()
            }
        } else {
            updateState()
        }

        if !snapshot.isProcessing {
            stopFloatingTranscript(clearVisible: true)
        }
    }

    private func setPickerStatus(_ message: String, tone: StatusTone) {
        pickerStatus = message
        pickerStatusTone = tone
    }

    private func setActionStatus(_ message: String, tone: StatusTone) {
        actionStatus = message
        actionStatusTone = tone
    }

    private func startObservingSystemSleep() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        let willSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWillSleep()
            }
        }

        let didWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemDidWake()
            }
        }

        workspaceObservers = [willSleep, didWake]
    }

    private func stopObservingSystemSleep() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func handleSystemWillSleep() {
        guard isProcessing, !isPaused else { return }
        setActionStatus("系統即將睡眠，已自動暫停目前佇列", tone: .neutral)
        Task {
            do {
                let snapshot = try await provider.setPaused(true)
                applySnapshot(snapshot)
            } catch {
                setActionStatus("系統睡眠前自動暫停失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    private func handleSystemDidWake() {
        guard isPaused else { return }
        setActionStatus("已從睡眠恢復，請手動繼續", tone: .neutral)
    }

    private func appendDiagnosticLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        diagnosticLogLines.append(trimmed)
        while diagnosticLogLines.count > 8 {
            diagnosticLogLines.removeFirst()
        }
    }

    private func addFloatingText(_ text: String) {
        let fragments = timedFragments(from: text)
        guard !fragments.isEmpty else { return }
        pendingFloatingFragments.append(contentsOf: fragments)
        if floatingDrainTask == nil {
            startFloatingDrainLoop()
        }
    }

    private func stopFloatingTranscript(clearVisible: Bool) {
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
                if self.pendingFloatingFragments.isEmpty {
                    self.floatingDrainTask = nil
                    return
                }

                let next = self.pendingFloatingFragments.removeFirst()
                self.pushFloatingFragment(next)
                let backlog = self.pendingFloatingFragments.count
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

    private func formatTime(_ milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds / 1000, 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

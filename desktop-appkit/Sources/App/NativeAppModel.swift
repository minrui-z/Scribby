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

    private let provider: TranscriptionProvider
    private let dialogs: DialogService
    private var pendingFloatingFragments: [String] = []
    private var floatingDrainTask: Task<Void, Never>?

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

    var showCompactAddButton: Bool {
        isProcessing
    }

    var showLiveHeader: Bool {
        isProcessing
    }

    var currentProcessingItem: QueueItemModel? {
        guard let currentFileId else { return nil }
        return queueItems.first(where: { $0.fileId == currentFileId })
    }

    var batchNote: String {
        diarizeEnabled
            ? "已開啟語者辨識。這條路只走 pyannote 多語者 diarization，需要 HuggingFace Token。首次執行可能因模型下載而較久。"
            : "純 Swift 核心版第一階段支援單檔或批次順序轉譯，暫不支援暫停與停止。"
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
        floatingDrainTask?.cancel()
        floatingDrainTask = nil
        provider.shutdown()
    }

    func attach(window: NSWindow?) {
        dialogs.attach(window: window)
    }

    func toggleSettings() {
        withAnimation(.easeInOut(duration: 0.24)) {
            showSettings.toggle()
        }
    }

    func closeSettings() {
        withAnimation(.easeInOut(duration: 0.24)) {
            showSettings = false
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
                        token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
                applySnapshot(snapshot)
            } catch {
                setActionStatus("開始轉譯失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    func togglePause() {
        setActionStatus("純 Swift 核心版第一階段不支援暫停", tone: .error)
    }

    func stopCurrent() {
        setActionStatus("純 Swift 核心版第一階段不支援停止", tone: .error)
    }

    func clearQueue() {
        setActionStatus("", tone: .neutral)
        Task {
            do {
                let snapshot = try await provider.clearQueue()
                applySnapshot(snapshot)
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
            setActionStatus(message, tone: .error)
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

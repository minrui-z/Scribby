import AppKit
import Combine
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
    @Published var selectedLanguage: String = "auto"
    @Published var diarizeEnabled = false
    @Published var enhancementEnabled = false
    @Published var speakers = 0
    @Published var token = ""
    @Published var tokenStatus = ""
    @Published var tokenStatusTone: StatusTone = .neutral
    @Published private(set) var providerInfo: ProviderInfo?
    @Published var selectedModelPreset: WhisperModelPreset = .default

    private var provider: TranscriptionProvider
    private let dialogs: DialogService
    private weak var window: NSWindow?
    private let statusCenter = AppStatusCenter()
    private let sleepWakeCoordinator = SleepWakeCoordinator()
    private var statusObservation: AnyCancellable?

    var pickerStatus: String { statusCenter.pickerStatus }
    var pickerStatusTone: StatusTone { statusCenter.pickerStatusTone }
    var actionStatus: String { statusCenter.actionStatus }
    var actionStatusTone: StatusTone { statusCenter.actionStatusTone }
    var diagnosticLogLines: [String] { statusCenter.diagnosticLogLines }
    var floatingLines: [FloatingLineModel] { statusCenter.floatingLines }
    var visiblePickerStatus: String? { statusCenter.visiblePickerStatus }
    var visibleActionStatus: String? { statusCenter.visibleActionStatus }
    var shouldShowDiagnostics: Bool { statusCenter.shouldShowDiagnostics }
    var showPickerStatus: Bool { visiblePickerStatus != nil }
    var showActionStatus: Bool { visibleActionStatus != nil }
    var isIdleBannerVisible: Bool {
        !isProcessing && queueItems.isEmpty && !showPickerStatus && !showActionStatus
    }

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
        self.statusObservation = statusCenter.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sleepWakeCoordinator.onWillSleep = { [weak self] in
            self?.handleSystemWillSleep()
        }
        sleepWakeCoordinator.onDidWake = { [weak self] in
            self?.handleSystemDidWake()
        }

        self.provider.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
    }

    var doneItems: [QueueItemModel] {
        queueItems.filter { [.done, .error, .stopped].contains($0.status) }
    }

    var finishedResults: [QueueItemModel] {
        queueItems.filter { $0.status == .done && $0.result != nil }
    }

    var canStart: Bool {
        queueItems.contains { ![QueueItemStatus.done, .error, .stopped].contains($0.status) } && !isProcessing
    }

    var canResume: Bool {
        isPaused && queueItems.contains { $0.status == .pending }
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
                    let info = try await provider.getInfo()
                    providerInfo = info
                    applySnapshot(info.snapshot)
                    supportsHardStop = info.supportsHardStop
                    statusCenter.markReady()
                    statusCenter.setActionStatus("SwiftWhisper 純 Swift 核心已就緒", tone: .success)
                    sleepWakeCoordinator.start()
                } catch {
                    statusCenter.setActionStatus("啟動 backend 失敗: \(error.localizedDescription)", tone: .error)
                }
            }
        } catch {
            statusCenter.setPickerStatus("啟動 backend 失敗: \(error.localizedDescription)", tone: .error)
            statusCenter.setActionStatus("啟動 backend 失敗: \(error.localizedDescription)", tone: .error)
        }
    }

    func shutdown() {
        sleepWakeCoordinator.stop()
        statusCenter.stopFloatingTranscript(clearVisible: true)
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

    func openSettings() {
        guard !showSettings else { return }
        withAnimation(.linear(duration: 0.22)) {
            showSettings = true
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
            statusCenter.setActionStatus("轉譯中無法切換模型", tone: .error)
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
                statusCenter.setActionStatus("已切換到 \(preset.displayName)", tone: .success)
            }
        } catch {
            statusCenter.setActionStatus("切換模型失敗: \(error.localizedDescription)", tone: .error)
        }
    }

    func pickAudioFiles() {
        presentAudioPicker()
    }

    func presentAudioPicker() {
        statusCenter.setPickerStatus("正在開啟音訊檔案選取器...", tone: .neutral)
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
            statusCenter.setPickerStatus("已取消選取音訊檔", tone: .neutral)
            return
        }
        Task {
            await enqueue(paths: paths, sourceLabel: "選取音訊檔")
        }
    }

    func handlePickerCancellation() {
        isFileImporterPresented = false
        statusCenter.setPickerStatus("已取消選取音訊檔", tone: .neutral)
    }

    func handlePickerFailure(_ message: String) {
        isFileImporterPresented = false
        statusCenter.setPickerStatus("選取音訊檔失敗: \(message)", tone: .error)
        statusCenter.setActionStatus("加入音訊檔案失敗: \(message)", tone: .error)
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
        statusCenter.setActionStatus("正在啟動轉譯...", tone: .neutral)
        Task {
            do {
                let snapshot = try await provider.startTranscription(
                    TranscriptionRequest(
                        language: selectedLanguage,
                        diarize: diarizeEnabled,
                        speakers: speakers,
                        token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                        enhance: enhancementEnabled
                    )
                )
                applySnapshot(snapshot)
            } catch {
                statusCenter.setActionStatus("開始轉譯失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    func togglePause() {
        if isPaused {
            statusCenter.setActionStatus("正在恢復轉譯...", tone: .neutral)
        } else {
            statusCenter.setActionStatus("正在暫停目前佇列...", tone: .neutral)
        }
        Task {
            do {
                let snapshot = try await provider.setPaused(!isPaused)
                applySnapshot(snapshot)
            } catch {
                statusCenter.setActionStatus(error.localizedDescription, tone: .error)
            }
        }
    }

    func stopCurrent() {
        statusCenter.setActionStatus("正在停止目前檔案...", tone: .neutral)
        Task {
            do {
                let result = try await provider.stopCurrent()
                applySnapshot(result.snapshot)
                if !result.accepted {
                    statusCenter.setActionStatus(result.message, tone: .neutral)
                }
            } catch {
                statusCenter.setActionStatus(error.localizedDescription, tone: .error)
            }
        }
    }

    func clearQueue() {
        statusCenter.setActionStatus("", tone: .neutral)
        Task {
            do {
                let snapshot = try await provider.clearQueue()
                applySnapshot(snapshot)
                if snapshot.items.isEmpty {
                    isProcessing = false
                    isPaused = false
                    stopRequested = false
                    currentFileId = nil
                    statusCenter.resetToIdle()
                }
                statusCenter.setActionStatus("", tone: .neutral)
            } catch {
                statusCenter.setActionStatus("清除全部失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    func removeQueueItem(_ item: QueueItemModel) {
        Task {
            do {
                let snapshot = try await provider.removeQueueItem(fileId: item.fileId)
                applySnapshot(snapshot)
                if snapshot.items.isEmpty {
                    isProcessing = false
                    isPaused = false
                    stopRequested = false
                    currentFileId = nil
                    statusCenter.resetToIdle()
                    return
                }
                statusCenter.setActionStatus("已刪除 \(item.filename)", tone: .success)
            } catch {
                statusCenter.setActionStatus("刪除失敗: \(error.localizedDescription)", tone: .error)
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
                statusCenter.setActionStatus("已下載：\(destination.lastPathComponent)", tone: .success)
                statusCenter.setPickerStatus("已在 Finder 顯示下載檔案", tone: .success)
            } catch {
                statusCenter.setActionStatus("下載失敗: \(error.localizedDescription)", tone: .error)
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
        statusCenter.setActionStatus("已複製逐字稿內容", tone: .success)
    }

    private func enqueue(paths: [String], sourceLabel: String) async {
        let normalized = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }

        statusCenter.setPickerStatus("", tone: .neutral)
        statusCenter.setActionStatus("正在把 \(normalized.count) 個音訊檔加入序列...", tone: .neutral)

        do {
            let snapshot = try await provider.enqueue(paths: normalized)
            applySnapshot(snapshot)
            statusCenter.setActionStatus("已加入 \(normalized.count) 個音訊檔", tone: .success)
        } catch {
            statusCenter.setPickerStatus("加入音訊檔案失敗: \(error.localizedDescription)", tone: .error)
            statusCenter.setActionStatus("加入音訊檔案失敗: \(error.localizedDescription)", tone: .error)
        }
    }

    private func handle(event: ProviderEvent) {
        switch event {
        case .backendReady(let info):
            providerInfo = info
            supportsHardStop = info.supportsHardStop
            applySnapshot(info.snapshot)
            statusCenter.markReady()
        case .queueUpdated(let snapshot):
            applySnapshot(snapshot)
        case .queuePaused(let message):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.setActionStatus(message, tone: .neutral)
        case .queueResumed(let message):
            statusCenter.setActionStatus(message, tone: .success)
        case .taskStarted(_, let filename):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.setActionStatus("開始轉譯 \(filename)", tone: .neutral)
        case .taskProgress(_, let message, _):
            statusCenter.setActionStatus(message, tone: .neutral)
        case .taskLog(_, let message):
            statusCenter.appendDiagnosticLog(message)
        case .taskPartialText(_, let text):
            statusCenter.addFloatingText(text)
        case .taskCompleted(_, let filename, _):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.setActionStatus("\(filename) 已完成", tone: .success)
        case .taskFailed(_, let message):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.setActionStatus(message, tone: .error)
        case .taskStopped(_, let message):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.setActionStatus(message, tone: .neutral)
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
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.setActionStatus(message, tone: .error)
        }
    }

    private func applySnapshot(_ snapshot: ProviderSnapshot) {
        let previousProcessing = isProcessing
        let previousCount = queueItems.count
        let previousDoneCount = doneItems.count
        let nextDoneCount = snapshot.items.filter { [.done, .error, .stopped].contains($0.status) }.count
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
            statusCenter.stopFloatingTranscript(clearVisible: true)
        }
    }

    private func handleSystemWillSleep() {
        guard isProcessing, !isPaused else { return }
        statusCenter.setActionStatus("系統即將睡眠，已自動暫停目前佇列", tone: .neutral)
        Task {
            do {
                let snapshot = try await provider.setPaused(true)
                applySnapshot(snapshot)
            } catch {
                statusCenter.setActionStatus("系統睡眠前自動暫停失敗: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    private func handleSystemDidWake() {
        guard isPaused else { return }
        statusCenter.setActionStatus("已從睡眠恢復，請手動繼續", tone: .neutral)
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds / 1000, 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

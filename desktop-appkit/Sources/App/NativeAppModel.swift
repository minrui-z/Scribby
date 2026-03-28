import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum OnboardingWizardStep: Int, CaseIterable {
    case enhancement
    case model
    case diarization
    case proofreading
    case install

    var title: String {
        switch self {
        case .enhancement: return "人聲增強"
        case .model: return "轉寫模型"
        case .diarization: return "語者辨識"
        case .proofreading: return "AI 校稿"
        case .install: return "安裝與準備"
        }
    }
}

struct OnboardingSelection: Equatable {
    var enableEnhancement: Bool?
    var selectedModelPreset: WhisperModelPreset?
    var enableDiarization: Bool?
    var pendingDiarizationToken = ""
    var enableProofreading: Bool?
    var proofreadingMode: ProofreadingMode = .standard
}

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
    @Published var selectedLanguage: String = "auto" {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }
    @Published var diarizeEnabled = false {
        didSet { UserDefaults.standard.set(diarizeEnabled, forKey: "diarizeEnabled") }
    }
    @Published var enhancementEnabled = false {
        didSet { UserDefaults.standard.set(enhancementEnabled, forKey: "enhancementEnabled") }
    }
    @Published var speakers = 0 {
        didSet { UserDefaults.standard.set(speakers, forKey: "speakers") }
    }
    @Published var token = "" {
        didSet { KeychainHelper.save(key: "huggingface-token", value: token) }
    }
    @Published var tokenStatus = ""
    @Published var tokenStatusTone: StatusTone = .neutral
    @Published private(set) var providerInfo: ProviderInfo?
    @Published var selectedModelPreset: WhisperModelPreset = .default {
        didSet { UserDefaults.standard.set(selectedModelPreset.rawValue, forKey: "selectedModelPreset") }
    }
    @Published var showModelManager = false
    @Published var showOnboardingWizard = false
    @Published var onboardingStep: OnboardingWizardStep = .enhancement
    @Published var onboardingSelection = OnboardingSelection()
    @Published private(set) var isPreparingOnboardingChoices = false
    @Published var onboardingPreparationStatus = ""
    @Published var onboardingPreparationProgress = 0.0
    @Published var onboardingPreparationNotes: [String] = []
    @Published var onboardingTokenStatus = ""
    @Published var onboardingTokenStatusTone: StatusTone = .neutral
    @Published var isVerifyingOnboardingToken = false
    @Published private(set) var onboardingActivePreparationGroup: String?
    @Published private(set) var onboardingCompletedPreparationGroups: Set<String> = []
    @Published var proofreadingMode: ProofreadingMode = .off {
        didSet { UserDefaults.standard.set(proofreadingMode.rawValue, forKey: "proofreadingMode") }
    }

    private var provider: TranscriptionProvider
    private let dialogs: DialogService
    private weak var window: NSWindow?
    private let statusCenter = AppStatusCenter()
    private let sleepWakeCoordinator = SleepWakeCoordinator()
    private var statusObservation: AnyCancellable?
    private let firstRunWizardCompletedKey = "firstRunWizardCompleted"
    private let firstTranscriptionWarmupNoticePrefix = "firstTranscriptionWarmupNoticeShown."
    private var onboardingPreparationTotalSteps = 0
    private var onboardingPreparationCompletedGroups = Set<String>()
    private var onboardingRequiresEncoder = false

    var pickerStatus: String { statusCenter.pickerStatus }
    var pickerStatusTone: StatusTone { statusCenter.pickerStatusTone }
    var actionStatus: String { statusCenter.actionStatus }
    var actionStatusTone: StatusTone { statusCenter.actionStatusTone }
    var diagnosticLogLines: [String] { statusCenter.diagnosticLogLines }
    var floatingLines: [FloatingLineModel] { statusCenter.floatingLines }
    var proofreadingStreamLines: [ProofreadingStreamLineModel] { statusCenter.proofreadingStreamLines }
    var proofreadingLiveStatus: String { statusCenter.proofreadingLiveStatus }
    var isProofreadingStreaming: Bool { statusCenter.isProofreadingStreaming }
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

    var shouldShowFirstTranscriptionWarmupNotice: Bool {
        guard !isProcessing, canStart, selectedModelPreset.coreMLEncoderProvisioning != .none else { return false }
        return !UserDefaults.standard.bool(forKey: firstTranscriptionWarmupNoticeKey(for: selectedModelPreset))
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
        loadPersistedSettings()
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
                    presentOnboardingWizardIfNeeded()
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

    func verifyOnboardingToken() {
        let normalized = onboardingSelection.pendingDiarizationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            onboardingTokenStatus = "請先輸入 Hugging Face Token"
            onboardingTokenStatusTone = .error
            return
        }

        isVerifyingOnboardingToken = true
        onboardingTokenStatus = "validating"
        onboardingTokenStatusTone = .neutral

        Task {
            do {
                let result = try await provider.verifyToken(normalized)
                isVerifyingOnboardingToken = false
                onboardingTokenStatus = result.ok ? "success" : "failure"
                onboardingTokenStatusTone = result.ok ? .success : .error
            } catch {
                isVerifyingOnboardingToken = false
                onboardingTokenStatus = "failure"
                onboardingTokenStatusTone = .error
            }
        }
    }

    var canAdvanceCurrentOnboardingStep: Bool {
        switch onboardingStep {
        case .enhancement:
            return onboardingSelection.enableEnhancement != nil
        case .model:
            return onboardingSelection.selectedModelPreset != nil
        case .diarization:
            return onboardingSelection.enableDiarization != nil
        case .proofreading:
            return onboardingSelection.enableProofreading != nil
        case .install:
            return !isPreparingOnboardingChoices && onboardingPreparationProgress >= 1.0
        }
    }

    func startTranscription() {
        if shouldShowFirstTranscriptionWarmupNotice {
            UserDefaults.standard.set(true, forKey: firstTranscriptionWarmupNoticeKey(for: selectedModelPreset))
        }
        statusCenter.setActionStatus("正在啟動轉譯...", tone: .neutral)
        Task {
            do {
                let snapshot = try await provider.startTranscription(
                    TranscriptionRequest(
                        language: selectedLanguage,
                        diarize: diarizeEnabled,
                        speakers: speakers,
                        token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                        enhance: enhancementEnabled,
                        proofreadingMode: proofreadingMode
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

    func selectProofreadingMode(_ mode: ProofreadingMode) {
        guard mode != proofreadingMode else { return }
        proofreadingMode = mode
        if mode == .off {
            statusCenter.setActionStatus("已關閉 AI 校稿", tone: .neutral)
        } else {
            statusCenter.setActionStatus("已啟用 \(mode.displayName)", tone: .success)
        }
    }

    func goToNextOnboardingStep() {
        guard let next = OnboardingWizardStep(rawValue: onboardingStep.rawValue + 1),
              onboardingStep != .install,
              !isPreparingOnboardingChoices else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            onboardingStep = next
        }
    }

    func goToPreviousOnboardingStep() {
        guard let previous = OnboardingWizardStep(rawValue: onboardingStep.rawValue - 1),
              onboardingStep != .install,
              !isPreparingOnboardingChoices else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            onboardingStep = previous
        }
    }

    func beginOnboardingPreparation() {
        UserDefaults.standard.set(true, forKey: firstRunWizardCompletedKey)

        let selection = onboardingSelection
        let normalizedToken = selection.pendingDiarizationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEnhancement = selection.enableEnhancement ?? false
        let resolvedModel = selection.selectedModelPreset ?? .default
        let resolvedDiarization = selection.enableDiarization ?? false
        let resolvedProofreading = selection.enableProofreading ?? false

        enhancementEnabled = resolvedEnhancement
        diarizeEnabled = resolvedDiarization
        proofreadingMode = resolvedProofreading ? selection.proofreadingMode : .off
        if !normalizedToken.isEmpty {
            token = normalizedToken
        }

        if resolvedModel != selectedModelPreset {
            switchModel(to: resolvedModel)
        }

        let shouldPrepareModel = true
        let shouldPrepareEncoder = resolvedModel.coreMLEncoderProvisioning != .none
        let shouldPrepareEnhancement = resolvedEnhancement
        let shouldPrepareDiarization = resolvedDiarization && !normalizedToken.isEmpty
        let shouldPrepareProofreading = resolvedProofreading

        onboardingPreparationNotes = []
        if resolvedDiarization && normalizedToken.isEmpty {
            onboardingPreparationNotes.append("語者辨識已保留為稍後設定；補上 Hugging Face Token 後即可完成授權。")
        }
        onboardingPreparationNotes.append("高效能模型首次 Neural Engine 準備可能需要 2-3 分鐘。")
        onboardingRequiresEncoder = shouldPrepareEncoder
        onboardingPreparationTotalSteps = [
            shouldPrepareModel,
            shouldPrepareEnhancement,
            shouldPrepareDiarization,
            shouldPrepareProofreading,
        ].filter { $0 }.count
        onboardingPreparationCompletedGroups = []
        onboardingCompletedPreparationGroups = []
        onboardingActivePreparationGroup = nil
        onboardingPreparationProgress = onboardingPreparationTotalSteps == 0 ? 1.0 : 0.0
        onboardingPreparationStatus = "正在整理首次設定..."

        withAnimation(.easeInOut(duration: 0.22)) {
            onboardingStep = .install
        }

        guard shouldPrepareModel || shouldPrepareEnhancement || shouldPrepareDiarization || shouldPrepareProofreading else {
            isPreparingOnboardingChoices = false
            onboardingPreparationStatus = "首次設定已完成。之後可直接開始使用，也可在設定調整進階功能。"
            statusCenter.setActionStatus("首次設定已完成", tone: .success)
            return
        }

        isPreparingOnboardingChoices = true
        statusCenter.setActionStatus("正在準備首次設定...", tone: .neutral)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await provider.prepareAdvancedFeatures(
                    modelPreset: resolvedModel,
                    enhancement: shouldPrepareEnhancement,
                    diarization: shouldPrepareDiarization,
                    proofreading: shouldPrepareProofreading,
                    log: { [weak self] message in
                        Task { @MainActor in
                            guard let self else { return }
                            self.onboardingPreparationStatus = message
                            self.updateOnboardingPreparationProgress(with: message)
                            self.statusCenter.setActionStatus(message, tone: .neutral)
                        }
                    }
                )

                await MainActor.run {
                    self.isPreparingOnboardingChoices = false
                    self.onboardingPreparationProgress = 1.0
                    self.onboardingActivePreparationGroup = nil
                    self.onboardingPreparationStatus = "首次設定已完成。之後可直接開始使用，功能也可在設定調整。"
                    self.statusCenter.setActionStatus("首次設定已完成", tone: .success)
                }
            } catch {
                await MainActor.run {
                    self.isPreparingOnboardingChoices = false
                    self.onboardingActivePreparationGroup = nil
                    self.onboardingPreparationStatus = "準備失敗：\(error.localizedDescription)"
                    if self.onboardingPreparationNotes.last != self.onboardingPreparationStatus {
                        self.onboardingPreparationNotes.append(self.onboardingPreparationStatus)
                    }
                    self.statusCenter.setActionStatus("準備首次設定失敗: \(error.localizedDescription)", tone: .error)
                }
            }
        }
    }

    func completeOnboardingWizard() {
        UserDefaults.standard.set(true, forKey: firstRunWizardCompletedKey)
        withAnimation(.easeInOut(duration: 0.22)) {
            showOnboardingWizard = false
        }
    }

    func skipOnboardingWizard() {
        UserDefaults.standard.set(true, forKey: firstRunWizardCompletedKey)
        withAnimation(.easeInOut(duration: 0.22)) {
            showOnboardingWizard = false
        }
        statusCenter.setActionStatus("已略過首次設定，之後都可在設定調整。", tone: .neutral)
    }

    private func loadPersistedSettings() {
        let defaults = UserDefaults.standard
        if let lang = defaults.string(forKey: "selectedLanguage") {
            selectedLanguage = lang
        }
        diarizeEnabled = defaults.bool(forKey: "diarizeEnabled")
        enhancementEnabled = defaults.bool(forKey: "enhancementEnabled")
        speakers = defaults.integer(forKey: "speakers")
        if let savedToken = KeychainHelper.load(key: "huggingface-token"), !savedToken.isEmpty {
            token = savedToken
        }
        if let presetRaw = defaults.string(forKey: "selectedModelPreset"),
           let preset = WhisperModelPreset(rawValue: presetRaw),
           preset != selectedModelPreset {
            switchModel(to: preset)
        }
        if let modeRaw = defaults.string(forKey: "proofreadingMode"),
           let mode = ProofreadingMode(rawValue: modeRaw) {
            proofreadingMode = mode
        }
    }

    private func presentOnboardingWizardIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: firstRunWizardCompletedKey) else { return }

        onboardingSelection = OnboardingSelection(
            enableEnhancement: nil,
            selectedModelPreset: nil,
            enableDiarization: nil,
            pendingDiarizationToken: "",
            enableProofreading: nil,
            proofreadingMode: .standard
        )
        onboardingStep = .enhancement
        onboardingPreparationStatus = ""
        onboardingPreparationProgress = 0.0
        onboardingPreparationNotes = []
        onboardingTokenStatus = ""
        onboardingTokenStatusTone = .neutral
        isVerifyingOnboardingToken = false
        onboardingActivePreparationGroup = nil
        onboardingCompletedPreparationGroups = []

        withAnimation(.easeInOut(duration: 0.24)) {
            showOnboardingWizard = true
        }
    }

    private func updateOnboardingPreparationProgress(with message: String) {
        onboardingPreparationStatus = condensedOnboardingPreparationStatus(from: message)

        let modelStarts = ["正在下載 Whisper 模型", "正在準備 Core ML encoder"]
        let modelDone = ["Whisper 模型已就緒", "Core ML encoder 已就緒"]
        let proofreadingStarts = ["正在建立AI 校稿環境", "正在準備 AI 校稿模型", "正在載入 AI 校稿模型", "正在下載 AI 校稿模型"]
        let proofreadingDone = ["AI 校稿模型已就緒", "AI 校稿已就緒"]

        if modelStarts.contains(where: { message.contains($0) }) {
            onboardingActivePreparationGroup = "whisper"
        }
        if message.contains("正在建立人聲加強環境") {
            onboardingActivePreparationGroup = "enhancement"
        }
        if message.contains("正在建立語者辨識環境") {
            onboardingActivePreparationGroup = "diarization"
        }
        if proofreadingStarts.contains(where: { message.contains($0) }) {
            onboardingActivePreparationGroup = "proofreading"
        }

        if modelDone.contains(where: { message.contains($0) }) {
            if message.contains("Whisper 模型已就緒") {
                onboardingPreparationCompletedGroups.insert("model")
            }
            if message.contains("Core ML encoder 已就緒") {
                onboardingPreparationCompletedGroups.insert("encoder")
            }
            let whisperReady = onboardingPreparationCompletedGroups.contains("model")
                && (!onboardingRequiresEncoder || onboardingPreparationCompletedGroups.contains("encoder"))
            if whisperReady {
                onboardingCompletedPreparationGroups.insert("whisper")
                if onboardingActivePreparationGroup == "whisper" {
                    onboardingActivePreparationGroup = nil
                }
            }
        }

        if message.contains("人聲加強已就緒") {
            onboardingCompletedPreparationGroups.insert("enhancement")
            if onboardingActivePreparationGroup == "enhancement" {
                onboardingActivePreparationGroup = nil
            }
        }

        if message.contains("語者辨識已就緒") {
            onboardingCompletedPreparationGroups.insert("diarization")
            if onboardingActivePreparationGroup == "diarization" {
                onboardingActivePreparationGroup = nil
            }
        }

        if proofreadingDone.contains(where: { message.contains($0) }) {
            onboardingCompletedPreparationGroups.insert("proofreading")
            if onboardingActivePreparationGroup == "proofreading" {
                onboardingActivePreparationGroup = nil
            }
        }

        guard onboardingPreparationTotalSteps > 0 else {
            onboardingPreparationProgress = 1.0
            return
        }

        onboardingPreparationProgress = Double(onboardingPreparationCompletedGroups.count) / Double(onboardingPreparationTotalSteps)
    }

    private func firstTranscriptionWarmupNoticeKey(for preset: WhisperModelPreset) -> String {
        firstTranscriptionWarmupNoticePrefix + preset.rawValue
    }

    private func condensedOnboardingPreparationStatus(from message: String) -> String {
        if message.contains("正在下載 Whisper 模型") || message.contains("正在準備 Core ML encoder") {
            return "正在準備轉譯模型..."
        }
        if message.contains("Whisper 模型已就緒") || message.contains("Core ML encoder 已就緒") {
            return "轉譯模型已就緒"
        }
        if message.contains("正在建立人聲加強環境") {
            return "正在準備人聲增強..."
        }
        if message.contains("人聲加強已就緒") {
            return "人聲增強已就緒"
        }
        if message.contains("正在建立語者辨識環境") {
            return "正在準備語者辨識..."
        }
        if message.contains("語者辨識已就緒") {
            return "語者辨識已就緒"
        }
        if message.contains("正在建立AI 校稿環境")
            || message.contains("正在準備 AI 校稿模型")
            || message.contains("正在載入 AI 校稿模型")
            || message.contains("正在下載 AI 校稿模型") {
            return "正在準備 AI 校稿..."
        }
        if message.contains("AI 校稿模型已就緒") || message.contains("AI 校稿已就緒") {
            return "AI 校稿已就緒"
        }
        return "正在準備環境..."
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
            statusCenter.clearProofreadingStream()
            statusCenter.setActionStatus(message, tone: .neutral)
        case .queueResumed(let message):
            statusCenter.setActionStatus(message, tone: .success)
        case .taskStarted(_, let filename):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.clearProofreadingStream()
            statusCenter.setActionStatus("開始轉譯 \(filename)", tone: .neutral)
        case .taskProgress(_, let message, _):
            statusCenter.setActionStatus(message, tone: .neutral)
            if message.contains("AI 校稿") {
                statusCenter.updateProofreadingLiveStatus(message)
            }
        case .taskLog(_, let message):
            statusCenter.appendDiagnosticLog(message)
        case .taskPartialText(let fileId, let text):
            let itemPhase = queueItems.first(where: { $0.fileId == fileId })?.phase
            if itemPhase == .proofreading {
                statusCenter.appendProofreadingStreamLine(text)
            } else {
                statusCenter.addFloatingText(text)
            }
        case .taskCompleted(_, let filename, _):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.finishProofreadingStream(finalMessage: "AI 校稿完成")
            statusCenter.setActionStatus("\(filename) 已完成", tone: .success)
        case .taskFailed(_, let message):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.clearProofreadingStream()
            statusCenter.setActionStatus(message, tone: .error)
        case .taskStopped(_, let message):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.clearProofreadingStream()
            statusCenter.setActionStatus(message, tone: .neutral)
        case .taskPhaseChanged(let fileId, let phase, let activePhases):
            if let idx = queueItems.firstIndex(where: { $0.fileId == fileId }) {
                if phase == .proofreading {
                    statusCenter.stopFloatingTranscript(clearVisible: true)
                    statusCenter.beginProofreadingStream()
                }
                queueItems[idx].phase = phase
                queueItems[idx].activePhases = activePhases
                queueItems[idx].downloadProgress = nil
            }
        case .taskDownloadProgress(let fileId, let info):
            if let idx = queueItems.firstIndex(where: { $0.fileId == fileId }) {
                queueItems[idx].downloadProgress = info
            }
        case .backendError(let message):
            statusCenter.stopFloatingTranscript(clearVisible: true)
            statusCenter.clearProofreadingStream()
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

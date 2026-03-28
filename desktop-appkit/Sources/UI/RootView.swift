import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: NativeAppModel
    @State private var hoveredControlHint: HoverControlHint?
    private let primaryInk = Color(red: 0.16, green: 0.14, blue: 0.12)
    private let secondaryInk = Color(red: 0.34, green: 0.31, blue: 0.28)
    private let tokenURL = URL(string: "https://huggingface.co/settings/tokens")!

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                AmbientBackgroundView()

                VStack {
                    Spacer()
                    if model.isProofreadingStreaming {
                        ProofreadingStreamOverlay(
                            lines: model.proofreadingStreamLines,
                            liveStatus: model.proofreadingLiveStatus
                        )
                        .allowsHitTesting(false)
                        .padding(.bottom, 108)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        LiveStreamOverlay(lines: model.floatingLines)
                            .allowsHitTesting(false)
                            .padding(.bottom, 42)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.28), value: model.isProofreadingStreaming)

                VStack(spacing: 26) {
                    header(availableWidth: proxy.size.width)
                    content(availableHeight: proxy.size.height, availableWidth: proxy.size.width)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 44)
                .padding(.top, 42)
                .padding(.bottom, 26)
                .foregroundStyle(primaryInk)

                if model.showSettings {
                    settingsOverlay
                        .zIndex(3)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                        )
                }

                if model.showModelManager {
                    modelManagerOverlay
                        .zIndex(4)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if model.showOnboardingWizard {
                    onboardingWizardOverlay
                        .zIndex(5)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .fileImporter(
            isPresented: $model.isFileImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.handlePickedFiles(urls: urls)
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                    model.handlePickerCancellation()
                } else {
                    model.handlePickerFailure(error.localizedDescription)
                }
            }
        }
    }

    private func header(availableWidth: CGFloat) -> some View {
        let constrainedToQueue = !showResultsSection
        let queueAlignedWidth = initialColumnWidth(for: availableWidth)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: 18) {
                        headerBrandMark

                        VStack(alignment: .leading, spacing: 8) {
                            Text("逐字搞定 Beta")
                                .font(.system(size: 36, weight: .regular))
                                .tracking(-0.8)
                            Text("語音轉譯")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(secondaryInk)
                        }
                    }
                    .opacity(model.showLiveHeader ? 0 : 1)
                    .offset(y: model.showLiveHeader ? -16 : 0)

                    if model.showLiveHeader {
                        listeningPill
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: model.showLiveHeader ? 56 : 86,
                    alignment: .leading
                )

                headerChrome
            }

            if model.isPaused {
                Text("恢復後會重新開始目前檔案")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryInk)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !model.isProcessing,
               model.showActionStatus,
               let action = model.visibleActionStatus {
                Text(action)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(statusColor(model.actionStatusTone))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: constrainedToQueue ? queueAlignedWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: constrainedToQueue ? .center : .leading)
        .animation(.easeInOut(duration: 0.28), value: model.showLiveHeader)
    }

    private var headerBrandMark: some View {
        Group {
            if let path = Bundle.main.path(forResource: "AppIconSource", ofType: "png"),
               let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.55))
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(primaryInk)
                    )
            }
        }
        .frame(width: 70, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var listeningPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isPaused ? Color(red: 0.89, green: 0.63, blue: 0.12) : Color(red: 0.97, green: 0.35, blue: 0.31))
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke((model.isPaused ? Color(red: 0.89, green: 0.63, blue: 0.12) : Color(red: 0.97, green: 0.35, blue: 0.31)).opacity(0.34), lineWidth: 4)
                        .scaleEffect(1.15)
                )
            Text(model.isPaused ? "已暫停" : "正在聆聽…")
                .font(.system(size: 17, weight: .semibold))
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .glassCard(cornerRadius: 999, strokeOpacity: 0.24)
    }

    private var headerChrome: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.showCompactAddButton {
                PulsingAddButton {
                    model.pickAudioFiles()
                }
                .transition(.scale.combined(with: .opacity))
            }

            Button {
                model.toggleSettings()
            } label: {
                Text("設定")
            }
            .buttonStyle(GlassCapsuleButtonStyle())
        }
        .frame(height: model.showLiveHeader ? 56 : 86, alignment: .center)
        .fixedSize()
        .animation(.easeInOut(duration: 0.24), value: model.showCompactAddButton)
        .animation(.easeInOut(duration: 0.24), value: model.showLiveHeader)
    }

    private func content(availableHeight: CGFloat, availableWidth: CGFloat) -> some View {
        let stageHeight = contentStageHeight(for: availableHeight)
        let hasQueue = !model.queueItems.isEmpty
        return Group {
            if showResultsSection {
                if useTwoColumnResultsLayout(for: availableWidth) {
                    HStack(alignment: .top, spacing: 22) {
                        VStack(spacing: 18) {
                            dropZone(minHeight: resultsDropZoneHeight(for: stageHeight), compact: true)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                ))

                            queueSection(compact: true, showControls: true, showDiagnostics: false)
                                .frame(maxHeight: stageHeight - resultsDropZoneHeight(for: stageHeight) - 18, alignment: .top)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .leading).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        }
                        .frame(width: leftRailWidth(for: availableWidth), alignment: .top)

                        resultsSection(availableHeight: stageHeight)
                            .frame(maxWidth: .infinity)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        dropZone(minHeight: resultsDropZoneHeight(for: stageHeight), compact: true)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))

                        queueSection(compact: true, showControls: true, showDiagnostics: false)
                            .frame(maxHeight: compactQueueHeight(for: stageHeight), alignment: .top)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))

                        resultsSection(availableHeight: resultsHeightWhenStacked(for: stageHeight))
                            .frame(maxWidth: .infinity)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                    }
                }
            } else {
                primaryColumn(availableHeight: stageHeight, availableWidth: availableWidth, compactDropZone: hasQueue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(maxHeight: stageHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.30), value: model.doneItems.count)
        .animation(.easeInOut(duration: 0.30), value: model.isProcessing)
    }

    private func primaryColumn(availableHeight: CGFloat, availableWidth: CGFloat, compactDropZone: Bool) -> some View {
        let hasQueue = !model.queueItems.isEmpty
        let dense = useDensePrimaryLayout(for: availableHeight) || model.queueItems.count > 2
        let zoneHeight = primaryDropZoneHeight(for: availableHeight, compact: compactDropZone || hasQueue)
        let sharedWidth = initialColumnWidth(for: availableWidth)
        return VStack(spacing: 22) {
            if !model.isProcessing && !model.isPaused {
                dropZone(minHeight: zoneHeight, compact: compactDropZone || hasQueue)
                    .frame(maxWidth: sharedWidth, alignment: .leading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }

            if !model.queueItems.isEmpty {
                queueSection(compact: dense, showControls: true, showDiagnostics: false)
                    .frame(maxWidth: sharedWidth, alignment: .leading)
                    .frame(maxHeight: max(availableHeight - zoneHeight - 32, 220), alignment: .top)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .layoutPriority(1)
        .animation(.easeInOut(duration: 0.30), value: model.isProcessing)
        .animation(.easeInOut(duration: 0.30), value: showResultsSection)
    }

    private func dropZone(minHeight: CGFloat, compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 24) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.52))
                    .frame(width: compact ? 44 : 72, height: compact ? 44 : 72)
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: compact ? 18 : 30, weight: .semibold))
                    .foregroundStyle(primaryInk)
            }
            .frame(height: compact ? 44 : 72)

            VStack(spacing: compact ? 6 : 8) {
                Text("加入音訊檔案")
                    .font(.system(size: compact ? 18 : 28, weight: .bold))

                Text(model.isDraggingFiles
                     ? "放開滑鼠即可加入檔案"
                     : (compact ? "拖放或選取音訊檔" : "拖放音訊檔，或使用下方按鈕選取。"))
                    .font(.system(size: compact ? 13 : 17, weight: .medium))
                    .foregroundStyle(secondaryInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: compact ? 260 : 520)
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: compact ? 320 : 680)

            if model.showPickerStatus, let visiblePickerStatus = model.visiblePickerStatus {
                Text(visiblePickerStatus)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .foregroundStyle(statusColor(model.pickerStatusTone))
                    .transition(.opacity)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: compact ? 260 : 420)
            }

            if !compact {
                Text("支援 .m4a .wav .mp3 .flac")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryInk)
            }

            Button {
                model.presentAudioPicker()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    Text(compact ? "新增檔案" : "選取音訊檔")
                        .font(.system(size: compact ? 13 : 15, weight: .semibold))
                }
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .padding(.top, compact ? 0 : 2)
        }
        .padding(.horizontal, compact ? 22 : 36)
        .padding(.top, compact ? 24 : 42)
        .padding(.bottom, compact ? 18 : 32)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
        .surfaceCard(cornerRadius: 28, borderOpacity: model.isDraggingFiles ? 0.18 : 0.05)
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: model.isDraggingFiles ? 2 : 1, dash: [9, 7]))
                .foregroundStyle(model.isDraggingFiles ? Color.accentColor.opacity(0.74) : Color.white.opacity(0.5))
                .padding(10)
        )
        .scaleEffect(model.isDraggingFiles ? 1.01 : 1)
        .animation(.easeOut(duration: 0.18), value: model.isDraggingFiles)
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { model.isDraggingFiles },
            set: { model.isDraggingFiles = $0 }
        )) { providers in
            loadDroppedPaths(from: providers)
            return true
        }
    }

    private func queueSection(compact: Bool, showControls: Bool, showDiagnostics: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.vertical, showsIndicators: false) {
                if compact {
                    let columns = [
                        GridItem(.flexible(minimum: 0), spacing: 12),
                        GridItem(.flexible(minimum: 0), spacing: 12),
                    ]
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(model.queueItems.enumerated()), id: \.element.id) { index, item in
                            QueueRow(item: item, index: index + 1, compact: compact, onDelete: { model.removeQueueItem(item) })
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(model.queueItems.enumerated()), id: \.element.id) { index, item in
                            QueueRow(item: item, index: index + 1, compact: compact, onDelete: { model.removeQueueItem(item) })
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .frame(maxHeight: compact ? 240 : 340)

            if showControls {
                VStack(alignment: .leading, spacing: 10) {
                    if model.shouldShowFirstTranscriptionWarmupNotice {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bolt.horizontal.circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("首次轉譯會先準備高效能運算環境，開始時間會稍久。")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.32))
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    HStack(spacing: 12) {
                        if model.isPaused {
                            Button(action: model.togglePause) {
                                HStack {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("繼續")
                                }
                            }
                            .buttonStyle(PrimaryActionButtonStyle(enabled: model.canResume))
                            .disabled(!model.canResume)

                            Button("清除全部") {
                                model.clearQueue()
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .foregroundStyle(secondaryInk)
                            .disabled(model.queueItems.isEmpty)
                        } else if model.isProcessing {
                            Button(action: model.togglePause) {
                                HStack {
                                    Image(systemName: "pause.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("暫停")
                                }
                            }
                            .buttonStyle(PrimaryActionButtonStyle(enabled: true))
                            .onHover { isHovering in
                                withAnimation(.easeOut(duration: 0.16)) {
                                    hoveredControlHint = isHovering ? .pause : nil
                                }
                            }

                            Button("停止") {
                                model.stopCurrent()
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .foregroundStyle(secondaryInk)
                            .disabled(!model.supportsHardStop)
                            .onHover { isHovering in
                                withAnimation(.easeOut(duration: 0.16)) {
                                    hoveredControlHint = isHovering ? .stop : nil
                                }
                            }
                        } else {
                            Button(action: model.startTranscription) {
                                HStack {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("開始轉譯")
                                }
                            }
                            .buttonStyle(PrimaryActionButtonStyle(enabled: model.canStart))
                            .disabled(!model.canStart)

                            Button("清除全部") {
                                model.clearQueue()
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .foregroundStyle(secondaryInk)
                            .disabled(model.queueItems.isEmpty || model.isProcessing)
                        }
                    }
                    .overlay(alignment: .top) {
                        if let text = hoveredControlHintText {
                            HoverHintBubble(text: text)
                                .offset(y: -48)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if showDiagnostics && model.shouldShowDiagnostics {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("診斷輸出")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(secondaryInk)
                        Spacer()
                        Text("即時")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(secondaryInk)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.diagnosticLogLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(primaryInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.62))
                    )
                }
                .transition(.opacity)
            }
        }
        .padding(compact ? 22 : 26)
        .surfaceCard(cornerRadius: 28, borderOpacity: 0.05)
        .animation(.easeInOut(duration: 0.24), value: queueAnimationSignature)
        .animation(.easeInOut(duration: 0.20), value: model.actionStatus)
    }

    private func resultsSection(availableHeight: CGFloat) -> some View {
        let containerHeight = max(availableHeight, 320)
        return GeometryReader { proxy in
            let visibleHeight = max(proxy.size.height, containerHeight)
            let resultCount = max(model.doneItems.count, 1)
            let resultCardHeight = resolvedResultCardHeight(
                viewportHeight: visibleHeight,
                itemCount: resultCount,
                cardSpacing: 16
            )
            let resultContentHeight = resolvedResultContentHeight(cardHeight: resultCardHeight)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    ForEach(model.doneItems) { item in
                        ResultCard(
                            item: item,
                            cardHeight: resultCardHeight,
                            contentViewportHeight: resultContentHeight,
                            onCopy: { model.copyResult(for: item) },
                            onSave: { model.saveResult(for: item) }
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: visibleHeight, alignment: .top)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(24)
        .surfaceCard(cornerRadius: 24, borderOpacity: 0.06)
    }

    private var settingsOverlay: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.003)
                .ignoresSafeArea()
                .onTapGesture {
                    model.closeSettings()
                }
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("設定")
                            .font(.system(size: 26, weight: .bold))
                        Text("語者辨識與模型")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(secondaryInk)
                    }
                    Spacer()
                    Button("×") {
                        model.closeSettings()
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .font(.system(size: 24, weight: .regular))
                }
                .padding(.bottom, 22)

                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {

                settingsCard {
                    Toggle(isOn: $model.diarizeEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("啟用語者辨識")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(primaryInk)
                            Text("開啟後會在轉譯完成後辨識不同說話者。")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(secondaryInk)
                        }
                    }
                    .toggleStyle(.switch)
                    .modifier(WindowDragBlocker(model: model))
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hugging Face Token")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(primaryInk)
                        Text("只在顯示不同說話者時需要。先開啟語者辨識，再貼上 token。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PasteFriendlyTokenField(
                        text: $model.token,
                        placeholder: "先開啟語者辨識，再貼上 Token",
                        isEnabled: model.diarizeEnabled
                    )
                    .frame(height: 30)
                    .disabled(!model.diarizeEnabled)

                    HStack(alignment: .center, spacing: 10) {
                        Button("驗證 Token") {
                            model.verifyToken()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .frame(width: 108)
                        .disabled(!model.diarizeEnabled || model.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("取得 Token") {
                            NSWorkspace.shared.open(tokenURL)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .frame(width: 108)

                        Spacer(minLength: 0)

                        if model.tokenVerified {
                            Text("已驗證")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(red: 0.14, green: 0.53, blue: 0.24))
                        }
                    }

                    Text("先建立 Access Token，並確認 pyannote 模型頁面已完成授權。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(model.diarizeEnabled ? 1 : 0.72)
                .scaleEffect(model.diarizeEnabled ? 1 : 0.985)
                .animation(.easeInOut(duration: 0.22), value: model.diarizeEnabled)

                settingsCard {
                    Text("轉譯模型")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryInk)

                    Text("切換後首次使用會自動下載模型。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryInk)

                    ForEach(WhisperModelPreset.allCases, id: \.rawValue) { preset in
                        Button {
                            model.switchModel(to: preset)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.selectedModelPreset == preset ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(model.selectedModelPreset == preset ? Color.accentColor : secondaryInk)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.displayName)
                                        .font(.system(size: 13, weight: model.selectedModelPreset == preset ? .bold : .medium))
                                        .foregroundStyle(primaryInk)
                                    Text(preset.sizeHint)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(secondaryInk)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isProcessing)
                    }

                    if !model.tokenStatus.isEmpty {
                        Text(model.tokenStatus)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(statusColor(model.tokenStatusTone))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                settingsCard {
                    Text("轉譯語言")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryInk)
                    Text("選擇音訊的語言，或讓模型自動偵測。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryInk)

                    let languageOptions: [(code: String, label: String)] = [
                        ("auto", "自動偵測"),
                        ("zh", "中文"),
                        ("en", "English"),
                        ("ja", "日本語"),
                        ("ko", "한국어"),
                        ("es", "Español"),
                        ("fr", "Français"),
                        ("de", "Deutsch"),
                    ]
                    ForEach(languageOptions, id: \.code) { option in
                        Button {
                            model.selectedLanguage = option.code
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.selectedLanguage == option.code ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(model.selectedLanguage == option.code ? Color.accentColor : secondaryInk)
                                Text(option.label)
                                    .font(.system(size: 13, weight: model.selectedLanguage == option.code ? .bold : .medium))
                                    .foregroundStyle(primaryInk)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isProcessing)
                    }
                }

                settingsCard {
                    Toggle(isOn: $model.enhancementEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("啟用人聲加強（beta）")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(primaryInk)
                            Text("轉譯前先降噪增清，適合嘈雜環境錄音。會增加前處理時間。")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(secondaryInk)
                        }
                    }
                    .toggleStyle(.switch)
                    .modifier(WindowDragBlocker(model: model))
                }

                settingsCard {
                    Text("AI 校稿（beta）")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryInk)
                    Text("轉譯完成後用本地 AI 模型校正文字。若已在首次功能準備頁啟用，會先把執行環境準備好；模型會在第一次實際使用時下載，需要 Apple Silicon。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(ProofreadingMode.allCases, id: \.rawValue) { mode in
                        Button {
                            model.selectProofreadingMode(mode)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.proofreadingMode == mode
                                    ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(model.proofreadingMode == mode ? Color.accentColor : secondaryInk)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.displayName)
                                        .font(.system(size: 13, weight: model.proofreadingMode == mode ? .bold : .medium))
                                        .foregroundStyle(primaryInk)
                                    if mode != .off {
                                        Text(mode.description)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(secondaryInk)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isProcessing)
                    }
                }

                settingsCard(tinted: false) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            model.showModelManager = true
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 15, weight: .medium))
                            Text("資料管理")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(secondaryInk)
                        }
                        .foregroundStyle(primaryInk)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                settingsCard(tinted: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("軟體資訊")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(primaryInk)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scribby Beta")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(primaryInk)
                            Text(appVersionLine)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(secondaryInk)
                        }

                        Text("桌面版本地執行，音訊不會離開您的電腦。轉譯、語者辨識、人聲加強與 AI 校稿都在本機完成；首次使用相關功能時，模型與執行環境會下載到 Application Support，Core ML encoder 也可能在本機編譯，不會打包進 app 本體。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Designed and developed by 莊旻叡")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                }
                }
            }
            .padding(24)
            .frame(width: 340)
            .frame(maxHeight: .infinity, alignment: .top)
            .foregroundStyle(primaryInk)
            .drawerGlass(cornerRadius: 28)
            .padding(.top, 84)
            .padding(.bottom, 26)
            .padding(.trailing, 24)
            .shadow(color: Color(red: 0.28, green: 0.20, blue: 0.12).opacity(0.05), radius: 18, x: -4, y: 6)
        }
        .animation(.easeInOut(duration: 0.28), value: model.showSettings)
        .animation(.easeInOut(duration: 0.22), value: model.showModelManager)
    }

    private var modelManagerOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.showModelManager = false
                    }
                }

            ModelManagerSheet {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.showModelManager = false
                }
            }
            .onTapGesture {
                // Swallow taps so background dismissal only happens outside the panel.
            }
        }
    }

    private var onboardingWizardOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            OnboardingWizardSheet(
                model: model,
                tokenURL: tokenURL
            )
        }
    }

    private func settingsCard<Content: View>(
        tinted: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(tinted ? 0.32 : 0.24))
        )
    }

    private var appVersionLine: String {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Beta"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? shortVersion
        return "版本 \(shortVersion)（build \(build)）"
    }

    private func loadDroppedPaths(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var paths: [String] = []
        let lock = NSLock()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? {
                    lock.lock()
                    paths.append(url.path)
                    lock.unlock()
                    return
                }
                if let url = item as? URL {
                    lock.lock()
                    paths.append(url.path)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if !paths.isEmpty {
                model.handleDroppedFiles(paths)
            }
        }
    }

    private func statusColor(_ tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .success: return Color(red: 0.14, green: 0.53, blue: 0.24)
        case .error: return Color(red: 0.74, green: 0.20, blue: 0.16)
        }
    }

    private var queueAnimationSignature: String {
        model.queueItems.map { "\($0.id):\($0.status):\($0.progress)" }.joined(separator: "|")
    }

    private var hoveredControlHintText: String? {
        switch hoveredControlHint {
        case .pause:
            return "會在目前段落停下，恢復後從該段繼續"
        case .stop:
            return "會停止目前檔案，本次不會自動繼續"
        case .none:
            return nil
        }
    }

    private var showResultsSection: Bool {
        !model.isProcessing && !model.doneItems.isEmpty
    }

    private func useTwoColumnResultsLayout(for availableWidth: CGFloat) -> Bool {
        availableWidth >= 780 && dynamicTypeSize < .accessibility1
    }

    private func resultsScrollHeight(for availableHeight: CGFloat) -> CGFloat {
        let reservedHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 360 : 320
        return availableHeight - reservedHeight
    }

    private func contentStageHeight(for availableHeight: CGFloat) -> CGFloat {
        let reserved: CGFloat = dynamicTypeSize.isAccessibilitySize ? 260 : 220
        return max(availableHeight - reserved, 420)
    }

    private func primaryDropZoneHeight(for availableHeight: CGFloat, compact: Bool) -> CGFloat {
        if compact {
            if availableHeight < 560 { return 140 }
            if availableHeight < 680 { return 152 }
            return 164
        }
        if availableHeight < 560 { return 190 }
        if availableHeight < 680 { return 220 }
        if availableHeight < 780 { return 250 }
        return 300
    }

    private func resultsDropZoneHeight(for availableHeight: CGFloat) -> CGFloat {
        if availableHeight < 560 { return 176 }
        if availableHeight < 700 { return 188 }
        return 200
    }

    private func useDensePrimaryLayout(for availableHeight: CGFloat) -> Bool {
        availableHeight < 620 || model.queueItems.count > 3
    }

    private func compactQueueHeight(for availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.34, 240), 360)
    }

    private func resultsHeightWhenStacked(for availableHeight: CGFloat) -> CGFloat {
        max(availableHeight - compactQueueHeight(for: availableHeight) - 24, 260)
    }

    private func leftRailWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.37, 360), 430)
    }

    private func initialColumnWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.82, 760), 1020)
    }

    private func resolvedResultCardHeight(viewportHeight: CGFloat, itemCount: Int, cardSpacing: CGFloat) -> CGFloat {
        switch itemCount {
        case 1:
            return max(min(viewportHeight - 8, 560), 400)
        case 2:
            return max(min((viewportHeight - cardSpacing - 4) / 2, 296), 220)
        default:
            return 248
        }
    }

    private func resolvedResultContentHeight(cardHeight: CGFloat) -> CGFloat {
        let reservedChrome: CGFloat = 146
        return max(min(cardHeight * 0.52, cardHeight - reservedChrome), 144)
    }

}

private enum HoverControlHint {
    case pause
    case stop
}

private struct HoverHintBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240)
            .allowsHitTesting(false)
            .shadow(color: Color.black.opacity(0.16), radius: 12, x: 0, y: 6)
    }
}

private struct OnboardingWizardSheet: View {
    @ObservedObject var model: NativeAppModel
    let tokenURL: URL

    private let primaryInk = Color(red: 0.16, green: 0.14, blue: 0.12)
    private let secondaryInk = Color(red: 0.34, green: 0.31, blue: 0.28)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Group {
                switch model.onboardingStep {
                case .enhancement:
                    enhancementStep
                case .model:
                    modelStep
                case .diarization:
                    diarizationStep
                case .proofreading:
                    proofreadingStep
                case .install:
                    installStep
                }
            }

            footer
        }
        .padding(24)
        .frame(width: 620, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.10), radius: 24, x: 0, y: 14)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: model.onboardingStep)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: model.onboardingSelection)
        .animation(.easeInOut(duration: 0.24), value: model.onboardingPreparationProgress)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(OnboardingWizardStep.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step.rawValue <= model.onboardingStep.rawValue ? Color.accentColor.opacity(step == model.onboardingStep ? 0.95 : 0.36) : secondaryInk.opacity(0.18))
                        .frame(height: 6)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("首次使用設定")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(primaryInk)
                Text("第 \(model.onboardingStep.rawValue + 1) 步，共 \(OnboardingWizardStep.allCases.count) 步 · \(model.onboardingStep.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("相關功能皆在本機執行，音訊不會離開電腦。完成選擇後，系統會依設定開始準備環境。")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enhancementStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("是否開啟人聲增強？")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(primaryInk)

            Text("人聲增強會在轉譯前先做降噪與增清，對嘈雜環境、收音偏小或背景有雜音的錄音通常有幫助。代價是會多一段前處理時間。")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                booleanChoiceCard(
                    isSelected: model.onboardingSelection.enableEnhancement == false,
                    title: "暫不開啟",
                    detail: "直接開始轉譯，速度最快，適合收音本來就很乾淨的音檔。"
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        model.onboardingSelection.enableEnhancement = false
                    }
                }

                booleanChoiceCard(
                    isSelected: model.onboardingSelection.enableEnhancement == true,
                    title: "開啟人聲增強",
                    detail: "會先做前處理，通常能提升吵雜錄音的可辨識度；短檔會多幾秒，長檔會依音檔長度增加。"
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        model.onboardingSelection.enableEnhancement = true
                    }
                }
            }
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("預設使用哪個模型？")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(primaryInk)

            Text("之後仍可在設定切換，這裡只決定初始預設。")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(secondaryInk)

            VStack(spacing: 12) {
                ForEach(WhisperModelPreset.allCases, id: \.rawValue) { preset in
                    Button {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                            model.onboardingSelection.selectedModelPreset = preset
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: model.onboardingSelection.selectedModelPreset == preset ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(model.onboardingSelection.selectedModelPreset == preset ? Color.accentColor : secondaryInk)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(preset.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(primaryInk)
                                    if let badge = preset.onboardingBadge {
                                        Text(badge)
                                            .font(.system(size: 11, weight: .bold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text("\(preset.sizeHint) · \(preset.onboardingDescription)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(secondaryInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(choiceBackground(isSelected: model.onboardingSelection.selectedModelPreset == preset))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var diarizationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("是否開啟語者辨識？")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(primaryInk)

            Text("語者辨識可區分不同說話者，例如「說話者 1 / 說話者 2」。需要 Hugging Face Token 來取得 pyannote 授權。")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                booleanChoiceCard(
                    isSelected: model.onboardingSelection.enableDiarization == false,
                    title: "暫不開啟",
                    detail: "先用一般逐字稿，之後隨時可在設定補開。"
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        model.onboardingSelection.enableDiarization = false
                    }
                }

                booleanChoiceCard(
                    isSelected: model.onboardingSelection.enableDiarization == true,
                    title: "開啟語者辨識",
                    detail: "適合多人對話、會議或訪談。Token 只是取得授權，不會有任何費用，資料也不會傳上去。"
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        model.onboardingSelection.enableDiarization = true
                    }
                }
            }

            if model.onboardingSelection.enableDiarization == true {
                VStack(alignment: .leading, spacing: 10) {
                    Text("如何拿到 Token")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryInk)
                    Text("1. 到 Hugging Face 建立 Access Token。\n2. 到 pyannote 模型頁完成授權。\n3. 將 Token 貼回此處即可。也可先略過，之後再補。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("貼上 Hugging Face Token（可先略過）", text: $model.onboardingSelection.pendingDiarizationToken)
                        .textFieldStyle(.plain)
                        .foregroundStyle(primaryInk)
                        .tint(primaryInk)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.75))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                                )
                        )
                        .onChange(of: model.onboardingSelection.pendingDiarizationToken) { _ in
                            if model.onboardingSelection.pendingDiarizationToken.count > 96 {
                                model.onboardingSelection.pendingDiarizationToken = String(model.onboardingSelection.pendingDiarizationToken.prefix(96))
                            }
                            model.onboardingTokenStatus = ""
                            model.onboardingTokenStatusTone = .neutral
                        }

                    HStack(spacing: 10) {
                        Button {
                            model.verifyOnboardingToken()
                        } label: {
                            HStack(spacing: 8) {
                                if model.isVerifyingOnboardingToken {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                                Text(tokenVerificationButtonTitle)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(tokenVerificationButtonColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(tokenVerificationButtonColor.opacity(0.22), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.onboardingSelection.pendingDiarizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(model.onboardingSelection.pendingDiarizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)

                        Button("取得 Token") {
                            NSWorkspace.shared.open(tokenURL)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())

                        Spacer(minLength: 0)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.32))
                )
            }
        }
    }

    private var proofreadingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("是否開啟 AI 校稿？")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(primaryInk)

            Text("AI 校稿會在轉譯完成後用本地模型修正文字。第一次實際使用時會下載約 2.6 GB 模型，整段過程仍然在本機完成。")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                booleanChoiceCard(
                    isSelected: model.onboardingSelection.enableProofreading == false,
                    title: "暫不開啟",
                    detail: "先保留原始轉寫結果，不另外建立 AI 校稿環境。"
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        model.onboardingSelection.enableProofreading = false
                    }
                }

                booleanChoiceCard(
                    isSelected: model.onboardingSelection.enableProofreading == true,
                    title: "開啟 AI 校稿",
                    detail: "可讓逐字稿更通順，並修正明顯辨識錯字。"
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        model.onboardingSelection.enableProofreading = true
                        if model.onboardingSelection.proofreadingMode == .off {
                            model.onboardingSelection.proofreadingMode = .standard
                        }
                    }
                }
            }

            if model.onboardingSelection.enableProofreading == true {
                VStack(alignment: .leading, spacing: 10) {
                    Text("校稿模式")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryInk)

                    VStack(spacing: 10) {
                        ForEach(ProofreadingMode.allCases.filter { $0 != .off }, id: \.rawValue) { mode in
                            Button {
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                    model.onboardingSelection.proofreadingMode = mode
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: model.onboardingSelection.proofreadingMode == mode ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(model.onboardingSelection.proofreadingMode == mode ? Color.accentColor : secondaryInk)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(mode.displayName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(primaryInk)
                                        Text(mode.description)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(secondaryInk)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .background(choiceBackground(isSelected: model.onboardingSelection.proofreadingMode == mode))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var installStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("正在依照選擇準備環境")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(primaryInk)

            Text("此步驟會先把所需模型與功能環境一次準備完成。")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("安裝進度")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryInk)
                    Spacer()
                    Text("\(Int(model.onboardingPreparationProgress * 100))%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                ProgressView(value: model.onboardingPreparationProgress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .scaleEffect(y: 1.4)

                if model.isPreparingOnboardingChoices && !model.onboardingPreparationStatus.isEmpty {
                    Text(model.onboardingPreparationStatus)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.isPreparingOnboardingChoices ? Color.accentColor : secondaryInk)
                        .lineLimit(2)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.34))
            )

            VStack(alignment: .leading, spacing: 12) {
                installStateRow(
                    key: "whisper",
                    title: "轉譯模型",
                    enabled: true,
                    detail: "下載並準備轉譯所需模型"
                )
                installStateRow(
                    key: "enhancement",
                    title: "人聲增強",
                    enabled: model.onboardingSelection.enableEnhancement == true,
                    detail: "建立 enhancement 環境"
                )
                installStateRow(
                    key: "diarization",
                    title: "語者辨識",
                    enabled: model.onboardingSelection.enableDiarization == true,
                    detail: model.onboardingSelection.pendingDiarizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "已選擇，但尚未填 Token，安裝時會先略過授權準備"
                        : "建立 diarization 環境",
                )
                installStateRow(
                    key: "proofreading",
                    title: "AI 校稿",
                    enabled: model.onboardingSelection.enableProofreading == true,
                    detail: "建立 proofreading 環境並下載模型"
                )
            }

        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(model.onboardingStep == .install ? "之後再說" : "稍後再說") {
                model.skipOnboardingWizard()
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(model.isPreparingOnboardingChoices)

            Spacer(minLength: 0)

            if model.onboardingStep != .enhancement && model.onboardingStep != .install {
                Button("上一步") {
                    model.goToPreviousOnboardingStep()
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }

            if model.onboardingStep == .install {
                Button(model.isPreparingOnboardingChoices ? "準備中..." : "完成") {
                    model.completeOnboardingWizard()
                }
                .buttonStyle(PrimaryActionButtonStyle(enabled: model.canAdvanceCurrentOnboardingStep))
                .frame(width: 144)
                .disabled(!model.canAdvanceCurrentOnboardingStep)
            } else if model.onboardingStep == .proofreading {
                Button("開始準備") {
                    model.beginOnboardingPreparation()
                }
                .buttonStyle(PrimaryActionButtonStyle(enabled: model.canAdvanceCurrentOnboardingStep))
                .frame(width: 144)
                .disabled(!model.canAdvanceCurrentOnboardingStep)
            } else {
                Button("下一步") {
                    model.goToNextOnboardingStep()
                }
                .buttonStyle(PrimaryActionButtonStyle(enabled: model.canAdvanceCurrentOnboardingStep))
                .frame(width: 144)
                .disabled(!model.canAdvanceCurrentOnboardingStep)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func booleanChoiceCard(
        isSelected: Bool,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : secondaryInk)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(primaryInk)
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(16)
            .background(choiceBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func installStateRow(
        key: String,
        title: String,
        enabled: Bool,
        detail: String
    ) -> some View {
        let isCompleted = model.onboardingCompletedPreparationGroups.contains(key)
        let isActive = model.onboardingActivePreparationGroup == key && !isCompleted
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: enabled ? (isCompleted ? "checkmark.circle.fill" : (isActive ? "arrow.triangle.2.circlepath.circle.fill" : "circle")) : "minus.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(enabled ? (isCompleted ? Color(red: 0.14, green: 0.53, blue: 0.24) : (isActive ? Color.accentColor : secondaryInk.opacity(0.9))) : secondaryInk.opacity(0.8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryInk)
                Text(enabled ? (isCompleted ? "已完成" : (isActive ? "準備中" : detail)) : "這次先不準備")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(enabled ? 0.34 : 0.18))
        )
        .animation(.easeInOut(duration: 0.22), value: isCompleted)
        .animation(.easeInOut(duration: 0.22), value: isActive)
    }

    private func choiceBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.white.opacity(0.24))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.28) : Color.black.opacity(0.06), lineWidth: 1)
            )
    }

    private func statusColor(_ tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return secondaryInk
        case .success: return Color(red: 0.14, green: 0.53, blue: 0.24)
        case .error: return Color(red: 0.74, green: 0.20, blue: 0.16)
        }
    }

    private var tokenVerificationButtonTitle: String {
        if model.isVerifyingOnboardingToken {
            return "驗證中"
        }
        switch model.onboardingTokenStatusTone {
        case .success:
            return "已驗證"
        case .error:
            return "驗證失敗"
        case .neutral:
            return "驗證 Token"
        }
    }

    private var tokenVerificationButtonColor: Color {
        if model.isVerifyingOnboardingToken {
            return Color.accentColor.opacity(0.9)
        }
        switch model.onboardingTokenStatusTone {
        case .success:
            return Color(red: 0.14, green: 0.53, blue: 0.24)
        case .error:
            return Color(red: 0.74, green: 0.20, blue: 0.16)
        case .neutral:
            return secondaryInk
        }
    }
}

private struct WindowDragBlocker: ViewModifier {
    @ObservedObject var model: NativeAppModel
    @State private var isDraggingControl = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isDraggingControl else { return }
                        isDraggingControl = true
                        model.setWindowBackgroundMovable(false)
                    }
                    .onEnded { _ in
                        isDraggingControl = false
                        model.setWindowBackgroundMovable(true)
                    }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            model.setWindowBackgroundMovable(true)
                        }
                    }
            )
            .onDisappear {
                isDraggingControl = false
                model.setWindowBackgroundMovable(true)
            }
    }
}

private struct QueueRow: View {
    let item: QueueItemModel
    let index: Int
    let compact: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                Text(String(format: "%02d", index))
                    .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                if showsLeadingStatus {
                    Text(statusLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(statusColor.opacity(0.14)))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: compact ? 42 : 52, alignment: .top)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !showsLeadingStatus {
                            Text(item.filename)
                                .font(.system(size: compact ? 15 : 16, weight: .semibold))
                                .lineLimit(compact ? 3 : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !compact && !metaText.isEmpty {
                            Text(metaText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.34))
                        }
                    }
                    Spacer(minLength: 12)
                    if !showsLeadingStatus {
                        Text(statusLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(statusColor.opacity(0.14)))
                            .foregroundStyle(statusColor)
                            .padding(.trailing, item.status != .processing ? 38 : 0)
                    }
                }

                if let detailText {
                    Text(detailText)
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.36, green: 0.33, blue: 0.30))
                        .lineLimit(compact ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: !compact)
                }

                if item.status == .processing {
                    SegmentedProgressBar(
                        progress: item.progress,
                        phase: item.phase,
                        activePhases: item.activePhases
                    )

                    if let dl = item.downloadProgress {
                        DownloadInfoCard(info: dl)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(compact ? 14 : 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
        .overlay(alignment: .topTrailing) {
            if item.status != .processing {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(FloatingIconButtonStyle())
                .foregroundStyle(Color(red: 0.48, green: 0.40, blue: 0.34))
                .padding(compact ? 12 : 14)
            }
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .pending: return "等待中"
        case .processing: return "轉譯中"
        case .done: return "完成"
        case .error: return item.error ?? "失敗"
        case .stopped: return "已停止"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .done: return .green
        case .error, .stopped: return .red
        case .processing: return .orange
        case .pending: return .secondary
        }
    }

    private var metaText: String {
        if showsLeadingStatus {
            return ""
        }
        if item.size > 0 {
            return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        }
        return "尚未取得大小"
    }

    private var detailText: String? {
        switch item.status {
        case .processing:
            return item.message.isEmpty ? statusLabel : item.message
        default:
            return nil
        }
    }

    private var showsLeadingStatus: Bool {
        [.done, .error, .stopped].contains(item.status)
    }

    private var showsStatusLine: Bool {
        false
    }

    private var primaryProgress: Color {
        Color(red: 0.18, green: 0.16, blue: 0.14).opacity(0.82)
    }
}

// MARK: - Segmented Progress Bar

private struct SegmentedProgressBar: View {
    let progress: Int
    let phase: ProcessingPhase?
    let activePhases: [ProcessingPhase]

    private struct Segment: Identifiable {
        let id: ProcessingPhase
        let fraction: Double  // width fraction (0-1) of the total bar
        let color: Color
    }

    private var segments: [Segment] {
        guard !activePhases.isEmpty else {
            return [Segment(id: .transcribing, fraction: 1.0, color: ProcessingPhase.transcribing.color)]
        }

        let weights: [(ProcessingPhase, Double)] = activePhases.map { p in
            switch p {
            case .downloading:  return (p, 0.10)
            case .enhancing:    return (p, 0.10)
            case .transcribing: return (p, activePhases.contains(.diarizing) ? 0.55 : 0.80)
            case .diarizing:    return (p, 0.25)
            case .proofreading: return (p, 0.15)
            }
        }
        let totalWeight = weights.reduce(0.0) { $0 + $1.1 }
        return weights.map { Segment(id: $0.0, fraction: $0.1 / totalWeight, color: $0.0.color) }
    }

    private var currentPhaseIndex: Int {
        guard let phase else { return 0 }
        return activePhases.firstIndex(of: phase) ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let phaseIdx = currentPhaseIndex
                    let state: SegmentState = {
                        if index < phaseIdx {
                            return .completed
                        } else if index == phaseIdx {
                            return .active
                        } else {
                            return .pending
                        }
                    }()

                    let fillFraction: Double = {
                        switch state {
                        case .completed: return 1.0
                        case .pending: return 0.0
                        case .active:
                            if segment.id == .transcribing {
                                // Transcribing has real 0-100 progress from whisper
                                return max(0.05, min(Double(progress) / 96.0, 1.0))
                            } else {
                                // Other phases: show ~40% fill as indeterminate active
                                return 0.4
                            }
                        }
                    }()

                    let segWidth = segment.fraction * (geo.size.width - CGFloat(max(segments.count - 1, 0)) * 2)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segment.color.opacity(0.15))
                            .frame(width: segWidth)

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segment.color)
                            .frame(width: max(segWidth * fillFraction, fillFraction > 0 ? 3 : 0))
                            .opacity(state == .active ? 1.0 : (state == .completed ? 0.85 : 0.3))
                    }
                    .frame(width: segWidth)
                    .animation(.easeInOut(duration: 0.4), value: fillFraction)
                    .animation(.easeInOut(duration: 0.3), value: state == .active)
                }
            }
        }
        .frame(height: 6)
    }

    private enum SegmentState {
        case completed, active, pending
    }
}

// MARK: - Download Info Card

private struct DownloadInfoCard: View {
    let info: DownloadProgress

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(ProcessingPhase.downloading.color)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(info.filename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text("\(info.formattedDownloaded) / \(info.formattedTotal)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if info.bytesPerSecond > 0 {
                        Text("· \(info.formattedSpeed)")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let eta = info.estimatedSecondsRemaining, eta > 0 && eta < 3600 {
                Text("剩餘 \(Int(eta))s")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("\(Int(info.fractionCompleted * 100))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(ProcessingPhase.downloading.color)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ProcessingPhase.downloading.color.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ProcessingPhase.downloading.color.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

private struct PulsingAddButton: View {
    let action: () -> Void
    @State private var glowing = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(FloatingIconButtonStyle())
        .overlay(
            Circle()
                .stroke(Color.accentColor.opacity(glowing ? 0.24 : 0.04), lineWidth: 1.4)
                .scaleEffect(glowing ? 1.16 : 0.92)
        )
        .shadow(color: Color.accentColor.opacity(glowing ? 0.20 : 0.06), radius: glowing ? 14 : 6, x: 0, y: 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                glowing = true
            }
        }
    }
}

private struct ResultCard: View {
    let item: QueueItemModel
    let cardHeight: CGFloat
    let contentViewportHeight: CGFloat
    let onCopy: () -> Void
    let onSave: () -> Void

    private let cardPadding: CGFloat = 14
    private let stackSpacing: CGFloat = 8
    private let actionBarHeight: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = proxy.size.height - (cardPadding * 2)
            let headerHeight = min(max(proxy.size.height * 0.10, 34), 42)
            let reserved = headerHeight + actionBarHeight + (stackSpacing * 2)
            let preferredViewport = availableHeight * 0.47
            let viewportHeight = max(min(contentViewportHeight, preferredViewport, availableHeight - reserved), 92)

            VStack(alignment: .leading, spacing: stackSpacing) {
                cardHeader(height: headerHeight)

                if let result = item.result {
                    resultViewport(result, height: viewportHeight)
                    actionBar
                } else if let error = item.error {
                    Text(error)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.38, green: 0.35, blue: 0.32))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)

                    HStack(spacing: 10) {
                        Button("複製") { }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .opacity(0)
                            .allowsHitTesting(false)

                        Button("下載") { }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .opacity(0)
                            .allowsHitTesting(false)
                        Spacer()
                    }
                    .frame(height: actionBarHeight, alignment: .leading)
                }
            }
            .padding(cardPadding)
        }
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.78))
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func cardHeader(height: CGFloat) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.filename)
                    .font(.system(size: 17, weight: .semibold))
            }
            Spacer()
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(statusColor.opacity(0.14)))
                .foregroundStyle(statusColor)
        }
        .frame(minHeight: height, alignment: .top)
    }

    private func resultViewport(_ result: TranscriptResult, height: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(result.segments.enumerated()), id: \.offset) { index, segment in
                    segmentCard(index: index, segment: segment)
                }
            }
            .padding(2)
        }
        .frame(height: height)
        .padding(8)
        .background(resultViewportBackground)
        .overlay(resultViewportBorder)
    }

    private var resultViewportBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.34))
    }

    private var resultViewportBorder: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.white.opacity(0.5), lineWidth: 1)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("複製") {
                onCopy()
            }
            .buttonStyle(SecondaryActionButtonStyle())

            Button("下載") {
                onSave()
            }
            .buttonStyle(SecondaryActionButtonStyle())
            Spacer()
        }
        .frame(height: actionBarHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmentCard(index: Int, segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.34))

                if let speakerLabel = segment.speakerLabel {
                    Text(speakerLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(red: 0.43, green: 0.31, blue: 0.18).opacity(0.08)))
                }

                Text("\(formatTime(segment.startTimeMs)) - \(formatTime(segment.endTimeMs))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.34))
            }

            Text(segment.text)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.66))
        )
    }

    private var statusText: String {
        switch item.status {
        case .done: return "完成"
        case .error: return "失敗"
        case .stopped: return "已停止"
        case .pending: return "等待中"
        case .processing: return "轉譯中"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .done: return .green
        case .error, .stopped: return .red
        case .pending, .processing: return .secondary
        }
    }

    private func formatTime(_ milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds / 1000, 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct LiveStreamOverlay: View {
    let lines: [FloatingLineModel]

    var body: some View {
        ZStack {
            ForEach(lines) { line in
                FloatingLineView(line: line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

private struct ProofreadingStreamOverlay: View {
    let lines: [ProofreadingStreamLineModel]
    let liveStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accentColor.opacity(0.92))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 6)
                            .scaleEffect(1.2)
                    )
                Text("AI 校稿中")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.46, green: 0.42, blue: 0.38))
                Spacer(minLength: 0)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.suffix(4).enumerated()), id: \.element.id) { index, line in
                        Text(line.text)
                            .font(.system(size: 13, weight: index == max(lines.suffix(4).count - 1, 0) ? .medium : .regular))
                            .foregroundStyle(Color(red: 0.20, green: 0.18, blue: 0.15).opacity(index == max(lines.suffix(4).count - 1, 0) ? 0.92 : 0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 96)

            if !liveStatus.isEmpty {
                HStack(spacing: 6) {
                    Text(liveStatus)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.16, green: 0.14, blue: 0.12))
                        .lineLimit(1)
                    BlinkingCursor()
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 420, height: 178, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.accentColor.opacity(0.92))
            .frame(width: 10, height: 18)
            .opacity(visible ? 1 : 0.18)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

private struct FloatingLineView: View {
    let line: FloatingLineModel
    @State private var animated = false

    var body: some View {
        Text(line.text)
            .font(.system(size: line.fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.16, green: 0.14, blue: 0.12).opacity(animated ? 0 : 0.92))
            .multilineTextAlignment(.center)
            .shadow(color: Color.white.opacity(0.32), radius: 6, x: 0, y: 0)
            .shadow(color: Color(red: 0.28, green: 0.20, blue: 0.12).opacity(0.06), radius: 8, x: 0, y: 3)
            .scaleEffect(animated ? 1.01 : 0.985)
            .offset(
                x: animated ? line.endXOffset : line.startXOffset,
                y: animated ? -line.riseDistance : 64
            )
            .opacity(animated ? 0 : 1)
            .blur(radius: animated ? 1.2 : 0)
            .onAppear {
                withAnimation(.linear(duration: 2.8).delay(line.delay)) {
                    animated = true
                }
            }
    }
}

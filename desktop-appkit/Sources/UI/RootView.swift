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
                    LiveStreamOverlay(lines: model.floatingLines)
                        .allowsHitTesting(false)
                        .padding(.bottom, 42)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 26) {
                    header(availableWidth: proxy.size.width)
                    content(availableHeight: proxy.size.height, availableWidth: proxy.size.width)
                    footer
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("逐字搞定 Beta")
                            .font(.system(size: 58, weight: .bold, design: .serif))
                            .tracking(-1.0)
                        Text("語音轉譯")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(secondaryInk)
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
               let action = quietActionStatus {
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

            if let visiblePickerStatus {
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

            if showDiagnostics && shouldShowDiagnostics {
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

    private var footer: some View {
        VStack(spacing: 6) {
            Text("桌面版本地執行 ・ Beta 測試版 ・ 音訊不會離開您的電腦")
            Text("Developed by 莊旻叡")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(secondaryInk)
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
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

                VStack(alignment: .leading, spacing: 12) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.32))
                )

                VStack(alignment: .leading, spacing: 12) {
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
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.32))
                )

                VStack(alignment: .leading, spacing: 10) {
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

                    HStack(spacing: 10) {
                        Button("驗證 Token") {
                            model.verifyToken()
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                        .disabled(!model.diarizeEnabled || model.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if model.tokenVerified {
                            Text("已驗證")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(red: 0.14, green: 0.53, blue: 0.24))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("先建立 Access Token，並確認 pyannote 模型頁面已完成授權。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("取得 Token") {
                            NSWorkspace.shared.open(tokenURL)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                    }
                    .opacity(model.diarizeEnabled ? 1 : 0.58)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.32))
                )
                .opacity(model.diarizeEnabled ? 1 : 0.72)
                .scaleEffect(model.diarizeEnabled ? 1 : 0.985)
                .animation(.easeInOut(duration: 0.22), value: model.diarizeEnabled)

                VStack(alignment: .leading, spacing: 10) {
                    Text("辨識模型")
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.24))
                )

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

    private var quietActionStatus: String? {
        guard !model.actionStatus.isEmpty else { return nil }
        if model.actionStatusTone == .error {
            return model.actionStatus
        }
        if model.actionStatus.contains("已刪除") || model.actionStatus.contains("已複製") || model.actionStatus.contains("已下載") || model.actionStatus.contains("已加入") {
            return model.actionStatus
        }
        return nil
    }

    private var visiblePickerStatus: String? {
        guard !model.pickerStatus.isEmpty else { return nil }
        if model.pickerStatus == "桌面版已就緒" {
            return nil
        }
        if model.pickerStatusTone == .error || model.pickerStatus.contains("已取消") {
            return model.pickerStatus
        }
        return nil
    }

    private var shouldShowDiagnostics: Bool {
        model.actionStatusTone == .error && !model.diagnosticLogLines.isEmpty
    }

    private var queueAnimationSignature: String {
        model.queueItems.map { "\($0.id):\($0.status):\($0.progress)" }.joined(separator: "|")
    }

    private var hoveredControlHintText: String? {
        switch hoveredControlHint {
        case .pause:
            return "會暫停佇列，恢復後會重新開始目前檔案"
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
                            .padding(.trailing, item.status != "processing" ? 38 : 0)
                    }
                }

                if let detailText {
                    Text(detailText)
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.36, green: 0.33, blue: 0.30))
                        .lineLimit(compact ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: !compact)
                }

                if item.status == "processing" {
                    SegmentedProgressBar(
                        progress: item.progress,
                        phase: item.phase,
                        activePhases: item.activePhases
                    )

                    if let dl = item.downloadProgress, item.phase == .downloading {
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
            if item.status != "processing" {
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
        case "pending": return "等待中"
        case "processing": return "轉譯中"
        case "done": return "完成"
        case "error": return item.error ?? "失敗"
        case "stopped": return "已停止"
        default: return item.status
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "done": return .green
        case "error", "stopped": return .red
        case "processing": return .orange
        default: return .secondary
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
        case "processing":
            return item.message.isEmpty ? statusLabel : item.message
        default:
            return nil
        }
    }

    private var showsLeadingStatus: Bool {
        ["done", "error", "stopped"].contains(item.status)
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
        case "done": return "完成"
        case "error": return "失敗"
        case "stopped": return "已停止"
        default: return item.status
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "done": return .green
        case "error", "stopped": return .red
        default: return .secondary
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

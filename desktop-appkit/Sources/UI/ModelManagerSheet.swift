import Foundation
import SwiftUI

// MARK: - ViewModel

@MainActor
final class ModelManagerViewModel: ObservableObject {
    @Published var models: [ManagedModel] = []
    @Published var storageItems: [ManagedStorageItem] = []
    @Published var downloadStates: [String: ModelDownloadState] = [:]
    @Published var isScanning = true
    @Published var errorMessage: String?
    @Published var appSupportFootprint: Int64 = 0

    private var downloadTasks: [String: Task<Void, Never>] = [:]

    var totalDownloadedSize: Int64 {
        ModelCatalog.shared.totalDownloadedSize(from: models)
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedSize, countStyle: .file)
    }

    var totalStorageSize: Int64 {
        ModelCatalog.shared.totalStorageSize(from: storageItems)
    }

    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: totalStorageSize, countStyle: .file)
    }

    var formattedAppSupportFootprint: String {
        ByteCountFormatter.string(fromByteCount: appSupportFootprint, countStyle: .file)
    }

    func scan() async {
        withAnimation(.easeInOut(duration: 0.18)) {
            isScanning = true
        }
        do {
            let scannedModels = try await ModelCatalog.shared.scan()
            let scannedStorage = try await ModelCatalog.shared.scanStorageItems()
            let footprint = try await ModelCatalog.shared.appSupportFootprint()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                models = scannedModels
                storageItems = scannedStorage
                appSupportFootprint = footprint
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.18)) {
                errorMessage = "掃描失敗：\(error.localizedDescription)"
            }
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            isScanning = false
        }
    }

    func downloadState(for model: ManagedModel) -> ModelDownloadState {
        downloadStates[model.id] ?? .idle
    }

    func download(_ model: ManagedModel) {
        guard downloadStates[model.id] == nil || downloadStates[model.id] == .idle else { return }

        let task = Task {
            switch model.kind {
            case .whisper(let preset):
                await downloadWhisper(model: model, preset: preset)
            case .llm(let spec):
                await downloadLLM(model: model, spec: spec)
            }
        }
        downloadTasks[model.id] = task
    }

    func cancelDownload(_ model: ManagedModel) {
        downloadTasks[model.id]?.cancel()
        downloadTasks[model.id] = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            downloadStates[model.id] = .idle
        }
    }

    func delete(_ model: ManagedModel) async {
        do {
            try await ModelCatalog.shared.delete(model)
            await scan()
        } catch {
            errorMessage = "刪除失敗：\(error.localizedDescription)"
        }
    }

    func delete(_ item: ManagedStorageItem) async {
        do {
            try await ModelCatalog.shared.delete(item)
            await scan()
        } catch {
            errorMessage = "清理失敗：\(error.localizedDescription)"
        }
    }

    // MARK: - Whisper Download

    private func downloadWhisper(model: ManagedModel, preset: WhisperModelPreset) async {
        guard let remoteURL = URL(string: preset.remoteURL) else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            downloadStates[model.id] = .downloading(progress: 0, bytesDownloaded: 0, totalBytes: 0)
        }

        do {
            let modelDir = try PathResolver.swiftWhisperModelDirectory()
            let destination = modelDir.appendingPathComponent(preset.filename)

            try await downloadFile(
                from: remoteURL,
                to: destination,
                modelId: model.id
            )

            withAnimation(.easeInOut(duration: 0.18)) {
                downloadStates[model.id] = .idle
            }
            await scan()
        } catch is CancellationError {
            withAnimation(.easeInOut(duration: 0.18)) {
                downloadStates[model.id] = .idle
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.18)) {
                downloadStates[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - LLM Download

    private func downloadLLM(model: ManagedModel, spec: LLMModelSpec) async {
        withAnimation(.easeInOut(duration: 0.18)) {
            downloadStates[model.id] = .installing
        }

        do {
            // Step 1: Ensure Python env with mlx-lm is ready
            try await PythonEnvironmentManager.shared.ensureReady(
                for: .proofreading,
                log: { _ in },
                pipProgress: { _ in }
            )

            try Task.checkCancellation()

            // Step 2: Download model via huggingface_hub snapshot_download
            let python = try PathResolver.pythonExecutable()
            let cacheDir = try await ModelCatalog.shared.llmModelCacheDirectory()

            let process = Process()
            process.executableURL = python
            process.arguments = [
                "-c",
                """
                import sys
                from huggingface_hub import snapshot_download
                repo = "\(spec.huggingFaceRepo)"
                local_dir = "\(cacheDir.path)/\(spec.huggingFaceRepo.replacingOccurrences(of: "/", with: "--"))"
                print(f"正在下載 {repo}...", flush=True)
                snapshot_download(repo_id=repo, local_dir=local_dir)
                print("下載完成", flush=True)
                """
            ]
            var env = try PathResolver.backendEnvironment()
            env["HF_HUB_DISABLE_PROGRESS_BARS"] = "0"
            env["HF_HUB_VERBOSITY"] = "info"
            process.environment = env

            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice

            try process.run()

            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in continuation.resume() }
                }
            } onCancel: {
                process.terminate()
            }

            guard process.terminationStatus == 0 else {
                let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(
                    domain: "ModelManager",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "下載失敗" : errText]
                )
            }

            withAnimation(.easeInOut(duration: 0.18)) {
                downloadStates[model.id] = .idle
            }
            await scan()

        } catch is CancellationError {
            withAnimation(.easeInOut(duration: 0.18)) {
                downloadStates[model.id] = .idle
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.18)) {
                downloadStates[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - URLSession Download with Progress

    private func downloadFile(from url: URL, to destination: URL, modelId: String) async throws {
        let partialDest = destination.appendingPathExtension("downloading")
        try? FileManager.default.removeItem(at: partialDest)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = WhisperDownloadDelegate(
                    destination: partialDest,
                    onProgress: { [weak self] downloaded, total in
                        Task { @MainActor [weak self] in
                            let progress = total > 0 ? Double(downloaded) / Double(total) : 0
                            withAnimation(.linear(duration: 0.14)) {
                                self?.downloadStates[modelId] = .downloading(
                                    progress: progress,
                                    bytesDownloaded: downloaded,
                                    totalBytes: total
                                )
                            }
                        }
                    },
                    continuation: continuation
                )
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            try? FileManager.default.removeItem(at: partialDest)
        }

        // Move to final destination
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partialDest, to: destination)
    }
}

// MARK: - URLSession Delegate

private final class WhisperDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Int64, Int64) -> Void
    private let continuation: CheckedContinuation<Void, Error>
    private let lock = NSLock()
    private var resumed = false

    init(destination: URL, onProgress: @escaping (Int64, Int64) -> Void, continuation: CheckedContinuation<Void, Error>) {
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.resume()
        } catch {
            continuation.resume(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation.resume(throwing: NSError(
                domain: "ModelManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            ))
        }
        session.finishTasksAndInvalidate()
    }
}

// MARK: - Sheet View

struct ModelManagerSheet: View {
    @StateObject private var vm = ModelManagerViewModel()
    let onClose: () -> Void

    private let primaryInk = Color(red: 0.16, green: 0.14, blue: 0.12)
    private let secondaryInk = Color(red: 0.34, green: 0.31, blue: 0.28)
    private let paperBackground = Color(red: 0.97, green: 0.962, blue: 0.947)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("資料管理")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(primaryInk)
                    Text("管理本機模型、快取與環境資料")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryInk)
                }
                Spacer()
                Button("完成") { onClose() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()
                .opacity(0.15)

            // Model List
            if vm.isScanning {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        storageOverview

                        // Whisper section
                        sectionHeader("Whisper 轉寫模型")
                        ForEach(vm.models.filter { if case .whisper = $0.kind { return true }; return false }) { model in
                            modelRow(model)
                            Divider().padding(.leading, 24).opacity(0.1)
                        }

                        // LLM section
                        sectionHeader("AI 校稿模型")
                        ForEach(vm.models.filter { if case .llm = $0.kind { return true }; return false }) { model in
                            modelRow(model)
                            Divider().padding(.leading, 24).opacity(0.1)
                        }

                        if !vm.storageItems.isEmpty {
                            sectionHeader("快取與環境")
                            ForEach(vm.storageItems) { item in
                                storageRow(item)
                                Divider().padding(.leading, 24).opacity(0.1)
                            }
                        }
                    }
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: vm.models)
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: vm.storageItems)
                    .animation(.easeInOut(duration: 0.18), value: vm.downloadStates)
                }
                .transition(.opacity)

                // Footer: total size
                Divider().opacity(0.15)
                VStack(alignment: .leading, spacing: 6) {
                    footerMetricRow(label: "模型占用", value: vm.formattedTotalSize)
                    footerMetricRow(label: "快取與環境", value: vm.formattedStorageSize)
                    footerMetricRow(label: "Scribby 總占用", value: vm.formattedAppSupportFootprint)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }

            // Error
            if let error = vm.errorMessage {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 520, height: 620)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(paperBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.46), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 24, x: 0, y: 16)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .preferredColorScheme(.light)
        .task { await vm.scan() }
        .animation(.easeInOut(duration: 0.2), value: vm.isScanning)
        .animation(.easeInOut(duration: 0.2), value: vm.errorMessage)
    }

    // MARK: - Section Header

    private var storageOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("目前 Scribby 的模型、Python 環境和舊版殘留都在這裡集中管理。刪除模型或快取後，下次使用時會重新下載或重建。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(_ model: ManagedModel) -> some View {
        let state = vm.downloadState(for: model)

        HStack(spacing: 14) {
            // Icon
            Image(systemName: iconName(for: model.kind))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(model.isDownloaded ? Color.accentColor : secondaryInk.opacity(0.5))
                .frame(width: 28)

            // Name + meta
            VStack(alignment: .leading, spacing: 3) {
                Text(model.kind.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryInk)

                badge(model.kind.cleanupBadge, tint: Color.accentColor.opacity(0.14), ink: Color.accentColor.opacity(0.92))

                if case .downloading(let progress, let downloaded, let total) = state {
                    downloadProgressRow(progress: progress, downloaded: downloaded, total: total)
                } else if case .installing = state {
                    Text("正在安裝環境，請稍候...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondaryInk)
                } else if case .failed(let msg) = state {
                    Text("失敗：\(msg)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .lineLimit(2)
                } else {
                    Text(model.isDownloaded
                         ? (model.formattedSizeOnDisk ?? model.kind.sizeHint)
                         : model.kind.sizeHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondaryInk)
                }
            }

            Spacer()

            // Action button
            actionButton(for: model, state: state)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        ))
    }

    @ViewBuilder
    private func storageRow(_ item: ManagedStorageItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(secondaryInk.opacity(0.65))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryInk)

                badge(item.kind.cleanupBadge, tint: Color(red: 0.39, green: 0.33, blue: 0.25).opacity(0.12), ink: secondaryInk)

                Text(item.kind.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.formattedSizeOnDisk)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primaryInk.opacity(0.82))
            }

            Spacer()

            Button("清理") {
                Task { await vm.delete(item) }
            }
            .buttonStyle(DestructiveSmallButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        ))
    }

    @ViewBuilder
    private func downloadProgressRow(progress: Double, downloaded: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress)
                .frame(maxWidth: 160)
                .tint(Color.accentColor)
                .animation(.linear(duration: 0.14), value: progress)
            if total > 0 {
                let dlStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
                let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                Text("\(dlStr) / \(totalStr)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryInk)
                    .contentTransition(.numericText())
            }
        }
    }

    @ViewBuilder
    private func actionButton(for model: ManagedModel, state: ModelDownloadState) -> some View {
        switch state {
        case .idle:
            if model.isDownloaded {
                Button("刪除") {
                    Task { await vm.delete(model) }
                }
                .buttonStyle(DestructiveSmallButtonStyle())
            } else {
                Button("下載") {
                    vm.download(model)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .font(.system(size: 13, weight: .semibold))
            }

        case .downloading, .installing:
            Button("取消") {
                vm.cancelDownload(model)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .font(.system(size: 13, weight: .semibold))

        case .failed:
            Button("重試") {
                vm.download(model)
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .font(.system(size: 13, weight: .semibold))
        }
    }

    private func iconName(for kind: ManagedModelKind) -> String {
        switch kind {
        case .whisper: return "waveform"
        case .llm: return "sparkles"
        }
    }

    private func footerMetricRow(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryInk)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primaryInk)
                .contentTransition(.numericText())
            Spacer()
        }
    }

    private func badge(_ text: String, tint: Color, ink: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint)
            )
            .fixedSize()
    }
}

// MARK: - Destructive Small Button Style

private struct DestructiveSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .foregroundStyle(Color.red.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.red.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.red.opacity(0.18), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

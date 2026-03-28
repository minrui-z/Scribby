import Foundation

// MARK: - LLM Model Spec

struct LLMModelSpec: Equatable {
    let id: String
    let displayName: String
    let huggingFaceRepo: String
    let sizeHint: String

    static let proofreadingGemma3Text4B = LLMModelSpec(
        id: "gemma-3-text-4b-proofreading",
        displayName: "Gemma 3 Text 4B（校稿）",
        huggingFaceRepo: "mlx-community/gemma-3-text-4b-it-4bit",
        sizeHint: "約 2.6 GB"
    )

    static let all: [LLMModelSpec] = [.proofreadingGemma3Text4B]
}

// MARK: - Managed Model

enum ManagedModelKind: Equatable {
    case whisper(WhisperModelPreset)
    case llm(LLMModelSpec)

    var displayName: String {
        switch self {
        case .whisper(let preset): return preset.displayName
        case .llm(let spec): return spec.displayName
        }
    }

    var sizeHint: String {
        switch self {
        case .whisper(let preset): return preset.sizeHint
        case .llm(let spec): return spec.sizeHint
        }
    }

    var categoryLabel: String {
        switch self {
        case .whisper: return "Whisper"
        case .llm: return "校稿"
        }
    }

    var cleanupBadge: String {
        switch self {
        case .whisper, .llm:
            return "刪除後會重新下載"
        }
    }
}

enum ManagedStorageKind: Equatable {
    case pythonEnvironment
    case standalonePython
    case debugLogs
    case legacyAppSupport

    var title: String {
        switch self {
        case .pythonEnvironment:
            return "Python 執行環境"
        case .standalonePython:
            return "Standalone Python"
        case .debugLogs:
            return "Debug Logs"
        case .legacyAppSupport:
            return "舊版 Scribby 資料"
        }
    }

    var subtitle: String {
        switch self {
        case .pythonEnvironment:
            return "刪除後，AI 校稿 / 人聲加強 / 語者辨識會在下次使用時重建"
        case .standalonePython:
            return "刪除後，找不到合格系統 Python 時會重新下載"
        case .debugLogs:
            return "只會清掉診斷紀錄，不影響功能"
        case .legacyAppSupport:
            return "舊版 com.minrui.scribby.native 殘留資料，可安全清理"
        }
    }

    var symbolName: String {
        switch self {
        case .pythonEnvironment:
            return "terminal"
        case .standalonePython:
            return "shippingbox"
        case .debugLogs:
            return "doc.text.magnifyingglass"
        case .legacyAppSupport:
            return "archivebox"
        }
    }

    var cleanupBadge: String {
        switch self {
        case .pythonEnvironment, .standalonePython:
            return "刪除後會重建"
        case .debugLogs, .legacyAppSupport:
            return "可安全刪除"
        }
    }
}

struct ManagedStorageItem: Identifiable, Equatable {
    let id: String
    let kind: ManagedStorageKind
    let path: URL
    let sizeOnDisk: Int64

    var formattedSizeOnDisk: String {
        ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file)
    }
}

struct ManagedModel: Identifiable, Equatable {
    let id: String
    let kind: ManagedModelKind
    var isDownloaded: Bool
    var sizeOnDisk: Int64?

    var formattedSizeOnDisk: String? {
        guard let size = sizeOnDisk else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - Download State

enum ModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case installing
    case failed(String)
}

// MARK: - ModelCatalog

actor ModelCatalog {
    static let shared = ModelCatalog()

    private let fileManager = FileManager.default

    // MARK: - Scan

    func scan() async throws -> [ManagedModel] {
        let modelDir = try PathResolver.swiftWhisperModelDirectory()
        let llmCacheDir = try llmModelCacheDirectory()

        var models: [ManagedModel] = []

        // Whisper models
        for preset in WhisperModelPreset.allCases {
            let fileURL = modelDir.appendingPathComponent(preset.filename)
            let downloaded = fileManager.fileExists(atPath: fileURL.path)
            let size = downloaded ? (try? totalWhisperFootprint(for: preset, modelDir: modelDir)) : nil
            models.append(ManagedModel(
                id: "whisper-\(preset.rawValue)",
                kind: .whisper(preset),
                isDownloaded: downloaded,
                sizeOnDisk: size
            ))
        }

        // LLM models
        for spec in LLMModelSpec.all {
            let modelDirs = llmModelDirectories(for: spec, under: llmCacheDir)
            let existingDirs = modelDirs.filter { fileManager.fileExists(atPath: $0.path) }
            let downloaded = !existingDirs.isEmpty
            let size = downloaded ? existingDirs.reduce(Int64(0)) { partial, dir in
                partial + ((try? sizeOfDirectory(at: dir)) ?? 0)
            } : nil
            models.append(ManagedModel(
                id: "llm-\(spec.id)",
                kind: .llm(spec),
                isDownloaded: downloaded,
                sizeOnDisk: size
            ))
        }

        return models
    }

    func scanStorageItems() throws -> [ManagedStorageItem] {
        var items: [ManagedStorageItem] = []

        let appSupport = try PathResolver.appSupportDirectory()
        let candidates: [(ManagedStorageKind, URL)] = [
            (.pythonEnvironment, appSupport.appendingPathComponent("python-env", isDirectory: true)),
            (.standalonePython, appSupport.appendingPathComponent("python-standalone", isDirectory: true)),
            (.debugLogs, appSupport.appendingPathComponent("debug-logs", isDirectory: true)),
            (.legacyAppSupport, appSupport.deletingLastPathComponent().appendingPathComponent("com.minrui.scribby.native", isDirectory: true)),
        ]

        for (kind, url) in candidates where fileManager.fileExists(atPath: url.path) {
            let size = try sizeOfDirectory(at: url)
            items.append(ManagedStorageItem(
                id: "storage-\(kind)",
                kind: kind,
                path: url,
                sizeOnDisk: size
            ))
        }

        return items.sorted { $0.sizeOnDisk > $1.sizeOnDisk }
    }

    func delete(_ item: ManagedStorageItem) throws {
        guard fileManager.fileExists(atPath: item.path.path) else { return }
        try fileManager.removeItem(at: item.path)
    }

    func appSupportFootprint() throws -> Int64 {
        try sizeOfDirectory(at: try PathResolver.appSupportDirectory())
    }

    // MARK: - Delete

    func delete(_ model: ManagedModel) throws {
        switch model.kind {
        case .whisper(let preset):
            let modelDir = try PathResolver.swiftWhisperModelDirectory()
            let fileURL = modelDir.appendingPathComponent(preset.filename)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            // Also remove CoreML encoder if present
            if let encoderURL = coreMLEncoderDirectory(for: preset) {
                if fileManager.fileExists(atPath: encoderURL.path) {
                    try fileManager.removeItem(at: encoderURL)
                }
            }
            if let packageURL = coreMLPackageDirectory(for: preset),
               fileManager.fileExists(atPath: packageURL.path) {
                try fileManager.removeItem(at: packageURL)
            }

        case .llm(let spec):
            let llmCacheDir = try llmModelCacheDirectory()
            for repoDir in llmModelDirectories(for: spec, under: llmCacheDir) where fileManager.fileExists(atPath: repoDir.path) {
                try fileManager.removeItem(at: repoDir)
            }
        }
    }

    // MARK: - Total Size

    nonisolated func totalDownloadedSize(from models: [ManagedModel]) -> Int64 {
        models.compactMap(\.sizeOnDisk).reduce(0, +)
    }

    nonisolated func totalStorageSize(from items: [ManagedStorageItem]) -> Int64 {
        items.map(\.sizeOnDisk).reduce(0, +)
    }

    // MARK: - Directories

    func llmModelCacheDirectory() throws -> URL {
        let directory = try PathResolver.appSupportDirectory()
            .appendingPathComponent("mlx-models", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    // MARK: - Private Helpers

    private func sizeOfItem(at url: URL) throws -> Int64 {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int64) ?? 0
    }

    private func sizeOfDirectory(at url: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    private func totalWhisperFootprint(for preset: WhisperModelPreset, modelDir: URL) throws -> Int64 {
        var total = try sizeOfItem(at: modelDir.appendingPathComponent(preset.filename))
        if let encoderDir = coreMLEncoderDirectory(for: preset),
           fileManager.fileExists(atPath: encoderDir.path) {
            total += try sizeOfDirectory(at: encoderDir)
        }
        if let packageDir = coreMLPackageDirectory(for: preset),
           fileManager.fileExists(atPath: packageDir.path) {
            total += try sizeOfDirectory(at: packageDir)
        }
        return total
    }

    private func coreMLEncoderDirectory(for preset: WhisperModelPreset) -> URL? {
        guard let modelDir = try? PathResolver.swiftWhisperModelDirectory() else { return nil }
        switch preset {
        case .tiny:
            return nil
        case .largeV3Turbo:
            return modelDir.appendingPathComponent("ggml-large-v3-turbo-encoder.mlmodelc", isDirectory: true)
        case .largeV3:
            return modelDir.appendingPathComponent("ggml-large-v3-encoder.mlmodelc", isDirectory: true)
        }
    }

    private func coreMLPackageDirectory(for preset: WhisperModelPreset) -> URL? {
        guard let modelDir = try? PathResolver.swiftWhisperModelDirectory() else { return nil }
        switch preset {
        case .tiny:
            return nil
        case .largeV3Turbo:
            return modelDir.appendingPathComponent("ggml-large-v3-turbo-encoder.mlpackage", isDirectory: true)
        case .largeV3:
            return modelDir.appendingPathComponent("ggml-large-v3-encoder.mlpackage", isDirectory: true)
        }
    }

    private func llmModelDirectories(for spec: LLMModelSpec, under root: URL) -> [URL] {
        let flattened = root.appendingPathComponent(
            spec.huggingFaceRepo.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
        let huggingFaceCache = root
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent("models--" + spec.huggingFaceRepo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        return [flattened, huggingFaceCache]
    }
}

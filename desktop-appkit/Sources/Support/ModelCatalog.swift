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
            let size = downloaded ? (try? sizeOfItem(at: fileURL)) : nil
            models.append(ManagedModel(
                id: "whisper-\(preset.rawValue)",
                kind: .whisper(preset),
                isDownloaded: downloaded,
                sizeOnDisk: size
            ))
        }

        // LLM models
        for spec in LLMModelSpec.all {
            let repoDir = llmCacheDir.appendingPathComponent(
                spec.huggingFaceRepo.replacingOccurrences(of: "/", with: "--"),
                isDirectory: true
            )
            let downloaded = fileManager.fileExists(atPath: repoDir.path)
            let size = downloaded ? (try? sizeOfDirectory(at: repoDir)) : nil
            models.append(ManagedModel(
                id: "llm-\(spec.id)",
                kind: .llm(spec),
                isDownloaded: downloaded,
                sizeOnDisk: size
            ))
        }

        return models
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

        case .llm(let spec):
            let llmCacheDir = try llmModelCacheDirectory()
            let repoDir = llmCacheDir.appendingPathComponent(
                spec.huggingFaceRepo.replacingOccurrences(of: "/", with: "--"),
                isDirectory: true
            )
            if fileManager.fileExists(atPath: repoDir.path) {
                try fileManager.removeItem(at: repoDir)
            }
        }
    }

    // MARK: - Total Size

    nonisolated func totalDownloadedSize(from models: [ManagedModel]) -> Int64 {
        models.compactMap(\.sizeOnDisk).reduce(0, +)
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
}

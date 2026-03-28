import Foundation

@MainActor
protocol TranscriptionProvider: AnyObject {
    var onEvent: ((ProviderEvent) -> Void)? { get set }

    func start() throws
    func shutdown()

    func getInfo() async throws -> ProviderInfo
    func verifyToken(_ token: String) async throws -> TokenVerificationResult
    func enqueue(paths: [String]) async throws -> ProviderSnapshot
    func startTranscription(_ request: TranscriptionRequest) async throws -> ProviderSnapshot
    func prepareAdvancedFeatures(
        modelPreset: WhisperModelPreset,
        enhancement: Bool,
        diarization: Bool,
        proofreading: Bool,
        log: @escaping @Sendable (String) -> Void
    ) async throws
    func setPaused(_ paused: Bool) async throws -> ProviderSnapshot
    func stopCurrent() async throws -> StopRequestResult
    func clearQueue() async throws -> ProviderSnapshot
    func removeQueueItem(fileId: String) async throws -> ProviderSnapshot
    func saveResult(fileId: String, destinationPath: String) async throws
}

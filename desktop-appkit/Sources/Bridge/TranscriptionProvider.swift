import Foundation

@MainActor
protocol TranscriptionProvider: AnyObject {
    var onEvent: ((ProviderEvent) -> Void)? { get set }

    func start() throws
    func shutdown()

    func getInfo() async throws -> ProviderInfo
    func subscribeEvents() async throws
    func verifyToken(_ token: String) async throws -> TokenVerificationResult
    func enqueue(paths: [String]) async throws -> ProviderSnapshot
    func startTranscription(_ request: TranscriptionRequest) async throws -> ProviderSnapshot
    func setPaused(_ paused: Bool) async throws -> ProviderSnapshot
    func stopCurrent() async throws -> StopRequestResult
    func clearQueue() async throws -> ProviderSnapshot
    func removeQueueItem(fileId: String) async throws -> ProviderSnapshot
    func saveResult(fileId: String, destinationPath: String) async throws
    func saveAllResults(fileIds: [String], destinationPath: String) async throws
}

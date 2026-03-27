import Foundation

@MainActor
final class PythonBackendProvider: TranscriptionProvider {
    private let client: BackendClient
    var onEvent: ((ProviderEvent) -> Void)?

    init(client: BackendClient = BackendClient()) {
        self.client = client
        self.client.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if let mapped = Self.mapEvent(event) {
                    NativeLogger.log("provider event: \(mapped)")
                    self.onEvent?(mapped)
                }
            }
        }
    }

    func start() throws {
        try client.start()
    }

    func shutdown() {
        client.shutdown()
    }

    func getInfo() async throws -> ProviderInfo {
        let value = try await client.sendAsync(command: "get_info")
        guard let dict = value as? [String: Any] else {
            throw NSError(domain: "PythonBackendProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "get_info 回傳格式錯誤"])
        }
        return try Self.parseInfo(dict)
    }

    func subscribeEvents() async throws {
        _ = try await client.sendAsync(command: "subscribe_events")
    }

    func verifyToken(_ token: String) async throws -> TokenVerificationResult {
        let value = try await client.sendAsync(command: "verify_token", args: ["token": token])
        guard let dict = value as? [String: Any] else {
            throw NSError(domain: "PythonBackendProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "verify_token 回傳格式錯誤"])
        }
        return TokenVerificationResult(
            ok: dict["ok"] as? Bool ?? false,
            message: dict["message"] as? String ?? "Token 驗證失敗"
        )
    }

    func enqueue(paths: [String]) async throws -> ProviderSnapshot {
        let value = try await client.sendAsync(command: "enqueue_files", args: ["paths": paths])
        guard let dict = value as? [String: Any],
              let snapshotDict = dict["queue"] as? [String: Any] else {
            throw NSError(domain: "PythonBackendProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "enqueue_files 回傳格式錯誤"])
        }
        return Self.parseSnapshot(snapshotDict)
    }

    func startTranscription(_ request: TranscriptionRequest) async throws -> ProviderSnapshot {
        let value = try await client.sendAsync(command: "start_transcription", args: [
            "language": request.language,
            "diarize": request.diarize,
            "speakers": request.speakers,
            "token": request.token,
        ])
        guard let dict = value as? [String: Any],
              let snapshotDict = dict["queue"] as? [String: Any] else {
            throw NSError(domain: "PythonBackendProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "start_transcription 回傳格式錯誤"])
        }
        return Self.parseSnapshot(snapshotDict)
    }

    func setPaused(_ paused: Bool) async throws -> ProviderSnapshot {
        let value = try await client.sendAsync(command: "pause_queue", args: ["paused": paused])
        guard let dict = value as? [String: Any],
              let snapshotDict = dict["queue"] as? [String: Any] else {
            throw NSError(domain: "PythonBackendProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "pause_queue 回傳格式錯誤"])
        }
        return Self.parseSnapshot(snapshotDict)
    }

    func stopCurrent() async throws -> StopRequestResult {
        let value = try await client.sendAsync(command: "stop_current")
        guard let dict = value as? [String: Any],
              let snapshotDict = dict["queue"] as? [String: Any] else {
            throw NSError(domain: "PythonBackendProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "stop_current 回傳格式錯誤"])
        }
        return StopRequestResult(
            accepted: dict["stopping"] as? Bool ?? dict["accepted"] as? Bool ?? false,
            hardStopped: dict["hard_stopped"] as? Bool ?? false,
            supportsHardStop: dict["supports_hard_stop"] as? Bool ?? false,
            message: dict["message"] as? String ?? "",
            snapshot: Self.parseSnapshot(snapshotDict)
        )
    }

    func clearQueue() async throws -> ProviderSnapshot {
        let value = try await client.sendAsync(command: "clear_queue")
        guard let dict = value as? [String: Any],
              let snapshotDict = dict["queue"] as? [String: Any] else {
            throw NSError(domain: "PythonBackendProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "clear_queue 回傳格式錯誤"])
        }
        return Self.parseSnapshot(snapshotDict)
    }

    func removeQueueItem(fileId: String) async throws -> ProviderSnapshot {
        throw NSError(
            domain: "PythonBackendProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "舊 Python backend 路線目前不支援單檔刪除"]
        )
    }

    func saveResult(fileId: String, destinationPath: String) async throws {
        _ = try await client.sendAsync(command: "save_result", args: [
            "file_id": fileId,
            "destination_path": destinationPath,
        ])
    }

    func saveAllResults(fileIds: [String], destinationPath: String) async throws {
        _ = try await client.sendAsync(command: "save_all_results", args: [
            "file_ids": fileIds,
            "destination_path": destinationPath,
        ])
    }

    private static func mapEvent(_ event: BackendEvent) -> ProviderEvent? {
        switch event.name {
        case "backend_ready":
            guard let infoDict = event.data["info"] as? [String: Any],
                  let info = try? parseInfo(infoDict) else { return nil }
            return .backendReady(info)
        case "queue_updated":
            return .queueUpdated(parseSnapshot(event.data))
        case "queue_paused":
            return .queuePaused(event.data["message"] as? String ?? "佇列已暫停")
        case "queue_resumed":
            return .queueResumed(event.data["message"] as? String ?? "佇列已恢復")
        case "task_started":
            let fileId = event.data["fileId"] as? String ?? event.data["file_id"] as? String ?? ""
            let filename = event.data["filename"] as? String ?? "音訊檔"
            return .taskStarted(fileId: fileId, filename: filename)
        case "task_progress":
            let fileId = event.data["fileId"] as? String ?? event.data["file_id"] as? String ?? ""
            let message = event.data["message"] as? String ?? "轉譯中..."
            let progress = event.data["progress"] as? Int
            return .taskProgress(fileId: fileId, message: message, progress: progress)
        case "task_partial_text":
            let fileId = event.data["fileId"] as? String ?? event.data["file_id"] as? String ?? ""
            return .taskPartialText(fileId: fileId, text: event.data["text"] as? String ?? "")
        case "task_completed":
            let fileId = event.data["fileId"] as? String ?? event.data["file_id"] as? String ?? ""
            let filename = event.data["filename"] as? String ?? "檔案"
            guard let resultDict = event.data["result"] as? [String: Any],
                  let result = parseTranscriptResult(resultDict) else { return nil }
            return .taskCompleted(fileId: fileId, filename: filename, result: result)
        case "task_failed":
            let fileId = event.data["fileId"] as? String ?? event.data["file_id"] as? String ?? ""
            return .taskFailed(fileId: fileId, message: event.data["message"] as? String ?? "轉譯失敗")
        case "task_stopped":
            let fileId = event.data["fileId"] as? String ?? event.data["file_id"] as? String ?? ""
            return .taskStopped(fileId: fileId, message: event.data["message"] as? String ?? "已停止")
        case "backend_error":
            return .backendError(event.data["message"] as? String ?? "桌面 backend 發生錯誤")
        default:
            return nil
        }
    }

    private static func parseInfo(_ dict: [String: Any]) throws -> ProviderInfo {
        ProviderInfo(
            engine: dict["engine"] as? String ?? "unknown",
            model: dict["model"] as? String ?? "unknown",
            device: dict["device"] as? String ?? "unknown",
            supportsHardStop: dict["supports_hard_stop"] as? Bool ?? false,
            snapshot: parseSnapshot((dict["state"] as? [String: Any]) ?? [:])
        )
    }

    private static func parseSnapshot(_ dict: [String: Any]) -> ProviderSnapshot {
        let items = (dict["items"] as? [[String: Any]] ?? dict["queue"] as? [[String: Any]] ?? [])
            .compactMap(parseQueueItem)
        return ProviderSnapshot(
            items: items,
            isProcessing: dict["running"] as? Bool ?? dict["isProcessing"] as? Bool ?? false,
            isPaused: dict["paused"] as? Bool ?? dict["isPaused"] as? Bool ?? false,
            stopRequested: dict["stop_requested"] as? Bool ?? dict["stopRequested"] as? Bool ?? false,
            supportsHardStop: dict["supports_hard_stop"] as? Bool ?? dict["supportsHardStop"] as? Bool ?? false,
            currentFileId: dict["current_file_id"] as? String ?? dict["currentFileId"] as? String
        )
    }

    private static func parseQueueItem(_ dict: [String: Any]) -> QueueItemModel? {
        let id = dict["id"] as? String ?? dict["fileId"] as? String ?? dict["file_id"] as? String
        let fileId = dict["fileId"] as? String ?? dict["file_id"] as? String ?? dict["id"] as? String
        guard let id, let fileId else { return nil }
        return QueueItemModel(
            id: id,
            fileId: fileId,
            sourcePath: dict["path"] as? String ?? dict["sourcePath"] as? String ?? "",
            filename: dict["filename"] as? String ?? dict["name"] as? String ?? "未知檔案",
            size: Int64(dict["size"] as? Int ?? 0),
            status: dict["status"] as? String ?? "pending",
            progress: dict["progress"] as? Int ?? 0,
            message: dict["message"] as? String ?? "",
            error: dict["error"] as? String,
            result: parseTranscriptResult(dict["result"] as? [String: Any])
        )
    }

    private static func parseTranscriptResult(_ dict: [String: Any]?) -> TranscriptResult? {
        guard let dict else { return nil }
        return TranscriptResult(
            text: dict["text"] as? String ?? "",
            language: dict["language"] as? String,
            count: dict["count"] as? Int ?? 0,
            hasSpeakers: dict["has_speakers"] as? Bool ?? false,
            suggestedFilename: dict["suggestedFilename"] as? String ?? "transcript.txt",
            segments: []
        )
    }
}

extension ProviderEvent: CustomStringConvertible {
    var description: String {
        switch self {
        case .backendReady(let info):
            return "backendReady(engine: \(info.engine))"
        case .queueUpdated(let snapshot):
            return "queueUpdated(items: \(snapshot.items.count), processing: \(snapshot.isProcessing))"
        case .queuePaused(let message):
            return "queuePaused(\(message))"
        case .queueResumed(let message):
            return "queueResumed(\(message))"
        case .taskStarted(_, let filename):
            return "taskStarted(\(filename))"
        case .taskProgress(_, let message, _):
            return "taskProgress(\(message))"
        case .taskLog(_, let message):
            return "taskLog(\(message))"
        case .taskPartialText:
            return "taskPartialText"
        case .taskCompleted(_, let filename, _):
            return "taskCompleted(\(filename))"
        case .taskFailed(_, let message):
            return "taskFailed(\(message))"
        case .taskStopped(_, let message):
            return "taskStopped(\(message))"
        case .taskPhaseChanged(_, let phase, _):
            return "taskPhaseChanged(\(phase.rawValue))"
        case .taskDownloadProgress(_, let info):
            return "taskDownloadProgress(\(info.filename): \(info.fractionCompleted))"
        case .backendError(let message):
            return "backendError(\(message))"
        }
    }
}

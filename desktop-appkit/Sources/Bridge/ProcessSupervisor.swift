import Darwin
import Foundation

actor ProcessSupervisor {
    enum Stage: CaseIterable {
        case enhancement
        case headless
        case diarization
    }

    private var pids: [Stage: Int32] = [:]
    private var temporaryURLs: Set<URL> = []

    func register(pid: Int32, for stage: Stage) {
        guard pid > 0 else { return }
        pids[stage] = pid
    }

    func clear(_ stage: Stage, matching pid: Int32? = nil) {
        if let pid {
            guard pids[stage] == pid else { return }
        }
        pids.removeValue(forKey: stage)
    }

    func trackTemporaryFile(_ url: URL) {
        temporaryURLs.insert(url)
    }

    func cleanupTemporaryFile(_ url: URL) {
        temporaryURLs.remove(url)
        try? FileManager.default.removeItem(at: url)
    }

    func cleanupAllTemporaryFiles() {
        let urls = temporaryURLs
        temporaryURLs.removeAll()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func terminateAll() async {
        let activePIDs = pids.values
        pids.removeAll()
        for pid in activePIDs where pid > 0 {
            await terminate(pid: pid)
        }
    }

    private func terminate(pid: Int32) async {
        if kill(pid, 0) != 0 { return }
        kill(pid, SIGINT)
        try? await Task.sleep(nanoseconds: 300_000_000)
        if kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
        }
        for _ in 0..<10 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }
}

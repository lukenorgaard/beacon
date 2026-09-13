import Foundation

/// A CLI process and the rollout it has open are one session. Folder names cannot establish
/// this identity: multiple terminals commonly work in the same repository.
enum CodexDiscoveryMerge {
    static func merge(
        files: [Session], processes: [Session], rollouts: [Session],
        openRollouts: (Int32) -> Set<String> = CodexProcessFiles.openRollouts
    ) -> [Session] {
        let cli = rollouts.filter { $0.host != .codexApp }
        var matches: [Int32: Session] = [:]
        var owners: [String: Set<Int32>] = [:]
        for process in processes where process.agent == .codex && !cli.isEmpty {
            guard let pid = process.pid, pid > 0 else { continue }
            let paths = Set(openRollouts(pid).map(fileIdentity))
            let candidates = cli.filter { row in
                row.transcriptPath.map { paths.contains(fileIdentity($0)) } ?? false
            }
            guard candidates.count == 1, let row = candidates.first else { continue }
            matches[pid] = row
            owners[row.sessionID, default: []].insert(pid)
        }

        let enriched = processes.map { process -> Session in
            guard let pid = process.pid, var row = matches[pid],
                  owners[row.sessionID]?.count == 1
            else { return process }
            row.pid = pid
            row.tty = process.tty
            row.shellPid = process.shellPid
            row.host = process.host
            row.hostPID = process.hostPID
            row.hostRef = process.hostRef
            return row
        }
        // CLI rows require a live process. If descriptor access is denied or ambiguous, keep
        // the existing process row; do not add an unverified second row from its transcript.
        // Desktop threads share an app-server and remain discoverable without a per-thread PID.
        let desktop = rollouts.filter { $0.host == .codexApp }
        return Session.merge(files: files, discovered: enriched + desktop)
    }

    private static func fileIdentity(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

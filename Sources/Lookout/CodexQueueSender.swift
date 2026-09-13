import Foundation
import os

/// SPEC §17.7: `codex queue --thread <session_id> --message <text>` delivers a reply into a
/// running Codex session through the shared local app-server daemon every `codex` process
/// registers on — an idle thread starts a new turn at once, a busy one runs it when the current
/// turn ends. This is Codex's `Send` channel; there is no messaging socket for it (SPEC §11.2).
enum CodexQueueSender {
    private static let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "codex-queue")

    static let timeout: TimeInterval = 5

    enum Result: Equatable {
        case sent
        case failed(reason: String)

        var isSuccess: Bool {
            if case .sent = self { return true }
            return false
        }

        var reason: String? {
            if case .failed(let reason) = self { return reason }
            return nil
        }
    }

    /// PATH first, then the fixed locations the CLI is commonly installed to.
    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String? {
        if let onPath = ClaudeBinary.which("codex", environment: environment, fileManager: fileManager) {
            return onPath
        }
        let candidates = [
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".codex/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Off the main thread, always: the whole call can spend up to `timeout` seconds.
    static func send(
        text: String,
        session: Session,
        home: LookoutHome = LookoutHome(),
        binary: String? = nil,
        timeout: TimeInterval = CodexQueueSender.timeout,
        queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated),
        completion: @escaping (Result) -> Void
    ) {
        queue.async {
            let result = sendSynchronously(
                text: text, session: session, home: home, binary: binary, timeout: timeout
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func sendSynchronously(
        text: String, session: Session, home: LookoutHome = LookoutHome(), binary: String? = nil,
        timeout: TimeInterval = CodexQueueSender.timeout
    ) -> Result {
        guard session.agent == .codex else {
            return finish(.failed(reason: "codex queue is codex-only"), session: session, home: home)
        }
        guard !session.sessionID.isEmpty else {
            return finish(.failed(reason: "no session id"), session: session, home: home)
        }
        guard let resolved = binary ?? discover() else {
            return finish(.failed(reason: "codex binary not found"), session: session, home: home)
        }

        let result = Shell.run(
            resolved, ["queue", "--thread", session.sessionID, "--message", text],
            timeout: timeout, mergeStandardError: true
        )
        if result.timedOut {
            return finish(.failed(reason: "timed out"), session: session, home: home)
        }
        guard result.exitCode == 0 else {
            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = output.isEmpty ? "exit \(result.exitCode)" : String(output.prefix(200))
            return finish(.failed(reason: reason), session: session, home: home)
        }
        return finish(.sent, session: session, home: home)
    }

    /// SPEC §17.7: logged to `~/.lookout/answers.log` under the `codex-queue` channel.
    private static func finish(_ result: Result, session: Session, home: LookoutHome) -> Result {
        AnswerAudit.record(
            session: session, channel: .codexQueue,
            outcome: result.isSuccess ? "sent" : "failed: \(result.reason ?? "")",
            home: home
        )
        log.notice("codex queue \(result.isSuccess ? "ok" : "failed", privacy: .public)")
        return result
    }
}

import Darwin
import Foundation
import os

/// Delivers a reply into a live Claude Code session over its own messaging socket (SPEC §11.2).
///
/// The protocol is the binary's own usage hint: two newline-terminated JSON lines over a Unix
/// stream socket, an auth line and then the user message. The token is read at send time — from
/// the reporter's token file first, from the process environment second (SPEC §15.1) — and is
/// never written anywhere by the app: not to disk, not to the log, not to `os_log`.
enum SessionMessenger {
    private static let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "send")

    /// SPEC §11.4: 2 s for the connection, 2 s for each write, 2 s for a reply.
    static let timeout: TimeInterval = 2
    /// The session never answers a delivered user message (observed: `reply=<none>` on every
    /// send), so waiting the full connection timeout for one only made Send feel slow. A short
    /// grace period still catches an immediate error line.
    static let replyTimeout: TimeInterval = 0.3

    /// What the card's status line is built from.
    enum Result: Equatable {
        /// Both lines were accepted and nothing came back that looked like an error.
        case sent(reply: String?)
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

    // MARK: - Public API

    /// Off the main thread, always: the whole call can spend six seconds in the worst case.
    static func send(
        text: String,
        session: Session,
        home: LookoutHome = LookoutHome(),
        queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated),
        environment: @escaping ProcessEnvironmentReader = ProcessSnapshot.messaging(of:),
        completion: @escaping (Result) -> Void
    ) {
        queue.async {
            let result = sendSynchronously(
                text: text, session: session, home: home, environment: environment
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Resolves the socket and the token, sends, and logs the outcome.
    ///
    /// `environment` is the seam the tests drive: in the app it is always the live
    /// `KERN_PROCARGS2` read, which no test may perform against a real session.
    static func sendSynchronously(
        text: String,
        session: Session,
        home: LookoutHome = LookoutHome(),
        environment: ProcessEnvironmentReader = ProcessSnapshot.messaging(of:)
    ) -> Result {
        guard session.agent == .claude else {
            return finish(.failed(reason: "no messaging socket for \(session.agent.display)"),
                          session: session, home: home)
        }
        guard let pid = session.pid, pid > 0, SessionStore.isAlive(pid) else {
            return finish(.failed(reason: "session process is gone"), session: session, home: home)
        }

        // SPEC §15.1: the token file first — `CLAUDE_CODE_MESSAGING_TOKEN` is set at runtime, so
        // it is not in the exec-time argument block and only the reporter ever sees it. The
        // procargs read stays as the fallback, and is skipped entirely when the two things it
        // could still answer (socket, token) are both already known.
        let fileToken = tokenFile(for: session, home: home)
        let stateSocket = Session.text(session.messagingSocket)
        var process: (socket: String?, token: SecretToken?) = (nil, nil)
        if stateSocket == nil || fileToken == nil { process = environment(pid) }

        guard let socket = stateSocket ?? Session.text(process.socket) else {
            return finish(.failed(reason: "no messaging socket"), session: session, home: home)
        }
        guard let resolved = resolve(file: fileToken, process: process.token) else {
            return finish(.failed(reason: noTokenReason), session: session, home: home)
        }

        let result = send(text: framed(text), socketPath: socket, token: resolved.token)
        return finish(
            result, session: session, home: home,
            socket: socket, token: resolved.token, source: resolved.source
        )
    }

    // MARK: - Framing (SPEC §17.12)

    /// What the session's model reads first. Claude Code files anything arriving on this socket
    /// as a message from another session with no sender ("Another Claude session sent a
    /// message"), so a model with a teammate to answer and no address for it will pick one —
    /// the owner's "go start on 09, 10 and 12" produced a reply into an unrelated session. The header
    /// names the real sender and closes the door on replying anywhere but here.
    static let header = """
        [Beacon] This message was typed by your user in Beacon, a panel on this Mac — it is not \
        from another Claude session. Answer here in this session; do not SendMessage anyone about it.
        """

    /// The header plus the text, except for slash commands (`/rename`, `/compact`), which the
    /// session only recognises when the line starts with the slash. Bug fix, 2026-09-06: a plain
    /// `text.hasPrefix("/")` also matched a path a user happened to type first ("/tmp/build.log
    /// has the answer") and missed a real command typed with a leading space (" /compact") — both
    /// wrong in opposite directions. `isSlashCommand` below is what actually decides; the command
    /// itself is sent trimmed, so the session always sees a line that genuinely starts with `/`.
    static func framed(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSlashCommand(trimmed) { return trimmed }
        return header + "\n\n" + text
    }

    /// A slash command is `/`, a letter, then letters/digits/hyphens, then whitespace or the end
    /// of the string — `/rename Nova`, `/compact`. A path that merely starts with a slash
    /// ("/tmp/build.log", "/Users/you/notes.md") never matches: the character right after the
    /// next `/` is not whitespace or the end, so the pattern fails there. Case-insensitive only
    /// because a command name being typed in caps should not itself defeat detection.
    static func isSlashCommand(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "^/[a-z][a-z0-9-]*(\\s|$)", options: [.caseInsensitive]
        ) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: - The token (SPEC §15.1)

    /// How `ProcessSnapshot.messaging(of:)` is shaped, named so the seam reads as one thing.
    typealias ProcessEnvironmentReader = (pid_t) -> (socket: String?, token: SecretToken?)

    /// Where a token came from — logged (the source, never the secret) so a failed Send can be
    /// told apart from a session that simply has not reported since the upgrade.
    enum TokenSource: String, Equatable {
        case file
        case process
    }

    struct ResolvedToken: Equatable {
        let token: SecretToken
        let source: TokenSource
    }

    /// The status line when neither source has a token (SPEC §15.1).
    static let noTokenReason = "no token file yet — the session has not reported since the upgrade"

    /// `~/.lookout/tokens/<agent>-<session_id>.token`, trimmed. Never logged, never copied
    /// anywhere but into the `SecretToken` wrapper.
    static func tokenFile(for session: Session, home: LookoutHome) -> SecretToken? {
        guard !session.sessionID.isEmpty else { return nil }
        let url = home.tokenFile(agent: session.agent, sessionID: session.sessionID)
        guard let data = try? Data(contentsOf: url), data.count <= maxTokenFileBytes,
              let text = String(data: data, encoding: .utf8),
              let trimmed = Session.text(text)
        else { return nil }
        return SecretToken(trimmed)
    }

    /// A token file bigger than this is not a token; it is not read into memory.
    static let maxTokenFileBytes = 8 * 1024

    /// SPEC §15.1's order: the file wins, the process environment is the fallback.
    static func resolve(file: SecretToken?, process: SecretToken?) -> ResolvedToken? {
        if let file, !file.isEmpty { return ResolvedToken(token: file, source: .file) }
        if let process, !process.isEmpty { return ResolvedToken(token: process, source: .process) }
        return nil
    }

    /// The wire half, with no notion of a session — this is what the tests drive against a fake
    /// server.
    static func send(
        text: String,
        socketPath: String,
        token: SecretToken,
        timeout: TimeInterval = SessionMessenger.timeout
    ) -> Result {
        guard let auth = line(["type": "auth", "token": token.value]) else {
            return .failed(reason: "could not encode the auth line")
        }
        guard let message = line([
            "type": "user",
            "message": ["role": "user", "content": text],
        ]) else {
            return .failed(reason: "could not encode the message")
        }

        let connection = Connection(path: socketPath, timeout: timeout)
        switch connection.open() {
        case .failure(let reason): return .failed(reason: reason)
        case .success: break
        }
        defer { connection.close() }

        if case .failure(let reason) = connection.write(auth) {
            return .failed(reason: "auth line: \(reason)")
        }
        if case .failure(let reason) = connection.write(message) {
            return .failed(reason: "message line: \(reason)")
        }

        switch connection.readLine() {
        case .closed:
            // The peer hung up without answering: the message went nowhere (SPEC §11.4's
            // `Send failed (socket closed)`).
            return .failed(reason: "socket closed")
        case .timedOut:
            // Silence is normal — the session queues the message when it is busy (SPEC §11.2).
            return .sent(reply: nil)
        case .failure(let reason):
            return .failed(reason: reason)
        case .line(let reply):
            if let problem = errorText(in: reply) { return .failed(reason: problem) }
            return .sent(reply: reply)
        }
    }

    // MARK: - Wire helpers

    /// One JSON object plus the newline the protocol separates lines with.
    static func line(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else { return nil }
        data.append(0x0A)
        return data
    }

    /// SPEC §11.4: success = the socket accepted both lines and any reply is not an error.
    /// A reply that is not JSON at all carries no error key, so it counts as accepted — the ack
    /// line's real shape is unknown until a live session answers one (SPEC §11.2).
    static func errorText(in reply: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let ok = object["ok"] as? Bool, ok == false {
            return describe(object["error"]) ?? "rejected"
        }
        if let ok = object["ok"] as? NSNumber, ok.boolValue == false {
            return describe(object["error"]) ?? "rejected"
        }
        guard object.keys.contains("error") else { return nil }
        return describe(object["error"]) ?? "error"
    }

    private static func describe(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return Session.text(text)
        case let nested as [String: Any]:
            return Session.text(nested["message"] as? String)
                ?? Session.text(nested["code"] as? String)
                ?? "error"
        case is NSNull, nil:
            return nil
        default:
            return "error"
        }
    }

    /// `~/.lookout/send.log`, token redacted (SPEC §11.4). The reply is logged raw *after* the
    /// token has been scrubbed out of it, which is the only way to learn the real ack shape.
    static func redact(_ text: String, token: SecretToken?) -> String {
        var result = text
        if let token, !token.isEmpty {
            result = result.replacingOccurrences(of: token.value, with: "<redacted>")
        }
        // Belt and braces: any `"token":"…"` pair goes, whatever value it holds. One pass —
        // the replacement matches the pattern too, so a loop here would never terminate.
        result = result.replacingOccurrences(
            of: "\"token\"\\s*:\\s*\"[^\"]*\"",
            with: "\"token\":\"<redacted>\"",
            options: .regularExpression
        )
        return result
    }

    private static func finish(
        _ result: Result, session: Session, home: LookoutHome,
        socket: String? = nil, token: SecretToken? = nil, source: TokenSource? = nil
    ) -> Result {
        var parts = ["session=\(session.sessionID)"]
        if let socket { parts.append("socket=\(socket)") }
        // The *source* of the token, never the token.
        if let source { parts.append("token=\(source.rawValue)") }
        switch result {
        case .sent(let reply):
            parts.append("outcome=sent")
            if let reply = Session.text(reply) {
                parts.append("reply=\(redact(String(reply.prefix(400)), token: token))")
            } else {
                parts.append("reply=<none>")
            }
        case .failed(let reason):
            parts.append("outcome=failed")
            parts.append("reason=\(redact(reason, token: token))")
        }
        LogFile.append(parts.joined(separator: " "), to: home.sendLog)
        log.notice("send \(result.isSuccess ? "ok" : "failed", privacy: .public)")
        return result
    }
}

// MARK: - The socket itself

extension SessionMessenger {
    /// A non-blocking `AF_UNIX` / `SOCK_STREAM` connection where every wait goes through `poll`,
    /// so nothing here can hang longer than its deadline.
    final class Connection {
        enum Outcome {
            case success
            case failure(String)
        }

        enum ReadOutcome: Equatable {
            case line(String)
            case timedOut
            case closed
            case failure(String)
        }

        private let path: String
        private let timeout: TimeInterval
        private var fd: Int32 = -1

        init(path: String, timeout: TimeInterval) {
            self.path = path
            self.timeout = timeout
        }

        deinit { close() }

        /// `sun_path` is 104 bytes on Darwin, NUL included.
        static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

        func open() -> Outcome {
            let bytes = Array(path.utf8)
            guard !bytes.isEmpty else { return .failure("empty socket path") }
            guard bytes.count <= Connection.maxPathLength else {
                return .failure("socket path too long")
            }

            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return .failure("socket(): \(errnoText())") }
            fd = descriptor

            // Without SO_NOSIGPIPE a write to a socket the session already closed would kill
            // Lookout with SIGPIPE instead of returning EPIPE.
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                guard let base = raw.baseAddress else { return }
                base.copyMemory(from: bytes, byteCount: bytes.count)
                raw[bytes.count] = 0
            }

            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(fd, sockaddrPointer, size)
                }
            }
            if connected == 0 { return .success }
            guard errno == EINPROGRESS else { return .failure("connect(): \(errnoText())") }

            switch wait(for: Int16(POLLOUT)) {
            case .failure(let reason): return .failure("connect(): \(reason)")
            case .success: break
            }

            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
                return .failure("connect(): \(errnoText())")
            }
            guard error == 0 else {
                return .failure("connect(): \(String(cString: strerror(error)))")
            }
            return .success
        }

        func write(_ data: Data) -> Outcome {
            let remaining = [UInt8](data)
            var offset = 0
            let deadline = Date().addingTimeInterval(timeout)

            while offset < remaining.count {
                if Date() >= deadline { return .failure("write timed out") }
                let written = remaining.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), remaining.count - offset)
                }
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { return .failure("socket closed") }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    switch wait(for: Int16(POLLOUT), until: deadline) {
                    case .failure(let reason): return .failure(reason)
                    case .success: continue
                    }
                }
                if errno == EINTR { continue }
                return .failure(errnoText())
            }
            return .success
        }

        /// Reads until the first newline, or until the deadline. An immediate EOF is reported as
        /// `.closed`, which is what tells Send from a silent success.
        func readLine() -> ReadOutcome {
            let deadline = Date().addingTimeInterval(SessionMessenger.replyTimeout)
            var buffer = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)

            while true {
                if Date() >= deadline {
                    return buffer.isEmpty ? .timedOut : .line(text(buffer))
                }
                switch wait(for: Int16(POLLIN), until: deadline) {
                case .failure(let reason):
                    if reason == "timed out" {
                        return buffer.isEmpty ? .timedOut : .line(text(buffer))
                    }
                    return .failure(reason)
                case .success:
                    break
                }

                let count = chunk.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.read(fd, base, raw.count)
                }
                if count == 0 {
                    return buffer.isEmpty ? .closed : .line(text(buffer))
                }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    return .failure(errnoText())
                }
                for index in 0..<count {
                    if chunk[index] == 0x0A { return .line(text(buffer)) }
                    buffer.append(chunk[index])
                    if buffer.count > 64 * 1024 { return .line(text(buffer)) }
                }
            }
        }

        func close() {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }

        // MARK: Waiting

        private func wait(for events: Int16, until deadline: Date? = nil) -> Outcome {
            let end = deadline ?? Date().addingTimeInterval(timeout)
            while true {
                let remaining = end.timeIntervalSinceNow
                if remaining <= 0 { return .failure("timed out") }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining, timeout) * 1000) + 1)
                if ready > 0 {
                    if descriptor.revents & Int16(POLLNVAL) != 0 { return .failure("socket closed") }
                    if descriptor.revents & Int16(POLLERR) != 0 { return .failure("socket error") }
                    return .success
                }
                if ready == 0 { return .failure("timed out") }
                if errno == EINTR { continue }
                return .failure(errnoText())
            }
        }

        private func text(_ bytes: [UInt8]) -> String {
            String(decoding: bytes, as: UTF8.self)
        }

        private func errnoText() -> String {
            String(cString: strerror(errno))
        }
    }
}

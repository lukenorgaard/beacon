import Darwin
import Foundation
import XCTest
@testable import Lookout

// MARK: - A throwaway companion server

/// The editor companion's HTTP contract (SPEC §16.2), served by 120 lines of POSIX sockets so
/// `EditorCompanion` can be driven end to end without an editor, an extension host, or a single
/// byte going anywhere but `127.0.0.1`.
final class FakeCompanionServer {
    struct Recorded: Equatable {
        let method: String
        let path: String
        let authorization: String?
        let body: String
    }

    let token: String
    var port = 0

    /// What `GET /terminals` answers with.
    var terminals: [[String: Any]] = []
    /// When set, every authorised request answers with this status and `{}`.
    var forcedStatus: Int?

    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "lookout.tests.companion")
    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var stopped = false

    init(token: String = "0123456789abcdef0123456789abcdef") {
        self.token = token
    }

    var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    enum Failure: Error { case socket, bind(String), listen, name }

    func start() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.socket }
        var on: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, size)
            }
        }
        guard bound == 0 else { throw Failure.bind(String(cString: strerror(errno))) }
        guard Darwin.listen(listener, 8) == 0 else { throw Failure.listen }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else { throw Failure.name }
        port = Int(UInt16(bigEndian: actual.sin_port))

        queue.async { [weak self] in self?.serve() }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        if listener >= 0 { Darwin.close(listener) }
        listener = -1
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        while !isStopped {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        guard let (head, body) = readRequest(client) else { return }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        let method = requestLine.first ?? ""
        let path = requestLine.count > 1 ? requestLine[1] : ""
        var authorization: String?
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "authorization"
            else { continue }
            authorization = pieces[1].trimmingCharacters(in: .whitespaces)
        }

        lock.lock()
        recorded.append(
            Recorded(method: method, path: path, authorization: authorization, body: body)
        )
        lock.unlock()

        guard authorization == "Bearer \(token)" else {
            respond(client, status: 401, json: ["error": "unauthorized"])
            return
        }
        if let forcedStatus {
            respond(client, status: forcedStatus, json: ["error": "forced"])
            return
        }

        switch (method, path) {
        case ("GET", "/terminals"):
            respond(client, status: 200, array: terminals)
        case ("GET", "/ping"):
            respond(client, status: 200, json: ["app": "cursor", "pid": 1, "version": "0.1.0"])
        case ("POST", "/focus"), ("POST", "/send"):
            let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
                as? [String: Any] ?? [:]
            let wanted = (object["processId"] as? NSNumber)?.intValue ?? -1
            let found = terminals.first {
                ($0["processId"] as? NSNumber)?.intValue == wanted
            }
            guard let found else {
                respond(client, status: 404, json: ["error": "no terminal with that processId"])
                return
            }
            respond(client, status: 200, json: [
                "ok": true,
                "index": found["index"] ?? 0,
                "name": found["name"] ?? "",
                "processId": wanted,
            ])
        default:
            respond(client, status: 404, json: ["error": "not found"])
        }
    }

    /// Headers up to the blank line, then `Content-Length` more bytes.
    private func readRequest(_ client: Int32) -> (String, String)? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(3)

        func read() -> Bool {
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000) + 1
            guard poll(&descriptor, 1, remaining) > 0 else { return false }
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(client, base, raw.count)
            }
            guard count > 0 else { return false }
            buffer.append(contentsOf: chunk[0..<count])
            return true
        }

        func split() -> (head: String, body: Data)? {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            return (
                String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self),
                Data(buffer[separator.upperBound...])
            )
        }

        while split() == nil {
            guard Date() < deadline, read() else { return nil }
        }
        guard var parts = split() else { return nil }

        var length = 0
        for line in parts.head.components(separatedBy: "\r\n").dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            length = Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        while parts.body.count < length, Date() < deadline {
            guard read(), let refreshed = split() else { break }
            parts = refreshed
        }
        return (parts.head, String(decoding: parts.body, as: UTF8.self))
    }

    private func respond(_ client: Int32, status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        write(client, status: status, body: data)
    }

    private func respond(_ client: Int32, status: Int, array: [[String: Any]]) {
        let data = (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8)
        write(client, status: status, body: data)
    }

    func write(_ client: Int32, status: Int, body: Data) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(client, base.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

/// The seam `Jumper`, the card and the rename panel are driven through — no sockets, no editor.
final class StubCompanion: CompanionChannel {
    var result: CompanionMatch?
    var live: Set<String> = []
    private(set) var matchCalls: [(app: String, shellPid: Int32?, agent: String?)] = []
    private(set) var focusCalls: [(app: String, shellPid: Int32?)] = []
    private(set) var sentTexts: [String] = []

    static func match(
        app: String = "cursor", pid: Int32 = 4242, index: Int = 2, name: String = "claude",
        folders: [String] = [], rule: CompanionMatch.Rule = .pid
    ) -> CompanionMatch {
        CompanionMatch(
            instance: CompanionInstance(
                app: app, pid: 900, port: 51234, token: SecretToken("abcdefabcdefabcdefabcdef"),
                windowTitle: "repo", folders: folders, startedAt: nil, version: "0.1.0",
                file: URL(fileURLWithPath: "/tmp/\(app)-900.json")
            ),
            terminal: CompanionTerminal(
                index: index, name: name, processId: pid, cwd: nil, isActive: true
            ),
            rule: rule
        )
    }

    func match(app: String, shellPid: Int32?, agentCommand: String?) -> CompanionMatch? {
        matchCalls.append((app, shellPid, agentCommand))
        return result
    }

    func focus(app: String, shellPid: Int32?, agentCommand: String?) -> CompanionMatch? {
        focusCalls.append((app, shellPid))
        return result
    }

    func send(
        app: String, shellPid: Int32?, agentCommand: String?, text: String
    ) -> CompanionMatch? {
        sentTexts.append(text)
        return result
    }

    func hasLiveInstance(app: String) -> Bool { live.contains(app) }
}

// MARK: - The tests

/// SPEC §16.3: the Lookout half of the editor companion.

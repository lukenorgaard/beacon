import Darwin
import Foundation

/// The smallest HTTP/1.1 client that can talk to the editor companion (SPEC §16.2): one request,
/// one response, `Connection: close`, a hard deadline on every wait.
///
/// Hand-rolled rather than `URLSession` for three reasons: App Transport Security has an opinion
/// about cleartext HTTP that would need an Info.plist key this lane may not touch; the companion
/// lives on `127.0.0.1` where a shared session's cache, cookies and connection pool are pure
/// liability; and the whole call has to fit inside the 2 s budget §16.3 gives it, which `poll`
/// guarantees and a URLSession delegate does not.
///
/// Never call this on the main thread.
enum LocalHTTP {
    struct Response: Equatable {
        let status: Int
        let body: Data

        /// The body as JSON, or nil when it was not an object/array.
        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
    }

    enum Failure: Equatable {
        case connect(String)
        case write(String)
        case read(String)
        case malformed
        /// The token is not header-safe, so no request was made at all.
        case unusableToken

        var text: String {
            switch self {
            case .connect(let reason): return "connect: \(reason)"
            case .write(let reason): return "write: \(reason)"
            case .read(let reason): return "read: \(reason)"
            case .malformed: return "malformed response"
            case .unusableToken: return "unusable token"
            }
        }
    }

    enum Outcome: Equatable {
        case response(Response)
        case failure(Failure)

        var response: Response? {
            if case .response(let value) = self { return value }
            return nil
        }
    }

    /// A response larger than this is not one of ours; the read stops there.
    static let maxResponseBytes = 1024 * 1024

    /// The one place a token is put into a header. Anything that could break out of the header
    /// line — or is simply not what the extension writes — is refused before a socket is opened.
    static func isHeaderSafe(_ token: SecretToken) -> Bool {
        let value = token.value
        guard (8...256).contains(value.count) else { return false }
        return value.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || "-._~+/=".contains(character)
        }
    }

    /// One request/response round trip against `127.0.0.1:<port>`.
    ///
    /// `path` is always one of this file's callers' own constants — never anything read off a
    /// disk or a wire — so it is spliced into the request line as-is.
    static func request(
        port: Int,
        method: String,
        path: String,
        token: SecretToken,
        body: Data? = nil,
        timeout: TimeInterval
    ) -> Outcome {
        guard isHeaderSafe(token) else { return .failure(.unusableToken) }
        guard (1...65_535).contains(port) else { return .failure(.connect("bad port")) }

        let connection = Connection(port: port, timeout: timeout)
        switch connection.open() {
        case .failure(let reason): return .failure(.connect(reason))
        case .success: break
        }
        defer { connection.close() }

        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: 127.0.0.1:\(port)\r\n"
        head += "Authorization: Bearer \(token.value)\r\n"
        head += "Accept: application/json\r\n"
        head += "Connection: close\r\n"
        if let body {
            head += "Content-Type: application/json; charset=utf-8\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"

        var request = Data(head.utf8)
        if let body { request.append(body) }

        if case .failure(let reason) = connection.write(request) {
            return .failure(.write(reason))
        }
        switch connection.readAll() {
        case .failure(let reason): return .failure(.read(reason))
        case .success(let data):
            guard let response = parse(data) else { return .failure(.malformed) }
            return .response(response)
        }
    }

    /// Status line + headers + body. `Connection: close` means the body ends at EOF, so nothing
    /// here has to understand chunked encoding — but a `Content-Length` is honoured when present.
    static func parse(_ data: Data) -> Response? {
        guard let separator = range(of: Data("\r\n\r\n".utf8), in: data) else { return nil }
        let headerData = data[data.startIndex..<separator.lowerBound]
        let body = Data(data[separator.upperBound...])
        guard let header = String(data: headerData, encoding: .utf8) ?? String(
            data: headerData, encoding: .isoLatin1
        ) else { return nil }

        guard let statusLine = header.split(separator: "\r\n", omittingEmptySubsequences: false)
            .first else { return nil }
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]),
              (100...599).contains(status)
        else { return nil }

        // A well-behaved server sends both; trust the length when it is shorter than what the
        // socket handed over (a keep-alive proxy in between, say).
        if let length = contentLength(inHeader: header), length <= body.count {
            return Response(status: status, body: body.prefix(length))
        }
        return Response(status: status, body: body)
    }

    static func contentLength(inHeader header: String) -> Int? {
        for line in header.split(separator: "\r\n").dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(pieces[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        return haystack.range(of: needle)
    }
}

// MARK: - The socket

extension LocalHTTP {
    /// A non-blocking loopback TCP connection where every wait goes through `poll`, so nothing
    /// here can outlive its deadline. Same shape as `SessionMessenger.Connection`, over AF_INET.
    final class Connection {
        enum Outcome {
            case success
            case failure(String)
        }

        enum ReadOutcome {
            case success(Data)
            case failure(String)
        }

        private let port: Int
        private let timeout: TimeInterval
        private var fd: Int32 = -1

        init(port: Int, timeout: TimeInterval) {
            self.port = port
            self.timeout = timeout
        }

        deinit { close() }

        func open() -> Outcome {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return .failure(errnoText()) }
            fd = descriptor

            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian // 127.0.0.1, never a name

            let size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, size)
                }
            }
            if connected == 0 { return .success }
            guard errno == EINPROGRESS else { return .failure(errnoText()) }

            switch wait(for: Int16(POLLOUT)) {
            case .failure(let reason): return .failure(reason)
            case .success: break
            }

            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
                return .failure(errnoText())
            }
            guard error == 0 else { return .failure(String(cString: strerror(error))) }
            return .success
        }

        func write(_ data: Data) -> Outcome {
            let bytes = [UInt8](data)
            var offset = 0
            let deadline = Date().addingTimeInterval(timeout)

            while offset < bytes.count {
                if Date() >= deadline { return .failure("timed out") }
                let written = bytes.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
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

        /// Reads until the peer closes, the cap is hit, or the deadline passes.
        func readAll() -> ReadOutcome {
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)

            while true {
                if Date() >= deadline {
                    return buffer.isEmpty ? .failure("timed out") : .success(buffer)
                }
                switch wait(for: Int16(POLLIN), until: deadline) {
                case .failure(let reason):
                    if reason == "timed out", !buffer.isEmpty { return .success(buffer) }
                    return .failure(reason)
                case .success:
                    break
                }

                let count = chunk.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.read(fd, base, raw.count)
                }
                if count == 0 { return .success(buffer) }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    return buffer.isEmpty ? .failure(errnoText()) : .success(buffer)
                }
                buffer.append(contentsOf: chunk[0..<count])
                if buffer.count >= LocalHTTP.maxResponseBytes { return .success(buffer) }
            }
        }

        func close() {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }

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

        private func errnoText() -> String {
            String(cString: strerror(errno))
        }
    }
}

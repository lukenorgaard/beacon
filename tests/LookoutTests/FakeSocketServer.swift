import Darwin
import Foundation
import XCTest
@testable import Lookout

/// A throwaway `AF_UNIX` server, so `SessionMessenger` can be driven end to end without going
/// anywhere near a real session socket under `/tmp/cc-socks`.
final class FakeSocketServer {
    enum Behaviour {
        /// Read the two lines, then answer with this one.
        case reply(String)
        /// Accept and hang up at once — the `socket closed` path.
        case closeImmediately
        /// Accept, read, and never answer — a busy session that queues the message.
        case silent
    }

    let path: String
    let behaviour: Behaviour
    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "lookout.tests.fakesocket")
    private let lock = NSLock()
    var lines: [String] = []
    private var stopped = false

    init(behaviour: Behaviour) {
        // `sun_path` is 104 bytes; a UUID under `/tmp` fits with room to spare.
        path = "/tmp/lkt-\(UUID().uuidString.prefix(8)).sock"
        self.behaviour = behaviour
    }

    var receivedLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func start() throws {
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.socket }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.baseAddress?.copyMemory(from: bytes, byteCount: bytes.count)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, size)
            }
        }
        guard bound == 0 else { throw Failure.bind(String(cString: strerror(errno))) }
        guard Darwin.listen(listener, 4) == 0 else { throw Failure.listen }

        queue.async { [weak self] in self?.accept() }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        if listener >= 0 { Darwin.close(listener) }
        listener = -1
        unlink(path)
    }

    private func accept() {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        // Long enough for a client that is about to connect, short enough not to wedge a test.
        guard poll(&descriptor, 1, 5000) > 0 else { return }
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }

        if case .closeImmediately = behaviour { return }

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, receivedLines.count < 2 {
            var poller = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            if count <= 0 { break }
            for index in 0..<count {
                if chunk[index] == 0x0A {
                    let line = String(decoding: buffer, as: UTF8.self)
                    lock.lock()
                    lines.append(line)
                    lock.unlock()
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    buffer.append(chunk[index])
                }
            }
        }

        switch behaviour {
        case .reply(let text):
            let payload = Array((text + "\n").utf8)
            _ = payload.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        case .silent:
            // A real session holds the socket open while it queues the message; hanging up
            // here instead would be the `closeImmediately` case, not silence.
            Thread.sleep(forTimeInterval: 1.5)
        case .closeImmediately:
            break
        }
    }

    enum Failure: Error {
        case socket
        case bind(String)
        case listen
    }
}

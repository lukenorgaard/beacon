import Foundation
import Security
import os

/// Reads the OAuth token Claude Code keeps in the login keychain.
///
/// The token never leaves this file except as an `Authorization` header, and is never logged,
/// printed or written anywhere (SPEC §2.3, §5.6).
enum Keychain {
    static let service = "Claude Code-credentials"

    static func claudeAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return token(fromCredentialsJSON: data)
    }

    /// `{"claudeAiOauth": {"accessToken": "…"}}` — anything else is treated as no token.
    static func token(fromCredentialsJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }
}

/// Fetches `GET /api/oauth/usage` and keeps the last good snapshot (SPEC §2.3, §5.3).
final class UsageClient: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: UsageError?
    @Published private(set) var isRefreshing = false
    /// When the last *successful* fetch landed; drives `Updated 12s ago` / `Offline · last update…`.
    @Published private(set) var lastSuccess: Date?

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "usage")
    private let queue = DispatchQueue(label: "io.github.lukenorgaard.beacon.usage", qos: .utility)
    private let session: URLSession
    private var ticker: DispatchSourceTimer?
    private var interval: TimeInterval = 60
    private var inFlight = false
    private var lastAttempt: Date?

    init(session: URLSession? = nil, snapshot: UsageSnapshot? = nil) {
        self.snapshot = snapshot
        self.lastSuccess = snapshot == nil ? nil : Date()
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    deinit { ticker?.cancel() }

    func start(interval seconds: Int) {
        setInterval(seconds)
        refresh()
    }

    func setInterval(_ seconds: Int) {
        let value = TimeInterval(max(30, seconds))
        guard value != interval || ticker == nil else { return }
        interval = value
        ticker?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + value, repeating: value, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        ticker = timer
    }

    /// A turn just ended — refetch, but never more often than every 20 s (SPEC §5.3).
    func refreshAfterStop() {
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 20 { return }
        refresh()
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self, !self.inFlight else { return }
            self.inFlight = true
            self.lastAttempt = Date()
            DispatchQueue.main.async { self.isRefreshing = true }
            self.fetch(retryOn401: true)
        }
    }

    private func fetch(retryOn401: Bool) {
        // Development only: `LOOKOUT_USAGE_FIXTURE=/path/usage.json` skips the keychain and network.
        if let fixture = ProcessInfo.processInfo.environment["LOOKOUT_USAGE_FIXTURE"] {
            queue.async { [weak self] in
                guard let self else { return }
                if let data = FileManager.default.contents(atPath: fixture),
                   let snapshot = try? UsageSnapshot.parse(data) {
                    self.finish(.success(snapshot))
                } else {
                    self.finish(.failure(.malformed))
                }
            }
            return
        }
        guard let token = Keychain.claudeAccessToken() else {
            finish(.failure(.notSignedIn))
            return
        }

        var request = URLRequest(url: UsageClient.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Beacon/1.4", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.finish(.failure(.offline(error.localizedDescription)))
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 {
                    // Claude Code refreshes its own token; re-read the keychain and try once more.
                    if retryOn401 {
                        self.fetch(retryOn401: false)
                    } else {
                        self.finish(.failure(.expired))
                    }
                    return
                }
                guard (200..<300).contains(code) else {
                    self.finish(.failure(.http(code)))
                    return
                }
                guard let data else {
                    self.finish(.failure(.malformed))
                    return
                }
                do {
                    self.finish(.success(try UsageSnapshot.parse(data)))
                } catch {
                    self.finish(.failure(.malformed))
                }
            }
        }.resume()
    }

    private func finish(_ result: Result<UsageSnapshot, UsageError>) {
        inFlight = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.lastSuccess = snapshot.fetchedAt
                self.error = nil
            case .failure(let error):
                // Keep the last good values on a network blip (SPEC §5.3).
                self.error = error
                self.log.error("Usage fetch failed: \(error.message, privacy: .public)")
            }
        }
    }

    /// Footer text: `Updated 12s ago`, or what went wrong.
    func statusText(now: Date = Date()) -> String {
        if isRefreshing && snapshot == nil { return "Loading…" }
        if let error {
            switch error {
            case .notSignedIn, .expired:
                return error.message
            default:
                if let lastSuccess {
                    return "Offline · last update \(Format.duration(now.timeIntervalSince(lastSuccess))) ago"
                }
                return error.message
            }
        }
        guard let lastSuccess else { return "No data yet" }
        return "Updated \(Format.duration(now.timeIntervalSince(lastSuccess))) ago"
    }
}

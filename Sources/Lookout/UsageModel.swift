import Foundation

/// Colour band for a percentage (SPEC §5.3).
enum UsageLevel {
    case ok
    case warn
    case critical
}

/// One card in the Usage tab, built from an entry of `limits[]` (SPEC §2.3).
struct UsageLimit: Identifiable, Equatable {
    let kind: String
    let group: String
    let percent: Double
    let severity: String
    let resetsAt: Date?
    /// `scope.model.display_name` — the thing that says "Fable" rather than "Weekly".
    let modelName: String?
    let isActive: Bool

    var id: String { modelName.map { "\(kind)-\($0)" } ?? kind }

    var isScoped: Bool { kind == "weekly_scoped" || modelName != nil }

    var label: String {
        if let modelName, !modelName.isEmpty { return modelName }
        switch kind {
        case "session": return "Session (5h)"
        case "weekly_all": return "Weekly"
        case "weekly_scoped": return "Weekly (scoped)"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var level: UsageLevel {
        UsageLimit.level(percent: percent, severity: severity)
    }

    static func level(percent: Double, severity: String) -> UsageLevel {
        if severity != "normal" { return .critical }
        if percent >= 80 { return .critical }
        if percent >= 50 { return .warn }
        return .ok
    }

    /// `resets in 2h 41m`, or nil when the API did not say.
    func resetsText(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "resetting now" }
        // Weekly windows are days away: `4d 1h` reads better than `97h`.
        if remaining >= 48 * 3600 {
            let days = Int(remaining) / 86_400
            let hours = (Int(remaining) % 86_400) / 3600
            return hours > 0 ? "resets in \(days)d \(hours)h" : "resets in \(days)d"
        }
        return "resets in \(Format.duration(remaining))"
    }

    /// 0…1, for the bar.
    var fraction: Double {
        min(1, max(0, percent / 100))
    }
}

/// A parsed `/api/oauth/usage` response. Everything except `limits[]` is optional by design —
/// the older per-model fields come back null on this account (SPEC §2.3).
struct UsageSnapshot: Equatable {
    var limits: [UsageLimit] = []
    var extraUsageEnabled: Bool = false
    var extraUsagePercent: Double?
    var fetchedAt: Date = Date()

    var sessionPercent: Double? {
        limits.first { $0.kind == "session" }?.percent
    }

    var weeklyPercent: Double? {
        limits.first { $0.kind == "weekly_all" }?.percent
    }

    /// Scoped model names seen so far, for the Settings checkbox list.
    var scopedModelNames: [String] {
        limits.compactMap { $0.isScoped ? $0.modelName : nil }
            .reduce(into: [String]()) { list, name in
                if !list.contains(name) { list.append(name) }
            }
    }

    func visibleLimits(hidden: Set<String>) -> [UsageLimit] {
        limits.filter { limit in
            guard limit.isScoped, let name = limit.modelName else { return true }
            return !hidden.contains(name)
        }
    }

    /// Parsed with JSONSerialization rather than Codable: every field in this payload can be
    /// null, an Int or a Double, and a strict decode would throw away a usable response.
    static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformed
        }

        var snapshot = UsageSnapshot()
        snapshot.fetchedAt = fetchedAt

        let rawLimits = root["limits"] as? [[String: Any]] ?? []
        snapshot.limits = rawLimits.compactMap { entry in
            guard let kind = entry["kind"] as? String else { return nil }
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            return UsageLimit(
                kind: kind,
                group: entry["group"] as? String ?? "",
                percent: number(entry["percent"]) ?? 0,
                severity: entry["severity"] as? String ?? "normal",
                resetsAt: (entry["resets_at"] as? String).flatMap(ISO8601.date),
                modelName: model?["display_name"] as? String,
                isActive: entry["is_active"] as? Bool ?? false
            )
        }

        if let extra = root["extra_usage"] as? [String: Any] {
            snapshot.extraUsageEnabled = extra["is_enabled"] as? Bool ?? false
            snapshot.extraUsagePercent = number(extra["utilization"])
        }
        return snapshot
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

enum UsageError: Error, Equatable {
    /// No `Claude Code-credentials` item in the keychain.
    case notSignedIn
    /// 401 twice in a row — the token is stale and Claude Code has not refreshed it.
    case expired
    case http(Int)
    case offline(String)
    case malformed

    var message: String {
        switch self {
        case .notSignedIn: return "Not signed in to Claude Code"
        case .expired: return "Sign-in expired — run any Claude Code command"
        case .http(let code): return "Usage API error \(code)"
        case .offline: return "Offline"
        case .malformed: return "Unreadable usage response"
        }
    }
}

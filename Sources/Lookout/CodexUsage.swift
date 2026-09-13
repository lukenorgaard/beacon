import Foundation

/// One rate-limit window from `~/.lookout/codex-usage.json` (SPEC §17.7): `used_percent` 0…100,
/// `window_minutes` (300 for the 5-hour window, 10080 for the weekly one), and `resets_at` as a
/// Unix epoch — the reporter's own field name and unit, unlike the Claude usage API's ISO string.
struct CodexUsageWindow: Equatable {
    /// What the bar is called. Codex names its windows only by length: 300 minutes is the
    /// familiar "5 hour", 10080 the weekly one; anything else is spelled out so a changed plan
    /// never shows up under the wrong name (the owner saw a weekly limit labelled "5 hour").
    var title: String {
        guard let minutes = windowMinutes, minutes > 0 else { return "Limit" }
        if minutes == 300 { return "5 hour" }
        if minutes == 10080 { return "Weekly" }
        if minutes < 1440 {
            let hours = minutes / 60
            return hours == hours.rounded() ? "\(Int(hours)) hour" : String(format: "%.1f hour", hours)
        }
        let days = minutes / 1440
        return days == days.rounded() ? "\(Int(days)) day" : String(format: "%.1f day", days)
    }

    var usedPercent: Double?
    var windowMinutes: Double?
    var resetsAt: Date?

    var fraction: Double { min(1, max(0, (usedPercent ?? 0) / 100)) }

    var level: UsageLevel {
        UsageLimit.level(percent: usedPercent ?? 0, severity: "normal")
    }

    /// `resets in 2h 41m` — the same spelling `UsageLimit.resetsText` uses, so the Codex section
    /// reads like a continuation of the Claude one, not a second language. `nil` when the
    /// reporter never sent a `resets_at` for this window.
    func resetsText(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "resetting now" }
        if remaining >= 48 * 3600 {
            let days = Int(remaining) / 86_400
            let hours = (Int(remaining) % 86_400) / 3600
            return hours > 0 ? "resets in \(days)d \(hours)h" : "resets in \(days)d"
        }
        return "resets in \(Format.duration(remaining))"
    }
}

/// `~/.lookout/codex-usage.json` (SPEC §17.7), parsed as tolerantly as the Claude usage snapshot:
/// on a real machine `secondary` and `limit_name` are frequently null, and the 5-hour bar has to
/// render alone when they are — never a crash, never a placeholder that looks like a real number.
struct CodexUsageSnapshot: Equatable {
    var updated: Date?
    var limitName: String?
    var planType: String?
    var primary: CodexUsageWindow?
    var secondary: CodexUsageWindow?

    /// `limit_name · plan_type`, either half omitted when it is null — SPEC §17.7's "hide the
    /// caption parts that are null".
    var caption: String? {
        let parts = [limitName, planType].compactMap { Session.text($0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func parse(_ data: Data) -> CodexUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var snapshot = CodexUsageSnapshot()
        if let updated = object["updated"] as? String { snapshot.updated = ISO8601.date(updated) }
        snapshot.limitName = object["limit_name"] as? String
        snapshot.planType = object["plan_type"] as? String
        snapshot.primary = CodexUsageSnapshot.window(object["primary"])
        snapshot.secondary = CodexUsageSnapshot.window(object["secondary"])
        return snapshot
    }

    private static func window(_ value: Any?) -> CodexUsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        var window = CodexUsageWindow()
        window.usedPercent = number(dict["used_percent"])
        window.windowMinutes = number(dict["window_minutes"])
        if let epoch = number(dict["resets_at"]) {
            window.resetsAt = Date(timeIntervalSince1970: epoch)
        }
        // A window object with nothing usable in it is the same as no window at all.
        if window.usedPercent == nil, window.windowMinutes == nil, window.resetsAt == nil {
            return nil
        }
        return window
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

/// Reads the file on demand — no watcher of its own; `AppState` re-reads it whenever the Claude
/// usage snapshot refreshes and once at launch (SPEC §17.7).
enum CodexUsageReader {
    static func read(home: LookoutHome) -> CodexUsageSnapshot? {
        let url = home.root.appendingPathComponent("codex-usage.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return CodexUsageSnapshot.parse(data)
    }
}

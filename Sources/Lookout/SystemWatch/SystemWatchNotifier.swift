import Foundation
import UserNotifications
import os

/// Who gets interrupted, and how often (SPEC §18.5: 20 minutes per rule id).
///
/// Pure value type with an injected clock, because this is the part that has to be right: a
/// warning that re-notifies every five seconds is worse than no warning at all.
struct SystemSignalCooldown {
    /// Silence per rule id, unless the rule gets worse.
    let window: TimeInterval

    private var lastNotified: [String: (date: Date, severity: SignalSeverity)] = [:]

    init(window: TimeInterval = 20 * 60) {
        self.window = window
    }

    /// The signals that should actually be delivered now. Everything else is already visible in
    /// the tab, which is the right place for a problem the user has been told about.
    mutating func admit(
        _ signals: [SystemSignal],
        minimum: SignalSeverity,
        enabled: Bool,
        now: Date
    ) -> [SystemSignal] {
        // Nothing is recorded while notifications are off, so turning them back on does not start
        // inside a cooldown the user never saw.
        guard enabled else { return [] }

        // Expire by age, never by absence. Dropping an entry the moment its signal clears lets
        // anything oscillating around its threshold reset its own cooldown and re-notify on every
        // reappearance — the loudest possible behaviour for the least stable condition.
        let ttl = window * 3
        lastNotified = lastNotified.filter { now.timeIntervalSince($0.value.date) < ttl }

        var admitted: [SystemSignal] = []
        for signal in signals where signal.severity >= minimum {
            if let previous = lastNotified[signal.id] {
                let escalated = signal.severity > previous.severity
                let cooledDown = now.timeIntervalSince(previous.date) >= window
                guard escalated || cooledDown else { continue }
            }
            lastNotified[signal.id] = (now, signal.severity)
            admitted.append(signal)
        }
        return admitted
    }
}

/// Delivers Sentinel warnings as notifications (SPEC §18.5). It never takes an action on the
/// system — quitting things stays the user's call, through the tab's own buttons.
final class SystemWatchNotifier {
    /// Registered alongside the session categories, never in place of them.
    static let categoryIdentifier = "io.github.lukenorgaard.beacon.sentinel"

    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "sentinel")
    /// `UNUserNotificationCenter.current()` traps unless the process is an application bundle.
    /// `Notifier` gates on a bundle identifier for the same reason, but that is not enough here:
    /// `swift test` runs inside Xcode's `xctest`, which has an identifier and would take the trap
    /// the moment `SystemWatcher.start()` registered a category.
    private let available = SystemWatchNotifier.isApplicationBundle
    private let sensitivity: () -> SystemWatchSensitivity
    private let notificationsEnabled: () -> Bool
    private let now: () -> Date
    private var cooldown: SystemSignalCooldown
    /// The one side effect, injectable so the cooldown path can be exercised end to end without
    /// a notification center.
    private let deliver: (SystemSignal) -> Void

    init(
        sensitivity: @escaping () -> SystemWatchSensitivity,
        notificationsEnabled: @escaping () -> Bool,
        window: TimeInterval = 20 * 60,
        now: @escaping () -> Date = Date.init,
        deliver: ((SystemSignal) -> Void)? = nil
    ) {
        self.sensitivity = sensitivity
        self.notificationsEnabled = notificationsEnabled
        self.now = now
        self.cooldown = SystemSignalCooldown(window: window)
        let available = Self.isApplicationBundle
        self.deliver = deliver ?? { signal in
            guard available else { return }
            SystemWatchNotifier.post(signal)
        }
    }

    static var isApplicationBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Adds the Sentinel category to whatever is already registered. `NotificationActions` owns
    /// the session categories and registers them at launch; replacing the set here would silently
    /// strip Allow/Deny/Reply off every session banner.
    func register() {
        guard available else {
            log.notice("Unbundled run — Sentinel notifications disabled")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            let sentinel = UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [], intentIdentifiers: [], options: []
            )
            center.setNotificationCategories(existing.union([sentinel]))
        }
    }

    /// Called once per cycle with the full signal list.
    func process(_ signals: [SystemSignal]) {
        let admitted = cooldown.admit(
            signals,
            minimum: sensitivity().notifyAt,
            enabled: notificationsEnabled(),
            now: now()
        )
        for signal in admitted { deliver(signal) }
    }

    private static func post(_ signal: SystemSignal) {
        let content = UNMutableNotificationContent()
        content.title = signal.notificationTitle
        content.body = signal.detail
        if let advice = signal.advice.first { content.subtitle = advice }
        content.categoryIdentifier = categoryIdentifier
        content.interruptionLevel = signal.severity == .critical ? .timeSensitive : .active
        content.sound = signal.severity == .critical ? .defaultCritical : .default
        content.userInfo = ["sentinel_signal_id": signal.id]

        // Identifier = rule id, so a re-notification after the cooldown replaces the stale banner
        // for that rule instead of stacking a second copy of the same warning.
        let request = UNNotificationRequest(
            identifier: "sentinel.\(signal.id)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

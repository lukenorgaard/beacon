import Foundation
import UserNotifications
import os

/// One notification per transition, replaced per session so they never pile up, and clicking one
/// lands in that session — the whole point of replacing the old osascript hook (SPEC §5.4).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the session id behind a clicked notification (the banner itself, not one of
    /// its buttons).
    var onActivate: ((String) -> Void)?
    /// SPEC §17.1: called for Allow / Deny / Reply / Open — `text` is the typed reply for Reply
    /// and nil for every plain button.
    var onAction: ((_ actionID: String, _ sessionID: String, _ text: String?) -> Void)?

    private let log = Logger(subsystem: "io.github.lukenorgaard.beacon", category: "notify")
    /// `UNUserNotificationCenter` needs a real bundle; running the raw binary has none.
    private let available = Bundle.main.bundleIdentifier != nil

    func start() {
        guard available else {
            log.notice("Unbundled run — notifications disabled")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // SPEC §17.1: category identifiers are stable strings, registered once at launch — before
        // authorization, so a notification delivered the moment permission is granted already has
        // its buttons.
        NotificationActions.register(on: center)
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                self?.log.error("Notification auth failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                self?.log.notice("Notifications not granted")
            }
        }
    }

    func notify(_ session: Session) {
        guard available else { return }

        let content = UNMutableNotificationContent()
        // SPEC §15.4: a banner has room for one name. The one the owner gave the session wins;
        // without one it stays the project folder, exactly as before.
        switch session.state {
        case .needsYou:
            content.title = "Needs you · \(session.displayLabel) (\(session.host.chip))"
            content.body = session.detail ?? session.reason ?? "Waiting for you"
        case .done:
            content.title = "Finished · \(session.displayLabel)"
            content.body = session.lastMessage ?? session.displayName ?? "Turn complete"
        default:
            return
        }
        content.sound = .default
        content.userInfo = ["session_id": session.sessionID]
        // SPEC §17.1: the category is what puts Allow/Deny/Open or Open/Reply… on the banner.
        if let category = NotificationCategory.of(session: session) {
            content.categoryIdentifier = category.rawValue
        }

        // Identifier = session id: a newer notification for the same session replaces the old one.
        let request = UNNotificationRequest(
            identifier: session.sessionID, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.log.error("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clear(sessionID: String) {
        guard available else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [sessionID])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionID = info["session_id"] as? String ?? response.notification.request.identifier

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            // The banner itself, not one of §17.1's buttons — the old, plain "jump" behaviour.
            DispatchQueue.main.async { [weak self] in self?.onActivate?(sessionID) }
        case UNNotificationDismissActionIdentifier:
            break
        default:
            // SPEC §17.1: Allow / Deny / Open / Reply…, the last of which carries typed text.
            let text = (response as? UNTextInputNotificationResponse)?.userText
            let actionID = response.actionIdentifier
            DispatchQueue.main.async { [weak self] in self?.onAction?(actionID, sessionID, text) }
        }
        completionHandler()
    }
}

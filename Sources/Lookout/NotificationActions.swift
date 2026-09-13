import AppKit
import Foundation
import UserNotifications

/// SPEC §17.1: which category a notification is filed under decides which action buttons macOS
/// puts on the banner.
enum NotificationCategory: String {
    case permission = "io.github.lukenorgaard.beacon.permission"
    case question = "io.github.lukenorgaard.beacon.question"
    case done = "io.github.lukenorgaard.beacon.done"
    /// A Codex question (SPEC §17.10): Codex takes the answer only from its own prompt, so the
    /// banner offers Open and nothing that would send text into the session.
    case codexQuestion = "io.github.lukenorgaard.beacon.codex-question"

    /// Nil for every state that never gets a notification at all (SPEC §5.4): a category is only
    /// meaningful alongside a notification, so there is nothing to compute for `working`/`idle`.
    static func of(session: Session) -> NotificationCategory? {
        switch session.state {
        case .needsYou:
            if session.reason == "question" {
                return session.agent == .codex ? .codexQuestion : .question
            }
            return .permission
        case .done:
            return .done
        default:
            return nil
        }
    }
}

/// Stable action identifiers — what comes back in `UNNotificationResponse.actionIdentifier`.
enum NotificationActionID {
    static let allow = "io.github.lukenorgaard.beacon.action.allow"
    static let deny = "io.github.lukenorgaard.beacon.action.deny"
    static let open = "io.github.lukenorgaard.beacon.action.open"
    static let reply = "io.github.lukenorgaard.beacon.action.reply"
}

/// SPEC §17.1: the three categories and their buttons, registered once at launch. Pure data —
/// building a `UNNotificationCategory` needs no bundle and no live notification center, so this
/// is testable by constructing it and inspecting the result.
enum NotificationActions {
    static func categories() -> Set<UNNotificationCategory> {
        let allow = UNNotificationAction(
            identifier: NotificationActionID.allow, title: "Allow", options: []
        )
        let deny = UNNotificationAction(
            identifier: NotificationActionID.deny, title: "Deny", options: [.destructive]
        )
        let open = UNNotificationAction(
            identifier: NotificationActionID.open, title: "Open", options: [.foreground]
        )
        let reply = UNTextInputNotificationAction(
            identifier: NotificationActionID.reply, title: "Reply…",
            options: [.foreground],
            textInputButtonTitle: "Send", textInputPlaceholder: "Reply…"
        )

        let permission = UNNotificationCategory(
            identifier: NotificationCategory.permission.rawValue,
            actions: [allow, deny, open], intentIdentifiers: [], options: []
        )
        let question = UNNotificationCategory(
            identifier: NotificationCategory.question.rawValue,
            actions: [open, reply], intentIdentifiers: [], options: []
        )
        let done = UNNotificationCategory(
            identifier: NotificationCategory.done.rawValue,
            actions: [open, reply], intentIdentifiers: [], options: []
        )
        let codexQuestion = UNNotificationCategory(
            identifier: NotificationCategory.codexQuestion.rawValue,
            actions: [open], intentIdentifiers: [], options: []
        )
        return [permission, question, done, codexQuestion]
    }

    /// A thin seam so registration is real `UNUserNotificationCenter` in the app and nothing at
    /// all in a test — `Notifier` already gates every center call behind its own `available`
    /// check for the same reason (no bundle in `swift test`).
    static func register(on center: UNUserNotificationCenter) {
        center.setNotificationCategories(categories())
    }
}

/// The one thing `NotificationActionRouter` needs from a real `UNUserNotificationCenter`: taking
/// the banner down once an action has answered it (SPEC §17.1). A fake conforming to this is
/// what makes the router testable without touching notifications at all.
protocol NotificationRemoving: AnyObject {
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: NotificationRemoving {}

/// What a notification's action button does (SPEC §17.1), decoupled from
/// `UNUserNotificationCenter` and from AppKit's own `UNNotificationResponse` (which has no public
/// initialiser) so the whole thing is driven by plain values in a test — exactly the seam-per-
/// side-effect style `AttentionCardModel` already uses for Send.
final class NotificationActionRouter {
    private let requests: RequestStore
    private let home: LookoutHome
    /// `@autoclosure` so the default `UNUserNotificationCenter.current()` is built only the
    /// first time an action actually fires — never merely from constructing `AppState`, which
    /// crashes in an unbundled `swift test` process exactly the way `Notifier`'s own `available`
    /// gate exists to avoid.
    private let centerProvider: () -> NotificationRemoving
    private lazy var center: NotificationRemoving = centerProvider()

    /// None of these may run for real in a test process.
    var sessionLookup: (String) -> Session?
    var answerWriter: (AnswerDecision, AttentionRequest) -> Result<URL, Error>
    var sender: (String, Session, @escaping (SessionMessenger.Result) -> Void) -> Void
    /// SPEC §17.7: Codex's own Send channel, tried before the companion.
    var codexSender: (String, Session, @escaping (CodexQueueSender.Result) -> Void) -> Void
    var companionSender: (String, Session, @escaping (CompanionMatch?) -> Void) -> Void
    var copier: (String) -> Void
    var jumper: (Session) -> Void

    init(
        requests: RequestStore,
        home: LookoutHome,
        center: @autoclosure @escaping () -> NotificationRemoving = UNUserNotificationCenter.current(),
        sessionLookup: @escaping (String) -> Session? = { _ in nil }
    ) {
        self.requests = requests
        self.home = home
        self.centerProvider = center
        self.sessionLookup = sessionLookup
        self.answerWriter = { decision, request in
            Result { try AnswerWriter.write(decision, for: request, in: home.answers) }
        }
        self.sender = { text, session, completion in
            SessionMessenger.send(text: text, session: session, home: home, completion: completion)
        }
        self.codexSender = { text, session, completion in
            CodexQueueSender.send(text: text, session: session, home: home, completion: completion)
        }
        let companion = EditorCompanion.client(home: home)
        self.companionSender = { text, session, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let match = companion.send(text: text, session: session)
                DispatchQueue.main.async { completion(match) }
            }
        }
        self.copier = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        self.jumper = { session in Jumper.jump(to: session) }
    }

    /// SPEC §17.1: routes one action button, and removes the banner afterwards whatever the
    /// outcome. `openCard` is what Allow/Deny falls back to once the request has expired — the
    /// card's own buttons are gone at that point too, so opening it is the only thing left to
    /// offer.
    func handle(
        actionID: String, sessionID: String, text: String?, openCard: @escaping (Session) -> Void
    ) {
        guard let session = sessionLookup(sessionID) else { return }
        defer { center.removeDeliveredNotifications(withIdentifiers: [sessionID]) }

        switch actionID {
        case NotificationActionID.open:
            jumper(session)
        case NotificationActionID.allow:
            answer(.allow, session: session, openCard: openCard)
        case NotificationActionID.deny:
            answer(.deny, session: session, openCard: openCard)
        case NotificationActionID.reply:
            guard let reply = Session.text(text) else { return }
            self.reply(reply, session: session)
        default:
            break
        }
    }

    private func answer(
        _ decision: AnswerDecision, session: Session, openCard: @escaping (Session) -> Void
    ) {
        guard let request = requests.request(for: session.sessionID), request.isAnswerable() else {
            openCard(session)
            return
        }
        switch answerWriter(decision, request) {
        case .success:
            AnswerAudit.record(
                session: session, channel: .answerFile, outcome: decision.rawValue,
                text: request.commandOrPath, home: home
            )
        case .failure:
            openCard(session)
        }
    }

    /// SPEC §17.1: the same channel order Send already uses (socket / `codex queue` → companion
    /// → Copy & go), logged under `notification` so `answers.log` tells this apart from a card's
    /// own reply.
    private func reply(_ text: String, session: Session) {
        // SPEC §17.7: Codex has no messaging socket — `codex queue` is tried first instead.
        if session.agent == .codex {
            codexSender(text, session) { [weak self] result in
                guard let self else { return }
                switch result {
                case .sent:
                    break
                case .failed(let reason):
                    self.deliverViaCompanion(session: session, text: text, reason: reason)
                }
            }
            return
        }
        guard session.canSendMessage else {
            deliverViaCompanion(session: session, text: text, reason: "no messaging socket")
            return
        }
        sender(text, session) { [weak self] result in
            guard let self else { return }
            switch result {
            case .sent:
                AnswerAudit.record(
                    session: session, channel: .notification, outcome: "sent",
                    text: text, home: self.home
                )
            case .failed(let reason):
                self.deliverViaCompanion(session: session, text: text, reason: reason)
            }
        }
    }

    private func deliverViaCompanion(session: Session, text: String, reason: String) {
        guard EditorCompanion.app(for: session.host) != nil else {
            copyAndGo(session: session, text: text, reason: reason)
            return
        }
        companionSender(text, session) { [weak self] match in
            guard let self else { return }
            guard match != nil else {
                self.copyAndGo(session: session, text: text, reason: reason)
                return
            }
            AnswerAudit.record(
                session: session, channel: .notification, outcome: "companion",
                text: text, home: self.home
            )
        }
    }

    private func copyAndGo(session: Session, text: String, reason: String) {
        copier(text)
        jumper(session)
        AnswerAudit.record(
            session: session, channel: .notification, outcome: "send-failed: \(reason)",
            text: text, home: home
        )
    }
}

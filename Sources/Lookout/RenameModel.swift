import AppKit
import Combine
import Foundation

/// SPEC §15.5: how a rename reaches the session *itself*. The local name (§15.4) is immediate
/// and always works; this is the second half, and the socket only carries user messages, so what
/// is possible depends entirely on where the session runs.
enum RenameChannel: String, Equatable, CaseIterable {
    /// Codex: there is no rename command, so the checkbox is not even shown.
    case none
    /// A Claude desktop session: a user message asking the model to call its own title tool.
    case title
    /// A CLI session in Terminal.app or iTerm, idle or done: `/rename …` typed into its tab.
    case typed
    /// Everything else (Cursor, Devin, VS Code, unknown, or a busy terminal): copy and jump.
    case paste

    /// The checkbox's subtitle (SPEC §15.5). Nil is what hides the checkbox.
    func subtitle(host: SessionHost) -> String? {
        switch self {
        case .none: return nil
        case .title: return "via the session's title tool"
        case .typed: return "typed into the \(host.chip) tab"
        case .paste: return "copied — paste it there"
        }
    }
}

/// Picks the channel and composes what goes down it. Pure: every rule in §15.5 is decided here
/// and nothing in this enum touches a socket, a tab or the pasteboard.
enum RenameDelivery {
    /// SPEC §15.5, in the order the rules are written.
    static func channel(for session: Session) -> RenameChannel {
        // Codex has no rename command at all — local name only.
        if session.agent == .codex { return .none }
        if session.host == .claudeDesktop || session.entrypoint == "claude-desktop" {
            return .title
        }
        switch session.host {
        case .terminal, .iterm:
            // Typing into a tab that is mid-turn would land in the middle of whatever the agent
            // is doing, so a busy session falls back to the Cursor rule.
            return session.state == .idle || session.state == .done ? .typed : .paste
        default:
            return .paste
        }
    }

    /// SPEC §15.5, verbatim: the user message a desktop session gets. The model calls
    /// `set_session_title`, the sidebar updates, and the reporter's `desktop_title` follows.
    static func message(name: String) -> String {
        "Rename this session to: \"\(name)\". Use your session-title tool to set exactly that "
            + "title, then reply with only: renamed."
    }

    /// `/rename <name>` — what is typed into a tab, and what is copied for a paste.
    static func command(name: String) -> String {
        "/rename \(name)"
    }

    /// The status line for a channel that has done its half and is waiting on the owner.
    static let pasteStatus = "Paste and press return there"

    /// SPEC §16.3: `/rename` went straight into the session's terminal tab inside the editor,
    /// so there is nothing left for the owner to paste.
    static let companionStatus = "Renamed via companion"
}

/// Everything the Rename… panel does (SPEC §15.4, §15.5).
///
/// No AppKit window here on purpose: the whole thing — prefill, save, clear, cancel, and every
/// §15.5 channel — is drivable from a test. The three side effects (send, type, copy + jump) are
/// closures the app fills in and a test replaces.
final class RenameModel: ObservableObject {
    /// The field. Prefilled with the current display name, selected, so typing replaces it.
    @Published var text: String = ""
    /// SPEC §15.5's checkbox. Default on wherever a mechanism exists.
    @Published var alsoRenameInSession: Bool = true
    @Published private(set) var session: Session?
    /// Set while a channel is doing its work; the buttons go quiet.
    @Published private(set) var isWorking = false
    /// The one line under the buttons.
    @Published private(set) var status: String?
    @Published private(set) var statusIsError = false
    /// True once the panel has said its piece and only has a Close left (SPEC §15.5's paste
    /// rule, and every failure).
    @Published private(set) var isFinished = false

    let names: SessionNames
    let settings: Settings
    private let home: LookoutHome

    /// Called when the panel should go away.
    var onClose: () -> Void = {}

    /// The three seams. None of them may run for real in a test process.
    var sender: (String, Session, @escaping (SessionMessenger.Result) -> Void) -> Void
    var typer: (String, Session, @escaping (Bool) -> Void) -> Void
    var copier: (String) -> Void
    var jumper: (Session) -> Void
    /// SPEC §16.3: the editor companion, tried before the clipboard on the `.paste` channel.
    var companion: (String, Session, @escaping (CompanionMatch?) -> Void) -> Void

    init(
        names: SessionNames,
        settings: Settings,
        home: LookoutHome = LookoutHome()
    ) {
        self.names = names
        self.settings = settings
        self.home = home
        self.sender = { text, session, completion in
            SessionMessenger.send(text: text, session: session, home: home, completion: completion)
        }
        self.typer = { command, session, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let delivered = Jumper.type(command: command, into: session)
                DispatchQueue.main.async { completion(delivered) }
            }
        }
        self.copier = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        self.jumper = { session in Jumper.jump(to: session) }
        let client = EditorCompanion.client(home: home)
        self.companion = { command, session, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let match = client.send(text: command, session: session)
                DispatchQueue.main.async { completion(match) }
            }
        }
    }

    // MARK: - Presenting

    /// Opens the panel on a session. SPEC §15.4: the field is prefilled with the name the row
    /// shows right now, so a renamed session prefills its custom name.
    func begin(_ session: Session) {
        self.session = session
        text = session.displayName ?? ""
        alsoRenameInSession = channel != .none
        isWorking = false
        isFinished = false
        status = nil
        statusIsError = false
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// SPEC §15.4: an empty field removes the override rather than storing a blank name.
    var clears: Bool { trimmed.isEmpty }

    /// The name the row used to show, for the line under the field.
    var originalName: String? { session?.sessionName }

    var channel: RenameChannel {
        guard let session else { return .none }
        return RenameDelivery.channel(for: session)
    }

    /// Nil hides the checkbox entirely (Codex, SPEC §15.5).
    var channelSubtitle: String? {
        guard let session else { return nil }
        return channel.subtitle(host: session.host)
    }

    var showsChannelCheckbox: Bool { channelSubtitle != nil }

    /// Clearing the override is a local act — there is nothing to rename a session *to*.
    var canPushToSession: Bool { showsChannelCheckbox && !clears }

    var canSave: Bool { session != nil && !isWorking && !isFinished }

    // MARK: - Actions

    /// SPEC §15.4 + §15.5: the local name is written first and unconditionally — every remote
    /// mechanism can fail, and none of them may take the name the owner just typed down with it.
    func save() {
        guard let session, !isWorking, !isFinished else { return }
        names.setName(clears ? nil : trimmed, for: session.sessionID)

        guard alsoRenameInSession, canPushToSession else {
            close()
            return
        }
        push(name: trimmed, session: session)
    }

    func cancel() {
        close()
    }

    /// The button the panel is left with after a paste or a failure.
    func finish() {
        close()
    }

    private func close() {
        session = nil
        text = ""
        isWorking = false
        isFinished = false
        status = nil
        statusIsError = false
        onClose()
    }

    // MARK: - SPEC §15.5

    private func push(name: String, session: Session) {
        switch RenameDelivery.channel(for: session) {
        case .none:
            close()
        case .title:
            isWorking = true
            status = "Asking the session to rename itself…"
            statusIsError = false
            let message = RenameDelivery.message(name: name)
            sender(message, session) { [weak self] result in
                self?.finished(result, session: session, name: name)
            }
        case .typed:
            isWorking = true
            status = "Typing /rename into the \(session.host.chip) tab…"
            statusIsError = false
            let command = RenameDelivery.command(name: name)
            typer(command, session) { [weak self] delivered in
                self?.finishedTyping(delivered, session: session, name: name, command: command)
            }
        case .paste:
            let command = RenameDelivery.command(name: name)
            // SPEC §16.3: inside Cursor, Devin or VS Code the companion can type `/rename` into
            // the session's own terminal; the clipboard is what happens when it cannot.
            guard EditorCompanion.app(for: session.host) != nil else {
                copyAndGo(command: command, session: session, name: name)
                return
            }
            isWorking = true
            status = "Sending /rename to the \(session.host.chip) terminal…"
            statusIsError = false
            companion(command, session) { [weak self] match in
                guard let self else { return }
                self.isWorking = false
                guard match != nil else {
                    self.copyAndGo(command: command, session: session, name: name)
                    return
                }
                self.record(session: session, outcome: "companion", name: name)
                self.settle(RenameDelivery.companionStatus, isError: false)
            }
        }
    }

    /// SPEC §15.5's Cursor rule: the name is on the clipboard and the session is in front.
    private func copyAndGo(command: String, session: Session, name: String) {
        copier(command)
        jumper(session)
        record(session: session, outcome: "copied", name: name)
        settle(RenameDelivery.pasteStatus, isError: false)
    }

    private func finished(_ result: SessionMessenger.Result, session: Session, name: String) {
        switch result {
        case .sent:
            record(session: session, outcome: "sent", name: name)
            close()
        case .failed(let reason):
            record(session: session, outcome: "failed: \(reason)", name: name)
            // SPEC §15.5: the local name is already saved, and says so — the panel only reports
            // the half that did not happen.
            settle("Renamed here, but the session did not take it: \(reason)", isError: true)
        }
    }

    private func finishedTyping(
        _ delivered: Bool, session: Session, name: String, command: String
    ) {
        guard delivered else {
            // The tab could not be found — fall back to §15.5's Cursor rule rather than
            // leaving the session unrenamed with nothing to do about it.
            copier(command)
            jumper(session)
            record(session: session, outcome: "typed-failed, copied", name: name)
            settle("Renamed here. \(RenameDelivery.pasteStatus)", isError: false)
            return
        }
        record(session: session, outcome: "typed", name: name)
        close()
    }

    private func settle(_ line: String, isError: Bool) {
        isWorking = false
        isFinished = true
        status = line
        statusIsError = isError
    }

    private func record(session: Session, outcome: String, name: String) {
        AnswerAudit.record(
            session: session, channel: .rename, outcome: outcome, text: name, home: home
        )
    }
}

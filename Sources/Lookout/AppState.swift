import AppKit
import Combine
import Foundation

enum PanelTab: String, CaseIterable {
    case sessions
    /// Every live sub-agent across every session (SPEC §12.3).
    case agents
    /// Reverse-chronological state-transition log (SPEC §17.5).
    case history
    case usage
    /// The machine itself: gauges, warnings, Top CPU (SPEC §18). Right of Usage, as asked.
    case sentinel

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .agents: return "Agents"
        case .history: return "History"
        case .usage: return "Usage"
        case .sentinel: return "Sentinel"
        }
    }

    /// The tab strip's own list. Two tabs sit behind a switch — History (the owner: "history I think
    /// is irrelevant", default off) and Sentinel (SPEC §18.5's Enabled, default on) — and the
    /// order is `allCases`' own, so nothing about the strip's layout has to know which tabs, if
    /// any, are missing.
    static func visibleCases(showHistory: Bool, showSentinel: Bool = true) -> [PanelTab] {
        allCases.filter { tab in
            switch tab {
            case .history: return showHistory
            case .sentinel: return showSentinel
            default: return true
            }
        }
    }
}

/// Ties the three moving parts together: session files + process scan, usage, and notifications.
final class AppState: ObservableObject {
    let settings: Settings
    let store: SessionStore
    let usage: UsageClient
    let notifier = Notifier()
    let seen: SeenSet
    /// `~/.lookout` (or `LOOKOUT_HOME`) — requests, answers and the two logs (SPEC §11.4).
    let home: LookoutHome
    let requests: RequestStore
    /// Bug fix (2026-09-04): Codex has no hook for a question in its TUI — this is what notices
    /// one anyway, by tailing the session's own rollout file (SPEC's `CodexQuestionWatcher`).
    let codexQuestions: CodexQuestionWatcher
    let attention: AttentionCoordinator
    let suggester: Suggester
    /// The one card model the card window renders; it outlives any single card.
    let cardModel: AttentionCardModel
    /// SPEC §17.1: what a notification's Allow / Deny / Reply / Open button does.
    let notificationRouter: NotificationActionRouter
    /// SPEC §17.2: the five global shortcuts.
    let hotKeys: HotKeyCenter
    /// SPEC §15.4: the custom session names, and the model behind the Rename… panel.
    let names: SessionNames
    let renameModel: RenameModel
    /// SPEC §18: what the Sentinel tab renders. Always here — the tab being off only means
    /// nothing publishes into it (the engine below is stopped and the tab leaves the strip).
    let systemWatch = SystemWatchState()

    /// SPEC §15.4: the row that asked to be renamed. The controller opens the panel next to
    /// `rowFrame` (SwiftUI's `.global` rect) and clears this when it closes; the token is what
    /// makes renaming the same row twice in a row publish twice.
    struct RenameTarget: Equatable {
        var session: Session
        var rowFrame: CGRect
        var token = UUID()
    }

    @Published var renameTarget: RenameTarget?

    @Published var tab: PanelTab = .sessions
    /// Everything, in display order (idle rows filtered out when the user asked for that).
    /// Filtered and ordered (SPEC §17.3) — what the sessions list actually draws.
    @Published var visibleSessions: [Session] = []
    @Published var allSessions: [Session] = []
    /// How many sessions pass the idle toggle alone, before the chips and the host popover —
    /// the denominator for `showing 4 of 13` (SPEC §17.3).
    var idleFilteredCount = 0
    /// Every live sub-agent, flattened for the Agents tab (SPEC §12.3).
    @Published var subagents: [LiveSubagent] = []

    // MARK: - History (SPEC §17.5)

    /// `nil` until the History tab has been opened once — `loadHistoryIfNeeded()` reads
    /// `history.jsonl` (+ `.1`) only then, so a session that never looks at History never pays
    /// for it.
    @Published var historyEntries: [HistoryEntry]?
    @Published var historySearch: String = "" { didSet { recomputeHistory() } }
    @Published var historyFilters: Set<HistoryFilter> = [] { didSet { recomputeHistory() } }
    @Published var historyGroups: [HistoryDayGroup] = []

    var historyRowCount: Int { historyGroups.reduce(0) { $0 + $1.entries.count } }

    // MARK: - Codex usage (SPEC §17.7)

    /// `nil` when `~/.lookout/codex-usage.json` does not exist — the Usage tab's Codex section
    /// hides itself in that case rather than showing an empty shell.
    @Published var codexUsage: CodexUsageSnapshot?

    private var cancellables = Set<AnyCancellable>()
    /// SPEC §18.1: created by `SystemWatch.makeEngine` when Settings → Sentinel → Enabled is on,
    /// released when it goes off. Nil is the honest "nothing is sampling" state.
    var systemWatchEngine: SystemWatchEngine?
    /// SPEC §18.6: the engine samples every 5 s while the tab is on screen and every 15 s
    /// otherwise, so it has to know whether the panel is showing at all — not just which tab is
    /// selected. `PanelController` reports this on every show/hide.
    var panelIsOnScreen = false
    /// SPEC §18.4: the window the Stop… confirmation is presented as a sheet on. Weak — the panel
    /// outlives nothing here, and a nil is simply "no panel yet", which the alert handles.
    weak var panelWindow: NSWindow?
    /// The list exactly as the store published it, before any name was put on it — what a
    /// change to `names` re-decorates (SPEC §15.4).
    var rawSessions: [Session] = []
    /// Bug fix (2026-09-04): re-runs `apply(rawSessions)` on a clock of its own. `store.$sessions`
    /// only republishes when a session *file* changes — a session hung at `working`/`background`
    /// touches nothing on disk for the rest of its (stuck) life, so nothing would otherwise ever
    /// notice it crossed `StaleBackground.staleAfter`.
    var staleTicker: DispatchSourceTimer?
    /// Session ids already notified/carded for `StaleBackground` (bug fix 2026-09-04) — without
    /// this, every `apply()` (the ticker above fires every minute) would reopen a card the user
    /// just dismissed, because as far as `AttentionCoordinator` can tell each call is a fresh
    /// `working` → `done` transition.
    var staleNotified: Set<String> = []
    /// Session id → the `call_id` of the Codex question last notified/carded for it (bug fix
    /// 2026-09-04) — the same one-shot guard `staleNotified` is, keyed on the call rather than
    /// just the session so a *second* question in the same session (a new call id, the session
    /// never having left `needs_you` in between) notifies again instead of being read as "already
    /// handled".
    var codexQuestionNotified: [String: String] = [:]

    init(
        settings: Settings = Settings(),
        store: SessionStore? = nil,
        usage: UsageClient = UsageClient(),
        home: LookoutHome = LookoutHome(),
        suggester: Suggester = Suggester(),
        names: SessionNames? = nil
    ) {
        self.settings = settings
        self.store = store ?? SessionStore()
        self.usage = usage
        self.seen = SeenSet(defaults: settings.defaults)
        self.home = home
        self.requests = RequestStore(home: home)
        self.codexQuestions = CodexQuestionWatcher()
        self.suggester = suggester
        let coordinator = AttentionCoordinator(settings: settings)
        self.attention = coordinator
        self.cardModel = AttentionCardModel(
            settings: settings, coordinator: coordinator, suggester: suggester, home: home
        )
        let store = names ?? SessionNames(home: home)
        self.names = store
        self.renameModel = RenameModel(names: store, settings: settings, home: home)
        // SPEC §17.1: `sessionLookup` needs `self.allSessions`, which does not exist yet — wired
        // for real in `start()`, exactly like `notifier.onActivate` below.
        self.notificationRouter = NotificationActionRouter(requests: requests, home: home)
        self.hotKeys = HotKeyCenter(settings: settings)
    }

    deinit {
        staleTicker?.cancel()
    }

    func start() {
        // The app delegate may already have wired this up with its own panel-reveal behaviour.
        if notifier.onActivate == nil {
            notifier.onActivate = { [weak self] id in self?.jump(sessionID: id) }
        }
        // SPEC §17.1: routes Allow / Deny / Reply / Open. `sessionLookup` needs `allSessions`,
        // which only exists now that `init` is behind us.
        notificationRouter.sessionLookup = { [weak self] id in
            self?.allSessions.first { $0.sessionID == id }
        }
        notifier.onAction = { [weak self] actionID, sessionID, text in
            guard let self else { return }
            self.notificationRouter.handle(actionID: actionID, sessionID: sessionID, text: text) {
                [weak self] session in
                self?.attention.present(session)
            }
        }
        notifier.start()

        store.onTransition = { [weak self] session, previous in
            self?.handle(transition: session, from: previous)
        }

        self.store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.apply(sessions) }
            .store(in: &cancellables)

        settings.$showIdle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.apply(self.rawSessions) }
            }
            .store(in: &cancellables)

        // History tab behind a switch: a tab already showing History falls back to Sessions the
        // moment the toggle goes off — fired once immediately (so `--tab history` at launch
        // cannot leave the panel on a tab that is not in its own strip) and again on every later
        // flip of the setting.
        settings.$showHistoryTab
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resolveTabIfNeeded() }
            .store(in: &cancellables)

        // SPEC §18.5: Sentinel behind the same kind of switch. `@Published` replays the current
        // value, so this both starts the engine at launch and follows every later flip.
        settings.$sentinelEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in self?.applySentinel(enabled: enabled) }
            .store(in: &cancellables)

        // SPEC §18.3/§18.6: `isVisible` is the only thing the tab writes back, and it is what
        // decides the sampling cadence.
        $tab
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in self?.updateSystemWatchVisibility(tab: tab) }
            .store(in: &cancellables)

        // SPEC §17.3: a chip, a host, the order or a pin changing re-filters and re-sorts the
        // same raw list — nothing here needs a fresh read from disk. On hold rides along here
        // too: a hold toggled from the row's context menu is decorated onto the session by
        // `apply()`, not read live from Settings the way `isPinned` is (the sort and the filter
        // chips need it *on* the record, not looked up beside it) — so it needs the same kick.
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                settings.$filterStates, settings.$filterHosts,
                settings.$sessionOrder, settings.$pinnedSessions
            ),
            settings.$heldSessions
        )
        .dropFirst()
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.apply(self.rawSessions) }
        }
        .store(in: &cancellables)

        // SPEC §15.4: a rename lands in the rows on the next frame — the names store is
        // observable and the list is simply decorated again.
        names.$names
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.apply(self.rawSessions) }
            }
            .store(in: &cancellables)

        settings.$usageRefreshInterval
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.usage.setInterval(value) }
            .store(in: &cancellables)

        Publishers.CombineLatest(settings.$discoverAgents, settings.$agentCommands)
            .receive(on: RunLoop.main)
            .sink { [weak self] discovery, commands in
                self?.store.apply(discovery: discovery, agentCommands: commands)
            }
            .store(in: &cancellables)

        // SPEC §11.4: the wait the reporter honours lives in `~/.lookout/config.json`, merged
        // with whatever else is already in there.
        settings.$waitSeconds
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                guard let self else { return }
                let url = self.home.config
                DispatchQueue.global(qos: .utility).async {
                    LookoutConfig.write(waitSeconds: seconds, to: url)
                }
            }
            .store(in: &cancellables)

        // SPEC §11.4: Ollama when it answers at startup, the heuristic when it does not. A
        // choice the user has already made is never overwritten.
        suggester.probe { [weak self] reachable, models in
            guard let self else { return }
            if self.settings.suggestionSource == nil {
                self.settings.suggestionSource = reachable ? .ollama : .heuristic
            }
            if self.settings.ollamaModel == nil {
                self.settings.ollamaModel = Ollama.defaultModel(models)
            }
        }

        // SPEC §17.7: re-read `codex-usage.json` whenever the Claude usage snapshot refreshes —
        // periodically, and immediately after a `Stop` — rather than polling it on a timer of
        // its own.
        usage.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshCodexUsage() }
            .store(in: &cancellables)

        // The rollout-derived limits change on the store's own tick, off this run loop.
        store.$rolloutUsage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshCodexUsage() }
            .store(in: &cancellables)

        // Bug fix (2026-09-04): the watcher's own 5 s timer publishes on its own schedule, off
        // this run loop entirely — a new (or newly closed) Codex question re-runs the whole
        // decorate/sort/notify pipeline exactly the way a renamed session already does above.
        codexQuestions.$questions
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.apply(self.rawSessions) }
            }
            .store(in: &cancellables)

        store.apply(discovery: settings.discoverAgents, agentCommands: settings.agentCommands)
        store.start()
        requests.start()
        codexQuestions.start()
        usage.start(interval: settings.usageRefreshInterval)
        refreshCodexUsage()
        startStaleTicker()
    }
}

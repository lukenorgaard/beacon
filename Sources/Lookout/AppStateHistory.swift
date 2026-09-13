import AppKit
import Combine
import Foundation

extension AppState {
    // MARK: - History (SPEC §17.5)

    /// A no-op after the first call — switching tabs back and forth must never re-read the file.
    func loadHistoryIfNeeded(now: Date = Date()) {
        guard historyEntries == nil else { return }
        historyEntries = HistoryStore.load(home: home, now: now)
        recomputeHistory()
    }

    func toggleHistoryFilter(_ filter: HistoryFilter) {
        var next = historyFilters
        if next.contains(filter) {
            next.remove(filter)
        } else {
            next.insert(filter)
        }
        if next.isEmpty || next == Set(HistoryFilter.allCases) { next = [] }
        historyFilters = next
    }

    /// A row's click: jump when the session is still live, otherwise nothing (the row is already
    /// disabled and muted — `HistoryView` never calls this for an ended one).
    func jumpToHistoryEntry(_ entry: HistoryEntry) {
        guard let session = allSessions.first(where: { $0.sessionID == entry.sessionID }) else {
            return
        }
        jump(to: session)
    }

    func recomputeHistory() {
        guard let entries = historyEntries else {
            if !historyGroups.isEmpty { historyGroups = [] }
            return
        }
        historyGroups = HistoryStore.grouped(
            HistoryStore.apply(entries, filters: historyFilters, search: historySearch)
        )
    }

    // MARK: - Codex usage (SPEC §17.7)

    /// Re-reads `codex-usage.json` on demand. Internal rather than private so a render test can
    /// populate `codexUsage` without calling `start()` (which would touch the network, the
    /// notification center and a handful of file watchers a headless test must never run).
    func refreshCodexUsage() {
        let snapshot = CodexUsageReader.read(home: home)
        if snapshot != codexUsage { codexUsage = snapshot }
    }
}

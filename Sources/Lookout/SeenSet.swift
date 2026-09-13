import Foundation

/// `done` rows the user has already looked at. Kept in memory and in UserDefaults by session id
/// (SPEC §5.2), so the green status dot goes out once and stays out — until that session
/// finishes another turn.
final class SeenSet {
    private static let key = "seenDoneSessions"

    let defaults: UserDefaults
    private var ids: Set<String>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: SeenSet.key) ?? [])
    }

    func isSeen(_ id: String) -> Bool { ids.contains(id) }

    func markSeen(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.insert(id)
        persist()
    }

    func markAllSeen(_ sessions: [Session]) {
        let done = sessions.filter { $0.state == .done }.map(\.id)
        guard !done.isEmpty else { return }
        let before = ids
        ids.formUnion(done)
        if before != ids { persist() }
    }

    /// A session that leaves `done` loses its flag — the next turn it finishes must light up
    /// again — and ids that no longer exist are dropped so the set cannot grow forever.
    func reconcile(with sessions: [Session]) {
        let stillDone = Set(sessions.filter { $0.state == .done }.map(\.id))
        let kept = ids.intersection(stillDone)
        guard kept != ids else { return }
        ids = kept
        persist()
    }

    func unseenDone(in sessions: [Session]) -> [Session] {
        sessions.filter { $0.state == .done && !ids.contains($0.id) }
    }

    private func persist() {
        defaults.set(Array(ids).sorted(), forKey: SeenSet.key)
    }
}

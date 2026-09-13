import SwiftUI

/// The Sessions list in two parts: everything else first, then Codex under a header of its own,
/// so the two kinds of work read apart at a glance instead of interleaving.
/// Within each part, sessions of the same project sit together, and a project with more than one
/// session gets a small header of its own.
///
/// Projects follow their first row in the selected sort order. In Pinned first mode, pinned
/// sessions have their own leading section across all agents and projects.
struct SessionSections: Equatable {
    enum Item: Identifiable, Equatable {
        /// The `CODEX` divider between the two parts.
        case section(title: String, count: Int)
        /// A project that holds two or more sessions within one part.
        case project(name: String, count: Int, codex: Bool)
        case row(Session)

        var id: String {
            switch self {
            case .section(let title, _): return "section:\(title)"
            case .project(let name, _, let codex): return "project:\(codex ? "codex" : "main"):\(name)"
            case .row(let session): return "row:\(session.id)"
            }
        }
    }

    var others: [Session]
    var codex: [Session]
    let items: [Item]

    init(_ sessions: [Session], pinned: Set<String> = [], order: SessionOrder = .state) {
        others = sessions.filter { $0.agent != .codex }
        codex = sessions.filter { $0.agent == .codex }
        let pinnedRows = order == .pinned ? sessions.filter { pinned.contains($0.id) } : []
        let pinnedIDs = Set(pinnedRows.map(\.id))
        let remainingOthers = others.filter { !pinnedIDs.contains($0.id) }
        let remainingCodex = codex.filter { !pinnedIDs.contains($0.id) }
        var items: [Item] = []
        if !pinnedRows.isEmpty {
            items.append(.section(title: "PINNED", count: pinnedRows.count))
            items += pinnedRows.map(Item.row)
        }
        items += SessionSections.clustered(remainingOthers, codex: false)
        if !remainingCodex.isEmpty {
            items.append(.section(title: "CODEX", count: remainingCodex.count))
            items += SessionSections.clustered(remainingCodex, codex: true)
        }
        self.items = items
    }

    var rowCount: Int { others.count + codex.count }

    /// Every drawn item that is not a row — the Codex divider and the project headers.
    var headerCount: Int { items.count - rowCount }

    /// Worktrees live inside the repository they branch from; their folder name is the row's
    /// title (`fix-export`), the repository is the cluster (`voyager`).
    static let worktreeMarkers = ["/.claude/worktrees/", "/.worktrees/"]

    /// Rows whose project cannot be worked out at all share one bucket, drawn last.
    static let otherKey = "\u{0}other"
    static let otherName = "Other"

    /// The project a session belongs to, or `otherKey` when there is nothing to go on.
    static func clusterKey(_ session: Session) -> String {
        let path = session.cwd
        // `URL(fileURLWithPath:)` resolves a relative — or empty — path against the *process*
        // working directory, which quietly clustered every path-less row under whatever folder
        // the app happened to be launched from. Every use below is guarded on an absolute path.
        for marker in worktreeMarkers {
            if let range = path.range(of: marker) {
                let parent = String(path[..<range.lowerBound])
                let repository = parent.isEmpty ? "" : URL(fileURLWithPath: parent).lastPathComponent
                if !repository.isEmpty, repository != "/" { return repository }
            }
        }
        // The home folder is where a session starts before it goes anywhere; its name is the
        // account's, not a project's.
        if !path.isEmpty, URL(fileURLWithPath: path).standardizedFileURL
            == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            return SessionSections.otherKey
        }
        if let project = Session.text(session.project) { return project }
        let folder = path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
        return folder.isEmpty || folder == "/" ? SessionSections.otherKey : folder
    }

    /// Groups by `clusterKey` in order of first appearance; rows inside a cluster keep their
    /// order, and every cluster carries a header.
    static func clustered(_ sessions: [Session], codex: Bool) -> [Item] {
        var order: [String] = []
        var groups: [String: [Session]] = [:]
        for session in sessions {
            let key = clusterKey(session)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(session)
        }
        // "Other" is a bucket, not a project: it goes last, whenever its first row turned up.
        let ordered = order.filter { $0 != otherKey } + order.filter { $0 == otherKey }
        return ordered.flatMap { key -> [Item] in
            let group = groups[key] ?? []
            let name = key == otherKey ? otherName : key
            // A header on every cluster, single-session ones included: without it a lone row
            // sitting under the cluster above reads as part of that cluster.
            return [.project(name: name, count: group.count, codex: codex)] + group.map(Item.row)
        }
    }
}

extension Theme.Metrics {
    var sectionHeaderHeight: CGFloat { scaled(16) }

    /// `listHeight(rows:)` with section headers counted in — each one is an item in the same
    /// stack, so it costs its own height plus one row gap. With no headers this is exactly the
    /// upstream figure.
    func listHeight(rows: Int, headers: Int) -> CGFloat {
        guard rows > 0 else { return emptyHeight }
        let items = rows + headers
        let content = CGFloat(rows) * rowHeight
            + CGFloat(headers) * sectionHeaderHeight
            + CGFloat(items - 1) * rowGap
        return min(content, listMaxHeight)
    }
}

/// `CODEX  3 ─────` in the Codex family blue, the same label the Usage tab uses for its Codex
/// card; project headers use the same shape, quieter.
struct SessionSectionHeader: View {
    let title: String
    let count: Int
    let color: Color
    var tracking: CGFloat = 0.8
    var lineOpacity: Double = 0.25

    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.scaled(6)) {
            Text(title)
                .font(metrics.sectionLabel)
                .tracking(tracking)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(count)")
                .font(metrics.sectionLabel)
                .foregroundStyle(Theme.textTertiary)
            Rectangle()
                .fill(color.opacity(lineOpacity))
                .frame(height: 1)
        }
        .padding(.horizontal, metrics.scaled(4))
        .frame(height: metrics.sectionHeaderHeight)
    }
}

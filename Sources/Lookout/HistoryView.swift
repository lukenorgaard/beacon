import SwiftUI

/// SPEC §17.5: the tab after Agents — reverse-chronological, grouped by day, filterable and
/// searchable. Reads `history.jsonl` (+ `.1`) lazily: `AppState.loadHistoryIfNeeded()` runs once,
/// the first time this view appears, so a session that never opens History never pays for it.
struct HistoryView: View {
    @ObservedObject var state: AppState

    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
        }
        .onAppear { state.loadHistoryIfNeeded() }
    }

    // MARK: - Toolbar: search + filter chips

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(6)) {
            HistorySearchField(text: $state.historySearch)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.controlGap) {
                    FilterChip(title: "All", count: nil, selected: state.historyFilters.isEmpty) {
                        state.historyFilters = []
                    }
                    ForEach(HistoryFilter.allCases) { filter in
                        FilterChip(
                            title: filter.label, count: nil,
                            selected: state.historyFilters.contains(filter)
                        ) {
                            state.toggleHistoryFilter(filter)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, metrics.padding)
        .padding(.top, metrics.scaled(6))
        .padding(.bottom, metrics.scaled(4))
        .frame(height: metrics.historyToolbarHeight)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.historyGroups.isEmpty {
            EmptyState(symbol: "clock.arrow.circlepath", title: emptyTitle, message: emptyMessage)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: metrics.rowGap) {
                    ForEach(state.historyGroups) { group in
                        HistoryDayHeader(day: group.day)
                        ForEach(group.entries) { entry in
                            HistoryRow(
                                entry: entry,
                                isLive: state.allSessions.contains { $0.sessionID == entry.sessionID }
                            ) {
                                state.jumpToHistoryEntry(entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, metrics.listInset)
            }
            .mask(overflowMask)
        }
    }

    @ViewBuilder
    private var overflowMask: some View {
        if metrics.historyListOverflows(rows: state.historyRowCount, groups: state.historyGroups.count) {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.86),
                    .init(color: .black.opacity(0.08), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

    private var emptyTitle: String {
        guard state.historyEntries != nil else { return "Loading history…" }
        return state.historySearch.isEmpty && state.historyFilters.isEmpty
            ? "No history yet" : "No matches"
    }

    private var emptyMessage: String {
        "Every state change — needs you, finished, started, ended — is logged here for 7 days."
    }
}

/// A plain search field, styled like the rest of the panel's chrome rather than a system control.
struct HistorySearchField: View {
    @Binding var text: String

    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.scaled(6)) {
            Image(systemName: "magnifyingglass")
                .font(metrics.font(10))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search history", text: $text)
                .textFieldStyle(.plain)
                .font(metrics.rowSecondary)
                .foregroundStyle(Theme.textPrimary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(metrics.font(10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, metrics.scaled(8))
        .frame(height: metrics.hitTarget)
        .background(
            RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.chipCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: metrics.stroke)
        )
    }
}

/// `TODAY`, `YESTERDAY`, or the weekday and date — one per day-group.
struct HistoryDayHeader: View {
    let day: Date

    @Environment(\.metrics) private var metrics

    private var label: String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMM"
        return formatter.string(from: day)
    }

    var body: some View {
        Text(label.uppercased())
            .font(metrics.sectionLabel)
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .frame(height: metrics.historyGroupHeaderHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One transition: time · agent colour dot · name/project · from→to (reason) · detail. Click
/// jumps to the session when it is still live; an ended session is a muted, disabled row instead
/// of a dead click.
struct HistoryRow: View {
    let entry: HistoryEntry
    let isLive: Bool
    let onTap: () -> Void

    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    private var dotColor: Color {
        switch entry.agent.name {
        case "claude": return Theme.familyClaude
        case "codex": return Theme.familyCodex
        default: return Theme.familyOther
        }
    }

    private var secondaryLine: String {
        var text = entry.transitionLabel
        if let detail = Session.text(entry.detail) { text += " · \(detail)" }
        return text
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: metrics.scaled(3)) {
                HStack(spacing: metrics.scaled(6)) {
                    Text(HistoryRow.time(entry.ts))
                        .font(metrics.numeral)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Circle()
                        .fill(dotColor)
                        .frame(width: metrics.scaled(6), height: metrics.scaled(6))
                    Text(entry.displayLabel)
                        .font(metrics.rowTitle)
                        .foregroundStyle(isLive ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: metrics.controlGap)
                    if !isLive {
                        Text("Session ended")
                            .font(metrics.chip)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Text(secondaryLine)
                    .font(metrics.rowSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, metrics.rowInset)
            .frame(height: metrics.historyRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isLive ? 1 : 0.55)
            .background(
                RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous)
                    .fill(hovering && isLive ? Theme.hoverFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: metrics.rowCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isLive)
        .onHover { hovering = $0 }
        .help(entry.tooltip)
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

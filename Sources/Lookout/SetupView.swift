import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

/// The rows of SPEC §10.2: hooks for both agents, the editor companion (§16.3), the three
/// permissions macOS asks for, and start-at-login. Same dark palette as the panel, but a plain
/// vertical stack — every control owns its own space, nothing is layered over anything.
struct SetupView: View {
    @ObservedObject var installer: HookInstaller
    /// SPEC §16.3: the editor companion's own row.
    @ObservedObject var companion: CompanionInstaller
    @ObservedObject var settings: Settings
    var onDone: () -> Void

    @State private var replaceOsascript = false
    @State private var launchAtLogin = LaunchAgent.isInstalled
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    /// `nil` while unknown — an unbundled run has no notification centre to ask.
    @State private var notificationStatus: UNAuthorizationStatus?

    /// SPEC §14: the setup window is a root of its own, so it reads the appearance and puts the
    /// measurements into its environment.
    var metrics: Theme.Metrics { settings.metrics }

    private static let accessibilityPane =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let notificationPane =
        "x-apple.systempreferences:com.apple.preference.notifications"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(spacing: metrics.setupCardGap) {
                    claudeCard
                    if installer.codexPresent { codexCard }
                    companionCard
                    accessibilityCard
                    notificationsCard
                    keychainCard
                    loginCard
                }
                .padding(.horizontal, metrics.padding + metrics.scaled(4))
                .padding(.vertical, metrics.padding)
            }
            // A ScrollView reports no intrinsic height, so the window collapsed to header +
            // footer (163 pt, seen live 2026-09-02). Give it a real height: all six rows fit at
            // 620 pt; scrolling is only the safety net for larger text.
            .frame(height: metrics.setupBodyHeight)

            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: metrics.setupWidth)
        .environment(\.metrics, metrics)
        .background(Theme.windowBackground)
        .environment(\.colorScheme, .dark)
        .onAppear(perform: recheck)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheck()
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.controlGap) {
                Text("Set up Beacon")
                    .font(metrics.setupTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text("v\(AppInfo.shortVersion)")
                    .font(metrics.chip)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: metrics.controlGap)
            }
            Text("Beacon watches your agent sessions. Install the hooks so every session reports "
                 + "in, then allow the three things macOS asks about.")
                .font(metrics.rowSecondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // A second language costs one line here and saves the first-run explanation for
            // the people the owner hands the installer to.
            Text("Dansk: Beacon holder øje med dine agent-sessioner. Tryk Install ud for hooks, "
                 + "og sig ja til de tre ting, macOS spørger om. Så er du kørende.")
                .font(metrics.rowSecondary)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, metrics.padding + metrics.scaled(4))
        .padding(.top, metrics.scaled(16))
        .padding(.bottom, metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: metrics.controlGap) {
            Button("Re-check", action: recheck)
                .disabled(installer.busy)
            Spacer(minLength: metrics.controlGap)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
        .padding(.horizontal, metrics.padding + metrics.scaled(4))
        .padding(.vertical, metrics.scaled(12))
    }

    // MARK: - 1. Claude Code hooks

    private var claudeCard: some View {
        SetupCard {
            SetupHeadline(
                dot: dot(for: installer.claude),
                title: "Claude Code hooks",
                message: hooksMessage(for: installer.claude, file: "~/.claude/settings.json")
            ) {
                hookButtons(status: installer.claude)
            }

            Toggle("Replace the old osascript notification hook", isOn: $replaceOsascript)
                .toggleStyle(.checkbox)
                .font(metrics.rowSecondary)
                .foregroundStyle(Theme.textSecondary)
                .disabled(!canRunInstaller)

            if let blocker = blockerMessage {
                SetupNote(text: blocker, tone: Theme.needsYou)
            }
            if let outcome = installer.lastOutcome {
                SetupNote(
                    text: outcome.message,
                    tone: outcome.succeeded ? Theme.textSecondary : Theme.needsYou
                )
            }
        }
    }

    @ViewBuilder
    private func hookButtons(status: HookStatus) -> some View {
        HStack(spacing: metrics.controlGap) {
            if installer.busy { ProgressView().controlSize(.small).scaleEffect(0.6) }
            Button(status == .notInstalled ? "Install" : "Reinstall") {
                installer.install(replaceOsascript: replaceOsascript) { outcome in
                    if outcome.succeeded { settings.setupSeen = true }
                }
            }
            .disabled(!canRunInstaller)
            if status != .notInstalled {
                Button("Remove") { installer.remove() }
                    .disabled(!canRunInstaller)
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: - 2. Codex hooks

    private var codexCard: some View {
        SetupCard {
            SetupHeadline(
                dot: dot(for: installer.codex),
                title: "Codex hooks",
                message: hooksMessage(for: installer.codex, file: "~/.codex/hooks.json")
                    + " The same button writes both files."
            ) {
                hookButtons(status: installer.codex)
            }
            SetupNote(
                text: "Codex runs its own hooks only after you trust them once: open a Codex "
                    + "session, run /hooks, and trust the lookout-report.py entries.",
                tone: Theme.textTertiary
            )
        }
    }

    // MARK: - 3. Editor companion (SPEC §16.3)

    private var companionCard: some View {
        SetupCard {
            SetupHeadline(
                dot: dot(for: companion.summary),
                title: "Editor companion",
                message: "A tiny extension inside Cursor, Devin and VS Code. Without it Beacon "
                    + "can only raise the window; with it, a click lands in the session's own "
                    + "terminal tab and Send and Rename type straight into it."
            ) {
                EmptyView()
            }

            ForEach(companion.apps) { status in
                CompanionAppRow(
                    status: status,
                    busy: companion.busy == status.app,
                    enabled: companion.canInstall && status.state.canInstall,
                    install: { companion.install(status.app) }
                )
            }

            if !companion.missingBundledFiles.isEmpty {
                SetupNote(
                    text: "This copy of Beacon is missing "
                        + companion.missingBundledFiles.joined(separator: ", ")
                        + " — rebuild the app.",
                    tone: Theme.needsYou
                )
            }
            if let outcome = companion.lastOutcome {
                SetupNote(
                    text: outcome.message,
                    tone: outcome.succeeded ? Theme.textSecondary : Theme.needsYou
                )
            }
        }
    }

    // MARK: - 4. Accessibility

    private var accessibilityCard: some View {
        SetupCard {
            SetupHeadline(
                dot: accessibilityTrusted ? Theme.done : Theme.idle,
                title: "Accessibility",
                message: accessibilityTrusted
                    ? "Granted. Clicking a Desktop row can select that session in the Claude app."
                    : "Not granted yet. Without it, a click on a Desktop row only brings the app "
                        + "forward instead of landing in the session."
            ) {
                Button(accessibilityTrusted ? "Open Settings" : "Allow…") {
                    open(SetupView.accessibilityPane)
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    // MARK: - 5. Notifications

    private var notificationsCard: some View {
        SetupCard {
            SetupHeadline(
                dot: notificationDot,
                title: "Notifications",
                message: notificationMessage
            ) {
                Button(notificationButtonTitle) { notificationAction() }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(notificationStatus == nil)
            }
        }
    }

    // MARK: - 6. Keychain

    private var keychainCard: some View {
        SetupCard {
            SetupHeadline(
                dot: Theme.idle,
                title: "Keychain",
                message: "On the first usage refresh, macOS asks whether Beacon may read the "
                    + "Claude Code credentials item. Choose Always Allow — the token only ever "
                    + "goes to Anthropic's usage endpoint."
            ) {
                EmptyView()
            }
        }
    }

    // MARK: - 7. Start at login

    private var loginCard: some View {
        SetupCard {
            SetupHeadline(
                dot: launchAtLogin ? Theme.done : Theme.idle,
                title: "Start at login",
                message: launchAtLogin
                    ? "A LaunchAgent in ~/Library/LaunchAgents starts Beacon when you log in."
                    : "Beacon will not come back after a restart until you open it yourself."
            ) {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Start at login")
                    .onChange(of: launchAtLogin) { _, newValue in
                        settings.launchAgentBootstrapped = true
                        _ = newValue ? LaunchAgent.install() : LaunchAgent.uninstall()
                    }
            }
        }
    }

    // MARK: - Derived text

    private var canRunInstaller: Bool {
        installer.pythonAvailable && !installer.busy && installer.missingBundledFiles.isEmpty
    }

    private var blockerMessage: String? {
        if !installer.missingBundledFiles.isEmpty {
            return "This copy of Beacon is missing "
                + installer.missingBundledFiles.joined(separator: ", ")
                + " — reinstall the app from the pkg."
        }
        if !installer.pythonAvailable {
            return "/usr/bin/python3 is not usable yet. Run xcode-select --install in Terminal, "
                + "then press Re-check. Session discovery and the Usage tab work without it."
        }
        return nil
    }

    private func hooksMessage(for status: HookStatus, file: String) -> String {
        switch status {
        case .installedHere:
            return "Installed in \(file), pointing at this copy of Beacon."
        case .installedElsewhere(let path):
            return "Installed in \(file), but pointing at \(path). Reinstall to point it here."
        case .notInstalled:
            return "Not installed. Beacon merges its entries into \(file), backs the file up "
                + "first, and leaves your other hooks alone."
        }
    }

    func dot(for state: CompanionState) -> Color {
        switch state {
        case .live: return Theme.done
        case .installable: return Theme.needsYou
        case .absent: return Theme.idle
        }
    }

    func dot(for status: HookStatus) -> Color {
        switch status {
        case .installedHere: return Theme.done
        case .installedElsewhere: return Theme.needsYou
        case .notInstalled: return Theme.idle
        }
    }

    private var notificationDot: Color {
        switch notificationStatus {
        case .authorized: return Theme.done
        case .provisional, .ephemeral, .denied: return Theme.needsYou
        default: return Theme.idle
        }
    }

    private var notificationMessage: String {
        switch notificationStatus {
        case .authorized:
            return "Allowed. Clicking a banner jumps straight to that session."
        case .provisional, .ephemeral:
            return "Delivered quietly. Allow them properly so needs-you banners are visible."
        case .denied:
            return "Turned off for Beacon. Switch them back on in System Settings → "
                + "Notifications, or you will not hear about a session that needs you."
        case .notDetermined:
            return "Not asked yet. Beacon sends one banner per transition and replaces it per "
                + "session, so they never pile up."
        case nil:
            return "Unavailable — this build is running unbundled."
        default:
            return "Unknown."
        }
    }

    private var notificationButtonTitle: String {
        notificationStatus == .notDetermined ? "Allow…" : "Open Settings"
    }

    // MARK: - Actions

    private func notificationAction() {
        guard AppInfo.isBundledApp else { return }
        guard notificationStatus == .notDetermined else {
            open(SetupView.notificationPane)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            refreshNotificationStatus()
        }
    }

    private func open(_ url: String) {
        guard let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }

    private func recheck() {
        installer.refresh()
        companion.refresh()
        accessibilityTrusted = AXIsProcessTrusted()
        launchAtLogin = LaunchAgent.isInstalled
        refreshNotificationStatus()
    }

    private func refreshNotificationStatus() {
        guard AppInfo.isBundledApp else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { notificationStatus = status }
        }
    }
}

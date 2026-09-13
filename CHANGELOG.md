# Changelog

## Unreleased — Beacon

- Rename the app and repository to Beacon; preserve local session data and hook commands.
- Use personal app and companion identifiers; document the settings and login-agent upgrade steps.
- Refresh setup, installation, privacy and contribution documentation and fixture screenshots.
- Add Sentinel resource charts, memory ranking, detailed explanations and confirmed Chrome-helper stops.
- Revalidate process identity before termination and escalation; protect critical processes.
- Validate reporter filename identifiers and include MIT notices in app/companion packages.
- Exclude untracked scratch files from source packaging and remove local build paths from app binaries.
- Replace personal development notes with neutral architecture documentation.
- Open macOS System Settings for disk review without a separate cleaner dependency.


All notable changes to Beacon (formerly Lookout) are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Codex sessions without hooks, grouped sessions and usage chips — 2026-09-13
- Codex Desktop sessions are discovered from Codex's own rollout files under `~/.codex/sessions/`,
  so they appear without trusted hooks. Only threads the user started become rows; Codex's
  sub-agent and review threads fold into their parent. A hook-written state file for the same id
  still wins.
- The Sessions list puts Codex sessions under a `CODEX` header and clusters sessions by project:
  worktrees group under their repository, and sessions with no identifiable project go to `Other`.
  Sort order, filters and pins still apply within each group.
- Usage chips beside the tabs show Claude and Codex limits, each number amber from 80 % and red
  from 90 %. The Codex usage section sits on its own card.
- Session rows and usage cards use an opaque background, and the last row is no longer faded.
- Codex Desktop rows are activated through AppleScript; `open -b` does not bring that app forward.
- `codex sandbox` helper processes are excluded from process discovery.
- A detail without a colon is no longer treated as a tool name, and the status label truncates
  instead of widening the row past the panel.
- The usage client backs off on 429 and 5xx responses (honouring `Retry-After`, 30 s to 15 min),
  pauses after a denied keychain prompt instead of prompting again on every refresh, and keeps the
  access token in memory only. Refresh always retries.
- Unpinning warns when macOS has hidden the status item behind the notch, and reopening the app
  brings the panel back in either mode.
- `scripts/build.sh` can sign with a stable self-signed identity from
  `scripts/make-local-identity.sh` when no Apple Development identity is available.
- `docs/INSTALL.md` covers Keychain *Always Allow*, the local signing identity and Codex sessions
  appearing before their hooks are trusted.

### Beacon — 2026-09-13
- Renamed the app, executable, distribution artifacts and public documentation to Beacon.
- Moved the repository to `lukenorgaard/beacon`, with Luke as code owner and reviewer.
- Kept existing Lookout session data and hook commands compatible.
- Documented the fork-and-pull-request workflow so contributors submit under their own accounts.
- Fixed installer test assertions that assumed a capitalized checkout folder name.
- Rebuild the companion when assembling the app so the bundled extension reflects current source.
- Allow `CODE_SIGN_IDENTITY=-` for an explicit ad-hoc build without selecting a Keychain identity.

### Repository preparation — 2026-09-13
- Added the public repository clone instructions and explicit network/privacy documentation.
- Anchored history integration and render tests to the fixture date so retention does not make
  the test suite fail as the calendar advances.
- Added source archives to release packaging and excluded local development records from Git.

### Source review — 2026-09-10

### Fixed
- Both usage-error logging calls now receive `lookout_home`. Malformed usage data cannot
  bypass Stop state persistence or SessionEnd history and cleanup through a broken logger.
  Diagnostics record only the exception type, not transcript contents.
- Codex Interrupt uses a 3-second timeout. Current Codex supports this event; stale comments
  claiming it was unwired have been corrected.

### Changed
- Split oversized Swift app files, Python reporter code and test suites by responsibility.
  Code/config files are limited to 500 physical lines, enforced by CI.
- The stable reporter entry point loads `hooks/lookout_reporter/`; app builds bundle the
  package alongside the entry point.
- Added a reproducible source ZIP, checksums, build instructions and a source map for UI merges.
- Isolated reporter tests from inherited Codex environment variables and implicit parent-shell
  assumptions; shell detection now uses an explicit child-agent fixture.

## 1.4 — 2026-09-04

### Added
- **Sentinel tab**: a fourth tab, right of Usage, watching overall system health — four gauges
  (CPU, memory pressure, swap, disk free) and a Top CPU list, plus warnings from twelve rules
  (memory pressure and critical memory, swap thrashing, CPU saturation, a hot WindowServer or
  VPN/security helper, low disk space, thermal pressure, an unexpected restart, process sprawl, a
  call app running while the machine is strained, and an orphaned process burning CPU) — a rule
  only fires once its condition has held for a while, not on a passing spike. Actions per warning:
  **Stop** (an orphaned process, or one of Lookout's own discovered agent processes — always
  behind a confirmation naming the pid and process before anything is killed), **Open Activity
  Monitor**, or **System Settings** for low disk space. Sensitivity (Critical only / Balanced / Early
  warning) and notifications live in Settings → Sentinel; the menu-bar dot turns the critical
  colour when a critical signal is active and no session needs you. Sampling runs off the main
  thread via `libproc`, with one exception: WindowServer and VPN/security helper processes run
  under a different user id, which `libproc` can't read for anyone but yourself, so one small,
  targeted `ps` call for just those pids runs at most every 15 seconds — the only shell-out in the
  whole tab.
- **Context per session**: a `ctx 24 %` chip on each row shows how full a session's context
  window is, from the reporter's new `context_tokens` / `context_window` / `context_at` /
  `context_compacted_at` fields (measured from the transcript tail on every tool call, stop and
  session end; cleared on compact). At or above a threshold — default 40 %, editable in
  Settings → General — the chip turns red with a small dot, and the header gains "N to compact".
  A per-model context-window table lives in Settings → Usage.

### Changed
- **Send framing**: every message Lookout sends into a session — from a card or a notification
  reply — now opens with a one-line header naming Lookout as the sender and asking the model to
  answer in that same session, so it's never mistaken for a stray peer message from another
  session and answered into the wrong place. Slash commands (`/rename`, `/compact`, …) are still
  sent raw.
- **Codex usage**: the Codex section in the Usage tab moved above the per-model cards and gained
  scroll indicators, since it had been scrolling out of view entirely; its usage bars are now
  labelled by the actual window length instead of always saying "5 hour" — a weekly limit was
  showing that label.
- **Performance**: the desktop jump now does a 50 ms press probe before the click, then verifies
  the click landed and retries once if not, logging one summary line per jump; Finished cards now
  expire after 30 minutes and never show twice for the same session state; the process scanner's
  cache is now keyed on pid **and** start time (not pid alone — pids get reused), sampling every
  5, 15 or 30 seconds depending on how much is changing.

### Fixed
- A stale question or permission request no longer attaches itself to a later, unrelated card.
- A `Stop` whose last message ends in a question mark is now reported as "done", even when
  background tasks are still listed.
- A working/background session with no update for over 2 hours now shows as Finished instead of
  staying stuck on "Working".
- Codex questions (`request_user_input`) are now detected straight from the session rollout,
  since Codex has no hook for them.
- Settings window sizing: the window no longer opens collapsed to a sliver.
- Cost estimate: token usage is now deduplicated by message id, so the same message is never
  counted twice toward the total.

### Fixed after review (2026-09-06)
- Sentinel: the "abandoned process" rule now needs positive evidence (an automation or scripted-agent helper adopted by launchd, still burning CPU) and is a warning, never critical — LaunchAgents, Homebrew services, XPC services and app extensions are never flagged.
- Sentinel: machine metrics are sampled every 5 s even while the tab is hidden, so rules with short windows (call at risk, memory critical) can fire; only process sampling slows to 15 s when hidden; opening the tab takes a fresh sample.
- Sentinel: the Stop confirmation is a sheet on the panel (a modal alert used to hide the panel), stopping runs in the background with a "Stopping…" state, and any failure is shown under the row.
- Desktop jump: no second click after a delivered click — the sidebar never reports selection, so the retry was dead time (≈ 120 ms after the row is found).
- Tests that depended on a quiet machine (process-scan timing, engine probe backoff) are robust under load.
- Cards: a question or permission card whose session then finishes now gets the 30-minute expiry and the show-once rule like any other Finished card.
- Send header: only real slash commands (`/compact`, `/rename …`) are sent bare; a message that merely starts with a path keeps the header.
- Settings: context-window fields commit on Enter or focus loss with a floor of 1,000 tokens, so a half-typed value can no longer turn every row red.
- Reporter: a non-numeric usage value in a transcript no longer stops the session's state file from being written (context and cost paths both guarded).
- Universal binary: the pkg now runs on Intel Macs as well as Apple Silicon; INSTALL.txt (English and Danish) ships next to the pkg and inside the dmg with the one Terminal line that gets past Gatekeeper on an unnotarised download.
- `swift test` no longer rewrites the README screenshots; set `LOOKOUT_REGENERATE_SCREENSHOTS=1` to regenerate them.

## [1.3] - 2026-09-03

### Added
- Notification banner actions: a permission banner now carries **Allow** / **Deny** / **Open**
  buttons, and a question or "finished" banner carries **Open** and a text-input **Reply…** —
  answered right from the banner, no need to open the card first.
- Global keyboard shortcuts via Carbon `RegisterEventHotKey` (no Accessibility needed): toggle the
  panel, jump to the session that's waited longest for you, focus the current card's reply field,
  and Allow/Deny the current permission card. Defaults ⌃⌥L / ⌃⌥J / ⌃⌥R / ⌃⌥A / ⌃⌥D, rebindable or
  clearable in Settings → General.
- Sessions tab: filter chips (Needs you / Working / Finished / Idle) with counts, a host filter
  popover, and four sort orders (By state / By activity / By project / Pinned first) with a
  per-row **Pin to top**.
- Answer presets: up to nine reorderable one-line replies in Settings → Cards, shown as buttons
  above the card's reply field and bindable to ⌘1–⌘9.
- History tab: a reverse-chronological, day-grouped log of every state transition, with its own
  filter chips and a search field. Backed by a new `~/.lookout/history.jsonl` the reporter appends
  to on every transition (rotated at 5 MB into `history.1.jsonl`).
- Cost per session: the reporter accumulates per-model token counts from each session's transcript;
  a per-model USD/MTok pricing table in Settings → Usage (editable, sensible defaults) turns that
  into a cost chip per row and a **Sessions today** summary in the Usage tab.
- Codex parity: **Send** now works for Codex sessions too, via a `codex queue` subprocess of the
  user's own CLI (no socket, no API call); the Usage tab reads Codex's 5-hour and weekly limits
  from a new `~/.lookout/codex-usage.json`, which the reporter keeps updated straight from Codex's
  own session files — no API call for this either. Codex sessions get permission cards and
  Allow/Deny like Claude Code, but never question cards — Codex has no `AskUserQuestion`-equivalent
  hook.
- Open-source packaging: `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, a `.gitignore`, GitHub
  Actions CI (`swift test`, the reporter's end-to-end suite, the companion's `node --test` suite,
  a companion vsix build check) and a release workflow that builds and attaches the pkg, dmg and
  vsix to a tagged release.

## [1.2]

### Added
- Attention card: a panel docked next to the sessions list that opens when a session needs you,
  showing the full permission request or question and four actions — **Allow**, **Deny**, **Send**
  (delivers a reply into the session without stealing focus), and **Copy & go** (the automatic
  fallback whenever Send isn't available).
- Suggested replies in the attention card from one of three sources: a built-in heuristic, a local
  Ollama model, or your own Claude Code subscription via headless `claude -p`.
- **Agents** tab: every live sub-agent across every session in one list, so a session that has
  fanned out into several background agents doesn't collapse into a single "Working…" row.
- Row colouring by family (Claude, Codex, local model, OpenRouter/custom) plus a model chip
  (`Fable`, `Sonnet`, `GPT-5.6`, …), with a legend in Settings.
- Appearance presets (Compact / Default / Comfortable / Large), a text-scale slider, and a panel
  that can be resized by dragging its edge.
- Rename a session — locally always, and, where a mechanism exists, in the session itself: the
  desktop app's own title tool, `/rename` typed into a Terminal.app/iTerm2 tab, or copy the command
  and jump there for Cursor/Devin.
- Editor companion: an optional Cursor/Devin/VS Code extension that lets Lookout focus, and type
  into, the exact integrated terminal a session is running in, instead of only raising the window.
- Worktree awareness: a session's row and jump target no longer get hijacked by a sub-agent
  reporting from inside a git worktree; a worktree chip is shown instead, and jumping resolves a
  worktree back to its open main-repository window.

### Fixed
- Sessions running inside the Claude desktop app now jump to the exact sidebar session instead of
  only bringing the app to the front.
- Sub-agent counts no longer go stale when hook events for the same session arrive concurrently
  (the reporter now takes a per-session lock).
- The messaging-socket token used by Send is now read from a private, per-session token file
  instead of relying on process-argument visibility, which isn't always available at the point the
  app needs it.

## [1.1]

### Added
- Self-installing `.pkg` (and a drag-and-drop `.dmg`): the reporter, hook fragments, and installer
  now ship inside the app bundle, so a recipient never needs the repository or a terminal.
- A Setup window, shown automatically on first launch, that installs/removes the hooks and reports
  Accessibility, Notifications, and Keychain status, plus a start-at-login toggle.
- Code-signing with a stable Apple Development identity when one is available in the keychain, so
  Accessibility and Keychain grants survive a rebuild instead of being invalidated by a fresh
  ad-hoc signature every time.

## [1.0]

### Added
- Initial release: a Sessions tab (state, host, time in state) and a Usage tab (5-hour and weekly
  Claude limits, read from the same keychain token the `claude` CLI already uses).
- The reporter (`hooks/lookout-report.py`), driven by Claude Code and Codex hooks, writing one
  small JSON state file per live session under `~/.lookout/sessions/`.
- Jump-to-session per host: the Claude desktop app's deep link, Cursor and Devin via
  LaunchServices, Terminal.app and iTerm2 via AppleScript.
- macOS notifications on "needs you" and "finished" that jump to the session when clicked.
- Any-agent support: a generic manual reporter mode (`--agent <name> --set <state>`, no JSON hooks
  required) and a process-discovery fallback that lists agents with no hooks as "Running · no
  hooks".
- Sub-agent tracking per session (`SubagentStart`/`SubagentStop`).
- `scripts/install-hooks.py`: idempotent, dry-run diff, automatic backup before writing, `--remove`.

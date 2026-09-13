# Contributing to Beacon

Thanks for looking at this. Beacon is a small, opinionated tool built for a specific workflow
(lots of parallel Claude Code / Codex sessions across Spaces), so the bar for a change is less
"does it work" and more "does it keep the whole thing fast, quiet, and safe to run unattended."

## Repository layout

```
beacon/
  Package.swift                 # Swift package manifest (macOS 14+, Swift 5.9 tools)
  Sources/Lookout/               # the app: AppKit + SwiftUI, one executable target
    SessionFilter.swift          # sessions-tab filter chips, host filter, sort orders
    HotKeys.swift                # global keyboard shortcuts (Carbon RegisterEventHotKey)
    AnswerPresets.swift          # reusable one-line replies, ⌘1–⌘9 bindings
    NotificationActions.swift    # notification-banner action buttons and routing
    HistoryModel.swift           # History tab: parses/filters/groups history.jsonl
    Pricing.swift                # per-model USD/MTok pricing table and cost math
    CodexUsage.swift             # parses codex-usage.json for the Usage tab
    CodexQueueSender.swift       # Send for Codex sessions, via `codex queue`
  tests/LookoutTests/            # XCTest suite for the app (swift test)
  hooks/lookout-report.py        # the reporter — invoked by Claude Code / Codex hooks
  hooks/claude-hooks.json        # hook fragment merged into ~/.claude/settings.json
  hooks/codex-hooks.json         # hook fragment merged into ~/.codex/hooks.json
  scripts/build.sh               # builds and (optionally) installs Beacon.app
  scripts/package.sh             # builds the .pkg / .dmg
  scripts/install-hooks.py       # merges/removes the hook fragments in your real config
  scripts/build-companion.py     # zips companion/ into a .vsix, stdlib only
  scripts/install-companion.sh   # installs the .vsix into Cursor / Devin / VS Code
  tests/test_reporter.sh         # end-to-end tests for the reporter + installer
  tests/fixtures/                # sample state files, requests, transcripts, usage response,
                                  # history.jsonl, codex-usage.json, codex-rollout.jsonl
  companion/                     # the Cursor/Devin/VS Code extension (plain JS, no build step)
  companion/test/                # node:test suite for the companion's HTTP server
  docs/screenshots/               # images used in the top-level README
  docs/history/                  # design notes from the original build (see docs/README.md)
```

The three parts — the Swift app, the Python reporter, and the JS companion extension — are
file-disjoint on purpose. A change to one should essentially never require touching the others;
if it does, that's worth calling out in the PR description.

The public app and Swift executable product are named **Beacon**. The Swift module and source
folder remain `Lookout`; existing data paths and hook commands retain their old names for
compatibility. The app and companion publisher use the personal Beacon identity. Apply
contributions to these existing paths.

## Running the tests

There are three independent suites. All three should pass before you open a PR.

**Swift app:**
```sh
swift build
swift test
```
`swift test` never touches `docs/screenshots/` on its own; run with `LOOKOUT_REGENERATE_SCREENSHOTS=1 swift test --filter Readme` to regenerate the six tracked PNGs after a UI change.

**Reporter + installer** (bash driving the real `hooks/lookout-report.py` and
`scripts/install-hooks.py` against temporary config files and a temporary `LOOKOUT_HOME` — it never
touches your real `~/.lookout`, `~/.claude/settings.json`, or `~/.codex/hooks.json`):
```sh
bash tests/test_reporter.sh
```

**Editor companion** (Node's built-in test runner against a fake `vscode` module — no editor, no
npm dependencies required):
```sh
node --test companion/test
```

If you touch `scripts/build-companion.py`, also sanity-check that it still produces a valid vsix:
```sh
python3 scripts/build-companion.py
```

## Ground rules

- **Keep every code file at or below 500 lines**, including tests, comments and blank lines.
  Split by responsibility. Swift extensions keep related behavior together while stored
  properties stay in their owning type; reporter modules have explicit imports. Run
  `python3 scripts/check-code-size.py` before a handoff. CI enforces the same limit.

These aren't arbitrary style preferences — each one maps to something that broke, or would have,
during Beacon's own development:

- **No shell-outs on the app's main thread.** Every jump action, every AppleScript call, every
  hook-installer invocation, every companion HTTP request runs on a background queue. Beacon is
  meant to sit pinned open across every Space at effectively zero idle cost; blocking the main
  thread for the length of a `Process` launch is exactly the kind of thing that turns "pinned
  panel" into "thing you quit after a day."
- **Never log a token, and never log the process environment.** Neither the reporter nor the app
  logs OAuth, messaging or companion credentials. Private token files are documented in
  SECURITY.md and must never be included in a report or source archive. The reporter extracts an explicit whitelist of fields from the environment (host
  identification, entrypoint) — it does not dump `os.environ` anywhere, even to a log meant to be
  read only by you. If you add a new field the reporter reads from the environment, add it to the
  whitelist explicitly; don't widen the read.
- **The reporter stays Python 3 stdlib, no third-party dependencies, and 3.9-compatible.** It runs
  synchronously inside a Claude Code / Codex hook on every single event, on whatever `python3` is
  on the machine it happens to run on — no venv, no pip install step, no assumption about which
  Python minor version is installed. Concretely: no walrus-operator-only patterns that would break
  on old point releases if you're not sure, no `match` statements, no non-stdlib imports.
- **The reporter exits 0 on internal errors and keeps waits bounded.** A hook that fails
  or hangs affects a real Claude Code / Codex session that has nothing to do with Beacon. Wrap new
  code paths so an exception is caught, logged to `~/.lookout/reporter.log`, and the process still
  exits cleanly. Permission requests may wait for an explicit answer for the configured interval; other
  hooks should return promptly. Keep lock waits bounded as well.

## Adding a new host (Cursor/Devin-style jump target)

"Host" means whatever application is actually hosting the terminal/session — see
`SessionHost` in `Sources/Lookout/SessionModel.swift` for the current enum and
`Sources/Lookout/Jumper.swift` for how each one is focused. Adding one touches:

1. **Reporter** (`hooks/lookout-report.py`) — teach the ancestor-process walk to recognize the new
   host's process name and set `host` accordingly.
2. **App** (`Sources/Lookout/SessionModel.swift`) — add the case to `SessionHost` and its chip
   label.
3. **Jumper** (`Sources/Lookout/Jumper.swift`) — add the focus strategy: an `open -a`/`open -b`
   call, an AppleScript, or (for a VS Code-family editor) the companion-first / open-window-folder
   path already used for Cursor and Devin.
4. Tests in `tests/LookoutTests/` covering the new host's identification and jump path, plus a
   fixture in `tests/fixtures/sessions/` if it's useful for visual/manual checks.

## Adding a new agent

Any agent that isn't Claude Code or Codex doesn't need reporter code changes at all — the generic
`--agent <name> --set <state>` manual mode (see [the reporter reference](docs/REPORTER.md))
already covers it as long as the caller is willing to make a couple of shell calls around its own
run. If you want it picked up automatically by process discovery instead (no reporter calls at
all, shown as `Running · no hooks`), add its executable basename to the default list in
Settings → Agents (`Sources/Lookout/AppState.swift` / the discovery settings) and make sure its
help/version/MCP-server invocations are excluded the same way `codex mcp-server` already is, so a
tool's own subprocesses don't get double-counted as separate agents.

## Pull requests

1. Fork [lukenorgaard/beacon](https://github.com/lukenorgaard/beacon) into your own GitHub account.
2. Create a branch from the current `main` and apply your changes there. If you started from a
   source ZIP, copy only the files you changed; preserve newer fixes already on `main`.
   For older checkouts, use a fresh clone and copy the intended source changes. Do not merge
   old Git history or include local notes, logs, credentials or real session data.
3. Commit with an email linked to your GitHub account (your GitHub noreply address works), so
   your commits are attributed to you.
4. Push to your fork and open a pull request targeting `lukenorgaard/beacon:main`.

Luke (`@lukenorgaard`) reviews contributions and decides whether to merge them. The review policy
requires maintainer approval, passing CI and resolved review conversations; changed code needs
another review. GitHub's automatic enforcement depends on the account plan and repository
visibility, so check the current branch settings. While the repository is private, the maintainer
must grant access before you can clone or contribute. Public contributions do not require write access.

Keep them focused — one behavior change per PR is much easier to review than a bundle of unrelated
fixes. Mention which of the three suites you ran and their results. Preserve the contributor's
commit authorship when merging so GitHub can credit their work.

By submitting a contribution, you confirm that you have the right to publish it under the
project's MIT license. Do not submit confidential employer/client material or code copied from
an incompatible license. Describe any third-party code and preserve its required notices.

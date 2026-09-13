# Sample session files

Six state files covering every state and every host in SPEC §4, for eyeballing the panel without
running a single real agent.

Point the app at this folder instead of `~/.lookout`:

```bash
LOOKOUT_HOME="$PWD/tests/fixtures" /Applications/Beacon.app/Contents/MacOS/Beacon
```

`SessionStore` looks for `$LOOKOUT_HOME/sessions/*.json`, so the env var names the *parent* of this
directory.

## Why every `pid` is 1

The app deletes a state file as soon as `kill(pid, 0)` says the process is gone (SPEC §4). `launchd`
is pid 1 and is always alive, so these samples survive the liveness tick.

## Nothing here is ever deleted

When `LOOKOUT_HOME` is set, pruning is off: dead or stale files are shown rather than removed, so a
fixture can never be eaten by a test run. Set `LOOKOUT_PRUNE=1` alongside `LOOKOUT_HOME` if you
actually want to exercise the delete path against a throwaway directory.

## Timestamps

`state_since` / `updated_at` are absolute (2026-09-02). They keep working forever — durations just
grow — except that the 24-hour staleness rule applies if you ever copy these into the real
`~/.lookout/sessions` with pruning on. Don't; use `LOOKOUT_HOME`.

## What they exercise

| File | State | Host | Point |
|---|---|---|---|
| `claude-ab813983-…` | needs_you / permission | cursor | `Needs permission · Bash` + `rm -rf build`, oldest needs-you so it sorts first; empty `subagents` list, so no chip; `claude-sonnet-5` with no `provider` → `Sonnet` chip, Claude family (SPEC §9.5) |
| `codex-7c1f0a52-…` | needs_you / question | terminal | `Question for you`; `gpt-5.6-sol` / `openai` → `GPT-5.6` chip, Codex family (light blue); the only fixture with a context measurement — `context_tokens` 122 000 of its own reported `context_window` 258 400 → `ctx 47 %` in red, over SPEC §19.2's 40 % (the app's own table is never consulted when the record carries a window) |
| `claude-1d9e4b77-…` | done | claude-desktop | `Finished` + `last_message`, `host_ref` deep-link jump (SPEC §9.1), `desktop_title` for the AX sidebar press (SPEC §9.4); `claude-fable-5-1` / `anthropic` → `Fable` chip, no provider suffix because it is the default |
| `claude-3b6a2c19-…` | working | devin | two sub-agents with their own `cwd` (SPEC §9.3, §12.2) and `2 agents · …` secondary text; `worktree` + `active_cwd` → the `⎇ wt-export-impo…` chip (SPEC §12.3), which takes line 1's single chip slot from the `⑂ 2` and `Llama · Local` chips; still **teal** family, because the provider outranks the agent |
| `claude-5f2d8e60-…` | working | iterm | iTerm `host_ref` jump path; `claude-opus-5` / `openrouter` → `Opus · OpenRouter` chip, **violet** family |
| `claude-9a0c5d34-…` | idle | terminal | hidden when "Show idle sessions" is off; no `model` at all, so the row keeps the ✦ agent glyph instead of a chip |

Expected order in the panel: the two needs-you rows (oldest first), then done, then the two working
rows (newest first), then idle. Any `running` rows the process scan finds sit between working and idle.

## Requests (SPEC §11.3)

`../requests/` holds one open request per `needs_you` fixture, named
`<agent>-<session_id>-<request_id>.json` exactly as the reporter writes it, and the two session
files point back at them with `request_id` / `request_summary`:

| File | Kind | Point |
|---|---|---|
| `claude-ab813983-…-3f9c1a7e` | permission | `Bash` + a three-line command, so the card's monospaced box has something to show and to scroll |
| `codex-7c1f0a52-…-b21d40c5` | question (on disk) | the request file itself still says `kind: question` — `RequestStore` reads it back verbatim — but SPEC §17.7 has no AskUserQuestion-equivalent hook for Codex, so the card coerces any Codex session to a permission-style ask (no option buttons) regardless of what the file says; Send goes through `codex queue --thread <session_id>` instead of a messaging socket, and only falls back to Copy & go when that command fails |

Launch the app against the whole set — sessions *and* requests — with the same variable:

```bash
LOOKOUT_HOME="$PWD/tests/fixtures" /Applications/Beacon.app/Contents/MacOS/Beacon
```

### Why `waits_until` is in 2036

The permission request's wait is deliberately a decade out. A request whose `waits_until` has
passed is *expired*: the card replaces Allow/Deny with "Answer in the terminal" (SPEC §11.4),
which is not what a fixture is for. The question request has no `waits_until` at all, because a
question never makes the reporter wait.

### `messaging_socket` is always null

The path is real on a live session (`/tmp/cc-socks/<pid>.sock`) and the token that goes with it
is never on disk (SPEC §11.2). No fixture names a socket: Send would then be pointed at somebody
else's session. With it null the card offers Send only when the live process environment has
one, which no fixture pid ever does.

## Families

Four of the five §9.5 families are on screen at once with these six files: Claude (orange),
Codex (light blue), Local model (teal) and OpenRouter / API (violet). The fifth, lavender-grey
"Other", only appears for an agent that is neither `claude` nor `codex` — start `gemini` or run
with discovery on and a `running` row shows it, at the quieter 25 % outline.

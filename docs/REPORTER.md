# Reporter reference

## Report from any agent

Claude Code and Codex use the hooks above automatically. Any other agent — a local model, a shell
wrapper, a cron job — can report into the same session list with a couple of manual calls; no JSON
hooks required, and `state` gains one extra value for this mode: `running` (alive, no detail
known). `--cwd` defaults to `$PWD`, `--pid` defaults to the reporter's own parent pid.

```sh
# before doing work
hooks/lookout-report.py --agent gemini --set working --session my-task-1 \
  --cwd "$PWD" --title "Summarize the quarterly report" --detail "step 2 of 5"

# something needs your input
hooks/lookout-report.py --agent gemini --set needs_you --session my-task-1 \
  --detail "waiting for API key"

# done
hooks/lookout-report.py --agent gemini --set done --session my-task-1 --message "Done."

# session over — deletes the state file
hooks/lookout-report.py --agent gemini --end --session my-task-1
```

A minimal wrapper around a local-model agent just needs a `--set working` before the run and a
`--set done` (or `--set idle`) after:

```sh
#!/usr/bin/env bash
SESSION="local-$$"
REPORTER=~/beacon/hooks/lookout-report.py   # wherever you cloned/installed Beacon
"$REPORTER" --agent my-local-model --set working --session "$SESSION" --cwd "$PWD"
my-local-model-cli "$@"
"$REPORTER" --agent my-local-model --set done --session "$SESSION"
```

`--agent auto` picks a name for you (`claude` when `CLAUDECODE=1` is set, `codex` when any
`CODEX_*` env var is present, otherwise `unknown`) — useful when the same wrapper script might run
under either. Agent names are otherwise free-form (`[a-z0-9_-]`, up to 32 characters); anything
else is rejected (logged, no file written) rather than silently mangled.

Session IDs use 1–160 ASCII letters, digits, underscores, hyphens or dots, excluding `.` and `..`.
Paths, control characters and glob patterns are rejected.

## Session state file

Path: `~/.lookout/sessions/<agent>-<session_id>.json` (directory mode `700`), written atomically
(temp file + `rename`). Schema version 1. This is the full contract between the reporter and the
app.

| Field | Type | Meaning |
|---|---|---|
| `schema` | int | Always `1` |
| `agent` | string | `"claude"` \| `"codex"` \| any `[a-z0-9_-]{1,32}` reporter name |
| `session_id` | string | Session id from the hook payload / `--session` |
| `state` | string | `"idle"` \| `"working"` \| `"needs_you"` \| `"done"` \| `"running"` (manual mode only, alive with no detail known) |
| `reason` | string | `session_start`, `prompt`, `tool`, `tool_done`, `permission`, `question`, `stop`, `interrupted`, `manual`, … |
| `detail` | string, optional | ≤ 120 chars, human text for the row (tool + command/file, question text, …) |
| `cwd` | string | Working directory of the session |
| `project` | string | `basename(cwd)` |
| `title` | string, optional | First user prompt, ≤ 80 chars, set once |
| `last_message` | string, optional | ≤ 160 chars, from the last `Stop` (or `--message`) |
| `pid` | int | Agent process pid |
| `tty` | string, optional | e.g. `ttys005`; `null` for the desktop app |
| `host` | string | `"cursor"` \| `"devin"` \| `"vscode"` \| `"terminal"` \| `"iterm"` \| `"claude-desktop"` \| `"codex-app"` \| `"unknown"` |
| `host_pid` | int, optional | pid of the host app; `null` if unknown |
| `host_ref` | string, optional | the desktop app's own session id, or `TERM_SESSION_ID` / `ITERM_SESSION_ID`, when present |
| `entrypoint` | string | `"claude-desktop"` \| `"cli"` \| `"codex"` |
| `transcript_path` | string, optional | Path to the session transcript |
| `started_at` | string | ISO 8601 UTC, set once |
| `state_since` | string | ISO 8601 UTC, updated only when `state` changes |
| `updated_at` | string | ISO 8601 UTC, updated on every event |
| `subagents` | array, optional | Live sub-agents: `{id, type, description, model, started_at}` |
| `desktop_title` | string, optional | The title the desktop app / CLI currently shows for this session |
| `model` | string, optional | Model of the newest assistant message, short display name |
| `provider` | string, optional | `anthropic`, `openai`, `openrouter`, `local` or `custom` |
| `tokens` | object, optional | Cumulative token counts since the reporter started tracking, keyed by model: `{model: {in, out, cache_read, cache_write}}` |
| `context_tokens` | int, optional | Current prompt size (context in use), from the last 256 KB of the transcript at `PostToolUse`/`Stop`/`SessionEnd`; cleared to `null` on `PostCompact` |
| `context_window` | int, optional | Codex only — `model_context_window` from the same measurement; `null` for Claude (the app resolves the window per model) |
| `context_at` | string, optional | ISO 8601 UTC, when `context_tokens` was last measured |
| `context_compacted_at` | string, optional | ISO 8601 UTC, set on `PostCompact` alongside the `context_tokens` clear |

The app treats a file as dead (and deletes it) when its `pid` is no longer alive or `updated_at`
is more than 24 hours old.

Two more small files live alongside the session files, both written by the same reporter:

- **`~/.lookout/history.jsonl`** — one JSON line per state transition (`{ts, agent, session_id,
  project, name, from, to, reason, detail, last_message}`), appended in place and rotated into
  `history.1.jsonl` once the live file passes 5 MB. This is what backs the History tab.
- **`~/.lookout/codex-usage.json`** — the newest Codex rate-limit snapshot seen in any Codex
  session's transcript (`updated`, `limit_name`, `plan_type`, and a `primary`/`secondary` window
  each with `used_percent`, `window_minutes`, `resets_at`), written atomically like the session
  files. This is what backs the Codex half of the Usage tab — Beacon never calls a Codex API for
  it.


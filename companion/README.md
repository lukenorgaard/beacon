# Beacon Companion

A tiny VS Code extension that lets [Beacon](../README.md) reach *inside* a
Cursor, Devin or VS Code window instead of only raising it.

Without it Beacon can bring the editor window to the front, but it cannot tell
which of the six integrated terminals in that window runs the agent you clicked.
The extension API can: `vscode.window.terminals`, `terminal.processId`,
`terminal.show()`, `terminal.sendText()`.

## What it does

On activation (`onStartupFinished`) every editor window's extension host:

1. starts an HTTP server on `127.0.0.1`, on a random free port,
2. mints a fresh random 32-hex token,
3. writes `~/.lookout/companion/<app>-<extension host pid>.json` (mode `600`):

```json
{
  "app": "cursor",
  "pid": 51234,
  "port": 52791,
  "token": "…32 hex chars…",
  "windowTitle": "acme-web",
  "folders": ["/Users/you/acme-web"],
  "started_at": "2026-09-03T09:12:44.031Z",
  "version": "0.1.0"
}
```

`app` is `vscode.env.appName` lower-cased and simplified: `cursor`, `devin`
(Devin/Windsurf), `vscode` (Visual Studio Code / Code - OSS), otherwise a slug of
the name. Beacon scans that folder, drops files whose pid is dead, and talks to
the rest.

The file is deleted on deactivate and when the server closes.

## Endpoints

Every request needs `Authorization: Bearer <token>`; anything else is `401`.
Request bodies are JSON and at most 64 KB (`413` above that). Responses are JSON.

| Method | Path         | Body                              | Response |
| ------ | ------------ | --------------------------------- | -------- |
| GET    | `/ping`      | –                                 | `{app, pid, version}` |
| GET    | `/terminals` | –                                 | `[{index, name, processId, cwd, creationOptions:{cwd}, isActive}]` — `processId` is awaited, `null` when unknown |
| POST   | `/focus`     | `{processId}`                     | `{ok, index, name, processId}`; `404` when no terminal has that pid |
| POST   | `/send`      | `{processId, text, newline=true}` | `{ok, index, name, processId}`; `404` as above |

Every request logs one line to the **Beacon** output channel
(View → Output → Beacon). The token is never logged.

## Security

- The server binds `127.0.0.1` only — nothing outside this Mac can reach it.
- The token is new on every window start and lives only in the state file, which
  is created with mode `600` (owner read/write). It is not exported through the
  extension API and never written to the log.
- The extension declares no `contributes`, reads no files and makes no outbound
  requests. It only lists terminals, shows one, and types into one.

## Install

Built and installed by Beacon (Setup → Editor companion), or by hand from the
repository root:

```sh
python3 scripts/build-companion.py          # → build/lookout-companion.vsix
bash scripts/install-companion.sh all       # cursor | devin | vscode | all
```

Then reload the window (⌘⇧P → *Reload Window*) or restart the app.

## Uninstall

Extensions view (⌘⇧X) → search "Beacon Companion" → Uninstall, or from a
terminal:

```sh
/Applications/Cursor.app/Contents/Resources/app/bin/cursor --uninstall-extension lukenorgaard.lookout-companion
/Applications/Devin.app/Contents/Resources/app/bin/devin-desktop --uninstall-extension lukenorgaard.lookout-companion
"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" --uninstall-extension lukenorgaard.lookout-companion
```

Reload the window afterwards; the state file disappears with it. Any leftovers
can be removed with `rm -rf ~/.lookout/companion`.

## Tests

```sh
node --test companion/test
```

The suite drives the real HTTP server against a fake `vscode` module injected as
the second argument of `activate(context, api)`. No editor, no npm dependencies.

# Security and privacy

## Scope and reporting

Beacon is a personal MIT-licensed project, not a security product. Tests and reviews reduce risk;
they do not guarantee safety, compatibility or legal immunity. Report vulnerabilities privately
through this repository's **Security → Report a vulnerability**, not a public issue containing
credentials or exploit details. If private reporting is unavailable, request a private channel
without publishing sensitive material.

## Data and network access

Beacon runs as your macOS user. It reads session files, transcript excerpts, workspace metadata
and process information needed for monitoring and jumping. Local state under `~/.lookout` can
include project paths, prompts, tool commands, questions, answers, titles, usage and message excerpts.
Logs may include excerpts or diagnostic replies. Truncation is not redaction: text can still contain
secrets or confidential material. Do not upload this directory, raw logs or real screenshots.

Automatic Codex discovery reads recent files under `$CODEX_HOME/sessions` (by default
`~/.codex/sessions`). It retains parsed metadata in memory while a rollout is recent and drops
it when the file ages out. Reads are bounded; older context in very large files may be unavailable
on a cold start. CLI sessions are matched using open rollout file paths from macOS process
information. Discovery itself does not upload transcripts or write a transcript cache to disk.

Beacon has no maintainer-operated service, telemetry or analytics. The intentional network and
process integrations are:

- **Claude usage:** `https://api.anthropic.com/api/oauth/usage`, authenticated with the end user's
  Claude Code OAuth credential from macOS Keychain. No maintainer API credential is shipped.
- **Claude suggestions:** your installed Claude CLI, using its configured account/provider and
  selected session context. This may consume your subscription or credits.
- **Ollama suggestions:** the configured endpoint, `http://localhost:11434` by default. A remote
  endpoint receives selected context; use an endpoint and transport you trust.
- **Session delivery:** local messaging sockets, your Codex CLI, editor companion or supported
  application automation. The receiving agent can subsequently use its own network services.

## Editor companion

Each supported editor window binds an HTTP server to `127.0.0.1` on a random port. Requests require
a fresh random 32-hex bearer token, compared with a constant-time check. The token is written under
`~/.lookout/companion` with mode `0600`, in a private directory, and removed on clean deactivation.
Request sizes are bounded. Binding loopback avoids an ordinary remotely reachable listener; it
is not a defense against another program already running as your user or an administrator.

The endpoints list terminals, focus them and send text. **Sending text with a newline can execute
commands in a terminal.** Treat access to the companion token as privileged access. Do not expose
its port through a proxy, share its descriptor file or copy it into a bug report.

## Tokens and local files

Claude messaging credentials are kept in separate mode-`0600` session token files in a mode-`0700`
directory, not embedded in rendered session state. The reporter never dumps its inherited
process environment. Credential-bearing diagnostics must be redacted. Session/request identifiers
are validated as bounded filename components before building paths.

These protections isolate ordinary other-user access, not programs already running as you. Local
malware, an administrator or an account compromise can read or modify user-owned state. Beacon
is not a sandbox for untrusted software, and does not make a shared user account private.

## Actions and timeouts

Allow/Deny decisions require an explicit user action. Permission hooks can wait for an answer for
a bounded interval (45 seconds by default, configurable up to 110); timeout returns control to the
agent's normal prompt. Session locks are also bounded. Internal reporter failures return exit code
zero so an error does not itself reject the agent's operation. The reporter is therefore not a
security enforcement boundary.

Sending a reply, renaming a session, jumping between apps or confirming a permission can affect
running work. Some client interfaces are undocumented; when delivery fails, use Copy & go and
verify in the destination. Suggestions are drafts, not automatic decisions.

Sentinel does not automatically stop processes or delete files. Stop requires confirmation and
checks the process ID, executable path, owner and start time, including before force escalation.
It protects system paths, critical names, PID 1, itself and other users' processes. Force stopping
can still lose unsaved work; identity checks reduce but cannot eliminate OS timing races.
Chrome helpers may serve multiple tabs. See [the action guide](docs/SENTINEL.md).

## Public contributions and builds

Never commit credentials, live state, signing keys, transcripts, account exports or private
screenshots. Use fictional fixtures. Review both the proposed files and their Git history: removing
content from the latest version does not erase earlier commits, forks, caches or downloaded copies.
GitHub secret scanning and push protection supplement manual review; they do not recognize every
secret or every kind of private information.

CI runs with read-only repository permissions, does not require provider credentials, and should
use disposable test processes. The application and companion include the MIT license. Release
signing is separate from a source build; an ad-hoc signature is not Apple notarization.

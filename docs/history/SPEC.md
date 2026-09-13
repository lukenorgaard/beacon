# Beacon architecture reference

This public technical reference replaces early development notes. The section numbers remain
so existing source comments have a useful destination. For current user behavior, start with
[the README](../../README.md), [installation](../INSTALL.md) and [Sentinel](../SENTINEL.md).

## 1. Purpose

Monitor coding-agent sessions across macOS applications, surface attention requests and provide
explicit actions. The app is a local user process, not a hosted service or remote-control agent.

## 2. Integrations

Claude and Codex hooks write small state files. Process discovery supplements reporting.
Claude usage comes from its HTTPS usage endpoint with the user's Keychain credential; Codex
usage comes from local session data. Client interfaces and payloads can change between versions.

## 3. Reporter contract

The Python entry point stays at `hooks/lookout-report.py`. Its package lives beside it.
Validate identifiers before building file paths. Use atomic writes, private directories and
bounded locks. Internal failures should return control to the agent without dumping payloads.

## 4. Session state

Versioned JSON records describe state, timestamps, project, host, model, context and usage.
Optional fields must remain compatible with older records. See [the schema](../REPORTER.md).
State can include private text; it must not be treated as safe to publish.

## 5. Native app

SwiftUI views use AppKit window and menu-bar integration. AppState connects stores, requests,
usage, notifications and settings. Expensive sampling and subprocess work stay off the main thread.

## 6. Verification

Swift tests cover models, integration boundaries and headless rendering. Reporter tests use
isolated homes and agent settings. Companion tests use disposable local servers and fake editors.
Never use real credentials, conversations or user processes as test fixtures.

## 7. Packaging

Build universal macOS binaries, bundle hooks, installer helpers, companion and MIT license.
Source archives include a checksum manifest. Build output, signing credentials and local session
notes are excluded from source publication.

## 8. Manual reporting

Other agents may report states through the CLI. Agent names and session IDs are bounded filename
components. The reporter is not a public HTTP service; it runs under the invoking user's account.

## 9. Session identity and jumping

Resolve a session's host, terminal and workspace where supported. Fall back to app activation
or Copy & go when precise selection is unavailable. Do not infer that activation confirms delivery.

## 10. Setup

Preview and merge hook configuration. Install only the requested integrations, retain backups
and support removal. Existing sessions may need restarting after hook changes.

## 11. Attention requests

Permission and question requests are expiring files associated with a session. Answers come from
an explicit user action. Permission hooks may wait for a bounded interval before falling back
to their usual prompt. Sending text may affect a terminal or agent session.

## 12. Workspaces and sub-agents

Keep parent-session identity while displaying live sub-agents separately. Workspace matching
may follow Git worktree relationships. Examples and screenshots must use fictional project names.

## 13. Suggestions

Heuristic suggestions are local. Claude suggestions use the installed CLI and its user account;
Ollama sends selected context to the configured endpoint, which may be remote. Model output is
a draft to review, never an automatic permission decision.

## 14. Layout

Shared metrics determine panel, row and control sizes across scales. Warnings and long lists
scroll within a height cap. Render tests check actual views rather than duplicated mock layouts.

## 15. Naming and messaging

Local display names are stored separately. Optional session renaming and reply delivery require
user action. Messaging credentials are separate from rendered session JSON, with private file
permissions. Never log credential values or full inherited environments.

## 16. Editor companion

Each editor window binds an authenticated server to loopback with a fresh random token stored
in a private local file. The API lists/focuses terminals and sends input. Sending terminal input
can execute commands; possession of the token is privileged access, not just a UI convenience.

## 17. History, costs and contributions

Session transition history stays local. Cost estimates derive from usage and editable pricing.
Global shortcuts and presets perform only the actions the user chooses. Public changes arrive as
pull requests, retain contributor attribution and require maintainer review.

## 18. Sentinel

Native sampling produces CPU, memory, swap, disk, thermal and process observations. Rules require
sustained conditions and produce explanations. Resource charts retain only bounded totals in memory.
Confirmed process stops verify identity and protect system processes. See [Sentinel](../SENTINEL.md).

## 19. Context

Context indicators use the freshest available transcript measurements and reported model windows.
User-editable fallback windows and thresholds remain estimates. Compaction invalidates older
measurements rather than pretending the previous context size is still current.

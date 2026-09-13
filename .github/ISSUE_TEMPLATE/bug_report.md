---
name: Bug report
about: Something in Beacon isn't working right
title: ""
labels: bug
assignees: ""
---

**What happened?**
A clear description of what went wrong, and what you expected instead.

**Steps to reproduce**
1. …
2. …

**Environment**
- macOS version:
- How you installed Beacon: pkg / built from source
- Beacon version (Settings, or `Contents/Info.plist` `CFBundleShortVersionString` of the app):
- Host app the session was running in (Claude desktop app / Cursor / Devin / Terminal.app / iTerm2 / other):
- Agent (Claude Code / Codex / other):

**Relevant logs**

If you can, attach the relevant lines from `~/.lookout/`:
- `jump.log` — for a jump/focus problem
- `send.log` — for a Send / attention-card problem
- `reporter.log` — for a missing or stuck session
- `answers.log` — for a rename or Allow/Deny problem

**Please double-check before pasting: none of these files should ever contain a token, but they
can contain your project paths, prompt text, or command text. Skim what you're about to paste and
redact anything you don't want public — if in doubt, leave it out and describe it in words
instead.**

```
paste the relevant lines here
```

**Anything else?**
Screenshots, or anything else that might help.

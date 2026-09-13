# Beacon 1.4 — source handoff, 10 September 2026

This folder contains the complete editable Swift app, Python reporter, editor companion,
tests and build scripts. It is the 1.4 source with the 10 September review fixes and file
cleanup. The installed app and previously distributed 1.4 installers are separate artifacts.

## Build on your Mac

Requirements: macOS 14+, Xcode or its command-line tools with Swift 5.9+, Python 3.9+.
Node.js is needed only for the companion's tests; the companion has no npm dependencies.

From this folder:

```sh
swift build
swift test
bash tests/test_reporter.sh
node --test companion/test
python3 scripts/check-code-size.py
bash scripts/build.sh
```

The last command builds `build/Beacon.app` for Apple Silicon and Intel. It does not install
or launch it. Open `Package.swift` in Xcode to edit the SwiftUI/AppKit source.
To install your own build deliberately, use `bash scripts/build.sh --install`.

## Carry your UI changes forward

Start with `Sources/Lookout/`. `docs/SOURCE-MAP.md` maps the old large files to their new
locations. In particular, the session row is now `SessionRow.swift`; settings pages,
attention-card helpers, session formatting and jump behavior have their own files.
Swift extensions retain the existing type names. This cleanup adds no intended UI changes.

Bring your v1 changes across feature by feature, then rerun the tests. Your modified v1
source was not available during this handoff, so those UI changes have not been merged here.

## Review fixes

- Both usage-failure handlers now pass `lookout_home` to `log_error`. A failed parse no
  longer prevents `Stop` from saving its state or `SessionEnd` from cleaning up. The log
  contains the exception type, never the offending transcript value.
- Current Codex **does** support `Interrupt`. The old comments were stale. Its timeout
  is now 3 seconds, within the documented 1–3 second range. See the
  [official hook reference](https://learn.chatgpt.com/docs/hooks#interrupt).
- Code and test files are split by responsibility and checked against a 500-line maximum,
  including comments and blank lines. CI runs the same check.
- Keep `hooks/lookout_reporter/` beside `hooks/lookout-report.py`: the entry point now
  imports that package. The app build bundles both automatically; imports do not write
  bytecode caches into the signed bundle.

Older Codex clients may omit `Interrupt`. Check `/hooks` on the target Mac and review/trust
new or changed hooks as appropriate for that client.

## Verification on 10 September 2026

- Fresh archive: universal Apple Silicon/Intel app build passed.
- Swift: 832 tests executed, 1 opt-in subscription test skipped, 0 failures.
- Reporter/installer: 190 checks passed, including the new failure-recovery tests.
- Editor companion: 10 tests passed.
- File-size check: every code/config file is at most 500 lines (largest: 499).
- The two new failure-recovery tests fail against the original 1.4 reporter and pass here.

Native UI render/layout checks are included in the Swift suite. Installation, permissions
and your custom v1 UI merge still need to be checked on your Mac.

## Package integrity

`SHA256SUMS` lists every source file in this archive. Verify after extraction with:

```sh
shasum -a 256 -c SHA256SUMS
```

The source archive excludes build products, caches, git history, session logs and local
checkpoints. To create a new source archive after editing:

```sh
python3 scripts/package-source.py
```

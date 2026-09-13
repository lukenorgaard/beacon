# Install and upgrade Beacon

## Build and open

On macOS 14+, install Xcode or its command-line tools and Python 3. Clone the repository and run:

```sh
CODE_SIGN_IDENTITY=- bash scripts/build.sh
```

The script builds both supported Mac architectures, bundles Python hooks and the editor companion,
and ad-hoc signs `build/Beacon.app`. Copy that app into Applications and open it. Running
`bash scripts/build.sh --install` explicitly installs and launches it; ordinary builds do neither.

An ad-hoc signature is not Apple notarization. If macOS blocks a downloaded build, first verify its
origin and any published checksum. Apple's [safe opening instructions](https://support.apple.com/en-us/102445)
explain the per-app **System Settings → Privacy & Security → Open Anyway** option when appropriate.
Do not disable Gatekeeper globally.

## Connect your agents

1. Open Beacon's setup screen and choose the hooks you want installed. The installer merges the
   relevant Claude/Codex configuration; review the preview and keep its backup.
2. Restart existing agent sessions so they pick up new hooks. If Codex asks you to trust a hook,
   review it in that client's `/hooks` interface.
3. Install **Beacon Companion** for the supported editor windows where you want precise terminal
   focus and reply delivery. Restart or reload those editor windows after installation.
4. Run a short test task, confirm it appears in Sessions, then use Jump and a harmless reply to
   verify your specific agent/editor version. Copy & go remains available when delivery fails.

Manual hook preview from the checkout:

```sh
python3 scripts/install-hooks.py --dry-run
```

For agents without hooks, use the [manual reporter](REPORTER.md).

## Permissions

- **Notifications:** optional attention and system-warning banners.
- **Accessibility / Automation:** used by supported jump and desktop/editor integrations. Grant
  only when you want those features; macOS may ask separately for each target application.
- **Keychain:** needed for Claude usage limits. The credential belongs to your own Claude login.
  Denying access prevents that usage fetch; it is not a maintainer credential.
- **Suggestions:** heuristics run without a model provider. Claude uses your installed CLI and
  account; Ollama uses the endpoint you configure. Context may leave the Mac with either remote option.

## Upgrade from Lookout

Before quitting Lookout, turn off **Start at login** in that app and note your preferred settings.
Uninstall the old companion through each editor's extension manager, then quit Lookout.

Beacon now has its own app identity (`io.github.lukenorgaard.beacon`) and companion publisher
(`lukenorgaard.lookout-companion`). Existing session/history files under `~/.lookout` are reused,
but app preferences start fresh. Reapply your settings and grant macOS permissions as needed.
Enable **Start at login** in Beacon if wanted; disabling it in the old app first avoids duplicate
login agents.

Reinstall hooks from Beacon in Applications so configuration points to `Beacon.app`. Install
Beacon Companion and reload the editor. After verifying your sessions work, remove the old app.

## Packaging

`python3 scripts/package-source.py` creates `build/Beacon-1.4-source.zip` and its SHA-256 file.
It uses an explicit Git-tracked file inventory and includes an internal checksum manifest.

`CODE_SIGN_IDENTITY=- bash scripts/package.sh` can produce a local PKG and DMG. Review signing
options in that script before distributing: installer signing/notarization may use separately
configured credentials. This is not needed to build or use Beacon locally.

## Remove

Quit Beacon. Use the hook installer's `--remove` option to remove only Beacon's hook entries,
and uninstall Beacon Companion through your editor's extension manager. Turn off Start at login
before removing Beacon.app from Applications. The optional local state under `~/.lookout` can
then be removed after saving anything you want to keep; it includes history, names and preferences.

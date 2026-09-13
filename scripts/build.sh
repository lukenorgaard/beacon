#!/bin/bash
# Builds Beacon.app. Pass --install to also place it in /Applications and launch it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Beacon.app"
BUNDLE_ID="io.github.lukenorgaard.beacon"
VERSION="1.4"

cd "$ROOT"

echo "==> Compiling (release)"
# Universal (Apple Silicon + Intel) so the pkg runs on any Mac the owner hands it to.
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS \
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/Beacon" \
    -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/Beacon"

BINARY="$(swift build -c release $ARCHS --show-bin-path)/Beacon"
[ -f "$BINARY" ] || { echo "Build produced no binary at $BINARY"; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$BINARY" "$APP/Contents/MacOS/Beacon"
# Debug object paths can identify the developer's home folder. Keep them out of distributions.
xcrun strip -S "$APP/Contents/MacOS/Beacon"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Beacon</string>
    <key>CFBundleDisplayName</key><string>Beacon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Beacon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSUserNotificationAlertStyle</key><string>alert</string>
    <key>NSAppleEventsUsageDescription</key><string>Beacon uses AppleScript to bring the terminal window hosting a session to the front.</string>
    <key>NSHumanReadableCopyright</key><string>Local build</string>
</dict>
</plist>
PLIST

# SPEC 10.1: the reporter side ships inside the bundle, mirroring the repo layout so
# install-hooks.py's own REPO_ROOT logic (parent of its scripts/ dir) resolves to Resources and
# the hook commands it writes point at Resources/hooks/lookout-report.py. Copied BEFORE codesign,
# or the signature would not cover them.
echo "==> Bundling reporter and installer"
mkdir -p "$APP/Contents/Resources/hooks" "$APP/Contents/Resources/scripts"
mkdir -p "$APP/Contents/Resources/hooks/lookout_reporter"
cp "$ROOT/hooks/lookout_reporter/"*.py "$APP/Contents/Resources/hooks/lookout_reporter/"
cp "$ROOT/hooks/lookout-report.py"   "$APP/Contents/Resources/hooks/lookout-report.py"
cp "$ROOT/hooks/claude-hooks.json"   "$APP/Contents/Resources/hooks/claude-hooks.json"
cp "$ROOT/hooks/codex-hooks.json"    "$APP/Contents/Resources/hooks/codex-hooks.json"
cp "$ROOT/scripts/install-hooks.py"  "$APP/Contents/Resources/scripts/install-hooks.py"
chmod +x "$APP/Contents/Resources/hooks/lookout-report.py" \
         "$APP/Contents/Resources/scripts/install-hooks.py"

# SPEC 16.3: the editor companion ships alongside them — the vsix plus the installer the setup
# page runs. Built here when it is missing, and copied BEFORE codesign for the same reason.
echo "==> Bundling editor companion"
python3 "$ROOT/scripts/build-companion.py"
mkdir -p "$APP/Contents/Resources/companion"
cp "$ROOT/build/lookout-companion.vsix"  "$APP/Contents/Resources/companion/lookout-companion.vsix"
cp "$ROOT/scripts/install-companion.sh"  "$APP/Contents/Resources/companion/install-companion.sh"
chmod +x "$APP/Contents/Resources/companion/install-companion.sh"

# A stable signing identity keeps macOS permission grants (Accessibility, the keychain item)
# across rebuilds. Ad-hoc signatures are keyed by cdhash, which changes with every build, so
# every reinstall silently invalidated the grants. Prefer an Apple Development identity if one
# exists in the keychain; fall back to ad-hoc.
# `|| true`: under `set -o pipefail` a grep that matches nothing fails the whole pipeline, which
# would abort the build on any Mac without an Apple Development certificate — the common case.
if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODE_SIGN_IDENTITY"
else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"' || true)"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    echo "==> Signing with $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "==> Signing (ad-hoc)"
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP" && echo "    signature ok"
codesign -dr - "$APP" 2>&1 | grep designated | sed 's/^/    /'

echo "==> Built $APP"

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to /Applications"
    # Quit any running copy first, or the replaced binary keeps running.
    pkill -f "/Applications/Beacon.app/Contents/MacOS/Beacon" 2>/dev/null || true
    pkill -f "/Applications/Lookout.app/Contents/MacOS/Lookout" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/Beacon.app"
    cp -R "$APP" "/Applications/Beacon.app"
    open "/Applications/Beacon.app"
    echo "==> Running. Look for the dot in your menu bar."
fi

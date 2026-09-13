#!/bin/bash
# Builds the one file the owner can send: build/Beacon-<version>.pkg (SPEC §10.3), plus a DMG for
# people who prefer drag-and-drop. Non-interactive — signing and notarisation happen only when
# the credentials are already there, and their absence is a printed note, not a failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Beacon.app"
BUNDLE_ID="io.github.lukenorgaard.beacon"

# One source of truth for the version: build.sh, which also stamps it into Info.plist.
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/scripts/build.sh" | head -1)"
[ -n "$VERSION" ] || { echo "Could not read VERSION from scripts/build.sh"; exit 1; }

COMPONENT="$BUILD/Beacon-component.pkg"
DIST="$BUILD/Beacon-distribution.xml"
PKG="$BUILD/Beacon-$VERSION.pkg"
DMG="$BUILD/Beacon-$VERSION.dmg"
DMG_STAGE="$BUILD/dmg"

cd "$ROOT"
bash "$ROOT/scripts/build.sh"

[ -d "$APP" ] || { echo "No app at $APP"; exit 1; }
for required in hooks/lookout-report.py hooks/claude-hooks.json hooks/codex-hooks.json scripts/install-hooks.py; do
    [ -f "$APP/Contents/Resources/$required" ] || {
        echo "Bundle is missing Contents/Resources/$required"; exit 1;
    }
done

echo "==> pkgbuild (component)"
rm -f "$COMPONENT" "$PKG"
pkgbuild \
    --component "$APP" \
    --install-location /Applications \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --scripts "$ROOT/scripts/pkg" \
    "$COMPONENT" >/dev/null

# A distribution wrapper is what gives the Installer window a title and a minimum-OS check;
# a bare component package shows the raw identifier instead.
cat > "$DIST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Beacon $VERSION</title>
    <organization>Beacon</organization>
    <options customize="never" require-scripts="false" rootVolumeOnly="true" hostArchitectures="arm64,x86_64"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="$BUNDLE_ID"/>
    </choices-outline>
    <choice id="$BUNDLE_ID" title="Beacon" visible="false">
        <pkg-ref id="$BUNDLE_ID"/>
    </choice>
    <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">$(basename "$COMPONENT")</pkg-ref>
</installer-gui-script>
XML

# `security find-identity -p codesigning` filters installer identities out, so ask for all of them.
# `|| true`: with `set -o pipefail` a grep that matches nothing would otherwise abort the script,
# and "no Developer ID" is the normal case here, not an error.
INSTALLER_IDENTITY="$(security find-identity -v 2>/dev/null \
    | grep -oE '"Developer ID Installer: [^"]+"' | head -1 | tr -d '"' || true)"

echo "==> productbuild (distribution)"
if [ -n "$INSTALLER_IDENTITY" ]; then
    echo "    signing with $INSTALLER_IDENTITY"
    productbuild --distribution "$DIST" --package-path "$BUILD" \
        --sign "$INSTALLER_IDENTITY" "$PKG" >/dev/null
else
    productbuild --distribution "$DIST" --package-path "$BUILD" "$PKG" >/dev/null
fi

NOTARISED="no"
if [ -n "$INSTALLER_IDENTITY" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Notarising with keychain profile $NOTARY_PROFILE"
    if xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait \
        && xcrun stapler staple "$PKG"; then
        NOTARISED="yes"
    else
        echo "    notarisation failed — shipping the signed but unnotarised pkg"
    fi
fi

# The one file that explains the first launch. Without a Developer ID + notarisation, anything
# downloaded carries a quarantine flag and macOS refuses to open it — and since macOS 15 the old
# "right-click → Open" no longer bypasses that. The Terminal line drops the flag; the settings
# route is the no-Terminal alternative.
INSTALL_TXT="$BUILD/INSTALL.txt"
cat > "$INSTALL_TXT" <<TXT
BEACON $VERSION — INSTALL / INSTALLATION

ENGLISH
1. Put Beacon-$VERSION.pkg in your Downloads folder.
2. Open Terminal (Spotlight: "Terminal"), paste this line and press Return:
   xattr -d com.apple.quarantine ~/Downloads/Beacon-$VERSION.pkg; open ~/Downloads/Beacon-$VERSION.pkg
   (It removes the download flag macOS puts on unsigned files, then opens the installer.)
3. Click through the installer. Beacon starts by itself — look for the dot in the menu bar.
4. In the Setup window: press Install next to the hooks, then allow Accessibility and
   Notifications when macOS asks. Done.
No Terminal? System Settings → Privacy & Security → scroll down → "Open Anyway" after the
first refused attempt, then open the pkg again.

DANSK
1. Læg Beacon-$VERSION.pkg i din Downloads-mappe.
2. Åbn Terminal (Spotlight: "Terminal"), indsæt denne linje og tryk Enter:
   xattr -d com.apple.quarantine ~/Downloads/Beacon-$VERSION.pkg; open ~/Downloads/Beacon-$VERSION.pkg
   (Den fjerner det download-flag, macOS sætter på usignerede filer, og åbner installeren.)
3. Klik dig igennem installeren. Beacon starter selv — kig efter prikken i menulinjen.
4. I Setup-vinduet: tryk Install ud for hooks, og sig ja til Accessibility og Notifications,
   når macOS spørger. Færdig.
Ingen Terminal? Systemindstillinger → Anonymitet & sikkerhed → rul ned → "Åbn alligevel" efter
det første afviste forsøg, og åbn så pkg'en igen.
TXT

echo "==> hdiutil (dmg)"
rm -rf "$DMG_STAGE"; rm -f "$DMG"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/Beacon.app"
cp "$INSTALL_TXT" "$DMG_STAGE/INSTALL.txt"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Beacon $VERSION" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO -quiet "$DMG"
rm -rf "$DMG_STAGE"

rm -f "$COMPONENT" "$DIST"

size() { du -h "$1" | cut -f1 | tr -d ' '; }

echo
echo "==> Done"
printf '    %s  (%s)\n' "$PKG" "$(size "$PKG")"
printf '    %s  (%s)\n' "$DMG" "$(size "$DMG")"
printf '    %s\n' "$INSTALL_TXT"
echo
if [ -z "$INSTALLER_IDENTITY" ]; then
    cat <<'NOTE'
    Unsigned: no "Developer ID Installer" identity in the keychain, so Gatekeeper refuses the
    downloaded pkg and app on another Mac (and since macOS 15 right-click → Open no longer
    helps). Send INSTALL.txt with the pkg — its one Terminal line removes the quarantine flag.
    Set NOTARY_PROFILE (see `xcrun notarytool store-credentials`) once a Developer ID exists to
    sign and notarise, after which a plain double-click works.
NOTE
elif [ "$NOTARISED" != "yes" ]; then
    echo "    Signed but not notarised (set NOTARY_PROFILE to notarise). Another Mac still"
    echo "    needs the INSTALL.txt line or Open Anyway on first launch."
else
    echo "    Signed and notarised — a plain double-click works."
fi

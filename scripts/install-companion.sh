#!/bin/bash
# Installs build/lookout-companion.vsix into Cursor, Devin and/or VS Code with
# each app's own bundled CLI. See docs/history/SPEC.md section 16.2.
#
#   scripts/install-companion.sh [cursor|devin|vscode|all] [--dry-run]
#
# Apps that are not installed are skipped without failing; the exit status is
# non-zero only when a requested app's CLI ran and failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
DEVIN_CLI="/Applications/Devin.app/Contents/Resources/app/bin/devin-desktop"
VSCODE_CLI="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"

usage() {
    cat <<USAGE
usage: $(basename "$0") [cursor|devin|vscode|all] [--dry-run]

  cursor    Cursor.app
  devin     Devin.app (Windsurf build)
  vscode    Visual Studio Code.app
  all       every one of those that is installed (default)

  --dry-run print the commands instead of running them
USAGE
}

TARGET=""
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        cursor|devin|vscode|all)
            TARGET="$arg"
            ;;
        --dry-run|-n)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done
[ -n "$TARGET" ] || TARGET="all"

# Repository checkout, or Lookout.app/Contents/Resources/companion/ where
# build.sh puts the vsix next to this script.
VSIX=""
for candidate in "$SCRIPT_DIR/../build/lookout-companion.vsix" "$SCRIPT_DIR/../companion/lookout-companion.vsix" "$SCRIPT_DIR/lookout-companion.vsix"; do
    if [ -f "$candidate" ]; then
        VSIX="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
        break
    fi
done

if [ -z "$VSIX" ]; then
    echo "No lookout-companion.vsix found next to $SCRIPT_DIR." >&2
    echo "Build it first: python3 scripts/build-companion.py" >&2
    [ "$DRY_RUN" -eq 1 ] || exit 1
    VSIX="$SCRIPT_DIR/../build/lookout-companion.vsix"
fi

cli_for() {
    case "$1" in
        cursor) echo "$CURSOR_CLI" ;;
        devin)  echo "$DEVIN_CLI" ;;
        vscode) echo "$VSCODE_CLI" ;;
    esac
}

label_for() {
    case "$1" in
        cursor) echo "Cursor" ;;
        devin)  echo "Devin" ;;
        vscode) echo "VS Code" ;;
    esac
}

if [ "$TARGET" = "all" ]; then
    APPS="cursor devin vscode"
else
    APPS="$TARGET"
fi

echo "==> vsix: $VSIX"

status=0
attempted=0
for app in $APPS; do
    cli="$(cli_for "$app")"
    label="$(label_for "$app")"

    if [ ! -x "$cli" ]; then
        echo "--> $label: not installed ($cli) — skipped"
        continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "--> $label: would run"
        echo "    \"$cli\" --install-extension \"$VSIX\" --force"
        attempted=1
        continue
    fi

    echo "--> $label: installing"
    if "$cli" --install-extension "$VSIX" --force; then
        echo "    $label: ok"
    else
        code=$?
        echo "    $label: FAILED (exit $code)" >&2
        status=1
    fi
    attempted=1
done

if [ "$attempted" -eq 0 ]; then
    echo "==> nothing to do — none of the requested apps is installed"
    exit 0
fi

echo "==> Reload the window (⌘⇧P → Reload Window) or restart the app to activate"
exit "$status"

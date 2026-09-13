#!/usr/bin/env python3
"""Merge Beacon's hook fragments (hooks/claude-hooks.json, hooks/codex-hooks.json)
into ~/.claude/settings.json and ~/.codex/hooks.json.

Idempotent: an entry is "ours" when its command string contains
"hooks/lookout-report.py", regardless of the checkout folder name. Re-running replaces ours in place and
never duplicates. Everything else in the target files is left untouched.

python3 stdlib only. See docs/history/SPEC.md section 3, point 3.
"""
import argparse
import copy
import difflib
import json
import re
import os
import shutil
import sys
from datetime import datetime

# Folder-name independent: the zip may be unpacked as "Beacon-main" or anything else.
MARKER = "hooks/lookout-report.py"
OSASCRIPT_PREFIX = "osascript -e 'display notification"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
HOOKS_DIR = os.path.join(REPO_ROOT, "hooks")

DEFAULT_CLAUDE_SETTINGS = os.path.expanduser("~/.claude/settings.json")
DEFAULT_CODEX_HOOKS = os.path.expanduser("~/.codex/hooks.json")


REPORTER_PATH = os.path.join(HOOKS_DIR, "lookout-report.py")
_REPORTER_RE = re.compile(r"\S*hooks/lookout-report\.py")


def load_fragment(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("hooks"), dict):
        raise SystemExit("error: %s does not have the expected {\"hooks\": {...}} shape" % path)
    # The fragments carry whatever absolute path they were written with; point every command at
    # the reporter inside THIS checkout so the zip works wherever it is unpacked.
    for entries in data["hooks"].values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                cmd = hook.get("command")
                if isinstance(cmd, str) and MARKER in cmd:
                    hook["command"] = _REPORTER_RE.sub(REPORTER_PATH, cmd, count=1)
    return data


def read_target(path):
    """Returns (data_or_None, raw_text). data is None if the file does not
    exist. Raises SystemExit if the file exists but is not valid JSON."""
    if not os.path.exists(path):
        return None, ""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if not text.strip():
        return {}, text
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise SystemExit("error: %s is not valid JSON: %s" % (path, e))
    if not isinstance(data, dict):
        raise SystemExit("error: %s does not contain a JSON object at the top level" % path)
    return data, text


def is_ours(command):
    return isinstance(command, str) and MARKER in command


def is_osascript_notification(command):
    return isinstance(command, str) and command.strip().startswith(OSASCRIPT_PREFIX)


def merge(target, fragment, remove, replace_osascript):
    """Returns a new top-level dict with 'hooks' merged. Never mutates
    target or fragment in place."""
    target = dict(target) if target else {}
    existing_hooks = dict(target.get("hooks", {}))
    frag_hooks = fragment.get("hooks", {})

    ordered_event_names = list(existing_hooks.keys())
    for en in frag_hooks.keys():
        if en not in existing_hooks:
            ordered_event_names.append(en)

    new_hooks = {}
    for event_name in ordered_event_names:
        existing_groups = existing_hooks.get(event_name, [])
        new_groups = []
        for g in existing_groups:
            g_hooks = g.get("hooks", []) if isinstance(g, dict) else []
            kept = []
            for h in g_hooks:
                cmd = h.get("command", "") if isinstance(h, dict) else ""
                if is_ours(cmd):
                    continue  # ours: always stripped here, re-added below unless --remove
                if replace_osascript and event_name == "Notification" and is_osascript_notification(cmd):
                    continue
                kept.append(h)
            if kept:
                g2 = dict(g)
                g2["hooks"] = kept
                new_groups.append(g2)
            # else: group becomes empty (was entirely ours / entirely the
            # removed osascript hook) -> drop the whole group object.
        if not remove:
            for g in frag_hooks.get(event_name, []):
                new_groups.append(copy.deepcopy(g))
        if new_groups:
            new_hooks[event_name] = new_groups
        # else: leave event_name out of new_hooks entirely.

    target["hooks"] = new_hooks
    return target


def count_ours(data):
    n = 0
    for groups in data.get("hooks", {}).values():
        for g in groups:
            for h in g.get("hooks", []):
                if is_ours(h.get("command", "")):
                    n += 1
    return n


def backup_file(path):
    if not os.path.exists(path):
        return None
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = "%s.bak-%s" % (path, ts)
    shutil.copy2(path, backup_path)
    return backup_path


def process_file(path, fragment, args, label):
    existing, old_text = read_target(path)
    merged = merge(existing, fragment, args.remove, args.replace_osascript)

    # ensure_ascii=False: preserve non-ASCII characters (e.g. Danish text,
    # em-dashes) as-is rather than escaping them to \uXXXX, which would
    # otherwise turn every such character elsewhere in the file into diff
    # noise unrelated to the actual hook changes.
    new_text = json.dumps(merged, indent=2, ensure_ascii=False) + "\n"
    # Validate the result actually parses as JSON before it is ever written.
    json.loads(new_text)

    if old_text == new_text:
        print("%s: no changes needed (%s)" % (label, path))
        return

    if args.dry_run:
        old_lines = old_text.splitlines(keepends=True) if old_text else []
        new_lines = new_text.splitlines(keepends=True)
        diff = list(
            difflib.unified_diff(
                old_lines, new_lines,
                fromfile=path if old_text else "/dev/null",
                tofile=path,
                lineterm="",
            )
        )
        print("--- dry-run diff for %s ---" % path)
        if diff:
            for line in diff:
                print(line.rstrip("\n"))
        else:
            print("(no textual diff)")
        return

    backup_path = backup_file(path)
    if backup_path:
        print("%s: backed up to %s" % (label, backup_path))

    dirpath = os.path.dirname(path)
    if dirpath and not os.path.isdir(dirpath):
        os.makedirs(dirpath, exist_ok=True)

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
    print("%s: updated %s (%d Beacon hook entries)" % (label, path, count_ours(merged)))


def main():
    parser = argparse.ArgumentParser(
        description="Merge/remove Beacon's hook fragments in ~/.claude/settings.json and ~/.codex/hooks.json."
    )
    parser.add_argument("--dry-run", action="store_true", help="print a unified diff per file, write nothing")
    parser.add_argument("--remove", action="store_true", help="strip Beacon's hook entries")
    parser.add_argument(
        "--replace-osascript",
        action="store_true",
        help="also remove the existing Notification hook whose command starts with osascript -e 'display notification",
    )
    parser.add_argument("--claude-settings", default=DEFAULT_CLAUDE_SETTINGS, help="override path for testing")
    parser.add_argument("--codex-hooks", default=DEFAULT_CODEX_HOOKS, help="override path for testing")
    args = parser.parse_args()

    claude_fragment = load_fragment(os.path.join(HOOKS_DIR, "claude-hooks.json"))
    codex_fragment = load_fragment(os.path.join(HOOKS_DIR, "codex-hooks.json"))

    process_file(args.claude_settings, claude_fragment, args, "claude")
    process_file(args.codex_hooks, codex_fragment, args, "codex")


if __name__ == "__main__":
    main()

# Reporter regression cases: installer. Sourced by ../test_reporter.sh.

# ---------------------------------------------------------------------------
# Case (h): install-hooks.py against a realistic pre-existing settings.json.
# ---------------------------------------------------------------------------
run_case_h() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local settings="$home/settings.json"
  local codexhooks="$home/hooks.json"

  cat > "$settings" <<'JSONEOF'
{
  "env": {
    "SOME_VAR": "1"
  },
  "permissions": {
    "allow": ["Read", "Edit", "Bash(*)"],
    "defaultMode": "auto"
  },
  "model": "claude-fable-5-1",
  "hooks": {
    "PreCompact": [
      {
        "hooks": [
          {"type": "command", "command": "~/.claude/hooks/pre-compact-checkpoint.sh"}
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {"type": "command", "command": "osascript -e 'display notification \"Claude needs your attention\" with title \"Claude Code\"'"}
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {"type": "command", "command": "npx prettier --write \"$FILE\""}
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {"type": "command", "command": "echo blocking protected files"}
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "echo blocking deploy commands"}
        ]
      }
    ]
  },
  "theme": "dark"
}
JSONEOF
  cp "$settings" "$settings.orig"
  rm -f "$codexhooks"

  # 1. --dry-run must not touch anything on disk.
  local dryout
  dryout=$(python3 "$INSTALLER" --claude-settings "$settings" --codex-hooks "$codexhooks" --dry-run 2>&1)
  DRY_RUN_DIFF_FOR_REPORT="$dryout"

  if [[ -f "$codexhooks" ]]; then
    fail "case h: --dry-run must not create the codex hooks file"
  else
    pass "case h: --dry-run does not create the missing codex hooks file"
  fi
  if diff -q "$settings.orig" "$settings" > /dev/null; then
    pass "case h: --dry-run leaves settings.json byte-for-byte untouched"
  else
    fail "case h: --dry-run modified settings.json"
  fi
  if echo "$dryout" | grep -q "lookout-report.py"; then
    pass "case h: --dry-run diff mentions lookout-report.py"
  else
    fail "case h: --dry-run diff does not mention lookout-report.py"
  fi

  # 2. Real run: creates the missing codex file, updates settings.json, backs it up.
  python3 "$INSTALLER" --claude-settings "$settings" --codex-hooks "$codexhooks" > /dev/null
  assert_file_present "$codexhooks" "case h: real run creates the missing codex hooks file"

  local backups
  backups=$(find "$home" -maxdepth 1 -name 'settings.json.bak-*' | wc -l | tr -d ' ')
  if [[ "$backups" -ge 1 ]]; then
    pass "case h: real run wrote a timestamped backup of settings.json"
  else
    fail "case h: no backup of settings.json was written"
  fi

  # 3. Existing (non-Lookout) entries and other top-level keys untouched.
  if python3 - "$settings" <<'PYEOF' > /dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
h = d["hooks"]
assert any("pre-compact-checkpoint.sh" in x["command"] for g in h.get("PreCompact", []) for x in g["hooks"])
assert any("display notification" in x["command"] for g in h.get("Notification", []) for x in g["hooks"])
assert any("prettier" in x["command"] for g in h.get("PostToolUse", []) for x in g["hooks"])
assert any(g.get("matcher") == "Bash" and "blocking deploy" in g["hooks"][0]["command"] for g in h.get("PreToolUse", []))
assert d.get("theme") == "dark"
assert d.get("model") == "claude-fable-5-1"
assert d.get("permissions", {}).get("allow") == ["Read", "Edit", "Bash(*)"]
PYEOF
  then
    pass "case h: existing non-Lookout hooks and other top-level keys untouched"
  else
    fail "case h: existing entries or other top-level keys were modified"
  fi

  # 4. Ours added exactly once (14 claude entries, 7 codex entries).
  local claude_count codex_count
  claude_count=$(python3 - "$settings" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
n = sum(1 for g in [gg for gs in d["hooks"].values() for gg in gs] for h in g["hooks"] if "hooks/lookout-report.py" in h.get("command", ""))
print(n)
PYEOF
)
  codex_count=$(python3 - "$codexhooks" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
n = sum(1 for g in [gg for gs in d["hooks"].values() for gg in gs] for h in g["hooks"] if "hooks/lookout-report.py" in h.get("command", ""))
print(n)
PYEOF
)
  if [[ "$claude_count" -eq 15 ]]; then
    pass "case h: exactly 15 Lookout hook entries in settings.json"
  else
    fail "case h: expected 15 Lookout entries in settings.json, got $claude_count"
  fi
  if [[ "$codex_count" -eq 10 ]]; then
    pass "case h: exactly 10 Lookout hook entries in hooks.json"
  else
    fail "case h: expected 10 Lookout entries in hooks.json, got $codex_count"
  fi

  # 5. Second --dry-run reports no changes.
  local dryout2
  dryout2=$(python3 "$INSTALLER" --claude-settings "$settings" --codex-hooks "$codexhooks" --dry-run 2>&1)
  if echo "$dryout2" | grep -qi "no changes needed"; then
    pass "case h: second run --dry-run reports no changes"
  else
    fail "case h: second run --dry-run unexpectedly shows a diff"
  fi

  # 6. Second real run does not duplicate entries.
  python3 "$INSTALLER" --claude-settings "$settings" --codex-hooks "$codexhooks" > /dev/null
  claude_count=$(python3 - "$settings" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
n = sum(1 for g in [gg for gs in d["hooks"].values() for gg in gs] for h in g["hooks"] if "hooks/lookout-report.py" in h.get("command", ""))
print(n)
PYEOF
)
  if [[ "$claude_count" -eq 15 ]]; then
    pass "case h: re-running install does not duplicate entries"
  else
    fail "case h: re-running install produced $claude_count entries (expected 15)"
  fi

  # 7. --remove restores original content (structural JSON equality).
  python3 "$INSTALLER" --claude-settings "$settings" --codex-hooks "$codexhooks" --remove > /dev/null
  if python3 - "$settings" "$settings.orig" <<'PYEOF' > /dev/null 2>&1
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
assert a == b, (a, b)
PYEOF
  then
    pass "case h: --remove restores settings.json to its original content"
  else
    fail "case h: --remove did not restore settings.json to its original content"
  fi

  # 8. --replace-osascript removes the owner's old osascript Notification hook
  #    (checked separately, on a fresh copy of the fixture).
  local settings2="$home/settings2.json"
  cp "$settings.orig" "$settings2"
  python3 "$INSTALLER" --claude-settings "$settings2" --codex-hooks "$home/hooks2.json" > /dev/null
  python3 "$INSTALLER" --claude-settings "$settings2" --codex-hooks "$home/hooks2.json" --replace-osascript > /dev/null
  if python3 - "$settings2" <<'PYEOF' > /dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["hooks"].get("Notification", []):
    for h in g["hooks"]:
        assert not h["command"].startswith("osascript -e 'display notification")
PYEOF
  then
    pass "case h: --replace-osascript removes the owner's old osascript Notification hook"
  else
    fail "case h: --replace-osascript did not remove the osascript hook"
  fi
}

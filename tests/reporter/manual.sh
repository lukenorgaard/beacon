# Reporter regression cases: manual. Sourced by ../test_reporter.sh.

# ---------------------------------------------------------------------------
# Case (i): manual mode --set / second --set keeps state_since / --end deletes.
# ---------------------------------------------------------------------------
run_case_i() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="manual-sess-0001"
  local file="$home/sessions/gemini-$sid.json"

  LOOKOUT_HOME="$home" "$REPORTER" --agent gemini --set working --session "$sid" --cwd /tmp/manualproj --title "translate the readme" --detail "running step 2 of 5"
  assert_file_present "$file" "case i: manual --set creates a state file"
  assert_json_field "$file" state working "case i: manual --set working -> state=working"
  assert_json_field "$file" reason manual "case i: manual --set -> reason=manual"
  assert_json_field "$file" title "translate the readme" "case i: manual --set writes title"
  assert_json_field "$file" detail "running step 2 of 5" "case i: manual --set writes detail"
  assert_json_field "$file" project manualproj "case i: manual --set derives project from --cwd"

  local since1
  since1=$(python3 -c "import json; print(json.load(open('$file'))['state_since'])")
  sleep 1.1
  LOOKOUT_HOME="$home" "$REPORTER" --agent gemini --set working --session "$sid"
  local since2
  since2=$(python3 -c "import json; print(json.load(open('$file'))['state_since'])")
  if [[ "$since1" == "$since2" ]]; then
    pass "case i: second manual --set with the same state keeps state_since"
  else
    fail "case i: state_since changed on a same-state --set ($since1 -> $since2)"
  fi

  # a --set with a *different* state should still bump state_since.
  sleep 1.1
  LOOKOUT_HOME="$home" "$REPORTER" --agent gemini --set done --session "$sid" --message "All done."
  local since3 state3
  since3=$(python3 -c "import json; print(json.load(open('$file'))['state_since'])")
  state3=$(python3 -c "import json; print(json.load(open('$file'))['state'])")
  if [[ "$state3" == "done" && "$since3" != "$since2" ]]; then
    pass "case i: --set done bumps state_since and updates state"
  else
    fail "case i: expected state=done with new state_since, got state=$state3 since=$since3"
  fi
  assert_json_field "$file" last_message "All done." "case i: manual --set --message writes last_message"

  LOOKOUT_HOME="$home" "$REPORTER" --agent gemini --end --session "$sid"
  assert_file_absent "$file" "case i: manual --end deletes the state file"
}

# ---------------------------------------------------------------------------
# Case (j): --agent auto detection.
# ---------------------------------------------------------------------------
run_case_j() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="auto-sess-0001"

  env -u CODEX_HOME CLAUDECODE=1 LOOKOUT_HOME="$home" "$REPORTER" --agent auto --set idle --session "$sid"
  assert_file_present "$home/sessions/claude-$sid.json" "case j: --agent auto with CLAUDECODE=1 resolves to claude"

  local home2; home2=$(mktemp -d); ALL_HOMES+=("$home2")
  env -u CLAUDECODE CODEX_HOME=/tmp/codexhome LOOKOUT_HOME="$home2" "$REPORTER" --agent auto --set idle --session "$sid"
  assert_file_present "$home2/sessions/codex-$sid.json" "case j: --agent auto with a CODEX_* var resolves to codex"

  local home3; home3=$(mktemp -d); ALL_HOMES+=("$home3")
  env -i PATH="$PATH" LOOKOUT_HOME="$home3" "$REPORTER" --agent auto --set idle --session "$sid"
  assert_file_present "$home3/sessions/unknown-$sid.json" "case j: --agent auto with neither var resolves to unknown"
}

# ---------------------------------------------------------------------------
# Case (k): invalid --agent name is rejected (logged, exit 0, no file).
# ---------------------------------------------------------------------------
run_case_k() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local rc n

  LOOKOUT_HOME="$home" "$REPORTER" --agent "Bad Name!" --set working --session sess-bad
  rc=$?
  n=$(find "$home/sessions" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$rc" -eq 0 && "$n" -eq 0 ]]; then
    pass "case k: invalid --agent name (spaces/uppercase) -> exit 0, no file"
  else
    fail "case k: invalid --agent name gave rc=$rc, $n file(s)"
  fi

  # a name that is valid-but-too-long (33 chars) must also be rejected.
  local long_name
  long_name=$(python3 -c "print('a' * 33)")
  LOOKOUT_HOME="$home" "$REPORTER" --agent "$long_name" --set working --session sess-bad2
  rc=$?
  n=$(find "$home/sessions" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$rc" -eq 0 && "$n" -eq 0 ]]; then
    pass "case k: 33-char agent name (over the 32-char limit) -> exit 0, no file"
  else
    fail "case k: over-length agent name gave rc=$rc, $n file(s)"
  fi

  if [[ -f "$home/reporter.log" ]] && grep -q "invalid or missing --agent" "$home/reporter.log"; then
    pass "case k: rejection is logged to reporter.log"
  else
    fail "case k: rejection was not logged"
  fi
}

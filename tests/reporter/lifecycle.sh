# Reporter regression cases: lifecycle. Sourced by ../test_reporter.sh.

# ---------------------------------------------------------------------------
# Case (a): replay the real Claude payload sequence from the fixture log.
# ---------------------------------------------------------------------------
run_case_a() {
  # Portable stand-in for `mapfile`/`readarray` (bash 3.2, macOS's default
  # /bin/bash, has neither).
  local stdin_lines=() event_names=()
  local line
  while IFS= read -r line; do
    stdin_lines+=("$line")
  done < <(grep '^stdin: ' "$FIXTURE_LOG" | sed 's/^stdin: //')
  while IFS= read -r line; do
    event_names+=("$line")
  done < <(grep '^=== ' "$FIXTURE_LOG" | sed -E 's/^=== [0-9:]+ event=//')

  if [[ ${#stdin_lines[@]} -ne 6 || ${#event_names[@]} -ne 6 ]]; then
    fail "case a: fixture log did not parse into 6 events (got ${#stdin_lines[@]} stdin lines, ${#event_names[@]} event names)"
    return
  fi

  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="00000000-0000-4000-8000-000000000001"
  local file="$home/sessions/claude-$sid.json"
  local expected_states=(idle working working working done)

  local i
  for i in 0 1 2 3 4; do
    printf '%s' "${stdin_lines[$i]}" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event "${event_names[$i]}"
    assert_json_field "$file" state "${expected_states[$i]}" "case a: state after ${event_names[$i]} == ${expected_states[$i]}"
  done

  printf '%s' "${stdin_lines[5]}" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event "${event_names[5]}"
  assert_file_absent "$file" "case a: state file deleted after SessionEnd"
}

# ---------------------------------------------------------------------------
# Case (b): synthetic PermissionRequest -> needs_you/permission, detail has command.
# ---------------------------------------------------------------------------
run_case_b() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-permreq-0001"
  local file="$home/sessions/claude-$sid.json"
  # wait_seconds=0: this case is about the state-file fields, not the SPEC
  # 11.3 answer wait (covered by cases v-z) - without this it would block
  # for the default 45s with no answerer.
  echo '{"wait_seconds": 0}' > "$home/config.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"cleanup"}}'

  printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PermissionRequest

  assert_json_field "$file" state needs_you "case b: PermissionRequest -> state=needs_you"
  assert_json_field "$file" reason permission "case b: PermissionRequest -> reason=permission"

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
assert 'rm -rf build' in (d.get('detail') or '')
" 2>/dev/null; then
    pass "case b: detail contains the command"
  else
    fail "case b: detail does not contain the command"
  fi
}

# ---------------------------------------------------------------------------
# Case (c): Notification permission_prompt while already needs_you keeps state_since.
# ---------------------------------------------------------------------------
run_case_c() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-notif-0001"
  local file="$home/sessions/claude-$sid.json"
  local perm_payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}'
  # wait_seconds=0: this is setup for the Notification/state_since check
  # below, not a test of the SPEC 11.3 answer wait (see cases v-z).
  echo '{"wait_seconds": 0}' > "$home/config.json"

  printf '%s' "$perm_payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PermissionRequest

  if [[ ! -f "$file" ]]; then
    fail "case c: setup PermissionRequest did not create a file"
    return
  fi
  local since1
  since1=$(python3 -c "import json; print(json.load(open('$file'))['state_since'])")

  sleep 1.1 # guarantee a real clock tick so a regression would be observable

  local notif_payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"Notification","message":"Claude needs your permission"}'
  printf '%s' "$notif_payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Notification --matcher permission_prompt

  local since2 state2
  since2=$(python3 -c "import json; print(json.load(open('$file'))['state_since'])")
  state2=$(python3 -c "import json; print(json.load(open('$file'))['state'])")

  if [[ "$since1" == "$since2" && "$state2" == "needs_you" ]]; then
    pass "case c: Notification permission_prompt while already needs_you keeps state_since ($since1)"
  else
    fail "case c: expected unchanged state_since=$since1/needs_you, got state_since=$since2 state=$state2"
  fi
}

# ---------------------------------------------------------------------------
# Case (d): PreToolUse tool_name=AskUserQuestion -> needs_you/question.
# ---------------------------------------------------------------------------
run_case_d() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-askq-0001"
  local file="$home/sessions/claude-$sid.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which environment should I deploy to?","header":"Environment","options":["staging","prod"]}]}}'

  printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse

  assert_json_field "$file" state needs_you "case d: AskUserQuestion -> state=needs_you"
  assert_json_field "$file" reason question "case d: AskUserQuestion -> reason=question"

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
assert 'Which environment' in (d.get('detail') or '')
" 2>/dev/null; then
    pass "case d: detail contains the question text"
  else
    fail "case d: detail does not contain the question text"
  fi
}

# ---------------------------------------------------------------------------
# Case (e): Codex payload sequence (--agent codex), Interrupt included
# Current Codex supports Interrupt; older clients may omit it.
# ---------------------------------------------------------------------------
run_case_e() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="codex-sess-0001"
  local file="$home/sessions/codex-$sid.json"
  local base='"session_id":"'"$sid"'","cwd":"/tmp/codexproj","transcript_path":"/tmp/codexproj/t.jsonl"'
  # wait_seconds=0: this sequence checks state-file transitions end to end,
  # not the SPEC 11.3 answer wait (see cases v-z) - Codex's PermissionRequest
  # would otherwise block for the default 45s with no answerer.
  echo '{"wait_seconds": 0}' > "$home/config.json"

  printf '%s' "{$base,\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event SessionStart
  assert_json_field "$file" state idle "case e: codex SessionStart -> idle"
  assert_json_field "$file" agent codex "case e: codex file has agent=codex"

  printf '%s' "{$base,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"Fix the failing test\"}" \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event UserPromptSubmit
  assert_json_field "$file" state working "case e: codex UserPromptSubmit -> working"
  assert_json_field "$file" title "Fix the failing test" "case e: codex title set from prompt"

  printf '%s' "{$base,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"shell\",\"tool_input\":{\"command\":\"rm file\"}}" \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event PermissionRequest
  assert_json_field "$file" state needs_you "case e: codex PermissionRequest -> needs_you"
  assert_json_field "$file" reason permission "case e: codex PermissionRequest -> reason=permission"

  printf '%s' "{$base,\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Done.\"}" \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event Stop
  assert_json_field "$file" state done "case e: codex Stop -> done"
  assert_json_field "$file" last_message "Done." "case e: codex last_message set from Stop"

  printf '%s' "{$base,\"hook_event_name\":\"Interrupt\"}" \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event Interrupt
  assert_json_field "$file" state idle "case e: codex Interrupt -> idle (supported by current Codex)"
  assert_json_field "$file" reason interrupted "case e: codex Interrupt -> reason=interrupted"

  printf '%s' "{$base,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event SessionEnd
  assert_file_absent "$file" "case e: codex SessionEnd deletes the file"
}

# ---------------------------------------------------------------------------
# Case (f): invalid / empty stdin -> exit 0, no file written.
# ---------------------------------------------------------------------------
run_case_f() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local rc n

  printf '%s' 'not valid json{{{' | LOOKOUT_HOME="$home" "$REPORTER" --agent claude --event UserPromptSubmit
  rc=$?
  n=$(find "$home/sessions" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$rc" -eq 0 && "$n" -eq 0 ]]; then
    pass "case f: invalid JSON stdin -> exit 0, no session file"
  else
    fail "case f: invalid JSON stdin gave rc=$rc, $n session file(s)"
  fi

  local home2; home2=$(mktemp -d); ALL_HOMES+=("$home2")
  LOOKOUT_HOME="$home2" "$REPORTER" --agent claude --event UserPromptSubmit < /dev/null
  rc=$?
  n=$(find "$home2/sessions" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$rc" -eq 0 && "$n" -eq 0 ]]; then
    pass "case f: empty stdin -> exit 0, no session file"
  else
    fail "case f: empty stdin gave rc=$rc, $n session file(s)"
  fi
}

# ---------------------------------------------------------------------------
# Case (g): no OAUTH / TOKEN / sk-ant strings in anything the reporter wrote.
# Must run after every other case that populates ALL_HOMES, before cleanup.
# ---------------------------------------------------------------------------
run_case_g() {
  if [[ ${#ALL_HOMES[@]} -eq 0 ]]; then
    fail "case g: no temp homes to scan"
    return
  fi
  local bad=0 f
  while IFS= read -r -d '' f; do
    if grep -Iq -E 'OAUTH|TOKEN|sk-ant' "$f" 2>/dev/null; then
      fail "case g: forbidden token-like string found in $f"
      bad=1
    fi
  done < <(find "${ALL_HOMES[@]}" -type f -print0 2>/dev/null)
  if [[ $bad -eq 0 ]]; then
    pass "case g: no OAUTH/TOKEN/sk-ant strings in any produced file"
  fi
}

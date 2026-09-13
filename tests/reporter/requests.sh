# Reporter regression cases: requests. Sourced by ../test_reporter.sh.

# ---------------------------------------------------------------------------
# Case (v): SPEC 11.3 - PermissionRequest with wait_seconds=0 ("do not
# wait"): the request file is written with the right fields, stdout is
# empty, and the state file stays needs_you *with* a request_id - cleanup of
# a wait_seconds=0 request only happens on a later event that leaves
# needs_you (see case aa for that half of the contract with a question
# request; the same prune_or_clear_stale_request code path handles both).
# ---------------------------------------------------------------------------
run_case_v() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-permwait0-0001"
  local file="$home/sessions/claude-$sid.json"
  echo '{"wait_seconds": 0}' > "$home/config.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"cleanup"}}'

  local out
  out=$(printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PermissionRequest)

  if [[ -z "$out" ]]; then
    pass "case v: wait_seconds=0 -> stdout empty"
  else
    fail "case v: wait_seconds=0 -> expected empty stdout, got: $out"
  fi

  assert_json_field "$file" state needs_you "case v: wait_seconds=0 -> state=needs_you"
  assert_json_field "$file" reason permission "case v: wait_seconds=0 -> reason=permission"
  assert_json_field "$file" request_summary "Bash: rm -rf build" "case v: wait_seconds=0 -> request_summary set"

  local rid
  rid=$(python3 -c "import json; print(json.load(open('$file')).get('request_id') or '')")
  if [[ -n "$rid" ]]; then
    pass "case v: wait_seconds=0 -> request_id is set (not nulled)"
  else
    fail "case v: wait_seconds=0 -> request_id missing"
  fi

  local reqfile="$home/requests/claude-$sid-$rid.json"
  if [[ -f "$reqfile" ]] && python3 -c "
import json
d = json.load(open('$reqfile'))
assert d.get('schema') == 1
assert d.get('agent') == 'claude'
assert d.get('session_id') == '$sid'
assert d.get('request_id') == '$rid'
assert d.get('kind') == 'permission'
assert d.get('tool_name') == 'Bash'
assert d.get('summary') == 'Bash: rm -rf build'
assert d.get('command_or_path') == 'rm -rf build'
assert d.get('cwd') == '/tmp/proj'
assert d.get('created_at')
assert d.get('waits_until')
" 2>/dev/null; then
    pass "case v: request file has all the right fields (kind/tool_name/summary/command_or_path/cwd/timestamps)"
  else
    fail "case v: request file missing or has wrong fields ($reqfile)"
  fi

  local mode
  mode=$(python3 -c "import os,stat; print(oct(stat.S_IMODE(os.stat('$home/requests').st_mode)))" 2>/dev/null)
  if [[ "$mode" == "0o700" ]]; then
    pass "case v: requests/ directory is mode 700"
  else
    fail "case v: requests/ directory mode is '$mode', expected 0o700"
  fi
}

# ---------------------------------------------------------------------------
# Case (w): SPEC 11.3 - PermissionRequest with wait_seconds=3, answered
# "allow" by a background writer ~0.3s in -> stdout is exactly the allow
# hook-decision JSON, request+answer files deleted, request_id nulled.
# ---------------------------------------------------------------------------
run_case_w() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-permallow-0001"
  local file="$home/sessions/claude-$sid.json"
  echo '{"wait_seconds": 3}' > "$home/config.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'

  answer_after_request "$home" claude "$sid" allow 0.3 &
  local bgpid=$!

  local t0 t1 out
  t0=$(python3 -c 'import time; print(time.time())')
  out=$(printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PermissionRequest)
  t1=$(python3 -c 'import time; print(time.time())')
  wait "$bgpid"

  local expected='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
  if [[ "$out" == "$expected" ]]; then
    pass "case w: allow answer -> stdout is exactly the allow decision JSON"
  else
    fail "case w: expected exactly '$expected', got '$out'"
  fi

  local elapsed; elapsed=$(python3 -c "print($t1 - $t0)")
  if python3 -c "exit(0 if $elapsed < 2.9 else 1)"; then
    pass "case w: returned promptly on the answer, did not wait out the full 3s ($elapsed s)"
  else
    fail "case w: took $elapsed s, expected well under the 3s wait_seconds"
  fi

  local reqcount anscount
  reqcount=$(find "$home/requests" -type f -name "claude-$sid-*.json" 2>/dev/null | wc -l | tr -d ' ')
  anscount=$(find "$home/answers" -type f -name "claude-$sid-*.json" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$reqcount" -eq 0 ]]; then pass "case w: request file deleted after answer"; else fail "case w: request file still present ($reqcount)"; fi
  if [[ "$anscount" -eq 0 ]]; then pass "case w: answer file deleted after answer"; else fail "case w: answer file still present ($anscount)"; fi

  assert_json_field "$file" request_id "" "case w: state file request_id is null after allow"
  assert_json_field "$file" state needs_you "case w: state stays needs_you (cleared later by PostToolUse, not here)"
}

# ---------------------------------------------------------------------------
# Case (x): same as (w) but with a "deny" answer.
# ---------------------------------------------------------------------------
run_case_x() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-permdeny-0001"
  local file="$home/sessions/claude-$sid.json"
  echo '{"wait_seconds": 3}' > "$home/config.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"curl evil.example"}}'

  answer_after_request "$home" claude "$sid" deny 0.3 &
  local bgpid=$!
  local out
  out=$(printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PermissionRequest)
  wait "$bgpid"

  local expected='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'
  if [[ "$out" == "$expected" ]]; then
    pass "case x: deny answer -> stdout is exactly the deny decision JSON"
  else
    fail "case x: expected exactly '$expected', got '$out'"
  fi

  local reqcount anscount
  reqcount=$(find "$home/requests" -type f -name "claude-$sid-*.json" 2>/dev/null | wc -l | tr -d ' ')
  anscount=$(find "$home/answers" -type f -name "claude-$sid-*.json" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$reqcount" -eq 0 && "$anscount" -eq 0 ]]; then
    pass "case x: request and answer files deleted after deny"
  else
    fail "case x: leftover files after deny (requests=$reqcount answers=$anscount)"
  fi
  assert_json_field "$file" request_id "" "case x: state file request_id is null after deny"
}

# ---------------------------------------------------------------------------
# Case (y): a "pass" answer -> stdout empty, same cleanup as allow/deny.
# ---------------------------------------------------------------------------
run_case_y() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-permpass-0001"
  local file="$home/sessions/claude-$sid.json"
  echo '{"wait_seconds": 3}' > "$home/config.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}'

  answer_after_request "$home" claude "$sid" pass 0.3 &
  local bgpid=$!
  local out
  out=$(printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PermissionRequest)
  wait "$bgpid"

  if [[ -z "$out" ]]; then
    pass "case y: pass answer -> stdout empty (normal prompt appears)"
  else
    fail "case y: pass answer -> expected empty stdout, got '$out'"
  fi

  local reqcount anscount
  reqcount=$(find "$home/requests" -type f -name "claude-$sid-*.json" 2>/dev/null | wc -l | tr -d ' ')
  anscount=$(find "$home/answers" -type f -name "claude-$sid-*.json" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$reqcount" -eq 0 && "$anscount" -eq 0 ]]; then
    pass "case y: request and answer files deleted after pass"
  else
    fail "case y: leftover files after pass (requests=$reqcount answers=$anscount)"
  fi
  assert_json_field "$file" request_id "" "case y: state file request_id is null after pass"
}

# ---------------------------------------------------------------------------
# Case (z): no answer at all, wait_seconds=1 -> stdout empty, the run takes
# at least 1s (the full wait) and under 2s (no runaway hang).
# ---------------------------------------------------------------------------
run_case_z() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-permtimeout-0001"
  local file="$home/sessions/claude-$sid.json"
  echo '{"wait_seconds": 1}' > "$home/config.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}'

  local t0 t1 out
  t0=$(python3 -c 'import time; print(time.time())')
  out=$(printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PermissionRequest)
  t1=$(python3 -c 'import time; print(time.time())')

  if [[ -z "$out" ]]; then
    pass "case z: timeout -> stdout empty"
  else
    fail "case z: timeout -> expected empty stdout, got '$out'"
  fi

  local elapsed; elapsed=$(python3 -c "print($t1 - $t0)")
  if python3 -c "exit(0 if ($elapsed >= 1.0 and $elapsed < 2.0) else 1)"; then
    pass "case z: timeout run took $elapsed s (>= 1s wait_seconds, < 2s)"
  else
    fail "case z: timeout run took $elapsed s, expected >= 1.0 and < 2.0"
  fi

  assert_json_field "$file" request_id "" "case z: state file request_id is null after timeout"
  local reqcount
  reqcount=$(find "$home/requests" -type f -name "claude-$sid-*.json" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$reqcount" -eq 0 ]]; then pass "case z: request file deleted after timeout"; else fail "case z: request file still present after timeout"; fi
}

# ---------------------------------------------------------------------------
# Case (aa): SPEC 11.3 - PreToolUse/AskUserQuestion writes a `question`
# request with the question text and option labels, no waiting; PostToolUse
# (an event that leaves needs_you) removes the file and nulls request_id.
# ---------------------------------------------------------------------------
run_case_aa() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-askq-options-0001"
  local file="$home/sessions/claude-$sid.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which environment should I deploy to?","header":"Environment","options":[{"label":"staging"},{"label":"prod"}]}]}}'

  printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse

  assert_json_field "$file" state needs_you "case aa: AskUserQuestion -> state=needs_you"
  assert_json_field "$file" reason question "case aa: AskUserQuestion -> reason=question"

  local rid
  rid=$(python3 -c "import json; print(json.load(open('$file')).get('request_id') or '')")
  if [[ -n "$rid" ]]; then
    pass "case aa: state file has a request_id"
  else
    fail "case aa: state file has no request_id"
  fi

  local reqfile="$home/requests/claude-$sid-$rid.json"
  if [[ -f "$reqfile" ]] && python3 -c "
import json
d = json.load(open('$reqfile'))
assert d.get('kind') == 'question'
assert d.get('question') == 'Which environment should I deploy to?'
assert d.get('options') == ['staging', 'prod'], d.get('options')
assert d.get('cwd') == '/tmp/proj'
assert d.get('created_at')
" 2>/dev/null; then
    pass "case aa: question request file has the question text and option labels"
  else
    fail "case aa: question request file missing or wrong ($reqfile)"
  fi

  local post='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
  printf '%s' "$post" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PostToolUse
  assert_json_field "$file" request_id "" "case aa: PostToolUse (leaves needs_you) clears request_id"
  if [[ ! -f "$reqfile" ]]; then
    pass "case aa: PostToolUse removes the question request file"
  else
    fail "case aa: question request file still present after PostToolUse"
  fi
}

# ---------------------------------------------------------------------------
# Case (bb): SPEC 11.3 - messaging_socket is recorded only when
# CLAUDE_CODE_MESSAGING_SOCKET points at a path that actually exists.
# ---------------------------------------------------------------------------
run_case_bb() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-msgsock-0001"
  local file="$home/sessions/claude-$sid.json"
  local sockfile="$home/fake.sock"
  : > "$sockfile"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SessionStart","source":"startup"}'

  printf '%s' "$payload" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ CLAUDE_CODE_MESSAGING_SOCKET="$sockfile" "$REPORTER" --agent claude --event SessionStart
  assert_json_field "$file" messaging_socket "$sockfile" "case bb: messaging_socket recorded when the env var points at an existing file"

  local home2; home2=$(mktemp -d); ALL_HOMES+=("$home2")
  local file2="$home2/sessions/claude-$sid.json"
  printf '%s' "$payload" | env -u CLAUDE_CODE_MESSAGING_SOCKET LOOKOUT_HOME="$home2" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionStart
  assert_json_field "$file2" messaging_socket "" "case bb: messaging_socket absent when the env var is unset"

  local home3; home3=$(mktemp -d); ALL_HOMES+=("$home3")
  local file3="$home3/sessions/claude-$sid.json"
  printf '%s' "$payload" | LOOKOUT_HOME="$home3" CLAUDE_PID=$$ CLAUDE_CODE_MESSAGING_SOCKET="/no/such/lookout-test-path.sock" "$REPORTER" --agent claude --event SessionStart
  assert_json_field "$file3" messaging_socket "" "case bb: messaging_socket absent when the env var points at a path that does not exist"
}

# ---------------------------------------------------------------------------
# Case (dd): SPEC 11.3 - a request file older than 6h is pruned on the next
# hook event even while the session is *still* needs_you (idle_prompt is a
# documented no-op state transition - SPEC 4 - so it exercises the prune
# check without itself clearing needs_you).
# ---------------------------------------------------------------------------
run_case_dd() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-request-prune-0001"
  local file="$home/sessions/claude-$sid.json"

  local pre='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Proceed?","options":[{"label":"yes"},{"label":"no"}]}]}}'
  printf '%s' "$pre" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse

  local rid
  rid=$(python3 -c "import json; print(json.load(open('$file'))['request_id'])")
  local reqfile="$home/requests/claude-$sid-$rid.json"
  assert_file_present "$reqfile" "case dd: setup - question request file exists"

  python3 -c "
import json, time
p = '$reqfile'
d = json.load(open(p))
d['created_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - 7*3600))
json.dump(d, open(p, 'w'))
"

  local notif='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"Notification","message":"still waiting"}'
  printf '%s' "$notif" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Notification --matcher idle_prompt

  assert_json_field "$file" state needs_you "case dd: idle_prompt leaves state=needs_you unchanged"
  assert_json_field "$file" request_id "" "case dd: a >6h-old request is pruned even while still needs_you"
  if [[ ! -f "$reqfile" ]]; then
    pass "case dd: stale (>6h) request file removed"
  else
    fail "case dd: stale request file still present"
  fi
}

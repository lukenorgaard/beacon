# Reporter regression cases: identity. Sourced by ../test_reporter.sh.

# ---------------------------------------------------------------------------
# Case (l): SPEC 9.1 - CLAUDE_CODE_HOST_SESSION_ID -> host_ref/host/entrypoint,
# takes precedence over TERM_SESSION_ID. An invalid id must not force anything.
# ---------------------------------------------------------------------------
run_case_l() {
  # This test suite itself may be running inside a real Claude desktop
  # session (verified on the owner's Mac: the ps ancestry of $$ walks up to
  # /Applications/Claude.app, and CLAUDE_CODE_ENTRYPOINT/CLAUDE_CODE_HOST_SESSION_ID
  # are already set in the ambient environment). A CLAUDE_PID that matches a
  # real, running ancestor would let the pre-existing ps-walk / ENTRYPOINT
  # rules produce "claude-desktop" on their own, which would make this test
  # pass even if the new CLAUDE_CODE_HOST_SESSION_ID handling were broken.
  # Use a synthetic PID with no `ps` entry and explicitly neutralize
  # CLAUDE_CODE_ENTRYPOINT so only the behaviour under test can produce the
  # result.
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-desktop-0001"
  local file="$home/sessions/claude-$sid.json"
  local payload='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SessionStart","source":"startup"}'

  printf '%s' "$payload" | env -u TERM_PROGRAM LOOKOUT_HOME="$home" CLAUDE_PID=999901 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_HOST_SESSION_ID="local_abc123-XYZ" TERM_SESSION_ID="w0t0p0:ABCDEF" "$REPORTER" --agent claude --event SessionStart

  assert_json_field "$file" host_ref "local_abc123-XYZ" "case l: valid desktop host session id -> host_ref set, wins over TERM_SESSION_ID"
  assert_json_field "$file" host claude-desktop "case l: valid desktop host session id -> host forced to claude-desktop"
  assert_json_field "$file" entrypoint claude-desktop "case l: valid desktop host session id -> entrypoint forced to claude-desktop"

  local home2; home2=$(mktemp -d); ALL_HOMES+=("$home2")
  local sid2="test-desktop-0002"
  local file2="$home2/sessions/claude-$sid2.json"
  local payload2='{"session_id":"'"$sid2"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SessionStart","source":"startup"}'
  printf '%s' "$payload2" | env -u TERM_PROGRAM LOOKOUT_HOME="$home2" CLAUDE_PID=999902 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_HOST_SESSION_ID="not-a-valid-id" TERM_SESSION_ID="w0t0p0:ABCDEF" "$REPORTER" --agent claude --event SessionStart

  assert_json_field "$file2" host_ref "w0t0p0:ABCDEF" "case l: invalid desktop host session id falls back to TERM_SESSION_ID"
  if [[ -f "$file2" ]] && python3 -c "
import json
d = json.load(open('$file2'))
assert d.get('host') != 'claude-desktop', d.get('host')
assert d.get('entrypoint') != 'claude-desktop', d.get('entrypoint')
" 2>/dev/null; then
    pass "case l: invalid desktop host session id does not force claude-desktop host/entrypoint"
  else
    fail "case l: invalid desktop host session id unexpectedly forced claude-desktop host/entrypoint"
  fi
}

run_case_ee() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  printf '%s' '{"session_id":"ignored-1","cwd":"/tmp/proj","hook_event_name":"SessionStart","source":"startup"}' | LOOKOUT_HOME="$home" LOOKOUT_IGNORE=1 CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionStart
  if [[ -e "$home/sessions" ]]; then fail "case ee: LOOKOUT_IGNORE=1 must not write anything"; else pass "case ee: LOOKOUT_IGNORE=1 writes nothing"; fi
  local out
  out=$(printf '%s' '{"session_id":"ignored-1","cwd":"/tmp/proj","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}' | LOOKOUT_HOME="$home" LOOKOUT_IGNORE=1 "$REPORTER" --agent claude --event PermissionRequest)
  if [[ -z "$out" ]]; then pass "case ee: ignored PermissionRequest prints no decision"; else fail "case ee: ignored PermissionRequest printed: $out"; fi
}

run_case_ff() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-token-0001"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"UserPromptSubmit","prompt":"hi"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ CLAUDE_CODE_MESSAGING_TOKEN="tok-abc-123" "$REPORTER" --agent claude --event UserPromptSubmit
  local tf="$home/tokens/claude-$sid.token"
  if [[ -f "$tf" && "$(cat "$tf")" == "tok-abc-123" ]]; then pass "case ff: messaging token stored in tokens/ file"; else fail "case ff: token file missing or wrong"; fi
  local mode; mode=$(stat -f %Lp "$tf" 2>/dev/null); local dmode; dmode=$(stat -f %Lp "$home/tokens" 2>/dev/null)
  if [[ "$mode" == "600" && "$dmode" == "700" ]]; then pass "case ff: token file 600 in a 700 dir"; else fail "case ff: modes file=$mode dir=$dmode"; fi
  if grep -q "tok-abc-123" "$home/sessions/claude-$sid.json"; then fail "case ff: token leaked into the state file"; else pass "case ff: token not in the state file"; fi
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"SessionEnd","reason":"other"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionEnd
  if [[ ! -e "$tf" ]]; then pass "case ff: SessionEnd removes the token file"; else fail "case ff: token file survived SessionEnd"; fi
}

run_case_gg() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-shell-pid-0001"
  # Create an explicit child agent. The reporter walks the agent's ancestors, so
  # treating this bash itself as the agent accidentally depended on its parent shell.
  LOOKOUT_HOME="$home" CLAUDE_CODE_ENTRYPOINT=cli python3 - "$REPORTER" "$sid" <<'PYTEST'
import json
import os
import subprocess
import sys

payload = {"session_id": sys.argv[2], "cwd": "/tmp/proj",
           "hook_event_name": "SessionStart", "source": "startup"}
subprocess.run([sys.executable, sys.argv[1], "--agent", "claude", "--event", "SessionStart"],
               input=json.dumps(payload), text=True, check=True,
               env=dict(os.environ, CLAUDE_PID=str(os.getpid())))
PYTEST
  local sp; sp=$(python3 -c "import json;print(json.load(open('$home/sessions/claude-$sid.json')).get('shell_pid') or '')")
  if [[ "$sp" == "$$" ]] && ps -o comm= -p "$sp" | grep -qE '(^|/)-?(zsh|bash|sh|fish|nu|dash|tcsh|ksh)$'; then pass "case gg: shell_pid points at a shell ancestor ($sp)"; else fail "case gg: shell_pid missing or not a shell (got '$sp')"; fi
}

# Reporter regression cases: metadata. Sourced by ../test_reporter.sh.

# ---------------------------------------------------------------------------
# Case (cc): SPEC 12.2 - cwd/project only move on SessionStart/UserPromptSubmit;
# a worktree cwd from a tool event sets active_cwd/worktree instead, cleared
# on Stop; origin_cwd is recorded once and never changes.
# ---------------------------------------------------------------------------
run_case_cc() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-worktree-0001"
  local file="$home/sessions/claude-$sid.json"

  local start='{"session_id":"'"$sid"'","cwd":"/Users/x/proj","transcript_path":"/tmp/t.jsonl","hook_event_name":"SessionStart","source":"startup"}'
  printf '%s' "$start" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionStart
  assert_json_field "$file" project proj "case cc: SessionStart sets project"
  assert_json_field "$file" origin_cwd "/Users/x/proj" "case cc: SessionStart sets origin_cwd"

  local pre='{"session_id":"'"$sid"'","cwd":"/Users/x/proj/.claude/worktrees/feat-1","transcript_path":"/tmp/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  printf '%s' "$pre" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse
  assert_json_field "$file" project proj "case cc: PreToolUse in a worktree does not change project"
  assert_json_field "$file" cwd "/Users/x/proj" "case cc: PreToolUse in a worktree does not change cwd"
  assert_json_field "$file" worktree feat-1 "case cc: worktree basename recorded"
  assert_json_field "$file" active_cwd "/Users/x/proj/.claude/worktrees/feat-1" "case cc: active_cwd set to the tool event's own cwd"

  local stop='{"session_id":"'"$sid"'","cwd":"/Users/x/proj","transcript_path":"/tmp/t.jsonl","hook_event_name":"Stop","last_assistant_message":"done"}'
  printf '%s' "$stop" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  assert_json_field "$file" worktree "" "case cc: Stop clears worktree"
  assert_json_field "$file" active_cwd "" "case cc: Stop clears active_cwd"

  local upd='{"session_id":"'"$sid"'","cwd":"/Users/x/proj2","transcript_path":"/tmp/t.jsonl","hook_event_name":"UserPromptSubmit","prompt":"do something else"}'
  printf '%s' "$upd" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event UserPromptSubmit
  assert_json_field "$file" project proj2 "case cc: UserPromptSubmit with a new cwd changes project"
  assert_json_field "$file" cwd "/Users/x/proj2" "case cc: UserPromptSubmit with a new cwd changes cwd"
  assert_json_field "$file" origin_cwd "/Users/x/proj" "case cc: origin_cwd stays the very first cwd seen"
}

# ---------------------------------------------------------------------------
# Case (jj): SPEC 11.3 / 17.7 - Codex PermissionRequest uses the same generic
# payload shape as Claude (tool_name/tool_input.command/cwd/session_id, plus
# Codex's own turn_id which the reporter must simply ignore): the request
# file gets the command as its summary, and an allow answer produces the same
# hook-decision JSON as the Claude path (mirrors cases v/w).
# ---------------------------------------------------------------------------
run_case_kk() {
  # 2026-09-04: (a) a turn that ends with a question is done even with background tasks listed,
  # (b) orphan request files die when the state leaves needs_you, (c) SessionEnd purges them.
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-stale-0001"
  local ev='LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude'
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"SessionStart","source":"startup"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionStart
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"UserPromptSubmit","prompt":"Do it"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event UserPromptSubmit
  # (a1) background task + a statement → still working/background (unchanged rule)
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"Stop","last_assistant_message":"Building now.","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"x"}]}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  local st; st=$(python3 -c "import json;d=json.load(open('$home/sessions/claude-$sid.json'));print(d['state'],d['reason'])")
  if [[ "$st" == "working background" ]]; then pass "case kk: Stop with a background task and no question stays working/background"; else fail "case kk: expected working background, got '$st'"; fi
  # (a2) background task + a question to the user → done, detail says so
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"Stop","last_assistant_message":"Skal jeg gå i gang med **T'"'"'et**?","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"x"}]}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  st=$(python3 -c "import json;d=json.load(open('$home/sessions/claude-$sid.json'));print(d['state'],d['reason'],'|',d['detail'])")
  if [[ "$st" == "done stop | Asks you · 1 background task still listed" ]]; then pass "case kk: Stop ending with a question is done despite a background task"; else fail "case kk: expected done with 'Asks you', got '$st'"; fi
  # (b) a question request, then an orphan file from an older question, then the answer arrives
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}]}]}}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse
  local rid; rid=$(python3 -c "import json;d=json.load(open('$home/sessions/claude-$sid.json'));print(d['request_id'])")
  printf '%s' '{"schema":"1","agent":"claude","session_id":"'"$sid"'","request_id":"deadbeef","kind":"question","question":"Old?","options":["X"],"created_at":"2026-09-03T13:34:48Z"}' > "$home/requests/claude-$sid-deadbeef.json"
  local before; before=$(ls "$home/requests" | grep -c "claude-$sid-")
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_response":{"answers":{"Which?":"A"}}}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PostToolUse
  local after; after=$(ls "$home/requests" 2>/dev/null | grep -c "claude-$sid-" || true)
  local req; req=$(python3 -c "import json;d=json.load(open('$home/sessions/claude-$sid.json'));print(d['request_id'])")
  if [[ "$before" == "2" && "$after" == "0" && "$req" == "None" ]]; then pass "case kk: answering a question removes its file and any orphan (2 → 0)"; else fail "case kk: request files before=$before after=$after request_id=$req"; fi
  # (c) SessionEnd purges request files even if one is left behind
  printf '%s' '{"schema":"1","agent":"claude","session_id":"'"$sid"'","request_id":"leftover","kind":"question","question":"?","options":[],"created_at":"2026-09-03T13:34:48Z"}' > "$home/requests/claude-$sid-leftover.json"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"SessionEnd","reason":"exit"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionEnd
  after=$(ls "$home/requests" 2>/dev/null | grep -c "claude-$sid-" || true)
  if [[ "$after" == "0" ]]; then pass "case kk: SessionEnd purges the session's request files"; else fail "case kk: $after request file(s) survived SessionEnd"; fi
}

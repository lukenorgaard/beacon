# Reporter regression cases: subagents. Sourced by ../test_reporter.sh.

# ---------------------------------------------------------------------------
# Case (m): SPEC 9.3 - PreToolUse Agent -> SubagentStart records one subagent
# with the staged description/model, and does not change session state.
# ---------------------------------------------------------------------------
run_case_m() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-subagent-0001"
  local file="$home/sessions/claude-$sid.json"

  local pretool='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Investigate flaky auth test   ","subagent_type":"debugger","model":"sonnet","run_in_background":false}}'
  printf '%s' "$pretool" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse
  assert_json_field "$file" state working "case m: PreToolUse Agent -> state=working"

  local start='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SubagentStart","agent_id":"agent-001","agent_type":"debugger"}'
  printf '%s' "$start" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart
  assert_json_field "$file" state working "case m: SubagentStart does not change state (still working)"

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
sub = d.get('subagents') or []
assert len(sub) == 1, sub
sa = sub[0]
assert sa.get('id') == 'agent-001', sa
assert sa.get('type') == 'debugger', sa
assert sa.get('description') == 'Investigate flaky auth test', sa
assert sa.get('model') == 'sonnet', sa
assert sa.get('started_at')
assert (d.get('pending_agents') or []) == [], d.get('pending_agents')
" 2>/dev/null; then
    pass "case m: PreToolUse Agent -> SubagentStart records one subagent with description/model/id"
  else
    fail "case m: subagent record after PreToolUse Agent -> SubagentStart is wrong"
  fi
}

# ---------------------------------------------------------------------------
# Case (n): SubagentStop removes the subagent by id; state unaffected.
# ---------------------------------------------------------------------------
run_case_n() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-subagent-stop-0001"
  local file="$home/sessions/claude-$sid.json"

  local pretool='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Task","tool_input":{"description":"Write release notes","subagent_type":"general-purpose"}}'
  printf '%s' "$pretool" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse

  local start='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SubagentStart","agent_id":"agent-002","agent_type":"general-purpose"}'
  printf '%s' "$start" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
assert len(d.get('subagents') or []) == 1
" 2>/dev/null; then
    pass "case n: setup - one live subagent before SubagentStop"
  else
    fail "case n: setup did not create a live subagent"
  fi

  local stop='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SubagentStop","agent_id":"agent-002","agent_type":"general-purpose"}'
  printf '%s' "$stop" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStop
  assert_json_field "$file" state working "case n: SubagentStop does not change state"

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
assert (d.get('subagents') or []) == [], d.get('subagents')
" 2>/dev/null; then
    pass "case n: SubagentStop removes the subagent by id"
  else
    fail "case n: subagent still present after SubagentStop"
  fi
}

# ---------------------------------------------------------------------------
# Case (o): two sub-agents of different types queued before either
# SubagentStart fires; each SubagentStart must match by type, not FIFO order.
# ---------------------------------------------------------------------------
run_case_o() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-subagent-match-0001"
  local file="$home/sessions/claude-$sid.json"

  local pre_a='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Audit the billing module","subagent_type":"code-reviewer"}}'
  printf '%s' "$pre_a" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse

  local pre_b='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Find the flaky test","subagent_type":"debugger"}}'
  printf '%s' "$pre_b" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse

  # SubagentStart fires for the *second* queued (debugger) sub-agent first.
  local start_debugger='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SubagentStart","agent_id":"agent-debugger","agent_type":"debugger"}'
  printf '%s' "$start_debugger" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart

  local start_reviewer='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SubagentStart","agent_id":"agent-reviewer","agent_type":"code-reviewer"}'
  printf '%s' "$start_reviewer" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
sub = {sa['id']: sa for sa in (d.get('subagents') or [])}
assert set(sub.keys()) == {'agent-debugger', 'agent-reviewer'}, sub
assert sub['agent-debugger']['description'] == 'Find the flaky test', sub['agent-debugger']
assert sub['agent-reviewer']['description'] == 'Audit the billing module', sub['agent-reviewer']
assert (d.get('pending_agents') or []) == []
" 2>/dev/null; then
    pass "case o: SubagentStart matches the pending entry by type, not arrival order"
  else
    fail "case o: SubagentStart did not match pending entries by type"
  fi
}

# ---------------------------------------------------------------------------
# Case (p): Stop clears pending_agents but keeps live subagents.
# ---------------------------------------------------------------------------
run_case_p() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-subagent-stopclears-0001"
  local file="$home/sessions/claude-$sid.json"

  local pre_live='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Live agent","subagent_type":"general-purpose"}}'
  printf '%s' "$pre_live" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse
  local start_live='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SubagentStart","agent_id":"agent-live","agent_type":"general-purpose"}'
  printf '%s' "$start_live" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart

  # A second Agent tool call whose SubagentStart never fires - stays pending.
  local pre_pending='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Never started","subagent_type":"researcher"}}'
  printf '%s' "$pre_pending" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
assert len(d.get('subagents') or []) == 1
assert len(d.get('pending_agents') or []) == 1
" 2>/dev/null; then
    pass "case p: setup - one live subagent, one still pending"
  else
    fail "case p: setup did not produce one live + one pending"
  fi

  local stop='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"Stop","last_assistant_message":"Done for now."}'
  printf '%s' "$stop" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  assert_json_field "$file" state working "case p: Stop with live sub-agents keeps state=working (background rule)"
  assert_json_field "$file" reason background "case p: reason is background while sub-agents live"

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
assert (d.get('pending_agents') or []) == [], d.get('pending_agents')
assert len(d.get('subagents') or []) == 1, d.get('subagents')
assert d['subagents'][0]['id'] == 'agent-live'
" 2>/dev/null; then
    pass "case p: Stop clears pending_agents but keeps live subagents"
  else
    fail "case p: Stop did not clear pending_agents / keep live subagents correctly"
  fi
}

# ---------------------------------------------------------------------------
# Case (q): subagent entries older than 6h are pruned on every write; fresh
# entries are left alone.
# ---------------------------------------------------------------------------
run_case_q() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-subagent-prune-0001"
  local file="$home/sessions/claude-$sid.json"

  local pre='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Stale agent","subagent_type":"general-purpose"}}'
  printf '%s' "$pre" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse
  local start='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SubagentStart","agent_id":"agent-stale","agent_type":"general-purpose"}'
  printf '%s' "$start" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart

  # A second, fresh sub-agent - proves pruning is selective, not wholesale.
  local pre2='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Fresh agent","subagent_type":"researcher"}}'
  printf '%s' "$pre2" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse
  local start2='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"SubagentStart","agent_id":"agent-fresh","agent_type":"researcher"}'
  printf '%s' "$start2" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart

  # Back-date the first sub-agent's started_at to 7 hours ago.
  python3 -c "
import json, time
path = '$file'
d = json.load(open(path))
for sa in d['subagents']:
    if sa['id'] == 'agent-stale':
        sa['started_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - 7*3600))
json.dump(d, open(path, 'w'))
"

  # Any subsequent hook event must prune it on write.
  local post='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"/tmp/proj/t.jsonl","hook_event_name":"PostToolUse","tool_name":"Read"}'
  printf '%s' "$post" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PostToolUse

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
ids = {sa['id'] for sa in (d.get('subagents') or [])}
assert ids == {'agent-fresh'}, ids
" 2>/dev/null; then
    pass "case q: subagent entries older than 6h are pruned on write, fresh ones kept"
  else
    fail "case q: 6h subagent prune did not behave as expected"
  fi
}

run_case_r() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-desktop-title-0001"
  local file="$home/sessions/claude-$sid.json"
  local tr="$home/fake-transcript.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' \
    '{"type":"custom-title","customTitle":"Old title"}' \
    '{"type":"assistant","message":{"role":"assistant","content":"hi"}}' \
    '{"type":"custom-title","customTitle":"  Terminal   session overlay widget "}' > "$tr"

  local stop='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"ok"}'
  printf '%s' "$stop" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  assert_json_field "$file" desktop_title "Terminal session overlay widget" "case r: desktop_title is the newest custom-title line, whitespace collapsed"

  local pre='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  printf '%s' "$pre" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse
  assert_json_field "$file" desktop_title "Terminal session overlay widget" "case r: desktop_title survives events that do not re-read the transcript"
}

run_case_s() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-model-provider-0001"
  local file="$home/sessions/claude-$sid.json"
  local tr="$home/fake-transcript.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-5","content":"a"}}' \
    '{"type":"assistant","message":{"role":"assistant","model":"claude-fable-5-1","content":"b"}}' > "$tr"

  local stop='{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"ok"}'
  printf '%s' "$stop" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ ANTHROPIC_BASE_URL="https://openrouter.ai/api/v1" "$REPORTER" --agent claude --event Stop
  assert_json_field "$file" model "claude-fable-5-1" "case s: model is the newest assistant message model"
  assert_json_field "$file" provider "openrouter" "case s: ANTHROPIC_BASE_URL at openrouter → provider openrouter"

  local sid2="test-model-provider-0002"
  local file2="$home/sessions/claude-$sid2.json"
  local start='{"session_id":"'"$sid2"'","cwd":"/tmp/proj","hook_event_name":"SessionStart","source":"startup"}'
  printf '%s' "$start" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ ANTHROPIC_BASE_URL="http://localhost:11434" "$REPORTER" --agent claude --event SessionStart
  assert_json_field "$file2" provider "local" "case s: localhost base URL → provider local"

  local sid3="test-model-provider-0003"
  local file3="$home/sessions/claude-$sid3.json"
  printf '%s' '{"session_id":"'"$sid3"'","cwd":"/tmp/proj","hook_event_name":"SessionStart","source":"startup"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ ANTHROPIC_BASE_URL="" "$REPORTER" --agent claude --event SessionStart
  assert_json_field "$file3" provider "anthropic" "case s: no base URL → provider anthropic"

  local cfile="$home/sessions/codex-test-model-provider-0004.json"
  printf '%s' '{"session_id":"test-model-provider-0004","cwd":"/tmp/proj","hook_event_name":"SessionStart","model":"gpt-5.6-sol"}' | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event SessionStart
  assert_json_field "$cfile" model "gpt-5.6-sol" "case s: codex model taken from the payload"
  assert_json_field "$cfile" provider "openai" "case s: codex default provider openai"
}

run_case_t() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-background-0001"
  local file="$home/sessions/claude-$sid.json"
  local pre='{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Long build","subagent_type":"general-purpose","run_in_background":true}}'
  printf '%s' "$pre" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse
  local start='{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"SubagentStart","agent_id":"agent-bg","agent_type":"general-purpose"}'
  printf '%s' "$start" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart
  local stop='{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"Stop","last_assistant_message":"Building in the background.","background_tasks":[]}'
  printf '%s' "$stop" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  assert_json_field "$file" state "working" "case t: Stop with a live sub-agent keeps the session working"
  assert_json_field "$file" reason "background" "case t: reason is background"
  assert_json_field "$file" detail "1 agent running in background" "case t: detail names the background agent count"
  assert_json_field "$file" last_message "Building in the background." "case t: last_message still recorded"
  local sstop='{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"SubagentStop","agent_id":"agent-bg","agent_type":"general-purpose"}'
  printf '%s' "$sstop" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStop
  assert_json_field "$file" state "done" "case t: last SubagentStop after the turn ended → done"
  assert_json_field "$file" reason "stop" "case t: reason stop after the last sub-agent"
  local stop2='{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"Stop","last_assistant_message":"All done.","background_tasks":[{"id":"bash-1"}]}'
  printf '%s' "$stop2" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  assert_json_field "$file" state "working" "case t: Stop with background_tasks stays working"
  assert_json_field "$file" detail "1 background task running" "case t: background task detail"
  local stop3='{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"Stop","last_assistant_message":"All done.","background_tasks":[]}'
  printf '%s' "$stop3" | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  assert_json_field "$file" state "done" "case t: plain Stop → done"
}

run_case_u() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-concurrency-0001"
  local file="$home/sessions/claude-$sid.json"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"SessionStart","source":"startup"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionStart
  # 10 sub-agent starts interleaved with 10 tool events, all launched at once.
  local i
  for i in $(seq 1 10); do
    printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"SubagentStart","agent_id":"agent-'"$i"'","agent_type":"general-purpose"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStart &
    printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"PostToolUse","tool_name":"Bash"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PostToolUse &
  done
  wait
  local count
  count=$(python3 -c "import json;print(len(json.load(open('$file')).get('subagents') or []))" 2>/dev/null || echo 0)
  if [[ "$count" -eq 10 ]]; then pass "case u: 20 concurrent hook events keep all 10 sub-agents (file lock)"; else fail "case u: expected 10 sub-agents after concurrent writes, got $count"; fi
  for i in $(seq 1 10); do
    printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"SubagentStop","agent_id":"agent-'"$i"'","agent_type":"general-purpose"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SubagentStop &
    printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PreToolUse &
  done
  wait
  count=$(python3 -c "import json;print(len(json.load(open('$file')).get('subagents') or []))" 2>/dev/null || echo 99)
  if [[ "$count" -eq 0 ]]; then pass "case u: concurrent SubagentStop events remove every sub-agent"; else fail "case u: expected 0 sub-agents after concurrent stops, got $count"; fi
}

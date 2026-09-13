# Reporter regression cases: usage. Sourced by ../test_reporter.sh.

run_case_hh() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="test-history-0001"
  local tr="$home/t.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40},"content":"a"}}' > "$tr"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"SessionStart","source":"startup"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionStart
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"UserPromptSubmit","prompt":"Fix the thing"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event UserPromptSubmit
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"Done."}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  local n; n=$(wc -l < "$home/history.jsonl" | tr -d ' ')
  if [[ "$n" == "3" ]]; then pass "case hh: three history lines (start, working, done)"; else fail "case hh: expected 3 history lines, got $n"; fi
  local tos; tos=$(python3 -c "import json;print(','.join(json.loads(l)['to'] for l in open('$home/history.jsonl')))")
  if [[ "$tos" == "idle,working,done" ]]; then pass "case hh: transitions idle→working→done"; else fail "case hh: transitions were $tos"; fi
  local tok; tok=$(python3 -c "import json;d=json.load(open('$home/sessions/claude-$sid.json'));t=d['tokens']['claude-sonnet-5'];print(t['in'],t['out'],t['cache_read'],t['cache_write'],d['usage_offset']>0)")
  if [[ "$tok" == "10 20 30 40 True" ]]; then pass "case hh: token usage accumulated per model with an offset"; else fail "case hh: tokens were '$tok'"; fi
  # second Stop with one more assistant line only adds the new line
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1},"content":"b"}}' >> "$tr"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"Done again."}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  tok=$(python3 -c "import json;d=json.load(open('$home/sessions/claude-$sid.json'));t=d['tokens']['claude-sonnet-5'];print(t['in'],t['out'])")
  if [[ "$tok" == "11 21" ]]; then pass "case hh: incremental usage (no double counting)"; else fail "case hh: incremental tokens were '$tok'"; fi
  # Claude Code writes one line per content block of the same response, each repeating the
  # response's whole usage: the same message id must count once, even across two scans.
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_dup","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":100,"cache_read_input_tokens":100,"cache_creation_input_tokens":100},"content":[{"type":"text","text":"x"}]}}' >> "$tr"
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_dup","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":100,"cache_read_input_tokens":100,"cache_creation_input_tokens":100},"content":[{"type":"tool_use","name":"Bash"}]}}' >> "$tr"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"Done."}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_dup","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":100,"cache_read_input_tokens":100,"cache_creation_input_tokens":100},"content":[{"type":"text","text":"y"}]}}' >> "$tr"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"Done."}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  tok=$(python3 -c "import json;d=json.load(open('$home/sessions/claude-$sid.json'));t=d['tokens']['claude-sonnet-5'];print(t['in'],t['out'],d.get('usage_version'),d.get('usage_seen_ids'))")
  if [[ "$tok" == "111 121 2 ['msg_dup']" ]]; then pass "case hh: repeated message id counted once, also across scans (usage_version 2)"; else fail "case hh: dedupe tokens were '$tok'"; fi
  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"SessionEnd","reason":"other"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionEnd
  local last; last=$(tail -1 "$home/history.jsonl" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d['to'], d['reason'])")
  if [[ "$last" == "ended other" ]]; then pass "case hh: SessionEnd writes an ended line"; else fail "case hh: last history line was '$last'"; fi
}

# ---------------------------------------------------------------------------
# Case (ii): SPEC 17.7 - Codex transcript usage accounting. codex-rollout.jsonl
# has: session_meta, two turn_context lines with different models (a
# mid-session model switch), three token_count events (one with info:null,
# skipped; two with rate_limits at different used_percent), and a last line
# that is intentionally incomplete (no trailing newline). Checks per-model
# token sums, usage_offset advancing correctly across two Stop events (the
# second call must add only the newly-completed + brand-new lines, not
# double-count), and the shared codex-usage.json rate-limit snapshot.
# ---------------------------------------------------------------------------
run_case_ii() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="codex-usage-0001"
  local file="$home/sessions/codex-$sid.json"
  local tr="$home/codex-rollout.jsonl"
  cp "$REPO_ROOT/tests/fixtures/codex-rollout.jsonl" "$tr"

  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/codexproj","transcript_path":"'"$tr"'","hook_event_name":"SessionStart","source":"startup"}' \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event SessionStart
  assert_json_field "$file" model "gpt-5.6-sol-mini" "case ii: model resolved from the transcript's newest turn_context (mid-session model switch), not the older one"

  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/codexproj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"First turn done."}' \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event Stop

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
tok = d.get('tokens') or {}
a = tok.get('gpt-5.6-sol')
b = tok.get('gpt-5.6-sol-mini')
assert a == {'in': 5135, 'out': 188, 'cache_read': 7936, 'cache_write': 0}, a
assert b == {'in': 400, 'out': 50, 'cache_read': 100, 'cache_write': 10}, b
" 2>/dev/null; then
    pass "case ii: per-model token sums after the first Stop (info:null event skipped, tokens attributed to the model active at each event)"
  else
    fail "case ii: wrong per-model token sums after the first Stop"
  fi

  local offset1 filesize1
  offset1=$(python3 -c "import json; print(json.load(open('$file'))['usage_offset'])")
  filesize1=$(python3 -c "import os; print(os.path.getsize('$tr'))")
  if [[ "$offset1" -gt 0 && "$offset1" -lt "$filesize1" ]]; then
    pass "case ii: usage_offset stops before the incomplete trailing line (offset=$offset1 < file size=$filesize1)"
  else
    fail "case ii: usage_offset=$offset1 not strictly between 0 and file size=$filesize1"
  fi

  local usagefile="$home/codex-usage.json"
  if [[ -f "$usagefile" ]] && python3 -c "
import json
d = json.load(open('$usagefile'))
assert d.get('limit_name') == 'Test-Limit', d
assert d.get('plan_type') == 'pro', d
assert d.get('primary') == {'used_percent': 25.0, 'window_minutes': 300, 'resets_at': 1787239100}, d.get('primary')
assert d.get('secondary') == {'used_percent': 5.0, 'window_minutes': 10080, 'resets_at': 1787825900}, d.get('secondary')
assert d.get('updated')
" 2>/dev/null; then
    pass "case ii: codex-usage.json holds the newest rate_limits snapshot (25.0/5.0) after the first Stop, not the earlier 10.0/2.0"
  else
    fail "case ii: codex-usage.json missing or wrong after the first Stop"
  fi

  local mode; mode=$(stat -f %Lp "$usagefile" 2>/dev/null)
  if [[ "$mode" == "600" ]]; then
    pass "case ii: codex-usage.json is mode 600"
  else
    fail "case ii: codex-usage.json mode is '$mode', expected 600"
  fi

  # Grow the transcript: complete the previously-incomplete line, then add one
  # brand-new token_count line - the second Stop must add only these two.
  sleep 1.1 # guarantee codex-usage.json's next `updated` lands on a later wall-clock second
  cat >> "$tr" <<'CODEXGROWEOF'
1787239300},"secondary":{"used_percent":8.0,"window_minutes":10080,"resets_at":1787826200},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"pro","rate_limit_reached_type":null}}}
{"timestamp":"2026-08-19T09:17:15.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":0,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":0,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115},"model_context_window":258400},"rate_limits":{"limit_id":"codex_test","limit_name":"Test-Limit","primary":{"used_percent":41.0,"window_minutes":300,"resets_at":1787239400},"secondary":{"used_percent":8.5,"window_minutes":10080,"resets_at":1787826300},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"pro","rate_limit_reached_type":null}}}
CODEXGROWEOF

  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/codexproj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"Second turn done."}' \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event Stop

  if [[ -f "$file" ]] && python3 -c "
import json
d = json.load(open('$file'))
tok = d.get('tokens') or {}
a = tok.get('gpt-5.6-sol')
b = tok.get('gpt-5.6-sol-mini')
assert a == {'in': 5135, 'out': 188, 'cache_read': 7936, 'cache_write': 0}, a
assert b == {'in': 1180, 'out': 145, 'cache_read': 320, 'cache_write': 10}, b
" 2>/dev/null; then
    pass "case ii: second Stop adds only the newly-completed + brand-new line (no double counting of the first scan)"
  else
    fail "case ii: wrong per-model token sums after the second Stop"
  fi

  local offset2 filesize2
  offset2=$(python3 -c "import json; print(json.load(open('$file'))['usage_offset'])")
  filesize2=$(python3 -c "import os; print(os.path.getsize('$tr'))")
  if [[ "$offset2" == "$filesize2" ]]; then
    pass "case ii: usage_offset reaches end of file once every line is complete (offset=$offset2 == file size)"
  else
    fail "case ii: usage_offset=$offset2 != file size=$filesize2 after every line completed"
  fi

  if [[ -f "$usagefile" ]] && python3 -c "
import json
d = json.load(open('$usagefile'))
assert d.get('primary') == {'used_percent': 41.0, 'window_minutes': 300, 'resets_at': 1787239400}, d.get('primary')
assert d.get('secondary') == {'used_percent': 8.5, 'window_minutes': 10080, 'resets_at': 1787826300}, d.get('secondary')
" 2>/dev/null; then
    pass "case ii: codex-usage.json refreshed to the newest rate_limits snapshot after the second Stop (41.0/8.5)"
  else
    fail "case ii: codex-usage.json not refreshed after the second Stop"
  fi
}

run_case_jj() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")
  local sid="codex-permreq-0001"
  local file="$home/sessions/codex-$sid.json"
  echo '{"wait_seconds": 3}' > "$home/config.json"
  local payload='{"session_id":"'"$sid"'","turn_id":"turn-9","cwd":"/tmp/codexproj","hook_event_name":"PermissionRequest","tool_name":"shell","tool_input":{"command":"rm -rf node_modules","description":"clean build"}}'
  local outfile="$home/reporter-stdout.txt"

  ( printf '%s' "$payload" | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event PermissionRequest > "$outfile" ) &
  local reporter_pid=$!

  local req="" i
  for i in $(seq 1 150); do
    req=$(find "$home/requests" -maxdepth 1 -type f -name "codex-$sid-*.json" 2>/dev/null | head -n1)
    [[ -n "$req" ]] && break
    sleep 0.02
  done

  if [[ -n "$req" ]] && python3 -c "
import json
d = json.load(open('$req'))
assert d.get('agent') == 'codex', d
assert d.get('kind') == 'permission', d
assert d.get('tool_name') == 'shell', d
assert d.get('summary') == 'shell: rm -rf node_modules', d
assert d.get('command_or_path') == 'rm -rf node_modules', d
assert d.get('cwd') == '/tmp/codexproj', d
" 2>/dev/null; then
    pass "case jj: codex PermissionRequest request file has the command as summary (mirrors Claude case v)"
  else
    fail "case jj: codex request file missing or has wrong fields (${req:-<none>})"
  fi

  if [[ -n "$req" ]]; then
    local base; base=$(basename "$req")
    mkdir -p "$home/answers"
    printf '{"decision":"allow","answered_at":"2026-09-03T00:00:00Z"}' > "$home/answers/$base"
  fi

  wait "$reporter_pid"
  local out; out=$(cat "$outfile" 2>/dev/null)
  local expected='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
  if [[ "$out" == "$expected" ]]; then
    pass "case jj: codex PermissionRequest allow answer -> stdout is exactly the allow decision JSON (mirrors Claude case w)"
  else
    fail "case jj: expected exactly '$expected', got '$out'"
  fi

  assert_json_field "$file" state needs_you "case jj: codex PermissionRequest -> state=needs_you (same mapping as Claude)"
  assert_json_field "$file" request_id "" "case jj: codex state file request_id nulled after allow"
}

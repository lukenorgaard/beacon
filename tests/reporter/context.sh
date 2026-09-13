# Reporter regression cases: context. Sourced by ../test_reporter.sh.

# ---------------------------------------------------------------------------
# Case (ll): SPEC 19.1 - context measurement.
# (a) Claude: one message id spanning three content-block lines with
#     identical usage, after an older message with different usage -> the
#     sum of the LAST message's usage. (b) PostCompact clears context_tokens
#     and stamps context_compacted_at (context_window untouched); a later
#     Stop measures again. (c) Codex: two token_count events -> the LAST
#     one's input_tokens + model_context_window. (d) an unparseable/missing
#     tail leaves the prior values exactly as they were. (e) a transcript
#     bigger than 256 KB with the real line at the end still measures, and a
#     decoy usage line living only in the first part (well outside the tail
#     window) is ignored. (f) the four new keys land in RECORD_KEY_ORDER's
#     position in the written file (after the usage/tokens keys, before
#     transcript_path).
# ---------------------------------------------------------------------------
run_case_ll() {
  local home; home=$(mktemp -d); ALL_HOMES+=("$home")

  # --- (a) + (b): Claude dedup-by-last-message-wins, then PostCompact/Stop ---
  local sid="test-context-0001"
  local file="$home/sessions/claude-$sid.json"
  local tr="$home/ctx.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_old","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":9,"output_tokens":9,"cache_read_input_tokens":9,"cache_creation_input_tokens":9},"content":[{"type":"text","text":"old"}]}}' > "$tr"
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_new","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":56,"output_tokens":12,"cache_read_input_tokens":225577,"cache_creation_input_tokens":10795},"content":[{"type":"text","text":"a"}]}}' >> "$tr"
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_new","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":56,"output_tokens":12,"cache_read_input_tokens":225577,"cache_creation_input_tokens":10795},"content":[{"type":"tool_use","name":"Bash"}]}}' >> "$tr"
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_new","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":56,"output_tokens":12,"cache_read_input_tokens":225577,"cache_creation_input_tokens":10795},"content":[{"type":"text","text":"b"}]}}' >> "$tr"

  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"PostToolUse","tool_name":"Bash"}' \
    | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PostToolUse
  assert_json_field "$file" context_tokens 236428 "case ll(a): PostToolUse sums the LAST message's usage (56+10795+225577), not the older message's"
  assert_json_field "$file" context_window "" "case ll(a): context_window stays null for Claude"
  local at1; at1=$(python3 -c "import json;print(json.load(open('$file')).get('context_at') or '')")
  if [[ "$at1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    pass "case ll(a): context_at is a UTC ISO timestamp"
  else
    fail "case ll(a): context_at was '$at1'"
  fi

  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"PostCompact"}' \
    | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PostCompact
  assert_json_field "$file" context_tokens "" "case ll(b): PostCompact clears context_tokens"
  local cat; cat=$(python3 -c "import json;print(json.load(open('$file')).get('context_compacted_at') or '')")
  if [[ "$cat" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    pass "case ll(b): PostCompact stamps context_compacted_at"
  else
    fail "case ll(b): context_compacted_at was '$cat'"
  fi
  assert_json_field "$file" context_window "" "case ll(b): PostCompact leaves context_window (still null here) untouched"

  printf '%s' '{"session_id":"'"$sid"'","cwd":"/tmp/proj","transcript_path":"'"$tr"'","hook_event_name":"Stop","last_assistant_message":"Done."}' \
    | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  assert_json_field "$file" context_tokens 236428 "case ll(b): a following Stop measures again"

  # --- (c): Codex, two token_count events, last one wins for both fields ---
  local csid="test-context-codex-0001"
  local cfile="$home/sessions/codex-$csid.json"
  local ctr="$home/ctx-codex.jsonl"
  # Timestamps must be this session's own: a token_count older than started_at is a stale
  # transcript (case g) and is deliberately ignored.
  local ts_now; ts_now=$(python3 -c "import time;print(time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime()))")
  printf '%s\n' '{"timestamp":"'"$ts_now"'.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":20,"output_tokens":10},"model_context_window":128000}}}' > "$ctr"
  printf '%s\n' '{"timestamp":"'"$ts_now"'.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":777,"cached_input_tokens":50,"output_tokens":20},"model_context_window":258400}}}' >> "$ctr"

  printf '%s' '{"session_id":"'"$csid"'","cwd":"/tmp/codexproj","transcript_path":"'"$ctr"'","hook_event_name":"PostToolUse","tool_name":"shell"}' \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event PostToolUse
  assert_json_field "$cfile" context_tokens 777 "case ll(c): Codex context_tokens is the LAST token_count event's input_tokens (777, not 300)"
  assert_json_field "$cfile" context_window 258400 "case ll(c): Codex context_window is the LAST token_count event's model_context_window (258400, not 128000)"

  # --- (d): unparseable / missing tail leaves the prior values exactly ---
  printf '%s' '{"session_id":"'"$csid"'","cwd":"/tmp/codexproj","transcript_path":"'"$home"'/does-not-exist.jsonl","hook_event_name":"PostToolUse","tool_name":"shell"}' \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event PostToolUse
  assert_json_field "$cfile" context_tokens 777 "case ll(d): a missing transcript_path leaves context_tokens unchanged"
  assert_json_field "$cfile" context_window 258400 "case ll(d): a missing transcript_path leaves context_window unchanged"

  local garbage="$home/garbage.jsonl"
  printf 'not json at all\nneither is this\n' > "$garbage"
  printf '%s' '{"session_id":"'"$csid"'","cwd":"/tmp/codexproj","transcript_path":"'"$garbage"'","hook_event_name":"PostToolUse","tool_name":"shell"}' \
    | LOOKOUT_HOME="$home" "$REPORTER" --agent codex --event PostToolUse
  assert_json_field "$cfile" context_tokens 777 "case ll(d): an unparseable tail leaves context_tokens unchanged"
  assert_json_field "$cfile" context_window 258400 "case ll(d): an unparseable tail leaves context_window unchanged"

  # --- (e): transcript > 256 KB, decoy usage line only in the first part ---
  local bsid="test-context-big-0001"
  local bfile="$home/sessions/claude-$bsid.json"
  local btr="$home/ctx-big.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_decoy","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}},"content":"decoy"}' > "$btr"
  python3 -c "
line = '{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"' + ('x' * 500) + '\"}}\n'
with open('$btr', 'a') as f:
    for _ in range(600):
        f.write(line)
"
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_final","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":4000,"output_tokens":1,"cache_read_input_tokens":900,"cache_creation_input_tokens":100}},"content":"final"}' >> "$btr"

  local bsize; bsize=$(python3 -c "import os;print(os.path.getsize('$btr'))")
  if [[ "$bsize" -gt 262144 ]]; then
    pass "case ll(e): setup - fixture transcript is bigger than 256 KB ($bsize bytes)"
  else
    fail "case ll(e): setup - fixture transcript is only $bsize bytes, need > 262144"
  fi

  printf '%s' '{"session_id":"'"$bsid"'","cwd":"/tmp/proj","transcript_path":"'"$btr"'","hook_event_name":"Stop","last_assistant_message":"Done."}' \
    | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  assert_json_field "$bfile" context_tokens 5000 "case ll(e): the line at the end of a >256 KB transcript still measures (4000+100+900), the first-part decoy (1+2+3) is ignored"

  # --- (f): the four keys land at RECORD_KEY_ORDER's position in the file ---
  if python3 -c "
import json
d = json.load(open('$file'), object_pairs_hook=lambda pairs: [k for k, _ in pairs])
i_seen = d.index('usage_seen_ids')
i_ctx_tokens = d.index('context_tokens')
i_ctx_window = d.index('context_window')
i_ctx_at = d.index('context_at')
i_ctx_compacted = d.index('context_compacted_at')
i_transcript = d.index('transcript_path')
assert i_seen < i_ctx_tokens < i_ctx_window < i_ctx_at < i_ctx_compacted < i_transcript, d
" 2>/dev/null; then
    pass "case ll(f): context_tokens/context_window/context_at/context_compacted_at sit between usage_seen_ids and transcript_path in the written file"
  else
    fail "case ll(f): key order wrong in $file"
  fi

  # (g) A transcript that stopped being written (CLAUDE_CODE_CHILD_SESSION:
  #     "Transcript saving is off"): its newest assistant line predates this
  #     session's started_at -> no context (None), and the stale line's model
  #     is not taken either. A fresh timestamped line measures normally.
  local sid_g="ctx-stale-0001"; local file_g="$home/sessions/claude-$sid_g.json"; local tr_g="$home/stale.jsonl"
  printf '%s\n' '{"timestamp":"2026-01-01T10:00:00.000Z","type":"assistant","message":{"id":"msg_old","role":"assistant","model":"claude-opus-5","usage":{"input_tokens":400000,"output_tokens":10,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"old"}]}}' > "$tr_g"
  printf '%s' '{"session_id":"'"$sid_g"'","cwd":"/tmp/proj","transcript_path":"'"$tr_g"'","hook_event_name":"SessionStart","source":"startup"}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event SessionStart
  printf '%s' '{"session_id":"'"$sid_g"'","cwd":"/tmp/proj","transcript_path":"'"$tr_g"'","hook_event_name":"Stop","last_assistant_message":"Done."}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  local stale; stale=$(python3 -c "import json;d=json.load(open('$file_g'));print(d.get('context_tokens'), d.get('model'))")
  if [[ "$stale" == "None None" ]]; then pass "case ll(g): a transcript older than started_at yields no context and no model"; else fail "case ll(g): stale transcript gave '$stale'"; fi
  local fresh_ts; fresh_ts=$(python3 -c "import datetime;print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z'))")
  printf '%s\n' '{"timestamp":"'"$fresh_ts"'","type":"assistant","message":{"id":"msg_new","role":"assistant","model":"claude-fable-5-1","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":200000,"cache_creation_input_tokens":5000},"content":[{"type":"text","text":"new"}]}}' >> "$tr_g"
  printf '%s' '{"session_id":"'"$sid_g"'","cwd":"/tmp/proj","transcript_path":"'"$tr_g"'","hook_event_name":"Stop","last_assistant_message":"Done."}' | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event Stop
  local fresh; fresh=$(python3 -c "import json;d=json.load(open('$file_g'));print(d.get('context_tokens'), d.get('model'))")
  if [[ "$fresh" == "205050 claude-fable-5-1" ]]; then pass "case ll(g): a fresh line measures again and names the model"; else fail "case ll(g): fresh transcript gave '$fresh'"; fi

  # (h) SPEC 19.1 hardening: a usage field that is an object (not a number) used to raise
  #     `int(x or 0)` straight out of the hook - the exception escaped run_hook_mode and the
  #     record was never written for that event (or any event after it, until the reporter
  #     process next happened to avoid the bad line). Fixed: the bad line is skipped for context
  #     measurement (context_tokens stays exactly as it was), and the state file write for the
  #     same event still happens normally - PostToolUse (like case ll(a)), so this exercises
  #     exactly the fixed code path (measure_context) without also touching accumulate_usage's
  #     own, separate per-model summation (Stop-only, and not part of this fix).
  local sid_h="ctx-object-0001"; local file_h="$home/sessions/claude-$sid_h.json"; local tr_h="$home/object.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_good","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":20,"cache_creation_input_tokens":5}},"content":"good"}' > "$tr_h"
  printf '%s' '{"session_id":"'"$sid_h"'","cwd":"/tmp/proj","transcript_path":"'"$tr_h"'","hook_event_name":"PostToolUse","tool_name":"Bash"}' \
    | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PostToolUse
  assert_json_field "$file_h" context_tokens 35 "case ll(h): setup - a normal usage line measures (10+5+20)"
  assert_json_field "$file_h" detail "Bash" "case ll(h): setup - PostToolUse records the tool name"

  printf '%s\n' '{"type":"assistant","message":{"id":"msg_bad","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":{"nested":"object"},"output_tokens":1,"cache_read_input_tokens":20,"cache_creation_input_tokens":5}},"content":"bad"}' >> "$tr_h"
  printf '%s' '{"session_id":"'"$sid_h"'","cwd":"/tmp/proj","transcript_path":"'"$tr_h"'","hook_event_name":"PostToolUse","tool_name":"Write"}' \
    | LOOKOUT_HOME="$home" CLAUDE_PID=$$ "$REPORTER" --agent claude --event PostToolUse
  assert_json_field "$file_h" context_tokens 35 "case ll(h): a non-numeric usage field is skipped - context_tokens stays exactly as it was"
  assert_json_field "$file_h" detail "Write" "case ll(h): the state file still writes on the same event - a bad usage value never freezes the row"
}

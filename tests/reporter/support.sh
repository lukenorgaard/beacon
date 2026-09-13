# Shared helpers for the reporter integration suite.
REPORTER="$REPO_ROOT/hooks/lookout-report.py"
INSTALLER="$REPO_ROOT/scripts/install-hooks.py"
FIXTURE_LOG="$REPO_ROOT/tests/fixtures/claude-hook-payloads.log"

PASS=0
FAIL=0
ALL_HOMES=()

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# assert_json_field <file> <field> <expected> <label>
assert_json_field() {
  local file="$1" field="$2" expected="$3" label="$4"
  if [[ ! -f "$file" ]]; then
    fail "$label (file missing: $file)"
    return
  fi
  local actual
  actual=$(python3 -c "
import json
d = json.load(open('$file'))
v = d.get('$field')
print('' if v is None else v)
" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected' got '$actual')"
  fi
}

assert_file_absent() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    fail "$label (file still exists: $file)"
  else
    pass "$label"
  fi
}

assert_file_present() {
  local file="$1" label="$2"
  if [[ -f "$file" ]]; then
    pass "$label"
  else
    fail "$label (file missing: $file)"
  fi
}

# answer_after_request <home> <agent> <sid> <decision> [extra_delay]
# Waits for the request file the reporter under test is about to write under
# $home/requests/<agent>-<sid>-*.json (it writes that file, and the state
# file, *before* it starts polling for an answer - SPEC 11.3 - precisely so
# an external answerer never has to guess the request_id), then writes the
# matching answer file `extra_delay` seconds later. Meant to be run with `&`
# concurrently with the reporter invocation under test.
answer_after_request() {
  local home="$1" agent="$2" sid="$3" decision="$4" extra_delay="${5:-0.3}"
  local req="" i
  for i in $(seq 1 150); do
    req=$(find "$home/requests" -maxdepth 1 -type f -name "$agent-$sid-*.json" 2>/dev/null | head -n1)
    [[ -n "$req" ]] && break
    sleep 0.02
  done
  if [[ -z "$req" ]]; then
    return 1
  fi
  sleep "$extra_delay"
  local base; base=$(basename "$req")
  mkdir -p "$home/answers"
  printf '{"decision":"%s","answered_at":"2026-09-02T00:00:00Z"}' "$decision" > "$home/answers/$base"
}

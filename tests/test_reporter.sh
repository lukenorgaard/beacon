#!/usr/bin/env bash
# End-to-end tests for hooks/lookout-report.py and scripts/install-hooks.py.
# Every case uses a temp LOOKOUT_HOME and temp copies of config files; this
# script never touches ~/.lookout, ~/.claude/settings.json or ~/.codex/hooks.json,
# and never prints or stores the process environment (it only ever passes a
# small number of explicit, non-secret env vars like CLAUDE_PID=$$ to the
# reporter under test).
set -uo pipefail


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/tests/reporter/support.sh"
source "$REPO_ROOT/tests/reporter/lifecycle.sh"
source "$REPO_ROOT/tests/reporter/installer.sh"
source "$REPO_ROOT/tests/reporter/manual.sh"
source "$REPO_ROOT/tests/reporter/identity.sh"
source "$REPO_ROOT/tests/reporter/subagents.sh"
source "$REPO_ROOT/tests/reporter/requests.sh"
source "$REPO_ROOT/tests/reporter/metadata.sh"
source "$REPO_ROOT/tests/reporter/usage.sh"
source "$REPO_ROOT/tests/reporter/context.sh"

run_case_a
run_case_b
run_case_c
run_case_d
run_case_e
run_case_f
run_case_h
run_case_i
run_case_j
run_case_k
run_case_l
run_case_m
run_case_n
run_case_o
run_case_p
run_case_q
run_case_r
run_case_s
run_case_t
run_case_u
run_case_v
run_case_w
run_case_x
run_case_y
run_case_z
run_case_aa
run_case_bb
run_case_cc
run_case_dd
run_case_ee
run_case_ff
run_case_gg
run_case_hh
run_case_ii
run_case_jj
run_case_kk
run_case_ll
if python3 -m unittest discover -s "$REPO_ROOT/tests/reporter" -p 'test_*.py'; then
  pass "usage-parser failure recovery and hook configuration"
else
  fail "usage-parser failure recovery and hook configuration"
fi

run_case_g # last: scans every temp home created above before cleanup

for h in "${ALL_HOMES[@]}"; do
  rm -rf "$h" 2>/dev/null
done

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]

"""Parse command-line options and dispatch the reporting mode."""

import os
import sys
from .common import (
    is_valid_agent_name,
    log_error,
    lookout_home_path,
    resolve_agent_auto,
)
from .hook import (
    run_hook_mode,
)
from .manual import (
    run_manual_mode,
)


# --- CLI parsing ------------------------------------------------------------

_KEY_FLAGS = (
    "agent", "event", "matcher", "set", "session", "cwd", "title", "detail",
    "message", "pid",
)


def parse_args(argv):
    out = {}
    i = 0
    n = len(argv)
    while i < n:
        a = argv[i]
        if a == "--end":
            out["end"] = True
            i += 1
            continue
        matched = False
        for flag in _KEY_FLAGS:
            opt = "--" + flag
            if a == opt and i + 1 < n:
                out[flag] = argv[i + 1]
                i += 2
                matched = True
                break
            prefix = opt + "="
            if a.startswith(prefix):
                out[flag] = a[len(prefix):]
                i += 1
                matched = True
                break
        if not matched:
            i += 1
    return out


def main():
    # A helper process (e.g. Lookout's own suggestion call through `claude -p`) must never show
    # up as a session: bail out before touching anything.
    if os.environ.get("LOOKOUT_IGNORE") == "1":
        return 0

    parsed = parse_args(sys.argv[1:])
    lookout_home = lookout_home_path()

    agent_raw = parsed.get("agent")
    agent = resolve_agent_auto(os.environ) if agent_raw == "auto" else agent_raw

    if not is_valid_agent_name(agent):
        log_error(lookout_home, "invalid or missing --agent: %r" % (agent_raw,))
        return 0

    manual_mode = bool(parsed.get("end")) or (parsed.get("set") is not None)
    if manual_mode:
        return run_manual_mode(agent, parsed, lookout_home)
    return run_hook_mode(agent, parsed, lookout_home)

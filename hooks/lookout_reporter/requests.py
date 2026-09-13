"""Permission and question requests, answers and stale-request cleanup."""

import calendar
import json
import os
import time
from .common import (
    _iso_to_epoch,
    ensure_private_dir,
    require_file_ids,
    truncate_collapse,
)
from .storage import (
    load_existing,
    write_json_atomic,
    write_ordered,
)


# --- detail extraction ---------------------------------------------------------

def make_permission_detail(payload):
    tool_name = payload.get("tool_name")
    tool_name = tool_name if isinstance(tool_name, str) else ""
    tool_input = payload.get("tool_input")
    short = None
    if isinstance(tool_input, dict):
        for key in ("command", "file_path", "description"):
            v = tool_input.get(key)
            if isinstance(v, str) and v.strip():
                short = v.strip()
                break
    if tool_name and short:
        detail = "%s: %s" % (tool_name, short)
    elif tool_name:
        detail = tool_name
    elif short:
        detail = short
    else:
        detail = ""
    return truncate_collapse(detail, 120)


def extract_question_detail(tool_input):
    if isinstance(tool_input, dict):
        questions = tool_input.get("questions")
        if isinstance(questions, list) and questions:
            q0 = questions[0]
            if isinstance(q0, dict):
                qt = q0.get("question")
                if isinstance(qt, str) and qt.strip():
                    return truncate_collapse(qt, 120)
            elif isinstance(q0, str) and q0.strip():
                return truncate_collapse(q0, 120)
        qt = tool_input.get("question")
        if isinstance(qt, str) and qt.strip():
            return truncate_collapse(qt, 120)
    return ""


# --- permission / question request files (SPEC 11.3) -------------------------

REQUEST_MAX_AGE_SECONDS = 6 * 60 * 60


def make_command_or_path(payload):
    """Full command / file_path / description behind a permission ask,
    capped at 2000 chars (unlike the 120-char `summary`, this is meant to be
    read in full in the AttentionCard's monospaced box - SPEC 11.4)."""
    tool_input = payload.get("tool_input")
    text = None
    if isinstance(tool_input, dict):
        for key in ("command", "file_path", "description"):
            v = tool_input.get(key)
            if isinstance(v, str) and v.strip():
                text = v.strip()
                break
    return truncate_collapse(text or "", 2000)


def extract_question_options(tool_input):
    """Option labels from tool_input.questions[0].options[].label (also
    accepts bare strings, for robustness against older/other payload
    shapes)."""
    if not isinstance(tool_input, dict):
        return []
    questions = tool_input.get("questions")
    if not isinstance(questions, list) or not questions:
        return []
    q0 = questions[0]
    if not isinstance(q0, dict):
        return []
    opts = q0.get("options")
    if not isinstance(opts, list):
        return []
    labels = []
    for o in opts:
        if isinstance(o, dict):
            label = o.get("label")
            if isinstance(label, str) and label.strip():
                labels.append(label.strip())
        elif isinstance(o, str) and o.strip():
            labels.append(o.strip())
    return labels


def make_request_id():
    """8 hex chars derived from time+pid (SPEC 11.3). Only used to name a
    request/answer file pair - not a security token."""
    raw = (int(time.time() * 1_000_000) ^ os.getpid()) & 0xFFFFFFFF
    return "%08x" % raw


def iso_from_epoch(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def read_wait_seconds(lookout_home):
    """`wait_seconds` from $LOOKOUT_HOME/config.json, default 45, clamped to
    0..110 (0 = do not wait). Any read/parse problem falls back to the
    default - a bad config.json must never make the reporter hang or crash."""
    value = 45
    try:
        with open(os.path.join(lookout_home, "config.json"), "r", encoding="utf-8") as f:
            data = json.load(f)
        raw = data.get("wait_seconds") if isinstance(data, dict) else None
        if isinstance(raw, bool):
            raw = None
        if isinstance(raw, (int, float)):
            value = int(raw)
    except Exception:
        value = 45
    if value < 0:
        value = 0
    if value > 110:
        value = 110
    return value


def request_file_path(lookout_home, agent, session_id, request_id):
    require_file_ids(agent, session_id, request_id)
    return os.path.join(lookout_home, "requests", "%s-%s-%s.json" % (agent, session_id, request_id))


def answer_file_path(lookout_home, agent, session_id, request_id):
    require_file_ids(agent, session_id, request_id)
    return os.path.join(lookout_home, "answers", "%s-%s-%s.json" % (agent, session_id, request_id))


def _remove_quiet(path):
    try:
        os.remove(path)
    except OSError:
        pass


def remove_session_requests(lookout_home, agent, session_id, keep=None):
    """Delete every request and answer file of this session except `keep`.
    A question file that outlives its answer is a live bug: the card attached
    a six-hour-old question to a later "done" card and the user's click was
    sent into the session as a fresh message (2026-09-04)."""
    prefix = "%s-%s-" % (agent, session_id)
    for sub in ("requests", "answers"):
        d = os.path.join(lookout_home, sub)
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for name in names:
            if not name.startswith(prefix) or not name.endswith(".json"):
                continue
            rid = name[len(prefix):-len(".json")]
            if keep and rid == keep:
                continue
            _remove_quiet(os.path.join(d, name))


def prune_or_clear_stale_request(record, lookout_home, agent, session_id):
    """Runs on every hook event, before any new request below is written.
    Clears a leftover `request_id` (permission or question) once the state
    has left needs_you, or once the request file itself is older than 6h -
    whichever a later event notices first. Never touches state/reason/detail."""
    rid = record.get("request_id")
    if not rid:
        if record.get("state") != "needs_you":
            remove_session_requests(lookout_home, agent, session_id)
        return
    req_path = request_file_path(lookout_home, agent, session_id, rid)
    clear = record.get("state") != "needs_you"
    # Orphans from an earlier question that was replaced before it was cleared.
    remove_session_requests(lookout_home, agent, session_id, keep=rid)
    if not clear:
        req = load_existing(req_path)
        if req is None:
            clear = True
        else:
            created_epoch = _iso_to_epoch(req.get("created_at"))
            now_epoch = calendar.timegm(time.gmtime())
            if created_epoch is not None and (now_epoch - created_epoch) > REQUEST_MAX_AGE_SECONDS:
                clear = True
    if clear:
        remove_session_requests(lookout_home, agent, session_id)
        record["request_id"] = None
        record["request_summary"] = None


def write_question_request(record, agent, session_id, payload, now, lookout_home):
    """PreToolUse / AskUserQuestion (SPEC 11.3): write a `question` request
    file, no waiting - the card offers Send/Copy & go, never a hook
    decision."""
    tool_input = payload.get("tool_input")
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    question = extract_question_detail(tool_input)
    options = extract_question_options(tool_input)
    request_id = make_request_id()
    req = {
        "schema": 1,
        "agent": agent,
        "session_id": session_id,
        "request_id": request_id,
        "kind": "question",
        "question": question,
        "options": options,
        "cwd": payload.get("cwd") if isinstance(payload.get("cwd"), str) else None,
        "created_at": now,
    }
    ensure_private_dir(os.path.join(lookout_home, "requests"))
    ensure_private_dir(os.path.join(lookout_home, "answers"))
    write_json_atomic(request_file_path(lookout_home, agent, session_id, request_id), req)
    record["request_id"] = request_id
    record["request_summary"] = question


def handle_permission_request(record, agent, session_id, payload, lookout_home, file_path):
    """PermissionRequest (SPEC 11.3): write a `permission` request file,
    publish it in the state file immediately, then (unless wait_seconds is
    0) poll for an answer until `waits_until`. Prints the hook decision
    JSON - the ONLY thing this process ever writes to stdout - and only for
    allow/deny. Always returns 0 (the process exit code)."""
    tool_name = payload.get("tool_name")
    tool_name = tool_name if isinstance(tool_name, str) else None
    summary = make_permission_detail(payload)
    command_or_path = make_command_or_path(payload)
    request_id = make_request_id()
    created_epoch = time.time()
    wait_seconds = read_wait_seconds(lookout_home)
    waits_until_epoch = created_epoch + wait_seconds

    req = {
        "schema": 1,
        "agent": agent,
        "session_id": session_id,
        "request_id": request_id,
        "kind": "permission",
        "tool_name": tool_name,
        "summary": summary,
        "command_or_path": command_or_path,
        "cwd": payload.get("cwd") if isinstance(payload.get("cwd"), str) else None,
        "created_at": iso_from_epoch(created_epoch),
        "waits_until": iso_from_epoch(waits_until_epoch),
    }
    ensure_private_dir(os.path.join(lookout_home, "requests"))
    ensure_private_dir(os.path.join(lookout_home, "answers"))
    req_path = request_file_path(lookout_home, agent, session_id, request_id)
    write_json_atomic(req_path, req)

    record["request_id"] = request_id
    record["request_summary"] = summary
    # Written before waiting so the app sees the request immediately.
    write_ordered(file_path, record)

    if wait_seconds <= 0:
        # "0 = do not wait": no poll, no cleanup here - a later event
        # (PostToolUse/Stop/SessionEnd, or the 6h prune) clears it.
        return 0

    ans_path = answer_file_path(lookout_home, agent, session_id, request_id)
    decision = None
    while time.time() < waits_until_epoch:
        ans = load_existing(ans_path)
        if isinstance(ans, dict):
            d = ans.get("decision")
            if d in ("allow", "deny", "pass"):
                decision = d
                break
        time.sleep(0.1)

    _remove_quiet(req_path)
    _remove_quiet(ans_path)
    record["request_id"] = None
    record["request_summary"] = None
    write_ordered(file_path, record)

    if decision in ("allow", "deny"):
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": decision},
            }
        }
        # The ONLY stdout this process ever produces (audited - every other
        # diagnostic goes through log_error to reporter.log).
        print(json.dumps(output, separators=(",", ":")))
    return 0


def _cleanup_session_requests(lookout_home, agent, session_id):
    """SessionEnd: remove any leftover request/answer file for this session,
    regardless of whether we know its request_id."""
    prefix = "%s-%s-" % (agent, session_id)
    for sub in ("requests", "answers"):
        d = os.path.join(lookout_home, sub)
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for name in names:
            if name.startswith(prefix) and name.endswith(".json"):
                _remove_quiet(os.path.join(d, name))

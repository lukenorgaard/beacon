"""Atomic session files, messaging tokens, session locks and transition history."""

import fcntl
import json
import os
import time
from .common import (
    ensure_private_dir,
    log_error,
    require_file_ids,
    truncate_collapse,
)


# --- session file I/O ---------------------------------------------------------

RECORD_KEY_ORDER = [
    "schema", "agent", "session_id", "state", "reason", "detail",
    "request_id", "request_summary",
    "cwd", "origin_cwd", "active_cwd", "worktree",
    "project", "title", "desktop_title", "model", "provider", "last_message", "background_tasks", "pid", "tty", "host", "host_pid",
    "host_ref", "shell_pid", "entrypoint", "messaging_socket", "tokens", "usage_offset", "usage_version", "usage_seen_ids",
    "context_tokens", "context_window", "context_at", "context_compacted_at", "transcript_path", "started_at", "state_since",
    "updated_at", "subagents", "pending_agents",
]


def session_file_path(lookout_home, agent, session_id):
    require_file_ids(agent, session_id)
    return os.path.join(lookout_home, "sessions", "%s-%s.json" % (agent, session_id))


def load_existing(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def write_json_atomic(path, obj):
    """Atomic write (SPEC 3: 'atomic write') shared by session records and
    the request files under $LOOKOUT_HOME/requests/ (SPEC 11.3): write a
    `.tmp.<pid>` file, chmod 600, then os.replace."""
    tmp_path = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
    try:
        os.chmod(tmp_path, 0o600)
    except Exception:
        pass
    os.replace(tmp_path, path)


def write_ordered(path, record):
    ordered = {k: record.get(k) for k in RECORD_KEY_ORDER}
    write_json_atomic(path, ordered)


_LOCK_HANDLES = []


def acquire_session_lock(file_path, timeout=3.0):
    """Serialise read-modify-write per session. Several hooks fire at the same instant
    (PreToolUse + SubagentStart, PostToolUse + SubagentStop) and without this one update
    silently overwrote the other. Held until the process exits; never blocks past `timeout`."""
    lock_path = file_path + ".lock"
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError:
        return False
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            _LOCK_HANDLES.append(fd)
            return True
        except OSError:
            if time.monotonic() >= deadline:
                os.close(fd)
                return False
            time.sleep(0.01)


def token_file_path(lookout_home, agent, session_id):
    require_file_ids(agent, session_id)
    return os.path.join(lookout_home, "tokens", "%s-%s.token" % (agent, session_id))


def store_messaging_token(lookout_home, agent, session_id, token):
    if not isinstance(token, str) or not token.strip():
        return
    path = token_file_path(lookout_home, agent, session_id)
    try:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                if f.read() == token:
                    return
        ensure_private_dir(os.path.join(lookout_home, "tokens"))
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(token)
        os.replace(tmp, path)
    except OSError:
        pass


def remove_messaging_token(lookout_home, agent, session_id):
    try:
        os.remove(token_file_path(lookout_home, agent, session_id))
    except OSError:
        pass


HISTORY_MAX_BYTES = 5 * 1024 * 1024


def cap_text(value, limit):
    """History fields are capped one by one so the JSON line never has to be cut."""
    if not isinstance(value, str):
        return None
    return truncate_collapse(value, limit)


def append_history(lookout_home, agent, session_id, record, prev_state, new_state, reason, detail, last_message, now):
    """One line per state transition (SPEC §17.5), rotated at 5 MB."""
    line = {
        "ts": now, "agent": agent, "session_id": session_id,
        "project": cap_text(record.get("project"), 80),
        "name": cap_text(record.get("desktop_title") or record.get("title"), 100),
        "from": prev_state, "to": new_state, "reason": reason,
        "detail": truncate_collapse(detail, 120) if isinstance(detail, str) else None,
        "last_message": truncate_collapse(last_message, 160) if isinstance(last_message, str) else None,
    }
    path = os.path.join(lookout_home, "history.jsonl")
    try:
        ensure_private_dir(lookout_home)
        try:
            if os.path.getsize(path) > HISTORY_MAX_BYTES:
                os.replace(path, os.path.join(lookout_home, "history.1.jsonl"))
        except OSError:
            pass
        with open(path, "a", encoding="utf-8") as f:
            # Every field is capped above; the serialised line itself is never cut, because a
            # cut JSON line is an unreadable line (SPEC 17.5).
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
    except OSError:
        pass


def delete_session_file(path, lookout_home):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    except Exception as e:
        log_error(lookout_home, "failed to remove session file: %s" % type(e).__name__)

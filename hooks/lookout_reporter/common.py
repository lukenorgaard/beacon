"""Agent validation, text helpers, private directories and safe diagnostic logging."""

import calendar
import os
import time


STATE_FILE_SCHEMA = 1


# --- agent name validation -------------------------------------------------

_AGENT_NAME_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789_-")


def is_valid_agent_name(name):
    if not isinstance(name, str):
        return False
    if not (1 <= len(name) <= 32):
        return False
    return all(c in _AGENT_NAME_CHARS for c in name)


def is_valid_file_id(value):
    """IDs become a single filename component, never a path or a glob."""
    return (isinstance(value, str) and 1 <= len(value) <= 160
            and value not in {".", ".."}
            and all(c.isascii() and (c.isalnum() or c in "_.-") for c in value))


def require_file_ids(*values):
    if not all(is_valid_file_id(value) for value in values):
        raise ValueError("invalid file identifier")


def resolve_agent_auto(env):
    """--agent auto: claude when CLAUDECODE=1, codex when any CODEX_* env var
    is present, else unknown. Only ever inspects env var *names* here plus
    the single CLAUDECODE value check below - never logged, never stored."""
    if env.get("CLAUDECODE") == "1":
        return "claude"
    for k in env.keys():
        if k.startswith("CODEX_"):
            return "codex"
    return "unknown"


# --- small text helpers ------------------------------------------------------

def ends_with_question(text):
    """True when the assistant's last message ends by asking something: trailing
    whitespace, markdown emphasis and closing quotes/brackets are ignored."""
    t = text.rstrip().rstrip("*_`\"')]") .rstrip()
    return t.endswith("?")


def truncate_collapse(s, limit):
    if not isinstance(s, str):
        return ""
    collapsed = " ".join(s.split())
    return collapsed[:limit]


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --- LOOKOUT_HOME / logging ---------------------------------------------------

def lookout_home_path():
    return os.environ.get("LOOKOUT_HOME") or os.path.expanduser("~/.lookout")


def ensure_private_dir(path):
    try:
        if not os.path.isdir(path):
            os.makedirs(path, exist_ok=True)
        os.chmod(path, 0o700)
    except Exception:
        pass


def rotate_log_if_needed(log_path, max_bytes=200_000):
    try:
        if os.path.getsize(log_path) > max_bytes:
            old_path = log_path + ".old"
            try:
                os.replace(log_path, old_path)
            except Exception:
                try:
                    os.remove(log_path)
                except Exception:
                    pass
    except FileNotFoundError:
        pass
    except Exception:
        pass


def log_error(lookout_home, message):
    # message must never contain env var values or full payload dumps.
    try:
        ensure_private_dir(lookout_home)
        log_path = os.path.join(lookout_home, "reporter.log")
        rotate_log_if_needed(log_path)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (now_iso(), message))
    except Exception:
        pass


def _iso_to_epoch(ts):
    if not isinstance(ts, str):
        return None
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None

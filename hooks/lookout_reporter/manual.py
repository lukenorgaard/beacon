"""Manual session reporting for agents without native hooks."""

import os
from .common import (
    STATE_FILE_SCHEMA,
    ensure_private_dir,
    is_valid_file_id,
    log_error,
    now_iso,
    truncate_collapse,
)
from .identity import (
    build_ps_map,
    normalize_tty,
    resolve_entrypoint,
    resolve_host,
    resolve_host_ref,
)
from .storage import (
    acquire_session_lock,
    delete_session_file,
    load_existing,
    session_file_path,
    write_ordered,
)


# --- manual mode (--set / --end) ------------------------------------------------

VALID_MANUAL_STATES = {"idle", "working", "needs_you", "done", "running"}


def run_manual_mode(agent, parsed, lookout_home):
    session_id = parsed.get("session")
    if not is_valid_file_id(session_id):
        log_error(lookout_home, "manual mode requires a valid --session")
        return 0

    sessions_dir = os.path.join(lookout_home, "sessions")
    file_path = session_file_path(lookout_home, agent, session_id)

    if parsed.get("end"):
        delete_session_file(file_path, lookout_home)
        return 0

    state = parsed.get("set")
    if state not in VALID_MANUAL_STATES:
        log_error(lookout_home, "invalid --set state: %r" % (state,))
        return 0

    ensure_private_dir(lookout_home)
    ensure_private_dir(sessions_dir)

    acquire_session_lock(file_path)
    existing = load_existing(file_path)
    record = existing if isinstance(existing, dict) else {}
    old_state = record.get("state")
    now = now_iso()

    record.setdefault("schema", STATE_FILE_SCHEMA)
    record["agent"] = agent
    record["session_id"] = session_id
    if not record.get("started_at"):
        record["started_at"] = now

    cwd = parsed.get("cwd") or os.environ.get("PWD") or os.getcwd()
    if isinstance(cwd, str) and cwd:
        record["cwd"] = cwd
        record["project"] = os.path.basename(cwd.rstrip("/")) or cwd

    pid_arg = parsed.get("pid")
    pid = None
    if pid_arg is not None:
        try:
            pid = int(pid_arg)
        except (TypeError, ValueError):
            pid = None
    if pid is None:
        pid = os.getppid()
    record["pid"] = pid

    env = os.environ
    ps_map = build_ps_map()

    entry = ps_map.get(pid)
    tty = normalize_tty(entry[1]) if entry else None
    if tty is not None:
        record["tty"] = tty
    elif "tty" not in record:
        record["tty"] = None

    host, host_pid = resolve_host(agent, env, ps_map, pid)
    if host and host != "unknown":
        record["host"] = host
    elif not record.get("host"):
        record["host"] = "unknown"
    if host_pid is not None:
        record["host_pid"] = host_pid
    elif "host_pid" not in record:
        record["host_pid"] = None

    href = resolve_host_ref(agent, env)
    if href:
        record["host_ref"] = href

    record["entrypoint"] = resolve_entrypoint(agent, env)

    if parsed.get("title"):
        record["title"] = truncate_collapse(parsed["title"], 80)
    if parsed.get("detail"):
        record["detail"] = truncate_collapse(parsed["detail"], 120)
    if parsed.get("message"):
        record["last_message"] = truncate_collapse(parsed["message"], 160)

    record["state"] = state
    record["reason"] = "manual"
    if state != old_state:
        record["state_since"] = now
    if not record.get("state_since"):
        record["state_since"] = now
    record["updated_at"] = now

    write_ordered(file_path, record)
    return 0

"""Orchestrate hook input, session state updates and session-end cleanup."""

import json
import os
import sys
from .common import (
    _iso_to_epoch,
    STATE_FILE_SCHEMA,
    ensure_private_dir,
    is_valid_file_id,
    log_error,
    now_iso,
)
from .context import (
    measure_context,
)
from .events import (
    apply_event,
)
from .identity import (
    build_ps_map,
    resolve_agent_pid_tty,
    resolve_entrypoint,
    resolve_host,
    resolve_host_ref,
    resolve_shell_pid,
)
from .requests import (
    _cleanup_session_requests,
    handle_permission_request,
    prune_or_clear_stale_request,
    remove_session_requests,
    write_question_request,
)
from .storage import (
    acquire_session_lock,
    append_history,
    delete_session_file,
    load_existing,
    remove_messaging_token,
    session_file_path,
    store_messaging_token,
    write_ordered,
)
from .subagents import (
    apply_subagent_event,
)
from .transcript import (
    cap_len,
    read_codex_model,
    read_codex_transcript_model,
    read_custom_title,
    read_transcript_model,
    resolve_provider,
    worktree_basename,
)
from .usage import (
    accumulate_usage,
)


# --- hook mode (stdin JSON) ----------------------------------------------------

def run_hook_mode(agent, parsed, lookout_home):
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""

    payload = None
    if raw and raw.strip():
        try:
            payload = json.loads(raw)
        except Exception:
            payload = None

    if not isinstance(payload, dict):
        log_error(lookout_home, "invalid or empty stdin JSON")
        return 0

    session_id = payload.get("session_id")
    if not is_valid_file_id(session_id):
        log_error(lookout_home, "missing or invalid session_id in payload")
        return 0

    event = parsed.get("event") or payload.get("hook_event_name")
    if not event:
        log_error(lookout_home, "missing event name")
        return 0

    sessions_dir = os.path.join(lookout_home, "sessions")
    file_path = session_file_path(lookout_home, agent, session_id)

    if event == "SessionEnd":
        acquire_session_lock(file_path)
        ended = load_existing(file_path)
        if isinstance(ended, dict):
            try:
                accumulate_usage(ended, agent, lookout_home)
            except Exception as exc:  # noqa: BLE001 - the record must still be written
                log_error(lookout_home, "accumulate_usage failed: %s" % type(exc).__name__)
            try:
                # A measurement must never stop SessionEnd's own history line/cleanup below
                # (SPEC 19.1 hardening - see _usage_field_is_numeric's doc comment).
                measure_context(ended, agent, ended.get("transcript_path"))
            except Exception:
                log_error(lookout_home, "measure_context failed at session end")
            append_history(lookout_home, agent, session_id, ended, ended.get("state"), "ended",
                           payload.get("reason"), None, ended.get("last_message"), now_iso())
        delete_session_file(file_path, lookout_home)
        remove_messaging_token(lookout_home, agent, session_id)
        remove_session_requests(lookout_home, agent, session_id)
        try:
            os.remove(file_path + ".lock")
        except OSError:
            pass
        _cleanup_session_requests(lookout_home, agent, session_id)
        return 0

    ensure_private_dir(lookout_home)
    ensure_private_dir(sessions_dir)

    acquire_session_lock(file_path)
    existing = load_existing(file_path)
    record = existing if isinstance(existing, dict) else {}
    now = now_iso()

    record.setdefault("schema", STATE_FILE_SCHEMA)
    record["agent"] = agent
    record["session_id"] = session_id
    if not record.get("started_at"):
        record["started_at"] = now

    # SPEC 12.2: cwd/project only move on main-turn events. Sub-agents run
    # in-process and report the parent's session_id with their own (worktree)
    # cwd on tool events - that must never relabel the row.
    payload_cwd = payload.get("cwd")
    payload_cwd = payload_cwd if isinstance(payload_cwd, str) and payload_cwd else None

    if payload_cwd and not record.get("origin_cwd"):
        record["origin_cwd"] = payload_cwd

    if event in ("SessionStart", "UserPromptSubmit") and payload_cwd:
        record["cwd"] = payload_cwd
        record["project"] = os.path.basename(payload_cwd.rstrip("/")) or payload_cwd
    elif payload_cwd and record.get("cwd") and payload_cwd != record.get("cwd"):
        record["active_cwd"] = cap_len(payload_cwd, 2000)
        wt = worktree_basename(payload_cwd)
        if wt:
            record["worktree"] = wt

    tp = payload.get("transcript_path")
    if isinstance(tp, str) and tp:
        record["transcript_path"] = tp

    env = os.environ
    # Identity (pid/tty/host) cannot change during a session: resolve it once, then skip the
    # `ps` call on every later event so the hook costs ~40 ms instead of ~100 ms per tool use.
    have_identity = (
        record.get("pid") is not None
        and "tty" in record
        and record.get("host") not in (None, "", "unknown")
    )
    ps_map = {} if have_identity else build_ps_map()

    if have_identity:
        pid, tty = record.get("pid"), record.get("tty")
    else:
        pid, tty = resolve_agent_pid_tty(agent, env, ps_map)
    if pid is not None:
        record["pid"] = pid
    if tty is not None:
        record["tty"] = tty
    elif "tty" not in record:
        record["tty"] = None

    if have_identity:
        host, host_pid = record.get("host"), record.get("host_pid")
    else:
        host, host_pid = resolve_host(agent, env, ps_map, pid if pid is not None else record.get("pid"))
        shell_pid = resolve_shell_pid(ps_map, pid if pid is not None else record.get("pid"))
        if shell_pid is not None:
            record["shell_pid"] = shell_pid
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

    # SPEC 11.3: Claude only, only when the socket path actually exists;
    # once per session is fine, but keep re-checking while it's missing
    # (SessionStart can fire before the CLI has created the socket file).
    if agent == "claude" and not record.get("messaging_socket"):
        sock = env.get("CLAUDE_CODE_MESSAGING_SOCKET")
        if sock and os.path.exists(sock):
            record["messaging_socket"] = sock
    if agent == "claude":
        # Claude Code sets the socket and its token at runtime, so only child processes (this
        # hook) can see the token. It goes into a 0600 file in a 0700 dir, never into the state
        # JSON or any log; SessionEnd removes it. Same-user processes could read it from our
        # environment anyway (`ps -E`), so this changes who can read it by nothing.
        store_messaging_token(lookout_home, agent, session_id, env.get("CLAUDE_CODE_MESSAGING_TOKEN"))

    if event in ("SessionStart", "UserPromptSubmit", "Stop"):
        desktop_title = read_custom_title(record.get("transcript_path"))
        if desktop_title:
            record["desktop_title"] = desktop_title
        if agent == "claude":
            started = _iso_to_epoch(record.get("started_at"))
            model = read_transcript_model(
                record.get("transcript_path"),
                not_before=(started - 60) if started is not None else None,
            )
            if model:
                record["model"] = model
        elif agent == "codex":
            # Prefer the transcript's own turn_context.model (tracks mid-session
            # model switches); fall back to the hook payload, then (SessionStart
            # only) the static ~/.codex/config.toml default.
            model = read_codex_transcript_model(record.get("transcript_path"))
            if not model:
                model = payload.get("model") if isinstance(payload.get("model"), str) else None
            if not model and event == "SessionStart":
                model = read_codex_model()
            if model:
                record["model"] = model
    if not record.get("provider"):
        provider = resolve_provider(agent, env)
        if provider:
            record["provider"] = provider

    prev_state = record.get("state")
    apply_event(record, event, parsed.get("matcher"), payload)
    if event in ("PostToolUse", "Stop"):
        # SPEC 19.1: cheap tail-only read, every PostToolUse/Stop (and SessionEnd,
        # above) for both agents - never the whole transcript, and independent of
        # accumulate_usage's own offset/dedupe state below. Never allowed to stop the
        # record from being written below - a bad/foreign transcript line must not
        # freeze this session's row forever (SPEC 19.1 hardening).
        try:
            measure_context(record, agent, record.get("transcript_path"))
        except Exception:
            log_error(lookout_home, "measure_context failed")
    if event == "Stop":
        try:
            accumulate_usage(record, agent, lookout_home)
        except Exception as exc:  # noqa: BLE001 - the record must still be written
            log_error(lookout_home, "accumulate_usage failed: %s" % type(exc).__name__)
    if record.get("state") != prev_state or event == "SessionStart":
        append_history(lookout_home, agent, session_id, record, prev_state, record.get("state"),
                       record.get("reason"), record.get("detail"), record.get("last_message"), now)
    apply_subagent_event(record, event, payload, now)

    record["updated_at"] = now
    if not record.get("state_since"):
        record["state_since"] = now

    # SPEC 11.3: clear a leftover permission/question request once the state
    # (just updated above) has left needs_you, or once it has gone stale -
    # before any fresh request below claims a new request_id.
    prune_or_clear_stale_request(record, lookout_home, agent, session_id)

    if event == "PreToolUse" and payload.get("tool_name") == "AskUserQuestion":
        write_question_request(record, agent, session_id, payload, now, lookout_home)
        write_ordered(file_path, record)
        return 0

    if event == "PermissionRequest":
        return handle_permission_request(record, agent, session_id, payload, lookout_home, file_path)

    write_ordered(file_path, record)
    return 0

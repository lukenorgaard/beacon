"""Resolve process, terminal and host identity from an explicit environment whitelist."""

import os
import re
import subprocess


# --- ps-based pid/tty/host resolution (SPEC 4, last paragraph) ---------------

def build_ps_map():
    """One `ps -axo pid=,ppid=,tty=,comm=` call, parsed once. Returns
    {pid: (ppid, tty, comm)}."""
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,tty=,comm="],
            capture_output=True,
            text=True,
            timeout=3,
        )
    except Exception:
        return {}
    m = {}
    for line in out.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        tty = parts[2]
        comm = parts[3]
        m[pid] = (ppid, tty, comm)
    return m


def normalize_tty(raw):
    if not raw or raw == "??":
        return None
    return raw


def comm_basename(comm):
    return comm.rsplit("/", 1)[-1]


def resolve_agent_pid_tty(agent, env, ps_map):
    """Returns (pid, tty). Uses CLAUDE_PID when present for agent=claude;
    otherwise walks $PPID upward until comm matches a known agent name."""
    if agent == "claude":
        raw = env.get("CLAUDE_PID")
        if raw and raw.isdigit():
            pid = int(raw)
            entry = ps_map.get(pid)
            tty = normalize_tty(entry[1]) if entry else None
            return pid, tty

    target_names = {"claude", "codex", agent}
    pid = os.getppid()
    seen = set()
    for _ in range(20):
        if pid in seen:
            break
        seen.add(pid)
        entry = ps_map.get(pid)
        if not entry:
            break
        ppid, tty, comm = entry
        if comm_basename(comm) in target_names:
            return pid, normalize_tty(tty)
        if ppid == pid:
            break
        pid = ppid
    return None, None


_DESKTOP_HOST_SESSION_ID_RE = re.compile(r"^local_[A-Za-z0-9-]{1,64}$")


def resolve_desktop_host_session_id(agent, env):
    """SPEC 9.1: CLAUDE_CODE_HOST_SESSION_ID identifies the exact desktop-app
    session (the id the app's `claude://code/continue?session=` URL handler
    actually validates against, regex verified 2026-09-02). Gated to
    agent == "claude", same as the CLAUDE_CODE_ENTRYPOINT check just below,
    so a value inherited by some other agent's child process (e.g. a Codex
    session launched as a subprocess from inside a desktop Claude session)
    never misattributes that session's host."""
    if agent != "claude":
        return None
    raw = env.get("CLAUDE_CODE_HOST_SESSION_ID")
    if raw and _DESKTOP_HOST_SESSION_ID_RE.match(raw):
        return raw
    return None


SHELL_NAMES = ("zsh", "bash", "fish", "sh", "nu", "dash", "tcsh", "ksh")


def resolve_shell_pid(ps_map, agent_pid):
    """Nearest ancestor of the agent that is a shell: the integrated terminal's own process,
    which is what the editor companion (SPEC §16) matches on (`terminal.processId`)."""
    if agent_pid is None:
        return None
    entry = ps_map.get(agent_pid)
    pid = entry[0] if entry else None
    seen = set()
    for _ in range(12):
        if pid is None or pid in seen:
            return None
        seen.add(pid)
        entry = ps_map.get(pid)
        if not entry:
            return None
        ppid, tty, comm = entry
        base = comm_basename(comm).lstrip("-")
        if base in SHELL_NAMES:
            return pid
        pid = ppid
    return None


def resolve_host(agent, env, ps_map, agent_pid):
    """Walk up to 12 ancestors from agent_pid looking for a known host app.
    CLAUDE_CODE_HOST_SESSION_ID (valid desktop id) or
    CLAUDE_CODE_ENTRYPOINT=claude-desktop force claude-desktop outright.
    TERM_PROGRAM is a cross-check fallback only when the ps walk found
    nothing conclusive."""
    if resolve_desktop_host_session_id(agent, env):
        return "claude-desktop", None
    if agent == "claude" and env.get("CLAUDE_CODE_ENTRYPOINT") == "claude-desktop":
        return "claude-desktop", None

    host = "unknown"
    host_pid = None
    pid = agent_pid
    if pid is not None:
        seen = set()
        for _ in range(12):
            if pid in seen:
                break
            seen.add(pid)
            entry = ps_map.get(pid)
            if not entry:
                break
            ppid, tty, comm = entry
            base = comm_basename(comm)
            if base == "Cursor":
                host, host_pid = "cursor", pid
                break
            if base == "Devin":
                host, host_pid = "devin", pid
                break
            if base == "Terminal":
                host, host_pid = "terminal", pid
                break
            if base == "iTerm2":
                host, host_pid = "iterm", pid
                break
            if base == "Claude":
                host, host_pid = "claude-desktop", pid
                break
            if base in ("ChatGPT", "Codex"):
                host, host_pid = "codex-app", pid
                break
            if base in ("Code", "Electron") and "Visual Studio Code" in comm:
                host, host_pid = "vscode", pid
                break
            if ppid == pid:
                break
            pid = ppid

    if host == "unknown":
        tp = env.get("TERM_PROGRAM")
        if tp == "Apple_Terminal":
            host = "terminal"
        elif tp == "iTerm.app":
            host = "iterm"
        elif tp == "vscode":
            host = "vscode"

    return host, host_pid


def resolve_entrypoint(agent, env):
    if resolve_desktop_host_session_id(agent, env):
        return "claude-desktop"
    if agent == "claude":
        return env.get("CLAUDE_CODE_ENTRYPOINT") or "cli"
    if agent == "codex":
        return "codex"
    return "cli"


def resolve_host_ref(agent, env):
    """The desktop session id (when present and valid) takes precedence over
    the terminal-multiplexer ids - it is more specific and is what the app
    needs for an exact desktop deep link (SPEC 9.1)."""
    desktop_id = resolve_desktop_host_session_id(agent, env)
    if desktop_id:
        return desktop_id
    return env.get("ITERM_SESSION_ID") or env.get("TERM_SESSION_ID") or None

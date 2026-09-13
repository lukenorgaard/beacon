"""Track pending and live subagents and prune stale entries."""

import calendar
import time
from .common import _iso_to_epoch


# --- sub-agent tracking (SPEC 9.3) --------------------------------------------
#
# `subagents` (public, optional record field) and `pending_agents` (internal
# staging list, never rendered by the app) are both persisted in the same
# state file - it is the only thing that survives between one hook
# invocation and the next. `events.apply_event` never touches either; this
# function never touches state/reason/detail.

PENDING_AGENTS_MAX = 20


SUBAGENT_MAX_AGE_SECONDS = 6 * 60 * 60


# "Task" is the pre-rename tool name for the same launch-a-subagent tool on
# older Claude Code versions; accept both.
_AGENT_TOOL_NAMES = ("Agent", "Task")




def _clean_optional_str(v, limit=None):
    if not isinstance(v, str):
        return None
    v = " ".join(v.split())
    if not v:
        return None
    return v[:limit] if limit is not None else v


def prune_stale_subagents(subagents, now_epoch):
    kept = []
    for sa in subagents:
        if not isinstance(sa, dict):
            continue
        epoch = _iso_to_epoch(sa.get("started_at"))
        if epoch is not None and (now_epoch - epoch) > SUBAGENT_MAX_AGE_SECONDS:
            continue
        kept.append(sa)
    return kept


def apply_subagent_event(record, event, payload, now):
    """PreToolUse (Agent/Task) stages a pending entry; SubagentStart matches
    it to a real agent_id (oldest pending entry of the same type, else the
    oldest pending entry, else a bare entry) and appends to `subagents`;
    SubagentStop removes by id; Stop clears the pending queue (but not live
    subagents). Runs on every hook event so the 6h prune happens on every
    write, per SPEC 9.3."""
    pending = record.get("pending_agents")
    pending = list(pending) if isinstance(pending, list) else []
    subagents = record.get("subagents")
    subagents = list(subagents) if isinstance(subagents, list) else []

    if event == "PreToolUse" and payload.get("tool_name") in _AGENT_TOOL_NAMES:
        tool_input = payload.get("tool_input")
        tool_input = tool_input if isinstance(tool_input, dict) else {}
        subagent_type = tool_input.get("subagent_type")
        subagent_type = subagent_type if isinstance(subagent_type, str) and subagent_type.strip() else "general-purpose"
        pending.append({
            "description": _clean_optional_str(tool_input.get("description"), 80),
            "type": subagent_type,
            "model": _clean_optional_str(tool_input.get("model")),
            "cwd": payload.get("cwd") if isinstance(payload.get("cwd"), str) and payload.get("cwd") else None,
        })
        if len(pending) > PENDING_AGENTS_MAX:
            pending = pending[-PENDING_AGENTS_MAX:]

    elif event == "SubagentStart":
        agent_id = payload.get("agent_id")
        agent_type = payload.get("agent_type")
        agent_type = agent_type if isinstance(agent_type, str) and agent_type.strip() else None

        matched = None
        if agent_type is not None:
            for i, p in enumerate(pending):
                if isinstance(p, dict) and p.get("type") == agent_type:
                    matched = pending.pop(i)
                    break
        if matched is None and pending:
            matched = pending.pop(0)

        if isinstance(agent_id, str) and agent_id:
            sa_cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) and payload.get("cwd") else None
            if sa_cwd is None and matched:
                sa_cwd = matched.get("cwd")
            subagents.append({
                "id": agent_id,
                "type": agent_type or (matched.get("type") if matched else None) or "general-purpose",
                "description": matched.get("description") if matched else None,
                "model": matched.get("model") if matched else None,
                "cwd": sa_cwd,
                "started_at": now,
            })

    elif event == "SubagentStop":
        agent_id = payload.get("agent_id")
        if isinstance(agent_id, str) and agent_id:
            subagents = [
                sa for sa in subagents
                if not (isinstance(sa, dict) and sa.get("id") == agent_id)
            ]
        # Last background agent gone and the main turn already ended → now it is finished.
        if not subagents and record.get("state") == "working" and record.get("reason") == "background":
            record["state"] = "done"
            record["reason"] = "stop"
            record["detail"] = None
            record["state_since"] = now

    elif event == "Stop":
        pending = []

    now_epoch = _iso_to_epoch(now)
    if now_epoch is None:
        now_epoch = calendar.timegm(time.gmtime())
    subagents = prune_stale_subagents(subagents, now_epoch)

    record["pending_agents"] = pending
    record["subagents"] = subagents

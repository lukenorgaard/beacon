"""Translate hook events into session state transitions."""

from .common import (
    ends_with_question,
    now_iso,
    truncate_collapse,
)
from .requests import (
    extract_question_detail,
    make_permission_detail,
)
from .transcript import (
    is_injected_prompt,
    sanitize_background_tasks,
    scan_transcript_for_title,
)


# --- event -> state mapping (SPEC 4 table) -------------------------------------

def apply_event(record, event, matcher, payload):
    old_state = record.get("state")
    state = old_state
    reason = record.get("reason")
    detail = record.get("detail")
    detail_touched = [False]

    def set_state(s, r):
        nonlocal state, reason
        state, reason = s, r

    def set_detail(d):
        if d:
            detail_touched[0] = True
            return d
        return None

    if event == "SessionStart":
        set_state("idle", "session_start")
        if not record.get("title") and payload.get("source") == "resume":
            t = scan_transcript_for_title(payload.get("transcript_path"))
            if t:
                record["title"] = t
    elif event == "UserPromptSubmit":
        set_state("working", "prompt")
        if not record.get("title") or is_injected_prompt(record.get("title")):
            prompt = payload.get("prompt")
            if isinstance(prompt, str) and prompt.strip() and not is_injected_prompt(prompt):
                record["title"] = truncate_collapse(prompt, 80)
    elif event == "PreToolUse":
        tool_name = payload.get("tool_name")
        if tool_name == "AskUserQuestion":
            set_state("needs_you", "question")
            d = extract_question_detail(payload.get("tool_input"))
            if d:
                detail = d
                detail_touched[0] = True
        else:
            set_state("working", "tool")
            if isinstance(tool_name, str) and tool_name:
                detail = truncate_collapse(tool_name, 120)
                detail_touched[0] = True
    elif event == "PostToolUse":
        set_state("working", "tool_done")
        tool_name = payload.get("tool_name")
        if isinstance(tool_name, str) and tool_name:
            detail = truncate_collapse(tool_name, 120)
            detail_touched[0] = True
    elif event == "PermissionRequest":
        set_state("needs_you", "permission")
        d = make_permission_detail(payload)
        if d:
            detail = d
            detail_touched[0] = True
    elif event == "Stop":
        # SPEC 12.2: a worktree cwd picked up from a tool event only applies
        # while that sub-agent activity is live.
        record["active_cwd"] = None
        record["worktree"] = None
        # The main turn ended, but sub-agents or background tasks may still run for this
        # session — then it is not finished yet (the owner, 2026-09-02).
        live = [sa for sa in (record.get("subagents") or []) if isinstance(sa, dict)]
        bg = payload.get("background_tasks")
        bg_count = len(bg) if isinstance(bg, list) else 0
        # Keep a sanitised copy of what Claude Code reports as still running (ids/descriptions
        # only, capped) so the app and the log can reconcile sub-agents against it.
        record["background_tasks"] = sanitize_background_tasks(bg)
        lam = payload.get("last_assistant_message")
        asks = isinstance(lam, str) and ends_with_question(lam)
        if (live or bg_count) and not asks:
            set_state("working", "background")
            if live:
                n = len(live)
                detail = "%d agent%s running in background" % (n, "" if n == 1 else "s")
            else:
                detail = "%d background task%s running" % (bg_count, "" if bg_count == 1 else "s")
            detail_touched[0] = True
        else:
            # A turn that ends with a question to the user is over, even if a background
            # task is still listed: a hung task kept a session "Working" for ten hours
            # while it was waiting for an answer (2026-09-04).
            set_state("done", "stop")
            if asks and (live or bg_count):
                n = len(live) or bg_count
                detail = "Asks you · %d background %s still listed" % (n, "agent" if live else "task")
                detail_touched[0] = True
        if isinstance(lam, str) and lam.strip():
            record["last_message"] = truncate_collapse(lam, 160)
    elif event == "Interrupt":
        # Current Codex emits this when an active main-thread turn is interrupted.
        # Older clients may omit it; Stop and SessionEnd remain independently handled.
        set_state("idle", "interrupted")
    elif event == "Notification":
        if matcher == "permission_prompt":
            if old_state != "needs_you":
                set_state("needs_you", "permission")
                msg = payload.get("message")
                if isinstance(msg, str) and msg.strip():
                    detail = truncate_collapse(msg, 120)
                    detail_touched[0] = True
            # else: already needs_you -> untouched, per SPEC table.
        elif matcher in ("elicitation_dialog", "elicitation_url_dialog"):
            set_state("needs_you", "question")
            msg = payload.get("message")
            if isinstance(msg, str) and msg.strip():
                detail = truncate_collapse(msg, 120)
                detail_touched[0] = True
        elif matcher == "idle_prompt":
            pass  # keep done/idle; refresh updated_at only (done in caller)
        else:
            pass
    elif event == "PostCompact":
        # SPEC 19.1: right after a compaction the transcript tail still shows the
        # pre-compact prompt size until the next message is written, so a stale
        # context_tokens would read as barely having dropped. Clear it and stamp
        # when it happened; context_window is kept (the window itself didn't
        # change) and the next PostToolUse/Stop measurement fills context_tokens
        # back in. State/reason/detail are untouched, like every other event not
        # in the table.
        record["context_tokens"] = None
        record["context_compacted_at"] = now_iso()
    else:
        # SubagentStop, PreCompact, SubagentStart, or any event not in the
        # table: unchanged, refresh updated_at only.
        pass

    record["state"] = state if state else "idle"
    record["reason"] = reason
    if detail_touched[0]:
        record["detail"] = detail
    if state != old_state:
        record["state_since"] = now_iso()

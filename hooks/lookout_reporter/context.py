"""Measure current context independently from cumulative token accounting."""

import calendar
import json
import time
from .common import (
    _iso_to_epoch,
    now_iso,
)


# --- context measurement (SPEC 19.1) ------------------------------------------
#
# Cheap, tail-only estimate of how much of the model's context window a session
# is currently using - refreshed at PostToolUse/Stop/SessionEnd, cleared at
# PostCompact. Deliberately separate from usage.accumulate_usage(): that
# function tracks *cumulative* usage since the reporter started watching
# (offset-based, deduped by message id, added into the record's running
# total); this one only cares about the *current* prompt size, so it always
# re-reads just the tail and never touches usage_offset/usage_seen_ids/tokens.

CONTEXT_TAIL_BYTES = 256 * 1024


def _tail_lines(path, tail_bytes=CONTEXT_TAIL_BYTES):
    """Last `tail_bytes` of `path`, decoded and split into lines, with a
    possible partial first line (the seek point can land mid-line) dropped.
    None on any I/O failure - the caller then leaves the record untouched."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            start = max(0, size - tail_bytes)
            f.seek(start)
            data = f.read()
    except OSError:
        return None
    lines = data.decode("utf-8", "replace").split("\n")
    if start > 0 and lines:
        # We started reading mid-file: the first line is almost certainly cut
        # off partway through and would fail to parse as JSON anyway, but drop
        # it explicitly rather than relying on that.
        lines = lines[1:]
    return lines


def _usage_field_is_numeric(value):
    """A transcript's `usage.*` field must be a plain number to trust (SPEC 19.1 hardening, same
    rule as `_codex_rate_limit_window`'s guards): `int(x or 0)` used to raise straight out of
    `_measure_claude_context` on a string or object value, and that exception used to escape all
    the way out of `run_hook_mode` - killing the record write for that event, and (until the next
    event that happened not to hit it) every one after it. `None`/absent is fine - it means "not
    reported", the same as 0. `bool` is excluded because `isinstance(True, int)` is true in
    Python and a stray `true`/`false` here is not a token count."""
    if value is None:
        return True
    if isinstance(value, bool):
        return False
    return isinstance(value, (int, float))


def _measure_claude_context(lines):
    """Last assistant line carrying `message.usage` in `lines` (SPEC 19.1):
    Claude Code writes one transcript line per content block of a response,
    and every line belonging to one `message.id` repeats that response's
    whole `usage` - so the last matching line in file order already holds
    the newest message's total; no per-id dedupe is needed here (unlike
    accumulate_usage's cumulative counting). A line whose usage carries a
    non-numeric field (a foreign/future payload shape) is treated as
    unusable and skipped entirely rather than trusted with the bad field
    silently zeroed - `total` simply stays at whatever the last *good* line
    left it, the same as a line with no usage at all."""
    total = None
    for line in lines:
        if '"usage"' not in line or '"assistant"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else None
        if obj.get("type") != "assistant" or not msg:
            continue
        usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else None
        if not usage:
            continue
        fields = (
            usage.get("input_tokens"),
            usage.get("cache_creation_input_tokens"),
            usage.get("cache_read_input_tokens"),
        )
        if not all(_usage_field_is_numeric(v) for v in fields):
            continue
        total = sum(int(v) if v is not None else 0 for v in fields)
    return total


def _measure_codex_context(lines):
    """The LAST `token_count` event in `lines` (SPEC 19.1). Unlike
    _accumulate_usage_codex, nothing here is a delta added to a running
    total: `last_token_usage.input_tokens` already includes cached tokens
    and IS the current prompt size, and `model_context_window` (when that
    same event happens to carry it) is the window. Returns (None, None) when
    no token_count event with usable `info` is found in the tail."""
    last_payload = None
    for line in lines:
        if '"token_count"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") != "event_msg":
            continue
        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        if payload.get("type") != "token_count":
            continue
        last_payload = payload
    if last_payload is None:
        return None, None
    info = last_payload.get("info") if isinstance(last_payload.get("info"), dict) else None
    if not info:
        return None, None
    tokens = None
    last = info.get("last_token_usage") if isinstance(info.get("last_token_usage"), dict) else None
    if isinstance(last, dict):
        it = last.get("input_tokens")
        if isinstance(it, (int, float)) and not isinstance(it, bool):
            tokens = int(it)
    window = None
    cw = info.get("model_context_window")
    if isinstance(cw, (int, float)) and not isinstance(cw, bool):
        window = int(cw)
    return tokens, window


def _transcript_epoch(ts):
    """Claude Code and Codex stamp transcript lines with fractional seconds
    ("2026-09-04T08:55:08.597Z"); _iso_to_epoch reads the reporter's own
    whole-second stamps. Both shapes land here."""
    if not isinstance(ts, str) or not ts:
        return None
    text = ts.strip()
    if text.endswith("Z"):
        text = text[:-1]
    if "." in text:
        text = text.split(".", 1)[0]
    try:
        return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


def _newest_line_epoch(lines, agent):
    """Timestamp of the newest line measure_context would read (assistant usage
    for Claude, token_count for Codex), as an epoch, or None when the tail
    carries no timestamps at all."""
    newest = None
    for line in lines:
        if agent == "codex":
            if '"token_count"' not in line:
                continue
        elif '"usage"' not in line or '"assistant"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if agent == "codex":
            payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else None
            if not payload or payload.get("type") != "token_count":
                continue
        elif obj.get("type") != "assistant":
            continue
        epoch = _transcript_epoch(obj.get("timestamp"))
        if epoch is not None:
            newest = epoch
    return newest


def transcript_is_stale(lines, agent, record):
    """SPEC 19.1: a transcript whose newest usage line predates this session's
    own start is not this run's transcript - Claude Code stops writing it when
    a session inherits CLAUDE_CODE_CHILD_SESSION ("Transcript saving is off"),
    and the tail then belongs to an older run with its own model and context.
    Nothing read from such a tail may describe the live session."""
    started = _iso_to_epoch(record.get("started_at")) if isinstance(record, dict) else None
    if started is None:
        return False
    newest = _newest_line_epoch(lines, agent)
    if newest is None:
        return False
    return newest < started - 60


def measure_context(record, agent, transcript_path):
    """SPEC 19.1: set context_tokens / context_window (Codex only) /
    context_at from the last 256 KB of the transcript - never the whole
    file, and never the usage-accumulation offset/dedupe state in usage.py. Any
    failure (no file, unparseable JSON, no usage line in the tail) leaves
    the record's context fields exactly as they already were."""
    if not isinstance(transcript_path, str) or not transcript_path:
        return
    lines = _tail_lines(transcript_path)
    if lines is None:
        return
    if transcript_is_stale(lines, agent, record):
        record["context_tokens"] = None
        record["context_at"] = now_iso()
        return
    if agent == "codex":
        tokens, window = _measure_codex_context(lines)
        if tokens is None:
            return
        record["context_tokens"] = tokens
        if window is not None:
            record["context_window"] = window
    else:
        tokens = _measure_claude_context(lines)
        if tokens is None:
            return
        record["context_tokens"] = tokens
    record["context_at"] = now_iso()

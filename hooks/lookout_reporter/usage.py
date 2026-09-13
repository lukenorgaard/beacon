"""Incremental token accounting and Codex rate-limit snapshots."""

import calendar
import json
import os
import re
import time
from .common import (
    ensure_private_dir,
    now_iso,
)
from .storage import (
    load_existing,
    write_json_atomic,
)


USAGE_KEYS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")


USAGE_SCAN_CAP = 50 * 1024 * 1024


# Bumped whenever the way tokens are counted changes; an older record is re-scanned from 0.
USAGE_VERSION = 2


USAGE_SEEN_IDS = 4096


def _usage_int(usage, key):
    """A usage field as an int, or 0 when it is missing or not a number - one odd value in a
    transcript must never stop the record from being written (review 2026-09-06)."""
    value = usage.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return int(value)


def _accumulate_usage_claude(lines, totals, seen_ids):
    """Claude transcript path (SPEC §17.6): each assistant message carries its
    own per-message `usage`, keyed by `message.model`.

    Claude Code writes one transcript line per content block of the same API
    response (text, tool_use, ...), and every one of those lines repeats the
    whole `usage` of that response — measured on a real day-long session, 1654
    lines for 343 responses - and after a /compact the un-summarised tail is
    written again with the same ids, hundreds of lines later. Counting a
    `message.id` once is the difference between the real API-equivalent cost
    and five times it. `seen_ids` is the list of counted ids (capped at
    USAGE_SEEN_IDS, oldest dropped), kept in the record so a repeat in a later
    scan is still recognised."""
    for raw in lines:
        if b'"usage"' not in raw or b'"assistant"' not in raw:
            continue
        try:
            obj = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else None
        if obj.get("type") != "assistant" or not msg:
            continue
        usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else None
        if not usage:
            continue
        message_id = msg.get("id") if isinstance(msg.get("id"), str) else None
        if message_id:
            if message_id in seen_ids:
                continue
            seen_ids.append(message_id)
            del seen_ids[:-USAGE_SEEN_IDS]
        model = msg.get("model") if isinstance(msg.get("model"), str) else "unknown"
        bucket = totals.get(model) if isinstance(totals.get(model), dict) else {"in": 0, "out": 0, "cache_read": 0, "cache_write": 0}
        bucket["in"] += _usage_int(usage, "input_tokens")
        bucket["out"] += _usage_int(usage, "output_tokens")
        bucket["cache_read"] += _usage_int(usage, "cache_read_input_tokens")
        bucket["cache_write"] += _usage_int(usage, "cache_creation_input_tokens")
        totals[model] = bucket
    return totals


def _accumulate_usage_codex(lines, totals, current_model):
    """Codex transcript path (SPEC §17.7): track the active model via
    `turn_context` lines (`model` can change between turns - and has been
    observed to always live under `payload.model`, never at the top level,
    but the top level is still accepted for robustness against a future/older
    CLI) and add each `token_count` event's `info.last_token_usage` deltas to
    that model's running bucket. `info` can be null on some events - skipped,
    not an error. Returns (totals, current_model, latest_rate_limits) - the
    caller persists codex-usage.json from the last one when a rate_limits
    blob was seen anywhere in this scan (last one in file order wins - the
    transcript is append-only, so later in the file means chronologically
    later)."""
    latest_rl = None
    for raw in lines:
        if not raw.strip():
            continue
        if b'"turn_context"' in raw:
            try:
                obj = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                continue
            if obj.get("type") == "turn_context":
                payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
                m = payload.get("model") if isinstance(payload.get("model"), str) else obj.get("model")
                if isinstance(m, str) and m.strip():
                    current_model = m.strip()
            continue
        if b'"token_count"' not in raw:
            continue
        try:
            obj = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        if obj.get("type") != "event_msg":
            continue
        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        if payload.get("type") != "token_count":
            continue
        info = payload.get("info") if isinstance(payload.get("info"), dict) else None
        if info:
            last = info.get("last_token_usage") if isinstance(info.get("last_token_usage"), dict) else None
            if last:
                model = current_model or "unknown"
                bucket = totals.get(model) if isinstance(totals.get(model), dict) else {"in": 0, "out": 0, "cache_read": 0, "cache_write": 0}
                input_tokens = int(last.get("input_tokens") or 0)
                cached = int(last.get("cached_input_tokens") or 0)
                # Codex's input_tokens INCLUDES the cached portion (verified
                # 2026-09-03 against real ~/.codex/sessions files) - unlike
                # Claude's usage.input_tokens, which already excludes
                # cache_read_input_tokens. Subtract the cached part back out
                # so "in" means the same thing (fresh, non-cached input) for
                # both agents' token buckets.
                bucket["in"] += max(0, input_tokens - cached)
                bucket["out"] += int(last.get("output_tokens") or 0)
                bucket["cache_read"] += cached
                bucket["cache_write"] += int(last.get("cache_write_input_tokens") or 0)
                totals[model] = bucket
        rl = payload.get("rate_limits") if isinstance(payload.get("rate_limits"), dict) else None
        if rl:
            latest_rl = rl
    return totals, current_model, latest_rl


_CODEX_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?Z$")


def _codex_ts_to_epoch(ts):
    """Parse a `now_iso()`-style timestamp (`"2026-08-19T09:16:45Z"` - what
    codex-usage.json's own `updated` field holds) down to whole-second epoch.
    Also accepts millisecond-precision timestamps
    (`"2026-08-19T09:16:45.957Z"`, the format Codex rollout lines use for
    their own `timestamp` field) for robustness, though `write_codex_usage_file`
    only ever feeds this `now_iso()` output. Sub-second precision is dropped -
    "newer than" only needs to be right to the second here."""
    if not isinstance(ts, str):
        return None
    m = _CODEX_TS_RE.match(ts)
    if not m:
        return None
    try:
        return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return None


def codex_usage_file_path(lookout_home):
    return os.path.join(lookout_home, "codex-usage.json")


def _codex_rate_limit_window(w):
    if not isinstance(w, dict):
        return None
    return {
        "used_percent": w.get("used_percent") if isinstance(w.get("used_percent"), (int, float)) and not isinstance(w.get("used_percent"), bool) else None,
        "window_minutes": w.get("window_minutes") if isinstance(w.get("window_minutes"), (int, float)) and not isinstance(w.get("window_minutes"), bool) else None,
        "resets_at": w.get("resets_at") if isinstance(w.get("resets_at"), (int, float)) and not isinstance(w.get("resets_at"), bool) else None,
    }


def write_codex_usage_file(lookout_home, rate_limits):
    """SPEC §17.7: persist the newest Codex rate-limit snapshot seen to
    `$LOOKOUT_HOME/codex-usage.json`, mode 0600, atomic write like every
    other file this module writes. This is one shared file, not per-session,
    so several concurrent Codex sessions' hook processes can race to write
    it. `updated` is this process's own wall-clock time at write time (not
    the transcript event's own timestamp, which can be arbitrarily far in
    the past on a first scan of an old/resumed session - comparing that
    against a wall-clock `updated` would make the guard below reject nearly
    every write); comparing wall-clock write times against each other still
    protects against a write that got delayed in OS scheduling landing
    *after* a genuinely later write already completed. Missing/invalid
    existing file, or an unparsable `updated`, always allows the write
    through rather than getting stuck never-updating."""
    if not isinstance(rate_limits, dict):
        return
    path = codex_usage_file_path(lookout_home)
    now = now_iso()
    new_epoch = _codex_ts_to_epoch(now)
    existing = load_existing(path)
    if isinstance(existing, dict):
        old_epoch = _codex_ts_to_epoch(existing.get("updated"))
        if old_epoch is not None and new_epoch is not None and new_epoch < old_epoch:
            return
    out = {
        "updated": now,
        "limit_name": rate_limits.get("limit_name") if isinstance(rate_limits.get("limit_name"), str) else None,
        "plan_type": rate_limits.get("plan_type") if isinstance(rate_limits.get("plan_type"), str) else None,
        "primary": _codex_rate_limit_window(rate_limits.get("primary")),
        "secondary": _codex_rate_limit_window(rate_limits.get("secondary")),
    }
    try:
        ensure_private_dir(lookout_home)
        write_json_atomic(path, out)
    except Exception:
        pass


def accumulate_usage(record, agent=None, lookout_home=None):
    """SPEC §17.6 (Claude) / §17.7 (Codex): read the transcript from the
    stored offset, add per-model token counts. `agent` picks the per-line
    parser - "codex" gets the turn_context/token_count path (and, when a
    `rate_limits` blob is seen, refreshes codex-usage.json via
    `lookout_home`); anything else (in practice just "claude") gets the
    message.usage path."""
    path = record.get("transcript_path")
    if not isinstance(path, str) or not path:
        return
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if record.get("usage_version") != USAGE_VERSION:
        # Counted under older rules (before per-message dedupe): start over from byte 0.
        record["tokens"] = {}
        record["usage_offset"] = 0
        record["usage_seen_ids"] = []
        record["usage_version"] = USAGE_VERSION
    offset = record.get("usage_offset")
    offset = offset if isinstance(offset, int) and 0 <= offset <= size else 0
    if size - offset > USAGE_SCAN_CAP:
        offset = size - USAGE_SCAN_CAP
    totals = record.get("tokens") if isinstance(record.get("tokens"), dict) else {}
    seen_ids = record.get("usage_seen_ids")
    seen_ids = [i for i in seen_ids if isinstance(i, str)] if isinstance(seen_ids, list) else []
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read(size - offset)
    except OSError:
        return
    # Only complete lines count; a partial last line is re-read next time.
    end = data.rfind(b"\n")
    if end < 0:
        return
    consumed = end + 1
    lines = data[:consumed].split(b"\n")

    if agent == "codex":
        current_model = record.get("model") if isinstance(record.get("model"), str) else None
        totals, current_model, latest_rl = _accumulate_usage_codex(lines, totals, current_model)
        if latest_rl is not None and lookout_home:
            write_codex_usage_file(lookout_home, latest_rl)
    else:
        totals = _accumulate_usage_claude(lines, totals, seen_ids)
        record["usage_seen_ids"] = seen_ids[-USAGE_SEEN_IDS:]

    record["tokens"] = totals
    record["usage_offset"] = offset + consumed

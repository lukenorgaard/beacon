"""Transcript titles, models, provider metadata and project paths."""

import json
import os
from .common import (
    truncate_collapse,
)
from .context import (
    _transcript_epoch,
)


# --- worktree / sub-agent cwd (SPEC 12.2) --------------------------------------

def worktree_basename(path):
    """Name of the git worktree a tool-event cwd points into, when the path
    looks like one: '.../.claude/worktrees/<name>...' or
    '.../worktrees/<name>...' (SPEC 12.2)."""
    if not isinstance(path, str):
        return None
    for marker in ("/.claude/worktrees/", "/worktrees/"):
        idx = path.find(marker)
        if idx == -1:
            continue
        rest = path[idx + len(marker):].strip("/")
        if rest:
            return rest.split("/", 1)[0]
    return None


def cap_len(s, limit):
    """Like truncate_collapse but does not collapse internal whitespace -
    cwd values are filesystem paths, not free text."""
    return s[:limit] if isinstance(s, str) else ""


def read_custom_title(path, tail_bytes=512 * 1024):
    """Latest `custom-title` line in the transcript = the session title the desktop app / CLI
    shows. Titles are rewritten often, so the newest one is near the end: read the tail only."""
    if not isinstance(path, str) or not path:
        return None
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - tail_bytes))
            chunk = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    title = None
    for line in chunk.splitlines():
        if '"custom-title"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") == "custom-title" and isinstance(obj.get("customTitle"), str):
            title = obj["customTitle"]
    return truncate_collapse(title, 80) if title else None


def read_transcript_model(path, tail_bytes=256 * 1024, not_before=None):
    """Model of the newest assistant message in the transcript (`message.model`).
    `not_before` (epoch) skips lines older than the session's own start - see
    transcript_is_stale for why an old tail must not name the model."""
    if not isinstance(path, str) or not path:
        return None
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - tail_bytes))
            chunk = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    model = None
    for line in chunk.splitlines():
        if '"assistant"' not in line or '"model"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        msg = obj.get("message") if isinstance(obj.get("message"), dict) else None
        if obj.get("type") == "assistant" and msg and isinstance(msg.get("model"), str):
            if not_before is not None:
                epoch = _transcript_epoch(obj.get("timestamp"))
                if epoch is not None and epoch < not_before:
                    continue
            model = msg["model"]
    return model[:60] if model else None


def read_codex_transcript_model(path, tail_bytes=256 * 1024):
    """Model from the newest `turn_context` line in a Codex rollout
    transcript (SPEC §17.7): `model` can change between turns, so only the
    last one in the tail matters. Verified 2026-09-03 against real
    ~/.codex/sessions files: it always lives under `payload.model`, never at
    the top level of the line - the top level is still accepted here for
    robustness against a future/older CLI version."""
    if not isinstance(path, str) or not path:
        return None
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - tail_bytes))
            chunk = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    model = None
    for line in chunk.splitlines():
        if '"turn_context"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") != "turn_context":
            continue
        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        m = payload.get("model") if isinstance(payload.get("model"), str) else obj.get("model")
        if isinstance(m, str) and m.strip():
            model = m.strip()
    return model[:60] if model else None


def resolve_provider(agent, env):
    """Where the model is served from: anthropic | openai | openrouter | local | custom."""
    if agent == "codex":
        base = env.get("OPENAI_BASE_URL", "")
        return classify_base_url(base, "openai")
    if agent == "claude":
        return classify_base_url(env.get("ANTHROPIC_BASE_URL", ""), "anthropic")
    return None


def classify_base_url(base, default):
    b = (base or "").strip().lower()
    if not b:
        return default
    if "openrouter" in b:
        return "openrouter"
    if any(h in b for h in ("localhost", "127.0.0.1", "0.0.0.0", "://host.docker", "ollama", "lmstudio", ":11434", ":1234")):
        return "local"
    if default == "anthropic" and "anthropic.com" in b:
        return default
    if default == "openai" and "openai.com" in b:
        return default
    return "custom"


def read_codex_model():
    """`model = "…"` from ~/.codex/config.toml (a few KB, read only on SessionStart)."""
    try:
        with open(os.path.expanduser("~/.codex/config.toml"), "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("model") and "=" in line and not line.startswith("model_"):
                    value = line.split("=", 1)[1].strip().strip('"').strip("'")
                    return value[:60] or None
    except OSError:
        return None
    return None


def sanitize_background_tasks(bg):
    out = []
    if not isinstance(bg, list):
        return out
    for item in bg[:10]:
        if isinstance(item, dict):
            entry = {}
            for key in ("id", "task_id", "agent_id", "type", "kind", "status", "description", "summary"):
                v = item.get(key)
                if isinstance(v, (str, int)):
                    entry[key] = truncate_collapse(str(v), 80)
            out.append(entry if entry else {"keys": ",".join(sorted(map(str, item.keys())))[:80]})
        elif isinstance(item, (str, int)):
            out.append({"id": truncate_collapse(str(item), 80)})
    return out


def is_injected_prompt(text):
    """The harness delivers task notifications, system reminders and cross-session messages
    through UserPromptSubmit too; they must never become a session's title."""
    if not isinstance(text, str):
        return False
    head = text.lstrip()[:24].lower()
    return head.startswith("<") or head.startswith("[system")


def scan_transcript_for_title(path):
    """First 200 lines of the transcript JSONL, first user message whose
    content is a plain string (not a content-block list / tool result)."""
    if not isinstance(path, str) or not path:
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= 200:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                role = None
                content = None
                msg = obj.get("message")
                if isinstance(msg, dict):
                    role = msg.get("role")
                    content = msg.get("content")
                elif obj.get("type") == "user":
                    role = "user"
                    content = obj.get("content")
                if role == "user" and isinstance(content, str) and content.strip():
                    return truncate_collapse(content, 80)
    except Exception:
        return None
    return None

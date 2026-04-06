#!/usr/bin/env python3
"""Extract a condensed session digest from a Claude Code JSONL file.

Usage:
    python3 extract-session-digest.py <path-to-jsonl>
    python3 extract-session-digest.py --metadata-only <path-to-jsonl>

Outputs a single JSON object to stdout with session metadata, condensed
user/assistant text, tools used, files touched, and signal detection.

--metadata-only: Skip full text extraction, only output counts and dates.
"""

import json
import sys
import re

SIGNAL_KEYWORDS = {
    "pendientes": [
        "todo", "fixme", "pendiente", "despues", "después",
        "proxima sesion", "próxima sesión", "hay que", "falta",
        "queda pendiente", "verificar", "confirmar", "monitorear",
    ],
    "plans": [
        "plan mode", "exitplanmode", "enterplanmode",
        "arquitectura", "diseño del", "implementacion",
        "implementation plan",
    ],
    "research": [],  # detected via tool usage, not keywords
    "learnings": [
        "gotcha", "cuidado", "importante:", "regla:", "nunca",
        "siempre", "aprendimos", "leccion", "lección", "ojo:",
        "critical:", "warning:", "tricky",
    ],
}

RESEARCH_TOOLS = {"WebSearch", "WebFetch", "mcp__fetcher__fetch_url", "mcp__fetcher__fetch_urls"}

TRIVIAL_LINE_THRESHOLD = 15
TRIVIAL_USER_MSG_THRESHOLD = 3
MAX_USER_MESSAGES = 100
TRUNCATION_KEEP_FIRST = 20
TRUNCATION_KEEP_LAST = 10
MAX_TEXT_LEN_USER = 500
MAX_TEXT_LEN_ASSISTANT = 1000


def is_system_reminder(text):
    """Check if text is primarily a system-reminder injection."""
    if not text:
        return False
    return "<system-reminder>" in text or text.strip().startswith("<system-reminder>")


def extract_user_text(content):
    """Extract meaningful user text from message content."""
    if isinstance(content, str):
        if is_system_reminder(content) or len(content.strip()) <= 5:
            return None
        # Strip system-reminder blocks from mixed content
        cleaned = re.sub(r"<system-reminder>.*?</system-reminder>", "", content, flags=re.DOTALL).strip()
        # Also strip local-command-caveat blocks
        cleaned = re.sub(r"<local-command-caveat>.*?</local-command-caveat>", "", cleaned, flags=re.DOTALL).strip()
        cleaned = re.sub(r"<command-name>.*?</command-name>", "", cleaned, flags=re.DOTALL).strip()
        cleaned = re.sub(r"<command-message>.*?</command-message>", "", cleaned, flags=re.DOTALL).strip()
        cleaned = re.sub(r"<command-args>.*?</command-args>", "", cleaned, flags=re.DOTALL).strip()
        cleaned = re.sub(r"<local-command-stdout>.*?</local-command-stdout>", "", cleaned, flags=re.DOTALL).strip()
        if len(cleaned) <= 5:
            return None
        return cleaned[:MAX_TEXT_LEN_USER]
    elif isinstance(content, list):
        parts = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text":
                text = item.get("text", "").strip()
                if text and not is_system_reminder(text) and len(text) > 5:
                    cleaned = re.sub(r"<system-reminder>.*?</system-reminder>", "", text, flags=re.DOTALL).strip()
                    if len(cleaned) > 5:
                        parts.append(cleaned[:MAX_TEXT_LEN_USER])
            # Skip tool_result blocks entirely (bulk of file size)
        return "\n".join(parts) if parts else None
    return None


def extract_digest(filepath, metadata_only=False):
    """Extract session digest from JSONL file."""
    user_texts = []
    assistant_texts = []
    tools_used = set()
    files_touched = set()
    custom_title = None
    slug = None
    ts_first = None
    ts_last = None
    line_count = 0
    session_id = None
    git_branch = None
    permission_modes = set()

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            line_count += 1
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            t = obj.get("type")
            ts = obj.get("timestamp", "")

            if ts:
                if ts_first is None or ts < ts_first:
                    ts_first = ts
                if ts_last is None or ts > ts_last:
                    ts_last = ts

            if not session_id and obj.get("sessionId"):
                session_id = obj["sessionId"]

            if not git_branch and obj.get("gitBranch"):
                git_branch = obj["gitBranch"]

            if t == "custom-title":
                custom_title = obj.get("customTitle") or obj.get("title")

            if obj.get("slug"):
                slug = obj["slug"]

            if obj.get("permissionMode"):
                permission_modes.add(obj["permissionMode"])

            if metadata_only:
                # Still count user messages for trivial detection
                if t == "user" and obj.get("message"):
                    msg = obj["message"]
                    content = msg.get("content", "") if isinstance(msg, dict) else ""
                    text = extract_user_text(content)
                    if text:
                        user_texts.append("")  # placeholder for counting
                continue

            # Extract user messages
            if t == "user" and obj.get("message"):
                msg = obj["message"]
                content = msg.get("content", "") if isinstance(msg, dict) else ""
                text = extract_user_text(content)
                if text:
                    user_texts.append(text)

            # Extract assistant text (skip thinking blocks)
            if t == "assistant" and obj.get("message"):
                msg = obj["message"]
                if isinstance(msg, dict):
                    for item in msg.get("content", []):
                        if not isinstance(item, dict):
                            continue
                        if item.get("type") == "text":
                            text = item.get("text", "").strip()
                            if text:
                                assistant_texts.append(text[:MAX_TEXT_LEN_ASSISTANT])
                        elif item.get("type") == "tool_use":
                            name = item.get("name", "")
                            if name:
                                tools_used.add(name)
                            inp = item.get("input", {})
                            if isinstance(inp, dict):
                                for k in ("file_path", "path", "command", "pattern", "query"):
                                    if k in inp:
                                        val = str(inp[k])[:200]
                                        files_touched.add(val)

    # Truncation for large sessions
    if len(user_texts) > MAX_USER_MESSAGES and not metadata_only:
        # Keep first N, last M, and any with signal keywords
        all_keywords = []
        for kw_list in SIGNAL_KEYWORDS.values():
            all_keywords.extend(kw_list)

        signal_indices = set()
        for i, text in enumerate(user_texts):
            text_lower = text.lower()
            if any(kw in text_lower for kw in all_keywords):
                signal_indices.add(i)

        keep_indices = set(range(TRUNCATION_KEEP_FIRST))
        keep_indices.update(range(len(user_texts) - TRUNCATION_KEEP_LAST, len(user_texts)))
        keep_indices.update(signal_indices)

        user_texts = [user_texts[i] for i in sorted(keep_indices) if i < len(user_texts)]

    # Detect signals
    all_text = "\n".join(user_texts + assistant_texts).lower() if not metadata_only else ""

    signals = {
        "pendientes": any(kw in all_text for kw in SIGNAL_KEYWORDS["pendientes"]) if all_text else False,
        "plans": (
            any(kw in all_text for kw in SIGNAL_KEYWORDS["plans"])
            or "plan" in permission_modes
        ),
        "research": bool(tools_used & RESEARCH_TOOLS),
        "learnings": any(kw in all_text for kw in SIGNAL_KEYWORDS["learnings"]) if all_text else False,
    }

    is_trivial = line_count < TRIVIAL_LINE_THRESHOLD or len(user_texts) < TRIVIAL_USER_MSG_THRESHOLD

    result = {
        "sessionId": session_id,
        "customTitle": custom_title,
        "slug": slug,
        "lineCount": line_count,
        "dateFirst": ts_first[:10] if ts_first else None,
        "dateLast": ts_last[:10] if ts_last else None,
        "tsFirst": ts_first,
        "tsLast": ts_last,
        "gitBranch": git_branch,
        "userMessageCount": len(user_texts),
        "assistantMessageCount": len(assistant_texts),
        "trivial": is_trivial,
        "signals": signals,
        "permissionModes": sorted(permission_modes),
        "toolsUsed": sorted(tools_used),
    }

    if not metadata_only:
        result["userTexts"] = user_texts
        result["assistantTexts"] = assistant_texts
        result["filesTouched"] = sorted(files_touched)[:50]

    return result


def main():
    args = sys.argv[1:]
    metadata_only = False

    if "--metadata-only" in args:
        metadata_only = True
        args.remove("--metadata-only")

    if not args:
        print("Usage: extract-session-digest.py [--metadata-only] <jsonl-file>", file=sys.stderr)
        sys.exit(1)

    filepath = args[0]
    try:
        result = extract_digest(filepath, metadata_only=metadata_only)
        json.dump(result, sys.stdout, ensure_ascii=False, indent=None)
        print()  # trailing newline
    except FileNotFoundError:
        print(json.dumps({"error": f"File not found: {filepath}"}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()

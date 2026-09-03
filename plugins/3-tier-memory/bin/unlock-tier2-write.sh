#!/bin/bash
# 3-tier-memory plugin: PostToolUse + PostToolUseFailure hook (Write|Edit)
# Releases the lock acquired by lock-tier2-write.sh (PreToolUse) for the same file.
# Registered under BOTH events: PostToolUse fires only on tool success, so a failed
# Edit (e.g. a stale old_string that no longer matches) would otherwise leave the lock
# held until the staleness window elapses — PostToolUseFailure closes that gap.
#
# Ownership-checked release: only remove the lock if it's still the one THIS tool call
# acquired (tool_use_id is stable across the PreToolUse/PostToolUse pair for one call,
# per Claude Code's hook contract). Without this, a holder that ran unusually long could
# release a DIFFERENT process's lock that had since taken over the same path — a real
# bug an adversary found in an earlier version, which unconditionally rm -rf'd by path
# alone. If the owner marker is missing (a lock from a fail-open path, or a legacy state),
# fail open toward releasing rather than leaking — no-op is the same failure class this
# hook exists to prevent.

RAW=$(cat)

case "$RAW" in
  *_pendientes.md*|*_session-index.md*|*_learnings.md*|*_plans-index.md*|*_research-index.md*) ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

FILE_PATH=$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
TOOL_USE_ID=$(printf '%s' "$RAW" | jq -r '.tool_use_id // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  _pendientes.md|_session-index.md|_learnings.md|_plans-index.md|_research-index.md) ;;
  *) exit 0 ;;
esac

LOCKDIR="$(dirname "$FILE_PATH")/.locks/${BASENAME}.lock"
[ -d "$LOCKDIR" ] || exit 0

OWNER=$(cat "$LOCKDIR/owner" 2>/dev/null)
if [ -n "$OWNER" ] && [ -n "$TOOL_USE_ID" ] && [ "$OWNER" != "$TOOL_USE_ID" ]; then
  # This lock belongs to a different tool call than the one that's releasing (a stale
  # takeover happened underneath us) — don't delete someone else's live lock.
  exit 0
fi

rm -rf "$LOCKDIR" 2>/dev/null
exit 0

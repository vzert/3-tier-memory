#!/bin/bash
# 3-tier-memory plugin: PreToolUse hook (Write|Edit)
# Mutual-exclusion lock for the 5 Tier-2 index files, so concurrent agents/sessions
# on the same project don't corrupt a shared file with an interleaved read-modify-write.
#
# Primitive: mkdir (atomic between processes on POSIX per mkdir(2). On Windows, CreateDirectoryW
# was measured 2026-09-03 on windows-latest/Git Bash through Python's os.mkdir — 16 processes x 40
# rounds racing for the same directory, exactly 1 winner every round; GitHub Actions run
# https://github.com/vzert/3-tier-memory/actions/runs/33776716992, branch ci/windows-journal-tests,
# step "mkdir atomico entre procesos". This hook calls coreutils `mkdir` from Git Bash, which
# reaches the same Win32 call, but that bash path itself was not probed) — NOT flock, which
# doesn't exist as a CLI on macOS and is Linux-only, so it can't ship in a cross-platform
# plugin. Staleness is mtime-based (an "acquired_at" epoch marker), not PID-liveness —
# checking whether a PID is alive isn't portable across the platforms this plugin ships to.
# Ownership is tool_use_id-based (see below), not PID-based, for the same reason.
#
# What this does and does NOT guarantee: the lock gives true mutual exclusion of the
# WRITE itself (no two Write/Edit calls corrupt the file at the byte level). It does NOT
# make a stale read safe — an agent that read the file before the lock existed and later
# writes based on that stale copy can still silently lose another writer's change. Edit's
# own old_string exact-match narrows this for targeted edits (the file's real write shape,
# per checkpoint-3t.md — a targeted insert after a stable anchor, not a full rewrite);
# measured: concurrent Edit-shaped writes preserved 40/40 across 5 trials, vs ~17-23/40 for
# a full-file Write rebuilt from a stale read. Because Write has no such check and IS the
# dangerous shape, this hook denies Write to a Tier-2 file that already exists (below) —
# Write is only safe for the first-ever creation of one of these files, and even that is
# now checked AFTER lock acquisition (see below), not before — a same-instant race between
# two first-time Writes is a real, measured TOCTOU if checked before the lock is held.
#
# Fail-open by design: any unexpected condition here (missing jq, unwritable dir, etc.)
# exits 0 and lets the write through. A buggy lock that bricks every write for every
# single-agent install is worse than the intermittent race it exists to prevent.

RAW=$(cat)

# Fast path: substring-test the raw JSON before spawning any subprocess. The overwhelming
# majority of Write/Edit calls never touch a Tier-2 file — pay zero jq/subshell cost for those.
case "$RAW" in
  *_pendientes.md*|*_session-index.md*|*_learnings.md*|*_plans-index.md*|*_research-index.md*) ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

TOOL_NAME=$(printf '%s' "$RAW" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
TOOL_USE_ID=$(printf '%s' "$RAW" | jq -r '.tool_use_id // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  _pendientes.md|_session-index.md|_learnings.md|_plans-index.md|_research-index.md) ;;
  *) exit 0 ;;
esac

LOCK_PARENT="$(dirname "$FILE_PATH")/.locks"
LOCKDIR="$LOCK_PARENT/${BASENAME}.lock"
STEALDIR="$LOCK_PARENT/${BASENAME}.steal"
mkdir -p "$LOCK_PARENT" 2>/dev/null

# Staleness is generous on purpose: it exists to self-heal from a crashed/cancelled
# holder, not to bound a legitimate hold. A single Write/Edit tool call should complete
# in well under a second — but the threshold must comfortably exceed any real hold, or a
# still-legitimate holder can have its live lock stolen out from under it (a real,
# adversary-found bug in an earlier version of this script that used an 8s threshold).
STALE_SECONDS=60
# The WAITER's budget, unrelated to staleness: how long a contending caller retries
# before giving up. Kept short for UX — a fast, clear deny beats a long stall — and stays
# comfortably under this hook's configured timeout in hooks.json so the deny is always an
# explicit exit 2, never dependent on how the harness handles an exceeded hook timeout
# (undocumented either way for a command-type PreToolUse hook, confirmed by direct doc
# lookup — this design doesn't rely on the answer regardless).
BUDGET_SECONDS=3
DEADLINE=$(( $(date +%s) + BUDGET_SECONDS ))

cleanup_steal() {
  rmdir "$STEALDIR" 2>/dev/null
}

while true; do
  if mkdir "$LOCKDIR" 2>/dev/null; then
    date +%s > "$LOCKDIR/acquired_at" 2>/dev/null
    [ -n "$TOOL_USE_ID" ] && printf '%s' "$TOOL_USE_ID" > "$LOCKDIR/owner" 2>/dev/null
    break
  fi

  if [ ! -d "$LOCKDIR" ]; then
    # mkdir failed but no lock is actually there: a genuine unexpected error
    # (permissions, read-only fs, disk full) — fail OPEN rather than block forever.
    exit 0
  fi

  # Orphan reclaim: a lock older than STALE_SECONDS (or missing its marker entirely —
  # a legitimate holder always writes it right after mkdir, so its absence is itself
  # anomalous) means the holder crashed/was cancelled without releasing. Gate the actual
  # reclaim behind its own mkdir so only ONE process performs it — otherwise two processes
  # can both judge it stale, both rm -rf, and both then mkdir the lock fresh (a real,
  # measured mutual-exclusion break in an earlier version of this script).
  ACQUIRED_AT=$(cat "$LOCKDIR/acquired_at" 2>/dev/null)
  NOW=$(date +%s)
  if [ -z "$ACQUIRED_AT" ] || [ "$((NOW - ACQUIRED_AT))" -gt "$STALE_SECONDS" ]; then
    if mkdir "$STEALDIR" 2>/dev/null; then
      # Re-verify staleness now that we've won the right to reclaim — the lock may have
      # been legitimately refreshed (or released and reacquired by someone else) between
      # our read above and winning this gate.
      ACQUIRED_AT2=$(cat "$LOCKDIR/acquired_at" 2>/dev/null)
      NOW2=$(date +%s)
      if [ -z "$ACQUIRED_AT2" ] || [ "$((NOW2 - ACQUIRED_AT2))" -gt "$STALE_SECONDS" ]; then
        rm -rf "$LOCKDIR" 2>/dev/null
      fi
      cleanup_steal
      continue
    fi
    # Someone else is already reclaiming — fall through to the wait/retry below.
  fi

  if [ "$NOW" -ge "$DEADLINE" ]; then
    echo "Tier-2 memory file '$BASENAME' is locked by another concurrent write. Retry the edit." >&2
    exit 2
  fi

  sleep 0.1
done

# We now hold the lock. Check Write-vs-existing-file AFTER acquiring, not before — checking
# first is a TOCTOU: two concurrent first-time Writes can both see "file doesn't exist" and
# both proceed, so the second one silently overwrites the first's freshly created content
# once it gets the lock. Checked here, only the actual lock holder's view of the filesystem
# counts.
if [ "$TOOL_NAME" = "Write" ] && [ -f "$FILE_PATH" ]; then
  rm -rf "$LOCKDIR" 2>/dev/null
  echo "Tier-2 index '$BASENAME' already exists — use Edit, not Write, so a stale full-file rewrite can't silently drop another writer's change." >&2
  exit 2
fi

exit 0

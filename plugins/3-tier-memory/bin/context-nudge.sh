#!/bin/bash
# 3-tier-memory plugin: UserPromptSubmit hook — context-aware checkpoint nudge.
#
# Suggests /checkpoint-3t when the conversation crosses a configurable fraction of the
# model's context window, computed from the ACTUAL token usage recorded in the transcript.
# This is independent of the harness auto-compact (which may fire prematurely and does NOT
# scale to a 1M window). It also REPLACES the PreCompact reminder for users who disable
# auto-compact to use the full window.
#
# Configurable via env (the harness does not expose the [1m] variant, so the window is a knob):
#   THREET_CONTEXT_WINDOW    total context window in tokens (default 200000; set 1000000 on 1M models)
#   THREET_CHECKPOINT_RATIO  fraction at which to start nudging (default 0.8)
#
# De-duped: nudges once per 10%-of-window bucket crossed, not every turn; resets after a drop.

source "$(dirname "$0")/resolve-project-dir.sh"

# Only nudge if a memory system exists (consistent with the other hooks)
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g')
if [ ! -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ] \
   && [ ! -f "$HOME/.claude/projects/$ENCODED/memory/_pendientes.md" ]; then
  exit 0
fi

STATE_DIR="$HOME/.claude/projects/$ENCODED"
mkdir -p "$STATE_DIR" 2>/dev/null

CTX_INPUT="$_HOOK_INPUT" \
CTX_WINDOW="${THREET_CONTEXT_WINDOW:-200000}" \
CTX_RATIO="${THREET_CHECKPOINT_RATIO:-0.8}" \
CTX_STATEFILE="$STATE_DIR/.ctx-nudge" \
python3 <<'PYEOF' 2>/dev/null
import json, os, sys

try:
    data = json.loads(os.environ.get("CTX_INPUT", ""))
except Exception:
    sys.exit(0)
tpath = data.get("transcript_path", "")
if not tpath or not os.path.isfile(tpath):
    sys.exit(0)

window = int(float(os.environ["CTX_WINDOW"]))
ratio = float(os.environ["CTX_RATIO"])
statefile = os.environ["CTX_STATEFILE"]
if window <= 0:
    sys.exit(0)
threshold = window * ratio

# Read the most recent usage record from the TAIL of the transcript (don't parse it all).
usage_total = 0
try:
    with open(tpath, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - 262144))  # last 256KB holds the recent messages
        tail = f.read().decode("utf-8", "replace")
    for line in reversed(tail.splitlines()):
        if '"usage"' not in line:
            continue
        try:
            u = (json.loads(line).get("message") or {}).get("usage") or {}
        except Exception:
            continue
        tot = ((u.get("input_tokens") or 0)
               + (u.get("cache_read_input_tokens") or 0)
               + (u.get("cache_creation_input_tokens") or 0))
        if tot:
            usage_total = tot
            break
except Exception:
    sys.exit(0)

if usage_total < threshold:
    # Reset the de-dupe state once we're well below threshold (e.g. after a compaction),
    # so the next time the context fills up it nudges again.
    if usage_total < threshold * 0.6:
        try:
            os.remove(statefile)
        except OSError:
            pass
    sys.exit(0)

# De-dupe: only nudge when crossing into a new 10%-of-window bucket.
bucket = int(usage_total // (window * 0.1))
last = -1
try:
    with open(statefile) as f:
        last = int((f.read().strip() or "-1"))
except Exception:
    pass
if bucket <= last:
    sys.exit(0)
try:
    with open(statefile, "w") as f:
        f.write(str(bucket))
except OSError:
    pass

pct = round(100 * usage_total / window)
msg = (f"CONTEXTO ~{pct}% del window ({usage_total // 1000}k/{window // 1000}k tokens) — "
       f"considera /checkpoint-3t pronto para no perder progreso de esta conversacion.")
if window == 200000:  # default/unconfigured — hint how to scale to a larger model
    msg += " (Si tu modelo es de 1M, exporta THREET_CONTEXT_WINDOW=1000000 para que el aviso no llegue prematuro.)"
print(msg)
PYEOF

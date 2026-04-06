#!/bin/bash
# 3-tier-memory plugin: Multi-dev detection
# Sourced by hooks to detect multi-dev mode and developer identity
#
# Exports:
#   MEMORY_MULTI_DEV  - "true" if multi-dev mode is active, empty otherwise
#   MEMORY_DEV        - username of current developer (via whoami)
#   MEMORY_PRUNE_SESSIONS       - max session index rows to keep (default: 10 single, 50 multi)
#   MEMORY_PRUNE_PLANS_COMPLETED - max completed plan rows to keep (default: 5 single, 20 multi)

MEMORY_MULTI_DEV=""
MEMORY_DEV=""
MEMORY_PRUNE_SESSIONS=""
MEMORY_PRUNE_PLANS_COMPLETED=""

# Find memory config
CONFIG_FILE=""
if [ -f "$CLAUDE_PROJECT_DIR/memory/.memory-config" ]; then
  CONFIG_FILE="$CLAUDE_PROJECT_DIR/memory/.memory-config"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g')
  AUTO_CONFIG="$HOME/.claude/projects/$ENCODED/memory/.memory-config"
  if [ -f "$AUTO_CONFIG" ]; then
    CONFIG_FILE="$AUTO_CONFIG"
  fi
fi

if [ -n "$CONFIG_FILE" ]; then
  # Check multi-dev flag
  if grep -q '^multi-dev:[[:space:]]*true' "$CONFIG_FILE" 2>/dev/null; then
    MEMORY_MULTI_DEV="true"
    MEMORY_DEV="$(whoami)"
  fi

  # Read prune thresholds (override defaults)
  _val=$(grep '^prune-sessions:' "$CONFIG_FILE" 2>/dev/null | sed 's/^prune-sessions:[[:space:]]*//')
  [ -n "$_val" ] && MEMORY_PRUNE_SESSIONS="$_val"

  _val=$(grep '^prune-plans-completed:' "$CONFIG_FILE" 2>/dev/null | sed 's/^prune-plans-completed:[[:space:]]*//')
  [ -n "$_val" ] && MEMORY_PRUNE_PLANS_COMPLETED="$_val"
fi

# Apply defaults based on mode
if [ -z "$MEMORY_PRUNE_SESSIONS" ]; then
  [ "$MEMORY_MULTI_DEV" = "true" ] && MEMORY_PRUNE_SESSIONS=50 || MEMORY_PRUNE_SESSIONS=10
fi
if [ -z "$MEMORY_PRUNE_PLANS_COMPLETED" ]; then
  [ "$MEMORY_MULTI_DEV" = "true" ] && MEMORY_PRUNE_PLANS_COMPLETED=20 || MEMORY_PRUNE_PLANS_COMPLETED=5
fi

export MEMORY_MULTI_DEV MEMORY_DEV MEMORY_PRUNE_SESSIONS MEMORY_PRUNE_PLANS_COMPLETED

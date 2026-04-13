#!/bin/bash
# Resolve CLAUDE_PROJECT_DIR from hook stdin if not set in environment
# Sourced by: all hook scripts in bin/
# Buffers stdin into $_HOOK_INPUT for downstream use

_HOOK_INPUT=$(cat)

# Resolve CLAUDE_PLUGIN_ROOT from script path if not in environment
if [ -z "$CLAUDE_PLUGIN_ROOT" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if [ -z "$CLAUDE_PROJECT_DIR" ]; then
  if command -v jq >/dev/null 2>&1; then
    CLAUDE_PROJECT_DIR=$(echo "$_HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  else
    CLAUDE_PROJECT_DIR=$(echo "$_HOOK_INPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
  fi
fi

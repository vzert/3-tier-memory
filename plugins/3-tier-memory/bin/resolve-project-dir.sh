#!/bin/bash
# Resolve CLAUDE_PROJECT_DIR from hook stdin if not set in environment
# Sourced by: all hook scripts in bin/
# Buffers stdin into $_HOOK_INPUT for downstream use

_HOOK_INPUT=$(cat)

if [ -z "$CLAUDE_PROJECT_DIR" ]; then
  if command -v jq >/dev/null 2>&1; then
    CLAUDE_PROJECT_DIR=$(echo "$_HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  else
    CLAUDE_PROJECT_DIR=$(echo "$_HOOK_INPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
  fi
fi

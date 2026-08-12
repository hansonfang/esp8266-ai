#!/bin/sh
# Codex Hook adapter: only the lifecycle event name leaves this process.
# The hook deliberately fails open so an unavailable clock never blocks Codex.
case "$1" in
  UserPromptSubmit|PreToolUse|PostToolUse|SubagentStart|SubagentStop|PreCompact|Stop)
    curl -fsS --max-time 1 -X POST http://127.0.0.1:8765/event \
      -H 'Content-Type: application/json' \
      --data "{\"agent\":\"codex\",\"event\":\"$1\"}" >/dev/null 2>&1 || true
    ;;
esac

printf '{}\n'

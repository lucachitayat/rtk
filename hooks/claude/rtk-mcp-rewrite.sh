#!/usr/bin/env bash
# rtk-mcp-hook-version: 1
# RTK Claude Code hook — rewrites MCP tool inputs for token savings.
# Requires: rtk >= 0.37.0 (for `mcp-rewrite` subcommand), jq.
#
# Currently supports: mcp__rider__* (injects worktree/obj/bin excludes into
# search_text / search_regex / search_file / search_symbol calls).
#
# Exit code protocol for `rtk mcp-rewrite`:
#   0 + stdout JSON   Rewrite applied → emit updatedInput
#   1                 No rewrite → pass through

if ! command -v jq &>/dev/null; then
  exit 0
fi

if ! command -v rtk &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT")

# Short-circuit on anything we don't know how to rewrite. Keep this prefix
# list in sync with the dispatch in src/hooks/mcp_rewrite_cmd.rs.
case "$TOOL_NAME" in
  mcp__rider__*) ;;
  *) exit 0 ;;
esac

TOOL_INPUT=$(jq -c '.tool_input' <<<"$INPUT")
if [ -z "$TOOL_INPUT" ] || [ "$TOOL_INPUT" = "null" ]; then
  exit 0
fi

REWRITTEN=$(rtk mcp-rewrite "$TOOL_NAME" "$TOOL_INPUT" 2>/dev/null)
EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
  # 1 = passthrough; any other non-zero = swallow and passthrough.
  exit 0
fi

# Emit updatedInput so Claude Code transparently sends the modified tool_input
# to the MCP server. We deliberately DO NOT set permissionDecision: the MCP
# call is subject to whatever permission rule the user has configured — we
# only touched the input.
jq -n -c --argjson new "$REWRITTEN" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "updatedInput": $new
  }
}'

#!/usr/bin/env bash
set -euo pipefail

# Launches claude with the appropriate role profile and system prompt.
# Usage: claude.sh <role> [team_number]
#   role:        manager | engineer | reviewer | orchestrator
#   team_number: e.g. 01, 02 (required for all roles except orchestrator)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="$1"
TEAM_NUM="${2:-}"

# Build the system prompt from role prompt + common prompts.
PROMPT="$(cat "$SCRIPT_DIR/prompts/$ROLE.md" "$SCRIPT_DIR/prompts/common/"*.md)"

# Substitute TEAM_NUM placeholder if a team number was provided.
if [[ -n "$TEAM_NUM" ]]; then
    PROMPT="${PROMPT//TEAM_NUM/$TEAM_NUM}"
fi

exec claude --dangerously-skip-permissions \
    --settings "$SCRIPT_DIR/profiles/$ROLE.json" \
    --append-system-prompt "$PROMPT"

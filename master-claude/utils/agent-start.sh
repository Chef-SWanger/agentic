#!/usr/bin/env bash
set -euo pipefail

# Bootstrap script for team agents. Stashes dirty state, pulls latest,
# then launches claude with the appropriate role.
# Usage: agent-start.sh <role> <team_number>
#   role:        manager | engineer | reviewer
#   team_number: e.g. 01, 02

ROLE="$1"
TEAM_NUM="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Auto-detect VCS and sync to latest.
if [[ -d ".sl" ]]; then
    # Sapling repo.
    echo "Detected Sapling repo, syncing..."
    sl status 2>/dev/null | { grep '^!' || true; } | awk '{print $2}' | xargs -r sl forget 2>/dev/null || true
    if [ -n "$(sl status 2>/dev/null)" ]; then
        sl commit -m "WIP: temporary commit $(date '+%Y-%m-%d %H:%M:%S')" || true
    fi
    if ! sl pull; then
        echo "Warning: 'sl pull' failed. Continuing with current state..."
    fi
    sleep 2
    sl goto --rev remote/master || echo "Warning: 'sl goto remote/master' failed. Continuing..."

elif git rev-parse --git-dir &>/dev/null; then
    # Git repo.
    echo "Detected Git repo, syncing..."
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        git stash push -m "WIP: temporary stash $(date '+%Y-%m-%d %H:%M:%S')" || true
    fi
    git fetch origin 2>/dev/null || echo "Warning: 'git fetch' failed. Continuing with current state..."
    # Detect default branch name.
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || true
    if [[ -z "$default_branch" ]]; then
        # Fallback: try main, then master.
        if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
            default_branch="main"
        else
            default_branch="master"
        fi
    fi
    git rebase "origin/$default_branch" 2>/dev/null || echo "Warning: 'git rebase origin/$default_branch' failed. Continuing..."

else
    echo "Warning: No recognized VCS found. Continuing without sync..."
fi

# Launch claude with the appropriate role.
exec "$SCRIPT_DIR/utils/claude.sh" "$ROLE" "$TEAM_NUM"

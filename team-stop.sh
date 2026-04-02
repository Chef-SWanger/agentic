#!/bin/bash
# Stops team agents (Executor and Validator) for a given session base name.
# Called during gwt rm to clean up agent sessions.
#
# Usage: team-stop.sh <session-base>
#   session-base - base name used when starting the team (e.g. "myrepo-feature")

SESSION_BASE="$1"

if [[ -z "$SESSION_BASE" ]]; then
  echo "Usage: team-stop.sh <session-base>"
  exit 1
fi

for suffix in executor validator; do
  session="${SESSION_BASE}-${suffix}"
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux kill-session -t "$session"
    echo "Stopped: $session"
  fi
done

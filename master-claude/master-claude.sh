#!/usr/bin/env bash
#
# master-claude — Team-based multi-agent orchestration CLI
# Usage: master-claude <command> [args]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TMUX_SOCKET="master-claude"
LOG_DIR="${HOME}/.master-claude/logs"

# Defaults (can be overridden by ~/.master-claude/config).
CHECKOUT_BASE="${HOME}/fbsource-multi"
CHECKOUT_PREFIX="fbsource"

# Load user config if it exists.
CONFIG_FILE="${HOME}/.master-claude/config"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage:
    master-claude setup <repo-path> <N>  Create N checkouts/worktrees from a repo
    master-claude start <N>              Start team N (manager + engineer + reviewer)
    master-claude stop <N>               Stop team N
    master-claude list                   List running teams & agents
    master-claude connect <N> [role]     Attach to agent (default: manager)
    master-claude logs <N> [role]        View logs (default: manager)
    master-claude orchestrator:start     Start cross-team orchestrator
    master-claude orchestrator:stop      Stop orchestrator
    master-claude stop-all               Stop everything (kill-server)
    master-claude config                 Show current configuration
EOF
}

die() {
    echo "Error: $*" >&2
    echo >&2
    usage >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

# Format team number to 2 digits (e.g. 1 -> 01, 03 -> 03).
fmt_team() {
    printf '%02d' "$1"
}

validate_team_num() {
    local n="$1"
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        die "Team number must be a positive integer, got: $n"
    fi
}

session_name() {
    local team="$1" role="$2"
    echo "team_${team}_${role}"
}

session_log_file() {
    local session="$1"
    echo "${LOG_DIR}/${session}.log"
}

check_session_alive() {
    local session="$1"
    tmux -L "$TMUX_SOCKET" has-session -t "$session" 2>/dev/null
}

checkout_dir() {
    local team="$1"
    echo "${CHECKOUT_BASE}/${CHECKOUT_PREFIX}${team}"
}

# ---------------------------------------------------------------------------
# team:start N
# ---------------------------------------------------------------------------

team_start() {
    local n="$1"
    validate_team_num "$n"
    local team
    team=$(fmt_team "$n")

    local checkout
    checkout=$(checkout_dir "$team")

    if [[ ! -d "$checkout" ]]; then
        die "Checkout not found: $checkout. Run 'master-claude setup <repo-path> <N>' first."
    fi

    # Check if team is already running.
    if check_session_alive "$(session_name "$team" manager)" 2>/dev/null; then
        die "Team $team is already running. Stop it first with: master-claude stop $team"
    fi

    ensure_log_dir

    echo "Starting team $team (checkout: $checkout)"

    # Clean up any stale sessions from this team.
    for role in manager engineer reviewer; do
        local sess
        sess=$(session_name "$team" "$role")
        tmux -L "$TMUX_SOCKET" kill-session -t "$sess" 2>/dev/null || true
    done

    # Start each role sequentially to avoid Claude config conflicts.
    for role in manager engineer reviewer; do
        local sess
        sess=$(session_name "$team" "$role")
        local log_file
        log_file=$(session_log_file "$sess")

        echo "  Starting $sess..."

        # Write log header.
        {
            echo "=== master-claude $sess started at $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
            echo "=== checkout: $checkout ==="
            echo ""
        } >> "$log_file"

        # Create tmux session in the checkout directory.
        if ! tmux -L "$TMUX_SOCKET" new-session -d -s "$sess" -c "$checkout" 2>/dev/null; then
            # If this is the first session, tmux server might not exist yet.
            tmux -L "$TMUX_SOCKET" new-session -d -s "$sess" -c "$checkout"
        fi

        # Enable logging.
        tmux -L "$TMUX_SOCKET" pipe-pane -t "$sess" -o "cat >> '$log_file'"

        # Launch the agent.
        tmux -L "$TMUX_SOCKET" send-keys -t "$sess" \
            "$SCRIPT_DIR/utils/agent-start.sh $role $team" Enter

        # Wait for Claude to initialize.
        echo "    Waiting for Claude to initialize..."
        sleep 10

        # Verify session is alive.
        if ! check_session_alive "$sess"; then
            echo "    ERROR: $sess exited unexpectedly!"
            echo "    Check log: $log_file"
            continue
        fi

        # Accept permissions prompt.
        tmux -L "$TMUX_SOCKET" send-keys -t "$sess" Down Enter

        # Send activation prompt so the agent reads its journal + Memory.md.
        sleep 3
        tmux -L "$TMUX_SOCKET" send-keys -t "$sess" \
            'Run your On Activation steps: read your journal and ~/Memory.md. If they do not exist, create them. Then report ready.'
        sleep 1
        tmux -L "$TMUX_SOCKET" send-keys -t "$sess" Enter

        echo "    $sess is running."
    done

    echo ""
    echo "Team $team started. Use 'master-claude connect $team' to attach to the manager."
}

# ---------------------------------------------------------------------------
# team:stop N
# ---------------------------------------------------------------------------

team_stop() {
    local n="$1"
    validate_team_num "$n"
    local team
    team=$(fmt_team "$n")

    echo "Stopping team $team..."

    for role in manager engineer reviewer; do
        local sess
        sess=$(session_name "$team" "$role")
        if check_session_alive "$sess"; then
            tmux -L "$TMUX_SOCKET" kill-session -t "$sess"
            echo "  Stopped $sess"
        else
            echo "  $sess was not running"
        fi
    done

    echo "Team $team stopped."
}

# ---------------------------------------------------------------------------
# team:list
# ---------------------------------------------------------------------------

team_list() {
    if ! tmux -L "$TMUX_SOCKET" has-session 2>/dev/null; then
        echo "No master-claude sessions running."
        return 0
    fi

    local sessions
    sessions=$(tmux -L "$TMUX_SOCKET" list-sessions -F "#{session_name}" 2>/dev/null || true)

    if [[ -z "$sessions" ]]; then
        echo "No master-claude sessions running."
        return 0
    fi

    printf "%-20s %-12s %-10s\n" "SESSION" "TEAM" "ROLE"
    printf "%-20s %-12s %-10s\n" "-------" "----" "----"

    echo "$sessions" | sort | while IFS= read -r sess; do
        if [[ "$sess" =~ ^team_([0-9]+)_(.+)$ ]]; then
            local team="${BASH_REMATCH[1]}"
            local role="${BASH_REMATCH[2]}"
            printf "%-20s %-12s %-10s\n" "$sess" "$team" "$role"
        elif [[ "$sess" == "orchestrator" ]]; then
            printf "%-20s %-12s %-10s\n" "$sess" "-" "orchestrator"
        fi
    done
}

# ---------------------------------------------------------------------------
# connect N [role]
# ---------------------------------------------------------------------------

connect() {
    local n="$1"
    validate_team_num "$n"
    local role="${2:-manager}"
    local team
    team=$(fmt_team "$n")
    local sess
    sess=$(session_name "$team" "$role")

    if ! check_session_alive "$sess"; then
        die "Session $sess is not running."
    fi

    tmux -L "$TMUX_SOCKET" attach -t "$sess"
}

# ---------------------------------------------------------------------------
# logs N [role]
# ---------------------------------------------------------------------------

logs() {
    local n="$1"
    validate_team_num "$n"
    local role="${2:-manager}"
    local team
    team=$(fmt_team "$n")
    local sess
    sess=$(session_name "$team" "$role")
    local log_file
    log_file=$(session_log_file "$sess")

    if [[ ! -f "$log_file" ]]; then
        echo "No log file found at $log_file"
        echo "Available log files:"
        ls -la "$LOG_DIR"/*.log 2>/dev/null || echo "  (none)"
        return 1
    fi

    echo "=== Log file: $log_file ==="
    cat "$log_file"
}

# ---------------------------------------------------------------------------
# orchestrator:start
# ---------------------------------------------------------------------------

orchestrator_start() {
    local sess="orchestrator"

    if check_session_alive "$sess" 2>/dev/null; then
        die "Orchestrator is already running. Stop it first with: master-claude orchestrator:stop"
    fi

    ensure_log_dir

    local log_file
    log_file=$(session_log_file "$sess")

    echo "Starting orchestrator..."

    {
        echo "=== master-claude orchestrator started at $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
        echo ""
    } >> "$log_file"

    # Orchestrator runs from the script directory (no checkout needed).
    tmux -L "$TMUX_SOCKET" new-session -d -s "$sess" -c "$SCRIPT_DIR"

    tmux -L "$TMUX_SOCKET" pipe-pane -t "$sess" -o "cat >> '$log_file'"

    tmux -L "$TMUX_SOCKET" send-keys -t "$sess" \
        "$SCRIPT_DIR/utils/claude.sh orchestrator" Enter

    echo "  Waiting for Claude to initialize..."
    sleep 10

    if ! check_session_alive "$sess"; then
        echo "ERROR: Orchestrator session exited unexpectedly!"
        echo "Check log: $log_file"
        return 1
    fi

    tmux -L "$TMUX_SOCKET" send-keys -t "$sess" Down Enter

    echo "Orchestrator is running. Use 'master-claude connect orchestrator' to attach."
}

# ---------------------------------------------------------------------------
# orchestrator:stop
# ---------------------------------------------------------------------------

orchestrator_stop() {
    local sess="orchestrator"
    if check_session_alive "$sess"; then
        tmux -L "$TMUX_SOCKET" kill-session -t "$sess"
        echo "Orchestrator stopped."
    else
        echo "Orchestrator was not running."
    fi
}

# ---------------------------------------------------------------------------
# stop — kill everything
# ---------------------------------------------------------------------------

stop_all() {
    if tmux -L "$TMUX_SOCKET" has-session 2>/dev/null; then
        tmux -L "$TMUX_SOCKET" kill-server
        echo "All master-claude sessions stopped."
    else
        echo "No master-claude sessions running."
    fi
}

# ---------------------------------------------------------------------------
# setup <repo-path> <N>
# ---------------------------------------------------------------------------

trust_directories() {
    local base="$1" prefix="$2" count="$3"
    python3 -c "
import json, os

claude_json = os.path.expanduser('~/.claude.json')
try:
    with open(claude_json, 'r') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

if 'projects' not in data:
    data['projects'] = {}

template = {
    'allowedTools': [],
    'disabledMcpjsonServers': [],
    'enabledMcpjsonServers': [],
    'hasClaudeMdExternalIncludesApproved': False,
    'hasClaudeMdExternalIncludesWarningShown': False,
    'hasTrustDialogAccepted': True,
    'mcpContextUris': [],
    'mcpServers': {},
    'projectOnboardingSeenCount': 0
}

for i in range(1, int('$count') + 1):
    key = f'$base/${prefix}{i:02d}'
    if key not in data['projects']:
        data['projects'][key] = dict(template)
    else:
        data['projects'][key]['hasTrustDialogAccepted'] = True

with open(claude_json, 'w') as f:
    json.dump(data, f, indent=2)
"
}

repos_setup() {
    local source_path="$1"
    local count="$2"

    # Resolve to absolute path.
    source_path="$(cd "$source_path" && pwd)"

    if [[ ! -d "$source_path" ]]; then
        die "Source path does not exist: $source_path"
    fi

    local repo_name
    repo_name=$(basename "$source_path")
    local base_dir="${HOME}/${repo_name}-multi"

    cd "$source_path"

    if [[ -d ".sl" ]]; then
        echo "Detected Sapling repo: $source_path"
        mkdir -p "$base_dir"
        for i in $(seq 1 "$count"); do
            local team
            team=$(printf '%02d' "$i")
            local dest="${base_dir}/${repo_name}${team}"
            if [[ -d "$dest" ]]; then
                echo "  $dest already exists, skipping"
                continue
            fi
            echo "  Cloning to $dest (this may take a while)..."
            sl clone "$source_path" "$dest"
        done
    elif git rev-parse --git-dir &>/dev/null; then
        echo "Detected Git repo: $source_path"
        mkdir -p "$base_dir"
        for i in $(seq 1 "$count"); do
            local team
            team=$(printf '%02d' "$i")
            local dest="${base_dir}/${repo_name}${team}"
            local branch="team-${team}"
            if [[ -d "$dest" ]]; then
                echo "  $dest already exists, skipping"
                continue
            fi
            echo "  Creating worktree at $dest (branch: $branch)..."
            git worktree add "$dest" -b "$branch"
        done
    else
        die "No recognized VCS found at $source_path (expected .sl or .git)"
    fi

    # Write config.
    mkdir -p "${HOME}/.master-claude"
    cat > "${HOME}/.master-claude/config" <<EOF
CHECKOUT_BASE="$base_dir"
CHECKOUT_PREFIX="$repo_name"
EOF

    # Trust directories in ~/.claude.json.
    echo ""
    echo "Trusting checkout directories in ~/.claude.json..."
    trust_directories "$base_dir" "$repo_name" "$count"

    echo ""
    echo "Setup complete."
    echo "  Config:   ~/.master-claude/config"
    echo "  Base:     $base_dir"
    echo "  Prefix:   $repo_name"
    echo "  Checkouts: ${count}"
    echo ""
    echo "You can now run: master-claude start 1"
}

show_config() {
    echo "Current configuration:"
    echo "  Config file:     $CONFIG_FILE"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  (loaded)"
    else
        echo "  (not found, using defaults)"
    fi
    echo "  CHECKOUT_BASE:   $CHECKOUT_BASE"
    echo "  CHECKOUT_PREFIX: $CHECKOUT_PREFIX"
    echo "  LOG_DIR:         $LOG_DIR"
    echo "  TMUX_SOCKET:     $TMUX_SOCKET"
    echo ""
    echo "Checkout directories:"
    local found=0
    for dir in "${CHECKOUT_BASE}/${CHECKOUT_PREFIX}"*/; do
        if [[ -d "$dir" ]]; then
            echo "  $dir"
            found=1
        fi
    done
    if [[ $found -eq 0 ]]; then
        echo "  (none found)"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        setup)
            [[ $# -lt 2 ]] && die "setup requires a repo path and count (e.g., master-claude setup ~/myrepo 5)"
            repos_setup "$1" "$2"
            ;;
        start)
            [[ $# -lt 1 ]] && die "start requires a team number"
            team_start "$1"
            ;;
        stop)
            [[ $# -lt 1 ]] && die "stop requires a team number"
            team_stop "$1"
            ;;
        list)
            team_list
            ;;
        connect)
            [[ $# -lt 1 ]] && die "connect requires a team number or 'orchestrator'"
            if [[ "$1" == "orchestrator" ]]; then
                if ! check_session_alive "orchestrator"; then
                    die "Orchestrator session is not running."
                fi
                tmux -L "$TMUX_SOCKET" attach -t orchestrator
            else
                connect "$1" "${2:-manager}"
            fi
            ;;
        logs)
            [[ $# -lt 1 ]] && die "logs requires a team number"
            logs "$1" "${2:-manager}"
            ;;
        orchestrator:start)
            orchestrator_start
            ;;
        orchestrator:stop)
            orchestrator_stop
            ;;
        stop-all)
            stop_all
            ;;
        config)
            show_config
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            die "Unknown command: $cmd"
            ;;
    esac
}

main "$@"

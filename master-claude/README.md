# master-claude

Team-based multi-agent orchestration CLI built on tmux and Claude Code. It spins up coordinated teams of AI agents — each with a Manager, Engineer, and Reviewer — that collaborate to complete software engineering tasks in parallel across isolated repo checkouts.

Works with both Git and Sapling (fbsource) repositories.

## Architecture

```
                    ┌──────────────┐
                    │ Orchestrator │  (optional, coordinates across teams)
                    └──────┬───────┘
               ┌───────────┼───────────┐
               ▼           ▼           ▼
         ┌──────────┐ ┌──────────┐ ┌──────────┐
         │ Team 01  │ │ Team 02  │ │ Team 03  │  ...
         └──────────┘ └──────────┘ └──────────┘

Each team:
  Manager  ──▶  Engineer  ──▶  Reviewer
  (plans)      (implements)    (reviews)
     ◀────── feedback loop ──────┘
```

Each team's three agents share a single repo checkout. All agents run as separate Claude CLI instances inside tmux sessions on a dedicated `master-claude` tmux socket. They communicate via `tmux send-keys` (sending) and `tmux capture-pane` (reading).

### Agent Roles

| Role | Responsibilities |
|------|-----------------|
| **Manager** | Plans tasks, delegates to Engineer, sends completed work to Reviewer, coordinates the feedback loop, reports results to user |
| **Engineer** | Implements code changes, runs tests/linters, reports "TASK COMPLETE" or "BLOCKED" |
| **Reviewer** | Reviews code for correctness/style/security, reports "REVIEW APPROVED" or "REVIEW: CHANGES REQUESTED" |
| **Orchestrator** | (Optional) Coordinates work across multiple teams, talks only to Managers |

### Persistence

- Each agent writes to a journal file (`~/team_NN_role.journal.md`) for context across sessions
- A shared `~/Memory.md` holds project-wide context accessible to all agents
- On startup, every agent reads its journal and Memory.md before reporting ready

## Prerequisites

- `tmux` installed
- `claude` CLI installed and authenticated
- A git or Sapling repository to work on

## Setup

1. Clone or copy this repo somewhere (e.g., `~/claude/master-claude/`).

2. Create a symlink in `~/bin/` so it's on your PATH:

   ```bash
   mkdir -p ~/bin
   ln -s ~/claude/master-claude/master-claude.sh ~/bin/master-claude
   ```

3. Add `~/bin` to your PATH in `~/.bashrc`:

   ```bash
   export PATH="$HOME/bin:$PATH"
   ```

4. (Optional) Add a shorthand alias:

   ```bash
   alias mc="master-claude"
   ```

5. Source your shell config:

   ```bash
   source ~/.bashrc
   ```

6. Create your checkouts:

   ```bash
   # For a git repo — creates worktrees:
   master-claude setup ~/myrepo 5

   # For fbsource (Sapling) — creates clones:
   master-claude setup /data/users/$USER/fbsource 5
   ```

   This creates the checkout directories, writes `~/.master-claude/config`, and trusts them in `~/.claude.json`.

## Usage

### Setting up checkouts

```bash
master-claude setup <repo-path> <N>
```

Creates N checkout directories from the given repo:
- **Git repos**: creates git worktrees, each on a `team-NN` branch
- **Sapling repos**: creates `sl clone` copies

Also writes `~/.master-claude/config` and trusts all directories in `~/.claude.json`.

Example:
```bash
master-claude setup ~/my-project 3
# Creates:
#   ~/my-project-multi/my-project01/  (worktree, branch: team-01)
#   ~/my-project-multi/my-project02/  (worktree, branch: team-02)
#   ~/my-project-multi/my-project03/  (worktree, branch: team-03)
```

### Viewing current config

```bash
master-claude config
```

Shows the active `CHECKOUT_BASE`, `CHECKOUT_PREFIX`, and lists existing checkout directories.

### Starting a team

```bash
master-claude start <N>
```

Starts team N (manager + engineer + reviewer). Each agent initializes, reads its journal and Memory.md, and reports ready. The manager waits for the engineer and reviewer before reporting "TEAM NN READY".

### Connecting to an agent

```bash
master-claude connect <N> [role]
```

Attaches to a team's tmux session. Defaults to `manager`. Detach with `Ctrl-b d`.

```bash
master-claude connect 1              # connect to team 01 manager
master-claude connect 1 engineer     # connect to team 01 engineer
master-claude connect orchestrator   # connect to orchestrator
```

### Listing running agents

```bash
master-claude list
```

### Viewing logs

```bash
master-claude logs <N> [role]
```

Shows the full log for an agent session. Defaults to `manager`. Logs are stored at `~/.master-claude/logs/`.

### Stopping a team

```bash
master-claude stop <N>
```

### Starting/stopping the orchestrator

```bash
master-claude orchestrator:start
master-claude orchestrator:stop
```

The orchestrator coordinates work across multiple teams. Only needed when running more than one team on a multi-part task.

### Stopping everything

```bash
master-claude stop-all
```

Kills the entire `master-claude` tmux server and all sessions.

## Customization

### Configuration — `~/.master-claude/config`

Created automatically by `master-claude setup`. You can also create or edit it manually:

```bash
CHECKOUT_BASE="$HOME/myrepo-multi"
CHECKOUT_PREFIX="myrepo"
```

This tells master-claude where to find checkouts. Team N uses `$CHECKOUT_BASE/${CHECKOUT_PREFIX}NN/`.

To switch between repos, just update the config and restart your teams.

### Agent prompts — `prompts/`

This is where most customization happens. Each role has its own system prompt:

| File | Purpose |
|------|---------|
| `prompts/manager.md` | Manager behavior: planning, delegation, monitoring, review coordination |
| `prompts/engineer.md` | Engineer behavior: implementation, testing, status reporting |
| `prompts/reviewer.md` | Reviewer behavior: review standards, feedback format |
| `prompts/orchestrator.md` | Orchestrator behavior: cross-team coordination |

Common prompt fragments appended to every agent:

| File | Purpose |
|------|---------|
| `prompts/common/compaction.md` | Rules for preserving context during conversation compaction |
| `prompts/common/filesystem-rules.md` | Rules preventing destructive filesystem operations (e.g., no `find` on large dirs) |

Add new `.md` files to `prompts/common/` and they'll automatically be appended to all agents' system prompts.

The placeholder `TEAM_NUM` in prompts is substituted with the actual team number (e.g., `01`) at launch time.

### Agent settings — `profiles/`

Claude CLI settings per role. These are JSON files passed via `--settings`:

| File | Purpose |
|------|---------|
| `profiles/manager.json` | Plugins and env vars for manager |
| `profiles/engineer.json` | Plugins and env vars for engineer |
| `profiles/reviewer.json` | Plugins and env vars for reviewer |
| `profiles/orchestrator.json` | Plugins and env vars for orchestrator |

Use these to enable/disable plugins, set environment variables, or configure model behavior per role.

### Agent bootstrap — `utils/agent-start.sh`

Runs before Claude launches for each team agent. Auto-detects VCS (Git or Sapling) and:
1. Stashes uncommitted changes
2. Fetches/pulls latest from remote
3. Syncs to the default branch

Modify this to change what happens before agents start (e.g., skip the pull, go to a different branch, run setup scripts).

### Claude launch — `utils/claude.sh`

Assembles the system prompt and launches the Claude CLI. Modify this to change CLI flags (e.g., add `--model`, `--mcp-config`, `--allowed-tools`).

### Hardcoded variables — `master-claude.sh`

At the top of the main script (these are defaults; the config file overrides `CHECKOUT_BASE` and `CHECKOUT_PREFIX`):

```bash
TMUX_SOCKET="master-claude"          # tmux socket name
LOG_DIR="${HOME}/.master-claude/logs" # where logs are stored
CHECKOUT_BASE="${HOME}/fbsource-multi" # base dir for checkouts (default)
CHECKOUT_PREFIX="fbsource"             # checkout dir prefix (default)
```

## File Structure

```
master-claude/
├── master-claude.sh              # Main CLI entrypoint
├── README.md                     # This file
├── profiles/
│   ├── engineer.json             # Claude settings for engineer
│   ├── manager.json              # Claude settings for manager
│   ├── orchestrator.json         # Claude settings for orchestrator
│   └── reviewer.json             # Claude settings for reviewer
├── prompts/
│   ├── common/
│   │   ├── compaction.md         # Context preservation rules
│   │   └── filesystem-rules.md   # Safe filesystem operation rules
│   ├── engineer.md               # Engineer system prompt
│   ├── manager.md                # Manager system prompt
│   ├── orchestrator.md           # Orchestrator system prompt
│   └── reviewer.md               # Reviewer system prompt
└── utils/
    ├── agent-start.sh            # Pre-launch bootstrap (auto-detects VCS)
    └── claude.sh                 # Prompt assembly + claude CLI launch

~/.master-claude/
├── config                        # CHECKOUT_BASE and CHECKOUT_PREFIX
└── logs/                         # Agent session logs
```

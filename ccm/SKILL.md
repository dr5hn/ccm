---
name: ccm
description: Claude Code Manager — manage accounts, sessions, environments, and optimize token usage. Use when the user mentions switching Claude accounts, cleaning up sessions, environment snapshots, disk usage, token optimization, Claude Code health check, orphaned sessions, orphaned processes, tmp files, MCP audit, project bindings, session search, token usage history, account reorder, launch modes, claudeignore, permission rules, statusline, status bar, or says "ccm", "doctor", "optimize tokens", "clean cache", "clean tmp", "session list", "session search", "env snapshot", "bind", "unbind", "reorder", "usage history", "launch auto", "launch yolo", "init", "permissions audit", "statusline".
allowed-tools: Bash(ccm *), Bash(~/.ccm/bin/ccm *), Bash(curl -fsSL *install.sh*)
---

# CCM — Claude Code Manager

The power-user toolkit for Claude Code. Manages accounts, sessions, environments, and usage from the terminal.

**GitHub:** https://github.com/dr5hn/ccm

## 1. Installation Check

Before running any CCM command, verify it's installed:

```bash
ccm version
```

If not found, install it:

```bash
curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/install.sh | bash
```

This installs to `~/.ccm/bin/ccm` — no sudo required. After install, the user needs to restart their terminal or `source ~/.zshrc`.

## 2. Command Reference

### Account Management

| Command | Description |
|---------|-------------|
| `ccm add` | Add current logged-in Claude account |
| `ccm remove <id>` | Remove account by number, email, or alias |
| `ccm switch [id]` | Switch to next account, specific, or project-bound |
| `ccm undo` | Revert to previous account |
| `ccm list` | List all managed accounts and project bindings |
| `ccm status` | Show active account details |
| `ccm alias <id> <name>` | Set friendly name (e.g., `ccm alias 1 work`) |
| `ccm reorder <from> <to>` | Reorder account positions |
| `ccm bind [path] <account>` | Bind project directory to an account |
| `ccm unbind [path]` | Remove project binding |
| `ccm bind list` | Show all project bindings |
| `ccm verify [id]` | Verify backup integrity |
| `ccm history` | Show recent switch history |
| `ccm export <path>` | Export accounts to archive |
| `ccm import <path>` | Import from archive |
| `ccm interactive` | Launch interactive menu |

### Session Management

| Command | Description |
|---------|-------------|
| `ccm session list` | List all project sessions with size, age, status |
| `ccm session info <project-path>` | Detailed info for a project's sessions |
| `ccm session search <query> [--limit N]` | Full-text search across all sessions |
| `ccm session relocate <old> <new>` | Update sessions after moving a project folder |
| `ccm session clean [--dry-run]` | Find and remove orphaned sessions |

### Environment Snapshots

| Command | Description |
|---------|-------------|
| `ccm env snapshot [name]` | Save current Claude Code configuration |
| `ccm env restore <name> [--force]` | Restore from a snapshot |
| `ccm env list` | List all snapshots |
| `ccm env delete <name>` | Remove a snapshot |
| `ccm env audit` | Audit MCP servers for token efficiency |

### Usage Stats

| Command | Description |
|---------|-------------|
| `ccm usage summary` | Claude Code footprint overview |
| `ccm usage top [--count N]` | Top projects by disk usage |
| `ccm usage history [--days N] [--project <path>]` | Token usage by project and day |

### Health & Maintenance

| Command | Description |
|---------|-------------|
| `ccm doctor` | 13 health checks (disk, tmp, processes, hooks, locks, cache) |
| `ccm doctor --fix` | Auto-fix safe issues |
| `ccm clean debug [--days N]` | Clean debug logs (default: older than 30 days) |
| `ccm clean telemetry` | Remove telemetry data |
| `ccm clean todos [--days N]` | Remove old todo files |
| `ccm clean history [--keep N]` | Trim history.jsonl (default: keep 1000) |
| `ccm clean tmp [--days N]` | Clean orphaned tmp output files (default: 1 day) |
| `ccm clean processes` | Kill orphaned Claude subagent processes (macOS) |
| `ccm clean cache` | Clean plugin cache (old versions) |
| `ccm clean all [--dry-run]` | Clean everything safe to clean |

### Launcher

| Command | Description |
|---------|-------------|
| `ccm launch` | Launch Claude Code with terminal reset on exit |
| `ccm launch auto` | Auto-accept most actions |
| `ccm launch yolo` | Skip ALL permissions (asks confirmation first) |
| `ccm launch plan` | Read-only mode |
| `ccm launch safe` | Ask for everything |

### Project Setup

| Command | Description |
|---------|-------------|
| `ccm init` | Auto-generate .claudeignore for detected project type |
| `ccm init --force` | Overwrite existing .claudeignore |

### Statusline

| Command | Description |
|---------|-------------|
| `ccm statusline` | Install smart statusline in Claude Code |
| `ccm statusline install` | Same as above |
| `ccm statusline remove` | Remove statusline and settings |

Standalone install (no CCM needed): `curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/statusline.sh | bash`

Shows: context bar, tokens, session cost, duration, burn rate, 5hr/7d rate limits, directory, branch, version.

### Permission Rules

| Command | Description |
|---------|-------------|
| `ccm permissions audit` | Scan for duplicates, contradictions, verbatim rules, bloat |
| `ccm permissions audit --fix` | Auto-remove duplicate rules |

### Token Optimization

| Command | Description |
|---------|-------------|
| `ccm optimize` | Analyze token usage and suggest reductions |

## 3. Common Workflows

### First-time setup
```bash
# Install CCM
curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/install.sh | bash
source ~/.zshrc

# Add your current account
ccm add

# Give it a friendly name
ccm alias 1 personal

# Log into another account in Claude Code, then:
ccm add
ccm alias 2 work
```

### Daily account switching
```bash
ccm switch work        # switch to work account
ccm switch personal    # switch back
ccm undo               # revert last switch
```

### Project-specific accounts
```bash
ccm bind ~/work/project work       # bind project to work account
ccm bind ~/personal/side-project personal
ccm bind list                      # show all bindings
# Now `ccm switch` in a bound directory auto-switches to the right account
```

### Token usage analytics
```bash
ccm usage history                  # last 7 days, all projects
ccm usage history --days 30        # last 30 days
ccm usage history --project .      # current project only
```

### Search conversation history
```bash
ccm session search "error handling"       # find across all sessions
ccm session search "API" --limit 5        # limit results
```

### Launch Claude Code with preset modes
```bash
ccm launch auto        # auto-accept mode
ccm launch yolo        # dangerous mode (skip all permissions)
ccm launch plan        # read-only mode
ccm launch auto -c     # auto mode + continue last session
```

### Install statusline
```bash
ccm statusline         # install — shows cost, tokens, rate limits, branch
ccm statusline remove  # uninstall
```

### New project setup
```bash
ccm init               # auto-generate .claudeignore
ccm permissions audit  # check for dead/duplicate permission rules
```

### Disk cleanup
```bash
ccm doctor             # see what's eating space (13 checks)
ccm doctor --fix       # auto-fix safe issues
ccm clean tmp          # clean orphaned tmp output files
ccm clean processes    # kill leaked subagent processes
ccm clean all --dry-run # preview all cleanups
```

### Token optimization
```bash
ccm optimize           # see what's inflating your context window
ccm env audit          # check MCP servers for CLI alternatives
ccm permissions audit  # find bloated permission rules
```

### Moving a project folder
```bash
# After moving ~/old-project to ~/new-location/project:
ccm session relocate ~/old-project ~/new-location/project
```

### Before risky config changes
```bash
ccm env snapshot before-experiment
# ... make changes ...
ccm env restore before-experiment  # if things break
```

## 4. Important Notes

- After switching accounts, restart Claude Code for changes to take effect
- `ccm doctor --fix` only removes data older than 30 days — recent data is never touched
- `ccm optimize` provides estimates — actual token counts vary by model and context
- Environment snapshots do NOT capture credentials — only configuration
- Session relocate updates both session files and memory references
- Project bindings are auto-cleaned when an account is removed
- Orphaned process detection is macOS only (ppid=1 unreliable on Linux)

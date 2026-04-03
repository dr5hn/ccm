---
name: ccm
description: Claude Code Manager — manage accounts, sessions, environments, and optimize token usage. Use when the user mentions switching Claude accounts, cleaning up sessions, environment snapshots, disk usage, token optimization, Claude Code health check, orphaned sessions, orphaned processes, tmp files, MCP audit, project bindings, session search, token usage history, account reorder, profiles, isolated, concurrent sessions, watch, rate limit, auto-switch, dashboard, session archive, setup wizard, recover, usage dashboard, usage compare, claudeignore, permission rules, statusline, status bar, or says "ccm", "doctor", "clean cache", "clean tmp", "session list", "session search", "env snapshot", "bind", "unbind", "reorder", "usage history", "init", "permissions audit", "statusline", "ccm watch", "ccm profiles", "ccm setup", "ccm recover".
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
| `ccm alias <id> <name>` | Set friendly name (e.g., `ccm alias 1 work`) |
| `ccm reorder <from> <to>` | Reorder account positions |
| `ccm bind [path] <account>` | Bind project directory to an account |
| `ccm unbind [path]` | Remove project binding |
| `ccm bind list` | Show all project bindings |
| `ccm hook` | Output shell hook for auto-switch on cd |
| `ccm verify [id]` | Verify backup integrity |
| `ccm history` | Show recent switch history |
| `ccm export <path>` | Export accounts to archive |
| `ccm import <path>` | Import from archive |

### Session Management

| Command | Description |
|---------|-------------|
| `ccm session list` | List all project sessions with size, age, status |
| `ccm session info <project-path>` | Detailed info for a project's sessions |
| `ccm session search <query> [--limit N]` | Full-text search across all sessions |
| `ccm session relocate <old> <new>` | Update sessions after moving a project folder |
| `ccm session summary [path] [--limit N]` | What happened in each session (topic, tools, files) |
| `ccm session clean [--dry-run]` | Find and remove orphaned sessions |
| `ccm session archive [--older-than Nd]` | Compress old sessions to tar.gz |
| `ccm session restore <archive>` | Restore from archive |
| `ccm session archives` | List all archives |

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
| `ccm usage sessions [--project <path>] [--days N]` | Per-session tokens and estimated cost |
| `ccm usage dashboard [--days N] [--account <name>]` | Per-account token usage |
| `ccm usage compare` | Side-by-side account comparison |

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

### Profiles & Monitoring

| Command | Description |
|---------|-------------|
| `ccm switch --isolated <account>` | Switch with CLAUDE_CONFIG_DIR isolation for concurrent sessions |
| `ccm profiles list` | List all isolated profiles |
| `ccm profiles sync <name>` | Sync settings to a profile |
| `ccm profiles delete <name>` | Remove a profile |
| `ccm watch --threshold N [--auto]` | Monitor rate limits, auto-switch accounts |
| `ccm watch stop` | Stop the watcher |
| `ccm watch status` | Show watcher state |
| `ccm recover` | Fix inconsistent credential state |
| `ccm setup` | First-run setup wizard |

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

## 3. Common Workflows

### First-time setup
```bash
# Install CCM
curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/install.sh | bash
source ~/.zshrc

# Run the setup wizard (adds accounts, sets aliases, installs statusline)
ccm setup
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

### Auto-switch on cd (shell hook)
```bash
# Add to ~/.zshrc or ~/.bashrc:
eval "$(ccm hook)"
# Now entering a bound directory auto-switches accounts
cd ~/work/project    # → auto-switches to work account
cd ~/personal/side   # → auto-switches to personal account
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

### Concurrent sessions
```bash
ccm switch --isolated work      # isolated profile for terminal 1
# In another terminal:
ccm switch --isolated personal  # isolated profile for terminal 2
ccm profiles list               # see all active profiles
ccm profiles sync work          # sync latest settings to a profile
```

### Rate limit monitoring
```bash
ccm watch --threshold 80        # alert when rate limit hits 80%
ccm watch --threshold 80 --auto # auto-switch accounts at threshold
ccm watch status                # check watcher state
ccm watch stop                  # stop monitoring
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
- Environment snapshots do NOT capture credentials — only configuration
- Use `ccm switch --isolated` for concurrent sessions in different terminals
- Install statusline before using `ccm watch` (provides rate limit data)
- Session relocate updates both session files and memory references
- Project bindings are auto-cleaned when an account is removed
- Orphaned process detection is macOS only (ppid=1 unreliable on Linux)

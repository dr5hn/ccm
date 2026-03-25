---
name: ccm
description: Claude Code Manager — manage accounts, sessions, environments, and optimize token usage. Use when the user mentions switching Claude accounts, cleaning up sessions, environment snapshots, disk usage, token optimization, Claude Code health check, orphaned sessions, MCP audit, or says "ccm", "doctor", "optimize tokens", "clean cache", "session list", "env snapshot".
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
| `ccm switch [id]` | Switch to next account, or specific by number/email/alias |
| `ccm undo` | Revert to previous account |
| `ccm list` | List all managed accounts |
| `ccm status` | Show active account details |
| `ccm alias <id> <name>` | Set friendly name (e.g., `ccm alias 1 work`) |
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

### Health & Maintenance

| Command | Description |
|---------|-------------|
| `ccm doctor` | Scan for health issues (stale locks, bloated logs, cache) |
| `ccm doctor --fix` | Auto-fix safe issues |
| `ccm clean debug [--days N]` | Clean debug logs (default: older than 30 days) |
| `ccm clean telemetry` | Remove telemetry data |
| `ccm clean todos [--days N]` | Remove old todo files |
| `ccm clean history [--keep N]` | Trim history.jsonl (default: keep 1000) |
| `ccm clean cache` | Clean plugin cache (old versions) |
| `ccm clean all [--dry-run]` | Clean everything safe to clean |

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

### Disk cleanup
```bash
ccm doctor             # see what's eating space
ccm doctor --fix       # auto-fix safe issues
ccm clean all --dry-run # preview all cleanups
```

### Token optimization
```bash
ccm optimize           # see what's inflating your context window
ccm env audit          # check MCP servers for CLI alternatives
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

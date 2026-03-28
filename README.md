```
 ██████╗ ██████╗███╗   ███╗
██╔════╝██╔════╝████╗ ████║
██║     ██║     ██╔████╔██║
██║     ██║     ██║╚██╔╝██║
╚██████╗╚██████╗██║ ╚═╝ ██║
 ╚═════╝ ╚═════╝╚═╝     ╚═╝
```

# CCM — Claude Code Manager

> The power-user toolkit for Claude Code

Manage accounts, sessions, environments, and usage — all from the terminal. Works on macOS, Linux, and WSL.

## Features

### Account Management
- **Multi-account switching** — add, remove, and switch between Claude Code accounts
- **Account aliases** — friendly names like `work` or `personal` for quick access
- **Switch history and undo** — track switches and revert instantly
- **Health verification** — validate backup integrity for all accounts
- **Export/Import** — backup and restore account configurations as portable archives
- **Interactive mode** — menu-driven interface for all operations

### Session Management
- **Session listing** — view all Claude Code project sessions with size and age
- **Session info** — inspect sessions for a specific project directory
- **Session relocation** — move sessions when a project folder is relocated
- **Session cleanup** — remove orphaned sessions for projects that no longer exist

### Environment Snapshots
- **Snapshot capture** — save current Claude Code environment (settings, MCP config, CLAUDE.md)
- **Snapshot restore** — roll back to a previous environment configuration
- **MCP audit** — flag MCP servers with CLI alternatives to save tokens

### Health & Maintenance
- **Doctor** — scan `~/.claude/` for stale locks, log bloat, cache size, orphaned sessions
- **Clean** — targeted cleanup for debug logs, telemetry, todos, cache, history
- **Auto-fix** — `ccm doctor --fix` resolves safe issues automatically

### Token Optimization
- **Optimize** — analyze context window footprint and suggest reductions
- **Plugin audit** — flag unused plugins inflating token usage
- **CLAUDE.md analysis** — warn if global instructions are too large

### Usage Statistics
- **Summary** — total projects, sessions, disk usage at a glance
- **Top projects** — rank projects by disk usage to identify space hogs

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/install.sh | bash
```

Installs to `~/.ccm/bin/` and adds to your `$PATH` automatically. No `sudo` required.

After install, restart your terminal (or `source ~/.zshrc`) and run:
```bash
ccm version
```

### Install as a Skill

If you use Claude Code (or Cursor, Codex, Gemini CLI, etc.):

```bash
npx skills add dr5hn/ccm@ccm
```

This teaches your AI agent about all CCM commands and workflows.

### Manual Install

```bash
mkdir -p ~/.ccm/bin && curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/ccm.sh -o ~/.ccm/bin/ccm && chmod +x ~/.ccm/bin/ccm
```

Then add to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):
```bash
export PATH="$HOME/.ccm/bin:$PATH"
```

### Update

Re-run the installer to update to the latest version:

```bash
curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/install.sh | bash
```

Or manually:
```bash
curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/ccm.sh -o ~/.ccm/bin/ccm && chmod +x ~/.ccm/bin/ccm
```

Check your current version with `ccm version`.

### Requirements

- Bash 4.4+
- `jq` — install with `brew install jq` (macOS) or `sudo apt install jq` (Linux)

## Quick Start

```bash
# Add your current Claude Code account
ccm add
ccm alias 1 personal

# Log into another account, then add it too
ccm add
ccm alias 2 work

# Switch between accounts
ccm switch work
ccm switch personal
ccm undo                    # revert last switch

# Launch interactive menu
ccm interactive
```

After each switch, restart Claude Code to use the new authentication.

## Command Reference

### Account Management

```bash
ccm add                        # Add current Claude Code account
ccm remove <id>                # Remove by number, email, or alias
ccm switch [id]                # Switch to next account, or specific target
ccm undo                       # Revert to the previous account
ccm list                       # List all managed accounts
ccm status                     # Show active account details
ccm alias <id> <name>          # Set a friendly alias
ccm verify [id]                # Verify backup integrity
ccm history                    # View switch history
ccm export <path>              # Export accounts to archive
ccm import <path>              # Import from archive
ccm interactive                # Launch interactive menu
```

### Session Management

```bash
ccm session list                       # List all project sessions
ccm session info <project-path>        # Show sessions for a project (use . for cwd)
ccm session relocate <old> <new>       # Update sessions after moving a project
ccm session clean [--dry-run]          # Remove orphaned sessions
```

### Environment Snapshots

```bash
ccm env snapshot [name]                # Capture environment state
ccm env restore <name> [--force]       # Restore a saved snapshot
ccm env list                           # List all snapshots
ccm env delete <name>                  # Delete a snapshot
ccm env audit                          # Audit MCP servers for token efficiency
```

### Health & Maintenance

```bash
ccm doctor                             # Scan for health issues
ccm doctor --fix                       # Auto-fix safe issues
ccm clean debug [--days N]             # Clean debug logs (default: 30 days)
ccm clean telemetry                    # Remove telemetry data
ccm clean todos [--days N]             # Remove old todo files
ccm clean history [--keep N]           # Trim history (default: keep 1000)
ccm clean cache                        # Clean plugin cache
ccm clean all [--dry-run]              # Clean everything safe
```

### Token Optimization

```bash
ccm optimize                           # Analyze token usage and suggest reductions
```

### Usage Statistics

```bash
ccm usage summary                      # Usage overview
ccm usage top [--count N]              # Top projects by disk usage
```

### Global Options

```bash
ccm help [module]                      # Show help (doctor, clean, optimize, session, env, usage)
ccm version                            # Show version
ccm --no-color <command>               # Disable colored output
```

## Examples

### Daily Account Switching

```bash
ccm switch work        # switch to work account
ccm switch personal    # switch back
ccm undo               # oops, revert
ccm history            # see recent switches
```

### Disk Cleanup

```bash
ccm doctor             # see what's eating space
ccm doctor --fix       # auto-fix safe issues
ccm clean all --dry-run # preview all cleanups
ccm session clean      # remove orphaned sessions
ccm usage top          # find biggest projects
```

### Token Optimization

```bash
ccm optimize           # full context window analysis
ccm env audit          # check MCP servers for CLI alternatives
```

### Environment Snapshots

```bash
ccm env snapshot before-experiment
# ... make risky config changes ...
ccm env restore before-experiment  # roll back if needed
```

### Moving a Project

```bash
# After moving ~/old-project to ~/new-location/project:
ccm session relocate ~/old-project ~/new-location/project
```

## How It Works

CCM stores account data separately from Claude Code:

- **macOS**: Credentials in Keychain, OAuth config in `~/.claude-switch-backup/`
- **Linux/WSL**: Both stored in `~/.claude-switch-backup/` with restricted permissions (600)

When switching accounts, CCM backs up the current account, restores the target, and updates Claude Code's auth files. Sessions, settings, and preferences are preserved.

### Storage Locations

| Data | Location |
|------|----------|
| Account configs & credentials | `~/.claude-switch-backup/` |
| Environment snapshots | `~/.claude-switch-backup/snapshots/` |
| Project sessions | `~/.claude/projects/` |
| CCM binary | `~/.ccm/bin/ccm` |

## Troubleshooting

### Switch fails or account not recognized

```bash
ccm list               # check managed accounts
ccm verify             # validate backups
ccm undo               # revert to previous
```

### Claude Code doesn't use the new account after switch

Restart Claude Code after every switch. Verify with `ccm status`.

### Disk usage is high

```bash
ccm doctor             # full health check
ccm usage top          # find space hogs
ccm session clean      # remove orphaned sessions
ccm clean all          # clean logs, telemetry, cache
```

### Cannot add an account

- Ensure you are logged into Claude Code first
- Verify `jq` is installed: `jq --version`
- Check write permissions to your home directory

## Uninstall

```bash
# Remove the binary
rm -f ~/.ccm/bin/ccm

# Remove the PATH entry from your shell profile
# (delete the "# CCM" lines from ~/.zshrc or ~/.bashrc)

# Optionally remove backup data
rm -rf ~/.claude-switch-backup
```

Your current Claude Code login will remain active.

## Security

- Credentials stored in macOS Keychain or files with 600 permissions
- Snapshot capture strips tokens/credentials from config files
- All inputs validated and sanitized before processing
- No use of `eval` or unsanitized shell calls

## Disclaimer

This is a personal weekend project and is not affiliated with, endorsed by, or associated with Anthropic. "Claude Code" is a product of Anthropic. This tool manages local configuration files and credentials on your machine — it does not interact with Anthropic's servers or APIs directly. Use at your own risk. Always back up your credentials before using any account management tool.

## License

MIT License — see [LICENSE](LICENSE) for details.

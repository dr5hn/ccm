```
 ██████╗ ██████╗███╗   ███╗
██╔════╝██╔════╝████╗ ████║
██║     ██║     ██╔████╔██║
██║     ██║     ██║╚██╔╝██║
╚██████╗╚██████╗██║ ╚═╝ ██║
 ╚═════╝ ╚═════╝╚═╝     ╚═╝
```

[![GitHub stars](https://img.shields.io/github/stars/dr5hn/ccm?style=flat-square&color=38bdf8)](https://github.com/dr5hn/ccm/stargazers) [![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE) [![Bash](https://img.shields.io/badge/bash-4.4%2B-blue?style=flat-square)](https://www.gnu.org/software/bash/) [![No Dependencies](https://img.shields.io/badge/dependencies-bash%20%2B%20jq-orange?style=flat-square)](#requirements)

# CCM — Claude Code Manager

> The power-user toolkit for Claude Code — manage accounts, sessions, environments, and health from one CLI. No Node, no Python, just bash. Works on macOS, Linux, and WSL.

## Why CCM?

Claude Code has no built-in multi-account support ([10+ open issues](https://github.com/anthropics/claude-code/issues?q=is%3Aissue+is%3Aopen+multi+account)). Your `~/.claude` directory can grow to [500GB+ without warning](https://github.com/anthropics/claude-code/issues/26911). Your settings.json accumulates dead permission rules you don't know about.

CCM is a single bash script that fixes all of this — and it's the only tool that auto-switches accounts when you `cd` into a project directory.

## Features

### Account Management
- **Multi-account switching** — add, remove, and switch between Claude Code accounts
- **Account aliases** — friendly names like `work` or `personal` for quick access
- **Account reorder** — rearrange account positions with automatic credential renaming
- **Project bindings** — bind directories to accounts, auto-switch with `ccm switch`
- **Shell hook** — `eval "$(ccm hook)"` auto-switches accounts when you `cd` into bound directories (zero per-cd overhead)
- **Switch history and undo** — track switches and revert instantly
- **Health verification** — validate backup integrity for all accounts
- **Export/Import** — backup and restore account configurations as portable archives
- **Interactive mode** — menu-driven interface for all operations

### Session Management
- **Session listing** — view all Claude Code project sessions with size and age
- **Session search** — full-text search across all conversation history
- **Session info** — inspect sessions for a specific project directory
- **Session relocation** — move sessions when a project folder is relocated
- **Session cleanup** — remove orphaned sessions for projects that no longer exist

### Statusline
- **Smart status bar** — shows context %, tokens, session cost, duration, burn rate, rate limits, directory, branch, and version at the bottom of Claude Code
- **Adaptive display** — 2 lines for single-account, 3 lines for multi-account. Rate limits only for Pro/Max users
- **Color-coded warnings** — context bar and rate limits change color as you approach limits. Compact warning at 80%+
- **Standalone install** — share with your team without CCM: `curl -fsSL .../statusline.sh | bash`

### Launcher
- **Launch modes** — `ccm launch auto|yolo|plan|safe` for preset permission modes
- **Terminal reset** — automatically fixes broken Ctrl-C/Ctrl-D after Claude Code exit in tmux
- **Pass-through args** — any extra flags forwarded to Claude Code

### Project Setup
- **Init** — auto-generate `.claudeignore` based on detected project type (Node, Python, Go, Rust, Java, Ruby, PHP, .NET, Dart, Swift)

### Environment Snapshots
- **Snapshot capture** — save current Claude Code environment (settings, MCP config, CLAUDE.md)
- **Snapshot restore** — roll back to a previous environment configuration
- **MCP audit** — flag MCP servers with CLI alternatives to save tokens

### Health & Maintenance
- **Doctor** — 13 health checks: stale locks, log bloat, cache, telemetry, todos, paste cache, file history, shell snapshots, orphaned sessions, total disk size, tmp files, orphaned processes, hook async config
- **Clean** — targeted cleanup for debug logs, telemetry, todos, cache, history, tmp output files, orphaned processes
- **Permissions audit** — find duplicate, contradictory, and dead permission rules in settings.json
- **Auto-fix** — `ccm doctor --fix` and `ccm permissions audit --fix` resolve safe issues automatically

### Token Optimization
- **Optimize** — analyze context window footprint and suggest reductions
- **Plugin audit** — flag unused plugins inflating token usage
- **CLAUDE.md analysis** — warn if global instructions are too large

### Usage Statistics
- **Summary** — total projects, sessions, disk usage at a glance
- **Top projects** — rank projects by disk usage to identify space hogs
- **Token history** — per-project and per-day token usage breakdown from session JSONL files

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
ccm switch [id]                # Switch to next, specific, or project-bound account
ccm undo                       # Revert to the previous account
ccm list                       # List all managed accounts and bindings
ccm status                     # Show active account details
ccm alias <id> <name>          # Set a friendly alias
ccm reorder <from> <to>        # Reorder account positions
ccm bind [path] <account>      # Bind project directory to an account
ccm unbind [path]              # Remove project binding
ccm bind list                  # Show all project bindings
ccm hook                       # Output shell hook for auto-switch on cd
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
ccm session search <query> [--limit N] # Full-text search across all sessions
ccm session relocate <old> <new>       # Update sessions after moving a project
ccm session clean [--dry-run]          # Remove orphaned sessions
```

### Launcher

```bash
ccm launch                             # Launch Claude Code with terminal reset
ccm launch auto                        # Auto-accept most actions
ccm launch yolo                        # Skip ALL permissions (asks confirmation)
ccm launch plan                        # Read-only mode
ccm launch safe                        # Ask for everything
ccm launch auto -c                     # Auto mode + continue last session
```

### Statusline

```bash
ccm statusline                         # Install statusline in Claude Code
ccm statusline install                 # Same as above
ccm statusline remove                  # Remove statusline
```

Or share with your team (no CCM needed):
```bash
curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/statusline.sh | bash
```

### Project Setup

```bash
ccm init                               # Generate .claudeignore for this project
ccm init --force                       # Overwrite existing .claudeignore
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
ccm doctor                             # 13 health checks
ccm doctor --fix                       # Auto-fix safe issues
ccm clean debug [--days N]             # Clean debug logs (default: 30 days)
ccm clean telemetry                    # Remove telemetry data
ccm clean todos [--days N]             # Remove old todo files
ccm clean history [--keep N]           # Trim history (default: keep 1000)
ccm clean tmp [--days N]               # Clean orphaned tmp output files (default: 1 day)
ccm clean processes                    # Kill orphaned Claude subagent processes
ccm clean cache                        # Clean plugin cache
ccm clean all [--dry-run]              # Clean everything safe
ccm permissions audit                  # Scan for duplicate/dead permission rules
ccm permissions audit --fix            # Auto-remove duplicates
```

### Token Optimization

```bash
ccm optimize                           # Analyze token usage and suggest reductions
```

### Usage Statistics

```bash
ccm usage summary                      # Usage overview
ccm usage top [--count N]              # Top projects by disk usage
ccm usage history [--days N]           # Token usage by project and day
ccm usage history --project <path>     # Token usage for a specific project
```

### Global Options

```bash
ccm help [module]                      # Show help (launch, init, permissions, doctor, etc.)
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

### Project-Specific Accounts

```bash
ccm bind ~/work/project work       # bind project to work account
ccm bind . personal                # bind current directory
ccm bind list                      # show all bindings
# Now `ccm switch` in a bound directory auto-switches

# Auto-switch on cd (add to ~/.zshrc or ~/.bashrc):
eval "$(ccm hook)"
# cd ~/work/project → auto-switches to work account
```

### Launch Claude Code with Presets

```bash
ccm launch auto        # auto-accept mode
ccm launch yolo        # dangerous mode (skip all permissions)
ccm launch plan        # read-only mode
ccm launch auto -c     # auto mode + continue last session
```

### New Project Setup

```bash
ccm init               # auto-generate .claudeignore
ccm permissions audit  # check for dead/duplicate permission rules
```

### Token Usage Analytics

```bash
ccm usage history              # last 7 days, all projects
ccm usage history --days 30    # last 30 days
ccm usage history --project .  # current project only
```

### Search Conversation History

```bash
ccm session search "error handling"   # search across all sessions
ccm session search "API" --limit 5    # limit results
```

### Disk Cleanup

```bash
ccm doctor             # 13 health checks
ccm doctor --fix       # auto-fix safe issues
ccm clean tmp          # clean orphaned tmp output files
ccm clean processes    # kill leaked subagent processes
ccm clean all --dry-run # preview all cleanups
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

## Ecosystem

CCM focuses on account management, operational health, and environment portability. It works great alongside other Claude Code tools:

| Tool | What it does | Stars |
|------|-------------|-------|
| [ccusage](https://github.com/ryoppippi/ccusage) | Detailed token analytics and cost tracking | 12k+ |
| [ccstatusline](https://github.com/sirmalloc/ccstatusline) | Rich interactive status bar with themes | 6k+ |
| [ccmanager](https://github.com/kbwo/ccmanager) | Multi-agent session orchestration | 900+ |

**What only CCM does:**
- Project-to-account bindings with shell hook auto-switch
- Permissions audit with `--fix` for settings.json
- `.claudeignore` generation from project type detection
- Environment snapshots (settings.json + MCP config + CLAUDE.md as a unit)
- Zero runtime dependencies — single bash script, no package managers needed

## Security

CCM handles OAuth credentials — security is taken seriously:

- **No `eval`** — all external data (JSON, user input) is processed with safe parsing patterns (`IFS read`, `jq @tsv`), never interpreted as shell code
- **Atomic writes with restricted permissions** — credential and config files are created with `umask 077` (owner-only from the moment of creation), then atomically moved into place
- **Input validation at every boundary** — account numbers validated as numeric, emails validated against regex, snapshot names restricted to `[a-zA-Z0-9._-]`, identifiers bounded to 255 chars
- **Path traversal protection** — all parameters used in file path construction are validated before use
- **macOS Keychain integration** — credentials stored in the system keychain, not on disk
- **Safe cleanup patterns** — `trap` and `rm` commands use proper quoting and `--` end-of-options markers

## How It Works

CCM stores account data separately from Claude Code:

- **macOS**: Credentials in Keychain, OAuth config in `~/.claude-switch-backup/`
- **Linux/WSL**: Both stored in `~/.claude-switch-backup/` with restricted permissions (owner-only via umask 077)

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

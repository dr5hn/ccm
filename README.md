```
 ██████╗ ██████╗███╗   ███╗
██╔════╝██╔════╝████╗ ████║
██║     ██║     ██╔████╔██║
██║     ██║     ██║╚██╔╝██║
╚██████╗╚██████╗██║ ╚═╝ ██║
 ╚═════╝ ╚═════╝╚═╝     ╚═╝
```

# CCM -- Claude Code Manager

> The power-user toolkit for Claude Code

Manage accounts, sessions, environments, and usage — all from the terminal. Works on macOS, Linux, and WSL.

## Features

### Account Management
- **Multi-account switching**: Add, remove, and switch between Claude Code accounts
- **Account aliases**: Set friendly names like `work` or `personal` for quick access
- **Switch history and undo**: Track switches and revert to the previous account instantly
- **Health verification**: Validate backup integrity for all accounts
- **Export/Import**: Backup and restore account configurations as portable archives
- **Interactive mode**: Menu-driven interface for all operations

### Session Management
- **Session listing**: View all Claude Code project sessions with size and age
- **Session info**: Inspect sessions for a specific project directory
- **Session relocation**: Move sessions when a project folder is relocated
- **Session cleanup**: Remove orphaned sessions for projects that no longer exist on disk

### Environment Snapshots
- **Snapshot capture**: Save the current Claude Code environment state (settings, MCP config, credentials metadata)
- **Snapshot restore**: Roll back to a previous environment configuration
- **Snapshot management**: List and delete saved snapshots
- **MCP audit**: Audit configured MCP servers and flag those with CLI alternatives

### Usage Statistics
- **Summary**: View total projects, sessions, disk usage, and session age distribution
- **Top projects**: Rank projects by disk usage to identify space hogs

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/install.sh | bash
```

This installs `ccm` to `~/.ccm/bin/` and adds it to your `$PATH` automatically. No `sudo` required.

After install, restart your terminal (or `source ~/.zshrc`) and run:
```bash
ccm version
```

### Manual install

If you prefer to install manually:

```bash
mkdir -p ~/.ccm/bin && curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/ccm.sh -o ~/.ccm/bin/ccm && chmod +x ~/.ccm/bin/ccm
```

Then add to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):
```bash
export PATH="$HOME/.ccm/bin:$PATH"
```

### Requirements

- Bash 4.4+
- `jq` (JSON processor)

**macOS:**
```bash
brew install jq
```

**Ubuntu/Debian:**
```bash
sudo apt install jq
```

## Quick Start

```bash
# 1. Log into Claude Code with your first account
# 2. Add it to CCM
./ccm.sh add

# 3. Log out, log into your second account
# 4. Add it too
./ccm.sh add

# 5. Switch between accounts
./ccm.sh switch

# 6. Or use the interactive menu
./ccm.sh interactive
```

After each switch, restart Claude Code to use the new authentication.

## Command Reference

### Account Management

```bash
ccm add                        # Add current Claude Code account
ccm remove <email|alias|num>   # Remove a managed account
ccm switch                     # Switch to next account in sequence
ccm switch <target>         # Switch to account by number, email, or alias
ccm undo                       # Revert to the previous account
ccm list                       # List all managed accounts with metadata
ccm status                     # Show detailed status of the active account
ccm alias <account> <name>     # Set a friendly alias for an account
ccm verify [account]           # Verify backup integrity (all or specific)
ccm history                    # View account switch history
ccm export <file.tar.gz>       # Export accounts to archive
ccm import <file.tar.gz>       # Import accounts from archive
ccm interactive                # Launch the interactive menu
```

### Session Management

```bash
ccm session list                       # List all project sessions
ccm session info <project-path>        # Show sessions for a project (use . for cwd)
ccm session relocate <old> <new>       # Relocate sessions after moving a project
ccm session clean [--dry-run]          # Remove orphaned sessions
```

### Environment Snapshots

```bash
ccm env snapshot [name]                # Capture environment state
ccm env restore <name> [--force]       # Restore a saved snapshot
ccm env list                           # List all saved snapshots
ccm env delete <name>                  # Delete a snapshot
ccm env audit                          # Audit MCP servers for CLI alternatives
```

### Usage Statistics

```bash
ccm usage summary                      # Show usage overview
ccm usage top [--count N]              # Show top N projects by disk usage
```

### Global Options

```bash
ccm --no-color <command>               # Disable colored output
ccm version                            # Show version
ccm help                               # Show general help
ccm help session                       # Show session module help
ccm help env                           # Show environment module help
ccm help usage                         # Show usage module help
```

## Examples

### Managing Multiple Accounts

```bash
# Set aliases for quick reference
./ccm.sh alias 1 work
./ccm.sh alias 2 personal

# Switch by alias
./ccm.sh switch work

# View history
./ccm.sh history

# Oops, switch back
./ccm.sh undo
```

### Cleaning Up Sessions

```bash
# See what would be removed
./ccm.sh session clean --dry-run

# Actually remove orphaned sessions
./ccm.sh session clean

# Check disk usage
./ccm.sh usage summary
./ccm.sh usage top --count 5
```

### Environment Snapshots

```bash
# Save state before a big change
./ccm.sh env snapshot before-upgrade

# Make changes to MCP config, settings, etc.
# ...

# Something went wrong? Restore
./ccm.sh env restore before-upgrade

# Audit MCP servers
./ccm.sh env audit
```

### Export and Import

```bash
# Backup all accounts
./ccm.sh export ~/ccm-backup.tar.gz

# Restore on another machine
./ccm.sh import ~/ccm-backup.tar.gz
```

## How It Works

CCM stores account authentication data separately from Claude Code:

- **macOS**: Credentials in Keychain, OAuth info in `~/.claude-switch-backup/`
- **Linux/WSL**: Both credentials and OAuth info in `~/.claude-switch-backup/` with restricted permissions (600)

When switching accounts, CCM:
1. Backs up the current account's authentication data
2. Restores the target account's authentication data
3. Updates Claude Code's authentication files

Sessions are stored in `~/.claude/projects/`. Environment snapshots are saved to `~/.claude-switch-backup/snapshots/`.

## Troubleshooting

### Switch fails or account not recognized

```bash
# Check managed accounts
./ccm.sh list

# Verify backup integrity
./ccm.sh verify

# Revert to previous account
./ccm.sh undo
```

### Cannot add an account

- Ensure you are logged into Claude Code first
- Verify `jq` is installed: `jq --version`
- Check write permissions to your home directory

### Claude Code does not use the new account after switch

- Restart Claude Code after every switch
- Check the active account: `./ccm.sh status`
- Verify the account: `./ccm.sh verify`

### Disk usage is high

```bash
# Identify large projects
./ccm.sh usage top

# Remove orphaned sessions
./ccm.sh session clean --dry-run
./ccm.sh session clean
```

### Environment restore fails

- List available snapshots: `./ccm.sh env list`
- Use `--force` to overwrite existing files: `./ccm.sh env restore <name> --force`

## Cleanup / Uninstall

```bash
# Note your current active account
./ccm.sh list

# Remove backup data
rm -rf ~/.claude-switch-backup

# Delete the script
rm ccm.sh
```

Your current Claude Code login will remain active.

## Security Notes

- Credentials stored in macOS Keychain or files with 600 permissions
- Authentication files are stored with restricted permissions
- All inputs are validated and sanitised before processing
- No use of `eval` or unsanitised shell calls

## License

MIT License - see [LICENSE](LICENSE) file for details.

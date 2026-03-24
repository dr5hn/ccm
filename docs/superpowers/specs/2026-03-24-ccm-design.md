# CCM — Claude Code Manager

**Date:** 2026-03-24
**Status:** Approved design (revised after spec review)
**Scope:** Rename `ccswitch` to `ccm` and expand from account switcher to full Claude Code environment manager and power-user toolkit.

## Overview

CCM is a CLI tool for solo developers who use Claude Code across multiple accounts and projects. It manages accounts, sessions, environment snapshots, and provides usage visibility — all from the terminal.

**Target user:** Solo developer juggling personal + work accounts and multiple projects.

**Design principles:**
- CLI-first: prefer CLI tools over MCP servers for token efficiency
- Hybrid command pattern: flat commands for frequent actions, subcommands for grouped features
- No magic: explicit operations, always confirm destructive actions
- Local only: everything runs on the user's machine, no external services

## CLI Pattern

Hybrid — frequent actions are flat, complex feature groups use subcommands:

```
ccm <action>                  # flat — account operations (most common)
ccm session <action>          # grouped — session management
ccm env <action>              # grouped — environment snapshots
ccm usage <action>            # grouped — usage stats
ccm help [module]             # help for all or specific module
ccm version                   # show version
```

### Global flags

| Flag | Description |
|---|---|
| `--no-color` | Disable colored output (also respects `NO_COLOR=1` env var) |
| `--version` | Show version (alias for `ccm version`) |
| `--help` | Show help (alias for `ccm help`) |

### Color initialization

The `--no-color` flag and `NO_COLOR` env var must be parsed **before** color variables are assigned. Implementation approach: color variables must NOT be declared as `readonly` at script top-level. Instead, a `init_colors()` function is called after argument pre-parsing. The main entry point first scans for `--no-color` in argv (without consuming it), sets `NO_COLOR=1` if found, then calls `init_colors()`, then proceeds to normal argument dispatch.

### Unicode and `--no-color`

When `--no-color` is active, all unicode symbols (checkmarks, warning triangles, arrows, progress spinners) are replaced with plain ASCII equivalents (`[ok]`, `[!!]`, `->`, `...`). This ensures clean output in terminals without unicode support.

## Module 1: Account Management

Existing features from `ccswitch`, restructured under the new CLI syntax. All current logic preserved.

### Commands

| Command | Description |
|---|---|
| `ccm add` | Add current logged-in account to managed accounts |
| `ccm remove <id>` | Remove account by number, email, or alias |
| `ccm switch` | Rotate to next account in sequence (order defined in `sequence.json`) |
| `ccm switch <id>` | Switch to specific account by number, email, or alias |
| `ccm undo` | Revert to previously active account |
| `ccm list` | List all managed accounts with metadata |
| `ccm status` | Show detailed status of active account |
| `ccm alias <id> <name>` | Set friendly name for an account |
| `ccm verify [id]` | Verify backup integrity (all or specific) |
| `ccm history` | Show recent switch history |
| `ccm export <path>` | Export all accounts to archive (credentials + configs) |
| `ccm import <path>` | Import accounts from archive |
| `ccm interactive` | Launch interactive menu mode |

### Changes from `ccswitch`

- `ccswitch --switch-to work` becomes `ccm switch work`
- `ccswitch --add-account` becomes `ccm add`
- `ccswitch --set-alias 1 work` becomes `ccm alias 1 work`
- `ccswitch --remove-account 2` becomes `ccm remove 2`
- All `--flag` style replaced with positional subcommands

### `switch` sequence behavior

`ccm switch` (no args) rotates to the next account in the `sequence` array defined in `sequence.json`. If current account is the last in the sequence, it wraps to the first. This matches the existing `ccswitch --switch` behavior.

### Data storage

No changes — continues to use `~/.claude-switch-backup/` with the existing v2.0 schema for `sequence.json`, credentials, and config backups.

## Module 2: Session Management

Manages Claude Code project session data stored in `~/.claude/projects/`.

### Background

Claude Code stores session data using a path-encoding convention:
- Project at `/Users/me/projects/foo` gets a session directory at `~/.claude/projects/-Users-me-projects-foo/`
- Each session is a `.jsonl` file containing conversation history
- A `memory/` subdirectory stores project-level memory files
- The `"cwd"` field inside `.jsonl` files references the original project path

Over time, sessions accumulate for deleted projects, renamed folders, and experiments. There is no built-in tooling to manage this.

### Path encoding/decoding

Claude Code encodes project paths by replacing every `/` with `-`. Example: `/Users/me/my-project` becomes `-Users-me-my-project`.

**Decoding is inherently lossy** because directory names can contain literal hyphens. `/Users/me/my-project` and a hypothetical `/Users/me/my/project` would produce the same encoded name. In practice this is not a problem because:
1. Real project paths rarely contain segments that create ambiguity
2. The decoding heuristic validates candidate paths against the filesystem — try replacing `-` with `/` greedily, then verify the path exists on disk
3. For `session list` display purposes, the decoded path is best-effort and the encoded directory name is the authoritative key

**Encoding function:** `encode_path() { echo "$1" | sed 's|/|-|g'; }`
**Decoding function:** Replace leading `-` with `/`, then remaining `-` with `/`, check if path exists. If not, iteratively try keeping some `-` as literal hyphens. Fall back to displaying the raw encoded name if no valid path is found.

### Commands

| Command | Description |
|---|---|
| `ccm session list` | List all project sessions with size, session count, last active date |
| `ccm session info <project-path>` | Show details for a specific project's sessions |
| `ccm session relocate <old> <new>` | Update session references after moving a project folder |
| `ccm session clean [--dry-run]` | Find and remove orphaned sessions (prompt for confirmation) |

### Behavior details

**`session list`**
- Reads `~/.claude/projects/` directory
- For each project session directory:
  - Decodes the directory name back to the original path (replace leading `-` and subsequent `-` back to `/`)
  - Counts `.jsonl` files
  - Sums total disk usage
  - Reads modification time of most recent `.jsonl` as "last active"
  - Checks if the original project path still exists on disk
- Output: table sorted by last active date (most recent first)
- Columns: project path (truncated with `~`), sessions, size, last active, status (active/orphaned)

**`session info <project-path>`**
- Takes a project path (e.g., `~/projects/foo` or `/Users/me/projects/foo`), resolves to absolute, encodes it, looks up the session directory
- Shows: number of sessions, total size, memory file count, last active date
- Lists individual session files with their sizes and dates

**`session relocate <old> <new>`**
- Existing implementation, moved from `ccswitch --relocate`
- Renames session directory using path encoding
- Updates `"cwd"` references in all `.jsonl` files via `sed`
- Updates path references in memory files
- Warns if `<new>` path does not exist on disk (could be a typo). Prompts for confirmation before proceeding.
- **Merge behavior:** When target session directory already exists, copies all files from old directory into new directory using `cp -n` (no-clobber) so existing files at the destination are preserved. Session files use UUID names so collisions are extremely unlikely, but if they occur, the newer destination version is kept. Then removes the old directory.

**`session clean [--dry-run]`**
- Cross-references every directory in `~/.claude/projects/` against actual disk paths
- Decodes each directory name back to the original path
- If the project folder no longer exists on disk, marks as orphaned
- With `--dry-run`: lists orphaned sessions with sizes, takes no action
- Without `--dry-run`: lists orphaned sessions, prompts for confirmation (`Remove N orphaned sessions? (y/N)`), then deletes on confirmation
- Never removes sessions for projects that still exist on disk
- **Limitation:** Projects on unmounted external drives or network shares will be falsely detected as orphaned. The confirmation prompt lists all candidates so the user can abort if they see false positives. A future enhancement could support an exclusion list.

## Module 3: Environment Snapshots + Audit

Capture and restore Claude Code environment state. Includes a token-efficiency auditor.

### Commands

| Command | Description |
|---|---|
| `ccm env snapshot [name]` | Capture current environment (auto-timestamp if no name) |
| `ccm env restore <name> [--force]` | Restore environment from snapshot |
| `ccm env list` | List all snapshots with dates and sizes |
| `ccm env delete <name>` | Remove a snapshot |
| `ccm env audit` | Analyze setup for token efficiency |

### What a snapshot captures

| File | Description |
|---|---|
| `~/.claude/settings.json` | Global settings and permissions |
| `~/.claude/.claude.json` | Active account config (oauthAccount structure only — tokens/credentials stripped) |
| `~/.claude/CLAUDE.md` | Global instructions (if exists) |
| `~/.claude/.mcp.json` | Global MCP server configuration (if exists) |

**Note:** Only the global `~/.claude/.mcp.json` is captured. Project-level `.mcp.json` files live in project repos and should be managed via git.

### What a snapshot does NOT capture

- Credentials or tokens (security risk — stripped before saving)
- Session `.jsonl` files (too large, not configuration)
- Project-level code files (those live in git)
- Project-level `.mcp.json` files (those live in git)

### Storage

`~/.claude-switch-backup/snapshots/<name>/` containing:
- `manifest.json` — timestamp, name, list of captured files with their source paths
- Copies of each captured file (flat — `settings.json`, `claude.json`, `CLAUDE.md`, `mcp.json`)

### Behavior details

**`env snapshot [name]`**
- Snapshot names must match `^[a-zA-Z0-9._-]+$` — alphanumeric, hyphens, underscores, and dots only. Rejects names with spaces, slashes, or shell metacharacters.
- If no name given, auto-generates: `snapshot-YYYY-MM-DD-HHMMSS`
- Copies each captured file into the snapshot directory
- For `.claude.json`: strips all fields except `oauthAccount` structure (removes tokens, session data)
- Writes `manifest.json`:
  ```json
  {
    "name": "before-mcp-changes",
    "created": "2026-03-24T12:00:00Z",
    "files": [
      {"source": "~/.claude/settings.json", "stored": "settings.json"},
      {"source": "~/.claude/.claude.json", "stored": "claude.json"},
      {"source": "~/.claude/CLAUDE.md", "stored": "CLAUDE.md"},
      {"source": "~/.claude/.mcp.json", "stored": "mcp.json"}
    ]
  }
  ```
- Only includes files that actually exist at snapshot time

**`env restore <name> [--force]`**
- Detects if Claude Code is running using the existing `is_claude_running()` function (checks `ps -eo pid,comm,args` for processes where the command name or first argument is `claude`). If running, aborts with error: "Claude Code is running. Please close it first, or use --force to restore anyway."
- `--force` flag overrides the running-process check
- Shows a summary of what will be restored and prompts for confirmation
- Restores each file from snapshot to its original location
- Files that existed in the snapshot but don't currently exist are created
- Files that currently exist but weren't in the snapshot are left untouched

**`env list`**
- Lists all snapshot directories under `~/.claude-switch-backup/snapshots/`
- Shows: name, creation date, number of files captured, total size

**`env delete <name>`**
- Removes the snapshot directory after confirmation

**`env audit`**
- Scans `~/.claude/.mcp.json` for configured MCP servers
- Checks each server name against a curated mapping of known MCP servers with CLI alternatives
- The mapping is a static associative array embedded in the script, manually updated by the developer

**Audit knowledge base:**

```bash
# Embedded in script as associative array
declare -A MCP_CLI_ALTERNATIVES=(
    ["playwright"]="npx playwright test|npx playwright codegen|~2000"
    ["postgres"]="psql -c 'query'|psql via Bash tool|~1500"
    ["filesystem"]="Built-in Read/Write/Glob/Grep tools|Already available|~1800"
    ["git"]="git CLI via Bash tool|Already available|~1200"
    ["sqlite"]="sqlite3 CLI via Bash tool|sqlite3 commands|~1000"
    ["docker"]="docker CLI via Bash tool|docker commands|~1500"
    ["redis"]="redis-cli via Bash tool|redis-cli commands|~800"
    ["mysql"]="mysql -e 'query'|mysql via Bash tool|~1200"
)
# Format: "cli_command|description|estimated_token_savings"
```

**Audit output format:**
```
Token Efficiency Audit
━━━━━━━━━━━━━━━━━━━━━

⚠ playwright (MCP) → CLI alternative available
  CLI: npx playwright test, npx playwright codegen
  Savings: ~2k tokens/request from tool schema removal

⚠ postgres (MCP) → CLI alternative available
  CLI: psql -c "SELECT ..."
  Savings: ~1.5k tokens/request

✓ context7 (MCP) → Keep (no CLI equivalent in knowledge base)
✓ figma (MCP) → Keep (no CLI equivalent in knowledge base)

Summary: 2 MCPs replaceable, estimated ~3.5k tokens saved per request
```

## Module 4: Usage Stats

Local analytics based on filesystem metadata. No API calls, no billing integration.

### Commands

| Command | Description |
|---|---|
| `ccm usage summary` | Overview of Claude Code footprint |
| `ccm usage top [--count N]` | Projects ranked by disk usage (default: top 10) |

### Behavior details

**`usage summary`**
- Scans `~/.claude/projects/` directory for all data
- Counts: total project session directories, total `.jsonl` files, total memory files
- Calculates: total disk usage, active vs orphaned project count
- Reads `~/.claude-switch-backup/sequence.json` for managed account count
- Counts sessions created in the last 7 days (based on file modification time — `mtime` — which is portable across macOS and Linux)

Output:
```
Claude Code Usage Summary
━━━━━━━━━━━━━━━━━━━━━━━━

Projects:      23 (19 active, 4 orphaned)
Sessions:      147 total (23 this week)
Memory files:  34
Disk usage:    284 MB
Accounts:      3 managed
```

**`usage top [--count N]`**
- Default: top 10 projects
- Ranks by total disk usage (sessions + memory)
- For each project: calculates total size, counts sessions, finds last modified `.jsonl`
- Truncates project paths using `~` for `$HOME`
- Platform-aware: uses `stat -f %m` on macOS, `stat -c %Y` on Linux for modification times

Output:
```
Top Projects by Disk Usage
━━━━━━━━━━━━━━━━━━━━━━━━━

 #  Project                          Sessions    Size   Last Active
 1  ~/AI/sozo-ai-chatbot                  49   82 MB   2 hours ago
 2  ~/AI/teamwork-cli                     24   41 MB   5 hours ago
 3  ~/Personal/projects/csc-app           45   38 MB   1 day ago
 ...
```

### Data source

All stats derived from:
- `~/.claude/projects/` directory structure and file metadata (size, modification time, file count)
- `~/.claude-switch-backup/sequence.json` for account data

No session file contents are read — only filesystem metadata.

### Platform considerations

File modification times are read differently per platform:
- macOS: `stat -f %m <file>` (epoch seconds)
- Linux: `stat -c %Y <file>` (epoch seconds)

The existing platform detection in the script (`detect_platform()`) is reused to select the correct `stat` variant.

## Help System

### `ccm help`

Top-level help lists all modules and their most common commands:

```
CCM — Claude Code Manager v3.0

Usage: ccm <command> [options]

Account Management:
  add, remove, switch, undo, list, status, alias, verify, history,
  export, import, interactive

Session Management:
  session list, session info, session relocate, session clean

Environment:
  env snapshot, env restore, env list, env delete, env audit

Usage Stats:
  usage summary, usage top

General:
  help [module]    Show help (optionally for a specific module)
  version          Show version

Run 'ccm help <module>' for detailed help on a module.
```

### `ccm help <module>`

Shows detailed help for a specific module (e.g., `ccm help session`, `ccm help env`).

### `ccm version`

Shows tool name and version:
```
ccm (Claude Code Manager) v3.0
```

Version numbering: `3.0` to indicate the major evolution from `ccswitch` v2.0.

## Rename Plan

- `ccswitch.sh` → `ccm.sh`
- Update all internal references (usage text, error messages, variable names where relevant)
- Update `README.md` to reflect new name and expanded scope
- Update `SCHEMA_VERSION` to `"3.0"`
- Repository rename is out of scope for the script itself (done manually on GitHub)

## Data Directory Structure

```
~/.claude-switch-backup/
  sequence.json                              # account registry (existing)
  configs/                                   # account config backups (existing)
  credentials/                               # account credential backups (existing)
  snapshots/                                 # NEW: environment snapshots
    <name>/
      manifest.json
      settings.json
      claude.json
      CLAUDE.md
      mcp.json

~/.claude/projects/                          # read/managed by session commands (not owned by ccm)
```

## Out of Scope

- Billing or cost tracking (requires API access)
- Team/multi-user features
- Auto-detection of project types
- AI-powered suggestions
- MCP server installation/management (audit recommends, doesn't act)
- GUI or web interface
- Session export/import (just a tar wrapper — use filesystem directly)
- Environment diff (use `diff` CLI directly against snapshot files)
- Sourced module files (future optimization if script exceeds ~4000 lines)

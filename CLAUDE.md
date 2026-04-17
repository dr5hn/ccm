# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CCM (Claude Code Manager) is a Bash CLI toolkit for managing multiple Claude Code accounts, sessions, environments, and health. Single-file architecture (`ccm.sh`, ~6600 lines) with a static landing page (`index.html`), a statusline visual guide (`statusline.html`), and a standalone statusline installer (`statusline.sh`).

## Commands

```bash
# Release (bumps version in ccm.sh + CHANGELOG.md, commits, pushes, creates GitHub release)
./release.sh patch|minor|major|X.Y.Z [--dry-run]

# Test locally after changes
bash ccm.sh version
bash ccm.sh doctor
bash ccm.sh help
bash ccm.sh permissions audit
bash ccm.sh clean tmp --days 365   # should find nothing
bash ccm.sh usage history --days 1
bash ccm.sh profiles list
bash ccm.sh watch status
bash ccm.sh recover
bash ccm.sh session archives

# Landing page — open index.html directly in browser, no build step
# Statusline guide — open statusline.html directly in browser
```

There is no test suite, linter, or build system. Validate changes by running commands manually.

## Architecture

### ccm.sh — Single-file modular Bash script

The script follows a strict top-to-bottom section layout:

1. **Constants & Utilities** (lines 1–550) — `CCM_VERSION`, color init, platform detection (`detect_platform()` → macos/wsl/linux), JSON helpers, validation functions, `write_json()` (atomic: temp file → validate → mv)
2. **Credential Management** (lines 261–370) — macOS uses Keychain, Linux/WSL uses file-based storage with atomic writes (temp + mv). `read_credentials()`/`write_credentials()` are platform-dispatched
3. **Sequence & Cache** (lines 370–550) — `sequence.json` is the account registry (schema v3.1, auto-migrates from v1/v2/v3). `resolve_account_identifier()` matches by number, email, or alias. Bindings stored in `sequence.json` under `"bindings"` key
4. **Session Management** (lines 550–1160) — `session list|info|search|relocate|clean|archive|restore|archives`. Path encoding: `/` → `-` for directory names under `~/.claude/projects/`
5. **Account Management** (lines 1160–2800) — Switching (checks project bindings first, supports `--isolated [--quiet]` for CLAUDE_CONFIG_DIR profiles), reordering (two-pass credential rename with pre-validated JSON), bind/unbind, shell hook (`ccm hook [--isolated]`), export/import
6. **Help System** (lines 2870–3350) — Topic-based help with `show_help()`, covers all modules including profiles, watch, recover, setup
7. **Environment Snapshots** (lines 3350–3755) — Capture/restore settings.json, MCP config, CLAUDE.md (strips tokens on save)
8. **Usage Module** (lines 3755–4345) — `usage summary|top|history|dashboard|compare` (history parses JSONL for token analytics using jq, dashboard attributes usage to accounts via switch history)
9. **Health & Maintenance** (lines 4345–5330) — `doctor` (13 checks), `clean` (9 targets + all), `permissions audit` (duplicate/dead rule detection)
10. **Profiles Module** (lines 5333–5535) — `switch_isolated [--quiet]` creates CLAUDE_CONFIG_DIR profiles (quiet mode prints only the path for hook use), `cmd_profiles` routes list/sync/delete
11. **Watch Module** (lines 5536–5724) — `cmd_watch` routes start/stop/status, background polling of `rate-limits.json`
12. **Usage Dashboard Module** (lines 5725–5942) — `usage_dashboard` with per-account token attribution, `format_token_count` helper
13. **Session Archive Module** (lines 5943–6144) — `session_archive` compresses old JSONL to tar.gz, `session_restore`, `session_archives_list`
14. **Setup Module** (lines 6145–6296) — `cmd_setup` interactive first-run wizard (6 steps)
15. **Recover Module** (lines 6297–6409) — `cmd_recover` checks credential consistency (4 checks)
16. **Statusline Module** (lines 6410–6691) — `statusline install|remove` generates a bash script that reads Claude Code session JSON via stdin, writes rate-limits.json for the watcher
17. **Init Module** (lines 6693–6889) — `init` auto-generates `.claudeignore` by detecting project type from manifest files
18. **Permissions Module** (lines 6890–7050) — `permissions audit [--fix]` scans settings.json for duplicate/contradictory/dead rules
19. **Main Entry** (lines 7050–7115) — `--no-color` parsing, dependency checks, case-based command dispatch with deprecation notices for removed commands

### Data layout

```
~/.claude-switch-backup/
├── sequence.json              # Account registry (metadata, history, aliases, bindings)
├── credentials/               # Per-account OAuth backups (atomic writes)
├── configs/                   # Per-account config backups
├── snapshots/                 # Environment snapshots
├── profiles/                  # Isolated CLAUDE_CONFIG_DIR profiles (NEW in v4.0)
│   ├── work/                  # Complete Claude Code config directory
│   └── personal/
├── archives/                  # Compressed session archives (NEW in v4.0)
│   ├── index.json             # Archive metadata
│   └── *.tar.gz               # Compressed sessions
├── usage-history.json         # Per-account usage aggregates (NEW in v4.0)
├── rate-limits.json           # Latest rate limit snapshot from statusline (NEW in v4.0)
└── watch.pid                  # Background watcher PID (NEW in v4.0)

~/.claude/projects/            # Claude Code session directories
└── -Users-darshan-project/    # Encoded path (/ → -)

~/.claude/ccm-statusline.sh    # Installed statusline script (reads session JSON from stdin)
```

### Key patterns

- **Cross-platform branching**: `detect_platform()` result gates credential storage, date formatting (`gdate` vs `date`), stat flags, and file operations throughout
- **Atomic writes**: All credential, config, and JSON writes use temp file → validate → `mv` to prevent corruption on interruption
- **Function docstrings**: Every function has `# Purpose:`, `# Parameters:`, `# Returns:`, `# Usage:` comments
- **Strict mode**: `set -euo pipefail` at top of script
- **Numeric validation**: All `--days`, `--limit`, `--keep` args validated with regex before use (prevents `set -e` aborts from `find -mtime +NaN`)
- **Permission preservation**: When writing to `settings.json`, original file permissions are read with `stat` and restored after write (avoids forcing 600 on a 644 file)
- **Orphan detection**: Process orphan detection (`ppid == 1`) is gated to macOS only — unreliable on Linux/WSL where systemd children legitimately have ppid=1
- **CLAUDE_CONFIG_DIR isolation**: Profiles create complete config directories that Claude Code reads via the `CLAUDE_CONFIG_DIR` env var, enabling true concurrent sessions
- **Statusline as data bridge**: The statusline script writes rate limit data to `rate-limits.json` on every prompt render, which the `ccm watch` background process polls

## Version Bumping

Version lives in two places that must stay in sync:
- `ccm.sh` line 9: `readonly CCM_VERSION="X.Y.Z"`
- `CHANGELOG.md`: `## [X.Y.Z] - YYYY-MM-DD` section

Use `./release.sh` to update both automatically.

## Skill Files

The CCM skill (for Claude Code / Cursor / Codex / Gemini CLI) lives in two locations:
- `ccm/SKILL.md` — tracked in git, published via `npx skills add dr5hn/ccm@ccm`
- `.agents/skills/ccm/SKILL.md` — local copy, gitignored (`.agents/` in `.gitignore`)

When updating the skill, edit `ccm/SKILL.md` and copy to `.agents/skills/ccm/SKILL.md`. The skill description triggers on keywords like "ccm", "switch accounts", "clean tmp", "statusline", "bind", "usage history", "profiles", "isolated", "watch", "rate limit", "dashboard", "session archive", "setup", "recover", etc.

## Statusline

The statusline script is embedded in `ccm.sh` as a heredoc inside `cmd_statusline()`. It is also duplicated as the standalone `statusline.sh` installer. **When modifying the statusline, update both locations.**

The script reads Claude Code session JSON from stdin (piped by Claude Code automatically) and account data directly from `sequence.json` + `.claude.json` files (no `ccm` binary dependency). The `.claude.json` config path has a fallback: checks `~/.claude/.claude.json` first, then `~/.claude.json`. Also uses `CLAUDE_CODE_USER_EMAIL` env var (v2.1.51+) as a fallback for account detection.

Token count uses the sum of `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` from `context_window.current_usage` (not `total_input_tokens`) to match Claude Code's own display.

The statusline also writes rate limit data to `~/.claude-switch-backup/rate-limits.json` on each invocation, which the `ccm watch` background process monitors.

## Landing Page (index.html)

Static single-file page. Dark theme with glassmorphism design, CSS variables for theming. No framework, no build. Fonts: Inter + JetBrains Mono via Google Fonts. Includes SEO (Open Graph, Twitter Card, JSON-LD). Terminal demos use a JS animation system with tab switching.

## Release Checklist

When releasing a new version, these files must all be updated:
1. `ccm.sh` line 9: `readonly CCM_VERSION="X.Y.Z"`
2. `CHANGELOG.md`: new `## [X.Y.Z]` section
3. `README.md`: new features/commands
4. `ccm/SKILL.md`: new commands, triggers, workflows (then copy to `.agents/skills/ccm/`)
5. `index.html`: feature cards, command accordion, terminal demos
6. `statusline.sh`: if statusline script changed (keep in sync with heredoc in ccm.sh)
7. `CLAUDE.md`: update architecture section with new line ranges and modules
8. GitHub release via `gh release create` or `./release.sh`

The `./release.sh` script only handles steps 1, 2, and 8 automatically. Steps 3–7 are manual.

## Removed Features (v4.0)

These commands were removed in v4.0 because Claude Code now has native equivalents:
- `ccm status` → use `ccm list` or Claude Code's `/status`
- `ccm interactive` → use direct CLI commands
- `ccm optimize` → use Claude Code's `/insights`
- `ccm launch` → use Claude Code's `--permission-mode` flags

Removed commands show deprecation notices with migration instructions.

## Conventions

- Commit format: `<type>: <description>` (e.g., `feat:`, `fix:`, `docs:`, `chore:`)
- Dependencies: bash 4.4+, jq, curl (checked at startup via `check_dependencies()`)
- All user input validated before use (emails, snapshot names, JSON, numeric args)
- Destructive operations require `--dry-run` support or confirmation prompts
- Backups created before modifying `settings.json` in `permissions audit --fix`
- `--no-color` flag disables all ANSI output globally
- Bindings auto-cleaned when account is removed (`cmd_remove_account`)
- Bindings updated when accounts are reordered (`cmd_reorder`)
- `.claudeignore` generated by `ccm init` is per-project — added to CCM repo's `.gitignore`

## Known Gotchas

- **`[[ -f "*.sln" ]]` doesn't glob in bash** — .NET detection in `cmd_init` uses `compgen -G` instead
- **`grep -c` exits 1 on zero matches** — always guard with `|| echo "0"` under `set -e`
- **`write_json` applies chmod 600** — fine for credentials/sequence.json but wrong for settings.json. When writing settings.json, preserve original permissions with `stat` + `chmod`
- **macOS `sed -i` requires backup extension** — use `sed -i.bak` then `rm .bak`, or write to temp + mv
- **`jq -s 'from_entries'` expects `{"key":...,"value":...}` objects** — plain `"k": v` fragments are not valid input
- **Session JSONL files can be multi-MB** — always use `grep -qF` (fixed-string) not `grep -q` (regex) for path matching to avoid catastrophic backtracking
- **Reorder credential rename** — sequence.json is written BEFORE file renames so recovery is possible if interrupted mid-rename
- **CLAUDE_CONFIG_DIR on macOS** — Keychain entries are global; isolated profiles use file-based credential storage for true isolation
- **Heredoc within heredoc** — the statusline heredoc inside `cmd_statusline()` uses `STATUSLINE_EOF` delimiter; the rate-limits JSON write inside it uses `RLJSON` to avoid delimiter collision
- **Zsh associative array subscripts** — `arr["$key"]=v` in zsh stores the key *including the literal quote characters*, whereas bash strips them. The `_ccm_check_binding` hook must use `_ccm_bindings[$path]=v` (unquoted subscript) so lookups with `${_ccm_bindings[$PWD]}` match. Any future hook code that populates associative arrays needs the same treatment
- **`ccm hook --isolated`** — emits a shell hook that sets `CLAUDE_CONFIG_DIR` per-shell instead of calling `ccm switch` (which rewrites global creds). This is the concurrent-terminal-safe variant; default mode is retained for backward compatibility. The isolated hook captures the profile path via `command ccm switch --isolated --quiet <n>`, so the `--quiet` flag in `switch_isolated` is load-bearing for that flow

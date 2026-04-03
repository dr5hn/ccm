# Changelog

All notable changes to CCM (Claude Code Manager) will be documented in this file.

## [4.0.0] - 2026-04-03

### Added
- **`ccm switch --isolated <account>`** — create CLAUDE_CONFIG_DIR-based isolated profiles for true concurrent multi-account sessions in different terminals
- **`ccm profiles list|sync|delete`** — manage isolated profile directories
- **`ccm watch --threshold N [--auto]`** — background rate limit monitor that notifies or auto-switches accounts when 5-hour usage exceeds threshold
- **`ccm watch stop|status`** — stop watcher or show current state and latest rate limit data
- **`ccm usage dashboard [--days N] [--account <name>]`** — per-account token usage attribution by correlating session JSONL with switch history
- **`ccm usage compare`** — side-by-side account comparison
- **`ccm session archive [--older-than Nd] [--project <path>] [--dry-run]`** — compress old sessions to tar.gz archives instead of deleting
- **`ccm session restore <archive>`** — restore sessions from a compressed archive
- **`ccm session archives`** — list all saved archives with metadata
- **`ccm usage sessions [--project <path>] [--days N] [--limit N]`** — per-session token usage and estimated cost breakdown with model-specific pricing (Opus/Sonnet/Haiku)
- **`ccm session summary [path] [--limit N]`** — show what happened in each session: topic (first user message), tool usage breakdown, and files modified
- **`ccm setup`** — interactive first-run wizard (dependency check, account import, statusline install, shell hook setup, project init)
- **`ccm recover`** — detect and fix inconsistent credential state from interrupted operations (checks sequence.json vs files, Keychain, profiles)
- Statusline now writes rate limit data to `~/.claude-switch-backup/rate-limits.json` for the watcher module
- Statusline shows bound account indicator when in a bound project directory
- Statusline uses `CLAUDE_CODE_USER_EMAIL` env var (Claude Code v2.1.51+) as fallback for account detection

### Removed
- **`ccm status`** — use `ccm list` or Claude Code's native `/status` command
- **`ccm interactive`** — use direct CLI commands instead
- **`ccm optimize`** — use Claude Code's native `/insights` command (AI-powered, 3,200 lines)
- **`ccm launch`** — use Claude Code's native `--permission-mode` flags or `/sandbox` command

### Changed
- Version bumped to 4.0.0 (major: breaking changes from removed commands)
- Deprecated commands show migration notices instead of errors
- Help text updated with all new commands and examples
- Session module now routes `archive|restore|archives` subcommands
- Usage module now routes `dashboard|compare` subcommands

## [3.3.2] - 2026-03-30
### Fixed
- Add error checking to Keychain rename during account reorder to prevent silent data inconsistency


## [3.3.1] - 2026-03-30

### Added
- **`ccm hook`** — outputs shell hook code for auto-switching accounts on `cd`. Add `eval "$(ccm hook)"` to `.zshrc`/`.bashrc` and bound projects auto-switch when you enter them
- Shell hook caches bindings in an associative array at startup (~30ms), then does pure-bash lookups on every `cd` (~0ms overhead)
- Parent directory matching — binding `~/Personal` matches `~/Personal/projects/foo/src`
- Zsh uses native `chpwd` hook; Bash wraps `cd`/`pushd`/`popd`
- Mtime guard: re-reads `sequence.json` only when the file changes
- `ccm bind` now shows a tip about `ccm hook` for auto-switch on cd

### Security
- **Eliminated `eval` command injection** — replaced `eval "$(jq ...)"` in statusline with safe `IFS read` + jq `@tsv` pattern; data is never interpreted as shell code
- **Fixed temp file race condition** — credential and config writes now use `umask 077` before `mktemp`, ensuring files are owner-only from creation
- **Added path traversal protection** — new `validate_account_params()` validates account numbers (numeric-only) and emails (regex) before constructing file paths
- **Secured trap cleanup patterns** — `trap "rm -rf '$dir'"` replaced with `trap 'rm -rf -- "$dir"'` for proper deferred expansion and end-of-options safety
- **Fixed awk injection vectors** — all `awk "... $var ..."` patterns replaced with safe `awk -v name="$var" '...'` variable passing
- **Added jq result validation** — `resolve_account_identifier()` now validates extracted account numbers are numeric before use
- **Added input bounds checking** — identifier inputs limited to 255 characters

## [3.3.0] - 2026-03-28

### Added
- **`ccm statusline [install|remove]`** — install a smart statusline at the bottom of Claude Code showing context bar, token count, session cost, duration, burn rate, 5hr/7-day rate limits with reset times, project directory, git branch, Claude Code version, and CCM account info
- **`ccm status --short`** — single-line account output for integrations
- **Standalone statusline installer** — `curl -fsSL .../statusline.sh | bash` for sharing within orgs without CCM dependency
- **Visual statusline guide** — `statusline.html` with annotated diagram explaining all 12 data points
- Statusline adapts: 2 lines for single-account users, 3 lines for multi-account, compact warning at 80%+ context
- Rate limit color coding: green <60%, yellow 60-79%, red 80%+

### Fixed
- Token count in statusline now matches Claude Code's display (sums input + cache_creation + cache_read)
- `ccm status` now forwards arguments (was missing `shift` in dispatcher)
- Statusline reads config from both `~/.claude/.claude.json` and `~/.claude.json` fallback

## [3.2.0] - 2026-03-28

### Added
- **`ccm launch [auto|yolo|plan|safe]`** — launch Claude Code with preset permission modes and terminal state reset on exit (fixes broken Ctrl-C/Ctrl-D in tmux/kitty/ghostty)
- **`ccm init [--force]`** — auto-generate `.claudeignore` based on detected project type (Node, Python, Go, Rust, Java, Ruby, PHP, .NET, Dart, Swift)
- **`ccm permissions audit [--fix]`** — scan settings.json for duplicate rules, contradictions, verbatim "Always Allow" junk, and rule count bloat

### Fixed
- Atomic credential writes on Linux/WSL (temp file + mv) to prevent corruption on interrupted writes
- Atomic config backup writes (same pattern)
- Stale bindings now auto-removed when an account is deleted
- Reorder writes sequence.json before credential rename for safe recovery if interrupted
- Bindings updated during account reorder to reference new account numbers
- `--keep 0` in `clean_history` rejected (would wipe entire file)
- `cmd_optimize` MEMORY.md path encoding fixed (`%2F` → `-`)

## [3.1.0] - 2026-03-28

### Added
- **`ccm clean tmp`** — clean orphaned subagent output files from `/tmp/claude-*/` (`--days N`, default 1)
- **`ccm clean processes`** — detect and kill orphaned Claude subagent processes
- **`ccm usage history`** — token usage analytics with per-project and per-day breakdowns (`--days N`, `--project <path>`)
- **`ccm session search`** — full-text search across all session JSONL files (`--limit N`)
- **`ccm reorder`** — reorder account positions with automatic credential renaming
- **`ccm bind`** / **`ccm unbind`** — bind project directories to specific accounts for auto-switching
- **`ccm list`** now shows project bindings
- **Enhanced `ccm doctor`** — 4 new health checks: total disk size, tmp output files, orphaned processes, hook async audit

### Changed
- `ccm switch` (no args) now checks project bindings before cycling to next account
- `ccm clean all` now includes tmp file cleanup and orphaned process detection
- Schema version bumped to 3.1 (auto-migrates from 3.0, adds `bindings` field)

## [3.0.1] - 2026-03-25

### Fixed
- `ccm session relocate` no longer hangs on large projects — uses `grep -qF` (fixed-string) instead of regex, adds per-file progress output

## [3.0.0] - 2026-03-25

### Added
- **Renamed from `ccswitch` to `ccm`** — new hybrid CLI with subcommand pattern
- **Session management** — `ccm session list`, `info`, `relocate`, `clean`
- **Environment snapshots** — `ccm env snapshot`, `restore`, `list`, `delete`
- **MCP token audit** — `ccm env audit` flags MCP servers with CLI alternatives
- **Usage stats** — `ccm usage summary`, `usage top`
- **Doctor** — `ccm doctor` scans for health issues (stale locks, log bloat, cache, orphaned sessions)
- **Clean** — `ccm clean debug|telemetry|todos|history|cache|all` with `--dry-run` support
- **Token optimizer** — `ccm optimize` analyzes context window footprint
- **Help system** — `ccm help <module>` for per-module documentation
- **Version command** — `ccm version`
- **ASCII art banner** — branded logo in help output and interactive mode
- **Installer script** — `install.sh` for sudo-free install to `~/.ccm/bin/`
- **Skills ecosystem** — installable via `npx skills add dr5hn/ccm@ccm`
- **Website** — `index.html` with CRT terminal aesthetic
- **Cross-platform date formatting** — `format_iso_date()` helper for macOS and Linux
- **Path decoding heuristic** — filesystem-walking algorithm for accurate session path display

### Changed
- CLI pattern: `--flag` style replaced with hybrid subcommands (`ccm switch` instead of `ccswitch --switch`)
- Color initialization deferred to support `--no-color` from any argument position
- Unicode symbols replaced with ASCII equivalents when `--no-color` is active
- `cmd_remove_account` and `cmd_set_alias` now accept aliases (not just numbers/emails)
- Schema version bumped from `2.0` to `3.0` with automatic migration
- Interactive mode header updated with ASCII art logo

### Fixed
- `--no-color` flag now works correctly (colors were previously `readonly` and couldn't be overridden)
- Path decoding no longer splits hyphenated directory names into separate segments
- `date -j` macOS-only calls replaced with cross-platform helper
- Stale `account_map` in interactive mode loop now properly reset between iterations

## [2.0.0] - 2025-11-24

### Added
- Account aliases (`--set-alias`)
- Switch history tracking (last 10 entries)
- Usage count per account
- Health status monitoring
- Schema v2.0 with automatic migration from v1.0
- Account verification (`--verify`)
- Export/Import (`--export`, `--import`)
- Interactive mode (`--interactive`)

### Changed
- Major code refactoring for readability and maintainability
- Added comprehensive docstrings to all functions

## [1.0.0] - 2025-07-02

### Added
- Initial release as `ccswitch`
- Multi-account add/remove/switch
- macOS Keychain and Linux file-based credential storage
- Cross-platform support (macOS, Linux, WSL)
- Container detection

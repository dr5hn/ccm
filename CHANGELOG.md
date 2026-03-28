# Changelog

All notable changes to CCM (Claude Code Manager) will be documented in this file.

## [3.1.0] - 2026-03-27

### Added
- **`ccm clean tmp`** — clean orphaned subagent output files from `/tmp/claude-*/` (`--days N`, default 1)
- **`ccm clean processes`** — detect and kill orphaned Claude subagent processes
- **`ccm usage history`** — token usage analytics with per-project and per-day breakdowns (`--days N`, `--project <path>`)
- **`ccm session search`** — full-text search across all session JSONL files (`--limit N`)
- **`ccm reorder`** — reorder account positions with automatic credential renaming
- **`ccm bind`** / **`ccm unbind`** — bind project directories to specific accounts for auto-switching
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

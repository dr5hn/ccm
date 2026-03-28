# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CCM (Claude Code Manager) is a Bash CLI toolkit for managing multiple Claude Code accounts, sessions, environments, and health. Single-file architecture (`ccm.sh`, ~4900 lines) with a static landing page (`index.html`).

## Commands

```bash
# Release (bumps version in ccm.sh + CHANGELOG.md, commits, pushes, creates GitHub release)
./release.sh patch|minor|major|X.Y.Z [--dry-run]

# Test locally after changes
bash ccm.sh version
bash ccm.sh doctor
bash ccm.sh help

# Landing page — open index.html directly in browser, no build step
```

There is no test suite, linter, or build system. Validate changes by running commands manually.

## Architecture

### ccm.sh — Single-file modular Bash script

The script follows a strict top-to-bottom section layout:

1. **Constants & Utilities** (lines 1–655) — `CCM_VERSION`, color init, platform detection (`detect_platform()` → macos/wsl/linux), JSON helpers, validation functions
2. **Credential Management** (lines 261–360) — macOS uses Keychain, Linux/WSL uses file-based storage with 600 permissions. `read_credentials()`/`write_credentials()` are platform-dispatched
3. **Sequence & Cache** (lines 364–492) — `sequence.json` is the account registry (schema v3.1, auto-migrates from v1/v2/v3). `resolve_account_identifier()` matches by number, email, or alias
4. **Session Management** (lines 655–1080) — `session list|info|relocate|clean|search`. Path encoding: `/` → `-` for directory names under `~/.claude/projects/`
5. **Account Management** (lines 1080–2230) — Switching (with project bindings), reordering, bind/unbind, export/import
6. **Interactive Mode** — Menu-driven TUI with ASCII art
7. **Help System** — Topic-based help with `show_help()`
8. **Environment Snapshots** — Capture/restore settings.json, MCP config, CLAUDE.md (strips tokens on save)
9. **Usage Module** — `usage summary|top|history` (history parses JSONL for token analytics)
10. **Health & Maintenance** — `doctor` (13 checks), `clean` (7 targets + all), `optimize` (token analysis)
11. **Main Entry** — `--no-color` parsing, dependency checks, case-based command dispatch

### Data layout

```
~/.claude-switch-backup/
├── sequence.json              # Account registry (metadata, history, aliases, bindings)
├── credentials/               # Per-account OAuth backups
└── snapshots/                 # Environment snapshots

~/.claude/projects/            # Claude Code session directories
└── -Users-darshan-project/    # Encoded path (/ → -)
```

### Key patterns

- **Cross-platform branching**: `detect_platform()` result gates credential storage, date formatting (`gdate` vs `date`), and file operations throughout
- **Safe JSON writes**: Write to temp file → `jq` validate → `mv` to target (atomic)
- **Function docstrings**: Every function has `# Purpose:`, `# Parameters:`, `# Returns:`, `# Usage:` comments
- **Strict mode**: `set -euo pipefail` at top of script

## Version Bumping

Version lives in two places that must stay in sync:
- `ccm.sh` line 9: `readonly CCM_VERSION="X.Y.Z"`
- `CHANGELOG.md`: `## [X.Y.Z] - YYYY-MM-DD` section

Use `./release.sh` to update both automatically.

## Landing Page (index.html)

Static single-file page. Dark theme with glassmorphism design, CSS variables for theming. No framework, no build. Fonts: Inter + JetBrains Mono via Google Fonts. Includes SEO (Open Graph, Twitter Card, JSON-LD).

## Conventions

- Commit format: `<type>: <description>` (e.g., `feat:`, `fix:`, `docs:`)
- Dependencies: bash 4.4+, jq, curl (checked at startup via `check_dependencies()`)
- All user input validated before use (emails, snapshot names, JSON)
- Destructive operations require `--dry-run` support or confirmation prompts
- `--no-color` flag disables all ANSI output globally

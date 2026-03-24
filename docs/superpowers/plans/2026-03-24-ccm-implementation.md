# CCM (Claude Code Manager) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `ccswitch` to `ccm` and expand it from an account switcher into a full Claude Code environment manager with session management, environment snapshots, token-efficiency auditing, and usage stats.

**Architecture:** Single bash script (`ccm.sh`) replacing `ccswitch.sh`. Existing account management logic is preserved and restructured under a hybrid CLI pattern (flat commands for common actions, subcommands for grouped features). Three new modules are added: session management, environment snapshots + audit, and usage stats. All data stays in `~/.claude-switch-backup/`.

**Tech Stack:** Bash 4.4+, jq, standard Unix utilities (stat, find, du, diff, sed, tar). No external dependencies beyond what `ccswitch.sh` already requires.

**Spec:** `docs/superpowers/specs/2026-03-24-ccm-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Rename | `ccswitch.sh` → `ccm.sh` | Main script — all modules |
| Modify | `README.md` | Updated docs for ccm |
| Keep | `LICENSE` | No changes |
| Keep | `.gitignore` | No changes |

The tool remains a single file. All modules live in `ccm.sh`.

---

## Task 1: Rename and Restructure CLI Dispatch

**Files:**
- Rename: `ccswitch.sh` → `ccm.sh`
- Modify: `ccm.sh` (entire main() function and show_usage())

This task converts the `--flag` style CLI to the hybrid subcommand pattern, and renames all internal references from `ccswitch` to `ccm`.

- [ ] **Step 1: Rename the file**

```bash
git mv ccswitch.sh ccm.sh
```

- [ ] **Step 2: Update the script header and constants**

In `ccm.sh`, update:
- Script header comment: "Multi-Account Switcher for Claude Code" → "CCM — Claude Code Manager"
- Add version constant: `readonly CCM_VERSION="3.0"`
- Update `SCHEMA_VERSION` from `"2.0"` to `"3.0"`
- Add `CLAUDE_PROJECTS_DIR` constant: `readonly CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"`

- [ ] **Step 3: Restructure color initialization**

Replace the top-level readonly color definitions (lines 18-34) with a deferred `init_colors()` function. Color variables must NOT be `readonly` since `--no-color` flag needs to override them after arg pre-parsing.

```bash
# Color variables (initialized by init_colors, after --no-color pre-parse)
COLOR_RED=''
COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_BLUE=''
COLOR_CYAN=''
COLOR_BOLD=''
COLOR_RESET=''

# Unicode/ASCII symbols (set by init_colors based on NO_COLOR)
SYM_INFO='i'
SYM_OK='[ok]'
SYM_WARN='[!!]'
SYM_ERR='[x]'
SYM_STEP='->'
SYM_PROGRESS='...'

init_colors() {
    if [[ "${NO_COLOR:-0}" -eq 0 ]] && [[ -t 1 ]]; then
        COLOR_RED='\033[0;31m'
        COLOR_GREEN='\033[0;32m'
        COLOR_YELLOW='\033[0;33m'
        COLOR_BLUE='\033[0;34m'
        COLOR_CYAN='\033[0;36m'
        COLOR_BOLD='\033[1m'
        COLOR_RESET='\033[0m'
        SYM_INFO='ℹ'
        SYM_OK='✓'
        SYM_WARN='⚠'
        SYM_ERR='✗'
        SYM_STEP='→'
        SYM_PROGRESS='⟳'
    fi
}
```

Update all logging functions to use `SYM_*` variables instead of hardcoded unicode:
```bash
log_info()    { echo -e "${COLOR_BLUE}${SYM_INFO}${COLOR_RESET} $*"; }
log_success() { echo -e "${COLOR_GREEN}${SYM_OK}${COLOR_RESET} $*"; }
log_warning() { echo -e "${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} $*" >&2; }
log_error()   { echo -e "${COLOR_RED}${SYM_ERR}${COLOR_RESET} $*" >&2; }
log_step()    { echo -e "${COLOR_CYAN}${SYM_STEP}${COLOR_RESET} $*"; }
show_progress() { echo -n -e "${COLOR_CYAN}${SYM_PROGRESS}${COLOR_RESET} ${1}..."; }
complete_progress() { echo -e " ${COLOR_GREEN}${SYM_OK}${COLOR_RESET}"; }
```

- [ ] **Step 4: Rewrite main() with hybrid CLI dispatch**

Replace the entire `main()` function with the new subcommand routing:

```bash
main() {
    # Pre-parse global flags before color init
    local args=("$@")
    for arg in "${args[@]}"; do
        case "$arg" in
            --no-color) NO_COLOR=1 ;;
        esac
    done

    init_colors

    # Strip --no-color from args for downstream parsing
    local clean_args=()
    for arg in "${args[@]}"; do
        [[ "$arg" != "--no-color" ]] && clean_args+=("$arg")
    done
    set -- "${clean_args[@]}"

    # Basic checks
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        log_error "Do not run this script as root (unless running in a container)"
        exit 1
    fi

    check_bash_version
    check_dependencies

    case "${1:-}" in
        # Account management (flat commands)
        add)            cmd_add_account ;;
        remove)         shift; cmd_remove_account "$@" ;;
        switch)         shift; if [[ $# -gt 0 ]]; then cmd_switch_to "$@"; else cmd_switch; fi ;;
        undo)           cmd_undo ;;
        list)           cmd_list ;;
        status)         cmd_status ;;
        alias)          shift; cmd_set_alias "$@" ;;
        verify)         shift; cmd_verify "$@" ;;
        history)        cmd_history ;;
        export)         shift; cmd_export "$@" ;;
        import)         shift; cmd_import "$@" ;;
        interactive)    cmd_interactive ;;

        # Grouped commands
        session)        shift; cmd_session "$@" ;;
        env)            shift; cmd_env "$@" ;;
        usage)          shift; cmd_usage "$@" ;;

        # General
        help)           shift; show_help "$@" ;;
        version)        show_version ;;
        --help)         show_help ;;
        --version)      show_version ;;
        "")             show_help ;;
        *)              log_error "Unknown command '$1'"; echo "Run 'ccm help' for usage."; exit 1 ;;
    esac
}
```

- [ ] **Step 5: Add version command**

```bash
show_version() {
    echo "ccm (Claude Code Manager) v${CCM_VERSION}"
}
```

- [ ] **Step 6: Rewrite help system**

Replace `show_usage()` with `show_help()` that supports per-module help:

```bash
show_help() {
    local module="${1:-}"

    case "$module" in
        session)
            echo -e "${COLOR_BOLD}Session Management${COLOR_RESET}"
            echo "Usage: ccm session <command>"
            echo ""
            echo "Commands:"
            echo "  list                          List all project sessions"
            echo "  info <project-path>           Show session details for a project"
            echo "  relocate <old-path> <new-path> Update sessions after moving a project"
            echo "  clean [--dry-run]             Remove orphaned sessions"
            ;;
        env)
            echo -e "${COLOR_BOLD}Environment Management${COLOR_RESET}"
            echo "Usage: ccm env <command>"
            echo ""
            echo "Commands:"
            echo "  snapshot [name]               Capture current environment"
            echo "  restore <name> [--force]      Restore from snapshot"
            echo "  list                          List all snapshots"
            echo "  delete <name>                 Remove a snapshot"
            echo "  audit                         Analyze MCP setup for token efficiency"
            ;;
        usage)
            echo -e "${COLOR_BOLD}Usage Stats${COLOR_RESET}"
            echo "Usage: ccm usage <command>"
            echo ""
            echo "Commands:"
            echo "  summary                       Overview of Claude Code footprint"
            echo "  top [--count N]               Top projects by disk usage"
            ;;
        "")
            echo -e "${COLOR_BOLD}CCM — Claude Code Manager v${CCM_VERSION}${COLOR_RESET}"
            echo "Usage: ccm <command> [options]"
            echo ""
            echo -e "${COLOR_BOLD}Account Management:${COLOR_RESET}"
            echo "  add                             Add current account"
            echo "  remove <id>                     Remove account by number, email, or alias"
            echo "  switch [id]                     Switch account (next or specific)"
            echo "  undo                            Revert last switch"
            echo "  list                            List managed accounts"
            echo "  status                          Show active account details"
            echo "  alias <id> <name>               Set account alias"
            echo "  verify [id]                     Verify account backups"
            echo "  history                         Show switch history"
            echo "  export <path>                   Export accounts to archive"
            echo "  import <path>                   Import accounts from archive"
            echo "  interactive                     Interactive menu mode"
            echo ""
            echo -e "${COLOR_BOLD}Session Management:${COLOR_RESET}"
            echo "  session list|info|relocate|clean"
            echo ""
            echo -e "${COLOR_BOLD}Environment:${COLOR_RESET}"
            echo "  env snapshot|restore|list|delete|audit"
            echo ""
            echo -e "${COLOR_BOLD}Usage Stats:${COLOR_RESET}"
            echo "  usage summary|top"
            echo ""
            echo -e "${COLOR_BOLD}General:${COLOR_RESET}"
            echo "  help [module]                   Show help (session, env, usage)"
            echo "  version                         Show version"
            echo "  --no-color                      Disable colored output"
            echo ""
            echo "Run 'ccm help <module>' for detailed help."
            ;;
        *)
            log_error "Unknown module '$module'"
            echo "Available modules: session, env, usage"
            exit 1
            ;;
    esac
}
```

- [ ] **Step 7: Update internal self-references**

Search and replace all occurrences of `ccswitch` in usage strings, error messages, and the interactive mode text. Replace `$0` references in user-facing strings with `ccm`.

- [ ] **Step 8: Update cmd_switch_to to accept alias**

The existing `cmd_switch_to` validates email format before resolving. Update it to also try alias resolution (via `resolve_account_identifier` which already supports aliases) without requiring email format validation:

```bash
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: ccm switch <account_number|email|alias>"
        exit 1
    fi

    local identifier="$1"
    local target_account

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    # Resolve identifier (handles number, email, and alias)
    target_account=$(resolve_account_identifier "$identifier")
    if [[ -z "$target_account" ]]; then
        log_error "No account found matching: $identifier"
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        log_error "Account-$target_account does not exist"
        exit 1
    fi

    perform_switch "$target_account"
}
```

- [ ] **Step 9: Test the restructured CLI**

```bash
chmod +x ccm.sh
bash ccm.sh version
bash ccm.sh help
bash ccm.sh help session
bash ccm.sh help env
bash ccm.sh help usage
bash ccm.sh list
bash ccm.sh --no-color help
```

All commands should produce output without errors. `list` should show existing managed accounts (if any from prior ccswitch usage).

- [ ] **Step 10: Commit**

```bash
git add ccm.sh
git commit -m "feat: rename ccswitch to ccm with hybrid CLI dispatch

Restructures CLI from --flag style to subcommand pattern.
Adds help system with per-module help, version command.
Fixes --no-color flag with deferred color initialization."
```

---

## Task 2: Session Management Module

**Files:**
- Modify: `ccm.sh` (add session subcommand router and session functions)

Adds `ccm session list`, `ccm session info`, `ccm session relocate`, and `ccm session clean`.

- [ ] **Step 1: Add path encoding/decoding utilities**

Add these functions after the existing utility functions section:

```bash
# Path encoding for Claude Code session directories
# Purpose: Converts an absolute path to Claude's session directory name
# Parameters: $1 - absolute path
# Returns: Encoded directory name (/ replaced with -)
encode_project_path() {
    echo "$1" | sed 's|/|-|g'
}

# Path decoding from Claude Code session directory name
# Purpose: Attempts to decode a session directory name back to the original path
# Parameters: $1 - encoded directory name
# Returns: Decoded path (best-effort, validated against filesystem)
decode_project_path() {
    local encoded="$1"
    # Simple decode: replace leading - with /, then all - with /
    local decoded
    decoded=$(echo "$encoded" | sed 's|-|/|g')

    # Validate against filesystem
    if [[ -d "$decoded" ]]; then
        echo "$decoded"
        return
    fi

    # Fallback: return the simple decode even if path doesn't exist
    echo "$decoded"
}

# Get human-readable file size
# Purpose: Converts bytes to human-readable format
# Parameters: $1 - size in bytes
# Returns: Formatted size string (e.g., "42 MB")
format_size() {
    local bytes="$1"
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(( bytes / 1073741824 )) GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(( bytes / 1048576 )) MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(( bytes / 1024 )) KB"
    else
        echo "${bytes} B"
    fi
}

# Get file modification time as epoch seconds (cross-platform)
# Purpose: Returns mtime in epoch seconds, works on macOS and Linux
# Parameters: $1 - file path
# Returns: Epoch seconds
get_mtime() {
    local file="$1"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos) stat -f %m "$file" 2>/dev/null || echo "0" ;;
        *)     stat -c %Y "$file" 2>/dev/null || echo "0" ;;
    esac
}

# Format epoch seconds as relative time (e.g., "2 hours ago")
# Purpose: Converts epoch timestamp to human-readable relative time
# Parameters: $1 - epoch seconds
# Returns: Relative time string
format_relative_time() {
    local timestamp="$1"
    local now
    now=$(date +%s)
    local diff=$(( now - timestamp ))

    if [[ $diff -lt 60 ]]; then
        echo "just now"
    elif [[ $diff -lt 3600 ]]; then
        local val=$(( diff / 60 ))
        echo "$val $( [[ $val -eq 1 ]] && echo "min" || echo "mins" ) ago"
    elif [[ $diff -lt 86400 ]]; then
        local val=$(( diff / 3600 ))
        echo "$val $( [[ $val -eq 1 ]] && echo "hour" || echo "hours" ) ago"
    elif [[ $diff -lt 604800 ]]; then
        local val=$(( diff / 86400 ))
        echo "$val $( [[ $val -eq 1 ]] && echo "day" || echo "days" ) ago"
    elif [[ $diff -lt 2592000 ]]; then
        local val=$(( diff / 604800 ))
        echo "$val $( [[ $val -eq 1 ]] && echo "week" || echo "weeks" ) ago"
    else
        local val=$(( diff / 2592000 ))
        echo "$val $( [[ $val -eq 1 ]] && echo "month" || echo "months" ) ago"
    fi
}

# Truncate path with ~ for $HOME
# Purpose: Replaces $HOME prefix with ~ for display
# Parameters: $1 - absolute path
# Returns: Truncated path
truncate_path() {
    echo "$1" | sed "s|^$HOME|~|"
}
```

- [ ] **Step 2: Add the session subcommand router**

```bash
# Session management subcommand router
# Purpose: Routes ccm session <action> to the appropriate function
# Parameters: $1 - action, $2+ - action arguments
# Returns: Delegates to session_* functions
cmd_session() {
    case "${1:-}" in
        list)       session_list ;;
        info)       shift; session_info "$@" ;;
        relocate)   shift; session_relocate "$@" ;;
        clean)      shift; session_clean "$@" ;;
        "")         show_help session ;;
        *)          log_error "Unknown session command '$1'"; show_help session; exit 1 ;;
    esac
}
```

- [ ] **Step 3: Implement `session_list`**

```bash
# List all project sessions
# Purpose: Displays all Claude Code project sessions with metadata
# Parameters: None
# Returns: Table of projects sorted by last active date
session_list() {
    local projects_dir="$CLAUDE_PROJECTS_DIR"

    if [[ ! -d "$projects_dir" ]]; then
        log_error "Claude Code projects directory not found: $projects_dir"
        exit 1
    fi

    echo -e "${COLOR_BOLD}Project Sessions${COLOR_RESET}"
    echo ""

    # Table header
    printf "  %-40s %8s %8s  %-14s  %s\n" "Project" "Sessions" "Size" "Last Active" "Status"
    printf "  %-40s %8s %8s  %-14s  %s\n" "$(printf '%0.s-' {1..40})" "--------" "--------" "--------------" "------"

    # Collect and sort data
    local entries=()
    while IFS= read -r dir; do
        [[ ! -d "$dir" ]] && continue
        local dirname
        dirname=$(basename "$dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")
        local display_path
        display_path=$(truncate_path "$decoded_path")

        # Count sessions
        local session_count=0
        session_count=$(find "$dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')

        # Total size
        local total_size
        total_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}')
        local size_display
        size_display=$(format_size "$total_size")

        # Last active (most recent .jsonl mtime)
        local last_active=0
        while IFS= read -r f; do
            local mt
            mt=$(get_mtime "$f")
            [[ $mt -gt $last_active ]] && last_active=$mt
        done < <(find "$dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null)

        local time_display
        if [[ $last_active -eq 0 ]]; then
            time_display="never"
        else
            time_display=$(format_relative_time "$last_active")
        fi

        # Status
        local status
        if [[ -d "$decoded_path" ]]; then
            status="${COLOR_GREEN}active${COLOR_RESET}"
        else
            status="${COLOR_RED}orphaned${COLOR_RESET}"
        fi

        # Store for sorting (prefix with timestamp for sort)
        entries+=("${last_active}|${display_path}|${session_count}|${size_display}|${time_display}|${status}")
    done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    # Sort by timestamp descending and display
    local sorted
    sorted=$(printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -rn)

    while IFS='|' read -r _ path sessions size last_active status; do
        [[ -z "$path" ]] && continue
        # Truncate path if too long
        if [[ ${#path} -gt 40 ]]; then
            path="...${path: -37}"
        fi
        printf "  %-40s %8s %8s  %-14s  " "$path" "$sessions" "$size" "$last_active"
        echo -e "$status"
    done <<< "$sorted"

    echo ""
    log_info "Total: ${#entries[@]} projects"
}
```

- [ ] **Step 4: Implement `session_info`**

```bash
# Show session details for a specific project
# Purpose: Displays detailed session information for a given project path
# Parameters: $1 - project path (absolute or ~/relative)
# Returns: Detailed session info
session_info() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: ccm session info <project-path>"
        exit 1
    fi

    local project_path="$1"
    # Resolve ~ and relative paths
    project_path="${project_path/#\~/$HOME}"
    # Try to resolve to absolute path; if dir exists use cd+pwd, otherwise
    # use realpath-like fallback to ensure we have an absolute path
    if [[ -d "$project_path" ]]; then
        project_path="$(cd "$project_path" && pwd)"
    elif [[ "$project_path" != /* ]]; then
        project_path="$(pwd)/$project_path"
    fi

    local encoded
    encoded=$(encode_project_path "$project_path")
    local session_dir="$CLAUDE_PROJECTS_DIR/$encoded"

    if [[ ! -d "$session_dir" ]]; then
        log_error "No session data found for: $project_path"
        exit 1
    fi

    local display_path
    display_path=$(truncate_path "$project_path")

    echo -e "${COLOR_BOLD}Session Info: ${display_path}${COLOR_RESET}"
    echo ""

    # Session count
    local session_count
    session_count=$(find "$session_dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')

    # Total size
    local total_size
    total_size=$(du -sk "$session_dir" 2>/dev/null | awk '{print $1 * 1024}')

    # Memory files
    local memory_count=0
    if [[ -d "$session_dir/memory" ]]; then
        memory_count=$(find "$session_dir/memory" -type f 2>/dev/null | wc -l | tr -d ' ')
    fi

    # Last active
    local last_active=0
    while IFS= read -r f; do
        local mt
        mt=$(get_mtime "$f")
        [[ $mt -gt $last_active ]] && last_active=$mt
    done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null)

    echo "  Sessions:     $session_count"
    echo "  Memory files: $memory_count"
    echo "  Total size:   $(format_size "$total_size")"
    if [[ $last_active -gt 0 ]]; then
        echo "  Last active:  $(format_relative_time "$last_active")"
    else
        echo "  Last active:  never"
    fi

    # Project status
    if [[ -d "$project_path" ]]; then
        echo -e "  Status:       ${COLOR_GREEN}active${COLOR_RESET} (project exists on disk)"
    else
        echo -e "  Status:       ${COLOR_RED}orphaned${COLOR_RESET} (project not found on disk)"
    fi

    # List individual sessions
    echo ""
    echo -e "${COLOR_BOLD}Session Files:${COLOR_RESET}"
    while IFS= read -r session_file; do
        local fname
        fname=$(basename "$session_file")
        local fsize
        fsize=$(du -sk "$session_file" 2>/dev/null | awk '{print $1 * 1024}')
        local fmtime
        fmtime=$(get_mtime "$session_file")
        printf "  %-45s %8s  %s\n" "$fname" "$(format_size "$fsize")" "$(format_relative_time "$fmtime")"
    done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | sort)
}
```

- [ ] **Step 5: Move relocate into session module**

Rename `cmd_relocate` to `session_relocate`. Update the merge behavior to use `cp -n` (no-clobber):

```bash
# In the existing cmd_relocate function, rename to session_relocate
# and change the merge cp line from:
#   cp -a "$old_session_dir"/. "$new_session_dir"/ 2>/dev/null
# to:
#   cp -an "$old_session_dir"/. "$new_session_dir"/ 2>/dev/null
# (-n = no-clobber, preserves existing files at destination)
```

Also update the usage message inside the function from `$0 --relocate` to `ccm session relocate`.

- [ ] **Step 6: Implement `session_clean`**

```bash
# Remove orphaned sessions
# Purpose: Finds and optionally removes sessions for projects that no longer exist
# Parameters: [--dry-run] - only show what would be removed
# Returns: List of orphaned sessions, optionally removes them
session_clean() {
    local dry_run=0
    if [[ "${1:-}" == "--dry-run" ]]; then
        dry_run=1
    fi

    local projects_dir="$CLAUDE_PROJECTS_DIR"

    if [[ ! -d "$projects_dir" ]]; then
        log_error "Claude Code projects directory not found: $projects_dir"
        exit 1
    fi

    show_progress "Scanning for orphaned sessions"

    local orphans=()
    local total_size=0

    while IFS= read -r dir; do
        [[ ! -d "$dir" ]] && continue
        local dirname
        dirname=$(basename "$dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")

        if [[ ! -d "$decoded_path" ]]; then
            local dir_size
            dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}')
            total_size=$(( total_size + dir_size ))
            orphans+=("${dir}|${decoded_path}|${dir_size}")
        fi
    done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    complete_progress

    if [[ ${#orphans[@]} -eq 0 ]]; then
        log_success "No orphaned sessions found."
        return 0
    fi

    echo ""
    echo -e "${COLOR_BOLD}Orphaned Sessions:${COLOR_RESET}"
    echo ""

    for entry in "${orphans[@]}"; do
        IFS='|' read -r dir path size <<< "$entry"
        local display_path
        display_path=$(truncate_path "$path")
        printf "  %-50s %8s\n" "$display_path" "$(format_size "$size")"
    done

    echo ""
    log_info "Total: ${#orphans[@]} orphaned sessions, $(format_size "$total_size")"
    echo ""

    if [[ $dry_run -eq 1 ]]; then
        log_info "Dry run — no files removed."
        return 0
    fi

    log_warning "Projects on unmounted drives may appear as orphaned."
    echo -n "Remove ${#orphans[@]} orphaned sessions? (y/N): "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cleanup cancelled."
        return 0
    fi

    show_progress "Removing orphaned sessions"
    for entry in "${orphans[@]}"; do
        IFS='|' read -r dir _ _ <<< "$entry"
        rm -rf "$dir"
    done
    complete_progress

    log_success "Removed ${#orphans[@]} orphaned sessions, freed $(format_size "$total_size")"
}
```

- [ ] **Step 7: Test session module**

```bash
bash ccm.sh session list
bash ccm.sh session info .
bash ccm.sh session clean --dry-run
bash ccm.sh help session

# Test relocate (create temp dirs to test)
mkdir -p /tmp/ccm-test-old
bash ccm.sh session relocate /tmp/ccm-test-old /tmp/ccm-test-new 2>&1 || true  # expected: no session data found
rmdir /tmp/ccm-test-old 2>/dev/null; rmdir /tmp/ccm-test-new 2>/dev/null
```

- [ ] **Step 8: Commit**

```bash
git add ccm.sh
git commit -m "feat: add session management module

Adds ccm session list, info, relocate, clean commands.
Includes cross-platform utilities for mtime, size formatting,
path encoding/decoding, and relative time display."
```

---

## Task 3: Environment Snapshots Module

**Files:**
- Modify: `ccm.sh` (add env subcommand router and env functions)

Adds `ccm env snapshot`, `ccm env restore`, `ccm env list`, `ccm env delete`, and `ccm env audit`.

- [ ] **Step 1: Add snapshot name validation utility**

```bash
# Validate snapshot name
# Purpose: Ensures snapshot name contains only safe characters
# Parameters: $1 - snapshot name
# Returns: 0 if valid, 1 if invalid
validate_snapshot_name() {
    local name="$1"
    if [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        return 0
    else
        return 1
    fi
}
```

- [ ] **Step 2: Add the env subcommand router**

```bash
# Environment management subcommand router
# Purpose: Routes ccm env <action> to the appropriate function
# Parameters: $1 - action, $2+ - action arguments
# Returns: Delegates to env_* functions
cmd_env() {
    case "${1:-}" in
        snapshot)   shift; env_snapshot "$@" ;;
        restore)    shift; env_restore "$@" ;;
        list)       env_list ;;
        delete)     shift; env_delete "$@" ;;
        audit)      env_audit ;;
        "")         show_help env ;;
        *)          log_error "Unknown env command '$1'"; show_help env; exit 1 ;;
    esac
}
```

- [ ] **Step 3: Implement `env_snapshot`**

```bash
# Capture current environment snapshot
# Purpose: Saves current Claude Code configuration to a named snapshot
# Parameters: [$1] - snapshot name (auto-generated if omitted)
# Returns: Exit code 0 on success
env_snapshot() {
    local name="${1:-snapshot-$(date +%Y-%m-%d-%H%M%S)}"

    if ! validate_snapshot_name "$name"; then
        log_error "Invalid snapshot name: '$name'"
        log_info "Use only letters, numbers, hyphens, underscores, and dots."
        exit 1
    fi

    local snapshot_dir="$BACKUP_DIR/snapshots/$name"

    if [[ -d "$snapshot_dir" ]]; then
        log_error "Snapshot '$name' already exists. Delete it first or choose a different name."
        exit 1
    fi

    mkdir -p "$snapshot_dir"
    chmod 700 "$snapshot_dir"

    show_progress "Capturing environment snapshot"

    local files_captured=0
    local manifest_files="[]"

    # Capture settings.json
    if [[ -f "$HOME/.claude/settings.json" ]]; then
        cp "$HOME/.claude/settings.json" "$snapshot_dir/settings.json"
        manifest_files=$(echo "$manifest_files" | jq --arg src "~/.claude/settings.json" --arg stored "settings.json" '. += [{"source": $src, "stored": $stored}]')
        ((files_captured++))
    fi

    # Capture .claude.json (stripped of sensitive fields)
    local config_path
    config_path=$(get_claude_config_path)
    if [[ -f "$config_path" ]]; then
        # Keep only oauthAccount structure, strip tokens
        jq '{oauthAccount: {emailAddress: .oauthAccount.emailAddress, accountUuid: .oauthAccount.accountUuid, organizationName: .oauthAccount.organizationName}}' "$config_path" > "$snapshot_dir/claude.json" 2>/dev/null || true
        manifest_files=$(echo "$manifest_files" | jq --arg src "~/.claude/.claude.json" --arg stored "claude.json" '. += [{"source": $src, "stored": $stored}]')
        ((files_captured++))
    fi

    # Capture CLAUDE.md
    if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
        cp "$HOME/.claude/CLAUDE.md" "$snapshot_dir/CLAUDE.md"
        manifest_files=$(echo "$manifest_files" | jq --arg src "~/.claude/CLAUDE.md" --arg stored "CLAUDE.md" '. += [{"source": $src, "stored": $stored}]')
        ((files_captured++))
    fi

    # Capture global MCP config
    if [[ -f "$HOME/.claude/.mcp.json" ]]; then
        cp "$HOME/.claude/.mcp.json" "$snapshot_dir/mcp.json"
        manifest_files=$(echo "$manifest_files" | jq --arg src "~/.claude/.mcp.json" --arg stored "mcp.json" '. += [{"source": $src, "stored": $stored}]')
        ((files_captured++))
    fi

    # Write manifest
    local manifest
    manifest=$(jq -n \
        --arg name "$name" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson files "$manifest_files" \
        '{name: $name, created: $created, files: $files}')
    echo "$manifest" > "$snapshot_dir/manifest.json"

    complete_progress

    log_success "Snapshot '$name' created ($files_captured files captured)"
}
```

- [ ] **Step 4: Implement `env_restore`**

```bash
# Restore environment from snapshot
# Purpose: Restores Claude Code configuration from a named snapshot
# Parameters: $1 - snapshot name, [--force] - skip running process check
# Returns: Exit code 0 on success
env_restore() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: ccm env restore <name> [--force]"
        exit 1
    fi

    local name="$1"
    local force=0
    [[ "${2:-}" == "--force" ]] && force=1

    local snapshot_dir="$BACKUP_DIR/snapshots/$name"

    if [[ ! -d "$snapshot_dir" ]] || [[ ! -f "$snapshot_dir/manifest.json" ]]; then
        log_error "Snapshot '$name' not found."
        exit 1
    fi

    # Check if Claude Code is running
    if [[ $force -eq 0 ]] && is_claude_running; then
        log_error "Claude Code is running. Please close it first, or use --force to restore anyway."
        exit 1
    fi

    # Show what will be restored
    echo -e "${COLOR_BOLD}Restoring snapshot: $name${COLOR_RESET}"
    echo ""

    local created
    created=$(jq -r '.created' "$snapshot_dir/manifest.json")
    log_info "Created: $created"
    echo ""

    echo "Files to restore:"
    jq -r '.files[] | "  \(.source) <- \(.stored)"' "$snapshot_dir/manifest.json"
    echo ""

    echo -n "Restore these files? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Restore cancelled."
        exit 0
    fi

    show_progress "Restoring environment"

    # Restore each file
    while IFS= read -r entry; do
        local source stored
        source=$(echo "$entry" | jq -r '.source')
        stored=$(echo "$entry" | jq -r '.stored')

        # Resolve ~ to $HOME
        local target_path="${source/#\~/$HOME}"
        local source_file="$snapshot_dir/$stored"

        if [[ -f "$source_file" ]]; then
            # Ensure target directory exists
            mkdir -p "$(dirname "$target_path")"

            # Special handling for claude.json: merge oauthAccount into
            # existing file instead of overwriting (to preserve tokens/creds)
            if [[ "$stored" == "claude.json" ]] && [[ -f "$target_path" ]]; then
                local oauth_section
                oauth_section=$(jq '.oauthAccount' "$source_file" 2>/dev/null)
                if [[ -n "$oauth_section" && "$oauth_section" != "null" ]]; then
                    local merged
                    merged=$(jq --argjson oauth "$oauth_section" '.oauthAccount = (.oauthAccount * $oauth)' "$target_path" 2>/dev/null)
                    if [[ -n "$merged" ]]; then
                        echo "$merged" > "$target_path"
                    fi
                fi
            else
                cp "$source_file" "$target_path"
            fi
        fi
    done < <(jq -c '.files[]' "$snapshot_dir/manifest.json")

    complete_progress
    log_success "Environment restored from snapshot '$name'"
    log_info "Restart Claude Code to apply changes."
}
```

- [ ] **Step 5: Implement `env_list` and `env_delete`**

```bash
# List all environment snapshots
# Purpose: Shows all saved snapshots with metadata
# Parameters: None
# Returns: Table of snapshots
env_list() {
    local snapshots_dir="$BACKUP_DIR/snapshots"

    if [[ ! -d "$snapshots_dir" ]] || [[ -z "$(ls -A "$snapshots_dir" 2>/dev/null)" ]]; then
        log_info "No snapshots found."
        return 0
    fi

    echo -e "${COLOR_BOLD}Environment Snapshots${COLOR_RESET}"
    echo ""
    printf "  %-30s  %-22s  %5s  %s\n" "Name" "Created" "Files" "Size"
    printf "  %-30s  %-22s  %5s  %s\n" "$(printf '%0.s-' {1..30})" "$(printf '%0.s-' {1..22})" "-----" "------"

    while IFS= read -r snap_dir; do
        [[ ! -d "$snap_dir" ]] && continue
        local manifest="$snap_dir/manifest.json"
        [[ ! -f "$manifest" ]] && continue

        local snap_name snap_created file_count snap_size
        snap_name=$(jq -r '.name' "$manifest")
        snap_created=$(jq -r '.created' "$manifest")
        file_count=$(jq -r '.files | length' "$manifest")
        snap_size=$(du -sk "$snap_dir" 2>/dev/null | awk '{print $1 * 1024}')

        printf "  %-30s  %-22s  %5s  %s\n" "$snap_name" "$snap_created" "$file_count" "$(format_size "$snap_size")"
    done < <(find "$snapshots_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
}

# Delete an environment snapshot
# Purpose: Removes a named snapshot after confirmation
# Parameters: $1 - snapshot name
# Returns: Exit code 0 on success
env_delete() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: ccm env delete <name>"
        exit 1
    fi

    local name="$1"
    local snapshot_dir="$BACKUP_DIR/snapshots/$name"

    if [[ ! -d "$snapshot_dir" ]]; then
        log_error "Snapshot '$name' not found."
        exit 1
    fi

    echo -n "Delete snapshot '$name'? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Delete cancelled."
        return 0
    fi

    rm -rf "$snapshot_dir"
    log_success "Snapshot '$name' deleted."
}
```

- [ ] **Step 6: Implement `env_audit`**

```bash
# Audit MCP configuration for token efficiency
# Purpose: Checks MCP servers against known CLI alternatives
# Parameters: None
# Returns: Audit report with recommendations
env_audit() {
    # Knowledge base: MCP name -> "cli_command|description|estimated_savings"
    declare -A MCP_CLI_ALTERNATIVES=(
        ["playwright"]="npx playwright test, npx playwright codegen|Browser automation via CLI|~2000"
        ["postgres"]="psql -c 'query'|Database queries via Bash tool|~1500"
        ["filesystem"]="Built-in Read/Write/Glob/Grep tools|Already available in Claude Code|~1800"
        ["git"]="git CLI via Bash tool|Already available in Claude Code|~1200"
        ["sqlite"]="sqlite3 via Bash tool|Database queries via CLI|~1000"
        ["docker"]="docker CLI via Bash tool|Container management via CLI|~1500"
        ["redis"]="redis-cli via Bash tool|Cache operations via CLI|~800"
        ["mysql"]="mysql -e 'query'|Database queries via Bash tool|~1200"
    )

    local mcp_config="$HOME/.claude/.mcp.json"

    if [[ ! -f "$mcp_config" ]]; then
        log_info "No global MCP configuration found at $mcp_config"
        return 0
    fi

    local server_names
    server_names=$(jq -r '.mcpServers // {} | keys[]' "$mcp_config" 2>/dev/null)

    if [[ -z "$server_names" ]]; then
        log_info "No MCP servers configured."
        return 0
    fi

    echo -e "${COLOR_BOLD}Token Efficiency Audit${COLOR_RESET}"
    echo "━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local replaceable=0
    local total_savings=0

    while IFS= read -r server; do
        [[ -z "$server" ]] && continue

        # Check if server name matches any known alternative (partial match)
        local matched=0
        for key in "${!MCP_CLI_ALTERNATIVES[@]}"; do
            if [[ "$server" == *"$key"* ]]; then
                IFS='|' read -r cli_cmd description savings <<< "${MCP_CLI_ALTERNATIVES[$key]}"
                echo -e "${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} ${COLOR_BOLD}${server}${COLOR_RESET} (MCP) ${SYM_STEP} CLI alternative available"
                echo "  CLI: $cli_cmd"
                echo "  Why: $description"
                echo "  Savings: ${savings} tokens/request from tool schema removal"
                echo ""
                ((replaceable++))
                # Extract numeric savings
                local num_savings
                num_savings=$(echo "$savings" | grep -oE '[0-9]+')
                total_savings=$(( total_savings + num_savings ))
                matched=1
                break
            fi
        done

        if [[ $matched -eq 0 ]]; then
            echo -e "${COLOR_GREEN}${SYM_OK}${COLOR_RESET} ${COLOR_BOLD}${server}${COLOR_RESET} (MCP) ${SYM_STEP} Keep (no CLI equivalent known)"
            echo ""
        fi
    done <<< "$server_names"

    echo "━━━━━━━━━━━━━━━━━━━━━"
    if [[ $replaceable -gt 0 ]]; then
        log_info "Summary: $replaceable MCP server(s) replaceable, estimated ~${total_savings} tokens saved per request"
    else
        log_success "All configured MCP servers appear to be necessary."
    fi
}
```

- [ ] **Step 7: Test env module**

```bash
bash ccm.sh env snapshot test-snap
bash ccm.sh env list
bash ccm.sh env audit

# Test restore happy path: modify settings, restore, verify
cp ~/.claude/settings.json /tmp/settings-backup.json
bash ccm.sh env restore test-snap  # answer y when prompted
diff ~/.claude/settings.json /tmp/settings-backup.json  # should match snapshot
cp /tmp/settings-backup.json ~/.claude/settings.json  # restore original

bash ccm.sh env delete test-snap
bash ccm.sh help env
```

- [ ] **Step 8: Commit**

```bash
git add ccm.sh
git commit -m "feat: add environment snapshots and audit module

Adds ccm env snapshot, restore, list, delete, audit commands.
Snapshot captures settings.json, .claude.json (stripped), CLAUDE.md, .mcp.json.
Audit checks MCP servers against known CLI alternatives for token savings."
```

---

## Task 4: Usage Stats Module

**Files:**
- Modify: `ccm.sh` (add usage subcommand router and usage functions)

Adds `ccm usage summary` and `ccm usage top`.

- [ ] **Step 1: Add the usage subcommand router**

```bash
# Usage stats subcommand router
# Purpose: Routes ccm usage <action> to the appropriate function
# Parameters: $1 - action, $2+ - action arguments
# Returns: Delegates to usage_* functions
cmd_usage() {
    case "${1:-}" in
        summary)    usage_summary ;;
        top)        shift; usage_top "$@" ;;
        "")         show_help usage ;;
        *)          log_error "Unknown usage command '$1'"; show_help usage; exit 1 ;;
    esac
}
```

- [ ] **Step 2: Implement `usage_summary`**

```bash
# Show Claude Code usage summary
# Purpose: Displays overview of Claude Code footprint on this machine
# Parameters: None
# Returns: Summary statistics
usage_summary() {
    local projects_dir="$CLAUDE_PROJECTS_DIR"

    echo -e "${COLOR_BOLD}Claude Code Usage Summary${COLOR_RESET}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Count projects
    local total_projects=0
    local active_projects=0
    local orphaned_projects=0

    if [[ -d "$projects_dir" ]]; then
        while IFS= read -r dir; do
            [[ ! -d "$dir" ]] && continue
            ((total_projects++))
            local dirname
            dirname=$(basename "$dir")
            local decoded_path
            decoded_path=$(decode_project_path "$dirname")
            if [[ -d "$decoded_path" ]]; then
                ((active_projects++))
            else
                ((orphaned_projects++))
            fi
        done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    # Count sessions
    local total_sessions=0
    local recent_sessions=0
    local week_ago
    week_ago=$(( $(date +%s) - 604800 ))

    if [[ -d "$projects_dir" ]]; then
        while IFS= read -r -d '' f; do
            ((total_sessions++))
            local mt
            mt=$(get_mtime "$f")
            if [[ $mt -ge $week_ago ]]; then
                ((recent_sessions++))
            fi
        done < <(find "$projects_dir" -name "*.jsonl" -type f -print0 2>/dev/null)
    fi

    # Count memory files
    local total_memory=0
    if [[ -d "$projects_dir" ]]; then
        total_memory=$(find "$projects_dir" -path "*/memory/*" -type f 2>/dev/null | wc -l | tr -d ' ')
    fi

    # Total disk usage
    local total_size=0
    if [[ -d "$projects_dir" ]]; then
        total_size=$(du -sk "$projects_dir" 2>/dev/null | awk '{print $1 * 1024}')
    fi

    # Account count
    local account_count=0
    if [[ -f "$SEQUENCE_FILE" ]]; then
        account_count=$(jq -r '.accounts | length' "$SEQUENCE_FILE" 2>/dev/null || echo "0")
    fi

    printf "  %-15s %s\n" "Projects:" "$total_projects ($active_projects active, $orphaned_projects orphaned)"
    printf "  %-15s %s\n" "Sessions:" "$total_sessions total ($recent_sessions this week)"
    printf "  %-15s %s\n" "Memory files:" "$total_memory"
    printf "  %-15s %s\n" "Disk usage:" "$(format_size "$total_size")"
    printf "  %-15s %s\n" "Accounts:" "$account_count managed"
}
```

- [ ] **Step 3: Implement `usage_top`**

```bash
# Show top projects by disk usage
# Purpose: Ranks projects by total disk usage
# Parameters: [--count N] - number of projects to show (default 10)
# Returns: Ranked table of projects
usage_top() {
    local count=10

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --count)
                shift
                count="${1:-10}"
                if ! [[ "$count" =~ ^[0-9]+$ ]]; then
                    log_error "Invalid count: $count"
                    exit 1
                fi
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    local projects_dir="$CLAUDE_PROJECTS_DIR"

    if [[ ! -d "$projects_dir" ]]; then
        log_error "Claude Code projects directory not found."
        exit 1
    fi

    echo -e "${COLOR_BOLD}Top Projects by Disk Usage${COLOR_RESET}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    printf "  %3s  %-40s %8s %8s  %s\n" "#" "Project" "Sessions" "Size" "Last Active"
    printf "  %3s  %-40s %8s %8s  %s\n" "---" "$(printf '%0.s-' {1..40})" "--------" "--------" "-----------"

    # Collect data
    local entries=()
    while IFS= read -r dir; do
        [[ ! -d "$dir" ]] && continue
        local dirname
        dirname=$(basename "$dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")
        local display_path
        display_path=$(truncate_path "$decoded_path")

        local session_count
        session_count=$(find "$dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')

        local dir_size
        dir_size=$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}')

        local last_active=0
        while IFS= read -r f; do
            local mt
            mt=$(get_mtime "$f")
            [[ $mt -gt $last_active ]] && last_active=$mt
        done < <(find "$dir" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null)

        entries+=("${dir_size}|${display_path}|${session_count}|${last_active}")
    done < <(find "$projects_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    # Sort by size descending and show top N
    local rank=1
    while IFS='|' read -r size path sessions last_active; do
        [[ -z "$size" ]] && continue
        [[ $rank -gt $count ]] && break

        if [[ ${#path} -gt 40 ]]; then
            path="...${path: -37}"
        fi

        local time_display
        if [[ $last_active -eq 0 ]]; then
            time_display="never"
        else
            time_display=$(format_relative_time "$last_active")
        fi

        printf "  %3d  %-40s %8s %8s  %s\n" "$rank" "$path" "$sessions" "$(format_size "$size")" "$time_display"
        ((rank++))
    done <<< "$(printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -rn)"
}
```

- [ ] **Step 4: Test usage module**

```bash
bash ccm.sh usage summary
bash ccm.sh usage top
bash ccm.sh usage top --count 5
bash ccm.sh help usage
```

- [ ] **Step 5: Commit**

```bash
git add ccm.sh
git commit -m "feat: add usage stats module

Adds ccm usage summary and ccm usage top commands.
Shows project counts, session stats, disk usage, and
ranks projects by size. All stats from filesystem metadata."
```

---

## Task 5: Update Interactive Mode and Final Polish

**Files:**
- Modify: `ccm.sh` (update interactive mode menu, add new options)
- Modify: `README.md` (rewrite for ccm)

- [ ] **Step 1: Update interactive mode menu**

Add new session/env/usage options to the interactive menu actions section:

```bash
echo -e "${COLOR_BOLD}Actions:${COLOR_RESET}"
echo "  s) Switch to next account"
echo "  a) Add current account"
echo "  v) Verify all accounts"
echo "  h) View switch history"
echo "  u) Undo last switch"
echo ""
echo -e "${COLOR_BOLD}Tools:${COLOR_RESET}"
echo "  sl) Session list"
echo "  sc) Session clean (dry run)"
echo "  us) Usage summary"
echo "  ut) Usage top"
echo "  es) Env snapshot"
echo "  el) Env snapshots list"
echo "  ea) Env audit"
echo ""
echo "  q) Quit"
```

Add corresponding case handlers:

```bash
sl|SL)
    echo ""
    session_list
    echo ""
    read -p "Press Enter to continue..."
    ;;
sc|SC)
    echo ""
    session_clean --dry-run
    echo ""
    read -p "Press Enter to continue..."
    ;;
us|US)
    echo ""
    usage_summary
    echo ""
    read -p "Press Enter to continue..."
    ;;
ut|UT)
    echo ""
    usage_top
    echo ""
    read -p "Press Enter to continue..."
    ;;
es|ES)
    echo ""
    echo -n "Snapshot name (leave empty for auto): "
    read -r snap_name
    if [[ -n "$snap_name" ]]; then
        env_snapshot "$snap_name"
    else
        env_snapshot
    fi
    echo ""
    read -p "Press Enter to continue..."
    ;;
el|EL)
    echo ""
    env_list
    echo ""
    read -p "Press Enter to continue..."
    ;;
ea|EA)
    echo ""
    env_audit
    echo ""
    read -p "Press Enter to continue..."
    ;;
```

- [ ] **Step 2: Update interactive mode header**

Change the header from "Multi-Account Switcher for Claude Code" to "CCM — Claude Code Manager":

```bash
echo -e "${COLOR_BOLD}╔══════════════════════════════════════════════════╗${COLOR_RESET}"
echo -e "${COLOR_BOLD}║  CCM — Claude Code Manager                     ║${COLOR_RESET}"
echo -e "${COLOR_BOLD}╚══════════════════════════════════════════════════╝${COLOR_RESET}"
```

- [ ] **Step 3: Run full end-to-end test**

```bash
# Version and help
bash ccm.sh version
bash ccm.sh help
bash ccm.sh help session
bash ccm.sh help env
bash ccm.sh help usage

# Account management (existing)
bash ccm.sh list
bash ccm.sh status

# Session management
bash ccm.sh session list
bash ccm.sh session info .
bash ccm.sh session clean --dry-run

# Environment
bash ccm.sh env snapshot e2e-test
bash ccm.sh env list
bash ccm.sh env audit
bash ccm.sh env delete e2e-test

# Usage
bash ccm.sh usage summary
bash ccm.sh usage top

# No-color mode
bash ccm.sh --no-color usage summary
bash ccm.sh --no-color session list

# Error cases
bash ccm.sh bogus
bash ccm.sh session bogus
bash ccm.sh env restore nonexistent
```

- [ ] **Step 4: Commit**

```bash
git add ccm.sh
git commit -m "feat: update interactive mode with session, env, and usage tools

Adds quick-access shortcuts for session list, clean, usage summary,
env snapshot, and audit from the interactive menu."
```

- [ ] **Step 5: Update README.md**

Rewrite the README to reflect the new tool name, all four modules, the hybrid CLI pattern, and updated examples. Keep the same structure (features, installation, usage, troubleshooting) but update all content.

- [ ] **Step 6: Commit README**

```bash
git add README.md
git commit -m "docs: rewrite README for ccm rebrand and new features

Updates documentation to cover all four modules: account management,
session management, environment snapshots, and usage stats."
```

---

## Task 6: Website (last task — designed separately)

This task is intentionally left as a placeholder. The website design will go through its own brainstorming cycle after the CCM implementation is complete.

- [ ] **Step 1: Brainstorm and design the terminal-UI website**
- [ ] **Step 2: Implement the website**
- [ ] **Step 3: Commit**

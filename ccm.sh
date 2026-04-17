#!/usr/bin/env bash

# CCM — Claude Code Manager
# Multi-account switcher and management tool for Claude Code

set -euo pipefail

# Configuration
readonly CCM_VERSION="4.1.0"
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly SCHEMA_VERSION="3.1"
readonly MAX_HISTORY_ENTRIES=10
readonly CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# Feature flags
NO_COLOR=${NO_COLOR:-0}

# Color and symbol variables (not readonly — overridden by --no-color)
COLOR_RED='' COLOR_GREEN='' COLOR_YELLOW='' COLOR_BLUE='' COLOR_CYAN='' COLOR_BOLD='' COLOR_RESET=''
SYM_INFO='i' SYM_OK='[ok]' SYM_WARN='[!!]' SYM_ERR='[x]' SYM_STEP='->' SYM_PROGRESS='...'

# Deferred color initialization
# Purpose: Sets color escape codes and unicode symbols when terminal supports them
# Parameters: None
# Returns: None (sets global color/symbol variables)
# Usage: init_colors
init_colors() {
    if [[ "${NO_COLOR:-0}" -eq 0 ]] && [[ -t 1 ]]; then
        COLOR_RED='\033[0;31m' COLOR_GREEN='\033[0;32m' COLOR_YELLOW='\033[0;33m'
        COLOR_BLUE='\033[0;34m' COLOR_CYAN='\033[0;36m' COLOR_BOLD='\033[1m' COLOR_RESET='\033[0m'
        SYM_INFO='ℹ' SYM_OK='✓' SYM_WARN='⚠' SYM_ERR='✗' SYM_STEP='→' SYM_PROGRESS='⟳'
    fi
}

# Cache variables
declare -A CACHE
CACHE_VALID=0

# Logging and output functions
log_info()    { echo -e "${COLOR_BLUE}${SYM_INFO}${COLOR_RESET} $*"; }
log_success() { echo -e "${COLOR_GREEN}${SYM_OK}${COLOR_RESET} $*"; }
log_warning() { echo -e "${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} $*" >&2; }
log_error()   { echo -e "${COLOR_RED}${SYM_ERR}${COLOR_RESET} $*" >&2; }
log_step()    { echo -e "${COLOR_CYAN}${SYM_STEP}${COLOR_RESET} $*"; }

# Progress indicator
show_progress()    { echo -n -e "${COLOR_CYAN}${SYM_PROGRESS}${COLOR_RESET} ${1}..."; }
complete_progress() { echo -e " ${COLOR_GREEN}${SYM_OK}${COLOR_RESET}"; }

# Container detection
# Purpose: Detects if the script is running inside a container environment
# Parameters: None
# Returns: 0 if running in container, 1 otherwise
# Usage: if is_running_in_container; then ...; fi
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    
    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    
    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Platform detection
# Purpose: Identifies the operating system platform
# Parameters: None
# Returns: Prints "macos", "wsl", "linux", or "unknown"
# Usage: platform=$(detect_platform)
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) 
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
# Purpose: Locates the Claude Code configuration file with validation
# Parameters: None
# Returns: Prints the absolute path to .claude.json
# Usage: config_path=$(get_claude_config_path)
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    
    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    
    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Snapshot name validation function
# Purpose: Validates that a snapshot name contains only safe characters
# Parameters: $1 — snapshot name to validate
# Returns: 0 if valid, 1 if invalid
# Usage: if validate_snapshot_name "my-snap"; then ...; fi
validate_snapshot_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]
}

# Account parameter validation for safe file path construction
# Purpose: Validates account_num is numeric and email is safe for use in file paths
# Parameters: $1 — account number, $2 — email address
# Returns: 0 if valid, 1 if invalid (logs error on failure)
# Usage: validate_account_params "1" "user@example.com" || return 1
validate_account_params() {
    local account_num="$1"
    local email="$2"
    if [[ ! "$account_num" =~ ^[0-9]+$ ]]; then
        log_error "Invalid account number: contains non-numeric characters"
        return 1
    fi
    if [[ -n "$email" ]] && ! validate_email "$email"; then
        log_error "Invalid email format for account parameter"
        return 1
    fi
    return 0
}

# Account identifier resolution function
# Resolves account number, email, or alias to account number
resolve_account_identifier() {
    local identifier="$1"
    local -a matches=()
    # Bounds check to prevent DoS via extremely long input
    if [[ ${#identifier} -gt 255 ]]; then
        echo ""
        return 1
    fi
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Try to look up by email first
        mapfile -t matches < <(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ ${#matches[@]} -eq 1 ]] && [[ "${matches[0]}" =~ ^[0-9]+$ ]]; then
            echo "${matches[0]}"
            return 0
        elif [[ ${#matches[@]} -gt 1 ]]; then
            log_error "Multiple accounts found for email '$identifier'"
            echo ""
            return 1
        fi

        # Try to look up by alias
        mapfile -t matches < <(jq -r --arg alias "$identifier" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ ${#matches[@]} -eq 1 ]] && [[ "${matches[0]}" =~ ^[0-9]+$ ]]; then
            echo "${matches[0]}"
            return 0
        elif [[ ${#matches[@]} -gt 1 ]]; then
            log_error "Alias '$identifier' matches multiple accounts. Reassign aliases to make them unique."
            echo ""
            return 1
        fi

        echo ""
    fi
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    local old_umask
    old_umask=$(umask)
    umask 077
    temp_file=$(mktemp "${file}.XXXXXX")
    umask "$old_umask"

    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f -- "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi

    mv -- "$temp_file" "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    local old_umask
    old_umask=$(umask)
    umask 077
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    umask "$old_umask"
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi
    
    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."
    
    while is_claude_running; do
        sleep 1
    done
    
    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            local tmp old_umask
            old_umask=$(umask)
            umask 077
            tmp=$(mktemp "$HOME/.claude/.credentials.XXXXXX")
            umask "$old_umask"
            printf '%s' "$credentials" > "$tmp"
            mv -- "$tmp" "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    validate_account_params "$account_num" "$email" || return 1
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    validate_account_params "$account_num" "$email" || return 1
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            local tmp old_umask
            old_umask=$(umask)
            umask 077
            tmp=$(mktemp "${cred_file}.XXXXXX")
            umask "$old_umask"
            printf '%s' "$credentials" > "$tmp"
            mv -- "$tmp" "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    validate_account_params "$account_num" "$email" || return 1
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    validate_account_params "$account_num" "$email" || return 1
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    local tmp old_umask
    old_umask=$(umask)
    umask 077
    tmp=$(mktemp "${config_file}.XXXXXX")
    umask "$old_umask"
    echo "$config" > "$tmp"
    mv -- "$tmp" "$config_file"
}

# Cache management functions
# Purpose: Invalidates the in-memory cache of sequence data
# Parameters: None
# Returns: None (modifies global cache state)
# Usage: invalidate_cache
invalidate_cache() {
    CACHE_VALID=0
    CACHE=()
}

load_sequence_cache() {
    if [[ "$CACHE_VALID" -eq 1 ]]; then
        return 0
    fi

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    CACHE[sequence_json]=$(cat "$SEQUENCE_FILE")
    CACHE_VALID=1
}

get_cached_sequence() {
    load_sequence_cache
    echo "${CACHE[sequence_json]}"
}

# Initialize sequence.json if it doesn't exist
# Purpose: Creates the sequence.json file with default schema if not present
# Parameters: None
# Returns: None (creates file with side effects)
# Usage: init_sequence_file
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "schemaVersion": "'"$SCHEMA_VERSION"'",
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {},
  "history": [],
  "bindings": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
        invalidate_cache
    fi
}

# Migrate old schema to new schema
# Purpose: Automatically migrates sequence.json from v1.0 to v2.0 schema
# Parameters: None
# Returns: None (modifies sequence.json with backup)
# Usage: migrate_sequence_file
migrate_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 0
    fi

    local current_version
    current_version=$(jq -r '.schemaVersion // "1.0"' "$SEQUENCE_FILE")

    if [[ "$current_version" == "$SCHEMA_VERSION" ]]; then
        return 0
    fi

    show_progress "Migrating data to schema version $SCHEMA_VERSION"

    # Backup current file
    cp "$SEQUENCE_FILE" "$SEQUENCE_FILE.backup-$(date +%s)"

    # Migrate from 1.0 to 2.0
    if [[ "$current_version" == "1.0" ]]; then
        local migrated
        migrated=$(jq '
            .schemaVersion = "2.0" |
            .history = [] |
            .accounts |= with_entries(
                .value |= . + {
                    alias: null,
                    lastUsed: null,
                    usageCount: 0,
                    healthStatus: "unknown"
                }
            )
        ' "$SEQUENCE_FILE")

        write_json "$SEQUENCE_FILE" "$migrated"
        invalidate_cache
        current_version="2.0"
    fi

    # Migrate from 2.0 to 3.0
    if [[ "$current_version" == "2.0" ]]; then
        local migrated
        migrated=$(jq '
            .schemaVersion = "3.0"
        ' "$SEQUENCE_FILE")

        write_json "$SEQUENCE_FILE" "$migrated"
        invalidate_cache
        current_version="3.0"
    fi

    # Migrate from 3.0 to 3.1 (add bindings)
    if [[ "$current_version" == "3.0" ]]; then
        local migrated
        migrated=$(jq --arg version "$SCHEMA_VERSION" '
            .schemaVersion = $version |
            .bindings = (.bindings // {})
        ' "$SEQUENCE_FILE")

        write_json "$SEQUENCE_FILE" "$migrated"
        invalidate_cache
    fi

    complete_progress
    log_success "Data migrated successfully (backup saved)"
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi
    
    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# ─── Session Utility Functions ────────────────────────────────────────────────

# Purpose: Converts an absolute path to Claude's session directory name (/ becomes -)
# Parameters: $1 — absolute path
# Returns: Prints encoded directory name
# Usage: encoded=$(encode_project_path "/Users/me/project")
encode_project_path() {
    echo "$1" | sed 's|/|-|g'
}

# Purpose: Converts an encoded session directory name back to an absolute path
# Parameters: $1 — encoded directory name
# Returns: Prints decoded path, validates against filesystem
# Usage: decoded=$(decode_project_path "-Users-me-my-project")
# Note: Encoding is lossy (both / and - become -). This function uses a
#   filesystem-walking heuristic to reconstruct the original path by checking
#   which segments exist as actual directories.
decode_project_path() {
    local encoded="$1"

    # Split encoded name into segments (strip leading -, split on -)
    local stripped="${encoded#-}"
    IFS='-' read -ra segments <<< "$stripped"

    # Walk the filesystem trying to reconstruct the real path
    # At each level, greedily try to match the longest directory name
    # by joining segments with hyphens
    local current="/"
    local i=0
    local len=${#segments[@]}

    while [[ $i -lt $len ]]; do
        local best_match=""
        local best_j=$i

        # Try combining segments[i..j] with hyphens, longest first
        local j=$(( len - 1 ))
        while [[ $j -ge $i ]]; do
            local candidate=""
            local k=$i
            while [[ $k -le $j ]]; do
                if [[ -z "$candidate" ]]; then
                    candidate="${segments[$k]}"
                else
                    candidate="${candidate}-${segments[$k]}"
                fi
                ((k++))
            done

            if [[ -d "${current%/}/$candidate" ]] || [[ $j -eq $i ]]; then
                best_match="$candidate"
                best_j=$j
                if [[ -d "${current%/}/$candidate" ]]; then
                    break
                fi
            fi
            ((j--))
        done

        current="${current%/}/$best_match"
        i=$(( best_j + 1 ))
    done

    echo "$current"
}

# Purpose: Converts bytes to human-readable size (KB/MB/GB)
# Parameters: $1 — size in bytes
# Returns: Prints formatted size string
# Usage: readable=$(format_size 1048576)  # "1.0 MB"
format_size() {
    local bytes="${1:-0}"
    if [[ "$bytes" -ge 1073741824 ]]; then
        awk -v b="$bytes" 'BEGIN { printf "%.1f GB", b / 1073741824 }'
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }'
    elif [[ "$bytes" -ge 1024 ]]; then
        awk -v b="$bytes" 'BEGIN { printf "%.1f KB", b / 1024 }'
    else
        echo "${bytes} B"
    fi
}

# Purpose: Gets file modification time as epoch seconds (cross-platform)
# Parameters: $1 — file path
# Returns: Prints epoch seconds
# Usage: mtime=$(get_mtime "/path/to/file")
get_mtime() {
    local filepath="$1"
    if [[ ! -e "$filepath" ]]; then
        echo "0"
        return
    fi
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)  stat -f %m "$filepath" 2>/dev/null || echo "0" ;;
        *)      stat -c %Y "$filepath" 2>/dev/null || echo "0" ;;
    esac
}

# Purpose: Converts epoch seconds to human-readable relative time string
# Parameters: $1 — epoch seconds (timestamp)
# Purpose: Formats an ISO 8601 timestamp to a local display format (cross-platform)
# Parameters: $1 — ISO timestamp (e.g. "2026-03-24T12:00:00Z")
# Returns: Formatted string (e.g. "2026-03-24 12:00") or raw input on failure
format_iso_date() {
    local iso="$1"
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos) date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$iso" ;;
        *)     date -d "$iso" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$iso" ;;
    esac
}

# Returns: Prints relative time string (e.g. "2 hours ago")
# Usage: relative=$(format_relative_time "$epoch_seconds")
format_relative_time() {
    local timestamp="$1"
    if [[ "$timestamp" -eq 0 ]]; then
        echo "unknown"
        return
    fi
    local now diff
    now=$(date +%s)
    diff=$((now - timestamp))

    if [[ "$diff" -lt 0 ]]; then
        echo "just now"
    elif [[ "$diff" -lt 60 ]]; then
        echo "just now"
    elif [[ "$diff" -lt 3600 ]]; then
        local mins=$((diff / 60))
        if [[ "$mins" -eq 1 ]]; then echo "1 minute ago"; else echo "$mins minutes ago"; fi
    elif [[ "$diff" -lt 86400 ]]; then
        local hours=$((diff / 3600))
        if [[ "$hours" -eq 1 ]]; then echo "1 hour ago"; else echo "$hours hours ago"; fi
    elif [[ "$diff" -lt 2592000 ]]; then
        local days=$((diff / 86400))
        if [[ "$days" -eq 1 ]]; then echo "1 day ago"; else echo "$days days ago"; fi
    elif [[ "$diff" -lt 31536000 ]]; then
        local months=$((diff / 2592000))
        if [[ "$months" -eq 1 ]]; then echo "1 month ago"; else echo "$months months ago"; fi
    else
        local years=$((diff / 31536000))
        if [[ "$years" -eq 1 ]]; then echo "1 year ago"; else echo "$years years ago"; fi
    fi
}

# Purpose: Replaces $HOME prefix with ~ for compact display
# Parameters: $1 — absolute path
# Returns: Prints truncated path
# Usage: short=$(truncate_path "/Users/me/project")  # "~/project"
truncate_path() {
    local path="$1"
    if [[ "$path" == "$HOME"* ]]; then
        echo "~${path#"$HOME"}"
    else
        echo "$path"
    fi
}

# ─── Session Commands ─────────────────────────────────────────────────────────

# Purpose: Routes session subcommands to their implementations
# Parameters: $1 — subcommand name, remaining args passed through
# Returns: Exit code from dispatched subcommand
# Usage: cmd_session list | cmd_session info <path> | cmd_session clean --dry-run
cmd_session() {
    case "${1:-}" in
        list)       session_list ;;
        info)       shift; session_info "$@" ;;
        summary)    shift; session_summary "$@" ;;
        relocate)   shift; session_relocate "$@" ;;
        clean)      shift; session_clean "$@" ;;
        search)     shift; session_search "$@" ;;
        archive)    shift; session_archive "$@" ;;
        restore)    shift; session_restore "$@" ;;
        archives)   session_archives_list ;;
        "")         show_help session ;;
        *)          log_error "Unknown session command '$1'"; show_help session; exit 1 ;;
    esac
}

# Purpose: Lists all Claude Code project sessions with status and usage info
# Parameters: None
# Returns: Prints formatted table of sessions sorted by most recent activity
# Usage: session_list
session_list() {
    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR"
        log_info "No sessions exist yet. Use Claude Code in a project to create one."
        return 0
    fi

    local entries=()
    local dir_count=0

    for session_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        [[ -d "$session_dir" ]] || continue
        dir_count=$((dir_count + 1))

        local dirname
        dirname=$(basename "$session_dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")
        local display_path
        display_path=$(truncate_path "$decoded_path")

        # Count .jsonl session files
        local file_count=0
        while IFS= read -r -d '' _; do
            file_count=$((file_count + 1))
        done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" -type f -print0 2>/dev/null)

        # Sum disk usage (in bytes)
        local disk_bytes=0
        local platform
        platform=$(detect_platform)
        case "$platform" in
            macos)  disk_bytes=$(du -sk "$session_dir" 2>/dev/null | awk '{print $1 * 1024}') ;;
            *)      disk_bytes=$(du -sb "$session_dir" 2>/dev/null | awk '{print $1}') ;;
        esac
        local disk_human
        disk_human=$(format_size "$disk_bytes")

        # Find most recent file modification time
        local latest_mtime=0
        while IFS= read -r -d '' f; do
            local mt
            mt=$(get_mtime "$f")
            if [[ "$mt" -gt "$latest_mtime" ]]; then
                latest_mtime="$mt"
            fi
        done < <(find "$session_dir" -type f -print0 2>/dev/null)

        local relative_time
        relative_time=$(format_relative_time "$latest_mtime")

        # Check if project directory exists on disk
        local status="active"
        if [[ ! -d "$decoded_path" ]]; then
            status="orphaned"
        fi

        # Store as tab-delimited for sorting: mtime<TAB>display_line
        local status_display
        if [[ "$status" == "active" ]]; then
            status_display="${COLOR_GREEN}active${COLOR_RESET}"
        else
            status_display="${COLOR_YELLOW}orphaned${COLOR_RESET}"
        fi
        entries+=("${latest_mtime}	$(printf '%-45s %5s %8s  %-16s %s' "$display_path" "$file_count" "$disk_human" "$relative_time" "$status_display")")
    done

    if [[ "$dir_count" -eq 0 ]]; then
        log_info "No project sessions found."
        return 0
    fi

    echo -e "${COLOR_BOLD}Claude Code Project Sessions${COLOR_RESET}"
    echo ""
    printf "${COLOR_BOLD}%-45s %5s %8s  %-16s %s${COLOR_RESET}\n" "PROJECT" "FILES" "SIZE" "LAST ACTIVE" "STATUS"
    echo "────────────────────────────────────────────────────────────────────────────────────────────"

    # Sort by mtime descending, then print
    printf '%s\n' "${entries[@]}" | sort -t$'\t' -k1 -rn | while IFS=$'\t' read -r _ line; do
        echo -e "$line"
    done

    echo ""
    log_info "Total: $dir_count project(s)"
}

# Purpose: Shows detailed information about a specific project's sessions
# Parameters: $1 — project path (absolute, relative, or with ~)
# Returns: Prints session details including files, size, and memory info
# Usage: session_info . | session_info ~/my-project
session_info() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: ccm session info <project-path>"
        echo ""
        echo "Shows detailed session information for a project."
        echo ""
        echo "Examples:"
        echo "  ccm session info ."
        echo "  ccm session info ~/projects/my-app"
        exit 1
    fi

    local input_path="$1"

    # Resolve to absolute path
    local abs_path
    # Handle ~ expansion
    if [[ "$input_path" == "~"* ]]; then
        input_path="${input_path/#\~/$HOME}"
    fi
    # If directory exists, resolve with cd+pwd for canonical path
    if [[ -d "$input_path" ]]; then
        abs_path=$(cd "$input_path" && pwd)
    elif [[ "$input_path" == /* ]]; then
        # Already absolute but dir doesn't exist (deleted project)
        abs_path="$input_path"
    else
        # Relative path, dir doesn't exist — prepend pwd
        abs_path="$(pwd)/$input_path"
    fi

    local encoded
    encoded=$(encode_project_path "$abs_path")
    local session_dir="$CLAUDE_PROJECTS_DIR/$encoded"

    if [[ ! -d "$session_dir" ]]; then
        log_error "No session data found for: $abs_path"
        log_info "Expected session directory: $session_dir"
        return 1
    fi

    local display_path
    display_path=$(truncate_path "$abs_path")

    echo -e "${COLOR_BOLD}Session Info: ${display_path}${COLOR_RESET}"
    echo ""

    # Status
    local status
    if [[ -d "$abs_path" ]]; then
        status="${COLOR_GREEN}active${COLOR_RESET} (project exists on disk)"
    else
        status="${COLOR_YELLOW}orphaned${COLOR_RESET} (project directory not found)"
    fi
    echo -e "  Status:         $status"

    # Session file count
    local file_count=0
    while IFS= read -r -d '' _; do
        file_count=$((file_count + 1))
    done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" -type f -print0 2>/dev/null)
    echo "  Session files:  $file_count"

    # Memory files
    local memory_count=0
    if [[ -d "$session_dir/memory" ]]; then
        while IFS= read -r -d '' _; do
            memory_count=$((memory_count + 1))
        done < <(find "$session_dir/memory" -type f -print0 2>/dev/null)
    fi
    echo "  Memory files:   $memory_count"

    # Total disk usage
    local disk_bytes=0
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)  disk_bytes=$(du -sk "$session_dir" 2>/dev/null | awk '{print $1 * 1024}') ;;
        *)      disk_bytes=$(du -sb "$session_dir" 2>/dev/null | awk '{print $1}') ;;
    esac
    local disk_human
    disk_human=$(format_size "$disk_bytes")
    echo "  Total size:     $disk_human"

    # Last active
    local latest_mtime=0
    while IFS= read -r -d '' f; do
        local mt
        mt=$(get_mtime "$f")
        if [[ "$mt" -gt "$latest_mtime" ]]; then
            latest_mtime="$mt"
        fi
    done < <(find "$session_dir" -type f -print0 2>/dev/null)
    local relative_time
    relative_time=$(format_relative_time "$latest_mtime")
    echo "  Last active:    $relative_time"

    # List individual session files
    if [[ "$file_count" -gt 0 ]]; then
        echo ""
        echo -e "  ${COLOR_BOLD}Session Files:${COLOR_RESET}"
        while IFS= read -r -d '' sf; do
            local fname fsize fmtime freltime
            fname=$(basename "$sf")
            case "$platform" in
                macos)  fsize=$(stat -f %z "$sf" 2>/dev/null || echo "0") ;;
                *)      fsize=$(stat -c %s "$sf" 2>/dev/null || echo "0") ;;
            esac
            fmtime=$(get_mtime "$sf")
            freltime=$(format_relative_time "$fmtime")
            echo "    $fname  $(format_size "$fsize")  $freltime"
        done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" -type f -print0 2>/dev/null | sort -z)
    fi

    # List memory files
    if [[ "$memory_count" -gt 0 ]]; then
        echo ""
        echo -e "  ${COLOR_BOLD}Memory Files:${COLOR_RESET}"
        while IFS= read -r -d '' mf; do
            local mfname
            mfname=$(basename "$mf")
            echo "    $mfname"
        done < <(find "$session_dir/memory" -type f -print0 2>/dev/null | sort -z)
    fi
}

# Purpose: Cleans orphaned session directories whose projects no longer exist on disk
# Parameters: [--dry-run] — list orphaned sessions without removing them
# Returns: Exit code 0 on success
# Usage: session_clean | session_clean --dry-run
session_clean() {
    local dry_run=0
    if [[ "${1:-}" == "--dry-run" ]]; then
        dry_run=1
    fi

    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_info "Claude Code projects directory not found. Nothing to clean."
        return 0
    fi

    local orphaned=()
    local orphaned_sizes=()
    local total_bytes=0

    for session_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        [[ -d "$session_dir" ]] || continue

        local dirname
        dirname=$(basename "$session_dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")

        if [[ ! -d "$decoded_path" ]]; then
            orphaned+=("$session_dir")
            local disk_bytes=0
            local platform
            platform=$(detect_platform)
            case "$platform" in
                macos)  disk_bytes=$(du -sk "$session_dir" 2>/dev/null | awk '{print $1 * 1024}') ;;
                *)      disk_bytes=$(du -sb "$session_dir" 2>/dev/null | awk '{print $1}') ;;
            esac
            orphaned_sizes+=("$disk_bytes")
            total_bytes=$((total_bytes + disk_bytes))
        fi
    done

    if [[ ${#orphaned[@]} -eq 0 ]]; then
        log_success "No orphaned sessions found. All project directories exist."
        return 0
    fi

    echo -e "${COLOR_BOLD}Orphaned Sessions${COLOR_RESET}"
    echo ""
    log_warning "Note: Projects on unmounted drives or network shares may appear as orphaned."
    echo ""

    for i in "${!orphaned[@]}"; do
        local dirname
        dirname=$(basename "${orphaned[$i]}")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")
        local display_path
        display_path=$(truncate_path "$decoded_path")
        local size_human
        size_human=$(format_size "${orphaned_sizes[$i]}")
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} $display_path  ($size_human)"
    done

    echo ""
    local total_human
    total_human=$(format_size "$total_bytes")
    log_info "Found ${#orphaned[@]} orphaned session(s), total size: $total_human"

    if [[ "$dry_run" -eq 1 ]]; then
        echo ""
        log_info "Dry run — no changes made. Remove --dry-run to clean."
        return 0
    fi

    echo ""
    echo -n "Remove all orphaned sessions? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Clean cancelled."
        return 0
    fi

    local removed=0
    for session_dir in "${orphaned[@]}"; do
        rm -rf "$session_dir"
        removed=$((removed + 1))
    done

    log_success "Removed $removed orphaned session(s), freed $total_human"
}

# Purpose: Shows summary of what happened in each session for a project
# Parameters: [project-path] [--limit N]
# Returns: 0
# Usage: session_summary . | session_summary ~/my-app --limit 5
session_summary() {
    local target_path="."
    local limit=5

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit) limit="$2"; shift 2 ;;
            *)       target_path="$1"; shift ;;
        esac
    done

    if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -eq 0 ]]; then
        log_error "--limit must be a positive integer."
        return 1
    fi

    local abs_path
    abs_path=$(cd "$target_path" 2>/dev/null && pwd || echo "$target_path")
    local encoded_path
    encoded_path=$(echo "$abs_path" | sed 's|/|-|g')
    local project_dir="$CLAUDE_PROJECTS_DIR/$encoded_path"

    if [[ ! -d "$project_dir" ]]; then
        log_error "No sessions found for: $abs_path"
        return 1
    fi

    local display_path
    display_path=$(truncate_path "$abs_path")

    echo -e "${COLOR_BOLD}Session Summaries — $display_path${COLOR_RESET}"
    echo ""

    local shown=0
    # Sort JSONL files by modification time, newest first
    while IFS= read -r jsonl_file; do
        [[ -f "$jsonl_file" ]] || continue
        shown=$((shown + 1))
        [[ "$shown" -gt "$limit" ]] && break

        local fname
        fname=$(basename "$jsonl_file" .jsonl)
        local short_id="${fname:0:8}"

        # Extract summary data in a single jq pass
        local summary
        summary=$(jq -s '
            {
                first_user: (
                    [.[] | select(.type == "user") | .message.content |
                        if type == "array" then
                            map(select(.type == "text")) | first | .text
                        elif type == "string" then .
                        else null end
                    ] | map(select(. != null and . != "null")) | first // "—"
                ),
                user_msgs: ([.[] | select(.type == "user")] | length),
                asst_msgs: ([.[] | select(.type == "assistant")] | length),
                tools: (
                    [.[] | select(.type == "assistant") | .message.content[]? |
                        select(.type == "tool_use") | .name] |
                    group_by(.) | map({name: .[0], count: length}) |
                    sort_by(-.count) | .[0:5]
                ),
                files_modified: (
                    [.[] | select(.type == "assistant") | .message.content[]? |
                        select(.type == "tool_use" and (.name == "Write" or .name == "Edit")) |
                        (.input.file_path // .input.path // empty)] |
                    unique | .[0:8]
                ),
                first_ts: ([.[] | .timestamp // empty] | map(select(. != null)) | first // ""),
                last_ts: ([.[] | .timestamp // empty] | map(select(. != null)) | last // ""),
                tokens: (
                    [.[] | select(.type == "assistant" and .message.usage != null) |
                        ((.message.usage.input_tokens // 0) + (.message.usage.output_tokens // 0) +
                         (.message.usage.cache_creation_input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0))] | add // 0
                )
            }
        ' "$jsonl_file" 2>/dev/null)

        [[ -z "$summary" ]] && continue

        local first_user user_msgs asst_msgs first_ts tokens
        first_user=$(echo "$summary" | jq -r '.first_user' | head -1)
        user_msgs=$(echo "$summary" | jq -r '.user_msgs')
        asst_msgs=$(echo "$summary" | jq -r '.asst_msgs')
        first_ts=$(echo "$summary" | jq -r '.first_ts')
        tokens=$(echo "$summary" | jq -r '.tokens')

        # Truncate first user message
        [[ ${#first_user} -gt 80 ]] && first_user="${first_user:0:77}..."

        local date_display="${first_ts:0:10}"
        local tok_fmt
        tok_fmt=$(format_token_count "$tokens")

        echo -e "  ${COLOR_BOLD}${short_id}...${COLOR_RESET}  ${COLOR_CYAN}$date_display${COLOR_RESET}  ${user_msgs} user / ${asst_msgs} assistant msgs  ${tok_fmt} tokens"

        # First user message as topic
        if [[ "$first_user" != "—" && -n "$first_user" ]]; then
            echo -e "  ${COLOR_GREEN}Topic:${COLOR_RESET} $first_user"
        fi

        # Tool usage
        local tools_str
        tools_str=$(echo "$summary" | jq -r '.tools[] | "\(.name)×\(.count)"' 2>/dev/null | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
        [[ -n "$tools_str" ]] && echo -e "  ${COLOR_YELLOW}Tools:${COLOR_RESET} $tools_str"

        # Files modified
        local files_str
        files_str=$(echo "$summary" | jq -r '.files_modified[]' 2>/dev/null | sed "s|$HOME|~|g" | sed 's|.*/||' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
        [[ -n "$files_str" ]] && echo -e "  ${COLOR_CYAN}Files:${COLOR_RESET} $files_str"

        echo ""
    done < <(find "$project_dir" -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null)

    local total
    total=$(find "$project_dir" -maxdepth 1 -name "*.jsonl" 2>/dev/null | wc -l | tr -d ' ')
    local remaining=$((total - shown))
    [[ "$remaining" -gt 0 ]] && echo "  $remaining more sessions — use --limit $((shown + 10)) to see more"
}

# Purpose: Full-text search across all JSONL session files
# Parameters: $1 — search query, [--limit N] (default 10)
# Returns: 0 on success
# Usage: session_search "error handling" | session_search "API" --limit 5
session_search() {
    local query=""
    local limit=10

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --limit) limit="$2"; shift 2 ;;
            -*)      log_error "Unknown option '$1'"; return 1 ;;
            *)       query="$1"; shift ;;
        esac
    done

    if [[ -z "$query" ]]; then
        log_error "Search query required."
        echo "Usage: ccm session search <query> [--limit N]"
        return 1
    fi

    if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -eq 0 ]]; then
        log_error "--limit must be a positive integer."
        return 1
    fi

    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "No sessions found."
        return 1
    fi

    echo -e "${COLOR_BOLD}Session Search: \"$query\"${COLOR_RESET}"
    echo ""

    local results=()
    local match_count=0

    for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        [[ -d "$project_dir" ]] || continue

        local dirname
        dirname=$(basename "$project_dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")
        local display_path
        display_path=$(truncate_path "$decoded_path")

        while IFS= read -r -d '' jsonl_file; do
            # Search for query in file (case-insensitive, fixed string)
            local first_match
            first_match=$(grep -i -m 1 -F "$query" "$jsonl_file" 2>/dev/null) || continue

            local timestamp
            timestamp=$(echo "$first_match" | jq -r '.timestamp // "unknown"' 2>/dev/null)

            # Extract text snippet from message content
            local snippet
            snippet=$(echo "$first_match" | jq -r '
                (.message.content // "") |
                if type == "array" then
                    map(select(type == "object" and .type == "text") | .text) | join(" ")
                elif type == "string" then .
                else ""
                end
            ' 2>/dev/null)

            # If snippet is empty, try data field
            if [[ -z "$snippet" || "$snippet" == "null" ]]; then
                snippet=$(echo "$first_match" | jq -r '(.data // "") | if type == "string" then . else "" end' 2>/dev/null)
            fi

            snippet="${snippet:0:120}"
            [[ ${#snippet} -ge 120 ]] && snippet="${snippet}..."

            local time_display="unknown"
            if [[ "$timestamp" != "unknown" && "$timestamp" != "null" ]]; then
                time_display="${timestamp:0:10} ${timestamp:11:8}"
            fi

            local sep=$'\x1F'
            results+=("${timestamp}${sep}${display_path}${sep}${time_display}${sep}${snippet}")
            match_count=$((match_count + 1))

            [[ "$match_count" -ge "$limit" ]] && break 2
        done < <(find "$project_dir" -maxdepth 2 -name "*.jsonl" -print0 2>/dev/null)
    done

    if [[ ${#results[@]} -eq 0 ]]; then
        log_info "No matches found for \"$query\""
        return 0
    fi

    # Sort results by timestamp descending and display
    local sep=$'\x1F'
    local sorted
    sorted=$(printf '%s\n' "${results[@]}" | sort -t"$sep" -k1 -r)

    local idx=0
    while IFS=$'\x1F' read -r ts project time_disp snippet; do
        [[ -z "$ts" ]] && continue
        idx=$((idx + 1))
        echo -e "  ${COLOR_BOLD}$idx.${COLOR_RESET} ${COLOR_CYAN}$project${COLOR_RESET}"
        echo "     $time_disp"
        if [[ -n "$snippet" && "$snippet" != "null" ]]; then
            echo "     $snippet"
        fi
        echo ""
    done <<< "$sorted"

    echo "Found $match_count result(s)"
}

# Add account
# Purpose: Adds the currently logged-in Claude Code account to managed accounts
# Parameters: None
# Returns: Exit code 0 on success, 1 on failure
# Usage: cmd_add_account
# Preconditions: User must be logged into Claude Code
cmd_add_account() {
    setup_directories
    init_sequence_file
    migrate_sequence_file

    show_progress "Checking current account"
    local current_email
    current_email=$(get_current_account)
    complete_progress

    if [[ "$current_email" == "none" ]]; then
        log_error "No active Claude account found. Please log in first."
        exit 1
    fi

    if account_exists "$current_email"; then
        log_info "Account $current_email is already managed."
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)

    show_progress "Reading credentials and configuration"
    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    complete_progress

    if [[ -z "$current_creds" ]]; then
        log_error "No credentials found for current account"
        exit 1
    fi

    # Get account UUID
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")

    show_progress "Storing account backups"
    # Store backups
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"
    complete_progress

    show_progress "Updating account registry"
    # Update sequence.json with new metadata fields
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            added: $now,
            alias: null,
            lastUsed: $now,
            usageCount: 1,
            healthStatus: "healthy"
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache
    complete_progress

    log_success "Added Account $account_num: $current_email"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: ccm remove <account_number|email|alias>"
        exit 1
    fi

    local identifier="$1"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    migrate_sequence_file

    # Resolve identifier (number, email, or alias)
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        log_error "No account found matching: $identifier"
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        log_error "Account-$account_num does not exist"
        exit 1
    fi

    local email
    email=$(echo "$account_info" | jq -r '.email')

    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    if [[ "$active_account" == "$account_num" ]]; then
        log_warning "Account-$account_num ($email) is currently active"
    fi

    echo -e -n "${COLOR_YELLOW}Are you sure you want to permanently remove Account-$account_num ($email)?${COLOR_RESET} [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        exit 0
    fi

    show_progress "Removing backup files"
    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    complete_progress

    show_progress "Updating account registry"
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .activeAccountNumber = (if .activeAccountNumber == ($num | tonumber) then null else .activeAccountNumber end) |
        .bindings = (.bindings // {} | with_entries(select(.value != ($num | tonumber | tostring)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache
    complete_progress

    log_success "Account-$account_num ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi
    
    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response
    
    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run 'ccm add' later."
        return 1
    fi
    
    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    migrate_sequence_file

    # Get current active account from .claude.json
    local current_email
    current_email=$(get_current_account)

    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    fi

    echo -e "${COLOR_BOLD}Accounts:${COLOR_RESET}"

    # Read each account and format with colors
    while IFS= read -r line; do
        local num email alias last_used usage_count health is_active
        num=$(echo "$line" | jq -r '.num')
        email=$(echo "$line" | jq -r '.email')
        alias=$(echo "$line" | jq -r '.alias // empty')
        last_used=$(echo "$line" | jq -r '.lastUsed // empty')
        usage_count=$(echo "$line" | jq -r '.usageCount // 0')
        health=$(echo "$line" | jq -r '.healthStatus // "unknown"')
        is_active=$(echo "$line" | jq -r '.isActive')

        # Format account line
        local account_line="  $num: $email"

        # Add alias if present
        if [[ -n "$alias" ]]; then
            account_line+=" ${COLOR_CYAN}[$alias]${COLOR_RESET}"
        fi

        # Add active indicator
        if [[ "$is_active" == "true" ]]; then
            account_line+=" ${COLOR_GREEN}(active)${COLOR_RESET}"
        fi

        # Add metadata on next line
        local metadata=""
        if [[ -n "$last_used" && "$last_used" != "null" ]]; then
            local last_used_formatted
            last_used_formatted=$(format_iso_date "$last_used")
            metadata+="     Last used: $last_used_formatted"
        fi

        if [[ "$usage_count" -gt 0 ]]; then
            metadata+=" | Used: ${usage_count}x"
        fi

        # Health indicator
        case "$health" in
            healthy)
                metadata+=" | ${COLOR_GREEN}●${COLOR_RESET} healthy"
                ;;
            degraded)
                metadata+=" | ${COLOR_YELLOW}●${COLOR_RESET} degraded"
                ;;
            unhealthy)
                metadata+=" | ${COLOR_RED}●${COLOR_RESET} unhealthy"
                ;;
        esac

        echo -e "$account_line"
        if [[ -n "$metadata" ]]; then
            echo -e "$metadata"
        fi
    done < <(jq -c --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] + {
            num: $num,
            isActive: (if "\($num)" == $active then "true" else "false" end)
        }
    ' "$SEQUENCE_FILE")

    # Show project bindings if any exist
    local bindings
    bindings=$(jq -r '.bindings // {} | to_entries[] | "\(.key)|\(.value)"' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$bindings" ]]; then
        echo ""
        echo -e "${COLOR_BOLD}Bindings:${COLOR_RESET}"
        while IFS='|' read -r path account_num; do
            [[ -z "$path" ]] && continue
            local display_path
            display_path=$(truncate_path "$path")
            local email
            email=$(jq -r --arg n "$account_num" '.accounts[$n].email // "unknown"' "$SEQUENCE_FILE")
            local alias_name
            alias_name=$(jq -r --arg n "$account_num" '.accounts[$n].alias // empty' "$SEQUENCE_FILE")
            local label="$account_num"
            [[ -n "$alias_name" ]] && label="$alias_name"
            echo -e "  ${display_path} ${COLOR_CYAN}→${COLOR_RESET} ${label}"
        done <<< "$bindings"
    fi
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi
    
    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run 'ccm switch' again to switch to the next account."
        exit 0
    fi
    
    # wait_for_claude_close

    # Check if current directory has a project binding
    local cwd
    cwd=$(pwd)
    local bound_account
    bound_account=$(jq -r --arg path "$cwd" '.bindings[$path] // empty' "$SEQUENCE_FILE" 2>/dev/null)

    if [[ -n "$bound_account" ]]; then
        local active_account
        active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        if [[ "$active_account" == "$bound_account" ]]; then
            local bound_email
            bound_email=$(jq -r --arg n "$bound_account" '.accounts[$n].email // "unknown"' "$SEQUENCE_FILE")
            log_info "Already on bound account $bound_account ($bound_email) for this project."
            return 0
        fi
        local bound_email
        bound_email=$(jq -r --arg n "$bound_account" '.accounts[$n].email // "unknown"' "$SEQUENCE_FILE")
        log_info "Project binding: switching to Account-$bound_account ($bound_email)"
        perform_switch "$bound_account"
        return $?
    fi

    local active_account sequence
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))

    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done

    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"

    perform_switch "$next_account"
}

# Switch to specific account
# Purpose: Switches to a specific account identified by number, email, or alias
# Parameters:
#   $1 - identifier: Account number, email, or alias
# Returns: Exit code 0 on success, 1 on failure
# Usage: cmd_switch_to 2  OR  cmd_switch_to work  OR  cmd_switch_to user@example.com
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

    # Resolve identifier (number, email, or alias) to account number
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

    # wait_for_claude_close
    perform_switch "$target_account"
}

# Add history entry
add_history_entry() {
    local from_account="$1"
    local to_account="$2"
    local timestamp="$3"

    local updated_sequence
    updated_sequence=$(jq --arg from "$from_account" --arg to "$to_account" --arg ts "$timestamp" --argjson max "$MAX_HISTORY_ENTRIES" '
        .history += [{
            from: ($from | tonumber),
            to: ($to | tonumber),
            timestamp: $ts
        }] |
        .history = (.history | .[-$max:])
    ' "$SEQUENCE_FILE")

    echo "$updated_sequence"
}

# Perform the actual account switch
# Purpose: Switches authentication from current account to target account
# Parameters:
#   $1 - target_account: Account number to switch to
# Returns: Exit code 0 on success, 1 on failure
# Usage: perform_switch 2
# Side effects: Updates credentials, config files, and sequence.json with history
perform_switch() {
    local target_account="$1"

    show_progress "Validating target account"
    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)
    complete_progress

    show_progress "Backing up current account"
    # Step 1: Backup current account (parallel safe operations)
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
    complete_progress

    show_progress "Retrieving target account data"
    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")

    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        log_error "Missing backup data for Account-$target_account"
        exit 1
    fi
    complete_progress

    show_progress "Validating backup data"
    # Validate before switching
    if ! echo "$target_config" | jq -e '.oauthAccount' >/dev/null 2>&1; then
        log_error "Invalid oauthAccount in backup"
        exit 1
    fi
    complete_progress

    show_progress "Activating target account"
    # Step 3: Activate target account
    write_credentials "$target_creds"

    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        log_error "Invalid oauthAccount in backup"
        exit 1
    fi

    # Merge with current config and validate
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log_error "Failed to merge config"
        exit 1
    fi

    # Use existing safe write_json function
    write_json "$(get_claude_config_path)" "$merged_config"
    complete_progress

    show_progress "Updating account metadata"
    # Step 4: Update state with history and metadata
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$now" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now |
        .accounts[$num].lastUsed = $now |
        .accounts[$num].usageCount = ((.accounts[$num].usageCount // 0) + 1)
    ' "$SEQUENCE_FILE")

    # Add history entry
    updated_sequence=$(echo "$updated_sequence" | jq --arg from "$current_account" --arg to "$target_account" --arg ts "$now" --argjson max "$MAX_HISTORY_ENTRIES" '
        .history += [{
            from: ($from | tonumber),
            to: ($to | tonumber),
            timestamp: $ts
        }] |
        .history = (.history | .[-$max:])
    ')

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache
    complete_progress

    log_success "Switched to Account-$target_account ($target_email)"
    echo ""
    # Display updated account list
    cmd_list
    echo ""
    log_info "Please restart Claude Code to use the new authentication."
    echo ""
}

# Set account alias
# Purpose: Assigns a friendly name/alias to an account for easier identification
# Parameters:
#   $1 - identifier: Account number, email, or existing alias
#   $2 - alias: New alias to assign (alphanumeric, dash, underscore only)
# Returns: Exit code 0 on success, 1 on failure
# Usage: cmd_set_alias 1 work
cmd_set_alias() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: ccm alias <account_number|email> <alias>"
        exit 1
    fi

    local identifier="$1"
    local alias="$2"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    migrate_sequence_file

    # Resolve identifier (number, email, or alias)
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        log_error "No account found matching: $identifier"
        exit 1
    fi

    # Validate account exists
    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        log_error "Account-$account_num does not exist"
        exit 1
    fi

    # Validate alias format (alphanumeric, dash, underscore only)
    if [[ ! "$alias" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid alias format. Use only letters, numbers, dash, and underscore"
        exit 1
    fi

    # Enforce unique aliases so identifier resolution stays deterministic.
    local existing_alias_num
    existing_alias_num=$(jq -r --arg alias "$alias" --arg num "$account_num" '
        .accounts
        | to_entries[]
        | select(.key != $num and .value.alias == $alias)
        | .key
    ' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$existing_alias_num" && "$existing_alias_num" != "null" ]]; then
        local existing_alias_email
        existing_alias_email=$(jq -r --arg num "$existing_alias_num" '.accounts[$num].email // "unknown"' "$SEQUENCE_FILE")
        log_error "Alias '$alias' is already used by Account-$existing_alias_num ($existing_alias_email)"
        exit 1
    fi

    show_progress "Setting alias for Account-$account_num"
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg alias "$alias" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num].alias = $alias |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache
    complete_progress

    local email
    email=$(echo "$account_info" | jq -r '.email')
    log_success "Set alias '$alias' for Account-$account_num ($email)"
}

# Verify account backups
# Purpose: Validates integrity of account backups (credentials and config)
# Parameters:
#   $1 - target_account (optional): Specific account to verify, or all if omitted
# Returns: Exit code 0 if all verified accounts are healthy, 1 if issues found
# Usage: cmd_verify 1  OR  cmd_verify
cmd_verify() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    migrate_sequence_file

    local target_account="${1:-}"
    local accounts_to_check

    if [[ -n "$target_account" ]]; then
        # Verify specific account
        if [[ "$target_account" =~ ^[0-9]+$ ]]; then
            accounts_to_check=("$target_account")
        else
            local resolved
            resolved=$(resolve_account_identifier "$target_account")
            if [[ -z "$resolved" ]]; then
                log_error "No account found: $target_account"
                exit 1
            fi
            accounts_to_check=("$resolved")
        fi
    else
        # Verify all accounts
        mapfile -t accounts_to_check < <(jq -r '.sequence[]' "$SEQUENCE_FILE")
    fi

    echo -e "${COLOR_BOLD}Verification Results:${COLOR_RESET}"
    local all_healthy=1

    for account_num in "${accounts_to_check[@]}"; do
        local email health_status="healthy"
        email=$(jq -r --arg num "$account_num" '.accounts[$num].email' "$SEQUENCE_FILE")

        # Check if credentials exist
        local creds config
        creds=$(read_account_credentials "$account_num" "$email")
        config=$(read_account_config "$account_num" "$email")

        if [[ -z "$creds" ]]; then
            health_status="unhealthy"
            all_healthy=0
            echo -e "  ${COLOR_RED}✗${COLOR_RESET} Account-$account_num ($email): Missing credentials"
        elif [[ -z "$config" ]]; then
            health_status="unhealthy"
            all_healthy=0
            echo -e "  ${COLOR_RED}✗${COLOR_RESET} Account-$account_num ($email): Missing configuration"
        elif ! echo "$config" | jq -e '.oauthAccount' >/dev/null 2>&1; then
            health_status="degraded"
            all_healthy=0
            echo -e "  ${COLOR_YELLOW}⚠${COLOR_RESET} Account-$account_num ($email): Invalid configuration format"
        else
            echo -e "  ${COLOR_GREEN}✓${COLOR_RESET} Account-$account_num ($email): Healthy"
        fi

        # Update health status
        local updated_sequence
        updated_sequence=$(jq --arg num "$account_num" --arg health "$health_status" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
            .accounts[$num].healthStatus = $health |
            .lastUpdated = $now
        ' "$SEQUENCE_FILE")
        write_json "$SEQUENCE_FILE" "$updated_sequence"
    done

    invalidate_cache

    if [[ $all_healthy -eq 1 ]]; then
        echo ""
        log_success "All accounts verified successfully"
    else
        echo ""
        log_warning "Some accounts have issues. Run 'ccm add' while logged in to repair."
    fi
}

# Show account status
# Purpose: Returns short account label for statusline integration (no colors, single line)
# Parameters: None
# Returns: Account alias or email on stdout
# Usage: get_active_account_label
get_active_account_label() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "no accounts"
        return 0
    fi
    local email
    email=$(get_current_account)
    if [[ "$email" == "none" ]]; then
        echo "no account"
        return 0
    fi
    local account_num
    account_num=$(jq -r --arg email "$email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$account_num" ]]; then
        local alias_name
        alias_name=$(jq -r --arg n "$account_num" '.accounts[$n].alias // empty' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$alias_name" ]]; then
            echo "$alias_name"
        else
            echo "$email"
        fi
    else
        echo "$email"
    fi
}

# Show switch history
cmd_history() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No switch history yet."
        exit 0
    fi

    migrate_sequence_file

    local history_count
    history_count=$(jq '.history | length' "$SEQUENCE_FILE")

    if [[ "$history_count" -eq 0 ]]; then
        log_info "No switch history yet."
        exit 0
    fi

    echo -e "${COLOR_BOLD}Account Switch History:${COLOR_RESET}"
    echo ""

    jq -r '.history | reverse | .[] |
        @json' "$SEQUENCE_FILE" | while read -r entry; do
        local from_num to_num timestamp
        from_num=$(echo "$entry" | jq -r '.from')
        to_num=$(echo "$entry" | jq -r '.to')
        timestamp=$(echo "$entry" | jq -r '.timestamp')

        local from_email to_email
        from_email=$(jq -r --arg num "$from_num" '.accounts["\($num)"].email // "Unknown"' "$SEQUENCE_FILE")
        to_email=$(jq -r --arg num "$to_num" '.accounts["\($num)"].email // "Unknown"' "$SEQUENCE_FILE")

        local time_formatted
        time_formatted=$(format_iso_date "$timestamp")

        echo -e "  ${COLOR_CYAN}→${COLOR_RESET} $time_formatted: Account-$from_num ($from_email) → Account-$to_num ($to_email)"
    done
}

# Undo last switch
cmd_undo() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        exit 1
    fi

    migrate_sequence_file

    local history_count
    history_count=$(jq '.history | length' "$SEQUENCE_FILE")

    if [[ "$history_count" -eq 0 ]]; then
        log_error "No switch history to undo"
        exit 1
    fi

    # Get last history entry
    local last_entry from_account
    last_entry=$(jq -r '.history | last' "$SEQUENCE_FILE")
    from_account=$(echo "$last_entry" | jq -r '.from')

    # Verify account still exists
    local account_exists
    account_exists=$(jq -e --arg num "$from_account" '.accounts[$num]' "$SEQUENCE_FILE" >/dev/null 2>&1 && echo "yes" || echo "no")

    if [[ "$account_exists" != "yes" ]]; then
        log_error "Cannot undo: Previous account (Account-$from_account) no longer exists"
        exit 1
    fi

    log_info "Undoing last switch to Account-$from_account..."
    perform_switch "$from_account"
}

# Purpose: Reorders accounts by moving one account to a new position
# Parameters: $1 — source position (current account number), $2 — target position
# Returns: 0 on success, 1 on failure
# Usage: cmd_reorder 3 1
cmd_reorder() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: ccm reorder <from_position> <to_position>"
        exit 1
    fi

    local from_pos="$1"
    local to_pos="$2"

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet."
        exit 1
    fi

    migrate_sequence_file

    # Validate positions are numbers
    if ! [[ "$from_pos" =~ ^[0-9]+$ ]] || ! [[ "$to_pos" =~ ^[0-9]+$ ]]; then
        log_error "Positions must be numbers."
        exit 1
    fi

    # Validate source account exists
    local from_account
    from_account=$(jq -r --arg num "$from_pos" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$from_account" ]]; then
        log_error "No account at position $from_pos."
        exit 1
    fi

    if [[ "$from_pos" == "$to_pos" ]]; then
        log_info "Account is already at position $to_pos."
        return 0
    fi

    # Get all account numbers sorted
    local account_nums
    account_nums=$(jq -r '.sequence | sort | map(tostring) | .[]' "$SEQUENCE_FILE")

    # Check target position is reasonable (1 to max)
    local max_num
    max_num=$(jq -r '.sequence | max' "$SEQUENCE_FILE")
    if [[ "$to_pos" -lt 1 ]] || [[ "$to_pos" -gt "$max_num" ]]; then
        log_error "Target position must be between 1 and $max_num."
        exit 1
    fi

    echo -e "${COLOR_BOLD}Reorder Accounts${COLOR_RESET}"
    echo ""

    # Show current state
    echo "Before:"
    while IFS= read -r num; do
        local email alias_name
        email=$(jq -r --arg n "$num" '.accounts[$n].email' "$SEQUENCE_FILE")
        alias_name=$(jq -r --arg n "$num" '.accounts[$n].alias // empty' "$SEQUENCE_FILE")
        local label="$email"
        [[ -n "$alias_name" ]] && label="$email [$alias_name]"
        echo "  $num: $label"
    done <<< "$account_nums"
    echo ""

    show_progress "Reordering accounts"

    local platform
    platform=$(detect_platform)
    local active_num
    active_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    # Build the reorder mapping: determine which account numbers need to change
    # Strategy: remove from_pos from sequence, insert at to_pos, then renumber sequentially
    local ordered_nums=()
    while IFS= read -r num; do
        [[ "$num" == "$from_pos" ]] && continue
        ordered_nums+=("$num")
    done <<< "$account_nums"

    # Insert from_pos at the right position (to_pos - 1 index, since we number from 1)
    local insert_idx=$((to_pos - 1))
    if [[ "$insert_idx" -ge "${#ordered_nums[@]}" ]]; then
        ordered_nums+=("$from_pos")
    else
        ordered_nums=("${ordered_nums[@]:0:$insert_idx}" "$from_pos" "${ordered_nums[@]:$insert_idx}")
    fi

    # Now renumber: ordered_nums[0] becomes 1, ordered_nums[1] becomes 2, etc.
    # Build a mapping of old_num -> new_num
    declare -A num_map
    local new_sequence=()
    for i in "${!ordered_nums[@]}"; do
        local old_num="${ordered_nums[$i]}"
        local new_num=$((i + 1))
        num_map[$old_num]=$new_num
        new_sequence+=("$new_num")
    done

    # Build the mapping JSON first — validate before touching any files
    local map_json="{}"
    declare -A email_map
    for k in "${!num_map[@]}"; do
        local email_for_num
        email_for_num=$(jq -r --arg n "$k" '.accounts[$n].email' "$SEQUENCE_FILE")
        email_map[$k]="$email_for_num"
        map_json=$(jq -n --argjson obj "$map_json" --arg k "$k" --argjson v "${num_map[$k]}" '$obj + {($k): $v}')
    done

    local new_active=$active_num
    [[ -n "${num_map[$active_num]+x}" ]] && new_active=${num_map[$active_num]}

    local seq_json
    seq_json=$(printf '%s\n' "${new_sequence[@]}" | jq -s '.')

    # Pre-validate: build the new sequence.json content BEFORE renaming files
    local updated_sequence
    updated_sequence=$(jq --argjson seq "$seq_json" --argjson active "$new_active" --argjson map "$map_json" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .sequence = $seq |
        .activeAccountNumber = $active |
        .lastUpdated = $now |
        .accounts = (
            .accounts | to_entries | map(
                .key = (if $map[.key] != null then ($map[.key] | tostring) else .key end) |
                .
            ) | from_entries
        )
    ' "$SEQUENCE_FILE") || {
        log_error "Failed to build updated sequence. No changes made."
        complete_progress
        return 1
    }

    # Validate the generated JSON before proceeding
    if ! echo "$updated_sequence" | jq empty 2>/dev/null; then
        log_error "Generated invalid JSON. No changes made."
        complete_progress
        return 1
    fi

    # Update bindings to reference new account numbers
    updated_sequence=$(echo "$updated_sequence" | jq --argjson map "$map_json" '
        .bindings = (.bindings // {} | with_entries(
            .value = (. as $v | if $map[$v | tostring] != null then ($map[$v | tostring] | tostring) else $v end)
        ))
    ')

    # Write sequence.json FIRST — if interrupted after this point,
    # credential files can be recovered by re-running reorder
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache

    # Now rename credential files (two-pass to avoid collisions)
    # Pass 1: rename to temp names
    local rename_failed=false
    for old_num in "${!num_map[@]}"; do
        local new_num=${num_map[$old_num]}
        [[ "$old_num" == "$new_num" ]] && continue

        local email
        email="${email_map[$old_num]}"

        case "$platform" in
            macos)
                local creds
                creds=$(security find-generic-password -s "Claude Code-Account-${old_num}-${email}" -w 2>/dev/null || echo "")
                if [[ -n "$creds" ]]; then
                    if ! security add-generic-password -U -s "Claude Code-Account-tmp-${old_num}-${email}" -a "$USER" -w "$creds" 2>/dev/null; then
                        log_warning "Failed to create temp Keychain entry for Account-${old_num} (${email})"
                        rename_failed=true
                        continue
                    fi
                    # Verify temp entry was created before deleting original
                    if security find-generic-password -s "Claude Code-Account-tmp-${old_num}-${email}" -w >/dev/null 2>&1; then
                        security delete-generic-password -s "Claude Code-Account-${old_num}-${email}" 2>/dev/null || true
                    else
                        log_warning "Temp Keychain entry not found after create for Account-${old_num} — keeping original"
                        rename_failed=true
                    fi
                fi
                ;;
            linux|wsl)
                local old_cred="$BACKUP_DIR/credentials/.claude-credentials-${old_num}-${email}.json"
                if [[ -f "$old_cred" ]]; then
                    mv "$old_cred" "$BACKUP_DIR/credentials/.claude-credentials-tmp-${old_num}-${email}.json"
                fi
                ;;
        esac
        local old_conf="$BACKUP_DIR/configs/.claude-config-${old_num}-${email}.json"
        if [[ -f "$old_conf" ]]; then
            mv "$old_conf" "$BACKUP_DIR/configs/.claude-config-tmp-${old_num}-${email}.json"
        fi
    done

    if [[ "$rename_failed" == "true" ]]; then
        log_warning "Some Keychain renames failed — backup data may be inconsistent with sequence.json"
        log_warning "Run 'ccm doctor' to check account health"
    fi

    # Pass 2: rename from temp to new names
    for old_num in "${!num_map[@]}"; do
        local new_num=${num_map[$old_num]}
        [[ "$old_num" == "$new_num" ]] && continue

        local email
        email="${email_map[$old_num]}"

        case "$platform" in
            macos)
                local creds
                creds=$(security find-generic-password -s "Claude Code-Account-tmp-${old_num}-${email}" -w 2>/dev/null || echo "")
                if [[ -n "$creds" ]]; then
                    if ! security add-generic-password -U -s "Claude Code-Account-${new_num}-${email}" -a "$USER" -w "$creds" 2>/dev/null; then
                        log_warning "Failed to rename Keychain entry from tmp-${old_num} to Account-${new_num} (${email})"
                        rename_failed=true
                        continue
                    fi
                    # Verify new entry was created before deleting temp
                    if security find-generic-password -s "Claude Code-Account-${new_num}-${email}" -w >/dev/null 2>&1; then
                        security delete-generic-password -s "Claude Code-Account-tmp-${old_num}-${email}" 2>/dev/null || true
                    else
                        log_warning "New Keychain entry not found after create for Account-${new_num} — keeping temp entry"
                        rename_failed=true
                    fi
                fi
                ;;
            linux|wsl)
                local tmp_cred="$BACKUP_DIR/credentials/.claude-credentials-tmp-${old_num}-${email}.json"
                if [[ -f "$tmp_cred" ]]; then
                    mv "$tmp_cred" "$BACKUP_DIR/credentials/.claude-credentials-${new_num}-${email}.json"
                fi
                ;;
        esac
        local tmp_conf="$BACKUP_DIR/configs/.claude-config-tmp-${old_num}-${email}.json"
        if [[ -f "$tmp_conf" ]]; then
            mv "$tmp_conf" "$BACKUP_DIR/configs/.claude-config-${new_num}-${email}.json"
        fi
    done

    if [[ "$rename_failed" == "true" ]]; then
        log_warning "Reorder completed with warnings — sequence.json updated but some backup data may need manual repair"
    fi

    complete_progress

    # Show new state
    echo "After:"
    local new_account_nums
    new_account_nums=$(jq -r '.sequence | sort | map(tostring) | .[]' "$SEQUENCE_FILE")
    while IFS= read -r num; do
        local email alias_name
        email=$(jq -r --arg n "$num" '.accounts[$n].email' "$SEQUENCE_FILE")
        alias_name=$(jq -r --arg n "$num" '.accounts[$n].alias // empty' "$SEQUENCE_FILE")
        local label="$email"
        [[ -n "$alias_name" ]] && label="$email [$alias_name]"
        local marker=""
        [[ "$num" == "$new_active" ]] && marker=" ${COLOR_GREEN}(active)${COLOR_RESET}"
        echo -e "  $num: $label$marker"
    done <<< "$new_account_nums"
    echo ""
    log_success "Accounts reordered successfully."
}

# Purpose: Binds a project directory to a specific account for auto-switching
# Parameters: [project-path] <account_identifier> OR "list" to show bindings
# Returns: 0 on success, 1 on failure
# Usage: cmd_bind . work | cmd_bind ~/project 2 | cmd_bind list
cmd_bind() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet."
        exit 1
    fi

    migrate_sequence_file

    # Handle "bind list"
    if [[ "${1:-}" == "list" ]]; then
        local bindings
        bindings=$(jq -r '.bindings // {} | to_entries[] | "\(.key)|\(.value)"' "$SEQUENCE_FILE" 2>/dev/null)

        echo -e "${COLOR_BOLD}Project Bindings:${COLOR_RESET}"
        echo ""

        if [[ -z "$bindings" ]]; then
            log_info "No project bindings configured."
            echo "Use 'ccm bind <path> <account>' to create one."
            return 0
        fi

        printf "  %-45s  %s\n" "Project" "Account"
        printf "  %-45s  %s\n" "-------" "-------"
        while IFS='|' read -r path account_num; do
            [[ -z "$path" ]] && continue
            local display_path
            display_path=$(truncate_path "$path")
            [[ ${#display_path} -gt 45 ]] && display_path="...${display_path: -42}"
            local email
            email=$(jq -r --arg n "$account_num" '.accounts[$n].email // "unknown"' "$SEQUENCE_FILE")
            local alias_name
            alias_name=$(jq -r --arg n "$account_num" '.accounts[$n].alias // empty' "$SEQUENCE_FILE")
            local account_label="$account_num: $email"
            [[ -n "$alias_name" ]] && account_label="$account_num: $email [$alias_name]"
            printf "  %-45s  %s\n" "$display_path" "$account_label"
        done <<< "$bindings"
        return 0
    fi

    # Parse arguments: [path] <account>
    local project_path account_identifier
    if [[ $# -lt 1 ]]; then
        log_error "Usage: ccm bind [project-path] <account_number|email|alias>"
        echo "       ccm bind list"
        exit 1
    elif [[ $# -eq 1 ]]; then
        project_path="."
        account_identifier="$1"
    else
        project_path="$1"
        account_identifier="$2"
    fi

    # Resolve project path to absolute
    local abs_path
    abs_path=$(cd "$project_path" 2>/dev/null && pwd)
    if [[ -z "$abs_path" ]]; then
        log_error "Directory not found: $project_path"
        exit 1
    fi

    # Resolve account
    local account_num
    account_num=$(resolve_account_identifier "$account_identifier")
    if [[ -z "$account_num" ]]; then
        log_error "No account found matching: $account_identifier"
        exit 1
    fi

    local email
    email=$(jq -r --arg n "$account_num" '.accounts[$n].email' "$SEQUENCE_FILE")

    # Update bindings
    local updated_sequence
    updated_sequence=$(jq --arg path "$abs_path" --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .bindings[$path] = ($num | tonumber | tostring) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache

    local display_path
    display_path=$(truncate_path "$abs_path")
    log_success "Bound $display_path → Account-$account_num ($email)"
    echo "  Running 'ccm switch' in this directory will auto-switch to this account."
    echo "  Tip: Add eval \"\$(ccm hook)\" to your shell rc for auto-switch on cd."
}

# Purpose: Removes a project-to-account binding
# Parameters: [project-path] (default: current directory)
# Returns: 0 on success, 1 on failure
# Usage: cmd_unbind | cmd_unbind ~/project
cmd_unbind() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet."
        exit 1
    fi

    migrate_sequence_file

    local project_path="${1:-.}"
    local abs_path
    abs_path=$(cd "$project_path" 2>/dev/null && pwd)
    if [[ -z "$abs_path" ]]; then
        log_error "Directory not found: $project_path"
        exit 1
    fi

    # Check if binding exists
    local existing
    existing=$(jq -r --arg path "$abs_path" '.bindings[$path] // empty' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -z "$existing" ]]; then
        local display_path
        display_path=$(truncate_path "$abs_path")
        log_info "No binding found for $display_path"
        return 0
    fi

    local updated_sequence
    updated_sequence=$(jq --arg path "$abs_path" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.bindings[$path]) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"
    invalidate_cache

    local display_path
    display_path=$(truncate_path "$abs_path")
    log_success "Removed binding for $display_path"
}

# Purpose: Outputs shell hook code for auto-switching accounts on directory change
# Parameters:
#   --isolated   Emit hook that uses CLAUDE_CONFIG_DIR per-shell (no global creds rewrite)
# Returns: 0 on success, outputs shell code to stdout
# Usage: eval "$(ccm hook)" | eval "$(ccm hook --isolated)"
cmd_hook() {
    local isolated=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --isolated) isolated=1 ;;
            *) log_error "Unknown option: $arg"; return 1 ;;
        esac
    done

    # Detect current shell from parent process
    local parent_shell
    parent_shell=$(ps -o comm= -p "$PPID" 2>/dev/null | sed 's/^-//')

    # Common preamble: state + _ccm_load_bindings
    cat << 'HOOK_PREAMBLE'
# CCM Auto-Switch Hook — switches Claude Code account when entering a bound directory
# Generated by: ccm hook
# Add to your shell rc: eval "$(ccm hook)"

# Cache: associative array of path → account number
typeset -gA _ccm_bindings 2>/dev/null || declare -gA _ccm_bindings 2>/dev/null || declare -A _ccm_bindings
_ccm_active_account=""
_ccm_seq_file="${HOME}/.claude-switch-backup/sequence.json"
_ccm_seq_mtime=""

# Purpose: Loads bindings from sequence.json into _ccm_bindings array
# Only re-reads if the file mtime has changed
_ccm_load_bindings() {
    [[ -f "$_ccm_seq_file" ]] || return

    # Check mtime to avoid unnecessary reads
    local current_mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        current_mtime=$(stat -f %m "$_ccm_seq_file" 2>/dev/null)
    else
        current_mtime=$(stat -c %Y "$_ccm_seq_file" 2>/dev/null)
    fi

    [[ "$current_mtime" == "$_ccm_seq_mtime" ]] && return
    _ccm_seq_mtime="$current_mtime"

    # Reset and reload
    _ccm_bindings=()
    _ccm_active_account=$(command jq -r '.activeAccountNumber // empty' "$_ccm_seq_file" 2>/dev/null)

    local pairs
    pairs=$(command jq -r '.bindings // {} | to_entries[] | "\(.key)\t\(.value)"' "$_ccm_seq_file" 2>/dev/null)
    [[ -z "$pairs" ]] && return

    # NOTE: zsh stores associative keys literally including quotes when using
    # `arr["$k"]=v`. Use unquoted subscript so bash and zsh agree on the key.
    local path acct
    while IFS=$'\t' read -r path acct; do
        _ccm_bindings[$path]="$acct"
    done <<< "$pairs"
}

HOOK_PREAMBLE

    # Check-binding body — two variants depending on isolation mode
    if (( isolated )); then
        cat << 'HOOK_ISOLATED'
# Purpose: On cd into a bound directory, activate that account's isolated profile
# by setting CLAUDE_CONFIG_DIR in THIS shell only. Never rewrites global credentials,
# so concurrent terminals cannot clobber each other.
_ccm_check_binding() {
    _ccm_load_bindings

    [[ ${#_ccm_bindings[@]} -eq 0 ]] && return

    local dir="$PWD"
    while [[ -n "$dir" ]]; do
        if [[ -n "${_ccm_bindings[$dir]+x}" ]]; then
            local bound_account="${_ccm_bindings[$dir]}"
            if [[ "$bound_account" != "$_ccm_active_account" ]]; then
                local profile_path
                profile_path=$(command ccm switch --isolated --quiet "$bound_account" 2>/dev/null)
                if [[ -n "$profile_path" && -d "$profile_path" ]]; then
                    export CLAUDE_CONFIG_DIR="$profile_path"
                    _ccm_active_account="$bound_account"
                    echo "[ccm] Isolated profile active: ${profile_path##*/} (account $bound_account)"
                else
                    echo "[ccm] Failed to activate isolated profile for account $bound_account" >&2
                fi
            fi
            return 0
        fi
        [[ "$dir" == "/" ]] && break
        dir="${dir%/*}"
        [[ -z "$dir" ]] && dir="/"
    done
}

HOOK_ISOLATED
    else
        cat << 'HOOK_GLOBAL'
# Purpose: On cd into a bound directory, run 'ccm switch' (rewrites global credentials)
_ccm_check_binding() {
    _ccm_load_bindings

    [[ ${#_ccm_bindings[@]} -eq 0 ]] && return

    local dir="$PWD"
    while [[ -n "$dir" ]]; do
        if [[ -n "${_ccm_bindings[$dir]+x}" ]]; then
            local bound_account="${_ccm_bindings[$dir]}"
            if [[ "$bound_account" != "$_ccm_active_account" ]]; then
                echo "[ccm] Auto-switching to account $bound_account for $(basename "$dir")..."
                command ccm switch "$bound_account" && _ccm_active_account="$bound_account"
            fi
            return 0
        fi
        [[ "$dir" == "/" ]] && break
        dir="${dir%/*}"
        [[ -z "$dir" ]] && dir="/"
    done
}

HOOK_GLOBAL
    fi

    cat << 'HOOK_TAIL'
# Load bindings once at shell startup
_ccm_load_bindings
HOOK_TAIL

    # Output the appropriate hook for the shell
    case "$parent_shell" in
        *zsh*)
            cat << 'ZSH_EOF'

# Zsh: use chpwd hook (called automatically on directory change)
autoload -Uz add-zsh-hook 2>/dev/null
if typeset -f add-zsh-hook > /dev/null 2>&1; then
    add-zsh-hook chpwd _ccm_check_binding
else
    chpwd_functions+=(_ccm_check_binding)
fi
ZSH_EOF
            ;;
        *)
            cat << 'BASH_EOF'

# Bash: wrap cd/pushd/popd to trigger the check
_ccm_cd() { builtin cd "$@" && _ccm_check_binding; }
_ccm_pushd() { builtin pushd "$@" && _ccm_check_binding; }
_ccm_popd() { builtin popd "$@" && _ccm_check_binding; }
alias cd='_ccm_cd'
alias pushd='_ccm_pushd'
alias popd='_ccm_popd'
BASH_EOF
            ;;
    esac
}

# Export accounts to encrypted archive
cmd_export() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: ccm export <output_path>"
        exit 1
    fi

    local output_path="$1"

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts to export"
        exit 1
    fi

    migrate_sequence_file

    show_progress "Creating export archive"

    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT

    # Copy sequence file
    cp "$SEQUENCE_FILE" "$temp_dir/sequence.json"

    # Copy configs
    cp -r "$BACKUP_DIR/configs" "$temp_dir/" 2>/dev/null || true

    # Export credentials based on platform
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            # Export macOS keychain entries
            local creds_dir="$temp_dir/credentials"
            mkdir -p "$creds_dir"

            while IFS= read -r line; do
                local num email
                num=$(echo "$line" | jq -r '.num')
                email=$(echo "$line" | jq -r '.email')

                local creds
                creds=$(read_account_credentials "$num" "$email")
                if [[ -n "$creds" ]]; then
                    echo "$creds" > "$creds_dir/.claude-credentials-${num}-${email}.json"
                    chmod 600 "$creds_dir/.claude-credentials-${num}-${email}.json"
                fi
            done < <(jq -c '.accounts | to_entries[] | {num: .key, email: .value.email}' "$SEQUENCE_FILE")
            ;;
        linux|wsl)
            # Copy credential files directly
            cp -r "$BACKUP_DIR/credentials" "$temp_dir/" 2>/dev/null || true
            ;;
    esac

    # Create tar archive
    tar -czf "$output_path" -C "$temp_dir" . 2>/dev/null
    complete_progress

    log_success "Exported to: $output_path"
    log_warning "Keep this file secure - it contains authentication credentials"
}

# Import accounts from archive
cmd_import() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: ccm import <archive_path>"
        exit 1
    fi

    local archive_path="$1"

    if [[ ! -f "$archive_path" ]]; then
        log_error "Archive file not found: $archive_path"
        exit 1
    fi

    echo -e -n "${COLOR_YELLOW}This will merge imported accounts with existing ones. Continue?${COLOR_RESET} [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        exit 0
    fi

    setup_directories
    init_sequence_file

    show_progress "Extracting archive"
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT

    tar -xzf "$archive_path" -C "$temp_dir" 2>/dev/null || {
        log_error "Failed to extract archive"
        exit 1
    }
    complete_progress

    if [[ ! -f "$temp_dir/sequence.json" ]]; then
        log_error "Invalid archive: missing sequence.json"
        exit 1
    fi

    show_progress "Importing accounts"

    # Merge sequence files
    local imported_sequence current_sequence merged_sequence
    imported_sequence=$(cat "$temp_dir/sequence.json")
    current_sequence=$(cat "$SEQUENCE_FILE")

    # Import each account
    local platform
    platform=$(detect_platform)

    while IFS= read -r line; do
        local num email
        num=$(echo "$line" | jq -r '.num')
        email=$(echo "$line" | jq -r '.email')

        # Check if account already exists
        if account_exists "$email"; then
            log_info "Skipping existing account: $email"
            continue
        fi

        # Get next available account number
        local new_num
        new_num=$(get_next_account_number)

        # Import config
        local config_file="$temp_dir/configs/.claude-config-${num}-${email}.json"
        if [[ -f "$config_file" ]]; then
            write_account_config "$new_num" "$email" "$(cat "$config_file")"
        fi

        # Import credentials
        case "$platform" in
            macos)
                local cred_file="$temp_dir/credentials/.claude-credentials-${num}-${email}.json"
                if [[ -f "$cred_file" ]]; then
                    write_account_credentials "$new_num" "$email" "$(cat "$cred_file")"
                fi
                ;;
            linux|wsl)
                local cred_file="$temp_dir/credentials/.claude-credentials-${num}-${email}.json"
                if [[ -f "$cred_file" ]]; then
                    cp "$cred_file" "$BACKUP_DIR/credentials/.claude-credentials-${new_num}-${email}.json"
                    chmod 600 "$BACKUP_DIR/credentials/.claude-credentials-${new_num}-${email}.json"
                fi
                ;;
        esac

        # Add to sequence
        local account_data
        account_data=$(echo "$imported_sequence" | jq -r --arg num "$num" '.accounts[$num]')

        local updated_sequence
        updated_sequence=$(jq --arg num "$new_num" --argjson data "$account_data" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
            .accounts[$num] = $data |
            .accounts[$num].added = $now |
            .sequence += [$num | tonumber] |
            .lastUpdated = $now
        ' "$SEQUENCE_FILE")

        write_json "$SEQUENCE_FILE" "$updated_sequence"

        log_info "Imported: $email as Account-$new_num"
    done < <(echo "$imported_sequence" | jq -c '.accounts | to_entries[] | {num: .key, email: .value.email}')

    invalidate_cache
    complete_progress

    log_success "Import completed"
}

# Relocate project sessions
# Purpose: Updates Claude Code project session references when a project folder is moved
# Parameters: $1 = old project path, $2 = new project path
# Returns: Exit code 0 on success, 1 on failure
# Usage: session_relocate /old/path /new/path
# Preconditions: Old path must have a corresponding session directory in ~/.claude/projects/
session_relocate() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: ccm session relocate <old_path> <new_path>"
        echo ""
        echo "Relocates Claude Code project sessions when you move a project folder."
        echo "Updates session history, memory, and all internal path references."
        echo ""
        echo "Examples:"
        echo "  ccm session relocate ~/projects/my-app ~/work/my-app"
        echo "  ccm session relocate /Users/me/old-location /Users/me/new-location"
        exit 1
    fi

    local old_path new_path
    old_path="$(cd "$1" 2>/dev/null && pwd || echo "$1")"
    new_path="$(cd "$2" 2>/dev/null && pwd || echo "$2")"

    # Validate inputs
    if [[ "$old_path" == "$new_path" ]]; then
        log_error "Old and new paths are identical: $old_path"
        exit 1
    fi

    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR"
        exit 1
    fi

    # Encode paths to Claude's directory naming convention (/ becomes -)
    local old_encoded new_encoded
    old_encoded=$(echo "$old_path" | sed 's|/|-|g')
    new_encoded=$(echo "$new_path" | sed 's|/|-|g')

    local old_session_dir="$CLAUDE_PROJECTS_DIR/$old_encoded"
    local new_session_dir="$CLAUDE_PROJECTS_DIR/$new_encoded"

    # Verify old session directory exists
    if [[ ! -d "$old_session_dir" ]]; then
        log_error "No session data found for: $old_path"
        log_info "Expected session directory: $old_session_dir"
        echo ""
        echo "Available project sessions:"
        ls -1 "$CLAUDE_PROJECTS_DIR" | head -20
        exit 1
    fi

    # Check if target session directory already exists
    if [[ -d "$new_session_dir" ]]; then
        log_warning "Session directory already exists for new path: $new_path"
        echo -n "Merge into existing session directory? (y/N): "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "Relocation cancelled."
            exit 0
        fi
    fi

    # Verify new path exists on disk
    if [[ ! -d "$new_path" ]]; then
        log_warning "New path does not exist yet: $new_path"
        echo -n "Continue anyway? (y/N): "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "Relocation cancelled."
            exit 0
        fi
    fi

    echo ""
    log_info "Relocating project sessions"
    log_step "From: ${COLOR_YELLOW}$old_path${COLOR_RESET}"
    log_step "  To: ${COLOR_GREEN}$new_path${COLOR_RESET}"
    echo ""

    # Count files to be processed
    local session_count
    session_count=$(find "$old_session_dir" -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')
    local memory_exists="no"
    if [[ -d "$old_session_dir/memory" ]]; then
        memory_exists="yes"
    fi

    log_info "Found $session_count session file(s), memory: $memory_exists"

    # Step 1: Rename/move the session directory
    show_progress "Moving session directory"
    if [[ -d "$new_session_dir" ]]; then
        # Merge: copy files from old into new (no-clobber preserves existing destination files)
        find "$old_session_dir" -maxdepth 1 -type f | while IFS= read -r src_file; do
            local dest_file="$new_session_dir/$(basename "$src_file")"
            [[ -e "$dest_file" ]] || cp "$src_file" "$dest_file"
        done
        # Copy memory directory contents with no-clobber
        if [[ -d "$old_session_dir/memory" ]]; then
            mkdir -p "$new_session_dir/memory"
            find "$old_session_dir/memory" -type f | while IFS= read -r src_file; do
                local dest_file="$new_session_dir/memory/$(basename "$src_file")"
                [[ -e "$dest_file" ]] || cp "$src_file" "$dest_file"
            done
        fi
        rm -rf "$old_session_dir"
    else
        mv "$old_session_dir" "$new_session_dir"
    fi
    complete_progress

    # Step 2: Update cwd references in all session .jsonl files
    local files_updated=0
    local temp_file
    local file_index=0

    # Collect session files into an array first (avoids subshell issues)
    local session_files=()
    while IFS= read -r -d '' f; do
        session_files+=("$f")
    done < <(find "$new_session_dir" -name "*.jsonl" -type f -print0 2>/dev/null)

    local total_files=${#session_files[@]}
    if [[ $total_files -gt 0 ]]; then
        log_info "Updating path references in $total_files session file(s)..."
        for session_file in "${session_files[@]}"; do
            ((file_index++))
            printf "\r  [%d/%d] %s" "$file_index" "$total_files" "$(basename "$session_file")"
            if grep -qF "$old_path" "$session_file" 2>/dev/null; then
                temp_file=$(mktemp)
                sed "s|$old_path|$new_path|g" "$session_file" > "$temp_file"
                mv "$temp_file" "$session_file"
                ((files_updated++))
            fi
        done
        printf "\n"
    fi

    # Step 3: Update memory files if they contain path references
    local memory_updated=0
    if [[ -d "$new_session_dir/memory" ]]; then
        local mem_files=()
        while IFS= read -r -d '' f; do
            mem_files+=("$f")
        done < <(find "$new_session_dir/memory" -type f -print0 2>/dev/null)

        if [[ ${#mem_files[@]} -gt 0 ]]; then
            log_info "Updating ${#mem_files[@]} memory file(s)..."
            for mem_file in "${mem_files[@]}"; do
                if grep -qF "$old_path" "$mem_file" 2>/dev/null; then
                    temp_file=$(mktemp)
                    sed "s|$old_path|$new_path|g" "$mem_file" > "$temp_file"
                    mv "$temp_file" "$mem_file"
                    ((memory_updated++))
                fi
            done
        fi
    fi

    echo ""
    log_success "Relocation complete!"
    echo ""
    log_info "Summary:"
    log_step "Session directory moved: $old_encoded -> $new_encoded"
    log_step "Session files updated: $files_updated"
    log_step "Memory files updated: $memory_updated"
    echo ""
    log_info "Your Claude Code sessions and memory for this project are now"
    log_info "accessible from: ${COLOR_GREEN}$new_path${COLOR_RESET}"
}

# Show version
# Purpose: Prints the CCM version string
# Parameters: None
# Returns: None (prints to stdout)
# Usage: show_version
show_version() { echo "ccm (Claude Code Manager) v${CCM_VERSION}"; }

# Show help
# Purpose: Displays help text for ccm or a specific subcommand module
# Parameters:
#   $1 (optional) - subcommand name for module-specific help
# Returns: None (prints to stdout)
# Usage: show_help  OR  show_help session
show_help() {
    local topic="${1:-}"

    case "$topic" in
        doctor)
            echo -e "${COLOR_BOLD}ccm doctor — Health Diagnostics${COLOR_RESET}"
            echo ""
            echo "Usage: ccm doctor [--fix]"
            echo ""
            echo "Scans ~/.claude/ for health issues including stale locks, debug logs,"
            echo "plugin cache, telemetry, todos, paste cache, file history, shell"
            echo "snapshots, orphaned sessions, total disk size, tmp output files,"
            echo "orphaned processes, and hook async configuration."
            echo ""
            echo -e "${COLOR_BOLD}Options:${COLOR_RESET}"
            echo "  --fix     Auto-fix safe issues (remove old logs, stale locks, etc.)"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm doctor             # Report issues only"
            echo "  ccm doctor --fix       # Fix safe issues automatically"
            ;;
        clean)
            echo -e "${COLOR_BOLD}ccm clean — Targeted Cleanup${COLOR_RESET}"
            echo ""
            echo "Usage: ccm clean <target> [options]"
            echo ""
            echo -e "${COLOR_BOLD}Targets:${COLOR_RESET}"
            echo "  cache                    Clean plugin cache (interactive)"
            echo "  debug [--days N]         Remove debug logs older than N days (default: 30)"
            echo "  telemetry                Remove all telemetry files"
            echo "  todos [--days N]         Remove todo files older than N days (default: 30)"
            echo "  history [--keep N]       Trim history.jsonl to last N entries (default: 1000)"
            echo "  tmp [--days N]           Remove tmp output files older than N days (default: 1)"
            echo "  processes                Kill orphaned Claude subagent processes"
            echo "  all [--dry-run]          Run all clean targets"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm clean debug --days 7"
            echo "  ccm clean telemetry"
            echo "  ccm clean history --keep 500"
            echo "  ccm clean tmp --days 3"
            echo "  ccm clean processes"
            echo "  ccm clean all --dry-run"
            echo "  ccm clean all"
            ;;
        hook)
            echo -e "${COLOR_BOLD}ccm hook — Shell Auto-Switch Hook${COLOR_RESET}"
            echo ""
            echo "Usage: eval \"\$(ccm hook)\"             # global mode (rewrites ~/.claude creds)"
            echo "       eval \"\$(ccm hook --isolated)\"  # isolated mode (CLAUDE_CONFIG_DIR per shell)"
            echo ""
            echo "Outputs shell code that auto-switches your Claude Code account"
            echo "when you cd into a directory with a project binding."
            echo ""
            echo -e "${COLOR_BOLD}Modes:${COLOR_RESET}"
            echo "  default   Runs 'ccm switch' on cd. Rewrites the global active account."
            echo "            Simple, but concurrent terminals in different bound dirs will"
            echo "            clobber each other's credentials."
            echo ""
            echo "  --isolated"
            echo "            Sets CLAUDE_CONFIG_DIR to a per-account profile dir in the"
            echo "            current shell only. Each terminal stays on its own account —"
            echo "            no global credential rewrites, safe for concurrent use."
            echo "            Profiles are created on demand under ~/.claude-switch-backup/profiles/."
            echo ""
            echo -e "${COLOR_BOLD}How it works:${COLOR_RESET}"
            echo "  1. Loads bindings from sequence.json into memory at shell startup"
            echo "  2. On every cd, checks if the new directory (or parent) has a binding"
            echo "  3. Either runs 'ccm switch' (global) or exports CLAUDE_CONFIG_DIR (isolated)"
            echo ""
            echo -e "${COLOR_BOLD}Performance:${COLOR_RESET}"
            echo "  Startup: ~30ms (one jq call to load bindings)"
            echo "  Per cd:  ~0ms when no binding change; one ccm call on transition"
            echo "  Re-reads sequence.json only when file mtime changes"
            echo ""
            echo -e "${COLOR_BOLD}Setup:${COLOR_RESET}"
            echo "  # Add to ~/.zshrc or ~/.bashrc:"
            echo "  eval \"\$(ccm hook --isolated)\"   # recommended if you use concurrent terminals"
            echo ""
            echo -e "${COLOR_BOLD}Shell support:${COLOR_RESET}"
            echo "  Zsh:  Uses chpwd hook (native directory change event)"
            echo "  Bash: Wraps cd/pushd/popd with auto-switch check"
            ;;
        profiles)
            echo -e "${COLOR_BOLD}ccm profiles — Isolated Profile Management${COLOR_RESET}"
            echo ""
            echo "Usage: ccm profiles <subcommand>"
            echo ""
            echo -e "${COLOR_BOLD}Subcommands:${COLOR_RESET}"
            echo "  list                     List all isolated profiles with status"
            echo "  sync <name>              Sync settings/MCP config to a profile"
            echo "  delete <name>            Remove an isolated profile"
            echo ""
            echo "Profiles are created via 'ccm switch --isolated <account>'."
            echo "Each profile uses CLAUDE_CONFIG_DIR for true concurrent sessions."
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm switch --isolated work     # create and activate profile"
            echo "  ccm profiles list              # show all profiles"
            echo "  ccm profiles sync work         # sync settings to profile"
            echo "  ccm profiles delete work       # remove profile"
            ;;
        watch)
            echo -e "${COLOR_BOLD}ccm watch — Rate Limit Watcher${COLOR_RESET}"
            echo ""
            echo "Usage: ccm watch [options]"
            echo ""
            echo -e "${COLOR_BOLD}Options:${COLOR_RESET}"
            echo "  --threshold N            Notify when 5h usage hits N% (default: 85)"
            echo "  --auto                   Auto-switch to next available account"
            echo "  stop                     Stop the background watcher"
            echo "  status                   Show current watcher state"
            echo ""
            echo "Requires: ccm statusline installed (provides rate limit data)."
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm watch --threshold 85          # notify at 85%"
            echo "  ccm watch --threshold 80 --auto   # auto-switch at 80%"
            echo "  ccm watch stop                    # stop watching"
            echo "  ccm watch status                  # show watcher state"
            ;;
        recover)
            echo -e "${COLOR_BOLD}ccm recover — Error Recovery${COLOR_RESET}"
            echo ""
            echo "Usage: ccm recover"
            echo ""
            echo "Detects and fixes inconsistent credential state from"
            echo "interrupted switch or reorder operations."
            echo ""
            echo -e "${COLOR_BOLD}Checks:${COLOR_RESET}"
            echo "  sequence.json vs credential files"
            echo "  Keychain entries vs sequence.json (macOS)"
            echo "  Active account vs credential state"
            echo "  Profile directory validity"
            ;;
        setup)
            echo -e "${COLOR_BOLD}ccm setup — First-Run Setup Wizard${COLOR_RESET}"
            echo ""
            echo "Usage: ccm setup"
            echo ""
            echo "Interactive wizard that guides you through:"
            echo "  1. Dependency check (bash 4.4+, jq, curl)"
            echo "  2. Claude Code detection"
            echo "  3. Auto-import current account"
            echo "  4. Statusline installation"
            echo "  5. Shell hook setup"
            echo "  6. Project initialization"
            ;;
        session)
            echo -e "${COLOR_BOLD}ccm session — Session Management${COLOR_RESET}"
            echo ""
            echo "Usage: ccm session <subcommand>"
            echo ""
            echo -e "${COLOR_BOLD}Subcommands:${COLOR_RESET}"
            echo "  list                     List all Claude Code project sessions"
            echo "  info <project-path>      Show detailed info for a project's sessions"
            echo "  summary [path] [--limit N]  Show what happened in each session (topic, tools, files)"
            echo "  relocate <old> <new>     Relocate project sessions after moving a folder"
            echo "  clean [--dry-run]        Remove orphaned sessions (projects no longer on disk)"
            echo "  search <query> [--limit N]  Full-text search across sessions (default: 10)"
            echo "  archive [--older-than Nd] [--project <path>] [--dry-run]"
            echo "                           Compress old sessions to tar.gz archives"
            echo "  restore <archive-name>   Restore sessions from an archive"
            echo "  archives                 List all saved archives"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm session list"
            echo "  ccm session info ."
            echo "  ccm session info ~/projects/my-app"
            echo "  ccm session relocate ~/old/project ~/new/project"
            echo "  ccm session clean --dry-run"
            echo "  ccm session clean"
            echo "  ccm session search 'error handling'"
            echo "  ccm session search 'API' --limit 5"
            echo "  ccm session archive --older-than 30d"
            echo "  ccm session archive --dry-run"
            echo "  ccm session archives"
            echo "  ccm session restore my-project-20260401.tar.gz"
            ;;
        env)
            echo -e "${COLOR_BOLD}ccm env — Environment Management${COLOR_RESET}"
            echo ""
            echo "Usage: ccm env <subcommand>"
            echo ""
            echo -e "${COLOR_BOLD}Subcommands:${COLOR_RESET}"
            echo "  snapshot [name]          Capture current environment state"
            echo "  restore <name> [--force] Restore a named environment snapshot"
            echo "  list                     List all saved snapshots"
            echo "  delete <name>            Delete a saved snapshot"
            echo "  audit                    Audit MCP servers for CLI alternatives"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm env snapshot before-upgrade"
            echo "  ccm env restore before-upgrade"
            echo "  ccm env list"
            echo "  ccm env delete before-upgrade"
            echo "  ccm env audit"
            ;;
        usage)
            echo -e "${COLOR_BOLD}ccm usage — Usage Statistics${COLOR_RESET}"
            echo ""
            echo "Usage: ccm usage <subcommand>"
            echo ""
            echo -e "${COLOR_BOLD}Subcommands:${COLOR_RESET}"
            echo "  summary                  Show usage summary (projects, sessions, disk)"
            echo "  top [--count N]          Show top N projects by disk usage (default: 10)"
            echo "  history [--days N] [--project <path>]"
            echo "                           Token usage breakdown by project and day (default: 7)"
            echo "  sessions [--project <path>] [--days N] [--limit N]"
            echo "                           Per-session tokens, cost, and duration (default: cwd)"
            echo "  dashboard [--days N] [--account <name>]"
            echo "                           Per-account token usage dashboard"
            echo "  compare [--days N]       Side-by-side account comparison"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm usage summary"
            echo "  ccm usage top"
            echo "  ccm usage top --count 5"
            echo "  ccm usage history"
            echo "  ccm usage history --days 30"
            echo "  ccm usage history --project ~/my-app"
            echo "  ccm usage sessions"
            echo "  ccm usage sessions --project ~/my-app"
            echo "  ccm usage sessions --days 7 --limit 50"
            echo "  ccm usage dashboard"
            echo "  ccm usage dashboard --days 30 --account work"
            echo "  ccm usage compare"
            ;;
        init)
            echo -e "${COLOR_BOLD}ccm init — Project Setup${COLOR_RESET}"
            echo ""
            echo "Usage: ccm init [--force]"
            echo ""
            echo "Auto-generates .claudeignore based on detected project type."
            echo "Detects: Node, Python, Go, Rust, Java, Ruby, PHP, .NET, Dart, Swift."
            echo ""
            echo "Options:"
            echo "  --force     Overwrite existing .claudeignore"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm init                 # generate .claudeignore"
            echo "  ccm init --force         # regenerate from scratch"
            ;;
        statusline)
            echo -e "${COLOR_BOLD}ccm statusline — Claude Code Status Bar${COLOR_RESET}"
            echo ""
            echo "Usage: ccm statusline [install|remove]"
            echo ""
            echo "Installs a statusline at the bottom of Claude Code showing:"
            echo "  [model] context% bar | active CCM account | session cost"
            echo ""
            echo -e "${COLOR_BOLD}Commands:${COLOR_RESET}"
            echo "  install              Install and configure the statusline (default)"
            echo "  remove               Remove statusline script and settings"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm statusline               # install"
            echo "  ccm statusline install        # same as above"
            echo "  ccm statusline remove         # uninstall"
            ;;
        permissions)
            echo -e "${COLOR_BOLD}ccm permissions — Permission Rules Management${COLOR_RESET}"
            echo ""
            echo "Usage: ccm permissions <subcommand>"
            echo ""
            echo -e "${COLOR_BOLD}Subcommands:${COLOR_RESET}"
            echo "  audit [--fix]            Scan for duplicates, contradictions, and bloat"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm permissions audit          # report issues"
            echo "  ccm permissions audit --fix    # auto-remove duplicates"
            ;;
        *)
            echo -e "${COLOR_GREEN}"
            echo ' ██████╗ ██████╗███╗   ███╗'
            echo '██╔════╝██╔════╝████╗ ████║'
            echo '██║     ██║     ██╔████╔██║'
            echo '██║     ██║     ██║╚██╔╝██║'
            echo '╚██████╗╚██████╗██║ ╚═╝ ██║'
            echo -e ' ╚═════╝ ╚═════╝╚═╝     ╚═╝'"${COLOR_RESET}"
            echo ""
            echo -e "${COLOR_BOLD}The power-user toolkit for Claude Code${COLOR_RESET}  ${COLOR_GREEN}v${CCM_VERSION}${COLOR_RESET}"
            echo ""
            echo "Usage: ccm <command> [options]"
            echo ""
            echo -e "${COLOR_BOLD}Account Management:${COLOR_RESET}"
            echo "  add                                Add current account to managed accounts"
            echo "  remove <num|email|alias>           Remove an account"
            echo "  list                               List all managed accounts"
            echo "  alias <num|email> <alias>          Set friendly name for an account"
            echo "  reorder <from> <to>                Reorder account positions"
            echo ""
            echo -e "${COLOR_BOLD}Switching:${COLOR_RESET}"
            echo "  switch [num|email|alias]           Switch account (next, specific, or project-bound)"
            echo "  switch --isolated <account>        Switch with CLAUDE_CONFIG_DIR isolation"
            echo "  bind [path] <account>              Bind project directory to an account"
            echo "  unbind [path]                      Remove project binding"
            echo "  bind list                          Show all project bindings"
            echo "  hook                               Output shell hook for auto-switch on cd"
            echo "  undo                               Undo last account switch"
            echo "  history                            Show account switch history"
            echo ""
            echo -e "${COLOR_BOLD}Profiles & Monitoring:${COLOR_RESET}"
            echo "  profiles <subcommand>              Manage isolated CLAUDE_CONFIG_DIR profiles"
            echo "  watch [--threshold N] [--auto]     Monitor rate limits, auto-switch accounts"
            echo ""
            echo -e "${COLOR_BOLD}Verification & Backup:${COLOR_RESET}"
            echo "  verify [num|email]                 Verify account backups"
            echo "  export <path>                      Export accounts to archive"
            echo "  import <path>                      Import accounts from archive"
            echo "  recover                            Fix inconsistent credential state"
            echo ""
            echo -e "${COLOR_BOLD}Modules:${COLOR_RESET}"
            echo "  session <subcommand>               Manage sessions (list|info|search|relocate|clean|archive)"
            echo "  env <subcommand>                   Environment snapshots & audit"
            echo "  usage <subcommand>                 Usage statistics, dashboard & reporting"
            echo ""
            echo -e "${COLOR_BOLD}Maintenance:${COLOR_RESET}"
            echo "  doctor [--fix]                     Diagnose and fix Claude Code health issues"
            echo "  clean <target> [--dry-run]         Clean up cache, logs, telemetry, tmp, processes"
            echo "  permissions <subcommand>           Audit and fix permission rules"
            echo ""
            echo -e "${COLOR_BOLD}Setup:${COLOR_RESET}"
            echo "  setup                              First-run setup wizard"
            echo "  init [--force]                     Generate .claudeignore for this project"
            echo "  statusline [install|remove]        Install CCM statusline in Claude Code"
            echo ""
            echo -e "${COLOR_BOLD}Other:${COLOR_RESET}"
            echo "  help [command]                     Show help (or help for a command)"
            echo "  version                            Show version"
            echo "  --no-color                         Disable colored output"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm setup"
            echo "  ccm add"
            echo "  ccm alias 1 work"
            echo "  ccm switch work"
            echo "  ccm switch --isolated work"
            echo "  ccm watch --threshold 85 --auto"
            echo "  ccm bind . work"
            echo "  ccm usage dashboard"
            echo "  ccm session archive --older-than 30d"
            echo "  ccm permissions audit"
            echo "  ccm clean tmp"
            echo "  ccm help profiles"
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Environment Snapshots & Audit Module
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Routes env subcommands to their implementations
# Parameters: $1 — subcommand (snapshot|restore|list|delete|audit), remaining args forwarded
# Returns: Exit code from dispatched subcommand
# Usage: cmd_env snapshot my-snap
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

# Purpose: Captures current Claude Code environment state into a named snapshot
# Parameters: $1 (optional) — snapshot name; auto-generated if omitted
# Returns: 0 on success, 1 on validation or write failure
# Usage: env_snapshot my-snap  OR  env_snapshot
env_snapshot() {
    local name="${1:-}"
    local snapshots_dir="$BACKUP_DIR/snapshots"
    local config_source
    config_source=$(get_claude_config_path)

    # Auto-generate name if none given
    if [[ -z "$name" ]]; then
        name="snapshot-$(date '+%Y-%m-%d-%H%M%S')"
    fi

    # Validate snapshot name
    if ! validate_snapshot_name "$name"; then
        log_error "Invalid snapshot name '$name'. Use only alphanumeric characters, dots, hyphens, and underscores."
        return 1
    fi

    local snap_dir="$snapshots_dir/$name"

    # Check for existing snapshot with same name
    if [[ -d "$snap_dir" ]]; then
        log_error "Snapshot '$name' already exists. Choose a different name or delete it first."
        return 1
    fi

    # Create snapshot directory with restricted permissions
    mkdir -p "$snap_dir"
    chmod 700 "$snap_dir"

    log_info "Creating snapshot '$name'..."

    # Define source files and their stored names
    local -a source_files=("$HOME/.claude/settings.json:settings.json")
    if [[ -f "$config_source" ]]; then
        source_files+=("$config_source:claude.json")
    fi
    source_files+=(
        "$HOME/.claude/CLAUDE.md:CLAUDE.md"
        "$HOME/.claude/.mcp.json:mcp.json"
    )

    local -a captured_files=()
    local files_json="[]"

    for entry in "${source_files[@]}"; do
        local source="${entry%%:*}"
        local stored="${entry##*:}"

        if [[ ! -f "$source" ]]; then
            continue
        fi

        if [[ "$stored" == "claude.json" ]]; then
            # Strip claude.json to only oauthAccount identity fields
            show_progress "Capturing $stored (stripped)"
            local stripped
            stripped=$(jq '{oauthAccount: {emailAddress: .oauthAccount.emailAddress, accountUuid: .oauthAccount.accountUuid, organizationName: .oauthAccount.organizationName}}' "$source" 2>/dev/null)
            if [[ $? -ne 0 ]] || [[ -z "$stripped" ]]; then
                log_warning "Failed to strip $source, skipping"
                continue
            fi
            echo "$stripped" > "$snap_dir/$stored"
            complete_progress
        else
            show_progress "Capturing $stored"
            cp "$source" "$snap_dir/$stored"
            complete_progress
        fi

        captured_files+=("$stored")
        files_json=$(echo "$files_json" | jq --arg src "$source" --arg st "$stored" '. + [{"source": $src, "stored": $st}]')
    done

    if [[ ${#captured_files[@]} -eq 0 ]]; then
        log_warning "No configuration files found to snapshot."
        rm -rf "$snap_dir"
        return 1
    fi

    # Write manifest
    local created
    created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local manifest
    manifest=$(jq -n --arg name "$name" --arg created "$created" --argjson files "$files_json" \
        '{name: $name, created: $created, files: $files}')
    echo "$manifest" > "$snap_dir/manifest.json"

    log_success "Snapshot '$name' created with ${#captured_files[@]} file(s)."
}

# Purpose: Restores a previously saved environment snapshot
# Parameters: $1 — snapshot name, $2 (optional) — --force to skip running check
# Returns: 0 on success, 1 on validation or restore failure
# Usage: env_restore my-snap  OR  env_restore my-snap --force
env_restore() {
    local name="${1:-}"
    local force=0
    local restore_warnings=0

    if [[ -z "$name" ]]; then
        log_error "Snapshot name required. Usage: ccm env restore <name> [--force]"
        return 1
    fi

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1 ;;
            *) log_error "Unknown option '$1'"; return 1 ;;
        esac
        shift
    done

    local snap_dir="$BACKUP_DIR/snapshots/$name"

    if [[ ! -d "$snap_dir" ]]; then
        log_error "Snapshot '$name' not found."
        return 1
    fi

    if [[ ! -f "$snap_dir/manifest.json" ]]; then
        log_error "Snapshot '$name' is missing its manifest. It may be corrupted."
        return 1
    fi

    # Check if Claude Code is running
    if is_claude_running && [[ "$force" -eq 0 ]]; then
        log_error "Claude Code is currently running. Close it first or use --force to override."
        return 1
    fi

    # Show what will be restored
    echo -e "${COLOR_BOLD}Snapshot '$name' contents:${COLOR_RESET}"
    local file_count
    file_count=$(jq -r '.files | length' "$snap_dir/manifest.json")
    local idx=0
    while [[ $idx -lt $file_count ]]; do
        local stored source
        stored=$(jq -r ".files[$idx].stored" "$snap_dir/manifest.json")
        source=$(jq -r ".files[$idx].source" "$snap_dir/manifest.json")
        echo "  $stored -> $source"
        idx=$((idx + 1))
    done

    # Prompt for confirmation
    echo ""
    read -r -p "Restore this snapshot? This will overwrite existing files. [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Restore cancelled."
        return 0
    fi

    # Restore each file
    idx=0
    while [[ $idx -lt $file_count ]]; do
        local stored source_file target_path
        stored=$(jq -r ".files[$idx].stored" "$snap_dir/manifest.json")
        source_file="$snap_dir/$stored"
        target_path=$(jq -r ".files[$idx].source" "$snap_dir/manifest.json")
        idx=$((idx + 1))

        if [[ ! -f "$source_file" ]]; then
            log_warning "Snapshot file '$stored' missing, skipping."
            continue
        fi

        # Ensure target directory exists
        local target_dir
        target_dir=$(dirname "$target_path")
        if [[ ! -d "$target_dir" ]]; then
            mkdir -p "$target_dir"
        fi

        if [[ "$stored" == "claude.json" ]]; then
            # Snapshots only store identity fields, so we must merge into an
            # existing config to preserve the current credentials/tokens.
            local merge_target="$target_path"
            if [[ ! -f "$merge_target" ]]; then
                local fallback_target
                fallback_target=$(get_claude_config_path)
                if [[ -f "$fallback_target" ]]; then
                    merge_target="$fallback_target"
                else
                    log_warning "Skipping claude.json restore: no existing config file found to preserve credentials."
                    restore_warnings=$((restore_warnings + 1))
                    continue
                fi
            fi

            target_dir=$(dirname "$merge_target")
            if [[ ! -d "$target_dir" ]]; then
                mkdir -p "$target_dir"
            fi

            show_progress "Merging $stored (preserving credentials)"
            local oauth_section
            oauth_section=$(jq '.oauthAccount' "$source_file" 2>/dev/null)
            if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
                log_warning "Skipping claude.json restore: snapshot is missing oauthAccount data."
                restore_warnings=$((restore_warnings + 1))
                continue
            fi
            local merged
            merged=$(jq --argjson oauth "$oauth_section" '.oauthAccount = ((.oauthAccount // {}) * $oauth)' "$merge_target" 2>/dev/null)
            if [[ -z "$merged" ]]; then
                log_warning "Skipping claude.json restore: existing config is invalid JSON at $merge_target."
                restore_warnings=$((restore_warnings + 1))
                continue
            fi
            write_json "$merge_target" "$merged"
            complete_progress
        else
            show_progress "Restoring $stored"
            cp "$source_file" "$target_path"
            complete_progress
        fi
    done

    if [[ "$restore_warnings" -gt 0 ]]; then
        log_warning "Snapshot '$name' restored with $restore_warnings warning(s)."
        return 1
    fi

    log_success "Snapshot '$name' restored successfully."
}

# Purpose: Lists all saved environment snapshots with metadata
# Parameters: None
# Returns: 0 (always succeeds; prints table or info message)
# Usage: env_list
env_list() {
    local snapshots_dir="$BACKUP_DIR/snapshots"

    if [[ ! -d "$snapshots_dir" ]]; then
        log_info "No snapshots found. Create one with: ccm env snapshot [name]"
        return 0
    fi

    # Collect snapshot data first to determine if any exist
    local found=0
    local output=""

    for snap_dir in "$snapshots_dir"/*/; do
        [[ -d "$snap_dir" ]] || continue
        local manifest="$snap_dir/manifest.json"
        [[ -f "$manifest" ]] || continue

        found=1
        local snap_name snap_created file_count snap_size_kb snap_size_bytes size_str
        snap_name=$(jq -r '.name' "$manifest")
        snap_created=$(jq -r '.created' "$manifest")
        file_count=$(jq -r '.files | length' "$manifest")
        snap_size_kb=$(du -sk "$snap_dir" 2>/dev/null | cut -f1)
        snap_size_bytes=$(( snap_size_kb * 1024 ))
        size_str=$(format_size "$snap_size_bytes")

        output+=$(printf "%-30s %-24s %-8s %-10s\n" "$snap_name" "$snap_created" "$file_count" "$size_str")
        output+=$'\n'
    done

    if [[ "$found" -eq 0 ]]; then
        log_info "No snapshots found. Create one with: ccm env snapshot [name]"
    else
        printf "${COLOR_BOLD}%-30s %-24s %-8s %-10s${COLOR_RESET}\n" "Name" "Created" "Files" "Size"
        printf "%-30s %-24s %-8s %-10s\n" "----" "-------" "-----" "----"
        printf "%s" "$output"
    fi
}

# Purpose: Deletes a named environment snapshot after confirmation
# Parameters: $1 — snapshot name
# Returns: 0 on success, 1 if not found or cancelled
# Usage: env_delete my-snap
env_delete() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        log_error "Snapshot name required. Usage: ccm env delete <name>"
        return 1
    fi

    local snap_dir="$BACKUP_DIR/snapshots/$name"

    if [[ ! -d "$snap_dir" ]]; then
        log_error "Snapshot '$name' not found."
        return 1
    fi

    read -r -p "Delete snapshot '$name'? This cannot be undone. [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Deletion cancelled."
        return 0
    fi

    rm -rf "$snap_dir"
    log_success "Snapshot '$name' deleted."
}

# Purpose: Audits MCP server configuration and suggests CLI alternatives to reduce overhead
# Parameters: None
# Returns: 0 (always succeeds; prints audit results)
# Usage: env_audit
env_audit() {
    local mcp_config="$HOME/.claude/.mcp.json"

    if [[ ! -f "$mcp_config" ]]; then
        log_info "No MCP configuration found at $mcp_config"
        return 0
    fi

    # Knowledge base of MCP servers with CLI alternatives
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

    local servers
    servers=$(jq -r '.mcpServers // {} | keys[]' "$mcp_config" 2>/dev/null)

    if [[ -z "$servers" ]]; then
        log_info "No MCP servers configured."
        return 0
    fi

    echo -e "${COLOR_BOLD}Token Efficiency Audit${COLOR_RESET}"
    echo ""

    local replaceable_count=0
    local total_savings=0

    while IFS= read -r server; do
        local matched=0
        for key in "${!MCP_CLI_ALTERNATIVES[@]}"; do
            if [[ "$server" == *"$key"* ]]; then
                matched=1
                local alt_info="${MCP_CLI_ALTERNATIVES[$key]}"
                local cli_alt reason savings_str
                cli_alt="${alt_info%%|*}"
                local remainder="${alt_info#*|}"
                reason="${remainder%%|*}"
                savings_str="${remainder##*|}"
                local savings_num
                savings_num=$(echo "$savings_str" | tr -dc '0-9')

                echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} ${COLOR_BOLD}$server${COLOR_RESET}"
                echo "    CLI alternative: $cli_alt"
                echo "    Reason: $reason"
                echo "    Estimated token savings: $savings_str tokens/request"
                echo ""

                replaceable_count=$((replaceable_count + 1))
                total_savings=$((total_savings + savings_num))
                break
            fi
        done

        if [[ "$matched" -eq 0 ]]; then
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} ${COLOR_BOLD}$server${COLOR_RESET} — no CLI replacement known, keep it"
            echo ""
        fi
    done <<< "$servers"

    echo -e "${COLOR_BOLD}Summary:${COLOR_RESET}"
    if [[ "$replaceable_count" -gt 0 ]]; then
        echo -e "  $replaceable_count server(s) could be replaced with CLI alternatives"
        echo -e "  Estimated total savings: ~$total_savings tokens/request"
    else
        echo -e "  All MCP servers appear necessary. No replacements suggested."
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Usage Statistics Module
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Routes usage subcommands to their implementations
# Parameters: $1 — subcommand (summary|top), remaining args forwarded
# Returns: Exit code from dispatched subcommand
# Usage: cmd_usage summary | cmd_usage top --count 5
cmd_usage() {
    case "${1:-}" in
        summary)    usage_summary ;;
        top)        shift; usage_top "$@" ;;
        history)    shift; usage_history "$@" ;;
        sessions)   shift; usage_sessions "$@" ;;
        dashboard)  shift; usage_dashboard "$@" ;;
        compare)    shift; usage_compare "$@" ;;
        "")         show_help usage ;;
        *)          log_error "Unknown usage command '$1'"; show_help usage; exit 1 ;;
    esac
}

# Purpose: Displays a summary of Claude Code usage across all projects
# Parameters: None
# Returns: None (prints summary to stdout)
# Usage: usage_summary
usage_summary() {
    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR"
        exit 1
    fi

    local total_projects=0
    local active_projects=0
    local orphaned_projects=0
    local total_sessions=0
    local recent_sessions=0
    local total_memory=0
    local managed_accounts=0

    local now
    now=$(date +%s)
    local seven_days_ago=$(( now - 604800 ))

    # Count projects and classify as active/orphaned
    for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        [[ -d "$project_dir" ]] || continue
        total_projects=$(( total_projects + 1 ))

        local dirname
        dirname=$(basename "$project_dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")

        if [[ -d "$decoded_path" ]]; then
            active_projects=$(( active_projects + 1 ))
        else
            orphaned_projects=$(( orphaned_projects + 1 ))
        fi

        # Count .jsonl session files and check recency
        while IFS= read -r -d '' jsonl_file; do
            total_sessions=$(( total_sessions + 1 ))
            local mtime
            mtime=$(get_mtime "$jsonl_file")
            if [[ "$mtime" -ge "$seven_days_ago" ]]; then
                recent_sessions=$(( recent_sessions + 1 ))
            fi
        done < <(find "$project_dir" -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null)

        # Count memory files
        if [[ -d "${project_dir}memory" ]]; then
            local mem_count
            mem_count=$(find "${project_dir}memory" -type f 2>/dev/null | wc -l | tr -d ' ')
            total_memory=$(( total_memory + mem_count ))
        fi
    done

    # Disk usage (du -sk gives size in KB)
    local disk_kb
    disk_kb=$(du -sk "$CLAUDE_PROJECTS_DIR" 2>/dev/null | awk '{print $1}')
    local disk_bytes=$(( disk_kb * 1024 ))
    local disk_display
    disk_display=$(format_size "$disk_bytes")

    # Count managed accounts
    if [[ -f "$SEQUENCE_FILE" ]]; then
        managed_accounts=$(jq '.accounts | length' "$SEQUENCE_FILE" 2>/dev/null || echo "0")
    fi

    echo ""
    echo "Claude Code Usage Summary"
    printf '%0.s━' {1..26}
    echo ""
    echo ""
    printf "  %-16s %s\n" "Projects:" "$total_projects ($active_projects active, $orphaned_projects orphaned)"
    printf "  %-16s %s\n" "Sessions:" "$total_sessions total ($recent_sessions this week)"
    printf "  %-16s %s\n" "Memory files:" "$total_memory"
    printf "  %-16s %s\n" "Disk usage:" "$disk_display"
    printf "  %-16s %s\n" "Accounts:" "$managed_accounts managed"
    echo ""
}

# Purpose: Displays top N projects ranked by disk usage
# Parameters: [--count N] — number of projects to show (default 10)
# Returns: None (prints table to stdout)
# Usage: usage_top | usage_top --count 5
usage_top() {
    local count=10

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --count)
                shift
                count="${1:-10}"
                if ! [[ "$count" =~ ^[0-9]+$ ]]; then
                    log_error "Invalid count: '$count'. Must be a positive integer."
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

    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR"
        exit 1
    fi

    # Collect project data: size_bytes|session_count|last_mtime|decoded_path
    local project_data=()

    for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        [[ -d "$project_dir" ]] || continue

        local dirname
        dirname=$(basename "$project_dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")

        # Size in KB from du, convert to bytes
        local size_kb
        size_kb=$(du -sk "$project_dir" 2>/dev/null | awk '{print $1}')
        local size_bytes=$(( size_kb * 1024 ))

        # Count sessions and find latest mtime
        local session_count=0
        local latest_mtime=0

        while IFS= read -r -d '' jsonl_file; do
            session_count=$(( session_count + 1 ))
            local mtime
            mtime=$(get_mtime "$jsonl_file")
            if [[ "$mtime" -gt "$latest_mtime" ]]; then
                latest_mtime=$mtime
            fi
        done < <(find "$project_dir" -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null)

        project_data+=("${size_bytes}|${session_count}|${latest_mtime}|${decoded_path}")
    done

    if [[ ${#project_data[@]} -eq 0 ]]; then
        log_info "No projects found in $CLAUDE_PROJECTS_DIR"
        return 0
    fi

    # Sort by size descending
    local sorted
    sorted=$(printf '%s\n' "${project_data[@]}" | sort -t'|' -k1 -nr)

    echo ""
    echo "Top Projects by Disk Usage"
    printf '%0.s━' {1..26}
    echo ""
    echo ""
    printf "  %-3s  %-40s %8s  %6s  %s\n" "#" "Project" "Sessions" "Size" "Last Active"
    printf "  %-3s  %-40s %8s  %6s  %s\n" "---" "------" "--------" "------" "-----------"

    local rank=0
    while IFS='|' read -r size_bytes session_count last_mtime decoded_path; do
        rank=$(( rank + 1 ))
        [[ "$rank" -gt "$count" ]] && break

        local display_path
        display_path=$(truncate_path "$decoded_path")
        # Truncate long paths to 40 chars
        if [[ ${#display_path} -gt 40 ]]; then
            display_path="...${display_path: -37}"
        fi

        local size_display
        size_display=$(format_size "$size_bytes")

        local time_display
        if [[ "$last_mtime" -eq 0 ]]; then
            time_display="unknown"
        else
            time_display=$(format_relative_time "$last_mtime")
        fi

        printf "  %-3s  %-40s %8s  %6s  %s\n" "$rank" "$display_path" "$session_count" "$size_display" "$time_display"
    done <<< "$sorted"

    echo ""
}

# Purpose: Displays per-project and per-day token usage by parsing JSONL session files
# Parameters: [--days N] [--project <path>]
# Returns: 0 on success
# Usage: usage_history | usage_history --days 30 | usage_history --project ~/my-app
usage_history() {
    local days=7
    local filter_project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)    days="$2"; shift 2 ;;
            --project) filter_project="$2"; shift 2 ;;
            *)         log_error "Unknown option '$1'"; return 1 ;;
        esac
    done

    if ! [[ "$days" =~ ^[0-9]+$ ]] || [[ "$days" -eq 0 ]]; then
        log_error "--days must be a positive integer."
        return 1
    fi

    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR"
        return 1
    fi

    local platform
    platform=$(detect_platform)
    local cutoff_date
    case "$platform" in
        macos) cutoff_date=$(date -v-"${days}"d +%Y-%m-%d) ;;
        *)     cutoff_date=$(date -d "-${days} days" +%Y-%m-%d) ;;
    esac

    echo -e "${COLOR_BOLD}Token Usage History (last $days days)${COLOR_RESET}"
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    echo ""

    show_progress "Scanning session files"

    local project_data=()
    local grand_input=0 grand_output=0 grand_cache_create=0 grand_cache_read=0
    declare -A day_input day_output day_cache_create day_cache_read

    for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        [[ -d "$project_dir" ]] || continue

        local dirname
        dirname=$(basename "$project_dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")

        if [[ -n "$filter_project" ]]; then
            local abs_filter
            abs_filter=$(cd "$filter_project" 2>/dev/null && pwd || echo "$filter_project")
            [[ "$decoded_path" != "$abs_filter" ]] && continue
        fi

        local proj_input=0 proj_output=0 proj_cache_create=0 proj_cache_read=0

        while IFS= read -r -d '' jsonl_file; do
            # Single jq pass per file — extract usage from assistant messages within date range
            local result
            result=$(jq -r --arg cutoff "$cutoff_date" '
                select(.type == "assistant" and .message.usage != null)
                | select(.timestamp != null and (.timestamp[:10]) >= $cutoff)
                | "\(.timestamp[:10])|\(.message.usage.input_tokens // 0)|\(.message.usage.output_tokens // 0)|\(.message.usage.cache_creation_input_tokens // 0)|\(.message.usage.cache_read_input_tokens // 0)"
            ' "$jsonl_file" 2>/dev/null) || continue

            while IFS='|' read -r date input output cache_create cache_read; do
                [[ -z "$date" || "$date" == "null" ]] && continue
                proj_input=$((proj_input + input))
                proj_output=$((proj_output + output))
                proj_cache_create=$((proj_cache_create + cache_create))
                proj_cache_read=$((proj_cache_read + cache_read))

                day_input[$date]=$(( ${day_input[$date]:-0} + input ))
                day_output[$date]=$(( ${day_output[$date]:-0} + output ))
                day_cache_create[$date]=$(( ${day_cache_create[$date]:-0} + cache_create ))
                day_cache_read[$date]=$(( ${day_cache_read[$date]:-0} + cache_read ))
            done <<< "$result"
        done < <(find "$project_dir" -maxdepth 2 -name "*.jsonl" -print0 2>/dev/null)

        local proj_total=$((proj_input + proj_output + proj_cache_create + proj_cache_read))
        if [[ "$proj_total" -gt 0 ]]; then
            project_data+=("${proj_total}|${proj_input}|${proj_output}|${proj_cache_create}|${proj_cache_read}|${decoded_path}")
            grand_input=$((grand_input + proj_input))
            grand_output=$((grand_output + proj_output))
            grand_cache_create=$((grand_cache_create + proj_cache_create))
            grand_cache_read=$((grand_cache_read + proj_cache_read))
        fi
    done

    complete_progress

    local grand_total=$((grand_input + grand_output + grand_cache_create + grand_cache_read))
    if [[ "$grand_total" -eq 0 ]]; then
        log_info "No token usage data found for the last $days days."
        return 0
    fi

    # Per-project table (sorted by total descending)
    echo -e "${COLOR_BOLD}Per-Project Breakdown:${COLOR_RESET}"
    echo ""
    printf "  %-40s %12s %12s %12s\n" "Project" "Input" "Output" "Total"
    printf "  %-40s %12s %12s %12s\n" "-------" "-----" "------" "-----"

    local sorted
    sorted=$(printf '%s\n' "${project_data[@]}" | sort -t'|' -k1 -nr)

    while IFS='|' read -r total input output cache_create cache_read path; do
        [[ -z "$total" ]] && continue
        local display_path
        display_path=$(truncate_path "$path")
        [[ ${#display_path} -gt 40 ]] && display_path="...${display_path: -37}"
        local combined_input=$((input + cache_create + cache_read))
        printf "  %-40s %12s %12s %12s\n" "$display_path" \
            "$(printf '%'\''d' "$combined_input" 2>/dev/null || echo "$combined_input")" \
            "$(printf '%'\''d' "$output" 2>/dev/null || echo "$output")" \
            "$(printf '%'\''d' "$total" 2>/dev/null || echo "$total")"
    done <<< "$sorted"

    echo ""

    # Per-day table (sorted by date)
    echo -e "${COLOR_BOLD}Per-Day Breakdown:${COLOR_RESET}"
    echo ""
    printf "  %-12s %12s %12s %12s\n" "Date" "Input" "Output" "Total"
    printf "  %-12s %12s %12s %12s\n" "----" "-----" "------" "-----"

    for date in $(echo "${!day_input[@]}" | tr ' ' '\n' | sort); do
        local di=${day_input[$date]:-0}
        local do_val=${day_output[$date]:-0}
        local dc=${day_cache_create[$date]:-0}
        local dr=${day_cache_read[$date]:-0}
        local dt=$((di + do_val + dc + dr))
        local combined_in=$((di + dc + dr))
        printf "  %-12s %12s %12s %12s\n" "$date" \
            "$(printf '%'\''d' "$combined_in" 2>/dev/null || echo "$combined_in")" \
            "$(printf '%'\''d' "$do_val" 2>/dev/null || echo "$do_val")" \
            "$(printf '%'\''d' "$dt" 2>/dev/null || echo "$dt")"
    done

    echo ""

    # Grand totals
    echo -e "${COLOR_BOLD}Totals:${COLOR_RESET}"
    printf "  Input tokens:          %s\n" "$(printf '%'\''d' "$grand_input" 2>/dev/null || echo "$grand_input")"
    printf "  Output tokens:         %s\n" "$(printf '%'\''d' "$grand_output" 2>/dev/null || echo "$grand_output")"
    printf "  Cache write tokens:    %s\n" "$(printf '%'\''d' "$grand_cache_create" 2>/dev/null || echo "$grand_cache_create")"
    printf "  Cache read tokens:     %s\n" "$(printf '%'\''d' "$grand_cache_read" 2>/dev/null || echo "$grand_cache_read")"
    printf "  ${COLOR_BOLD}Grand total:           %s${COLOR_RESET}\n" "$(printf '%'\''d' "$grand_total" 2>/dev/null || echo "$grand_total")"
}

# Purpose: Shows per-session token usage and estimated cost for a project
# Parameters: [--project <path>] [--days N] [--limit N]
# Returns: 0
# Usage: usage_sessions | usage_sessions --project . | usage_sessions --days 30
usage_sessions() {
    local filter_project=""
    local days=0
    local limit=20

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) filter_project="$2"; shift 2 ;;
            --days)    days="$2"; shift 2 ;;
            --limit)   limit="$2"; shift 2 ;;
            *)         log_error "Unknown option '$1'"; return 1 ;;
        esac
    done

    if [[ -n "$days" ]] && ! [[ "$days" =~ ^[0-9]+$ ]]; then
        log_error "--days must be a positive integer."
        return 1
    fi
    if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -eq 0 ]]; then
        log_error "--limit must be a positive integer."
        return 1
    fi

    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR"
        return 1
    fi

    # If no project specified, default to current directory
    if [[ -z "$filter_project" ]]; then
        filter_project="$(pwd)"
    fi

    # Resolve to absolute path
    local abs_project
    abs_project=$(cd "$filter_project" 2>/dev/null && pwd || echo "$filter_project")

    # Encode the project path to find the session directory
    local encoded_path
    encoded_path=$(echo "$abs_project" | sed 's|/|-|g')
    local project_dir="$CLAUDE_PROJECTS_DIR/$encoded_path"

    if [[ ! -d "$project_dir" ]]; then
        log_error "No sessions found for: $abs_project"
        return 1
    fi

    local display_path
    display_path=$(truncate_path "$abs_project")

    echo -e "${COLOR_BOLD}Session Usage — $display_path${COLOR_RESET}"
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""

    show_progress "Analyzing sessions"

    local now
    now=$(date +%s)
    local cutoff_seconds=0
    [[ "$days" -gt 0 ]] && cutoff_seconds=$((days * 86400))

    # Model pricing (per 1M tokens, USD)
    # Format: input|output|cache_read
    declare -A MODEL_PRICING
    MODEL_PRICING["claude-opus-4-6"]="15|75|1.875"
    MODEL_PRICING["claude-opus-4-5-20250414"]="15|75|1.875"
    MODEL_PRICING["claude-sonnet-4-6"]="3|15|0.30"
    MODEL_PRICING["claude-sonnet-4-5-20250514"]="3|15|0.30"
    MODEL_PRICING["claude-haiku-4-5-20251001"]="0.80|4|0.08"

    local session_data=()
    local grand_input=0 grand_output=0 grand_cache=0 grand_msgs=0
    local grand_cost_cents=0

    while IFS= read -r -d '' jsonl_file; do
        local fname
        fname=$(basename "$jsonl_file" .jsonl)
        local short_id="${fname:0:8}"

        # Check file age if --days specified
        if [[ "$cutoff_seconds" -gt 0 ]]; then
            local mtime
            mtime=$(get_mtime "$jsonl_file")
            local age=$((now - mtime))
            [[ "$age" -gt "$cutoff_seconds" ]] && continue
        fi

        # Single jq pass for all session metrics
        local stats
        stats=$(jq -s '
            [.[] | select(.type == "assistant" and .message.usage != null)] |
            {
                messages: length,
                input: (map(.message.usage.input_tokens // 0) | add // 0),
                output: (map(.message.usage.output_tokens // 0) | add // 0),
                cache_create: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
                cache_read: (map(.message.usage.cache_read_input_tokens // 0) | add // 0),
                model: ([.[] | .message.model // .model // empty] | first // "unknown"),
                first_ts: ([.[].timestamp // empty] | first // ""),
                last_ts: ([.[].timestamp // empty] | last // "")
            }
        ' "$jsonl_file" 2>/dev/null)

        [[ -z "$stats" ]] && continue

        local msgs input output cc cr model first_ts last_ts
        msgs=$(echo "$stats" | jq -r '.messages')
        input=$(echo "$stats" | jq -r '.input')
        output=$(echo "$stats" | jq -r '.output')
        cc=$(echo "$stats" | jq -r '.cache_create')
        cr=$(echo "$stats" | jq -r '.cache_read')
        model=$(echo "$stats" | jq -r '.model')
        first_ts=$(echo "$stats" | jq -r '.first_ts')
        last_ts=$(echo "$stats" | jq -r '.last_ts')

        [[ "$msgs" -eq 0 ]] && continue

        local total=$((input + output + cc + cr))

        # Calculate cost using model pricing
        local cost_cents=0
        local pricing="${MODEL_PRICING[$model]:-}"
        if [[ -n "$pricing" ]]; then
            IFS='|' read -r price_in price_out price_cache <<< "$pricing"
            # Cost in cents: (tokens / 1M) * price_per_M * 100
            local cost_in cost_out cost_cr
            cost_in=$(awk -v t="$((input + cc))" -v p="$price_in" 'BEGIN{printf "%.0f", (t / 1000000) * p * 100}')
            cost_out=$(awk -v t="$output" -v p="$price_out" 'BEGIN{printf "%.0f", (t / 1000000) * p * 100}')
            cost_cr=$(awk -v t="$cr" -v p="$price_cache" 'BEGIN{printf "%.0f", (t / 1000000) * p * 100}')
            cost_cents=$((cost_in + cost_out + cost_cr))
        fi

        # Calculate duration from first to last timestamp
        local duration_fmt="—"
        if [[ -n "$first_ts" && -n "$last_ts" && "$first_ts" != "$last_ts" ]]; then
            local ts_start ts_end dur_s
            case "$(uname)" in
                Darwin)
                    ts_start=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${first_ts:0:19}" +%s 2>/dev/null || echo "0")
                    ts_end=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_ts:0:19}" +%s 2>/dev/null || echo "0")
                    ;;
                *)
                    ts_start=$(date -d "${first_ts:0:19}" +%s 2>/dev/null || echo "0")
                    ts_end=$(date -d "${last_ts:0:19}" +%s 2>/dev/null || echo "0")
                    ;;
            esac
            if [[ "$ts_start" -gt 0 && "$ts_end" -gt 0 ]]; then
                dur_s=$((ts_end - ts_start))
                if [[ "$dur_s" -ge 3600 ]]; then
                    duration_fmt="$((dur_s / 3600))h$((dur_s % 3600 / 60))m"
                elif [[ "$dur_s" -ge 60 ]]; then
                    duration_fmt="$((dur_s / 60))m"
                else
                    duration_fmt="${dur_s}s"
                fi
            fi
        fi

        # Date display from first timestamp
        local date_display="${first_ts:0:10}"

        # Store: sort_key|short_id|msgs|input|output|cache|cost_cents|duration|date|model
        local combined_input=$((input + cc))
        session_data+=("${first_ts}|${short_id}|${msgs}|${combined_input}|${output}|${cr}|${cost_cents}|${duration_fmt}|${date_display}|${model}")

        grand_input=$((grand_input + combined_input))
        grand_output=$((grand_output + output))
        grand_cache=$((grand_cache + cr))
        grand_msgs=$((grand_msgs + msgs))
        grand_cost_cents=$((grand_cost_cents + cost_cents))
    done < <(find "$project_dir" -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null)

    complete_progress

    if [[ ${#session_data[@]} -eq 0 ]]; then
        log_info "No sessions found."
        return 0
    fi

    # Sort by timestamp descending (most recent first)
    local sorted
    sorted=$(printf '%s\n' "${session_data[@]}" | sort -t'|' -k1 -r)

    printf "  %-10s %-6s %8s %8s %8s %8s %8s  %s\n" "Session" "Date" "Messages" "Input" "Output" "Cache" "Cost" "Duration"
    printf "  %-10s %-6s %8s %8s %8s %8s %8s  %s\n" "───────" "────" "────────" "─────" "──────" "─────" "────" "────────"

    local shown=0
    while IFS='|' read -r _ts sid smsg sinput soutput scache scost sdur sdate smodel; do
        [[ -z "$sid" ]] && continue
        shown=$((shown + 1))
        [[ "$shown" -gt "$limit" ]] && break

        local cost_fmt
        cost_fmt=$(awk -v c="$scost" 'BEGIN{printf "$%.2f", c/100}')

        printf "  %-10s %-10s %5d %8s %8s %8s %8s  %s\n" \
            "${sid}..." "$sdate" "$smsg" \
            "$(format_token_count "$sinput")" \
            "$(format_token_count "$soutput")" \
            "$(format_token_count "$scache")" \
            "$cost_fmt" "$sdur"
    done <<< "$sorted"

    local remaining=$(( ${#session_data[@]} - shown ))
    [[ "$remaining" -gt 0 ]] && echo "  ... and $remaining more (use --limit to show more)"

    echo ""
    echo "  ─────────────────────────────────────────────────────────────────────"

    local grand_cost_fmt
    grand_cost_fmt=$(awk -v c="$grand_cost_cents" 'BEGIN{printf "$%.2f", c/100}')

    printf "  %-10s %-10s %5d %8s %8s %8s %8s\n" \
        "Total" "" "$grand_msgs" \
        "$(format_token_count "$grand_input")" \
        "$(format_token_count "$grand_output")" \
        "$(format_token_count "$grand_cache")" \
        "$grand_cost_fmt"

    echo ""
    echo -e "  ${COLOR_BOLD}Sessions:${COLOR_RESET} ${#session_data[@]}  ${COLOR_BOLD}Cost:${COLOR_RESET} $grand_cost_fmt (estimated)"
    echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Cost is estimated from model pricing — actual billing may differ"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Doctor Module — Health Diagnostics
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Routes doctor subcommands to their implementations
# Parameters: $@ — optional flags (--fix)
# Returns: Exit code from dispatched scan
# Usage: cmd_doctor | cmd_doctor --fix
cmd_doctor() {
    local fix_mode=0
    if [[ "${1:-}" == "--fix" ]]; then
        fix_mode=1
    fi
    doctor_scan "$fix_mode"
}

# Purpose: Calculates total size of a directory in bytes (cross-platform)
# Parameters: $1 — directory path
# Returns: Prints size in bytes
# Usage: size=$(doctor_dir_size "/path/to/dir")
doctor_dir_size() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "0"
        return
    fi
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)  du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}' ;;
        *)      du -sb "$dir" 2>/dev/null | awk '{print $1}' ;;
    esac
}

# Purpose: Counts files older than N days in a directory
# Parameters: $1 — directory path, $2 — age in days
# Returns: Prints count of old files
# Usage: count=$(doctor_count_old_files "/path" 30)
doctor_count_old_files() {
    local dir="$1"
    local days="$2"
    if [[ ! -d "$dir" ]]; then
        echo "0"
        return
    fi
    find "$dir" -type f -mtime +"$days" 2>/dev/null | wc -l | tr -d ' '
}

# Purpose: Counts all files in a directory
# Parameters: $1 — directory path
# Returns: Prints file count
# Usage: count=$(doctor_count_files "/path")
doctor_count_files() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "0"
        return
    fi
    find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

# Purpose: Removes files older than N days from a directory
# Parameters: $1 — directory path, $2 — age in days
# Returns: Prints count of removed files
# Usage: removed=$(doctor_remove_old_files "/path" 30)
doctor_remove_old_files() {
    local dir="$1"
    local days="$2"
    if [[ ! -d "$dir" ]]; then
        echo "0"
        return
    fi
    local count
    count=$(find "$dir" -type f -mtime +"$days" 2>/dev/null | wc -l | tr -d ' ')
    find "$dir" -type f -mtime +"$days" -delete 2>/dev/null
    echo "$count"
}

# Purpose: Scans ~/.claude/ for health issues and optionally fixes them
# Parameters: $1 — fix mode (1=fix, 0=report only)
# Returns: 0 on success
# Usage: doctor_scan 0 (report) | doctor_scan 1 (fix)
doctor_scan() {
    local fix_mode="${1:-0}"
    local issues=0
    local recoverable_bytes=0
    local now
    now=$(date +%s)
    local day_seconds=86400

    echo -e "${COLOR_BOLD}CCM Doctor — Health Check${COLOR_RESET}"
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    echo ""

    # 1. Stale lock files
    local stale_locks=0
    local lock_dirs=("$HOME/.claude/ide" "$HOME/.claude/sessions")
    for lock_base in "${lock_dirs[@]}"; do
        if [[ -d "$lock_base" ]]; then
            while IFS= read -r lockfile; do
                local mtime
                mtime=$(get_mtime "$lockfile")
                if [[ $((now - mtime)) -gt $((24 * day_seconds)) ]]; then
                    stale_locks=$((stale_locks + 1))
                    if [[ "$fix_mode" -eq 1 ]]; then
                        rm -f "$lockfile"
                    fi
                fi
            done < <(find "$lock_base" -name "*.lock" -o -name "lock" 2>/dev/null)
        fi
    done
    if [[ "$stale_locks" -eq 0 ]]; then
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Lock files" "No stale locks found"
    else
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Lock files" "$stale_locks stale lock(s) older than 24 hours"
        issues=$((issues + 1))
        if [[ "$fix_mode" -eq 1 ]]; then
            log_step "  Removed $stale_locks stale lock file(s)"
        fi
    fi

    # 2. Debug log bloat
    local debug_dir="$HOME/.claude/debug"
    local debug_size
    debug_size=$(doctor_dir_size "$debug_dir")
    local debug_count
    debug_count=$(doctor_count_files "$debug_dir")
    local debug_old
    debug_old=$(doctor_count_old_files "$debug_dir" 30)
    local debug_size_mb=$((debug_size / 1048576))
    if [[ "$debug_size_mb" -gt 50 ]] || [[ "$debug_old" -gt 0 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Debug logs" "$(format_size "$debug_size") ($debug_count files, $debug_old older than 30 days)"
        issues=$((issues + 1))
        if [[ "$fix_mode" -eq 1 ]] && [[ "$debug_old" -gt 0 ]]; then
            local old_size_before=$debug_size
            local removed
            removed=$(doctor_remove_old_files "$debug_dir" 30)
            local new_size
            new_size=$(doctor_dir_size "$debug_dir")
            local freed=$((old_size_before - new_size))
            recoverable_bytes=$((recoverable_bytes + freed))
            log_step "  Removed $removed old debug log(s), freed $(format_size "$freed")"
        elif [[ "$debug_old" -gt 0 ]]; then
            recoverable_bytes=$((recoverable_bytes + debug_size))
        fi
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Debug logs" "$(format_size "$debug_size") ($debug_count files)"
    fi

    # 3. Plugin cache bloat
    local plugin_cache_dir="$HOME/.claude/plugins/cache"
    local plugin_size
    plugin_size=$(doctor_dir_size "$plugin_cache_dir")
    local plugin_size_mb=$((plugin_size / 1048576))
    if [[ "$plugin_size_mb" -gt 200 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Plugin cache" "$(format_size "$plugin_size") (consider manual cleanup)"
        issues=$((issues + 1))
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Plugin cache" "$(format_size "$plugin_size")"
    fi

    # 4. Telemetry accumulation
    local telemetry_dir="$HOME/.claude/telemetry"
    local telemetry_size
    telemetry_size=$(doctor_dir_size "$telemetry_dir")
    local telemetry_count
    telemetry_count=$(doctor_count_files "$telemetry_dir")
    local telemetry_size_mb=$((telemetry_size / 1048576))
    if [[ "$telemetry_size_mb" -gt 20 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Telemetry" "$(format_size "$telemetry_size") ($telemetry_count files)"
        issues=$((issues + 1))
        if [[ "$fix_mode" -eq 1 ]] && [[ -d "$telemetry_dir" ]]; then
            find "$telemetry_dir" -type f -delete 2>/dev/null
            recoverable_bytes=$((recoverable_bytes + telemetry_size))
            log_step "  Removed $telemetry_count telemetry file(s), freed $(format_size "$telemetry_size")"
        else
            recoverable_bytes=$((recoverable_bytes + telemetry_size))
        fi
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Telemetry" "$(format_size "$telemetry_size") ($telemetry_count files)"
    fi

    # 5. Todo accumulation
    local todo_dir="$HOME/.claude/todos"
    local todo_count
    todo_count=$(doctor_count_files "$todo_dir")
    local todo_old
    todo_old=$(doctor_count_old_files "$todo_dir" 30)
    if [[ "$todo_count" -gt 100 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Todos" "$todo_count files ($todo_old older than 30 days)"
        issues=$((issues + 1))
        if [[ "$fix_mode" -eq 1 ]] && [[ "$todo_old" -gt 0 ]]; then
            local removed
            removed=$(doctor_remove_old_files "$todo_dir" 30)
            log_step "  Removed $removed old todo file(s)"
        fi
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Todos" "$todo_count files"
    fi

    # 6. Paste cache
    local paste_dir="$HOME/.claude/paste-cache"
    local paste_size
    paste_size=$(doctor_dir_size "$paste_dir")
    local paste_size_mb=$((paste_size / 1048576))
    if [[ "$paste_size_mb" -gt 10 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Paste cache" "$(format_size "$paste_size")"
        issues=$((issues + 1))
        if [[ "$fix_mode" -eq 1 ]] && [[ -d "$paste_dir" ]]; then
            find "$paste_dir" -type f -delete 2>/dev/null
            recoverable_bytes=$((recoverable_bytes + paste_size))
            log_step "  Cleared paste cache, freed $(format_size "$paste_size")"
        else
            recoverable_bytes=$((recoverable_bytes + paste_size))
        fi
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Paste cache" "$(format_size "$paste_size")"
    fi

    # 7. File history
    local history_dir="$HOME/.claude/file-history"
    local history_size
    history_size=$(doctor_dir_size "$history_dir")
    local history_old
    history_old=$(doctor_count_old_files "$history_dir" 30)
    local history_size_mb=$((history_size / 1048576))
    if [[ "$history_size_mb" -gt 50 ]] || [[ "$history_old" -gt 0 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "File history" "$(format_size "$history_size") ($history_old entries older than 30 days)"
        issues=$((issues + 1))
        if [[ "$fix_mode" -eq 1 ]] && [[ "$history_old" -gt 0 ]]; then
            local old_size_before=$history_size
            local removed
            removed=$(doctor_remove_old_files "$history_dir" 30)
            local new_size
            new_size=$(doctor_dir_size "$history_dir")
            local freed=$((old_size_before - new_size))
            recoverable_bytes=$((recoverable_bytes + freed))
            log_step "  Removed $removed old file history entries, freed $(format_size "$freed")"
        elif [[ "$history_old" -gt 0 ]]; then
            recoverable_bytes=$((recoverable_bytes + history_size))
        fi
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "File history" "$(format_size "$history_size")"
    fi

    # 8. Shell snapshots
    local snapshot_dir="$HOME/.claude/shell-snapshots"
    local snapshot_count
    snapshot_count=$(doctor_count_files "$snapshot_dir")
    if [[ "$snapshot_count" -gt 100 ]]; then
        local snapshot_old
        snapshot_old=$(doctor_count_old_files "$snapshot_dir" 30)
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Shell snapshots" "$snapshot_count files ($snapshot_old older than 30 days)"
        issues=$((issues + 1))
        if [[ "$fix_mode" -eq 1 ]] && [[ -d "$snapshot_dir" ]]; then
            # Remove oldest files beyond the 50 most recent (snapshot dirs use UUID names)
            local removed=0
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                rm -f "$f"
                removed=$((removed + 1))
            done < <(find "$snapshot_dir" -type f -print0 2>/dev/null \
                | xargs -0 ls -1t 2>/dev/null | tail -n +51)
            log_step "  Removed $removed old shell snapshots, kept 50 most recent"
        fi
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Shell snapshots" "$snapshot_count files"
    fi

    # 9. Orphaned sessions
    local orphan_count=0
    local orphan_bytes=0
    if [[ -d "$CLAUDE_PROJECTS_DIR" ]]; then
        for session_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
            [[ -d "$session_dir" ]] || continue
            local dirname
            dirname=$(basename "$session_dir")
            local decoded_path
            decoded_path=$(decode_project_path "$dirname")
            if [[ ! -d "$decoded_path" ]]; then
                orphan_count=$((orphan_count + 1))
                local disk_bytes
                disk_bytes=$(doctor_dir_size "$session_dir")
                orphan_bytes=$((orphan_bytes + disk_bytes))
            fi
        done
    fi
    if [[ "$orphan_count" -gt 0 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Orphaned sessions" "$orphan_count orphaned ($(format_size "$orphan_bytes"))"
        issues=$((issues + 1))
        recoverable_bytes=$((recoverable_bytes + orphan_bytes))
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Orphaned sessions" "No orphaned sessions found"
    fi

    # 10. Total ~/.claude/ size
    local claude_total_size
    claude_total_size=$(doctor_dir_size "$HOME/.claude")
    local claude_total_gb=$((claude_total_size / 1073741824))
    if [[ "$claude_total_gb" -ge 5 ]]; then
        printf "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} %-24s %s\n" "Total ~/.claude size" "$(format_size "$claude_total_size") — CRITICAL (>5 GB)"
        issues=$((issues + 1))
    elif [[ "$claude_total_gb" -ge 1 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Total ~/.claude size" "$(format_size "$claude_total_size") — consider cleanup"
        issues=$((issues + 1))
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Total ~/.claude size" "$(format_size "$claude_total_size")"
    fi

    # 11. Tmp output files
    local uid
    uid=$(id -u)
    local tmp_base
    case "$(detect_platform)" in
        macos) tmp_base="/private/tmp/claude-${uid}" ;;
        *)     tmp_base="/tmp/claude-${uid}" ;;
    esac
    if [[ -d "$tmp_base" ]]; then
        local tmp_size
        tmp_size=$(doctor_dir_size "$tmp_base")
        local tmp_count
        tmp_count=$(doctor_count_files "$tmp_base")
        local tmp_old
        tmp_old=$(doctor_count_old_files "$tmp_base" 1)
        if [[ "$tmp_old" -gt 0 ]]; then
            printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Tmp output files" "$(format_size "$tmp_size") ($tmp_count files, $tmp_old older than 1 day)"
            issues=$((issues + 1))
            recoverable_bytes=$((recoverable_bytes + tmp_size))
            if [[ "$fix_mode" -eq 1 ]]; then
                find "$tmp_base" -type f -mtime +1 -delete 2>/dev/null
                find "$tmp_base" -type d -empty -delete 2>/dev/null
                local tmp_new_size
                tmp_new_size=$(doctor_dir_size "$tmp_base")
                local tmp_freed=$((tmp_size - tmp_new_size))
                log_step "  Removed $tmp_old old tmp file(s), freed $(format_size "$tmp_freed")"
            fi
        else
            printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Tmp output files" "$(format_size "$tmp_size") ($tmp_count files)"
        fi
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Tmp output files" "No directory found"
    fi

    # 12. Orphaned Claude processes (macOS only — ppid=1 is unreliable on Linux/WSL)
    local oproc_count=0
    local oproc_rss=0
    if [[ "$(detect_platform)" == "macos" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local o_ppid o_rss o_cmd
            o_ppid=$(echo "$line" | awk '{print $2}')
            o_rss=$(echo "$line" | awk '{print $3}')
            o_cmd=$(echo "$line" | awk '{$1=$2=$3=""; print $0}')
            [[ "$o_cmd" == *"Claude.app"* || "$o_cmd" == *"Claude Helper"* || "$o_cmd" == *"/Applications/"* ]] && continue
            if [[ "$o_ppid" -eq 1 ]]; then
                oproc_count=$((oproc_count + 1))
                oproc_rss=$((oproc_rss + o_rss))
            fi
        done < <(ps -eo pid,ppid,rss,command 2>/dev/null | grep -i "[c]laude" | grep -v "Claude.app" | grep -v "Claude Helper")
    fi
    if [[ "$oproc_count" -gt 0 ]]; then
        local oproc_mb=$((oproc_rss / 1024))
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Orphaned processes" "$oproc_count process(es), ~${oproc_mb}MB (run 'ccm clean processes')"
        issues=$((issues + 1))
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Orphaned processes" "None detected"
    fi

    # 13. Hook async audit
    local settings_file="$HOME/.claude/settings.json"
    local non_async_hooks=0
    if [[ -f "$settings_file" ]]; then
        non_async_hooks=$(jq '[.hooks // {} | to_entries[] | .value[] | select(.command != null and (.async // false) == false)] | length' "$settings_file" 2>/dev/null || echo "0")
    fi
    if [[ "$non_async_hooks" -gt 0 ]]; then
        printf "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} %-24s %s\n" "Hook async config" "$non_async_hooks hook(s) without async — may slow startup"
        issues=$((issues + 1))
    else
        printf "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} %-24s %s\n" "Hook async config" "All hooks properly configured"
    fi

    # Summary
    echo ""
    if [[ "$issues" -eq 0 ]]; then
        log_success "No issues found. Claude Code environment is healthy."
    elif [[ "$fix_mode" -eq 1 ]]; then
        log_success "Fixed $issues issue(s), freed $(format_size "$recoverable_bytes")"
    else
        echo -e "${COLOR_BOLD}Summary:${COLOR_RESET} $issues issue(s) found, ~$(format_size "$recoverable_bytes") recoverable"
        echo "Run 'ccm doctor --fix' to auto-fix safe issues."
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Clean Module — Targeted Cleanup
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Routes clean subcommands to their implementations
# Parameters: $1 — target (cache|debug|telemetry|todos|history|all), remaining args forwarded
# Returns: Exit code from dispatched subcommand
# Usage: cmd_clean debug --days 30 | cmd_clean all --dry-run
cmd_clean() {
    case "${1:-}" in
        cache)      shift; clean_cache "$@" ;;
        debug)      shift; clean_debug "$@" ;;
        telemetry)  clean_telemetry ;;
        todos)      shift; clean_todos "$@" ;;
        history)    shift; clean_history "$@" ;;
        tmp)        shift; clean_tmp "$@" ;;
        processes)  clean_processes ;;
        all)        shift; clean_all "$@" ;;
        "")         show_help clean ;;
        *)          log_error "Unknown clean target '$1'"; show_help clean; exit 1 ;;
    esac
}

# Purpose: Cleans plugin cache by listing cached directories and their sizes
# Parameters: None
# Returns: 0 on success
# Usage: clean_cache
clean_cache() {
    local cache_dir="$HOME/.claude/plugins/cache"
    if [[ ! -d "$cache_dir" ]]; then
        log_info "Plugin cache directory not found. Nothing to clean."
        return 0
    fi

    local total_size
    total_size=$(doctor_dir_size "$cache_dir")
    echo -e "${COLOR_BOLD}Plugin Cache${COLOR_RESET}"
    echo ""
    echo "Total size: $(format_size "$total_size")"
    echo ""

    local found_dirs=0
    for plugin_dir in "$cache_dir"/*/; do
        [[ -d "$plugin_dir" ]] || continue
        found_dirs=1
        local name
        name=$(basename "$plugin_dir")
        local size
        size=$(doctor_dir_size "$plugin_dir")
        printf "  %-40s %s\n" "$name" "$(format_size "$size")"
    done

    if [[ "$found_dirs" -eq 0 ]]; then
        log_info "No cached plugins found."
        return 0
    fi

    echo ""
    echo -n "Remove all cached plugins? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Clean cancelled."
        return 0
    fi

    find "$cache_dir" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null
    log_success "Plugin cache cleared, freed $(format_size "$total_size")"
}

# Purpose: Removes debug logs older than N days
# Parameters: --days N (default 30)
# Returns: 0 on success
# Usage: clean_debug | clean_debug --days 7
clean_debug() {
    local days=30
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) days="$2"; shift 2 ;;
            *)      log_error "Unknown option '$1'"; return 1 ;;
        esac
    done

    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        log_error "--days must be a non-negative integer."
        return 1
    fi

    local debug_dir="$HOME/.claude/debug"
    if [[ ! -d "$debug_dir" ]]; then
        log_info "Debug log directory not found. Nothing to clean."
        return 0
    fi

    local old_count
    old_count=$(doctor_count_old_files "$debug_dir" "$days")
    local total_size
    total_size=$(doctor_dir_size "$debug_dir")

    echo -e "${COLOR_BOLD}Debug Log Cleanup${COLOR_RESET}"
    echo ""
    echo "Total debug log size: $(format_size "$total_size")"
    echo "Files older than $days days: $old_count"

    if [[ "$old_count" -eq 0 ]]; then
        echo ""
        log_success "No debug logs older than $days days."
        return 0
    fi

    echo ""
    echo -n "Remove $old_count debug log(s) older than $days days? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Clean cancelled."
        return 0
    fi

    local size_before=$total_size
    local removed
    removed=$(doctor_remove_old_files "$debug_dir" "$days")
    local size_after
    size_after=$(doctor_dir_size "$debug_dir")
    local freed=$((size_before - size_after))
    log_success "Removed $removed debug log(s), freed $(format_size "$freed")"
}

# Purpose: Removes all telemetry files
# Parameters: None
# Returns: 0 on success
# Usage: clean_telemetry
clean_telemetry() {
    local telemetry_dir="$HOME/.claude/telemetry"
    if [[ ! -d "$telemetry_dir" ]]; then
        log_info "Telemetry directory not found. Nothing to clean."
        return 0
    fi

    local count
    count=$(doctor_count_files "$telemetry_dir")
    local total_size
    total_size=$(doctor_dir_size "$telemetry_dir")

    echo -e "${COLOR_BOLD}Telemetry Cleanup${COLOR_RESET}"
    echo ""
    echo "Telemetry files: $count"
    echo "Total size: $(format_size "$total_size")"

    if [[ "$count" -eq 0 ]]; then
        echo ""
        log_success "No telemetry files found."
        return 0
    fi

    echo ""
    echo -n "Remove all $count telemetry file(s)? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Clean cancelled."
        return 0
    fi

    find "$telemetry_dir" -type f -delete 2>/dev/null
    log_success "Removed $count telemetry file(s), freed $(format_size "$total_size")"
}

# Purpose: Removes todo files older than N days
# Parameters: --days N (default 30)
# Returns: 0 on success
# Usage: clean_todos | clean_todos --days 7
clean_todos() {
    local days=30
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) days="$2"; shift 2 ;;
            *)      log_error "Unknown option '$1'"; return 1 ;;
        esac
    done

    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        log_error "--days must be a non-negative integer."
        return 1
    fi

    local todo_dir="$HOME/.claude/todos"
    if [[ ! -d "$todo_dir" ]]; then
        log_info "Todos directory not found. Nothing to clean."
        return 0
    fi

    local total_count
    total_count=$(doctor_count_files "$todo_dir")
    local old_count
    old_count=$(doctor_count_old_files "$todo_dir" "$days")

    echo -e "${COLOR_BOLD}Todos Cleanup${COLOR_RESET}"
    echo ""
    echo "Total todo files: $total_count"
    echo "Files older than $days days: $old_count"

    if [[ "$old_count" -eq 0 ]]; then
        echo ""
        log_success "No todo files older than $days days."
        return 0
    fi

    echo ""
    echo -n "Remove $old_count todo file(s) older than $days days? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Clean cancelled."
        return 0
    fi

    local removed
    removed=$(doctor_remove_old_files "$todo_dir" "$days")
    log_success "Removed $removed old todo file(s)"
}

# Purpose: Trims history.jsonl to keep last N entries
# Parameters: --keep N (default 1000)
# Returns: 0 on success
# Usage: clean_history | clean_history --keep 500
clean_history() {
    local keep=1000
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep) keep="$2"; shift 2 ;;
            *)      log_error "Unknown option '$1'"; return 1 ;;
        esac
    done

    if ! [[ "$keep" =~ ^[0-9]+$ ]] || [[ "$keep" -eq 0 ]]; then
        log_error "--keep must be a positive integer."
        return 1
    fi

    local history_file="$HOME/.claude/history.jsonl"
    if [[ ! -f "$history_file" ]]; then
        log_info "History file not found. Nothing to clean."
        return 0
    fi

    local total_lines
    total_lines=$(wc -l < "$history_file" | tr -d ' ')

    echo -e "${COLOR_BOLD}History Cleanup${COLOR_RESET}"
    echo ""
    echo "Total history entries: $total_lines"
    echo "Entries to keep: $keep"

    if [[ "$total_lines" -le "$keep" ]]; then
        echo ""
        log_success "History has $total_lines entries, within limit of $keep."
        return 0
    fi

    local to_remove=$((total_lines - keep))
    echo "Entries to remove: $to_remove"

    echo ""
    echo -n "Remove $to_remove oldest history entries? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Clean cancelled."
        return 0
    fi

    local temp_file
    temp_file=$(mktemp "${history_file}.XXXXXX")
    tail -n "$keep" "$history_file" > "$temp_file"
    mv "$temp_file" "$history_file"
    log_success "Removed $to_remove history entries, kept last $keep"
}

# Purpose: Removes orphaned subagent output files from Claude tmp directory
# Parameters: --days N (default 1) — only remove files older than N days
# Returns: 0 on success
# Usage: clean_tmp | clean_tmp --days 3
clean_tmp() {
    local days=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) days="$2"; shift 2 ;;
            *)      log_error "Unknown option '$1'"; return 1 ;;
        esac
    done

    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        log_error "--days must be a non-negative integer."
        return 1
    fi

    local platform
    platform=$(detect_platform)
    local uid
    uid=$(id -u)
    local tmp_base
    case "$platform" in
        macos) tmp_base="/private/tmp/claude-${uid}" ;;
        *)     tmp_base="/tmp/claude-${uid}" ;;
    esac

    echo -e "${COLOR_BOLD}Tmp File Cleanup${COLOR_RESET}"
    echo ""

    if [[ ! -d "$tmp_base" ]]; then
        log_info "Claude tmp directory not found: $tmp_base"
        return 0
    fi

    local size_before
    size_before=$(doctor_dir_size "$tmp_base")
    local total_files
    total_files=$(find "$tmp_base" -type f 2>/dev/null | wc -l | tr -d ' ')
    local old_files
    old_files=$(doctor_count_old_files "$tmp_base" "$days")

    echo "  Directory:  $tmp_base"
    echo "  Total size: $(format_size "$size_before")"
    echo "  Files:      $total_files total, $old_files older than $days day(s)"

    if [[ "$old_files" -eq 0 ]]; then
        echo ""
        log_success "No tmp files older than $days day(s)"
        return 0
    fi

    echo ""
    echo -n "Remove $old_files file(s) older than $days day(s)? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Clean cancelled."
        return 0
    fi

    find "$tmp_base" -type f -mtime +"$days" -delete 2>/dev/null
    find "$tmp_base" -type d -empty -delete 2>/dev/null

    local size_after
    size_after=$(doctor_dir_size "$tmp_base")
    local freed=$((size_before - size_after))
    log_success "Removed $old_files file(s), freed $(format_size "$freed")"
}

# Purpose: Detects and kills orphaned Claude Code subagent processes
# Parameters: None
# Returns: 0 on success
# Usage: clean_processes
clean_processes() {
    echo -e "${COLOR_BOLD}Orphaned Process Cleanup${COLOR_RESET}"
    echo ""

    local platform
    platform=$(detect_platform)

    # PPID=1 orphan detection is only reliable on macOS (launchd).
    # On Linux/WSL, systemd children legitimately have ppid=1.
    if [[ "$platform" != "macos" ]]; then
        log_info "Orphaned process detection is only supported on macOS."
        return 0
    fi

    local orphan_pids=()
    local orphan_info=()
    local total_rss=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid ppid rss cmd
        pid=$(echo "$line" | awk '{print $1}')
        ppid=$(echo "$line" | awk '{print $2}')
        rss=$(echo "$line" | awk '{print $3}')
        cmd=$(echo "$line" | awk '{$1=$2=$3=""; print $0}' | sed 's/^  *//')

        # Skip Claude Desktop app processes
        [[ "$cmd" == *"Claude.app"* ]] && continue
        [[ "$cmd" == *"Claude Helper"* ]] && continue
        [[ "$cmd" == *"/Applications/"* ]] && continue

        # Validate PID is numeric
        [[ "$pid" =~ ^[0-9]+$ ]] || continue

        # Orphaned = parent PID is 1 (reparented to launchd on macOS)
        if [[ "$ppid" -eq 1 ]]; then
            orphan_pids+=("$pid")
            local mem_mb=$((rss / 1024))
            total_rss=$((total_rss + rss))
            orphan_info+=("${pid}|${mem_mb}MB|${cmd}")
        fi
    done < <(ps -eo pid,ppid,rss,command 2>/dev/null | grep -i "[c]laude" | grep -v "Claude.app" | grep -v "Claude Helper")

    if [[ ${#orphan_pids[@]} -eq 0 ]]; then
        log_success "No orphaned Claude processes found."
        return 0
    fi

    local total_mem_mb=$((total_rss / 1024))
    printf "  %-8s  %-8s  %s\n" "PID" "Memory" "Command"
    printf "  %-8s  %-8s  %s\n" "--------" "--------" "-------"
    for info in "${orphan_info[@]}"; do
        IFS='|' read -r pid mem cmd <<< "$info"
        local short_cmd="${cmd:0:60}"
        printf "  %-8s  %-8s  %s\n" "$pid" "$mem" "$short_cmd"
    done
    echo ""
    echo "  Total: ${#orphan_pids[@]} orphaned process(es), ~${total_mem_mb}MB memory"

    echo ""
    echo -n "Kill ${#orphan_pids[@]} orphaned process(es)? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Clean cancelled."
        return 0
    fi

    local killed=0
    for pid in "${orphan_pids[@]}"; do
        kill "$pid" 2>/dev/null && killed=$((killed + 1))
    done
    log_success "Killed $killed orphaned process(es), freed ~${total_mem_mb}MB memory"
}

# Purpose: Runs all clean targets with optional dry-run mode
# Parameters: --dry-run (optional)
# Returns: 0 on success
# Usage: clean_all | clean_all --dry-run
clean_all() {
    local dry_run=0
    if [[ "${1:-}" == "--dry-run" ]]; then
        dry_run=1
    fi

    echo -e "${COLOR_BOLD}CCM Clean All${COLOR_RESET}"
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━${COLOR_RESET}"
    echo ""

    local total_freed=0

    # Debug logs (30 days)
    local debug_dir="$HOME/.claude/debug"
    local debug_old
    debug_old=$(doctor_count_old_files "$debug_dir" 30)
    local debug_size
    debug_size=$(doctor_dir_size "$debug_dir")
    if [[ "$debug_old" -gt 0 ]]; then
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Debug logs: $debug_old files older than 30 days ($(format_size "$debug_size") total)"
        if [[ "$dry_run" -eq 0 ]]; then
            local size_before=$debug_size
            doctor_remove_old_files "$debug_dir" 30 >/dev/null
            local size_after
            size_after=$(doctor_dir_size "$debug_dir")
            local freed=$((size_before - size_after))
            total_freed=$((total_freed + freed))
            log_step "  Removed $debug_old old debug log(s), freed $(format_size "$freed")"
        fi
    else
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Debug logs: clean"
    fi

    # Telemetry
    local telemetry_dir="$HOME/.claude/telemetry"
    local telemetry_count
    telemetry_count=$(doctor_count_files "$telemetry_dir")
    local telemetry_size
    telemetry_size=$(doctor_dir_size "$telemetry_dir")
    if [[ "$telemetry_count" -gt 0 ]]; then
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Telemetry: $telemetry_count files ($(format_size "$telemetry_size"))"
        if [[ "$dry_run" -eq 0 ]]; then
            find "$telemetry_dir" -type f -delete 2>/dev/null
            total_freed=$((total_freed + telemetry_size))
            log_step "  Removed $telemetry_count telemetry file(s), freed $(format_size "$telemetry_size")"
        fi
    else
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Telemetry: clean"
    fi

    # Todos (30 days)
    local todo_dir="$HOME/.claude/todos"
    local todo_old
    todo_old=$(doctor_count_old_files "$todo_dir" 30)
    if [[ "$todo_old" -gt 0 ]]; then
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Todos: $todo_old files older than 30 days"
        if [[ "$dry_run" -eq 0 ]]; then
            doctor_remove_old_files "$todo_dir" 30 >/dev/null
            log_step "  Removed $todo_old old todo file(s)"
        fi
    else
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Todos: clean"
    fi

    # Paste cache
    local paste_dir="$HOME/.claude/paste-cache"
    local paste_size
    paste_size=$(doctor_dir_size "$paste_dir")
    local paste_count
    paste_count=$(doctor_count_files "$paste_dir")
    if [[ "$paste_count" -gt 0 ]]; then
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Paste cache: $(format_size "$paste_size")"
        if [[ "$dry_run" -eq 0 ]]; then
            find "$paste_dir" -type f -delete 2>/dev/null
            total_freed=$((total_freed + paste_size))
            log_step "  Cleared paste cache, freed $(format_size "$paste_size")"
        fi
    else
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Paste cache: clean"
    fi

    # History
    local history_file="$HOME/.claude/history.jsonl"
    if [[ -f "$history_file" ]]; then
        local history_lines
        history_lines=$(wc -l < "$history_file" | tr -d ' ')
        if [[ "$history_lines" -gt 1000 ]]; then
            local to_remove=$((history_lines - 1000))
            echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} History: $history_lines entries ($to_remove over limit of 1000)"
            if [[ "$dry_run" -eq 0 ]]; then
                local temp_file
                temp_file=$(mktemp "${history_file}.XXXXXX")
                tail -n 1000 "$history_file" > "$temp_file"
                mv "$temp_file" "$history_file"
                log_step "  Trimmed history to 1000 entries (removed $to_remove)"
            fi
        else
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} History: $history_lines entries (within limit)"
        fi
    else
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} History: no file found"
    fi

    # Tmp output files (1 day)
    local uid
    uid=$(id -u)
    local tmp_base
    case "$(detect_platform)" in
        macos) tmp_base="/private/tmp/claude-${uid}" ;;
        *)     tmp_base="/tmp/claude-${uid}" ;;
    esac
    if [[ -d "$tmp_base" ]]; then
        local tmp_old
        tmp_old=$(doctor_count_old_files "$tmp_base" 1)
        local tmp_size
        tmp_size=$(doctor_dir_size "$tmp_base")
        if [[ "$tmp_old" -gt 0 ]]; then
            echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Tmp output files: $tmp_old files older than 1 day ($(format_size "$tmp_size") total)"
            if [[ "$dry_run" -eq 0 ]]; then
                local tmp_before=$tmp_size
                find "$tmp_base" -type f -mtime +1 -delete 2>/dev/null
                find "$tmp_base" -type d -empty -delete 2>/dev/null
                local tmp_after
                tmp_after=$(doctor_dir_size "$tmp_base")
                local tmp_freed=$((tmp_before - tmp_after))
                total_freed=$((total_freed + tmp_freed))
                log_step "  Removed $tmp_old old tmp file(s), freed $(format_size "$tmp_freed")"
            fi
        else
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Tmp output files: clean"
        fi
    else
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Tmp output files: no directory found"
    fi

    # Orphaned processes (report only — macOS only, ppid=1 unreliable on Linux)
    local orphan_count=0
    local orphan_rss=0
    if [[ "$(detect_platform)" == "macos" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid ppid rss cmd
            ppid=$(echo "$line" | awk '{print $2}')
            rss=$(echo "$line" | awk '{print $3}')
            cmd=$(echo "$line" | awk '{$1=$2=$3=""; print $0}')
            [[ "$cmd" == *"Claude.app"* || "$cmd" == *"Claude Helper"* || "$cmd" == *"/Applications/"* ]] && continue
            if [[ "$ppid" -eq 1 ]]; then
                orphan_count=$((orphan_count + 1))
                orphan_rss=$((orphan_rss + rss))
            fi
        done < <(ps -eo pid,ppid,rss,command 2>/dev/null | grep -i "[c]laude" | grep -v "Claude.app" | grep -v "Claude Helper")
    fi
    if [[ "$orphan_count" -gt 0 ]]; then
        local orphan_mb=$((orphan_rss / 1024))
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Orphaned processes: $orphan_count process(es), ~${orphan_mb}MB (run 'ccm clean processes')"
    else
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Orphaned processes: none"
    fi

    echo ""
    if [[ "$dry_run" -eq 1 ]]; then
        log_info "Dry run — no changes made. Remove --dry-run to execute cleanup."
    else
        log_success "Cleanup complete, freed $(format_size "$total_freed")"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Profiles Module — Isolated CLAUDE_CONFIG_DIR Profiles
# ──────────────────────────────────────────────────────────────────────────────

readonly PROFILES_DIR="$BACKUP_DIR/profiles"

# Purpose: Creates and activates an isolated profile for concurrent sessions
# Parameters:
#   --quiet     Suppress banner and progress; print only profile path to stdout
#   $1/$N       Account identifier (number, email, or alias)
# Returns: 0 on success, 1 on failure; prints profile path on success in --quiet mode
# Usage: switch_isolated work | switch_isolated --quiet 2
switch_isolated() {
    local quiet=0
    local identifier=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --quiet) quiet=1 ;;
            --) ;;
            *) [[ -z "$identifier" ]] && identifier="$arg" ;;
        esac
    done

    if [[ -z "$identifier" ]]; then
        log_error "Usage: ccm switch --isolated [--quiet] <account>"
        return 1
    fi

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts are managed yet"
        return 1
    fi

    local target_account
    target_account=$(resolve_account_identifier "$identifier")
    if [[ -z "$target_account" ]]; then
        log_error "No account found matching: $identifier"
        return 1
    fi

    local target_email
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    local target_alias
    target_alias=$(jq -r --arg num "$target_account" '.accounts[$num].alias // empty' "$SEQUENCE_FILE")
    local profile_name="${target_alias:-account-$target_account}"

    local profile_dir="$PROFILES_DIR/$profile_name"
    mkdir -p "$profile_dir"

    if [[ ! -f "$profile_dir/.claude.json" ]]; then
        (( quiet )) || show_progress "Creating isolated profile: $profile_name"

        # Copy credentials and config from account backup
        local target_creds target_config
        target_creds=$(read_account_credentials "$target_account" "$target_email")
        target_config=$(read_account_config "$target_account" "$target_email")

        if [[ -z "$target_creds" || -z "$target_config" ]]; then
            log_error "Missing backup data for Account-$target_account. Run 'ccm verify $target_account' first."
            return 1
        fi

        # Write config to profile directory
        echo "$target_config" > "$profile_dir/.claude.json"

        # Write credentials to profile (file-based, platform-independent for isolation)
        echo "$target_creds" > "$profile_dir/credentials.json"
        chmod 600 "$profile_dir/credentials.json"

        # Copy settings and MCP config from main ~/.claude/
        [[ -f "$HOME/.claude/settings.json" ]] && cp "$HOME/.claude/settings.json" "$profile_dir/settings.json"
        [[ -f "$HOME/.claude/.mcp.json" ]] && cp "$HOME/.claude/.mcp.json" "$profile_dir/.mcp.json"

        if (( quiet )); then :
        else
            complete_progress
            log_success "Created profile: $profile_name"
        fi
    fi

    # Export the env var for this shell session (only affects the ccm subshell)
    export CLAUDE_CONFIG_DIR="$profile_dir"

    if (( quiet )); then
        # Machine-readable: emit only the profile path so callers can capture it
        printf '%s\n' "$profile_dir"
        return 0
    fi

    echo ""
    echo -e "${COLOR_BOLD}Isolated profile activated: ${COLOR_GREEN}$profile_name${COLOR_RESET}"
    echo -e "  Account: $target_email"
    echo -e "  Config:  $profile_dir"
    echo ""
    echo "  CLAUDE_CONFIG_DIR=$profile_dir"
    echo ""
    echo "  Run 'claude' in this terminal to use this profile."
    echo "  Other terminals use the default account."
    echo ""
    log_info "To add to your shell: export CLAUDE_CONFIG_DIR=\"$profile_dir\""
}

# Purpose: Routes profiles subcommands
# Parameters: $1 — subcommand (list|sync|delete)
# Returns: Exit code from dispatched subcommand
# Usage: cmd_profiles list | cmd_profiles sync work | cmd_profiles delete work
cmd_profiles() {
    case "${1:-}" in
        list)   profiles_list ;;
        sync)   shift; profiles_sync "$@" ;;
        delete) shift; profiles_delete "$@" ;;
        "")     show_help profiles ;;
        *)      log_error "Unknown profiles command '$1'"; show_help profiles; exit 1 ;;
    esac
}

# Purpose: Lists all isolated profiles with their status
# Parameters: None
# Returns: None (prints table to stdout)
# Usage: profiles_list
profiles_list() {
    echo -e "${COLOR_BOLD}Isolated Profiles${COLOR_RESET}"
    echo ""

    if [[ ! -d "$PROFILES_DIR" ]] || [[ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]]; then
        log_info "No profiles found. Create one with: ccm switch --isolated <account>"
        return 0
    fi

    printf "  %-20s %-30s %s\n" "Profile" "Email" "Status"
    printf "  %-20s %-30s %s\n" "-------" "-----" "------"

    for profile_dir in "$PROFILES_DIR"/*/; do
        [[ -d "$profile_dir" ]] || continue
        local name
        name=$(basename "$profile_dir")
        local email="unknown"
        if [[ -f "$profile_dir/.claude.json" ]]; then
            email=$(jq -r '.oauthAccount.emailAddress // "unknown"' "$profile_dir/.claude.json" 2>/dev/null)
        fi
        local status="${COLOR_GREEN}ready${COLOR_RESET}"
        if [[ "${CLAUDE_CONFIG_DIR:-}" == "$profile_dir" ]] || [[ "${CLAUDE_CONFIG_DIR:-}" == "${profile_dir%/}" ]]; then
            status="${COLOR_CYAN}active${COLOR_RESET}"
        fi
        printf "  %-20s %-30s " "$name" "$email"
        echo -e "$status"
    done
    echo ""
}

# Purpose: Syncs settings and MCP config from main ~/.claude/ to a named profile
# Parameters: $1 — profile name
# Returns: 0 on success, 1 if profile not found
# Usage: profiles_sync work
profiles_sync() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "Usage: ccm profiles sync <name>"
        return 1
    fi

    local profile_dir="$PROFILES_DIR/$name"
    if [[ ! -d "$profile_dir" ]]; then
        log_error "Profile not found: $name"
        return 1
    fi

    show_progress "Syncing settings to profile: $name"
    [[ -f "$HOME/.claude/settings.json" ]] && cp "$HOME/.claude/settings.json" "$profile_dir/settings.json"
    [[ -f "$HOME/.claude/.mcp.json" ]] && cp "$HOME/.claude/.mcp.json" "$profile_dir/.mcp.json"
    complete_progress
    log_success "Profile '$name' synced with current settings"
}

# Purpose: Deletes an isolated profile directory
# Parameters: $1 — profile name
# Returns: 0 on success, 1 if profile not found
# Usage: profiles_delete work
profiles_delete() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "Usage: ccm profiles delete <name>"
        return 1
    fi

    local profile_dir="$PROFILES_DIR/$name"
    if [[ ! -d "$profile_dir" ]]; then
        log_error "Profile not found: $name"
        return 1
    fi

    if [[ "${CLAUDE_CONFIG_DIR:-}" == "$profile_dir" ]] || [[ "${CLAUDE_CONFIG_DIR:-}" == "${profile_dir%/}" ]]; then
        log_warning "This profile is currently active in this terminal."
        echo -n "Delete anyway? (y/N): "
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0
    fi

    rm -rf "$profile_dir"
    log_success "Deleted profile: $name"
}

# ──────────────────────────────────────────────────────────────────────────────
# Watch Module — Rate Limit Monitoring
# ──────────────────────────────────────────────────────────────────────────────

readonly WATCH_PID_FILE="$BACKUP_DIR/watch.pid"
readonly RATE_LIMITS_FILE="$BACKUP_DIR/rate-limits.json"

# Purpose: Routes watch subcommands
# Parameters: $@ — subcommand and options
# Returns: Exit code from dispatched subcommand
# Usage: cmd_watch --threshold 85 | cmd_watch stop | cmd_watch status
cmd_watch() {
    case "${1:-}" in
        stop)   watch_stop ;;
        status) watch_status ;;
        "")     show_help watch ;;
        *)      watch_start "$@" ;;
    esac
}

# Purpose: Starts the rate limit watcher as a background process
# Parameters: [--threshold N] [--auto] [--interval N]
# Returns: 0 on success
# Usage: watch_start --threshold 85 --auto
watch_start() {
    local threshold=85
    local auto_switch=0
    local interval=60

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold) threshold="$2"; shift 2 ;;
            --auto)      auto_switch=1; shift ;;
            --interval)  interval="$2"; shift 2 ;;
            *)           log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [[ "$threshold" -lt 1 ]] || [[ "$threshold" -gt 100 ]]; then
        log_error "--threshold must be 1-100"
        return 1
    fi

    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 10 ]]; then
        log_error "--interval must be >= 10 seconds"
        return 1
    fi

    # Kill existing watcher if running
    watch_stop 2>/dev/null

    local mode_label="notify"
    [[ "$auto_switch" -eq 1 ]] && mode_label="auto-switch"

    echo -e "${COLOR_BOLD}CCM Rate Limit Watcher${COLOR_RESET}"
    echo ""
    echo "  Threshold:  ${threshold}%"
    echo "  Mode:       $mode_label"
    echo "  Interval:   ${interval}s"
    echo ""

    if [[ ! -f "$RATE_LIMITS_FILE" ]]; then
        log_warning "No rate limit data found. Install the CCM statusline first:"
        echo "  ccm statusline install"
        echo ""
        log_info "The statusline writes rate limit data that the watcher monitors."
        return 1
    fi

    # Start background watcher
    (
        while true; do
            if [[ ! -f "$RATE_LIMITS_FILE" ]]; then
                sleep "$interval"
                continue
            fi

            local five_hour_pct
            five_hour_pct=$(jq -r '.five_hour.used_percentage // 0' "$RATE_LIMITS_FILE" 2>/dev/null || echo "0")
            local pct_int
            pct_int=$(echo "$five_hour_pct" | cut -d. -f1)

            if [[ "$pct_int" -ge "$threshold" ]]; then
                if [[ "$auto_switch" -eq 1 ]]; then
                    # Find account with lowest usage (round-robin fallback)
                    local script_dir
                    script_dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")
                    bash "${script_dir}/ccm.sh" switch 2>/dev/null || true
                    echo -e "\a${COLOR_YELLOW}[CCM Watch] Rate limit at ${pct_int}% — auto-switched account${COLOR_RESET}" >&2
                else
                    echo -e "\a${COLOR_YELLOW}[CCM Watch] Rate limit at ${pct_int}% (threshold: ${threshold}%) — run 'ccm switch' to rotate${COLOR_RESET}" >&2
                fi
            fi

            sleep "$interval"
        done
    ) &
    local watcher_pid=$!
    echo "$watcher_pid" > "$WATCH_PID_FILE"
    disown "$watcher_pid" 2>/dev/null

    log_success "Watcher started (PID: $watcher_pid)"
    echo "  Stop with: ccm watch stop"
}

# Purpose: Stops the background rate limit watcher
# Parameters: None
# Returns: 0
# Usage: watch_stop
watch_stop() {
    if [[ -f "$WATCH_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WATCH_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_success "Watcher stopped (PID: $pid)"
        else
            log_info "Watcher was not running"
        fi
        rm -f "$WATCH_PID_FILE"
    else
        log_info "No watcher is running"
    fi
}

# Purpose: Shows the current watcher state and latest rate limit data
# Parameters: None
# Returns: 0
# Usage: watch_status
watch_status() {
    echo -e "${COLOR_BOLD}CCM Watcher Status${COLOR_RESET}"
    echo ""

    # Watcher process
    if [[ -f "$WATCH_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WATCH_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  Watcher:  ${COLOR_GREEN}running${COLOR_RESET} (PID: $pid)"
        else
            echo -e "  Watcher:  ${COLOR_RED}stopped${COLOR_RESET} (stale PID file)"
            rm -f "$WATCH_PID_FILE"
        fi
    else
        echo -e "  Watcher:  ${COLOR_YELLOW}not running${COLOR_RESET}"
    fi

    # Latest rate limit data
    if [[ -f "$RATE_LIMITS_FILE" ]]; then
        local five_pct seven_pct five_reset seven_reset
        five_pct=$(jq -r '.five_hour.used_percentage // "n/a"' "$RATE_LIMITS_FILE" 2>/dev/null)
        seven_pct=$(jq -r '.seven_day.used_percentage // "n/a"' "$RATE_LIMITS_FILE" 2>/dev/null)
        five_reset=$(jq -r '.five_hour.resets_at // empty' "$RATE_LIMITS_FILE" 2>/dev/null)
        seven_reset=$(jq -r '.seven_day.resets_at // empty' "$RATE_LIMITS_FILE" 2>/dev/null)

        echo ""
        echo -e "  ${COLOR_BOLD}Rate Limits:${COLOR_RESET}"
        local five_fmt="$five_pct%"
        if [[ -n "$five_reset" && "$five_reset" != "null" ]]; then
            local reset_time
            case "$(uname)" in
                Darwin) reset_time=$(date -r "$five_reset" +%H:%M 2>/dev/null) ;;
                *)      reset_time=$(date -d "@$five_reset" +%H:%M 2>/dev/null) ;;
            esac
            [[ -n "$reset_time" ]] && five_fmt+=" (resets $reset_time)"
        fi
        echo "    5-hour:  $five_fmt"

        local seven_fmt="$seven_pct%"
        if [[ -n "$seven_reset" && "$seven_reset" != "null" ]]; then
            local reset_time
            case "$(uname)" in
                Darwin) reset_time=$(date -r "$seven_reset" +%H:%M 2>/dev/null) ;;
                *)      reset_time=$(date -d "@$seven_reset" +%H:%M 2>/dev/null) ;;
            esac
            [[ -n "$reset_time" ]] && seven_fmt+=" (resets $reset_time)"
        fi
        echo "    7-day:   $seven_fmt"

        local updated
        updated=$(jq -r '.updated_at // empty' "$RATE_LIMITS_FILE" 2>/dev/null)
        [[ -n "$updated" ]] && echo "    Updated: $updated"
    else
        echo ""
        echo -e "  Rate data: ${COLOR_YELLOW}unavailable${COLOR_RESET} (install statusline first)"
    fi
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Usage Dashboard Module — Per-Account Token Analytics
# ──────────────────────────────────────────────────────────────────────────────

readonly USAGE_HISTORY_FILE="$BACKUP_DIR/usage-history.json"

# Purpose: Shows per-account usage dashboard with token attribution
# Parameters: [--days N] [--account <name>]
# Returns: 0
# Usage: usage_dashboard | usage_dashboard --days 30 | usage_dashboard --account work
usage_dashboard() {
    local days=7
    local filter_account=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)    days="$2"; shift 2 ;;
            --account) filter_account="$2"; shift 2 ;;
            *)         log_error "Unknown option '$1'"; return 1 ;;
        esac
    done

    if ! [[ "$days" =~ ^[0-9]+$ ]] || [[ "$days" -eq 0 ]]; then
        log_error "--days must be a positive integer."
        return 1
    fi

    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR"
        return 1
    fi

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_error "No accounts managed. Run 'ccm add' first."
        return 1
    fi

    echo -e "${COLOR_BOLD}Account Usage Dashboard (last $days days)${COLOR_RESET}"
    echo -e "${COLOR_BOLD}═══════════════════════════════════════════${COLOR_RESET}"
    echo ""

    show_progress "Analyzing token usage across accounts"

    # Build switch history timeline from sequence.json
    local platform
    platform=$(detect_platform)
    local cutoff_date
    case "$platform" in
        macos) cutoff_date=$(date -v-"${days}"d +%Y-%m-%d) ;;
        *)     cutoff_date=$(date -d "-${days} days" +%Y-%m-%d) ;;
    esac

    # Get all account emails for attribution
    declare -A account_input account_output account_cache account_sessions account_duration
    local account_emails=()

    while IFS=$'\t' read -r num email alias_name; do
        [[ -z "$email" || "$email" == "null" ]] && continue
        local label="${alias_name:-$email}"
        if [[ -n "$filter_account" ]]; then
            [[ "$num" != "$filter_account" && "$email" != "$filter_account" && "$label" != "$filter_account" ]] && continue
        fi
        account_emails+=("$email")
        account_input[$email]=0
        account_output[$email]=0
        account_cache[$email]=0
        account_sessions[$email]=0
        account_duration[$email]=0
    done < <(jq -r '.accounts | to_entries[] | [.key, .value.email, (.value.alias // "")] | @tsv' "$SEQUENCE_FILE" 2>/dev/null)

    if [[ ${#account_emails[@]} -eq 0 ]]; then
        complete_progress
        log_info "No accounts found matching filter."
        return 0
    fi

    # Build switch timeline for attribution
    # Each history entry has {from, to, timestamp}
    # We create intervals: [timestamp_i, timestamp_i+1) → account_i
    local switch_times=()
    local switch_accounts=()

    while IFS=$'\t' read -r ts account_num; do
        [[ -z "$ts" ]] && continue
        local account_email
        account_email=$(jq -r --arg n "$account_num" '.accounts[$n].email // ""' "$SEQUENCE_FILE" 2>/dev/null)
        [[ -z "$account_email" ]] && continue
        switch_times+=("$ts")
        switch_accounts+=("$account_email")
    done < <(jq -r '.history[]? | [.timestamp, (.to | tostring)] | @tsv' "$SEQUENCE_FILE" 2>/dev/null)

    # Current active account fills the latest window
    local current_email
    current_email=$(get_current_account)

    # Attribute sessions: for each JSONL file, find which account was active at session time
    local grand_input=0 grand_output=0 grand_cache=0

    for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        [[ -d "$project_dir" ]] || continue

        while IFS= read -r -d '' jsonl_file; do
            # Get first timestamp from file to determine which account was active
            local first_ts
            first_ts=$(head -1 "$jsonl_file" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null)
            [[ -z "$first_ts" ]] && continue
            [[ "${first_ts:0:10}" < "$cutoff_date" ]] && continue

            # Determine active account at session start by checking switch history
            local session_account="$current_email"
            for i in "${!switch_times[@]}"; do
                if [[ "${switch_times[$i]}" > "$first_ts" ]]; then
                    break
                fi
                session_account="${switch_accounts[$i]}"
            done

            # Skip if this account is filtered out
            if [[ -n "$filter_account" ]] && [[ " ${account_emails[*]} " != *" $session_account "* ]]; then
                continue
            fi

            # Parse token usage from this session
            local result
            result=$(jq -r --arg cutoff "$cutoff_date" '
                select(.type == "assistant" and .message.usage != null)
                | select(.timestamp != null and (.timestamp[:10]) >= $cutoff)
                | "\(.message.usage.input_tokens // 0)|\(.message.usage.output_tokens // 0)|\(.message.usage.cache_creation_input_tokens // 0)|\(.message.usage.cache_read_input_tokens // 0)"
            ' "$jsonl_file" 2>/dev/null) || continue

            local sess_in=0 sess_out=0 sess_cache=0
            while IFS='|' read -r input output cache_create cache_read; do
                [[ -z "$input" ]] && continue
                sess_in=$((sess_in + input + cache_create + cache_read))
                sess_out=$((sess_out + output))
                sess_cache=$((sess_cache + cache_create + cache_read))
            done <<< "$result"

            if [[ "$sess_in" -gt 0 || "$sess_out" -gt 0 ]]; then
                # Ensure account exists in our tracking arrays
                if [[ -n "${account_input[$session_account]+x}" ]]; then
                    account_input[$session_account]=$(( ${account_input[$session_account]} + sess_in ))
                    account_output[$session_account]=$(( ${account_output[$session_account]} + sess_out ))
                    account_cache[$session_account]=$(( ${account_cache[$session_account]} + sess_cache ))
                    account_sessions[$session_account]=$(( ${account_sessions[$session_account]} + 1 ))
                fi
                grand_input=$((grand_input + sess_in))
                grand_output=$((grand_output + sess_out))
                grand_cache=$((grand_cache + sess_cache))
            fi
        done < <(find "$project_dir" -maxdepth 2 -name "*.jsonl" -print0 2>/dev/null)
    done

    complete_progress

    if [[ "$grand_input" -eq 0 && "$grand_output" -eq 0 ]]; then
        log_info "No token usage data found for the last $days days."
        return 0
    fi

    # Display dashboard
    printf "  %-25s %12s %12s %12s %8s\n" "Account" "Input" "Output" "Cache" "Sessions"
    printf "  %-25s %12s %12s %12s %8s\n" "───────" "─────" "──────" "─────" "────────"

    for email in "${account_emails[@]}"; do
        local in_val=${account_input[$email]:-0}
        local out_val=${account_output[$email]:-0}
        local cache_val=${account_cache[$email]:-0}
        local sess_val=${account_sessions[$email]:-0}

        [[ "$in_val" -eq 0 && "$out_val" -eq 0 ]] && continue

        # Get display label (alias or truncated email)
        local label
        label=$(jq -r --arg e "$email" '.accounts | to_entries[] | select(.value.email == $e) | .value.alias // $e' "$SEQUENCE_FILE" 2>/dev/null)
        [[ ${#label} -gt 25 ]] && label="...${label: -22}"

        # Format numbers
        local in_fmt out_fmt cache_fmt
        in_fmt=$(format_token_count "$in_val")
        out_fmt=$(format_token_count "$out_val")
        cache_fmt=$(format_token_count "$cache_val")

        printf "  %-25s %12s %12s %12s %8d\n" "$label" "$in_fmt" "$out_fmt" "$cache_fmt" "$sess_val"
    done

    echo ""
    printf "  %-25s %12s %12s %12s\n" "───────" "─────" "──────" "─────"
    printf "  %-25s %12s %12s %12s\n" "Total" \
        "$(format_token_count "$grand_input")" \
        "$(format_token_count "$grand_output")" \
        "$(format_token_count "$grand_cache")"
    echo ""
}

# Purpose: Formats token count as human-readable string (K/M)
# Parameters: $1 — token count
# Returns: Formatted string on stdout
# Usage: format_token_count 1500000  # → "1.5M"
format_token_count() {
    local count="$1"
    if [[ "$count" -ge 1000000 ]]; then
        awk -v c="$count" 'BEGIN{printf "%.1fM", c/1000000}'
    elif [[ "$count" -ge 1000 ]]; then
        awk -v c="$count" 'BEGIN{printf "%.0fK", c/1000}'
    else
        echo "$count"
    fi
}

# Purpose: Side-by-side account usage comparison
# Parameters: [--days N]
# Returns: 0
# Usage: usage_compare | usage_compare --days 30
usage_compare() {
    usage_dashboard "$@"
}

# ──────────────────────────────────────────────────────────────────────────────
# Session Archive Module — Compress & Restore Sessions
# ──────────────────────────────────────────────────────────────────────────────

readonly ARCHIVES_DIR="$BACKUP_DIR/archives"

# Purpose: Archives old sessions as compressed tar.gz files
# Parameters: [--older-than Nd] [--project <path>] [--dry-run]
# Returns: 0 on success
# Usage: session_archive | session_archive --older-than 30d
session_archive() {
    local older_than=30
    local filter_project=""
    local dry_run=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --older-than)
                local val="${2:-30d}"
                older_than="${val%d}"
                if ! [[ "$older_than" =~ ^[0-9]+$ ]]; then
                    log_error "--older-than must be a number (with optional 'd' suffix)"
                    return 1
                fi
                shift 2
                ;;
            --project) filter_project="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            *)         log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ ! -d "$CLAUDE_PROJECTS_DIR" ]]; then
        log_error "Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR"
        return 1
    fi

    mkdir -p "$ARCHIVES_DIR"

    local platform
    platform=$(detect_platform)
    local now
    now=$(date +%s)
    local cutoff_seconds=$((older_than * 86400))

    echo -e "${COLOR_BOLD}Session Archive${COLOR_RESET}"
    echo ""

    local total_archived=0
    local total_size=0

    for project_dir in "$CLAUDE_PROJECTS_DIR"/*/; do
        [[ -d "$project_dir" ]] || continue

        local dirname
        dirname=$(basename "$project_dir")
        local decoded_path
        decoded_path=$(decode_project_path "$dirname")

        if [[ -n "$filter_project" ]]; then
            local abs_filter
            abs_filter=$(cd "$filter_project" 2>/dev/null && pwd || echo "$filter_project")
            [[ "$decoded_path" != "$abs_filter" ]] && continue
        fi

        # Find JSONL files older than threshold
        local old_files=()
        while IFS= read -r -d '' jsonl_file; do
            local mtime
            mtime=$(get_mtime "$jsonl_file")
            local age=$((now - mtime))
            if [[ "$age" -ge "$cutoff_seconds" ]]; then
                old_files+=("$jsonl_file")
            fi
        done < <(find "$project_dir" -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null)

        [[ ${#old_files[@]} -eq 0 ]] && continue

        local display_path
        display_path=$(truncate_path "$decoded_path")
        local file_count=${#old_files[@]}

        # Calculate size
        local dir_size=0
        for f in "${old_files[@]}"; do
            local fsize
            fsize=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
            dir_size=$((dir_size + fsize))
        done

        if [[ "$dry_run" -eq 1 ]]; then
            echo "  [dry-run] Would archive $file_count sessions from $display_path ($(format_size $dir_size))"
        else
            # Create archive
            local archive_name="${dirname}-$(date +%Y%m%d).tar.gz"
            local archive_path="$ARCHIVES_DIR/$archive_name"

            # Use file list to avoid archiving non-old files
            local file_list
            file_list=$(mktemp)
            printf '%s\n' "${old_files[@]}" > "$file_list"
            tar czf "$archive_path" -T "$file_list" 2>/dev/null
            rm -f "$file_list"

            # Update index
            local index_file="$ARCHIVES_DIR/index.json"
            local entry
            entry=$(jq -n \
                --arg name "$archive_name" \
                --arg project "$decoded_path" \
                --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --argjson sessions "$file_count" \
                --argjson original_bytes "$dir_size" \
                '{name: $name, project: $project, archived_at: $date, sessions: $sessions, original_bytes: $original_bytes}')

            if [[ -f "$index_file" ]]; then
                local updated
                updated=$(jq --argjson entry "$entry" '. += [$entry]' "$index_file")
                echo "$updated" > "$index_file"
            else
                echo "[$entry]" > "$index_file"
            fi

            # Remove archived files
            for f in "${old_files[@]}"; do
                rm -f "$f"
            done

            echo "  Archived $file_count sessions from $display_path ($(format_size $dir_size))"
        fi

        total_archived=$((total_archived + file_count))
        total_size=$((total_size + dir_size))
    done

    echo ""
    if [[ "$total_archived" -eq 0 ]]; then
        log_info "No sessions older than ${older_than} days found."
    elif [[ "$dry_run" -eq 1 ]]; then
        log_info "Would archive $total_archived sessions ($(format_size $total_size)). Run without --dry-run to proceed."
    else
        log_success "Archived $total_archived sessions, freed $(format_size $total_size)"
    fi
}

# Purpose: Restores sessions from an archive
# Parameters: $1 — archive name
# Returns: 0 on success, 1 on failure
# Usage: session_restore my-project-20260401.tar.gz
session_restore() {
    local archive_name="${1:-}"
    if [[ -z "$archive_name" ]]; then
        log_error "Usage: ccm session restore <archive-name>"
        return 1
    fi

    local archive_path="$ARCHIVES_DIR/$archive_name"
    if [[ ! -f "$archive_path" ]]; then
        log_error "Archive not found: $archive_name"
        echo "  Run 'ccm session archives' to list available archives."
        return 1
    fi

    show_progress "Restoring sessions from $archive_name"
    tar xzf "$archive_path" 2>/dev/null
    complete_progress
    log_success "Restored sessions from $archive_name"
}

# Purpose: Lists all session archives with sizes
# Parameters: None
# Returns: None (prints table to stdout)
# Usage: session_archives_list
session_archives_list() {
    echo -e "${COLOR_BOLD}Session Archives${COLOR_RESET}"
    echo ""

    local index_file="$ARCHIVES_DIR/index.json"
    if [[ ! -f "$index_file" ]] || [[ ! -d "$ARCHIVES_DIR" ]]; then
        log_info "No archives found. Create one with: ccm session archive"
        return 0
    fi

    printf "  %-40s %8s %10s  %s\n" "Archive" "Sessions" "Saved" "Date"
    printf "  %-40s %8s %10s  %s\n" "───────" "────────" "─────" "────"

    jq -r '.[] | [.name, (.sessions | tostring), (.original_bytes | tostring), .archived_at] | @tsv' "$index_file" 2>/dev/null | \
    while IFS=$'\t' read -r name sessions orig_bytes date; do
        local archive_path="$ARCHIVES_DIR/$name"
        local archive_size="deleted"
        if [[ -f "$archive_path" ]]; then
            local actual_bytes
            actual_bytes=$(wc -c < "$archive_path" | tr -d ' ')
            archive_size=$(format_size "$actual_bytes")
        fi
        local display_date="${date:0:10}"
        printf "  %-40s %8s %10s  %s\n" "$name" "$sessions" "$(format_size "$orig_bytes")" "$display_date"
    done

    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Setup Module — First-Run Wizard
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Interactive first-run setup wizard
# Parameters: None
# Returns: 0
# Usage: cmd_setup
cmd_setup() {
    echo -e "${COLOR_GREEN}"
    echo ' ██████╗ ██████╗███╗   ███╗'
    echo '██╔════╝██╔════╝████╗ ████║'
    echo '██║     ██║     ██╔████╔██║'
    echo '██║     ██║     ██║╚██╔╝██║'
    echo '╚██████╗╚██████╗██║ ╚═╝ ██║'
    echo -e ' ╚═════╝ ╚═════╝╚═╝     ╚═╝'"${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD}CCM Setup Wizard${COLOR_RESET}  ${COLOR_GREEN}v${CCM_VERSION}${COLOR_RESET}"
    echo ""

    # Step 1: Dependencies
    echo -e "${COLOR_BOLD}Step 1: Checking dependencies${COLOR_RESET}"
    local deps_ok=1

    if command -v jq &>/dev/null; then
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} jq $(jq --version 2>/dev/null)"
    else
        echo -e "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} jq — install with: brew install jq"
        deps_ok=0
    fi

    if command -v curl &>/dev/null; then
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} curl"
    else
        echo -e "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} curl — install with: brew install curl"
        deps_ok=0
    fi

    local bash_ver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    if [[ "${BASH_VERSINFO[0]}" -ge 4 ]] && [[ "${BASH_VERSINFO[1]}" -ge 4 || "${BASH_VERSINFO[0]}" -ge 5 ]]; then
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} bash $bash_ver"
    else
        echo -e "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} bash $bash_ver — need 4.4+: brew install bash"
        deps_ok=0
    fi

    if [[ "$deps_ok" -eq 0 ]]; then
        echo ""
        log_error "Install missing dependencies and re-run 'ccm setup'."
        return 1
    fi
    echo ""

    # Step 2: Detect Claude Code
    echo -e "${COLOR_BOLD}Step 2: Detecting Claude Code${COLOR_RESET}"
    local claude_bin
    claude_bin=$(command -v claude 2>/dev/null)
    if [[ -n "$claude_bin" ]]; then
        local claude_ver
        claude_ver=$(claude --version 2>/dev/null | head -1 || echo "unknown")
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Claude Code: $claude_ver"
    else
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Claude Code not found in PATH"
        echo "  Install: https://code.claude.com"
    fi
    echo ""

    # Step 3: Import current account
    echo -e "${COLOR_BOLD}Step 3: Account setup${COLOR_RESET}"
    local current_email
    current_email=$(get_current_account 2>/dev/null || echo "none")

    if [[ "$current_email" != "none" ]]; then
        echo "  Found logged-in account: $current_email"

        if [[ -f "$SEQUENCE_FILE" ]] && account_exists "$current_email"; then
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Already managed by CCM"
        else
            echo -n "  Import this account? (Y/n): "
            read -r import_choice
            if [[ "$import_choice" != "n" && "$import_choice" != "N" ]]; then
                cmd_add_account
            fi
        fi
    else
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} No account logged in. Log in with 'claude' first."
    fi
    echo ""

    # Step 4: Statusline
    echo -e "${COLOR_BOLD}Step 4: Statusline${COLOR_RESET}"
    local statusline_path="$HOME/.claude/ccm-statusline.sh"
    if [[ -f "$statusline_path" ]]; then
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Already installed"
    else
        echo -n "  Install CCM statusline? (Y/n): "
        read -r sl_choice
        if [[ "$sl_choice" != "n" && "$sl_choice" != "N" ]]; then
            cmd_statusline install
        fi
    fi
    echo ""

    # Step 5: Shell hook
    echo -e "${COLOR_BOLD}Step 5: Shell hook (auto-switch on cd)${COLOR_RESET}"
    local shell_rc=""
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == *zsh* ]]; then
        shell_rc="$HOME/.zshrc"
    else
        shell_rc="$HOME/.bashrc"
    fi

    if [[ -f "$shell_rc" ]] && grep -qF 'ccm hook' "$shell_rc" 2>/dev/null; then
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Already in $shell_rc"
    else
        echo "  This adds auto-switching when you cd into a bound project."
        echo -n "  Add to $shell_rc? (Y/n): "
        read -r hook_choice
        if [[ "$hook_choice" != "n" && "$hook_choice" != "N" ]]; then
            echo "" >> "$shell_rc"
            echo '# CCM — auto-switch Claude Code account on cd' >> "$shell_rc"
            echo 'eval "$(ccm hook)"' >> "$shell_rc"
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Added to $shell_rc"
        fi
    fi
    echo ""

    # Step 6: Project init
    echo -e "${COLOR_BOLD}Step 6: Project setup${COLOR_RESET}"
    if [[ -f ".claudeignore" ]]; then
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} .claudeignore exists"
    else
        echo -n "  Generate .claudeignore for current project? (Y/n): "
        read -r init_choice
        if [[ "$init_choice" != "n" && "$init_choice" != "N" ]]; then
            cmd_init
        fi
    fi
    echo ""

    # Quick start
    echo -e "${COLOR_BOLD}Quick Start Cheatsheet${COLOR_RESET}"
    echo "  ────────────────────────────────"
    echo "  ccm add                  Add another account"
    echo "  ccm alias 1 work         Name your accounts"
    echo "  ccm switch work          Switch accounts"
    echo "  ccm bind . work          Bind project to account"
    echo "  ccm usage dashboard      View per-account usage"
    echo ""
    log_success "Setup complete!"
}

# ──────────────────────────────────────────────────────────────────────────────
# Recover Module — Error Recovery
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Detects and fixes inconsistent credential state from interrupted operations
# Parameters: None
# Returns: 0 on success
# Usage: cmd_recover
cmd_recover() {
    echo -e "${COLOR_BOLD}CCM Recovery — Checking credential consistency${COLOR_RESET}"
    echo ""

    local issues=0

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No sequence.json found — nothing to recover."
        return 0
    fi

    # Check 1: sequence.json vs credential files
    echo -e "${COLOR_BOLD}Check 1: Credential files${COLOR_RESET}"
    local account_count
    account_count=$(jq '.accounts | length' "$SEQUENCE_FILE")

    while IFS=$'\t' read -r num email; do
        [[ -z "$num" || -z "$email" ]] && continue

        local creds_path="$BACKUP_DIR/credentials/account-${num}-${email}"
        local config_path="$BACKUP_DIR/configs/account-${num}-${email}.json"

        if [[ ! -f "$creds_path" ]] && [[ ! -d "$creds_path" ]]; then
            echo -e "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} Missing credentials for Account-$num ($email)"
            issues=$((issues + 1))
        else
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Account-$num ($email) credentials present"
        fi

        if [[ ! -f "$config_path" ]]; then
            echo -e "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} Missing config for Account-$num ($email)"
            issues=$((issues + 1))
        fi
    done < <(jq -r '.accounts | to_entries[] | [.key, .value.email] | @tsv' "$SEQUENCE_FILE" 2>/dev/null)
    echo ""

    # Check 2: Active account consistency
    echo -e "${COLOR_BOLD}Check 2: Active account state${COLOR_RESET}"
    local active_num
    active_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    local active_email
    active_email=$(jq -r --arg n "$active_num" '.accounts[$n].email // empty' "$SEQUENCE_FILE")
    local current_email
    current_email=$(get_current_account 2>/dev/null || echo "none")

    if [[ "$current_email" == "none" ]]; then
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} No active account in Claude Code config"
        issues=$((issues + 1))
    elif [[ "$current_email" != "$active_email" ]]; then
        echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Active email mismatch:"
        echo "    Claude Code: $current_email"
        echo "    CCM expects: $active_email (Account-$active_num)"
        issues=$((issues + 1))
    else
        echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Active account matches: $current_email (Account-$active_num)"
    fi
    echo ""

    # Check 3: Keychain consistency (macOS only)
    local platform
    platform=$(detect_platform)
    if [[ "$platform" == "macos" ]]; then
        echo -e "${COLOR_BOLD}Check 3: Keychain entries (macOS)${COLOR_RESET}"
        local keychain_ok=1
        if security find-generic-password -s "claude-oauth-credentials" -w &>/dev/null; then
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Keychain entry for claude-oauth-credentials exists"
        else
            echo -e "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} Missing Keychain entry for claude-oauth-credentials"
            keychain_ok=0
            issues=$((issues + 1))
        fi
        echo ""
    fi

    # Check 4: Profile directories
    if [[ -d "$PROFILES_DIR" ]]; then
        echo -e "${COLOR_BOLD}Check 4: Profile directories${COLOR_RESET}"
        for profile_dir in "$PROFILES_DIR"/*/; do
            [[ -d "$profile_dir" ]] || continue
            local pname
            pname=$(basename "$profile_dir")
            if [[ -f "$profile_dir/.claude.json" ]]; then
                echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} Profile '$pname' has valid config"
            else
                echo -e "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} Profile '$pname' is missing .claude.json"
                issues=$((issues + 1))
            fi
        done
        echo ""
    fi

    # Summary
    if [[ "$issues" -eq 0 ]]; then
        log_success "No issues found. Credential state is consistent."
    else
        echo -e "${COLOR_BOLD}Found $issues issue(s).${COLOR_RESET}"
        echo ""
        echo "Remediation steps:"
        echo "  1. Run 'ccm verify' to check all accounts"
        echo "  2. Re-add missing accounts with 'ccm switch <account>' then 'ccm add'"
        echo "  3. For profile issues, delete and recreate: ccm profiles delete <name>"
    fi
}


# ──────────────────────────────────────────────────────────────────────────────
# Statusline Module — Claude Code Status Bar Integration
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Installs or removes the CCM statusline for Claude Code
# Parameters: $1 — subcommand (install|remove)
# Returns: 0 on success
# Usage: cmd_statusline install | cmd_statusline remove
cmd_statusline() {
    local action="${1:-install}"
    local script_path="$HOME/.claude/ccm-statusline.sh"
    local settings_file="$HOME/.claude/settings.json"

    case "$action" in
        install)
            echo -e "${COLOR_BOLD}CCM Statusline Setup${COLOR_RESET}"
            echo ""

            mkdir -p "$HOME/.claude"

            # Create the statusline script
            cat > "$script_path" << 'STATUSLINE_EOF'
#!/usr/bin/env bash
# CCM Statusline — smart multi-line display for Claude Code

input=$(cat)

# ── Colors ──
R="\033[0m" C="\033[36m" D="\033[90m" G="\033[32m" Y="\033[33m" RED="\033[31m"

# ── Extract all session data in a single jq call for performance ──
# Uses tab-delimited output with read instead of eval to prevent command injection
IFS=$'\t' read -r PCT IN_TOK CC_TOK CR_TOK COST DUR_MS API_MS CWD RL5_PCT RL5_RESET RL7_PCT RL7_RESET CC_VER < <(
    echo "$input" | jq -r '[
        (.context_window.used_percentage // 0 | floor),
        (.context_window.current_usage.input_tokens // 0),
        (.context_window.current_usage.cache_creation_input_tokens // 0),
        (.context_window.current_usage.cache_read_input_tokens // 0),
        (.cost.total_cost_usd // 0),
        (.cost.total_duration_ms // 0),
        (.cost.total_api_duration_ms // 0),
        (.cwd // ""),
        (.rate_limits.five_hour.used_percentage // "" | tostring),
        (.rate_limits.five_hour.resets_at // "" | tostring),
        (.rate_limits.seven_day.used_percentage // "" | tostring),
        (.rate_limits.seven_day.resets_at // "" | tostring),
        (.version // "")
    ] | @tsv' 2>/dev/null
)

TOKENS=$((IN_TOK + CC_TOK + CR_TOK))

# ── Context bar (10 chars) ──
PCT_NUM=${PCT:-0}
FILLED=$((PCT_NUM / 10))
EMPTY=$((10 - FILLED))
BAR=""
for ((i=0; i<FILLED; i++)); do BAR+="▓"; done
for ((i=0; i<EMPTY; i++)); do BAR+="░"; done

if [[ "$PCT_NUM" -ge 90 ]]; then BAR_C="$RED"
elif [[ "$PCT_NUM" -ge 70 ]]; then BAR_C="$Y"
else BAR_C="$G"; fi

# ── Format tokens (K/M) ──
if [[ "$TOKENS" -ge 1000000 ]]; then
    TOK_FMT="$(awk -v t="$TOKENS" 'BEGIN{printf "%.1fM", t/1000000}')"
elif [[ "$TOKENS" -ge 1000 ]]; then
    TOK_FMT="$(awk -v t="$TOKENS" 'BEGIN{printf "%.0fK", t/1000}')"
else
    TOK_FMT="${TOKENS}"
fi

# ── Format cost ──
COST_FMT=$(awk -v c="$COST" 'BEGIN{printf "$%.2f", c}' 2>/dev/null || echo "\$$COST")

# ── Format session duration ──
DUR_S=$((DUR_MS / 1000))
if [[ "$DUR_S" -ge 3600 ]]; then
    DUR_FMT="$((DUR_S / 3600))h$((DUR_S % 3600 / 60))m"
elif [[ "$DUR_S" -ge 60 ]]; then
    DUR_FMT="$((DUR_S / 60))m"
else
    DUR_FMT="${DUR_S}s"
fi

# ── Format API latency ──
API_S=$((API_MS / 1000))
if [[ "$API_S" -ge 3600 ]]; then
    API_FMT="$((API_S / 3600))h$((API_S % 3600 / 60))m"
elif [[ "$API_S" -ge 60 ]]; then
    API_FMT="$((API_S / 60))m"
elif [[ "$API_S" -gt 0 ]]; then
    API_FMT="${API_S}s"
else
    API_FMT=""
fi

# ── Token burn rate (tokens per minute) ──
BURN_FMT=""
if [[ "$DUR_S" -gt 60 ]] && [[ "$TOKENS" -gt 0 ]]; then
    BURN=$((TOKENS / (DUR_S / 60)))
    if [[ "$BURN" -ge 1000000 ]]; then
        BURN_FMT="$(awk -v b="$BURN" 'BEGIN{printf "%.1fM", b/1000000}')/m"
    elif [[ "$BURN" -ge 1000 ]]; then
        BURN_FMT="$(awk -v b="$BURN" 'BEGIN{printf "%.0fK", b/1000}')/m"
    else
        BURN_FMT="${BURN}/m"
    fi
fi

# ── Format rate limits (5hr + 7day) ──
_fmt_rl() {
    local pct="$1" reset="$2" label="$3"
    [[ -z "$pct" || "$pct" == "null" ]] && return
    local pint=$(echo "$pct" | cut -d. -f1)
    local rc="$G"
    [[ "$pint" -ge 80 ]] && rc="$RED"
    [[ "$pint" -ge 60 ]] && [[ "$pint" -lt 80 ]] && rc="$Y"
    local rfmt=""
    if [[ -n "$reset" ]] && [[ "$reset" != "null" ]]; then
        case "$(uname)" in
            Darwin) rfmt=$(date -r "$reset" +%H:%M 2>/dev/null) ;;
            *)      rfmt=$(date -d "@$reset" +%H:%M 2>/dev/null) ;;
        esac
    fi
    printf " ${D}·${R} ${rc}${label}: ${pint}%%${R}"
    [[ -n "$rfmt" ]] && printf "${D} ↻${rfmt}${R}"
}

RL_FMT=""
RL_FMT+="$(_fmt_rl "$RL5_PCT" "$RL5_RESET" "5hr")"
RL_FMT+="$(_fmt_rl "$RL7_PCT" "$RL7_RESET" "7d")"

# ── Write rate limits to shared file for ccm watch ──
RL_FILE="$HOME/.claude-switch-backup/rate-limits.json"
if [[ -n "$RL5_PCT" && "$RL5_PCT" != "null" ]] || [[ -n "$RL7_PCT" && "$RL7_PCT" != "null" ]]; then
    mkdir -p "$(dirname "$RL_FILE")" 2>/dev/null
    cat > "${RL_FILE}.tmp" 2>/dev/null << RLJSON
{"five_hour":{"used_percentage":${RL5_PCT:-0},"resets_at":${RL5_RESET:-0}},"seven_day":{"used_percentage":${RL7_PCT:-0},"resets_at":${RL7_RESET:-0}},"updated_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
RLJSON
    mv "${RL_FILE}.tmp" "$RL_FILE" 2>/dev/null
fi

# ── Git branch ──
BRANCH=""
if [[ -n "$CWD" ]] && command -v git &>/dev/null; then
    BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
fi

# ── Directory (short) ──
DIR_SHORT=""
if [[ -n "$CWD" ]]; then
    DIR_SHORT="${CWD/#$HOME/~}"
    [[ ${#DIR_SHORT} -gt 30 ]] && DIR_SHORT="…${DIR_SHORT: -29}"
fi

# ── CCM account data (direct file read + env var fallback) ──
SEQ="$HOME/.claude-switch-backup/sequence.json"
CONF="$HOME/.claude/.claude.json"
[[ -f "$CONF" ]] || CONF="$HOME/.claude.json"

ALIAS="" EMAIL_SHORT="" HEALTH="" TOTAL_ACCTS=0
if [[ -f "$SEQ" ]] && [[ -f "$CONF" ]]; then
    # Use CLAUDE_CODE_USER_EMAIL env var if available (v2.1.51+), fall back to config file
    EMAIL="${CLAUDE_CODE_USER_EMAIL:-}"
    [[ -z "$EMAIL" ]] && EMAIL=$(jq -r '.oauthAccount.emailAddress // empty' "$CONF" 2>/dev/null)
    if [[ -n "$EMAIL" ]]; then
        EMAIL_SHORT="$EMAIL"
        ACCT_DATA=$(jq -r --arg e "$EMAIL" '
            .accounts | to_entries[] | select(.value.email == $e) |
            "\(.value.alias // "")\t\(.value.healthStatus // "unknown")"
        ' "$SEQ" 2>/dev/null)
        if [[ -n "$ACCT_DATA" ]]; then
            ALIAS=$(echo "$ACCT_DATA" | cut -f1)
            HEALTH=$(echo "$ACCT_DATA" | cut -f2)
        fi
        TOTAL_ACCTS=$(jq '.accounts | length' "$SEQ" 2>/dev/null || echo "0")
    fi
fi

# ── Compact warning ──
COMPACT_WARN=""
if [[ "$PCT_NUM" -ge 80 ]]; then
    COMPACT_WARN=" ${D}·${R} ${Y}⚠ /compact${R}"
fi

# ── LINE 1: Context + tokens + cost + duration + API + burn rate + rate limits ──
L1="${BAR_C}${BAR}${R} ${PCT_NUM}% ${D}·${R} ${TOK_FMT} tokens ${D}·${R} ${COST_FMT} ${D}·${R} ${DUR_FMT}"
[[ -n "$BURN_FMT" ]] && L1+=" ${D}·${R} ${BURN_FMT}"
L1+="${RL_FMT}"
echo -e "$L1"

# ── LINE 2: Directory + branch + version + compact warning ──
L2="${C}${DIR_SHORT}${R}"
[[ -n "$BRANCH" ]] && L2+=" ${D}·${R} ${G}${BRANCH}${R}"
[[ -n "$CC_VER" ]] && L2+=" ${D}· v${CC_VER}${R}"
L2+="${COMPACT_WARN}"
echo -e "$L2"

# ── LINE 3: Account info (only if 2+ accounts managed) ──
if [[ "$TOTAL_ACCTS" -ge 2 ]]; then
    ACCT_LABEL="${ALIAS:-$EMAIL_SHORT}"
    case "$HEALTH" in
        healthy)  H="${G}●${R}" ;;
        degraded) H="${Y}●${R}" ;;
        *)        H="${RED}●${R}" ;;
    esac
    # Check for bound account in current directory
    BOUND=""
    if [[ -n "$CWD" ]] && [[ -f "$SEQ" ]]; then
        BOUND_ACCT=$(jq -r --arg p "$CWD" '.bindings[$p] // empty' "$SEQ" 2>/dev/null)
        if [[ -n "$BOUND_ACCT" ]]; then
            BOUND_ALIAS=$(jq -r --arg n "$BOUND_ACCT" '.accounts[$n].alias // ("acct-" + $n)' "$SEQ" 2>/dev/null)
            BOUND=" ${D}· bound:${R} ${C}${BOUND_ALIAS}${R}"
        fi
    fi
    echo -e "${C}${ACCT_LABEL}${R} ${D}(${EMAIL_SHORT})${R} ${D}·${R} ${TOTAL_ACCTS} accounts ${D}·${R} ${H}${BOUND}"
fi
STATUSLINE_EOF

            chmod +x "$script_path"
            log_success "Created statusline script: $script_path"

            # Update settings.json to use the statusline
            if [[ -f "$settings_file" ]]; then
                local orig_perms
                orig_perms=$(stat -f '%Lp' "$settings_file" 2>/dev/null || stat -c '%a' "$settings_file" 2>/dev/null || echo "644")
                local updated
                updated=$(jq --arg cmd "$script_path" '
                    .statusLine = {
                        type: "command",
                        command: $cmd,
                        padding: 2
                    }
                ' "$settings_file")
                echo "$updated" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"
                chmod "$orig_perms" "$settings_file"
            else
                mkdir -p "$HOME/.claude"
                echo "{}" | jq --arg cmd "$script_path" '
                    .statusLine = {
                        type: "command",
                        command: $cmd,
                        padding: 2
                    }
                ' > "$settings_file"
            fi
            log_success "Updated settings.json with statusline config"

            echo ""
            echo "  Restart Claude Code to see the statusline."
            echo "  Shows your active CCM account name in the status bar."
            ;;

        remove)
            if [[ -f "$script_path" ]]; then
                rm -f "$script_path"
                log_success "Removed statusline script"
            fi

            if [[ -f "$settings_file" ]]; then
                local orig_perms
                orig_perms=$(stat -f '%Lp' "$settings_file" 2>/dev/null || stat -c '%a' "$settings_file" 2>/dev/null || echo "644")
                local updated
                updated=$(jq 'del(.statusLine)' "$settings_file")
                echo "$updated" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"
                chmod "$orig_perms" "$settings_file"
                log_success "Removed statusline from settings.json"
            fi

            rm -f "/tmp/.ccm-statusline-cache"
            echo "  Restart Claude Code to remove the statusline."
            ;;

        *)
            log_error "Usage: ccm statusline [install|remove]"
            return 1
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Init Module — Project Setup
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Auto-generates .claudeignore based on detected project type
# Parameters: [--force] — overwrite existing .claudeignore
# Returns: 0 on success, 1 on failure
# Usage: cmd_init | cmd_init --force
cmd_init() {
    local force=0
    if [[ "${1:-}" == "--force" ]]; then
        force=1
    fi

    local target=".claudeignore"

    if [[ -f "$target" ]] && [[ "$force" -eq 0 ]]; then
        log_info ".claudeignore already exists. Use --force to overwrite."
        return 0
    fi

    # Detect project type(s) from manifest files
    local types=()
    [[ -f "package.json" ]]      && types+=("node")
    [[ -f "pyproject.toml" || -f "setup.py" || -f "requirements.txt" || -f "Pipfile" ]] && types+=("python")
    [[ -f "go.mod" ]]            && types+=("go")
    [[ -f "Cargo.toml" ]]        && types+=("rust")
    [[ -f "build.gradle" || -f "pom.xml" ]]   && types+=("java")
    [[ -f "Gemfile" ]]           && types+=("ruby")
    [[ -f "composer.json" ]]     && types+=("php")
    compgen -G "*.sln" >/dev/null 2>&1 || compgen -G "*.csproj" >/dev/null 2>&1 && types+=("dotnet")
    [[ -f "pubspec.yaml" ]]      && types+=("dart")
    [[ -f "Package.swift" ]]     && types+=("swift")

    if [[ ${#types[@]} -eq 0 ]]; then
        types+=("generic")
    fi

    log_info "Detected project type(s): ${types[*]}"

    # Build .claudeignore content
    local content=""

    # Common patterns (always included)
    content+="# Generated by ccm init
# Common
.git/
.DS_Store
*.log
*.tmp
*.swp
*~
"

    for ptype in "${types[@]}"; do
        case "$ptype" in
            node)
                content+="
# Node.js
node_modules/
dist/
build/
.next/
.nuxt/
.output/
coverage/
.nyc_output/
*.min.js
*.min.css
*.bundle.js
*.chunk.js
package-lock.json
yarn.lock
pnpm-lock.yaml
.pnp.*
"
                ;;
            python)
                content+="
# Python
__pycache__/
*.pyc
*.pyo
.venv/
venv/
env/
.env/
*.egg-info/
dist/
build/
.tox/
.pytest_cache/
.mypy_cache/
.ruff_cache/
htmlcov/
"
                ;;
            go)
                content+="
# Go
vendor/
*.exe
*.test
*.out
"
                ;;
            rust)
                content+="
# Rust
target/
Cargo.lock
"
                ;;
            java)
                content+="
# Java
target/
build/
.gradle/
*.class
*.jar
*.war
*.ear
.idea/
*.iml
"
                ;;
            ruby)
                content+="
# Ruby
vendor/bundle/
.bundle/
coverage/
tmp/
log/
"
                ;;
            php)
                content+="
# PHP
vendor/
node_modules/
storage/framework/
bootstrap/cache/
.phpunit.result.cache
composer.lock
"
                ;;
            dotnet)
                content+="
# .NET
bin/
obj/
*.dll
*.exe
*.pdb
packages/
"
                ;;
            dart)
                content+="
# Dart/Flutter
.dart_tool/
build/
.packages
.flutter-plugins
.flutter-plugins-dependencies
pubspec.lock
"
                ;;
            swift)
                content+="
# Swift
.build/
DerivedData/
*.xcodeproj/xcuserdata/
Packages/
"
                ;;
            generic)
                content+="
# Build artifacts
dist/
build/
out/
"
                ;;
        esac
    done

    printf '%s' "$content" > "$target"
    log_success "Generated $target for: ${types[*]}"
    echo ""
    echo "  Patterns added: $(grep -cE '^[^#[:space:]]' "$target" 2>/dev/null || echo "0") rules"
    echo "  Edit $target to customize further."
}

# ──────────────────────────────────────────────────────────────────────────────
# Permissions Module — Permission Rules Audit
# ──────────────────────────────────────────────────────────────────────────────

# Purpose: Audits permission rules in settings files for duplicates, dead rules, and bloat
# Parameters: [--fix] — auto-remove duplicate and dead rules
# Returns: 0 on success
# Usage: cmd_permissions audit | cmd_permissions audit --fix
cmd_permissions() {
    case "${1:-}" in
        audit)  shift; permissions_audit "$@" ;;
        "")     show_help permissions ;;
        *)      log_error "Unknown permissions command '$1'"; show_help permissions; exit 1 ;;
    esac
}

# Purpose: Scans settings.json and settings.local.json for permission rule issues
# Parameters: [--fix] — auto-deduplicate and clean
# Returns: 0 on success
# Usage: permissions_audit | permissions_audit --fix
permissions_audit() {
    local fix_mode=0
    if [[ "${1:-}" == "--fix" ]]; then
        fix_mode=1
    fi

    echo -e "${COLOR_BOLD}Permission Rules Audit${COLOR_RESET}"
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    echo ""

    local settings_file="$HOME/.claude/settings.json"
    local local_file="$HOME/.claude/settings.local.json"
    local issues=0

    # Audit global settings
    for file in "$settings_file" "$local_file"; do
        [[ -f "$file" ]] || continue

        local filename
        filename=$(basename "$file")
        echo -e "${COLOR_BOLD}$filename:${COLOR_RESET}"

        # Count rules per category
        local allow_count deny_count ask_count
        allow_count=$(jq '[.permissions.allow // [] | .[] ] | length' "$file" 2>/dev/null || echo "0")
        deny_count=$(jq '[.permissions.deny // [] | .[] ] | length' "$file" 2>/dev/null || echo "0")
        ask_count=$(jq '[.permissions.ask // [] | .[] ] | length' "$file" 2>/dev/null || echo "0")
        local total=$((allow_count + deny_count + ask_count))

        echo "  Rules: $allow_count allow, $deny_count deny, $ask_count ask ($total total)"

        # Check for duplicates
        local allow_dupes deny_dupes ask_dupes
        allow_dupes=$(jq '[.permissions.allow // [] | .[] ] | group_by(.) | map(select(length > 1) | {rule: .[0], count: length}) | length' "$file" 2>/dev/null || echo "0")
        deny_dupes=$(jq '[.permissions.deny // [] | .[] ] | group_by(.) | map(select(length > 1) | {rule: .[0], count: length}) | length' "$file" 2>/dev/null || echo "0")
        ask_dupes=$(jq '[.permissions.ask // [] | .[] ] | group_by(.) | map(select(length > 1) | {rule: .[0], count: length}) | length' "$file" 2>/dev/null || echo "0")

        local total_dupes=$((allow_dupes + deny_dupes + ask_dupes))
        if [[ "$total_dupes" -gt 0 ]]; then
            echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Duplicates: $allow_dupes in allow, $deny_dupes in deny, $ask_dupes in ask"
            issues=$((issues + total_dupes))

            # Show duplicate rules
            if [[ "$allow_dupes" -gt 0 ]]; then
                jq -r '[.permissions.allow // [] | .[] ] | group_by(.) | map(select(length > 1)) | .[] | "     allow: \(.[0]) (x\(length))"' "$file" 2>/dev/null
            fi
            if [[ "$deny_dupes" -gt 0 ]]; then
                jq -r '[.permissions.deny // [] | .[] ] | group_by(.) | map(select(length > 1)) | .[] | "     deny: \(.[0]) (x\(length))"' "$file" 2>/dev/null
            fi
            if [[ "$ask_dupes" -gt 0 ]]; then
                jq -r '[.permissions.ask // [] | .[] ] | group_by(.) | map(select(length > 1)) | .[] | "     ask: \(.[0]) (x\(length))"' "$file" 2>/dev/null
            fi
        else
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} No duplicates"
        fi

        # Check for contradictions (same rule in both allow and deny)
        local contradictions
        contradictions=$(jq '[(.permissions.allow // []) as $a | (.permissions.deny // []) as $d | $a[] as $rule | select($d | index($rule)) | $rule] | unique | length' "$file" 2>/dev/null || echo "0")
        if [[ "$contradictions" -gt 0 ]]; then
            echo -e "  ${COLOR_RED}${SYM_ERR}${COLOR_RESET} Contradictions: $contradictions rule(s) in both allow AND deny"
            jq -r '[(.permissions.allow // []) as $a | (.permissions.deny // []) as $d | $a[] as $rule | select($d | index($rule)) | $rule] | unique[] | "     \(.)"' "$file" 2>/dev/null
            issues=$((issues + contradictions))
        else
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} No contradictions"
        fi

        # Check for verbatim strings that could be wildcards
        local verbatim_count
        verbatim_count=$(jq '[.permissions.allow // [] | .[] | select(test("^Bash\\(") and (test("[*:]") | not))] | length' "$file" 2>/dev/null || echo "0")
        if [[ "$verbatim_count" -gt 0 ]]; then
            echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} Verbatim rules: $verbatim_count Bash rules without wildcards (from 'Always Allow')"
            issues=$((issues + 1))

            # Show top offenders
            jq -r '[.permissions.allow // [] | .[] | select(test("^Bash\\(") and (test("[*:]") | not))] | .[0:5][] | "     \(.)"' "$file" 2>/dev/null
            local remaining=$((verbatim_count - 5))
            [[ "$remaining" -gt 0 ]] && echo "     ... and $remaining more"
        else
            echo -e "  ${COLOR_GREEN}${SYM_OK}${COLOR_RESET} No verbatim Bash rules"
        fi

        # Warn on high rule count
        if [[ "$total" -gt 100 ]]; then
            echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} High rule count ($total) — consider consolidating with wildcards"
            issues=$((issues + 1))
        elif [[ "$total" -gt 50 ]]; then
            echo -e "  ${COLOR_YELLOW}${SYM_WARN}${COLOR_RESET} $total rules — approaching bloat threshold"
        fi

        # Fix mode: remove duplicates
        if [[ "$fix_mode" -eq 1 ]] && [[ "$total_dupes" -gt 0 ]]; then
            # Backup before modifying
            cp "$file" "${file}.bak"
            log_step "  Backup saved to ${filename}.bak"

            local fixed
            fixed=$(jq '
                .permissions.allow = ([.permissions.allow // [] | .[] ] | unique) |
                .permissions.deny = ([.permissions.deny // [] | .[] ] | unique) |
                .permissions.ask = ([.permissions.ask // [] | .[] ] | unique)
            ' "$file")

            # Preserve original permissions (don't apply chmod 600)
            local orig_perms
            orig_perms=$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo "644")
            echo "$fixed" > "${file}.tmp" && mv "${file}.tmp" "$file"
            chmod "$orig_perms" "$file"

            local new_allow new_deny new_ask
            new_allow=$(echo "$fixed" | jq '[.permissions.allow // [] | .[]] | length')
            new_deny=$(echo "$fixed" | jq '[.permissions.deny // [] | .[]] | length')
            new_ask=$(echo "$fixed" | jq '[.permissions.ask // [] | .[]] | length')
            local removed=$(( (allow_count + deny_count + ask_count) - (new_allow + new_deny + new_ask) ))
            log_step "  Removed $removed duplicate rule(s)"
        fi

        echo ""
    done

    # Summary
    if [[ "$issues" -eq 0 ]]; then
        log_success "Permission rules look clean."
    else
        echo -e "${COLOR_BOLD}Summary:${COLOR_RESET} $issues issue(s) found"
        if [[ "$fix_mode" -eq 0 ]]; then
            echo "Run 'ccm permissions audit --fix' to auto-fix duplicates."
        fi
    fi
}

# Main script logic
# Purpose: Entry point — parses global flags, initializes colors, dispatches subcommands
# Parameters: All CLI arguments
# Returns: Exit code from dispatched subcommand
# Usage: main "$@"
main() {
    local args=("$@")
    for arg in "${args[@]}"; do
        case "$arg" in --no-color) NO_COLOR=1 ;; esac
    done
    init_colors
    local clean_args=()
    for arg in "${args[@]}"; do
        [[ "$arg" != "--no-color" ]] && clean_args+=("$arg")
    done
    set -- "${clean_args[@]}"

    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        log_error "Do not run this script as root (unless running in a container)"
        exit 1
    fi
    check_bash_version
    check_dependencies

    case "${1:-}" in
        add)            cmd_add_account ;;
        remove)         shift; cmd_remove_account "$@" ;;
        switch)         shift;
                        if [[ "${1:-}" == "--isolated" ]]; then
                            shift; switch_isolated "$@"
                        elif [[ $# -gt 0 ]]; then
                            cmd_switch_to "$@"
                        else
                            cmd_switch
                        fi ;;
        undo)           cmd_undo ;;
        list)           cmd_list ;;
        alias)          shift; cmd_set_alias "$@" ;;
        verify)         shift; cmd_verify "$@" ;;
        history)        cmd_history ;;
        export)         shift; cmd_export "$@" ;;
        import)         shift; cmd_import "$@" ;;
        reorder)        shift; cmd_reorder "$@" ;;
        bind)           shift; cmd_bind "$@" ;;
        unbind)         shift; cmd_unbind "$@" ;;
        hook)           shift; cmd_hook "$@" ;;
        profiles)       shift; cmd_profiles "$@" ;;
        watch)          shift; cmd_watch "$@" ;;
        recover)        cmd_recover ;;
        setup)          cmd_setup ;;
        session)        shift; cmd_session "$@" ;;
        env)            shift; cmd_env "$@" ;;
        usage)          shift; cmd_usage "$@" ;;
        doctor)         shift; cmd_doctor "$@" ;;
        clean)          shift; cmd_clean "$@" ;;
        init)           shift; cmd_init "$@" ;;
        # Deprecated in v4.0 — show migration notice
        status)         log_info "Removed in v4.0. Use 'ccm list' or Claude Code's native /status."; exit 0 ;;
        interactive)    log_info "Removed in v4.0. Use direct CLI commands instead."; exit 0 ;;
        optimize)       log_info "Removed in v4.0. Use Claude Code's native /insights command."; exit 0 ;;
        launch)         log_info "Removed in v4.0. Use 'claude --permission-mode auto' or /sandbox directly."; exit 0 ;;
        permissions)    shift; cmd_permissions "$@" ;;
        statusline)     shift; cmd_statusline "$@" ;;
        help)           shift; show_help "$@" ;;
        version)        show_version ;;
        --help)         show_help ;;
        --version)      show_version ;;
        "")             show_help ;;
        *)              log_error "Unknown command '$1'"; echo "Run 'ccm help' for usage."; exit 1 ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

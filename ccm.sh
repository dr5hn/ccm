#!/usr/bin/env bash

# CCM — Claude Code Manager
# Multi-account switcher and management tool for Claude Code

set -euo pipefail

# Configuration
readonly CCM_VERSION="3.0"
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly SCHEMA_VERSION="3.0"
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

# Account identifier resolution function
# Resolves account number, email, or alias to account number
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Try to look up by email first
        local account_num
        account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
            return
        fi

        # Try to look up by alias
        account_num=$(jq -r --arg alias "$identifier" '.accounts | to_entries[] | select(.value.alias == $alias) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
            return
        fi

        echo ""
    fi
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    
    mv "$temp_file" "$file"
    chmod 600 "$file"
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
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
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
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
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
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
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
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
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
  "history": []
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
        migrated=$(jq --arg version "$SCHEMA_VERSION" '
            .schemaVersion = $version
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
        awk "BEGIN { printf \"%.1f GB\", $bytes / 1073741824 }"
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk "BEGIN { printf \"%.1f MB\", $bytes / 1048576 }"
    elif [[ "$bytes" -ge 1024 ]]; then
        awk "BEGIN { printf \"%.1f KB\", $bytes / 1024 }"
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
        relocate)   shift; session_relocate "$@" ;;
        clean)      shift; session_clean "$@" ;;
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

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            log_error "Invalid email format: $identifier"
            exit 1
        fi

        # Resolve email to account number
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            log_error "No account found with email: $identifier"
            exit 1
        fi
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
            last_used_formatted=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_used" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$last_used")
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

    # Resolve identifier to account number
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        if ! validate_email "$identifier"; then
            log_error "Invalid email format: $identifier"
            exit 1
        fi
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            log_error "No account found with email: $identifier"
            exit 1
        fi
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
cmd_status() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No accounts are managed yet."
        exit 0
    fi

    migrate_sequence_file

    local current_email
    current_email=$(get_current_account)

    echo -e "${COLOR_BOLD}Claude Code Account Status${COLOR_RESET}"
    echo ""

    if [[ "$current_email" != "none" ]]; then
        local account_num
        account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)

        if [[ -n "$account_num" ]]; then
            local account_info
            account_info=$(jq -r --arg num "$account_num" '.accounts[$num]' "$SEQUENCE_FILE")

            local alias last_used usage_count health
            alias=$(echo "$account_info" | jq -r '.alias // "none"')
            last_used=$(echo "$account_info" | jq -r '.lastUsed // "unknown"')
            usage_count=$(echo "$account_info" | jq -r '.usageCount // 0')
            health=$(echo "$account_info" | jq -r '.healthStatus // "unknown"')

            echo -e "${COLOR_BOLD}Active Account:${COLOR_RESET} $current_email ${COLOR_GREEN}(Account-$account_num)${COLOR_RESET}"
            echo -e "  Alias: $alias"
            echo -e "  Usage count: ${usage_count}x"

            if [[ "$last_used" != "unknown" && "$last_used" != "null" ]]; then
                local last_used_formatted
                last_used_formatted=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_used" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$last_used")
                echo -e "  Last used: $last_used_formatted"
            fi

            case "$health" in
                healthy) echo -e "  Health: ${COLOR_GREEN}●${COLOR_RESET} healthy" ;;
                degraded) echo -e "  Health: ${COLOR_YELLOW}●${COLOR_RESET} degraded" ;;
                unhealthy) echo -e "  Health: ${COLOR_RED}●${COLOR_RESET} unhealthy" ;;
                *) echo -e "  Health: unknown" ;;
            esac
        else
            echo -e "${COLOR_BOLD}Active Account:${COLOR_RESET} $current_email ${COLOR_YELLOW}(not managed)${COLOR_RESET}"
        fi
    else
        echo -e "${COLOR_BOLD}Active Account:${COLOR_RESET} ${COLOR_RED}None${COLOR_RESET}"
    fi

    echo ""
    local total_accounts
    total_accounts=$(jq '.accounts | length' "$SEQUENCE_FILE")
    echo -e "${COLOR_BOLD}Total managed accounts:${COLOR_RESET} $total_accounts"

    local schema_version
    schema_version=$(jq -r '.schemaVersion // "1.0"' "$SEQUENCE_FILE")
    echo -e "${COLOR_BOLD}Data version:${COLOR_RESET} $schema_version"
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
        time_formatted=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$timestamp")

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
    trap "rm -rf '$temp_dir'" EXIT

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
    trap "rm -rf '$temp_dir'" EXIT

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
    show_progress "Updating path references in session files"
    local files_updated=0
    local escaped_old escaped_new
    # Escape for sed (handle forward slashes and special chars)
    escaped_old=$(printf '%s\n' "$old_path" | sed 's/[&/\]/\\&/g')
    escaped_new=$(printf '%s\n' "$new_path" | sed 's/[&/\]/\\&/g')

    while IFS= read -r -d '' session_file; do
        if grep -q "$old_path" "$session_file" 2>/dev/null; then
            # Use a temp file to avoid in-place sed portability issues
            local temp_file
            temp_file=$(mktemp)
            sed "s|$old_path|$new_path|g" "$session_file" > "$temp_file"
            mv "$temp_file" "$session_file"
            ((files_updated++))
        fi
    done < <(find "$new_session_dir" -name "*.jsonl" -type f -print0 2>/dev/null)
    complete_progress

    # Step 3: Update memory files if they contain path references
    show_progress "Updating memory files"
    local memory_updated=0
    if [[ -d "$new_session_dir/memory" ]]; then
        while IFS= read -r -d '' mem_file; do
            if grep -q "$old_path" "$mem_file" 2>/dev/null; then
                local temp_file
                temp_file=$(mktemp)
                sed "s|$old_path|$new_path|g" "$mem_file" > "$temp_file"
                mv "$temp_file" "$mem_file"
                ((memory_updated++))
            fi
        done < <(find "$new_session_dir/memory" -type f -print0 2>/dev/null)
    fi
    complete_progress

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

# Interactive mode
# Purpose: Launches a menu-driven interface for account management
# Parameters: None
# Returns: Runs until user quits
# Usage: cmd_interactive
cmd_interactive() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        log_info "No accounts are managed yet."
        first_run_setup || exit 1
    fi

    migrate_sequence_file

    while true; do
        clear
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

        # Show current account
        local current_email
        current_email=$(get_current_account)

        if [[ "$current_email" != "none" ]]; then
            local account_num
            account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
            if [[ -n "$account_num" ]]; then
                local alias
                alias=$(jq -r --arg num "$account_num" '.accounts[$num].alias // "no alias"' "$SEQUENCE_FILE")
                echo -e "${COLOR_GREEN}●${COLOR_RESET} Current: Account-$account_num ($current_email) [$alias]"
            else
                echo -e "${COLOR_YELLOW}●${COLOR_RESET} Current: $current_email (not managed)"
            fi
        else
            echo -e "${COLOR_RED}●${COLOR_RESET} No active account"
        fi
        echo ""

        echo -e "${COLOR_BOLD}Available Accounts:${COLOR_RESET}"
        local idx=1
        declare -A account_map
        while IFS= read -r line; do
            local num email alias is_active
            num=$(echo "$line" | jq -r '.num')
            email=$(echo "$line" | jq -r '.email')
            alias=$(echo "$line" | jq -r '.alias // ""')
            is_active=$(echo "$line" | jq -r '.isActive')

            account_map[$idx]=$num

            local display="  $idx) Account-$num: $email"
            if [[ -n "$alias" ]]; then
                display+=" ${COLOR_CYAN}[$alias]${COLOR_RESET}"
            fi
            if [[ "$is_active" == "true" ]]; then
                display+=" ${COLOR_GREEN}(active)${COLOR_RESET}"
            fi
            echo -e "$display"
            ((idx++))
        done < <(jq -c --arg active "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" '
            .sequence[] as $num |
            .accounts["\($num)"] + {
                num: $num,
                isActive: (if "\($num)" == $active then "true" else "false" end)
            }
        ' "$SEQUENCE_FILE")

        echo ""
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
        echo ""
        echo -n "Select an option (1-$((idx-1)) or action): "

        read -r choice

        case "$choice" in
            [0-9]*)
                if [[ -n "${account_map[$choice]:-}" ]]; then
                    local target_num="${account_map[$choice]}"
                    echo ""
                    perform_switch "$target_num"
                    echo ""
                    read -p "Press Enter to continue..."
                else
                    log_error "Invalid selection"
                    sleep 1
                fi
                ;;
            s|S)
                echo ""
                cmd_switch
                echo ""
                read -p "Press Enter to continue..."
                ;;
            a|A)
                echo ""
                cmd_add_account
                echo ""
                read -p "Press Enter to continue..."
                ;;
            v|V)
                echo ""
                cmd_verify
                echo ""
                read -p "Press Enter to continue..."
                ;;
            h|H)
                echo ""
                cmd_history
                echo ""
                read -p "Press Enter to continue..."
                ;;
            u|U)
                echo ""
                cmd_undo
                echo ""
                read -p "Press Enter to continue..."
                ;;
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
                read -rp "Snapshot name (leave empty for auto): " snap_name
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
            q|Q)
                echo ""
                log_info "Goodbye!"
                exit 0
                ;;
            *)
                log_error "Invalid option"
                sleep 1
                ;;
        esac
    done
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
        session)
            echo -e "${COLOR_BOLD}ccm session — Session Management${COLOR_RESET}"
            echo ""
            echo "Usage: ccm session <subcommand>"
            echo ""
            echo -e "${COLOR_BOLD}Subcommands:${COLOR_RESET}"
            echo "  list                     List all Claude Code project sessions"
            echo "  info <project-path>      Show detailed info for a project's sessions"
            echo "  relocate <old> <new>     Relocate project sessions after moving a folder"
            echo "  clean [--dry-run]        Remove orphaned sessions (projects no longer on disk)"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm session list"
            echo "  ccm session info ."
            echo "  ccm session info ~/projects/my-app"
            echo "  ccm session relocate ~/old/project ~/new/project"
            echo "  ccm session clean --dry-run"
            echo "  ccm session clean"
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
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm usage summary"
            echo "  ccm usage top"
            echo "  ccm usage top --count 5"
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
            echo "  status                             Show active account details"
            echo "  alias <num|email> <alias>          Set friendly name for an account"
            echo ""
            echo -e "${COLOR_BOLD}Switching:${COLOR_RESET}"
            echo "  switch [num|email|alias]           Switch account (next or specific)"
            echo "  undo                               Undo last account switch"
            echo "  history                            Show account switch history"
            echo ""
            echo -e "${COLOR_BOLD}Verification & Backup:${COLOR_RESET}"
            echo "  verify [num|email]                 Verify account backups"
            echo "  export <path>                      Export accounts to archive"
            echo "  import <path>                      Import accounts from archive"
            echo ""
            echo -e "${COLOR_BOLD}Modules:${COLOR_RESET}"
            echo "  session <subcommand>               Manage Claude Code sessions"
            echo "  env <subcommand>                   Environment snapshots & audit"
            echo "  usage <subcommand>                 Usage statistics & reporting"
            echo ""
            echo -e "${COLOR_BOLD}Other:${COLOR_RESET}"
            echo "  interactive                        Launch interactive menu mode"
            echo "  help [command]                     Show help (or help for a command)"
            echo "  version                            Show version"
            echo "  --no-color                         Disable colored output"
            echo ""
            echo -e "${COLOR_BOLD}Examples:${COLOR_RESET}"
            echo "  ccm add"
            echo "  ccm alias 1 work"
            echo "  ccm switch work"
            echo "  ccm switch user@example.com"
            echo "  ccm list"
            echo "  ccm verify"
            echo "  ccm export ~/accounts-backup.tar.gz"
            echo "  ccm history"
            echo "  ccm undo"
            echo "  ccm help session"
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
    local -a source_files=(
        "$HOME/.claude/settings.json:settings.json"
        "$HOME/.claude/.claude.json:claude.json"
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

        if [[ "$stored" == "claude.json" ]] && [[ -f "$target_path" ]]; then
            # CRITICAL: Merge oauthAccount fields, preserving tokens/credentials
            show_progress "Merging $stored (preserving credentials)"
            local oauth_section
            oauth_section=$(jq '.oauthAccount' "$source_file")
            local merged
            merged=$(jq --argjson oauth "$oauth_section" '.oauthAccount = (.oauthAccount * $oauth)' "$target_path")
            echo "$merged" > "$target_path"
            complete_progress
        else
            show_progress "Restoring $stored"
            cp "$source_file" "$target_path"
            complete_progress
        fi
    done

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

    echo -e "${COLOR_BOLD}MCP Server Audit${COLOR_RESET}"
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
                echo "    Estimated token savings: $savings_str tokens/session"
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
        echo -e "  Estimated total savings: ~$total_savings tokens/session"
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
        session)        shift; cmd_session "$@" ;;
        env)            shift; cmd_env "$@" ;;
        usage)          shift; cmd_usage "$@" ;;
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
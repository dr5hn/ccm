#!/usr/bin/env bash

# CCM Release Script
# Usage: ./release.sh <version|patch|minor|major> [--dry-run]
#
# Bumps version across all files, commits, tags, and creates a GitHub release.
#
# Examples:
#   ./release.sh patch          # 3.0.1 -> 3.0.2
#   ./release.sh minor          # 3.0.1 -> 3.1.0
#   ./release.sh major          # 3.0.1 -> 4.0.0
#   ./release.sh 3.2.0          # explicit version
#   ./release.sh patch --dry-run # preview changes without applying

set -euo pipefail

# Colors
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[0;90m'
    RESET='\033[0m'
else
    GREEN='' RED='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

info()    { echo -e "${CYAN}ℹ${RESET} $*"; }
success() { echo -e "${GREEN}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
error()   { echo -e "${RED}✗${RESET} $*" >&2; }
step()    { echo -e "  ${DIM}→${RESET} $*"; }

# --- Resolve script directory and paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCM_SH="$SCRIPT_DIR/ccm.sh"
CHANGELOG="$SCRIPT_DIR/CHANGELOG.md"

# --- Parse arguments ---
DRY_RUN=false
VERSION_ARG=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Usage: ./release.sh <version|patch|minor|major> [--dry-run]"
            echo ""
            echo "Arguments:"
            echo "  patch       Bump patch version (e.g., 3.0.1 -> 3.0.2)"
            echo "  minor       Bump minor version (e.g., 3.0.1 -> 3.1.0)"
            echo "  major       Bump major version (e.g., 3.0.1 -> 4.0.0)"
            echo "  X.Y.Z       Set explicit version"
            echo ""
            echo "Options:"
            echo "  --dry-run   Preview changes without applying"
            echo "  -h, --help  Show this help"
            exit 0
            ;;
        *) VERSION_ARG="$arg" ;;
    esac
done

if [[ -z "$VERSION_ARG" ]]; then
    error "Version argument required. Usage: ./release.sh <version|patch|minor|major>"
    exit 1
fi

# --- Precondition checks ---
if [[ ! -f "$CCM_SH" ]]; then
    error "ccm.sh not found at: $CCM_SH"
    exit 1
fi

if ! command -v gh &>/dev/null; then
    error "GitHub CLI (gh) is required. Install: https://cli.github.com"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    error "jq is required. Install: brew install jq"
    exit 1
fi

# Check for uncommitted changes
if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain -- ccm.sh CHANGELOG.md)" ]]; then
    warn "You have uncommitted changes in ccm.sh or CHANGELOG.md"
    echo -n "Continue anyway? (y/N): "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Release cancelled."
        exit 0
    fi
fi

# --- Read current version ---
CURRENT_VERSION=$(grep -oP 'readonly CCM_VERSION="\K[^"]+' "$CCM_SH" 2>/dev/null \
    || grep -o 'readonly CCM_VERSION="[^"]*"' "$CCM_SH" | sed 's/readonly CCM_VERSION="//;s/"//')

if [[ -z "$CURRENT_VERSION" ]]; then
    error "Could not read CCM_VERSION from ccm.sh"
    exit 1
fi

info "Current version: ${BOLD}v${CURRENT_VERSION}${RESET}"

# --- Calculate new version ---
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
# Default missing parts to 0
MAJOR="${MAJOR:-0}"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

case "$VERSION_ARG" in
    patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
    *)
        # Validate explicit version format
        if [[ ! "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            error "Invalid version format: $VERSION_ARG (expected X.Y.Z)"
            exit 1
        fi
        NEW_VERSION="$VERSION_ARG"
        ;;
esac

info "New version:     ${BOLD}${GREEN}v${NEW_VERSION}${RESET}"
echo ""

# --- Collect files to update ---
# Map of files and what gets updated
declare -a UPDATE_FILES=()
declare -a UPDATE_DESCRIPTIONS=()

# 1. ccm.sh — CCM_VERSION constant
UPDATE_FILES+=("$CCM_SH")
UPDATE_DESCRIPTIONS+=("CCM_VERSION constant")

# 2. CHANGELOG.md — add new version section
if [[ -f "$CHANGELOG" ]]; then
    UPDATE_FILES+=("$CHANGELOG")
    UPDATE_DESCRIPTIONS+=("New changelog section")
fi

info "Files to update:"
for i in "${!UPDATE_FILES[@]}"; do
    step "${UPDATE_FILES[$i]##*/} — ${UPDATE_DESCRIPTIONS[$i]}"
done
echo ""

# --- Dry run check ---
if $DRY_RUN; then
    warn "DRY RUN — no changes will be made"
    echo ""
    echo "Would perform:"
    step "Update CCM_VERSION in ccm.sh: \"$CURRENT_VERSION\" -> \"$NEW_VERSION\""
    step "Add [${NEW_VERSION}] section to CHANGELOG.md"
    step "Git commit: \"release: v${NEW_VERSION}\""
    step "Create GitHub release: v${NEW_VERSION}"
    echo ""
    info "Run without --dry-run to apply."
    exit 0
fi

# --- Prompt for changelog entry ---
echo -e "${BOLD}Changelog entry for v${NEW_VERSION}:${RESET}"
echo -e "${DIM}(Enter lines, then an empty line to finish. Prefix with ### for section headers.)${RESET}"
echo -e "${DIM}Example:${RESET}"
echo -e "${DIM}  ### Fixed${RESET}"
echo -e "${DIM}  - Description of fix${RESET}"
echo ""

CHANGELOG_LINES=()
while true; do
    read -r -p "> " line
    [[ -z "$line" ]] && break
    CHANGELOG_LINES+=("$line")
done

if [[ ${#CHANGELOG_LINES[@]} -eq 0 ]]; then
    error "Changelog entry is required."
    exit 1
fi

echo ""

# --- Apply changes ---

# 1. Update CCM_VERSION in ccm.sh
info "Updating ccm.sh..."
sed -i.bak "s/readonly CCM_VERSION=\"$CURRENT_VERSION\"/readonly CCM_VERSION=\"$NEW_VERSION\"/" "$CCM_SH"
rm -f "$CCM_SH.bak"
success "CCM_VERSION: $CURRENT_VERSION -> $NEW_VERSION"

# 2. Update CHANGELOG.md
if [[ -f "$CHANGELOG" ]]; then
    info "Updating CHANGELOG.md..."
    TODAY=$(date +%Y-%m-%d)

    # Build the new changelog section
    NEW_SECTION="## [${NEW_VERSION}] - ${TODAY}\n"
    for line in "${CHANGELOG_LINES[@]}"; do
        NEW_SECTION+="${line}\n"
    done
    NEW_SECTION+="\n"

    # Insert after the header (line 4, before the first ## entry)
    # Find the line number of the first ## [version] entry
    FIRST_VERSION_LINE=$(grep -n '^## \[' "$CHANGELOG" | head -1 | cut -d: -f1)

    if [[ -n "$FIRST_VERSION_LINE" ]]; then
        # Insert the new section before the first version entry
        {
            head -n $((FIRST_VERSION_LINE - 1)) "$CHANGELOG"
            echo -e "$NEW_SECTION"
            tail -n +$FIRST_VERSION_LINE "$CHANGELOG"
        } > "$CHANGELOG.tmp"
        mv "$CHANGELOG.tmp" "$CHANGELOG"
    else
        # No existing version entries, append to end
        echo -e "\n$NEW_SECTION" >> "$CHANGELOG"
    fi
    success "Added [${NEW_VERSION}] section to CHANGELOG.md"
fi

echo ""

# --- Git commit ---
info "Committing version bump..."
git -C "$SCRIPT_DIR" add ccm.sh CHANGELOG.md
git -C "$SCRIPT_DIR" commit -m "$(cat <<EOF
release: v${NEW_VERSION}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
success "Committed: release: v${NEW_VERSION}"

# --- Git push ---
info "Pushing to remote..."
git -C "$SCRIPT_DIR" push
success "Pushed to remote"

# --- GitHub release ---
info "Creating GitHub release..."

# Build release notes
RELEASE_BODY="# CCM v${NEW_VERSION}\n\n"
for line in "${CHANGELOG_LINES[@]}"; do
    RELEASE_BODY+="${line}\n"
done
RELEASE_BODY+="\n## Install / Update\n\n"
RELEASE_BODY+="\`\`\`bash\n"
RELEASE_BODY+="curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/install.sh | bash\n"
RELEASE_BODY+="\`\`\`\n"

RELEASE_URL=$(gh release create "v${NEW_VERSION}" \
    --title "v${NEW_VERSION}" \
    --notes "$(echo -e "$RELEASE_BODY")" \
    --repo "$(git -C "$SCRIPT_DIR" remote get-url origin | sed 's/.*github.com[:/]//;s/\.git$//')" \
    2>&1)

success "GitHub release created"

echo ""
echo -e "${BOLD}${GREEN}Release v${NEW_VERSION} complete!${RESET}"
echo ""
step "Version bumped: $CURRENT_VERSION -> $NEW_VERSION"
step "Changelog updated"
step "Committed and pushed"
step "GitHub release: $RELEASE_URL"

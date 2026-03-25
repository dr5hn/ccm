#!/usr/bin/env bash
# CCM — Claude Code Manager installer
# Usage: curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/install.sh | bash

set -euo pipefail

CCM_DIR="$HOME/.ccm"
CCM_BIN="$CCM_DIR/bin"
CCM_URL="https://raw.githubusercontent.com/dr5hn/ccm/main/ccm.sh"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    DIM='\033[0;90m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN='' CYAN='' DIM='' BOLD='' RESET=''
fi

info()    { echo -e "${CYAN}>${RESET} $*"; }
success() { echo -e "${GREEN}✓${RESET} $*"; }
dim()     { echo -e "${DIM}$*${RESET}"; }

echo ""
echo -e "${GREEN}"
echo ' ██████╗ ██████╗███╗   ███╗'
echo '██╔════╝██╔════╝████╗ ████║'
echo '██║     ██║     ██╔████╔██║'
echo '██║     ██║     ██║╚██╔╝██║'
echo '╚██████╗╚██████╗██║ ╚═╝ ██║'
echo -e ' ╚═════╝ ╚═════╝╚═╝     ╚═╝'"${RESET}"
echo ""
echo -e "${BOLD}The power-user toolkit for Claude Code${RESET}"
echo ""

# Check dependencies
for cmd in bash jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required but not found."
        if [[ "$cmd" == "jq" ]]; then
            echo "  Install with: brew install jq (macOS) or sudo apt install jq (Linux)"
        fi
        exit 1
    fi
done

# Check bash version
bash_version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
if ! awk -v ver="$bash_version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
    echo "Error: Bash 4.4+ required (found $bash_version)"
    echo "  macOS: brew install bash"
    exit 1
fi

# Create install directory
info "Installing to ${CCM_BIN}/ccm"
mkdir -p "$CCM_BIN"

# Download
curl -fsSL "$CCM_URL" -o "$CCM_BIN/ccm"
chmod +x "$CCM_BIN/ccm"

success "Downloaded ccm"

# Detect shell and profile
detect_profile() {
    local shell_name
    shell_name=$(basename "$SHELL")

    case "$shell_name" in
        zsh)
            if [[ -f "$HOME/.zshrc" ]]; then
                echo "$HOME/.zshrc"
            else
                echo "$HOME/.zprofile"
            fi
            ;;
        bash)
            if [[ -f "$HOME/.bashrc" ]]; then
                echo "$HOME/.bashrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.profile"
            fi
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

PROFILE=$(detect_profile)
PATH_LINE='export PATH="$HOME/.ccm/bin:$PATH"'

# Add to PATH if not already there
if [[ ":$PATH:" == *":$CCM_BIN:"* ]]; then
    success "Already in PATH"
elif grep -qF '.ccm/bin' "$PROFILE" 2>/dev/null; then
    success "PATH entry already in $PROFILE"
else
    echo "" >> "$PROFILE"
    echo '# CCM — Claude Code Manager' >> "$PROFILE"
    echo "$PATH_LINE" >> "$PROFILE"
    success "Added to PATH in $(basename "$PROFILE")"
fi

# Verify
export PATH="$CCM_BIN:$PATH"
VERSION=$("$CCM_BIN/ccm" version 2>/dev/null || echo "unknown")

echo ""
success "Installed! ${DIM}${VERSION}${RESET}"
echo ""
dim "  Restart your terminal or run:"
dim "    source $PROFILE"
echo ""
dim "  Then try:"
dim "    ccm help"
echo ""

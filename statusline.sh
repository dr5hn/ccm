#!/usr/bin/env bash
# Claude Code Statusline — standalone installer
# Usage: curl -fsSL https://raw.githubusercontent.com/dr5hn/ccm/main/statusline.sh | bash
#
# Shows context, tokens, cost, duration, burn rate, rate limits,
# directory, branch, version, and CCM account (if multi-account).

set -euo pipefail

SCRIPT_PATH="$HOME/.claude/ccm-statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

# Colors
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    DIM='\033[0;90m'
    RESET='\033[0m'
else
    GREEN='' CYAN='' DIM='' RESET=''
fi

echo ""
echo -e "${CYAN}Claude Code Statusline Installer${RESET}"
echo ""

# Create the statusline script
mkdir -p "$HOME/.claude"

cat > "$SCRIPT_PATH" << 'EOF'
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

# ── CCM account data (direct file read) ──
SEQ="$HOME/.claude-switch-backup/sequence.json"
CONF="$HOME/.claude/.claude.json"
[[ -f "$CONF" ]] || CONF="$HOME/.claude.json"

ALIAS="" EMAIL_SHORT="" HEALTH="" TOTAL_ACCTS=0
if [[ -f "$SEQ" ]] && [[ -f "$CONF" ]]; then
    EMAIL=$(jq -r '.oauthAccount.emailAddress // empty' "$CONF" 2>/dev/null)
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

# ── LINE 1: Context + tokens + cost + duration + burn rate + rate limits ──
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
    echo -e "${C}${ACCT_LABEL}${R} ${D}(${EMAIL_SHORT})${R} ${D}·${R} ${TOTAL_ACCTS} accounts ${D}·${R} ${H}"
fi
EOF

chmod +x "$SCRIPT_PATH"
echo -e "${GREEN}✓${RESET} Created $SCRIPT_PATH"

# Update settings.json
if [[ -f "$SETTINGS" ]]; then
    ORIG_PERMS=$(stat -f '%Lp' "$SETTINGS" 2>/dev/null || stat -c '%a' "$SETTINGS" 2>/dev/null || echo "644")
    UPDATED=$(jq --arg cmd "$SCRIPT_PATH" '.statusLine = {type: "command", command: $cmd, padding: 2}' "$SETTINGS")
    echo "$UPDATED" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
    chmod "$ORIG_PERMS" "$SETTINGS"
else
    echo "{}" | jq --arg cmd "$SCRIPT_PATH" '.statusLine = {type: "command", command: $cmd, padding: 2}' > "$SETTINGS"
fi
echo -e "${GREEN}✓${RESET} Updated settings.json"

echo ""
echo -e "${GREEN}Done!${RESET} Restart Claude Code to see the statusline."
echo ""
echo -e "  ${DIM}Uninstall: rm ~/.claude/ccm-statusline.sh${RESET}"
echo -e "  ${DIM}Guide:     https://github.com/dr5hn/ccm#statusline${RESET}"

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
# Claude Code Statusline
# https://github.com/dr5hn/ccm

input=$(cat)

R="\033[0m" C="\033[36m" D="\033[90m" G="\033[32m" Y="\033[33m" RED="\033[31m"

eval "$(echo "$input" | jq -r '
    "PCT=\(.context_window.used_percentage // 0 | floor)",
    "IN_TOK=\(.context_window.current_usage.input_tokens // 0)",
    "CC_TOK=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
    "CR_TOK=\(.context_window.current_usage.cache_read_input_tokens // 0)",
    "COST=\(.cost.total_cost_usd // 0)",
    "DUR_MS=\(.cost.total_duration_ms // 0)",
    "API_MS=\(.cost.total_api_duration_ms // 0)",
    "CWD=\(.cwd // "" | @sh)",
    "RL5_PCT=\(.rate_limits.five_hour.used_percentage // "" | tostring)",
    "RL5_RESET=\(.rate_limits.five_hour.resets_at // "" | tostring)",
    "RL7_PCT=\(.rate_limits.seven_day.used_percentage // "" | tostring)",
    "RL7_RESET=\(.rate_limits.seven_day.resets_at // "" | tostring)",
    "CC_VER=\(.version // "" | @sh)"
' 2>/dev/null)"

TOKENS=$((IN_TOK + CC_TOK + CR_TOK))

PCT_NUM=${PCT:-0}
FILLED=$((PCT_NUM / 10)); EMPTY=$((10 - FILLED))
BAR=""; for ((i=0; i<FILLED; i++)); do BAR+="▓"; done; for ((i=0; i<EMPTY; i++)); do BAR+="░"; done

if [[ "$PCT_NUM" -ge 90 ]]; then BAR_C="$RED"
elif [[ "$PCT_NUM" -ge 70 ]]; then BAR_C="$Y"
else BAR_C="$G"; fi

if [[ "$TOKENS" -ge 1000000 ]]; then TOK_FMT="$(awk "BEGIN{printf \"%.1fM\", $TOKENS/1000000}")"
elif [[ "$TOKENS" -ge 1000 ]]; then TOK_FMT="$(awk "BEGIN{printf \"%.0fK\", $TOKENS/1000}")"
else TOK_FMT="${TOKENS}"; fi

COST_FMT=$(awk "BEGIN{printf \"\$%.2f\", $COST}" 2>/dev/null || echo "\$$COST")

DUR_S=$((DUR_MS / 1000))
if [[ "$DUR_S" -ge 3600 ]]; then DUR_FMT="$((DUR_S / 3600))h$((DUR_S % 3600 / 60))m"
elif [[ "$DUR_S" -ge 60 ]]; then DUR_FMT="$((DUR_S / 60))m"
else DUR_FMT="${DUR_S}s"; fi

BURN_FMT=""
if [[ "$DUR_S" -gt 60 ]] && [[ "$TOKENS" -gt 0 ]]; then
    BURN=$((TOKENS / (DUR_S / 60)))
    if [[ "$BURN" -ge 1000000 ]]; then BURN_FMT="$(awk "BEGIN{printf \"%.1fM\", $BURN/1000000}")/m"
    elif [[ "$BURN" -ge 1000 ]]; then BURN_FMT="$(awk "BEGIN{printf \"%.0fK\", $BURN/1000}")/m"
    else BURN_FMT="${BURN}/m"; fi
fi

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

BRANCH=""
CWD_CLEAN=$(echo "$CWD" | tr -d "'")
if [[ -n "$CWD_CLEAN" ]] && command -v git &>/dev/null; then
    BRANCH=$(git -C "$CWD_CLEAN" branch --show-current 2>/dev/null)
fi

DIR_SHORT=""
if [[ -n "$CWD_CLEAN" ]]; then
    DIR_SHORT="${CWD_CLEAN/#$HOME/~}"
    [[ ${#DIR_SHORT} -gt 30 ]] && DIR_SHORT="…${DIR_SHORT: -29}"
fi

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

COMPACT_WARN=""
[[ "$PCT_NUM" -ge 80 ]] && COMPACT_WARN=" ${D}·${R} ${Y}⚠ /compact${R}"

L1="${BAR_C}${BAR}${R} ${PCT_NUM}% ${D}·${R} ${TOK_FMT} tokens ${D}·${R} ${COST_FMT} ${D}·${R} ${DUR_FMT}"
[[ -n "$BURN_FMT" ]] && L1+=" ${D}·${R} ${BURN_FMT}"
L1+="${RL_FMT}"
echo -e "$L1"

VER_CLEAN=$(echo "$CC_VER" | tr -d "'")
L2="${C}${DIR_SHORT}${R}"
[[ -n "$BRANCH" ]] && L2+=" ${D}·${R} ${G}${BRANCH}${R}"
[[ -n "$VER_CLEAN" ]] && L2+=" ${D}· v${VER_CLEAN}${R}"
L2+="${COMPACT_WARN}"
echo -e "$L2"

if [[ "$TOTAL_ACCTS" -ge 2 ]]; then
    ACCT_LABEL="${ALIAS:-$EMAIL_SHORT}"
    case "$HEALTH" in
        healthy)  H="${G}●${R}" ;; degraded) H="${Y}●${R}" ;; *) H="${RED}●${R}" ;;
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

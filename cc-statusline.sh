#!/bin/bash
# =============================================================================
# Claude Code statusline renderer (jq-based)
# -----------------------------------------------------------------------------
# Field map: JSON input → variable → display block
#   ✅ active   ❌ block currently commented out (paired-disable candidate)
#
#   F[ 0] MODEL              .model.display_name                         → L1 model badge + EFFORT default lookup
#   F[ 1] DIR                .workspace.current_dir                      → REPO_LINK basename (fallback when no git remote)
#   F[ 2] COST               .cost.total_cost_usd                        → L2 cost + today-cost tracker
#   F[ 3] PCT                .context_window.used_percentage             → L2 context bar + % label
#   F[ 4] CTX_SIZE           .context_window.context_window_size         → L1 1M/200K label
#   F[ 5] DURATION_MS        .cost.total_duration_ms                     → L3 api wait %  ❌ DUR (l.252)  ❌ burn rate (l.345)
#   F[ 6] LINES_ADD          .cost.total_lines_added                     → L1 +N lines
#   F[ 7] LINES_DEL          .cost.total_lines_removed                   → L1 -N lines
#   F[ 8] VIM_MODE           .vim.mode                                   → L1 NOR / INS
#   F[ 9] VERSION            .version                                    → L1 vX.Y.Z
#   F[10] RATE_5H            .rate_limits.five_hour.used_percentage      → L2 5h limit %
#   F[11] RATE_7D            .rate_limits.seven_day.used_percentage      → L2 7d limit %
#   F[12] RESET_5H           .rate_limits.five_hour.resets_at            → L2 5h countdown
#   F[13] RESET_7D           .rate_limits.seven_day.resets_at            → L2 7d countdown
#   F[14] TOTAL_IN_TOKENS    .context_window.total_input_tokens          → L3 in:           ❌ burn rate
#   F[15] TOTAL_OUT_TOKENS   .context_window.total_output_tokens         → L3 out:          ❌ burn rate
#   F[16] API_DURATION_MS    .cost.total_api_duration_ms                 → L3 api wait
#   F[17] CACHE_READ         .context_window.current_usage.cache_read_input_tokens      → L3 cache hit + cur read
#   F[18] CACHE_CREATE       .context_window.current_usage.cache_creation_input_tokens  → L3 cache hit + cur write
#   F[19] CUR_INPUT          .context_window.current_usage.input_tokens                 → L3 cache hit + cur in
#   F[20] SESSION_ID         .session_id                                 → today-cost tracker + last-prompt lookup
#   F[21] TRANSCRIPT_PATH    .transcript_path                            → L4 agents / tools / todos
#
# Display layout:
#   L1: model + ctx-size + version + repo + branch + lines + git-stats + vim
#   L2: ctx-bar + cost + today-cost + 5h + 7d
#   L3: cache-hit + tokens + api-wait + cur-token-detail
#   L4: active-agents + running-tools + todos + last-prompt   (only printed if non-empty)
#
# To disable a display block: comment the block, then check this map — if an
# F[N] field is consumed ONLY by disabled blocks, comment its assignment too.
# =============================================================================
input=$(cat)

# ── Parse JSON in a single jq call ────────────────────────────
# Each expression outputs one line; empty strings produce empty lines,
# which readarray preserves — so positional alignment is stable.
readarray -t F < <(jq -r '
  .model.display_name // "Claude",
  .workspace.current_dir // "",
  .cost.total_cost_usd // 0,
  (.context_window.used_percentage // 0 | floor),
  .context_window.context_window_size // "",
  .cost.total_duration_ms // 0,
  .cost.total_lines_added // "",
  .cost.total_lines_removed // "",
  .vim.mode // "",
  .version // "",
  .rate_limits.five_hour.used_percentage // "",
  .rate_limits.seven_day.used_percentage // "",
  .rate_limits.five_hour.resets_at // "",
  .rate_limits.seven_day.resets_at // "",
  .context_window.total_input_tokens // "",
  .context_window.total_output_tokens // "",
  .cost.total_api_duration_ms // 0,
  .context_window.current_usage.cache_read_input_tokens // "",
  .context_window.current_usage.cache_creation_input_tokens // "",
  .context_window.current_usage.input_tokens // "",
  .session_id // "",
  .transcript_path // ""
' <<< "$input")

MODEL=${F[0]}              # → L1 model + EFFORT default
DIR=${F[1]}                # → REPO_LINK basename fallback
COST=${F[2]}               # → L2 cost + today tracker
PCT=${F[3]}                # → L2 context bar + %
CTX_SIZE=${F[4]}           # → L1 1M/200K label
DURATION_MS=${F[5]}        # → L3 api wait %  + ❌DUR + ❌burn (shared, do NOT disable extraction)
LINES_ADD=${F[6]}          # → L1 +lines
LINES_DEL=${F[7]}          # → L1 -lines
VIM_MODE=${F[8]}           # → L1 NOR/INS
VERSION=${F[9]}            # → L1 vX.Y.Z
RATE_5H=${F[10]}           # → L2 5h
RATE_7D=${F[11]}           # → L2 7d
RESET_5H=${F[12]}          # → L2 5h countdown
RESET_7D=${F[13]}          # → L2 7d countdown
TOTAL_IN_TOKENS=${F[14]}   # → L3 in:   + ❌burn (shared)
TOTAL_OUT_TOKENS=${F[15]}  # → L3 out:  + ❌burn (shared)
API_DURATION_MS=${F[16]}   # → L3 api wait
CACHE_READ=${F[17]}        # → L3 cache hit + cur read
CACHE_CREATE=${F[18]}      # → L3 cache hit + cur write
CUR_INPUT=${F[19]}         # → L3 cache hit + cur in
SESSION_ID=${F[20]}        # → today tracker + last-prompt lookup
TRANSCRIPT_PATH=${F[21]}   # → L4 agents/tools/todos

# ── Effort / thinking level (from settings.json) ──────────────
EFFORT=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null)
if [ -z "$EFFORT" ]; then
  # Default per model (mirrors claude-dashboard's getDefaultEffort)
  case "$MODEL" in
    *Opus*)   EFFORT=xhigh ;;
    *Sonnet*) EFFORT=medium ;;
    *)        EFFORT=high ;;
  esac
fi
case "$EFFORT" in
  low)    EFFORT_LABEL=L ;;
  medium) EFFORT_LABEL=M ;;
  high)   EFFORT_LABEL=H ;;
  xhigh)  EFFORT_LABEL=xH ;;
  *)      EFFORT_LABEL="" ;;
esac
# Only Opus/Sonnet support effort levels
case "$MODEL" in
  *Opus*|*Sonnet*) MODEL_DISP="${MODEL} (${EFFORT_LABEL})" ;;
  *)               MODEL_DISP="$MODEL" ;;
esac

# ── Today cost tracker ────────────────────────────────────────
# Mirror of claude-dashboard's per-session aggregation: track each session's
# running cost.total_cost_usd in a JSON file and sum across today's sessions.
TRACKER=$HOME/.claude/cc-statusline-cost.json
TODAY=$(date +%Y-%m-%d)
TODAY_COST=0
if [ -n "$SESSION_ID" ]; then
  TODAY_COST=$(jq -r --arg today "$TODAY" --arg sid "$SESSION_ID" --argjson cost "$COST" '
    (if (.date // "") != $today then {date: $today, sessions: {}} else . end)
    | .sessions[$sid] = $cost
    | (. as $s | (.sessions | to_entries | map(.value) | add) | tostring + "\t" + ($s | tojson))
  ' "$TRACKER" 2>/dev/null || echo -e "0\t{\"date\":\"$TODAY\",\"sessions\":{\"$SESSION_ID\":$COST}}")
  # Persist new state, keep total
  TODAY_TOTAL=${TODAY_COST%%$'\t'*}
  TODAY_STATE=${TODAY_COST#*$'\t'}
  printf '%s' "$TODAY_STATE" > "$TRACKER"
  TODAY_COST=$TODAY_TOTAL
fi

# ── Transcript-derived widgets (agents / tools / todos) ───────
# Single parse pass to extract all needed signals from the transcript.
ACTIVE_AGENTS=""
ACTIVE_AGENT_COUNT=0
RUNNING_TOOLS=""
RUNNING_TOOL_COUNT=0
TODO_DONE=0
TODO_TOTAL=0
TODO_CURRENT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Pass 1: every tool_use (id, name, subagent_type) — pre-filtered with grep
  TOOL_USES=$(grep -F '"type":"tool_use"' "$TRANSCRIPT_PATH" 2>/dev/null \
    | jq -r 'select(.type=="assistant") | .message.content[]?
             | select(.type=="tool_use")
             | "\(.id)\t\(.name)\t\(.input.subagent_type // "")"' 2>/dev/null)
  # Pass 2: completed tool_use_ids
  COMPLETED=$(grep -F '"tool_use_id":"toolu_' "$TRANSCRIPT_PATH" 2>/dev/null \
    | jq -r '.message.content[]? | select(.type=="tool_result") | .tool_use_id' 2>/dev/null \
    | sort -u)
  if [ -n "$TOOL_USES" ]; then
    # Filter to active (tool_use_id NOT in completed); split Agent vs other tools
    ACTIVE=$(awk -F'\t' -v completed="$COMPLETED" '
      BEGIN { n=split(completed, arr, "\n"); for (i=1;i<=n;i++) done[arr[i]]=1 }
      !($1 in done) { print $2 "\t" $3 }
    ' <<< "$TOOL_USES")
    AGENTS_RAW=$(awk -F'\t' '$1=="Agent" && $2!="" { print $2 }' <<< "$ACTIVE")
    TOOLS_RAW=$(awk -F'\t' '$1!="Agent" { print $1 }' <<< "$ACTIVE")
    if [ -n "$AGENTS_RAW" ]; then
      ACTIVE_AGENT_COUNT=$(wc -l <<< "$AGENTS_RAW" | tr -d ' ')
      ACTIVE_AGENTS=$(paste -sd, <<< "$AGENTS_RAW")
    fi
    if [ -n "$TOOLS_RAW" ]; then
      RUNNING_TOOL_COUNT=$(wc -l <<< "$TOOLS_RAW" | tr -d ' ')
      RUNNING_TOOLS=$(paste -sd, <<< "$TOOLS_RAW")
    fi
  fi
  # Last TodoWrite invocation → todo progress
  TODO_RAW=$(grep -F '"name":"TodoWrite"' "$TRANSCRIPT_PATH" 2>/dev/null \
    | tail -1 \
    | jq -c '.message.content[]? | select(.type=="tool_use" and .name=="TodoWrite") | .input.todos // []' 2>/dev/null)
  if [ -n "$TODO_RAW" ] && [ "$TODO_RAW" != "null" ] && [ "$TODO_RAW" != "[]" ]; then
    TODO_TOTAL=$(jq 'length' <<< "$TODO_RAW")
    TODO_DONE=$(jq '[.[] | select(.status=="completed" or .status=="complete" or .status=="done")] | length' <<< "$TODO_RAW")
    TODO_CURRENT=$(jq -r '[.[] | select(.status=="in_progress" or .status=="running")][0].content // ""' <<< "$TODO_RAW")
  fi
fi

# ── Last user prompt (from ~/.claude/history.jsonl) ───────────
LAST_PROMPT=""
LAST_PROMPT_TIME=""
HISTORY_FILE="$HOME/.claude/history.jsonl"
if [ -f "$HISTORY_FILE" ] && [ -n "$SESSION_ID" ]; then
  # tail keeps cost bounded on a long history; 200 lines is plenty for the most-recent prompt
  LAST_ENTRY=$(tail -n 200 "$HISTORY_FILE" 2>/dev/null \
    | grep -F "\"sessionId\":\"$SESSION_ID\"" \
    | tail -1)
  if [ -n "$LAST_ENTRY" ]; then
    LAST_PROMPT=$(jq -r '.display // "" | gsub("\\s+"; " ")' <<< "$LAST_ENTRY")
    LAST_PROMPT_TIME_MS=$(jq -r '.timestamp // 0' <<< "$LAST_ENTRY")
    if [ "$LAST_PROMPT_TIME_MS" -gt 0 ]; then
      LAST_PROMPT_TIME=$(date -d "@$((LAST_PROMPT_TIME_MS / 1000))" +"%H:%M" 2>/dev/null)
    fi
    if [ ${#LAST_PROMPT} -gt 60 ]; then
      LAST_PROMPT="${LAST_PROMPT:0:57}..."
    fi
  fi
fi

# ── Colors ────────────────────────────────────────────────────
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'
RED='\033[31m'; MAGENTA='\033[35m'; BLUE='\033[34m'
WHITE='\033[37m'

SEP="${DIM} | ${RESET}"

# ── Helper: color by percentage ───────────────────────────────
color_pct() {
  local val=$1
  if [ "$val" -ge 80 ]; then echo "$RED"
  elif [ "$val" -ge 50 ]; then echo "$YELLOW"
  else echo "$GREEN"; fi
}

# ── Helper: format duration from ms ───────────────────────────
fmt_dur() {
  local ms=$1
  local total_sec=$(( ms / 1000 ))
  local h=$(( total_sec / 3600 ))
  local m=$(( (total_sec % 3600) / 60 ))
  local s=$(( total_sec % 60 ))
  if [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf "%dm %02ds" "$m" "$s"
  else printf "%ds" "$s"; fi
}

# ── Helper: format countdown from epoch ───────────────────────
fmt_countdown() {
  local reset_at=$1
  local now=$(date +%s)
  local diff=$(( reset_at - now ))
  if [ "$diff" -le 0 ]; then echo "now"; return; fi
  local h=$(( diff / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  printf "%dh %dm" "$h" "$m"
}

# ── Helper: format token count (K/M) ──────────────────────────
fmt_tokens() {
  local t=$1
  if [ -z "$t" ] || [ "$t" = "null" ]; then echo "0"; return; fi
  if [ "$t" -ge 1000000 ]; then
    printf "%.1fM" "$(echo "scale=1; $t / 1000000" | bc)"
  elif [ "$t" -ge 1000 ]; then
    printf "%.1fK" "$(echo "scale=1; $t / 1000" | bc)"
  else
    echo "$t"
  fi
}

# ── Context window size label ─────────────────────────────────
CTX_LABEL=""
if [ -n "$CTX_SIZE" ]; then
  if [ "$CTX_SIZE" -ge 1000000 ]; then
    CTX_LABEL="${DIM}1M${RESET}"
  else
    CTX_LABEL="${DIM}200K${RESET}"
  fi
fi

# ── Git info ──────────────────────────────────────────────────
BRANCH=""
git rev-parse --git-dir > /dev/null 2>&1 && BRANCH="$(git branch --show-current 2>/dev/null)"

REPO_LINK="${DIR##*/}"
REMOTE=$(git remote get-url origin 2>/dev/null | sed 's/git@github.com:/https:\/\/github.com\//' | sed 's/\.git$//')
if [ -n "$REMOTE" ]; then
  REPO_NAME=$(basename "$REMOTE")
  REPO_LINK=$(printf '%b' "\e]8;;${REMOTE}\a${REPO_NAME}\e]8;;\a")
fi

# ── Context bar ───────────────────────────────────────────────
BAR_COLOR=$(color_pct "$PCT")
BAR_W=10
HALF_STEPS=$((PCT * BAR_W * 2 / 100))
[ "$PCT" -gt 0 ] && [ "$HALF_STEPS" -eq 0 ] && HALF_STEPS=1
FULL=$((HALF_STEPS / 2)); HAS_HALF=$((HALF_STEPS % 2))
EMPTY=$((BAR_W - FULL - HAS_HALF))
BAR=""
for i in $(seq 1 $FULL); do BAR="${BAR}${BAR_COLOR}●${RESET}"; done
[ "$HAS_HALF" -eq 1 ] && BAR="${BAR}${BAR_COLOR}◐${RESET}"
for i in $(seq 1 $EMPTY); do BAR="${BAR}${DIM}●${RESET}"; done

# ── Duration ──────────────────────────────────────────────────
# Status: DISABLED — display not currently rendered on any L1–L4 line.
# Consumes: DURATION_MS (F[5])
# Paired-disable note: DURATION_MS is ALSO consumed by L3 api wait % (l. ~358)
#   → do NOT comment out the F[5] extraction even if you keep DUR disabled.
# To re-enable: uncomment below AND inject ${DUR} into the desired L1–L4 line.
# DUR=$(fmt_dur "$DURATION_MS")

# ── Git file stats ────────────────────────────────────────────
GIT_STATS=""
if git rev-parse --git-dir > /dev/null 2>&1; then
  GIT_M=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  GIT_A=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  GIT_D=$(git diff --diff-filter=D --name-only 2>/dev/null | wc -l | tr -d ' ')
  PARTS=""
  [ "$GIT_M" -gt 0 ] 2>/dev/null && PARTS="${YELLOW}${GIT_M}M${RESET}"
  [ "$GIT_A" -gt 0 ] 2>/dev/null && { [ -n "$PARTS" ] && PARTS="${PARTS} "; PARTS="${PARTS}${GREEN}${GIT_A}A${RESET}"; }
  [ "$GIT_D" -gt 0 ] 2>/dev/null && { [ -n "$PARTS" ] && PARTS="${PARTS} "; PARTS="${PARTS}${RED}${GIT_D}D${RESET}"; }
  [ -n "$PARTS" ] && GIT_STATS="${PARTS}"
fi

# ── Cache hit rate ────────────────────────────────────────────
CACHE_HIT=""
if [ -n "$CACHE_READ" ] && [ -n "$CUR_INPUT" ] && [ "$CUR_INPUT" != "0" ]; then
  CACHE_TOTAL=$((CACHE_READ + CUR_INPUT + ${CACHE_CREATE:-0}))
  if [ "$CACHE_TOTAL" -gt 0 ]; then
    CACHE_PCT=$((CACHE_READ * 100 / CACHE_TOTAL))
    CACHE_C=$(color_pct "$((100 - CACHE_PCT))")
    CACHE_HIT="${DIM}cache${RESET} ${CACHE_C}${CACHE_PCT}%${RESET}"
  fi
fi

# ══════════════════════════════════════════════════════════════
# LINE 1: Model + Context size + Version + Repo + Branch + Lines + Files + Agent
# INPUTS: MODEL_DISP CTX_LABEL VERSION REPO_LINK BRANCH LINES_ADD LINES_DEL GIT_STATS VIM_MODE
# ══════════════════════════════════════════════════════════════
L1="${CYAN}${BOLD}${MODEL_DISP}${RESET}"
[ -n "$CTX_LABEL" ] && L1="${L1} ${CTX_LABEL}"
[ -n "$VERSION" ] && L1="${L1} ${DIM}v${VERSION}${RESET}"
L1="${L1}${SEP}${WHITE}${REPO_LINK}${RESET}"
[ -n "$BRANCH" ] && L1="${L1} ${DIM}(${BRANCH})${RESET}"

LINES_PART=""
if [ -n "$LINES_ADD" ] && [ "$LINES_ADD" != "0" ]; then
  LINES_PART="${GREEN}+${LINES_ADD}${RESET}"
fi
if [ -n "$LINES_DEL" ] && [ "$LINES_DEL" != "0" ]; then
  [ -n "$LINES_PART" ] && LINES_PART="${LINES_PART} ${RED}-${LINES_DEL}${RESET}" || LINES_PART="${RED}-${LINES_DEL}${RESET}"
fi
[ -n "$LINES_PART" ] && L1="${L1}${SEP}${LINES_PART} ${DIM}lines${RESET}"

[ -n "$GIT_STATS" ] && L1="${L1}${SEP}${GIT_STATS}"

[ -n "$VIM_MODE" ] && {
  if [ "$VIM_MODE" = "NORMAL" ]; then
    L1="${L1}${SEP}${BLUE}${BOLD}NOR${RESET}"
  else
    L1="${L1}${SEP}${GREEN}${BOLD}INS${RESET}"
  fi
}

# ══════════════════════════════════════════════════════════════
# LINE 2: Context bar + Cost + Duration + Rate limits (5h & 7d with countdown)
# INPUTS: BAR PCT COST TODAY_COST RATE_5H RESET_5H RATE_7D RESET_7D
# ══════════════════════════════════════════════════════════════
COST_FMT=$(printf '$%.2f' "$COST")
TODAY_FMT=$(printf '$%.2f' "$TODAY_COST")
L2="${BAR} ${DIM}${PCT}%${RESET}${SEP}${YELLOW}${COST_FMT}${RESET} ${DIM}(today ${TODAY_FMT})${RESET}"

if [ -n "$RATE_5H" ]; then
  R5_INT=$(printf "%.0f" "$RATE_5H")
  R5_C=$(color_pct "$R5_INT")
  L2="${L2}${SEP}${DIM}5h${RESET} ${R5_C}${R5_INT}%${RESET}"
  if [ -n "$RESET_5H" ]; then
    R5_CD=$(fmt_countdown "$RESET_5H")
    L2="${L2} ${DIM}(${R5_CD})${RESET}"
  fi
fi

if [ -n "$RATE_7D" ]; then
  R7_INT=$(printf "%.0f" "$RATE_7D")
  R7_C=$(color_pct "$R7_INT")
  L2="${L2}${SEP}${DIM}7d${RESET} ${R7_C}${R7_INT}%${RESET}"
  if [ -n "$RESET_7D" ]; then
    R7_CD=$(fmt_countdown "$RESET_7D")
    L2="${L2} ${DIM}(${R7_CD})${RESET}"
  fi
fi

# ══════════════════════════════════════════════════════════════
# LINE 3: Cache hit rate + Tokens + API wait + Current token detail
# INPUTS: CACHE_HIT (←CACHE_READ+CACHE_CREATE+CUR_INPUT)  TOTAL_IN_TOKENS TOTAL_OUT_TOKENS
#         API_DURATION_MS DURATION_MS  CUR_INPUT CACHE_READ CACHE_CREATE
# ══════════════════════════════════════════════════════════════
L3=""
[ -n "$CACHE_HIT" ] && L3="${CACHE_HIT}"

IN_FMT=$(fmt_tokens "$TOTAL_IN_TOKENS")
OUT_FMT=$(fmt_tokens "$TOTAL_OUT_TOKENS")
TOKENS_PART="${DIM}in:${RESET} ${CYAN}${IN_FMT}${RESET} ${DIM}out:${RESET} ${MAGENTA}${OUT_FMT}${RESET}"
[ -n "$L3" ] && L3="${L3}${SEP}${TOKENS_PART}" || L3="${TOKENS_PART}"

# Burn rate: (in + out) tokens per minute of session wall time
# Status: DISABLED — appended-to-L3 if re-enabled.
# Consumes: DURATION_MS (F[5]), TOTAL_IN_TOKENS (F[14]), TOTAL_OUT_TOKENS (F[15])
# Paired-disable note: all three are ALSO consumed by active L3 / L2 outputs
#   (api wait %, in:, out:) → do NOT comment out their F[N] extractions.
# To re-enable: uncomment the block AND the trailing L3 concat line.
# BURN_PART=""
# if [ "$DURATION_MS" -gt 0 ] && [ -n "$TOTAL_IN_TOKENS" ] && [ -n "$TOTAL_OUT_TOKENS" ]; then
#   TOTAL_TOK=$((TOTAL_IN_TOKENS + TOTAL_OUT_TOKENS))
#   BURN_RATE=$((TOTAL_TOK * 60000 / DURATION_MS))
#   BURN_FMT=$(fmt_tokens "$BURN_RATE")
#   BURN_PART="${SEP}${DIM}burn${RESET} ${YELLOW}${BURN_FMT}/min${RESET}"
# fi
# L3="${L3}${BURN_PART}"

API_DUR=$(fmt_dur "$API_DURATION_MS")
if [ "$DURATION_MS" -gt 0 ] && [ "$API_DURATION_MS" -gt 0 ]; then
  API_PCT=$((API_DURATION_MS * 100 / DURATION_MS))
  L3="${L3}${SEP}${DIM}api wait${RESET} ${CYAN}${API_DUR}${RESET} ${DIM}(${API_PCT}%)${RESET}"
else
  L3="${L3}${SEP}${DIM}api wait${RESET} ${CYAN}${API_DUR}${RESET}"
fi

CUR_IN_FMT=$(fmt_tokens "$CUR_INPUT")
CACHE_R_FMT=$(fmt_tokens "$CACHE_READ")
CACHE_C_FMT=$(fmt_tokens "$CACHE_CREATE")
L3="${L3}${SEP}${DIM}cur${RESET} ${CUR_IN_FMT} ${DIM}in${RESET} ${CACHE_R_FMT} ${DIM}read${RESET} ${CACHE_C_FMT} ${DIM}write${RESET}"

# ══════════════════════════════════════════════════════════════
# LINE 4: Live activity — agents + tools + todos + last prompt
# INPUTS: ACTIVE_AGENTS RUNNING_TOOLS TODO_DONE/TODO_TOTAL TODO_CURRENT LAST_PROMPT LAST_PROMPT_TIME
#         (all derived from TRANSCRIPT_PATH + SESSION_ID + history.jsonl)
# Note: this line is conditionally printed — only if at least one field is non-empty.
# ══════════════════════════════════════════════════════════════
L4=""
add4() { [ -n "$L4" ] && L4="${L4}${SEP}$1" || L4="$1"; }

[ "$ACTIVE_AGENT_COUNT" -gt 0 ] && add4 "${MAGENTA}agents ${ACTIVE_AGENT_COUNT} ${ACTIVE_AGENTS}${RESET}"
[ "$RUNNING_TOOL_COUNT" -gt 0 ] && add4 "${YELLOW}tools ${RUNNING_TOOLS}${RESET}"
if [ "$TODO_TOTAL" -gt 0 ]; then
  TODO_PART="${CYAN}todos ${TODO_DONE}/${TODO_TOTAL}${RESET}"
  [ -n "$TODO_CURRENT" ] && TODO_PART="${TODO_PART} ${DIM}${TODO_CURRENT:0:40}${RESET}"
  add4 "$TODO_PART"
fi
if [ -n "$LAST_PROMPT" ]; then
  PROMPT_PART=""
  [ -n "$LAST_PROMPT_TIME" ] && PROMPT_PART="${DIM}${LAST_PROMPT_TIME}${RESET} "
  PROMPT_PART="${PROMPT_PART}${LAST_PROMPT}"
  add4 "$PROMPT_PART"
fi

# ── Output ────────────────────────────────────────────────────
echo -e "$L1"
echo -e "$L2"
echo -e "$L3"
[ -n "$L4" ] && echo -e "$L4"


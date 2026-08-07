#!/bin/bash
# =============================================================================
# Claude Code statusline renderer (jq-based)
# -----------------------------------------------------------------------------
# Field map: JSON input → variable → display block
#   ✅ active   ❌ block currently commented out (paired-disable candidate)
#
#   F[ 0] MODEL              .model.display_name                         → L1 model badge + EFFORT default lookup
#   F[ 1] DIR                .workspace.current_dir                      → REPO_LINK basename (fallback when no git remote) + PWD subpath
#   F[22] PROJECT_DIR        .workspace.project_dir                      → L1 PWD subpath (cwd relative to project root)
#   F[ 2] COST               .cost.total_cost_usd                        → L2 cost + today-cost tracker
#   F[ 3] PCT                .context_window.used_percentage             → L2 context bar + % label (fallback only; recomputed vs CTX_EFF, l. ~284)
#   F[ 4] CTX_SIZE           .context_window.context_window_size         → CTX_EFF → L1 window label + L2 % denominator
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
#   F[17] CACHE_READ         .context_window.current_usage.cache_read_input_tokens      → L3 cache hit + cur read  + L2 % numerator
#   F[18] CACHE_CREATE       .context_window.current_usage.cache_creation_input_tokens  → L3 cache hit + cur write + L2 % numerator
#   F[19] CUR_INPUT          .context_window.current_usage.input_tokens                 → L3 cache hit + cur in    + L2 % numerator
#   F[20] SESSION_ID         .session_id                                 → today-cost tracker + last-prompt lookup
#   F[21] TRANSCRIPT_PATH    .transcript_path                            → L4 agents / tools / todos
#
# Display layout:
#   L1: model + ctx-size + version + repo + branch + lines + git-stats + vim
#   L2: ctx-bar + cost + today-cost + 5h + 7d
#   L3: cache-hit + tokens + api-wait + agents-or-last-agent   (❌ cur-token-detail disabled — see l. ~413)
#   L4: running-tools + todos + last-prompt   (only printed if non-empty)
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
  .transcript_path // "",
  .workspace.project_dir // ""
' <<< "$input")

MODEL=${F[0]}              # → L1 model + EFFORT default
DIR=${F[1]}                # → REPO_LINK basename fallback
COST=${F[2]}               # → L2 cost + today tracker
PCT=${F[3]}                # → L2 context bar + %  (fallback; recomputed vs CTX_EFF)
CTX_SIZE=${F[4]}           # → CTX_EFF → L1 window label + L2 % denominator
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
CACHE_READ=${F[17]}        # → L3 cache hit + cur read  + L2 % numerator (shared)
CACHE_CREATE=${F[18]}      # → L3 cache hit + cur write + L2 % numerator (shared)
CUR_INPUT=${F[19]}         # → L3 cache hit + cur in    + L2 % numerator (shared)
SESSION_ID=${F[20]}        # → today tracker + last-prompt lookup
TRANSCRIPT_PATH=${F[21]}   # → L4 agents/tools/todos
PROJECT_DIR=${F[22]}       # → L1 PWD subpath

# ── Effort / thinking level (from settings.json) ──────────────
EFFORT=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null)
if [ -z "$EFFORT" ]; then
  # Default per model
  case "$MODEL" in
    *Opus*) EFFORT=medium ;;
    *)      EFFORT=high ;;
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
printf -v TODAY '%(%Y-%m-%d)T' -1
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
# Perf: only the last TRANSCRIPT_TAIL_LINES lines are scanned (via `tail -n | grep`,
# NOT a shared bash variable — a multi-MB var re-fed through `<<<` here-strings
# gets rematerialized to a temp file on every use and was measured 10x slower
# than three independent `tail | grep` pipes). Cost of the old full-file grep+jq
# pass grew with total tool-calls in the session (measured: 1.8s on an
# 89K-line/251MB synthetic transcript); the display only ever needs the 3 most
# recent agents/tools/todo anyway, so bounding the window keeps cost flat
# (~20ms added) regardless of how long the session gets.
TRANSCRIPT_TAIL_LINES=2000
ACTIVE_AGENTS=""
ACTIVE_AGENT_COUNT=0
LAST_AGENT=""
RUNNING_TOOLS=""
RUNNING_TOOL_COUNT=0
TODO_DONE=0
TODO_TOTAL=0
TODO_CURRENT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Pass 1: every tool_use (id, name, subagent_type) — pre-filtered with grep
  # `description` is free text and can carry any whitespace. Left raw, a newline
  # splits one record across several lines, and every continuation line then parses
  # as a never-completed tool_use with an empty name — the `tools` widget renders it
  # as a run of bare commas; a CR survives to stdout and rewinds the drawn line.
  # Collapse whitespace so one record stays one line (same idiom as LAST_PROMPT).
  TOOL_USES=$(tail -n "$TRANSCRIPT_TAIL_LINES" "$TRANSCRIPT_PATH" 2>/dev/null \
    | grep -F '"type":"tool_use"' \
    | jq -r 'select(.type=="assistant") | .message.content[]?
             | select(.type=="tool_use")
             | "\(.id)\t\(.name)\t\(.input.subagent_type // "")\t\((.input.description // "") | gsub("\\s+"; " "))"' 2>/dev/null)
  # Pass 2: completed tool_use_ids
  COMPLETED=$(tail -n "$TRANSCRIPT_TAIL_LINES" "$TRANSCRIPT_PATH" 2>/dev/null \
    | grep -F '"tool_use_id":"toolu_' \
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
      readarray -t _agents <<< "$AGENTS_RAW"; ACTIVE_AGENT_COUNT=${#_agents[@]}
      ACTIVE_AGENTS=$(paste -sd, <<< "$AGENTS_RAW")
    fi
    if [ -n "$TOOLS_RAW" ]; then
      readarray -t _tools <<< "$TOOLS_RAW"; RUNNING_TOOL_COUNT=${#_tools[@]}
      RUNNING_TOOLS=$(paste -sd, <<< "$TOOLS_RAW")
    fi
    # Last Agent invocation, regardless of completion — fallback for the L3
    # `agents` display when nothing is currently active.
    LAST_AGENT=$(awk -F'\t' '$2=="Agent" && $3!="" { last=$3 } END { print last }' <<< "$TOOL_USES")
    # AJ-25: Agents-with-status (claude-hud parity) — both running + completed, up
    # to 3 most recent. 4-field input: id name subagent_type description.
    # Emits tab-sep: status<TAB>type<TAB>description.
    AGENTS_WITH_STATUS=$(awk -F'\t' -v completed="$COMPLETED" '
      BEGIN { n=split(completed, arr, "\n"); for (i=1;i<=n;i++) done[arr[i]]=1 }
      $2=="Agent" && $3!="" {
        status = ($1 in done) ? "done" : "running"
        print status "\t" $3 "\t" $4
      }
    ' <<< "$TOOL_USES" | tail -3)
  fi
  # Last TodoWrite invocation → todo progress
  TODO_RAW=$(tail -n "$TRANSCRIPT_TAIL_LINES" "$TRANSCRIPT_PATH" 2>/dev/null \
    | grep -F '"name":"TodoWrite"' \
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
      printf -v LAST_PROMPT_TIME '%(%H:%M)T' $((LAST_PROMPT_TIME_MS / 1000))
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
  local diff=$(( reset_at - EPOCHSECONDS ))
  if [ "$diff" -le 0 ]; then echo "now"; return; fi
  local h=$(( diff / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  printf "%dh %dm" "$h" "$m"
}

# ── Helper: format token count (K/M) ──────────────────────────
fmt_tokens() {
  local t=$1
  if [ -z "$t" ] || [ "$t" = "null" ]; then echo "0"; return; fi
  # Integer division truncates, and so did `bc` with scale=1 — exact substitution.
  if [ "$t" -ge 1000000 ]; then
    printf "%d.%dM" $((t / 1000000)) $((t % 1000000 * 10 / 1000000))
  elif [ "$t" -ge 1000 ]; then
    printf "%d.%dK" $((t / 1000)) $((t % 1000 * 10 / 1000))
  else
    echo "$t"
  fi
}

# ── Helper: format a context-window size (round numbers only) ─
fmt_window() {
  local t=$1
  if [ $((t % 1000000)) -eq 0 ]; then echo "$((t / 1000000))M"; else echo "$((t / 1000))K"; fi
}

# ── Effective context window + usage % ────────────────────────
# stdin's context_window.used_percentage divides by the RAW model window
# (CLI Xv(): 1e6 for [1m] models) and ignores CLAUDE_CODE_AUTO_COMPACT_WINDOW,
# while auto-compact measures against that env value — up to 5x under-report.
# Recompute against the window the compactor actually sees.
CTX_EFF=$CTX_SIZE
ACW=${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}
if [ -n "$ACW" ] && [ "$ACW" -gt 0 ] 2>/dev/null; then
  { [ -z "$CTX_EFF" ] || [ "$ACW" -lt "$CTX_EFF" ]; } && CTX_EFF=$ACW
fi

# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE moves the compaction trigger down to that share
# of the window, so the budget the bar measures against shrinks with it:
#
#   CLI Rko():  threshold = min(floor(window * pct/100), window - 13000)
#
# The second arm is deliberately not reproduced — with no override this script
# already treats the whole window as 100%, so applying it only here would make
# the two paths disagree about the same session. Caveat: on a small window that
# arm is the binding one (200K window, pct=95 → CLI compacts at 187000 while the
# bar divides by 190000).
#
# The CLI parses with parseFloat, so the accepted form is a numeric prefix —
# leading blanks, an optional '+', a leading '.', and a trailing non-numeric tail
# are all tolerated. Exponent notation is the one parseFloat form rejected:
# honouring only its mantissa would silently pick a wrong budget.
# Six fractional digits are kept and the rest truncated; scaling by 1e6 keeps the
# arithmetic integer, and the range check runs on the scaled value so this script
# and the ps1 accept exactly the same inputs.
CTX_FULL=$CTX_EFF
ACP=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}
ACP_ON=0
ACP_LABEL=""
if [ -n "$CTX_EFF" ] && [[ $ACP =~ ^[[:blank:]]*[+]?([0-9]*)(\.([0-9]*))? ]]; then
  _acp_i=${BASH_REMATCH[1]}
  _acp_f=${BASH_REMATCH[3]}
  _acp_rest=${ACP:${#BASH_REMATCH[0]}}
  if [ -n "$_acp_i$_acp_f" ] && [ ${#_acp_i} -le 3 ] && [[ $_acp_rest != [eE]* ]]; then
    _acp_f="${_acp_f}000000"
    _acp_f=${_acp_f:0:6}
    _acp_x=$(( 10#0$_acp_i * 1000000 + 10#$_acp_f ))
    if [ "$_acp_x" -gt 0 ] && [ "$_acp_x" -le 100000000 ]; then
      _acp_eff=$(( CTX_FULL * _acp_x / 100000000 ))
      if [ "$_acp_eff" -gt 0 ]; then
        CTX_EFF=$_acp_eff
        ACP_ON=1
        while [[ $_acp_f == *0 ]]; do _acp_f=${_acp_f%0}; done
        ACP_LABEL=$(( 10#0$_acp_i ))
        [ -n "$_acp_f" ] && ACP_LABEL="${ACP_LABEL}.${_acp_f}"
      fi
    fi
  fi
fi

CUR_TOKENS=$(( ${CUR_INPUT:-0} + ${CACHE_READ:-0} + ${CACHE_CREATE:-0} ))
if [ -n "$CTX_EFF" ] && [ "$CTX_EFF" -gt 0 ] && [ "$CUR_TOKENS" -gt 0 ]; then
  PCT=$(( CUR_TOKENS * 100 / CTX_EFF ))
  [ "$PCT" -gt 100 ] && PCT=100
fi

# ── Context window size label ─────────────────────────────────
# Budget first, since that is what the bar's % divides by; the full window
# stays visible behind it — "500K (1M·50%)".
CTX_LABEL=""
if [ -n "$CTX_EFF" ] && [ "$CTX_EFF" -gt 0 ]; then
  if [ "$ACP_ON" -eq 1 ]; then
    CTX_LABEL="${DIM}$(fmt_window "$CTX_EFF") ($(fmt_window "$CTX_FULL")·${ACP_LABEL}%)${RESET}"
  else
    CTX_LABEL="${DIM}$(fmt_window "$CTX_EFF")${RESET}"
  fi
fi

# ── Git info ──────────────────────────────────────────────────
BRANCH=""
IS_GIT=0
GIT_COMMIT=""
# One rev-parse answers both questions. It resolves arguments in order and
# prints each as it goes, so a repo with no commit yet still emits the git-dir
# line before HEAD fails — the exit status reflects only the last argument, so
# key on the lines, never on $?.
{ read -r _gitdir; read -r GIT_COMMIT; } < <(
  git rev-parse --git-dir --short HEAD 2>/dev/null
)
[ -n "$_gitdir" ] && IS_GIT=1
[ "$IS_GIT" -eq 1 ] && BRANCH="$(git branch --show-current 2>/dev/null)"
# Detached HEAD (checkout of a sha, rebase, bisect) prints nothing. Without a
# placeholder the whole (branch* M A D +N -N) block on L1 is suppressed, taking
# the working-tree stats with it. The @<hash> rendered right after names the commit.
#
#   git checkout origin/main  → origin/main   (a ref actually asked for)
#   git checkout <sha>        → detached      (nothing to name it)
#
# Scoped to refs/remotes/origin on purpose: `git name-rev` resolves to ANY ref at
# the commit, including an unrelated worktree branch, and would show a name the
# user is not on. The extra spawn only runs on this rare path.
#
# origin/HEAD is excluded: it shortens to the bare remote name `origin`, and it
# sorts first, so --count=1 would return that instead of the branch it aliases.
if [ "$IS_GIT" -eq 1 ] && [ -z "$BRANCH" ]; then
  BRANCH=$(git for-each-ref --count=1 --points-at HEAD \
             --exclude=refs/remotes/origin/HEAD \
             --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
  [ -z "$BRANCH" ] && BRANCH="detached"
fi

REPO_LINK="${DIR##*/}"
REMOTE=$(git remote get-url origin 2>/dev/null)
REMOTE=${REMOTE/git@github.com:/https:\/\/github.com\/}
REMOTE=${REMOTE%.git}
if [ -n "$REMOTE" ]; then
  REPO_NAME=${REMOTE##*/}
  REPO_LINK=$(printf '%b' "\e]8;;${REMOTE}\a${REPO_NAME}\e]8;;\a")
fi

# PWD subpath: show cwd relative to project root when inside a subdirectory.
# project_dir is supplied by the harness; fall back to git toplevel if absent.
PWD_SUBPATH=""
_proj="$PROJECT_DIR"
if [ -z "$_proj" ]; then
  _proj=$(git rev-parse --show-toplevel 2>/dev/null)
fi
if [ -n "$_proj" ] && [ -n "$DIR" ] && [ "$DIR" != "$_proj" ]; then
  case "$DIR" in
    "$_proj"/*) PWD_SUBPATH="${DIR#$_proj/}" ;;
  esac
fi

# ── Context bar ───────────────────────────────────────────────
# Each cell represents 10%; any partial above a 10%-multiple lights a half-cell.
# Gives a smooth gradient: 0%=empty, 1-9%=◐, 10%=●, 11-19%=●◐, 20%=●●, ...
BAR_COLOR=$(color_pct "$PCT")
BAR_W=10
FULL=$((PCT / 10))
[ "$FULL" -gt "$BAR_W" ] && FULL=$BAR_W
HAS_HALF=0
[ "$PCT" -gt 0 ] && [ $((PCT % 10)) -gt 0 ] && [ "$FULL" -lt "$BAR_W" ] && HAS_HALF=1
EMPTY=$((BAR_W - FULL - HAS_HALF))
BAR=""
for ((i = 0; i < FULL; i++)); do BAR="${BAR}${BAR_COLOR}●${RESET}"; done
[ "$HAS_HALF" -eq 1 ] && BAR="${BAR}${BAR_COLOR}◐${RESET}"
for ((i = 0; i < EMPTY; i++)); do BAR="${BAR}${DIM}●${RESET}"; done

# ── Duration ──────────────────────────────────────────────────
# Status: DISABLED — display not currently rendered on any L1–L4 line.
# Consumes: DURATION_MS (F[5])
# Paired-disable note: DURATION_MS is ALSO consumed by L3 api wait % (l. ~358)
#   → do NOT comment out the F[5] extraction even if you keep DUR disabled.
# To re-enable: uncomment below AND inject ${DUR} into the desired L1–L4 line.
# DUR=$(fmt_dur "$DURATION_MS")

# ── Git file stats (M/A/D counts + working-tree line diff) — consumed inside (branch*) on L1 ──
# Per AJ-25 + follow-up: M/A/D file counts + +N/-N line diff inside parens BOTH come from
# git working-tree state (real-time, resets on commit/revert). Session-cumulative +N/-N
# from cost JSON renders separately on L3 (see SESSION_LINES below).
GIT_M=0
GIT_A=0
GIT_D=0
GIT_LINES_ADD=0
GIT_LINES_DEL=0
if [ "$IS_GIT" -eq 1 ]; then
  # One porcelain pass replaces three `git diff`/`ls-files` calls. Keys on the
  # WORKTREE column (Y), matching `git diff --name-only`'s unstaged-only scope —
  # keying on X would newly count staged-only files. `-uall` is required: plain
  # porcelain collapses an untracked directory to one entry, `ls-files --others`
  # lists every file inside it.
  while IFS= read -r _line; do
    case "${_line:0:2}" in
      '??') GIT_A=$((GIT_A + 1)) ;;
      ?D)   GIT_D=$((GIT_D + 1)); GIT_M=$((GIT_M + 1)) ;;
      ?[!\ ]) GIT_M=$((GIT_M + 1)) ;;
    esac
  done < <(git status --porcelain -uall 2>/dev/null)
  # Working-tree +N/-N from shortstat (staged + unstaged); untracked file lines not counted.
  _shortstat=$(git diff HEAD --shortstat 2>/dev/null)
  GIT_LINES_ADD=0
  GIT_LINES_DEL=0
  [[ $_shortstat =~ ([0-9]+)\ insertion ]] && GIT_LINES_ADD=${BASH_REMATCH[1]}
  [[ $_shortstat =~ ([0-9]+)\ deletion ]] && GIT_LINES_DEL=${BASH_REMATCH[1]}
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

# ── Login account (from ~/.claude.json) ───────────────────────
# Source: .oauthAccount — not in statusline stdin JSON, read directly like EFFORT.
# Display: displayName + redacted email (local part masked to first char).
ACCOUNT=""
# One jq, two lines: ~/.claude.json is ~140KB, so parsing it twice costs more
# than everything else on this path. `// ""` rather than `// empty` — a dropped
# line would shift the email into the name.
ACCT_NAME=""
ACCT_EMAIL=""
{ read -r ACCT_NAME; read -r ACCT_EMAIL; } < <(
  jq -r '(.oauthAccount.displayName // ""), (.oauthAccount.emailAddress // "")' \
     "$HOME/.claude.json" 2>/dev/null
)
ACCT_REDACTED=""
if [ -n "$ACCT_EMAIL" ]; then
  ACCT_REDACTED="${ACCT_EMAIL%%@*}"
  ACCT_REDACTED="${ACCT_REDACTED:0:1}***@${ACCT_EMAIL#*@}"
fi
if [ -n "$ACCT_NAME" ] && [ -n "$ACCT_REDACTED" ]; then
  ACCOUNT="👤 ${ACCT_NAME} ${DIM}·${RESET} ${DIM}${ACCT_REDACTED}${RESET}"
elif [ -n "$ACCT_NAME" ]; then
  ACCOUNT="👤 ${ACCT_NAME}"
elif [ -n "$ACCT_REDACTED" ]; then
  ACCOUNT="👤 ${DIM}${ACCT_REDACTED}${RESET}"
fi

# ══════════════════════════════════════════════════════════════
# LINE 1: Model + Context size + Version + Repo + Branch + Lines + Files + Agent + Account
# INPUTS: MODEL_DISP CTX_LABEL VERSION REPO_LINK BRANCH LINES_ADD LINES_DEL GIT_STATS VIM_MODE ACCOUNT
# ══════════════════════════════════════════════════════════════
L1="${CYAN}${BOLD}${MODEL_DISP}${RESET}"
[ -n "$CTX_LABEL" ] && L1="${L1} ${CTX_LABEL}"
# [ -n "$VERSION" ] && L1="${L1} ${DIM}v${VERSION}${RESET}"   # Hidden per AJ-25 — uncomment to re-enable Claude Code version.
L1="${L1}${SEP}${WHITE}${REPO_LINK}${RESET}"
[ -n "$PWD_SUBPATH" ] && L1="${L1}${DIM}/${PWD_SUBPATH}${RESET}"

# ── Consolidated git block (AJ-25): (branch* M A D +N -N) — suppress zero categories ──
if [ -n "$BRANCH" ]; then
  BRANCH_PARTS="${BRANCH}"
  # Dirty marker: any of M/A/D > 0
  if { [ "$GIT_M" -gt 0 ] 2>/dev/null; } || { [ "$GIT_A" -gt 0 ] 2>/dev/null; } || { [ "$GIT_D" -gt 0 ] 2>/dev/null; }; then
    BRANCH_PARTS="${BRANCH_PARTS}*"
  fi
  [ "$GIT_M" -gt 0 ] 2>/dev/null && BRANCH_PARTS="${BRANCH_PARTS} ${YELLOW}${GIT_M}M${RESET}${DIM}"
  [ "$GIT_A" -gt 0 ] 2>/dev/null && BRANCH_PARTS="${BRANCH_PARTS} ${GREEN}${GIT_A}A${RESET}${DIM}"
  [ "$GIT_D" -gt 0 ] 2>/dev/null && BRANCH_PARTS="${BRANCH_PARTS} ${RED}${GIT_D}D${RESET}${DIM}"
  [ "$GIT_LINES_ADD" -gt 0 ] 2>/dev/null && BRANCH_PARTS="${BRANCH_PARTS} ${GREEN}+${GIT_LINES_ADD}${RESET}${DIM}"
  [ "$GIT_LINES_DEL" -gt 0 ] 2>/dev/null && BRANCH_PARTS="${BRANCH_PARTS} ${RED}-${GIT_LINES_DEL}${RESET}${DIM}"
  L1="${L1} ${DIM}(${BRANCH_PARTS})${RESET}"
fi

# ── Current commit short hash (after worktree/branch block) ──
[ -n "$GIT_COMMIT" ] && L1="${L1} ${DIM}@${RESET}${MAGENTA}${GIT_COMMIT}${RESET}"


[ -n "$VIM_MODE" ] && {
  if [ "$VIM_MODE" = "NORMAL" ]; then
    L1="${L1}${SEP}${BLUE}${BOLD}NOR${RESET}"
  else
    L1="${L1}${SEP}${GREEN}${BOLD}INS${RESET}"
  fi
}

# ── Login account (identity, end of L1) ──────────────────────
[ -n "$ACCOUNT" ] && L1="${L1}${SEP}${ACCOUNT}"

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

# Session-cumulative line diff (from cost.total_lines_*) — distinct from
# git working-tree +N/-N inside the L1 parens. This is monotonic across the session.
SESSION_LINES_PART=""
if [ -n "$LINES_ADD" ] && [ "$LINES_ADD" != "0" ]; then
  SESSION_LINES_PART="${GREEN}+${LINES_ADD}${RESET}"
fi
if [ -n "$LINES_DEL" ] && [ "$LINES_DEL" != "0" ]; then
  [ -n "$SESSION_LINES_PART" ] && SESSION_LINES_PART="${SESSION_LINES_PART} ${RED}-${LINES_DEL}${RESET}" || SESSION_LINES_PART="${RED}-${LINES_DEL}${RESET}"
fi
[ -n "$SESSION_LINES_PART" ] && L3="${L3}${SEP}${SESSION_LINES_PART} ${DIM}lines${RESET}"

# Tools running — moved from L4 to L3 (after api wait + session lines) per user preference.
[ "$RUNNING_TOOL_COUNT" -gt 0 ] && L3="${L3}${SEP}${DIM}tools${RESET} ${YELLOW}${RUNNING_TOOLS}${RESET}"

# Subagent dispatch (AJ-25 — claude-hud parity): rendered as dedicated L3.5 lines
# below L3, not inline on L3. See AGENTS_LINES construction in the output section.
# Replaced old `agents N type,type` inline render.

# Current token detail (cur in / read / write) — DISABLED, uncomment to re-enable.
# Paired-disable note: CUR_INPUT (F[19]) / CACHE_READ (F[17]) / CACHE_CREATE (F[18])
# are ALSO consumed by the cache hit rate block (l. ~309) — do NOT comment out
# their F[N] extractions.
# CUR_IN_FMT=$(fmt_tokens "$CUR_INPUT")
# CACHE_R_FMT=$(fmt_tokens "$CACHE_READ")
# CACHE_C_FMT=$(fmt_tokens "$CACHE_CREATE")
# L3="${L3}${SEP}${DIM}cur${RESET} ${CUR_IN_FMT} ${DIM}in${RESET} ${CACHE_R_FMT} ${DIM}read${RESET} ${CACHE_C_FMT} ${DIM}write${RESET}"

# ══════════════════════════════════════════════════════════════
# LINE 4: Live activity — running tools + todos + last prompt
# INPUTS: RUNNING_TOOLS TODO_DONE/TODO_TOTAL TODO_CURRENT LAST_PROMPT LAST_PROMPT_TIME
#         (all derived from TRANSCRIPT_PATH + SESSION_ID + history.jsonl)
# Conditionally printed — only if at least one field is non-empty.
# ══════════════════════════════════════════════════════════════
L4=""
add4() { [ -n "$L4" ] && L4="${L4}${SEP}$1" || L4="$1"; }

# Tools moved to L3 (after api wait) — was: add4 tools render here.
if [ "$TODO_TOTAL" -gt 0 ]; then
  TODO_PART="${CYAN}todos ${TODO_DONE}/${TODO_TOTAL}${RESET}"
  [ -n "$TODO_CURRENT" ] && TODO_PART="${TODO_PART} ${DIM}${TODO_CURRENT:0:40}${RESET}"
  add4 "$TODO_PART"
fi
if [ -n "$LAST_PROMPT" ]; then
  PROMPT_PART=""
  [ -n "$LAST_PROMPT_TIME" ] && PROMPT_PART="${DIM}${LAST_PROMPT_TIME}${RESET} "
  PROMPT_PART="${PROMPT_PART}${DIM}❯${RESET} ${LAST_PROMPT}"
  add4 "$PROMPT_PART"
fi

# ── Subagent dispatch lines (AJ-25 — claude-hud parity) ──────
# Up to 3 most-recent agents, one per line. `◐` = running, `✓` = completed.
AGENT_LINES=""
if [ -n "$AGENTS_WITH_STATUS" ]; then
  while IFS=$'\t' read -r ag_status ag_type ag_desc; do
    [ -z "$ag_type" ] && continue
    if [ "$ag_status" = "running" ]; then
      ag_icon="${YELLOW}◐${RESET}"
    else
      ag_icon="${GREEN}✓${RESET}"
    fi
    # Truncate description to 60 chars (claude-hud uses ~40; widen a bit for cc-statusline density)
    ag_desc_trunc="${ag_desc:0:60}"
    ag_line="${ag_icon} ${MAGENTA}${ag_type}${RESET}: ${DIM}${ag_desc_trunc}${RESET}"
    [ -n "$AGENT_LINES" ] && AGENT_LINES="${AGENT_LINES}"$'\n'"${ag_line}" || AGENT_LINES="${ag_line}"
  done <<< "$AGENTS_WITH_STATUS"
fi

# ── Output ────────────────────────────────────────────────────
echo -e "$L1"
echo -e "$L2"
echo -e "$L3"
[ -n "$AGENT_LINES" ] && echo -e "$AGENT_LINES"
[ -n "$L4" ] && echo -e "$L4"

# Claude Code discards statusline output on a non-zero exit. The optional-line
# tests above become the exit status when their variable is empty, so pin it.
exit 0


#!/bin/bash
# Smoke test for cc-statusline.sh
#
# Runs the script against test/sample.json and asserts structural markers.
# Robust to volatile fields (today-cost tracker, countdown, git state of cwd).
#
# Exits 0 on pass, 1 on fail.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/cc-statusline.sh"
SAMPLE="$SCRIPT_DIR/sample.json"

# Both rewrite the window label, and Claude Code exports them from settings.json
# — a suite run inside a session inherits them without any shell doing it.
unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
unset CC_STATUSLINE_FORGE CC_STATUSLINE_WEB_PORT

fail=0
pass=0
check() {
  local name=$1
  local cond=$2
  if eval "$cond"; then
    echo "  ✅ $name"
    pass=$((pass + 1))
  else
    echo "  ❌ $name"
    fail=$((fail + 1))
  fi
}

echo "Running cc-statusline.sh against test/sample.json…"
out=$(bash "$SCRIPT" < "$SAMPLE" 2>/dev/null)
# Strip ANSI for content checks
plain=$(printf '%s' "$out" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g')

echo
echo "Output (plain):"
echo "$plain" | sed 's/^/  | /'
echo

# Structural assertions
check "non-empty output"               '[ -n "$out" ]'
check "at least 3 lines"               '[ "$(printf "%s\n" "$plain" | wc -l)" -ge 3 ]'
check "contains model name"            'grep -q "Opus 4.7" <<< "$plain"'
# The model badge no longer carries the deployment variant, so the window is
# named once, on L2, as the effective budget the bar divides by.
check "no context variant in the badge" '! grep -q "1M context" <<< "$plain"'
check "contains ctx window label"      'grep -qE "[0-9]+% [0-9.]+[KM]" <<< "$(printf "%s\n" "$plain" | sed -n 2p)"'
check "version hidden (AJ-25)"         '! grep -q "v1.2.3" <<< "$plain"'
check "contains session cost"          'grep -q "\$1.23" <<< "$plain"'
check "contains today cost label"      'grep -qF "(today \$" <<< "$plain"'
check "contains 5h rate limit"         'grep -q "5h 23%" <<< "$plain"'
check "contains 7d rate limit"         'grep -q "7d 57%" <<< "$plain"'

# ── Countdown day unit ────────────────────────────────────────
# The 7d window resets up to 168h out, so its countdown has to read "2d 13h"
# rather than "61h 44m". Both cases are pinned relative to now: the sample's
# fixed resets_at sits in 2286, which proves the day branch renders and nothing
# else about what it renders.
countdown_7d() {  # $1 = seconds from now; echoes the plain 7d group from L2
  local tmp; tmp=$(mktemp -t cc-statusline-countdown.XXXXXX)
  jq --argjson t "$(( $(date +%s) + $1 ))" \
     '.rate_limits.seven_day.resets_at = $t' "$SAMPLE" > "$tmp"
  bash "$SCRIPT" < "$tmp" 2>/dev/null \
    | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g' \
    | grep -oE '7d 57% \([^)]*\)'
  rm -f "$tmp"
}
# The reported symptom. Operand order is load-bearing — swapped, this reads "13d 2h".
check "(countdown) 61h44m reads 2d 13h" '[ "$(countdown_7d 222240)" = "7d 57% (2d 13h)" ]'
# Just past the inclusive boundary: pins the "1d 0h" spelling against "24h 0m".
check "(countdown) 24h+1m reads 1d 0h"  '[ "$(countdown_7d 86460)" = "7d 57% (1d 0h)" ]'
check "contains in/out tokens"         'grep -q "in: 123.4K" <<< "$plain" && grep -q "out: 7.8K" <<< "$plain"'
check "contains api wait line"         'grep -q "api wait" <<< "$plain"'
check "contains cache hit %"           'grep -q "cache 97%" <<< "$plain"'
check "contains vim NORMAL marker"     'grep -q "NOR" <<< "$plain"'
check "session id renders on L3"       '[ "$(printf "%s\n" "$plain" | sed -n 3p | grep -c "#test-session-id-xyz")" = 1 ]'
check "cwd links to file://"           'grep -q "]8;;file:///home/jimmy/projects/conex/jj" <<< "$out"'
# The sample's current_dir is a subdirectory of its project_dir, so the path shown
# is the project root and not wherever the session wandered.
check "L1 path is the project root"    '! grep -q "conex/jj/src" <<< "$plain"'
# Older Claude versions send no project_dir; the cwd is what is left to show.
check "no project_dir falls back to cwd" \
  'jq "del(.workspace.project_dir)" "$SAMPLE" | bash "$SCRIPT" 2>/dev/null | grep -q "conex/jj/src"'
check "L1 carries user:project"        'grep -qE "\| [^ :]+:[^ :|]+ git:\\(" <<< "$(printf "%s\n" "$plain" | sed -n 1p)"'
check "account shows email only"       '! grep -qE "👤 [^ ]+ · " <<< "$plain"'

# ── Second pass: with a real transcript that has active agents/tools/todos ──
echo
echo "Running with active transcript (agents/tools/todos)…"
TRANSCRIPT_TMP=$(mktemp -t cc-statusline-smoke.XXXXXX.jsonl)
trap 'rm -f "$TRANSCRIPT_TMP"' EXIT
# Fixture order is load-bearing: toolu_multiline must precede another running
# tool. Its continuation lines emit empty records, and command substitution
# strips trailing empties — in last position the phantom-comma check below
# would pass vacuously.
cat > "$TRANSCRIPT_TMP" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"subagent_type":"reviewer-opus-high","description":"alpha\rbeta"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_multiline","name":"Bash","input":{"description":"first line\nsecond line\nthird line"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"/tmp/x"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_todo","name":"TodoWrite","input":{"todos":[{"content":"first","status":"completed"},{"content":"second","status":"in_progress"}]}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_todo","content":"ok"}]}}
JSONL
out2=$(jq --arg t "$TRANSCRIPT_TMP" '.transcript_path=$t' "$SAMPLE" | bash "$SCRIPT" 2>/dev/null)
plain2=$(printf '%s' "$out2" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g')

echo "Output (plain, with transcript):"
echo "$plain2" | sed 's/^/  | /'
echo

check "(active) contains agents indicator"  'grep -qE "(◐|✓) reviewer-opus-high" <<< "$plain2"'
check "(active) contains tools indicator"   'grep -q "tools Bash,Read" <<< "$plain2"'
# A multi-line `description` used to split its record across lines; each continuation
# parsed as a nameless never-completed tool_use, rendering as bare commas.
check "(active) no phantom empty tools"     '! grep -qE "tools ,|,," <<< "$plain2"'
# A bare CR reaching stdout rewinds the cursor and overwrites the drawn line.
check "(active) no raw CR in output"        '! grep -q $'"'"'\r'"'"' <<< "$out2"'
check "(active) contains todos progress"    'grep -q "todos 1/2" <<< "$plain2"'
check "(active) contains current todo"      'grep -q "second" <<< "$plain2"'

# ── Third pass: branch label, in a throwaway repo ──────────────────────────
# Runs from a scratch repo because the label depends on the cwd's git state.
# Two traps are laid on purpose, both on commits the cases land on:
#   decoy       — a local branch; `git name-rev` would pick it (issue #9)
#   origin/HEAD — shortens to the bare `origin` and sorts first (issue #12)
echo
echo "Running branch-label cases in a scratch repo…"
REPO_TMP=$(mktemp -d -t cc-statusline-smoke.XXXXXX)
trap 'rm -f "$TRANSCRIPT_TMP"; rm -rf "$REPO_TMP" "$REPO_TMP/../wt-$$"' EXIT
(
  cd "$REPO_TMP"
  git init -q -b main
  git config user.email t@t && git config user.name t
  echo one > f && git add f && git commit -qm one
  git branch decoy
  echo two > f && git commit -qam two
  git update-ref refs/remotes/origin/main HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
) > /dev/null 2>&1

label() {  # $1 = revision to check out; echoes L1's branch:commit token
  git -C "$REPO_TMP" checkout -q "$1"
  ( cd "$REPO_TMP" && bash "$SCRIPT" < "$SAMPLE" 2>/dev/null ) \
    | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g' \
    | head -1 | grep -oP '\x{e0a0} \K[^ |)]+'
}

check "(git) detached at origin ref → ref name" '[[ "$(label main~0)" =~ ^origin/main:[0-9a-f]+$ ]]'
check "(git) detached, no origin ref → literal" '[[ "$(label decoy~0)" =~ ^detached:[0-9a-f]+$ ]]'
check "(git) on a branch → branch name"         '[[ "$(label main)" =~ ^main:[0-9a-f]+$ ]]'
# The glyph before the branch says which checkout this is:  in a normal one,
# τ in a linked worktree. Same repo, so only the glyph may differ.
glyph() {  # $1 = directory to render from; echoes the glyph before the branch
  ( cd "$1" && bash "$SCRIPT" < "$SAMPLE" 2>/dev/null ) \
    | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g' \
    | head -1 | grep -oP '\S(?= \S+:[0-9a-f]+)'
}
git -C "$REPO_TMP" checkout -q main
git -C "$REPO_TMP" worktree add -q "$REPO_TMP/../wt-$$" -b wt-branch >/dev/null 2>&1
GLYPH_BRANCH=$'\ue0a0'
check "(git) main checkout → branch glyph"     '[ "$(glyph "$REPO_TMP")" = "$GLYPH_BRANCH" ]'
check "(git) linked worktree → tau glyph"      '[ "$(glyph "$REPO_TMP/../wt-$$")" = "τ" ]'
# In a worktree the branch name reaches the worktree's own directory — the shown
# path is the main checkout's, so nothing else on the line would.
wt_branch_link() {
  ( cd "$1" && bash "$SCRIPT" < "$SAMPLE" 2>/dev/null ) | head -1 \
    | grep -oP '\x1b\]8;;\K[^\x07]+' | tail -1
}
check "(git) worktree branch → its own dir"    '[ "$(wt_branch_link "$REPO_TMP/../wt-$$")" = "file://$(cd "$REPO_TMP/../wt-$$" && pwd)" ]'
# A session launched in a worktree reports the worktree as its project root, so
# the collapse to the main checkout has to happen here or the long path is back.
wt_path_link() {  # $1 = worktree dir, reported as both cwd and project root
  local d
  d=$(cd "$1" && pwd)
  jq --arg d "$d" '.workspace.project_dir = $d | .workspace.current_dir = $d' "$SAMPLE" \
    | ( cd "$d" && bash "$SCRIPT" 2>/dev/null ) \
    | head -1 | grep -oP '\x1b\]8;;\K[^\x07]+' | head -1
}
check "(git) worktree path → main checkout"    '[ "$(wt_path_link "$REPO_TMP/../wt-$$")" = "file://$(cd "$REPO_TMP" && pwd)" ]'
# project_dir is fixed at launch; a session that has since moved out of it (the
# worktree removed after its merge, cwd back in the main checkout) must show
# where it is now, not where it started.
stale_path_link() {  # $1 = cwd (a git root), $2 = stale project_dir
  local d
  d=$(cd "$1" && pwd)
  jq --arg d "$d" --arg p "$2" '.workspace.project_dir = $p | .workspace.current_dir = $d' "$SAMPLE" \
    | ( cd "$d" && bash "$SCRIPT" 2>/dev/null ) \
    | head -1 | grep -oP '\x1b\]8;;\K[^\x07]+' | head -1
}
check "(git) stale project_dir → cwd git root" '[ "$(stale_path_link "$REPO_TMP" "$REPO_TMP/.claude/worktrees/gone")" = "file://$(cd "$REPO_TMP" && pwd)" ]'

# ── Fourth pass: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE ───────────────────────────
# The bar divides by the override'd budget, so a wrong parse is invisible in the
# label but silently wrong in the %; both are asserted.
echo
echo "Running auto-compact percentage override cases…"
win() {  # $1 = env value, or UNSET; echoes L2's window label + bar %
  local out
  if [ "$1" = UNSET ]; then out=$(bash "$SCRIPT" < "$SAMPLE" 2>/dev/null)
  else out=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="$1" bash "$SCRIPT" < "$SAMPLE" 2>/dev/null)
  fi
  # Both live on L2 now: `<bar> <pct>% <label> | …` — echoed label-first, so the
  # expected strings below keep reading "<label> <pct>%".
  printf '%s' "$out" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g' \
    | sed -nE '2s/^[●◐ ]+ ([0-9]+%) ([^|]*) \|.*/\2 \1/p' | tr -d '\n'
}

check "(pct) unset → window less reserve"  '[ "$(win UNSET)" = "987K 5%" ]'
check "(pct) set-but-empty → same as unset" '[ "$(win "")" = "987K 5%" ]'
check "(pct) 50 → halved budget, 10%"      '[ "$(win 50)" = "500K (1M·50%) 10%" ]'
check "(pct) decimals kept"                '[ "$(win 33.3)" = "333K (1M·33.3%) 15%" ]'
check "(pct) label normalised"             '[ "$(win 33.30)" = "333K (1M·33.3%) 15%" ]'
check "(pct) non-numeric ignored"          '[ "$(win abc)" = "987K 5%" ]'
check "(pct) out of range ignored"         '[ "$(win 150)" = "987K 5%" ]'
# Boundaries where a truncate-then-range-check gets it wrong; both scripts must
# agree on every one of them.
check "(pct) 100 → reserve still binds"    '[ "$(win 100)" = "987K (1M·100%) 5%" ]'
check "(pct) just over 100 ignored"        '[ "$(win 100.004)" = "987K 5%" ]'
check "(pct) tiny fraction still applies"  '[ "$(win 0.001)" = "0K (1M·0.001%) 100%" ]'
check "(pct) zero ignored"                 '[ "$(win 0)" = "987K 5%" ]'
check "(pct) parseFloat prefix accepted"   '[ "$(win 50abc)" = "500K (1M·50%) 10%" ]'
check "(pct) exponent notation rejected"   '[ "$(win 1e2)" = "987K 5%" ]'
check "(pct) overlong digit run ignored"   '[ "$(win 99999999999999999999)" = "987K 5%" ]'
# Which arm of the CLI's min() binds depends on the window; both are covered.
check "(pct) 99 on 1M → reserve arm wins"  '[ "$(win 99)" = "987K (1M·99%) 5%" ]'
check "(pct) 98 on 1M → pct arm wins"      '[ "$(win 98)" = "980K (1M·98%) 5%" ]'
check "(pct) applies to the ACW window"    '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000; win 50)" = "100K (200K·50%) 51%" ]'
check "(pct) reserve applies to ACW too"   '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000; win UNSET)" = "187K 27%" ]'
check "(pct) 95 on 200K → reserve arm"     '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000; win 95)" = "187K (200K·95%) 27%" ]'
# A window at or below the reserve has nothing left to divide by; the full
# window stands in rather than a zero or negative budget.
check "(pct) window at the reserve"        '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=13000; win UNSET)" = "13K 100%" ]'
# ...and an override on such a window still takes its own arm. The CLI's min()
# would pick the reserve arm's zero and compact at once; a zero budget is not
# divisible, so pinning the pct arm here pins the deliberate divergence.
check "(pct) override on a reserve window" '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=13000; win 50)" = "6K (13K·50%) 100%" ]'

# ── Fifth pass: L1 hyperlink targets, in a throwaway repo ──────────────────
# The URLs live inside OSC 8 sequences, which every other pass strips, so these
# read the raw output. Same scratch repo as the branch-label pass, re-pointed.
echo
echo "Running hyperlink-target cases…"
link() {  # $1 = remote URL, $2 = branch; echoes the branch link (last OSC 8)
  git -C "$REPO_TMP" remote remove origin 2>/dev/null
  git -C "$REPO_TMP" remote add origin "$1"
  git -C "$REPO_TMP" checkout -q -B "$2" main
  # The branch link is built only for a branch the remote has, so the scratch
  # repo has to look pushed. `link_local` below is the unpushed counterpart.
  git -C "$REPO_TMP" update-ref "refs/remotes/origin/$2" HEAD
  ( cd "$REPO_TMP" && bash "$SCRIPT" < "$SAMPLE" 2>/dev/null ) \
    | head -1 | grep -oP '\x1b\]8;;\K[^\x07]+' | tail -1
}

check "(link) scp remote → https tree URL" \
  '[ "$(link git@github.com:o/r.git b)" = "https://github.com/o/r/tree/b" ]'
# An SSH remote is unbrowsable as given; the user and the SSH port are dropped.
check "(link) ssh:// remote loses user+port" \
  '[ "$(link ssh://git@gitlab.example.com:2222/g/p.git b)" = "https://gitlab.example.com/g/p/-/tree/b" ]'
# ...but a port on an https remote is the web UI's own and must survive.
check "(link) https port survives" \
  '[ "$(link https://10.0.0.1:30001/g/p.git b)" = "https://10.0.0.1:30001/g/p/tree/b" ]'
check "(link) non-git ssh user rewritten" \
  '[ "$(link deploy@git.example.com:g/p.git b)" = "https://git.example.com/g/p/tree/b" ]'
# The forge guess reads the host only: this repo lives on GitHub.
check "(link) gitlab in path is not gitlab" \
  '[ "$(link https://github.com/gitlab-org/gitlab.git b)" = "https://github.com/gitlab-org/gitlab/tree/b" ]'
# Case-insensitive on purpose — the ps1 mirror's -like cannot be made otherwise.
check "(link) mixed-case gitlab host matches" \
  '[ "$(link git@GitLab.example.com:g/p.git b)" = "https://GitLab.example.com/g/p/-/tree/b" ]'
# A self-hosted instance whose host names no forge is unreachable by any guess.
check "(link) FORGE override wins" \
  '[ "$(export CC_STATUSLINE_FORGE=gitlab; link https://10.0.0.1:30001/g/p.git b)" = "https://10.0.0.1:30001/g/p/-/tree/b" ]'
# A ref lands in a path now, so `&` and `=` are legal there and must survive;
# `#` would still truncate the URL.
check "(link) branch & and = kept verbatim" \
  '[ "$(link https://github.com/o/r.git "x&y=z")" = "https://github.com/o/r/tree/x&y=z" ]'
# The SSH port is not the web port; only the user knows which one serves the UI.
check "(link) WEB_PORT added to ssh:// remote" \
  '[ "$(export CC_STATUSLINE_WEB_PORT=30001; link ssh://git@10.0.0.1:30023/g/p.git b)" = "https://10.0.0.1:30001/g/p/tree/b" ]'
check "(link) WEB_PORT added to scp remote" \
  '[ "$(export CC_STATUSLINE_WEB_PORT=30001; link git@10.0.0.1:g/p.git b)" = "https://10.0.0.1:30001/g/p/tree/b" ]'
# An https remote already carries the web port; the override must not double it.
check "(link) WEB_PORT leaves https remote alone" \
  '[ "$(export CC_STATUSLINE_WEB_PORT=30001; link https://10.0.0.1:8080/g/p.git b)" = "https://10.0.0.1:8080/g/p/tree/b" ]'
# The value is spliced into a link target, so anything but digits is ignored —
# `443/@evil.example.com` would otherwise point the link at another host.
check "(link) non-numeric WEB_PORT ignored" \
  '[ "$(export CC_STATUSLINE_WEB_PORT=443/@evil.example.com; link git@10.0.0.1:g/p.git b)" = "https://10.0.0.1/g/p/tree/b" ]'
# A branch the remote never saw has no tree there — a throwaway worktree's local
# branch is the usual one. The cwd link is then the only OSC 8 left on the line.
link_local() {  # $1 = remote URL, $2 = branch; same, but the branch is unpushed
  git -C "$REPO_TMP" remote remove origin 2>/dev/null
  git -C "$REPO_TMP" remote add origin "$1"
  git -C "$REPO_TMP" checkout -q -B "$2" main
  git -C "$REPO_TMP" update-ref -d "refs/remotes/origin/$2" 2>/dev/null
  ( cd "$REPO_TMP" && bash "$SCRIPT" < "$SAMPLE" 2>/dev/null ) \
    | head -1 | grep -oP '\x1b\]8;;\K[^\x07]+' | tail -1
}
check "(link) unpushed branch → cwd link only" \
  '[ "$(link_local https://github.com/o/r.git wt-scratch)" = "file:///home/jimmy/projects/conex/jj" ]'
check "(link) branch # encoded" \
  '[ "$(link https://github.com/o/r.git "x#y")" = "https://github.com/o/r/tree/x%23y" ]'
# The one byte that must NOT be escaped: `feat/x` is both a real ref and a real
# tree path, and %2F is not resolved by either forge.
check "(link) branch slash survives" \
  '[ "$(link https://github.com/o/r.git "feat/x")" = "https://github.com/o/r/tree/feat/x" ]'
# Detached HEAD shows a remote ref or the literal `detached`; neither is a branch
# the forge resolves, so the cwd file:// link is the only OSC 8 left on the line.
check "(link) detached HEAD → cwd link only" \
  '[ "$(link https://github.com/o/r.git b >/dev/null; git -C "$REPO_TMP" checkout -q --detach HEAD; cd "$REPO_TMP" && bash "$SCRIPT" < "$SAMPLE" 2>/dev/null | head -1 | grep -oP '"'"'\x1b\]8;;\K[^\x07]+'"'"' | tail -1)" = "file:///home/jimmy/projects/conex/jj" ]'

# ── Sixth pass: the effort label, against a crafted settings.json ──────────
# Effort is read from settings.json, not from stdin, so these point HOME at a
# scratch copy rather than the machine's own — which also keeps the cost
# tracker and account lookup out of the real one.
echo
echo "Running effort-label cases…"
HOME_TMP=$(mktemp -d)
trap 'rm -rf "$HOME_TMP"' EXIT
mkdir -p "$HOME_TMP/.claude"
SETTINGS_DEFAULT='{ "effortLevel": "medium",
                    "modelSettings": { "claude-opus-5": { "effortLevel": "low" } } }'

effort() {  # $1 = model id (may be empty), $2 = settings.json (default above)
  printf '%s' "${2:-$SETTINGS_DEFAULT}" > "$HOME_TMP/.claude/settings.json"
  printf '%s' "{\"model\":{\"id\":\"$1\",\"display_name\":\"Opus 5 (1M context)\"},
    \"workspace\":{\"current_dir\":\"$HOME_TMP\"},
    \"context_window\":{\"used_percentage\":10,\"context_window_size\":1000000},
    \"session_id\":\"effort-test\"}" \
    | HOME="$HOME_TMP" bash "$SCRIPT" 2>/dev/null \
    | head -1 | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed -E 's/ \|.*//'
}

effort_raw() {  # same, ANSI intact — the colour is part of what is asserted
  printf '%s' "${2:-$SETTINGS_DEFAULT}" > "$HOME_TMP/.claude/settings.json"
  printf '%s' "{\"model\":{\"id\":\"$1\",\"display_name\":\"Opus 5 (1M context)\"},
    \"workspace\":{\"current_dir\":\"$HOME_TMP\"},
    \"context_window\":{\"used_percentage\":10,\"context_window_size\":1000000},
    \"session_id\":\"effort-test\"}" \
    | HOME="$HOME_TMP" bash "$SCRIPT" 2>/dev/null | head -1
}

# The runtime says what it is running at, and that beats anything the file says:
# settings edited mid-session, or /effort, leave the file describing a level the
# session is not on.
effort_payload() {  # $1 = .effort.level, $2 = settings.json (default above), $3 = display_name
  printf '%s' "${2:-$SETTINGS_DEFAULT}" > "$HOME_TMP/.claude/settings.json"
  printf '%s' "{\"model\":{\"id\":\"claude-opus-5\",\"display_name\":\"${3:-Opus 5 (1M context)}\"},
    \"effort\":{\"level\":\"$1\"},
    \"workspace\":{\"current_dir\":\"$HOME_TMP\"},
    \"context_window\":{\"used_percentage\":10,\"context_window_size\":1000000},
    \"session_id\":\"effort-test\"}" \
    | HOME="$HOME_TMP" bash "$SCRIPT" 2>/dev/null \
    | head -1 | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed -E 's/ \|.*//'
}
check "(effort) payload beats settings" \
  '[ "$(effort_payload high)" = "Opus 5 (high)" ]'
# ...including when the file has nothing to say at all.
check "(effort) payload without settings" \
  '[ "$(effort_payload xhigh "{}")" = "Opus 5 (xhigh)" ]'

# The badge is not gated on the model name: a Fable or Haiku session that
# reports a level shows it, same as Opus.
check "(effort) badge on a non-Opus/Sonnet model" \
  '[ "$(effort_payload medium "{}" "Fable 5.1")" = "Fable 5.1 (medium)" ]'

# ── Today-cost tracker, against a crafted tracker file ─────────────────────
# A refresh that lands on an unreadable tracker must start it over, not carry
# the emptiness forward: jq on an empty file prints nothing and exits 0, which
# once left today at $0.00 until someone deleted the file by hand.
today() {  # $1 = session id, $2 = cost.total_cost_usd → the "today $X" figure
  printf '%s' "{\"model\":{\"display_name\":\"Opus 5\"},\"cost\":{\"total_cost_usd\":$2},
    \"workspace\":{\"current_dir\":\"$HOME_TMP\"},
    \"context_window\":{\"used_percentage\":10,\"context_window_size\":1000000},
    \"session_id\":\"$1\"}" \
    | HOME="$HOME_TMP" bash "$SCRIPT" 2>/dev/null \
    | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -o 'today \$[0-9.]*' | head -1
}
TRACKER_TMP=$HOME_TMP/.claude/cc-statusline-cost.json

: > "$TRACKER_TMP"
check "(today) empty tracker restarts from this session" \
  '[ "$(today s1 1.50)" = "today \$1.50" ]'

printf '%s' '{"date":"x","sessions":{"a":' > "$TRACKER_TMP"
check "(today) unparsable tracker restarts from this session" \
  '[ "$(today s1 1.50)" = "today \$1.50" ]'

rm -f "$TRACKER_TMP"
check "(today) missing tracker shows this session, not 0" \
  '[ "$(today s1 1.50)" = "today \$1.50" ]'

check "(today) second session adds to the first" \
  '[ "$(today s2 0.25)" = "today \$1.75" ]'

check "(today) tracker holds both sessions" \
  '[ "$(jq -r ".sessions|length" "$TRACKER_TMP")" = 2 ]'

# Valid JSON of the wrong shape makes jq exit with no output. That must leave
# the tracker as it was, not replace it with an empty file.
printf '{"date":"%s","sessions":{"a":"oops"}}' "$(date +%F)" > "$TRACKER_TMP"
check "(today) jq failure shows 0 rather than a guess" \
  '[ "$(today s1 1.50)" = "today \$0.00" ]'
check "(today) jq failure leaves the tracker untouched" \
  '[ "$(jq -r ".sessions.a" "$TRACKER_TMP")" = oops ]'

# Everything below sends no .effort.level, which is every Claude Code older than
# the field — the settings.json inference is what is left, and its two levels
# keep their order: choosing an effort while a model is selected writes it under
# that model and leaves the top-level value stale, so the per-model one wins.
check "(effort) per-model beats top-level" \
  '[ "$(effort claude-opus-5)" = "Opus 5 (low)" ]'
# The runtime may report a deployment suffix settings.json does not key on.
check "(effort) deployment suffix stripped" \
  '[ "$(effort "claude-opus-5[1m]")" = "Opus 5 (low)" ]'
# A model with no entry of its own still gets the top-level value.
check "(effort) unlisted model falls back" \
  '[ "$(effort claude-sonnet-5)" = "Opus 5 (medium)" ]'
# ...as does a payload with no id at all, which is what every older one is.
check "(effort) missing id falls back" \
  '[ "$(effort "")" = "Opus 5 (medium)" ]'
# Settings that answer for no effort at all get no guess. A per-model default
# standing in for the real value is exactly what hid a stale one behind a
# plausible (M), so the badge says it does not know — and says it in red.
check "(effort) no setting reads unknown" \
  '[ "$(effort claude-opus-5 "{}")" = "Opus 5 (unknown)" ]'
check "(effort) unknown is painted red" \
  '[ -n "$(effort_raw claude-opus-5 "{}" | grep -F "$(printf "\033[31m\033[1m(unknown)")")" ]'
# A level outside the four prints as itself rather than vanishing into a blank
# badge — `auto` is a real value the settings can hold.
check "(effort) unrecognised level prints itself" \
  '[ "$(effort claude-opus-5 "{\"effortLevel\":\"auto\"}")" = "Opus 5 (auto)" ]'

echo
echo "Result: $pass passed, $fail failed."
[ "$fail" -eq 0 ]

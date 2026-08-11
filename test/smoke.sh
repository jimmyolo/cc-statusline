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

# Inherited from the developer's own shell, these rewrite the window label and
# would make every other assertion depend on their environment. Claude Code
# exports both when the user sets them in settings.json, so a developer running
# this suite from inside a session hits it without touching a shell at all.
unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW

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
check "contains 1M context label"      'grep -q "1M" <<< "$plain"'
check "version hidden (AJ-25)"         '! grep -q "v1.2.3" <<< "$plain"'
check "contains session cost"          'grep -q "\$1.23" <<< "$plain"'
check "contains today cost label"      'grep -qF "(today \$" <<< "$plain"'
check "contains 5h rate limit"         'grep -q "5h 23%" <<< "$plain"'
check "contains 7d rate limit"         'grep -q "7d 57%" <<< "$plain"'
check "contains in/out tokens"         'grep -q "in: 123.4K" <<< "$plain" && grep -q "out: 7.8K" <<< "$plain"'
check "contains api wait line"         'grep -q "api wait" <<< "$plain"'
check "contains cache hit %"           'grep -q "cache 97%" <<< "$plain"'
check "contains vim NORMAL marker"     'grep -q "NOR" <<< "$plain"'

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
trap 'rm -f "$TRANSCRIPT_TMP"; rm -rf "$REPO_TMP"' EXIT
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

label() {  # $1 = revision to check out; echoes the (…) group from L1
  git -C "$REPO_TMP" checkout -q "$1"
  ( cd "$REPO_TMP" && bash "$SCRIPT" < "$SAMPLE" 2>/dev/null ) \
    | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g' \
    | head -1 | grep -oE '\([^)]*\)' | tail -1
}

check "(git) detached at origin ref → ref name" '[ "$(label main~0)" = "(origin/main)" ]'
check "(git) detached, no origin ref → literal" '[ "$(label decoy~0)" = "(detached)" ]'
check "(git) on a branch → branch name"         '[ "$(label main)" = "(main)" ]'

# ── Fourth pass: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE ───────────────────────────
# The bar divides by the override'd budget, so a wrong parse is invisible in the
# label but silently wrong in the %; both are asserted.
echo
echo "Running auto-compact percentage override cases…"
win() {  # $1 = env value, or UNSET; echoes L1's window label + L2's bar %
  local out
  if [ "$1" = UNSET ]; then out=$(bash "$SCRIPT" < "$SAMPLE" 2>/dev/null)
  else out=$(CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="$1" bash "$SCRIPT" < "$SAMPLE" 2>/dev/null)
  fi
  printf '%s' "$out" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g' \
    | sed -nE '1s/.*\(M\) ([^|]*) \|.*/\1/p; 2s/.*[● ] ([0-9]+%).*/ \1/p' | tr -d '\n'
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
# The reserve is a fixed token count, so which arm of the CLI's min() binds
# depends on the window. Both arms are exercised here.
check "(pct) 99 on 1M → reserve arm wins"  '[ "$(win 99)" = "987K (1M·99%) 5%" ]'
check "(pct) 98 on 1M → pct arm wins"      '[ "$(win 98)" = "980K (1M·98%) 5%" ]'
check "(pct) applies to the ACW window"    '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000; win 50)" = "100K (200K·50%) 51%" ]'
check "(pct) reserve applies to ACW too"   '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000; win UNSET)" = "187K 27%" ]'
check "(pct) 95 on 200K → reserve arm"     '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000; win 95)" = "187K (200K·95%) 27%" ]'
# A window at or below the reserve has nothing left to divide by; the full
# window stands in rather than a zero or negative budget.
check "(pct) window at the reserve"        '[ "$(export CLAUDE_CODE_AUTO_COMPACT_WINDOW=13000; win UNSET)" = "13K 100%" ]'

echo
echo "Result: $pass passed, $fail failed."
[ "$fail" -eq 0 ]

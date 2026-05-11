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
check "contains version"               'grep -q "v1.2.3" <<< "$plain"'
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
cat > "$TRANSCRIPT_TMP" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"subagent_type":"reviewer-opus-high"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"/tmp/x"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_todo","name":"TodoWrite","input":{"todos":[{"content":"first","status":"completed"},{"content":"second","status":"in_progress"}]}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_todo","content":"ok"}]}}
JSONL
out2=$(jq --arg t "$TRANSCRIPT_TMP" '.transcript_path=$t' "$SAMPLE" | bash "$SCRIPT" 2>/dev/null)
plain2=$(printf '%s' "$out2" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\]8;;[^\x07]*\x07//g')

echo "Output (plain, with transcript):"
echo "$plain2" | sed 's/^/  | /'
echo

check "(active) contains agents indicator"  'grep -q "agents 1 reviewer-opus-high" <<< "$plain2"'
check "(active) contains tools indicator"   'grep -q "tools Read" <<< "$plain2"'
check "(active) contains todos progress"    'grep -q "todos 1/2" <<< "$plain2"'
check "(active) contains current todo"      'grep -q "second" <<< "$plain2"'

echo
echo "Result: $pass passed, $fail failed."
[ "$fail" -eq 0 ]

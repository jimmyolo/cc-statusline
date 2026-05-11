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

echo
echo "Result: $pass passed, $fail failed."
[ "$fail" -eq 0 ]

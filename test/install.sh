#!/bin/bash
# Test for scripts/install.sh — the installer /cc-statusline:setup runs.
#
# The installer edits the user's real settings.json, so what matters is what it
# must NOT do: drop keys it does not own, or point statusLine at a path that
# disappears on the next plugin update. Each case runs in a throwaway config dir.
#
# Exits 0 on pass, 1 on fail.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"

FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: $2, want: $3)"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run() { # run <case-dir> <args...>
  local dir="$1"; shift
  CLAUDE_CONFIG_DIR="$dir/config" bash "$INSTALL" "$dir/data" "$@" >"$dir/out" 2>&1
}

# A refusal must happen before anything is written: no data dir, no stray temp
# file beside settings.json, and the installer's own message rather than a jq one.
refused() { # refused <case-dir> <exit> <message> <settings-before>
  check "exits non-zero" "$([ "$2" -ne 0 ] && echo nonzero)" nonzero
  check "settings.json left untouched" "$(cat "$1/config/settings.json")" "$4"
  check "no data dir created" "$([ -e "$1/data" ] && echo exists || echo absent)" absent
  check "nothing else left in the config dir" "$(ls -A "$1/config")" settings.json
  check "says why" "$(grep -c -F "$3" "$1/out")" 1
}

echo "install: no settings.json yet"
C="$TMP/fresh"; mkdir -p "$C/config"
run "$C"; check "exit 0" "$?" 0
check "script copied into the data dir" "$(cmp -s "$ROOT/cc-statusline.sh" "$C/data/cc-statusline.sh" && echo same)" same
check "statusLine.type" "$(jq -r .statusLine.type "$C/config/settings.json")" command
check "statusLine.command points at the data-dir copy" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "bash '$C/data/cc-statusline.sh'"
check "no temp file left beside settings.json" "$(ls -A "$C/config")" settings.json

echo "install: an empty settings.json is treated as {}"
C="$TMP/empty"; mkdir -p "$C/config"
: >"$C/config/settings.json"
run "$C"; check "exit 0" "$?" 0
check "statusLine written" "$(jq -r .statusLine.command "$C/config/settings.json")" "bash '$C/data/cc-statusline.sh'"
C="$TMP/blank"; mkdir -p "$C/config"
printf ' \n\t\n' >"$C/config/settings.json"
run "$C"; check "whitespace-only: exit 0" "$?" 0
check "whitespace-only: statusLine written" "$(jq -r .statusLine.type "$C/config/settings.json")" command

echo "install: a data dir with shell metacharacters reaches the shell as one literal path"
C="$TMP/meta"; mkdir -p "$C/config"
D="$C/da ta \$(touch pwned) it's"
CLAUDE_CONFIG_DIR="$C/config" bash "$INSTALL" "$D" >"$C/out" 2>&1; check "exit 0" "$?" 0
printf 'echo copied-script-ran\n' >"$D/cc-statusline.sh"
CMD="$(jq -r .statusLine.command "$C/config/settings.json")"
check "the command runs the copied script" "$(cd "$C" && sh -c "$CMD" </dev/null 2>&1)" copied-script-ran
check "nothing in the path was executed" "$([ -e "$C/pwned" ] && echo ran || echo absent)" absent

echo "install: existing settings are merged, not replaced"
C="$TMP/merge"; mkdir -p "$C/config"
cat >"$C/config/settings.json" <<'JSON'
{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]},
 "statusLine": {"type": "command", "command": "old", "padding": 2}}
JSON
run "$C"; check "exit 0" "$?" 0
check "unrelated top-level key kept" "$(jq -r .model "$C/config/settings.json")" opus
check "nested key kept" "$(jq -r '.permissions.allow[0]' "$C/config/settings.json")" 'Bash(ls:*)'
check "statusLine.padding kept" "$(jq -r .statusLine.padding "$C/config/settings.json")" 2
check "statusLine.command replaced" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "bash '$C/data/cc-statusline.sh'"

echo "install: settings.json is replaced by rename, never truncated in place"
C="$TMP/atomic"; mkdir -p "$C/config"
echo '{"model": "opus"}' >"$C/config/settings.json"
INODE="$(ls -i "$C/config/settings.json" | awk '{print $1}')"
run "$C"; check "exit 0" "$?" 0
check "settings.json is a new file" "$([ "$(ls -i "$C/config/settings.json" | awk '{print $1}')" != "$INODE" ] && echo renamed)" renamed

echo "install: a symlinked settings.json stays a symlink"
C="$TMP/symlink"; mkdir -p "$C/config" "$C/dotfiles"
echo '{"model": "opus"}' >"$C/dotfiles/settings.json"
ln -s "$C/dotfiles/settings.json" "$C/config/settings.json"
run "$C"; check "exit 0" "$?" 0
check "still a symlink" "$([ -L "$C/config/settings.json" ] && echo link)" link
check "target got the statusLine" "$(jq -r .statusLine.type "$C/dotfiles/settings.json")" command
check "no temp file left beside the target" "$(ls -A "$C/dotfiles")" settings.json

echo "install: pwsh mode"
C="$TMP/pwsh"; mkdir -p "$C/config"
run "$C" pwsh; check "exit 0" "$?" 0
check "ps1 copied into the data dir" "$(cmp -s "$ROOT/cc-statusline.ps1" "$C/data/cc-statusline.ps1" && echo same)" same
check "statusLine.command runs pwsh without a profile" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "pwsh -NoProfile -File '$C/data/cc-statusline.ps1'"

echo "install: rejects what it cannot do safely"
C="$TMP/badmode"; mkdir -p "$C/config"
run "$C" zsh; check "unknown mode exits non-zero" "$([ $? -ne 0 ] && echo nonzero)" nonzero
check "unknown mode leaves no settings.json" "$([ -e "$C/config/settings.json" ] && echo exists || echo absent)" absent
check "unknown mode creates no data dir" "$([ -e "$C/data" ] && echo exists || echo absent)" absent
check "unknown mode says why" "$(grep -c -F "unknown mode 'zsh'" "$C/out")" 1

echo "install: malformed settings.json"
C="$TMP/badjson"; mkdir -p "$C/config"
printf '{not json' >"$C/config/settings.json"
run "$C"; refused "$C" "$?" "is not valid JSON; left untouched" '{not json'

echo "install: settings.json holding two JSON documents"
C="$TMP/twodocs"; mkdir -p "$C/config"
printf '{"a":1} {"b":2}' >"$C/config/settings.json"
run "$C"; refused "$C" "$?" "does not hold a single JSON object; left untouched" '{"a":1} {"b":2}'

for doc in '[1]' 'false' 'null' '"x"'; do
  echo "install: settings.json whose top level is $doc, not an object"
  C="$TMP/notobject-$doc"; mkdir -p "$C/config"
  printf '%s' "$doc" >"$C/config/settings.json"
  run "$C"; refused "$C" "$?" "does not hold a single JSON object; left untouched" "$doc"
done

echo "install: settings.json whose statusLine is not an object"
C="$TMP/badstatusline"; mkdir -p "$C/config"
printf '{"statusLine": "bash x"}' >"$C/config/settings.json"
run "$C"; refused "$C" "$?" "statusLine is not an object; left untouched" '{"statusLine": "bash x"}'

C="$TMP/nodata"; mkdir -p "$C/config"
CLAUDE_CONFIG_DIR="$C/config" bash "$INSTALL" >"$C/out" 2>&1
check "missing data-dir argument exits non-zero" "$([ $? -ne 0 ] && echo nonzero)" nonzero

[ "$FAIL" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$FAIL"

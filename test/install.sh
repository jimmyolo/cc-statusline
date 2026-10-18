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

# stub <bin-dir> <name> <stdout>: an executable that prints <stdout>.
stub() {
  mkdir -p "$1"
  printf '#!/bin/bash\necho %s\n' "$3" >"$1/$2"
  chmod +x "$1/$2"
}

# The installer's default mode reads the host's uname, so every case runs as if
# on Linux unless it puts its own uname stub ahead of this one.
stub "$TMP/default-bin" uname Linux
PATH="$TMP/default-bin:$PATH"

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

echo "install: re-running setup keeps a hand-edited data-dir copy as .bak"
C="$TMP/rerun"; mkdir -p "$C/config"
run "$C"; check "first run: exit 0" "$?" 0
check "first run: no .bak" "$([ -e "$C/data/cc-statusline.sh.bak" ] && echo exists || echo absent)" absent
printf '# my edit\n' >>"$C/data/cc-statusline.sh"
cp "$C/data/cc-statusline.sh" "$C/edited"
run "$C"; check "second run: exit 0" "$?" 0
check "the .bak holds the edited copy" "$(cmp -s "$C/edited" "$C/data/cc-statusline.sh.bak" && echo same)" same
check "the data-dir copy is the repo script again" "$(cmp -s "$ROOT/cc-statusline.sh" "$C/data/cc-statusline.sh" && echo same)" same
check "the output names the .bak path" "$(grep -c -F "$C/data/cc-statusline.sh.bak" "$C/out")" 1

echo "install: re-running setup over an unmodified copy makes no .bak"
C="$TMP/rerun-clean"; mkdir -p "$C/config"
run "$C"; run "$C"; check "second run: exit 0" "$?" 0
check "no .bak" "$([ -e "$C/data/cc-statusline.sh.bak" ] && echo exists || echo absent)" absent
check "the output does not mention a .bak" "$(grep -c -F ".bak" "$C/out")" 0

echo "install: a plugin update makes no .bak unless the copy was edited"
# The installer runs from a copied plugin root so its script can change between
# runs, as it does after /plugin update.
C="$TMP/update"; mkdir -p "$C/config" "$C/plugin/scripts"
cp "$INSTALL" "$C/plugin/scripts/"; cp "$ROOT/cc-statusline.sh" "$C/plugin/"
runp() { CLAUDE_CONFIG_DIR="$C/config" bash "$C/plugin/scripts/install.sh" "$C/data" >"$C/out" 2>&1; }
runp; printf '# v2\n' >>"$C/plugin/cc-statusline.sh"
runp; check "update over an unedited copy: exit 0" "$?" 0
check "update over an unedited copy: no .bak" "$([ -e "$C/data/cc-statusline.sh.bak" ] && echo exists || echo absent)" absent
check "update over an unedited copy: the copy is the new script" "$(cmp -s "$C/plugin/cc-statusline.sh" "$C/data/cc-statusline.sh" && echo same)" same
printf '# my edit\n' >>"$C/data/cc-statusline.sh"; cp "$C/data/cc-statusline.sh" "$C/edited"
printf '# v3\n' >>"$C/plugin/cc-statusline.sh"
runp; check "update after an edit: exit 0" "$?" 0
check "update after an edit: .bak holds the edited copy" "$(cmp -s "$C/edited" "$C/data/cc-statusline.sh.bak" && echo same)" same
check "update after an edit: the copy is the new script" "$(cmp -s "$C/plugin/cc-statusline.sh" "$C/data/cc-statusline.sh" && echo same)" same
printf '# v4\n' >>"$C/plugin/cc-statusline.sh"
runp; check "second update, no new edit: exit 0" "$?" 0
check "second update, no new edit: .bak still holds the edited copy" "$(cmp -s "$C/edited" "$C/data/cc-statusline.sh.bak" && echo same)" same
check "second update, no new edit: the output does not mention a .bak" "$(grep -c -F ".bak" "$C/out")" 0
check "second update, no new edit: the copy is the new script" "$(cmp -s "$C/plugin/cc-statusline.sh" "$C/data/cc-statusline.sh" && echo same)" same

echo "install: pwsh mode"
C="$TMP/pwsh"; mkdir -p "$C/config"
run "$C" pwsh; check "exit 0" "$?" 0
check "ps1 copied into the data dir" "$(cmp -s "$ROOT/cc-statusline.ps1" "$C/data/cc-statusline.ps1" && echo same)" same
check "statusLine.command runs pwsh without a profile" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "pwsh -NoProfile -File '$C/data/cc-statusline.ps1'"

echo "install: pwsh mode prints no picked line"
check "explicit pwsh says nothing about picking" "$(grep -c -F "picked" "$C/out")" 0

# Auto mode reads the OS from uname and pwsh from PATH, so the cases about it
# stub both.
echo "install: auto mode on a non-Windows host picks the shell script, even with pwsh on PATH"
C="$TMP/auto-linux"; mkdir -p "$C/config"
stub "$C/bin" uname Linux; stub "$C/bin" pwsh ""
PATH="$C/bin:$PATH" run "$C"; check "exit 0" "$?" 0
check "sh copied into the data dir" "$(cmp -s "$ROOT/cc-statusline.sh" "$C/data/cc-statusline.sh" && echo same)" same
check "ps1 not copied" "$([ -e "$C/data/cc-statusline.ps1" ] && echo exists || echo absent)" absent
check "statusLine.command runs bash" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "bash '$C/data/cc-statusline.sh'"
check "says what it picked" "$(grep -c -x -F "picked cc-statusline.sh: not Windows" "$C/out")" 1
check "the picked line carries no error prefix" "$(grep -c -F "install.sh:" "$C/out")" 0

echo "install: auto mode on Windows with pwsh on PATH picks the PowerShell port"
C="$TMP/auto-win-pwsh"; mkdir -p "$C/config"
stub "$C/bin" uname MINGW64_NT-10.0-19045; stub "$C/bin" pwsh ""
PATH="$C/bin:$PATH" run "$C"; check "exit 0" "$?" 0
check "ps1 copied into the data dir" "$(cmp -s "$ROOT/cc-statusline.ps1" "$C/data/cc-statusline.ps1" && echo same)" same
check "sh not copied" "$([ -e "$C/data/cc-statusline.sh" ] && echo exists || echo absent)" absent
check "statusLine.command runs pwsh without a profile" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "pwsh -NoProfile -File '$C/data/cc-statusline.ps1'"
check "says what it picked" "$(grep -c -x -F "picked cc-statusline.ps1: Windows and pwsh on PATH" "$C/out")" 1
check "the picked line carries no error prefix" "$(grep -c -F "install.sh:" "$C/out")" 0

echo "install: auto mode on Windows without pwsh falls back to the shell script"
# A PATH prefix would still find a real pwsh further down, so PATH is the host's
# own with every directory that holds a pwsh dropped, plus the uname stub.
C="$TMP/auto-win-nopwsh"; mkdir -p "$C/config"
stub "$C/bin" uname MSYS_NT-10.0
NOPWSH="$C/bin"
IFS=: read -ra DIRS <<<"$PATH"
for d in "${DIRS[@]}"; do
  [ -x "$d/pwsh" ] || NOPWSH="$NOPWSH:$d"
done
PATH="$NOPWSH" run "$C"; check "exit 0" "$?" 0
check "sh copied into the data dir" "$(cmp -s "$ROOT/cc-statusline.sh" "$C/data/cc-statusline.sh" && echo same)" same
check "ps1 not copied" "$([ -e "$C/data/cc-statusline.ps1" ] && echo exists || echo absent)" absent
check "statusLine.command runs bash" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "bash '$C/data/cc-statusline.sh'"
check "says what it picked" "$(grep -c -x -F "picked cc-statusline.sh: Windows but pwsh is not on PATH" "$C/out")" 1

echo "install: auto mode with a failing uname falls back to the shell script and says why"
C="$TMP/auto-nouname"; mkdir -p "$C/config" "$C/bin"
printf '#!/bin/bash\nexit 1\n' >"$C/bin/uname"; chmod +x "$C/bin/uname"
stub "$C/bin" pwsh ""
PATH="$C/bin:$PATH" run "$C"; check "exit 0" "$?" 0
check "statusLine.command runs bash" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "bash '$C/data/cc-statusline.sh'"
check "says the OS was not detected" "$(grep -c -x -F "picked cc-statusline.sh: could not detect the OS" "$C/out")" 1

# Re-running setup keeps the script an earlier run installed, so a user who moved
# to the other script, or who customised their copy, is not switched by a re-run.
echo "install: auto mode keeps the shell script setup installed before, even on Windows with pwsh"
C="$TMP/sticky-sh"; mkdir -p "$C/config"
stub "$C/bin" uname MINGW64_NT-10.0-19045; stub "$C/bin" pwsh ""
jq -n --arg c "bash '$C/data/cc-statusline.sh'" '{statusLine: {type: "command", command: $c}}' >"$C/config/settings.json"
PATH="$C/bin:$PATH" run "$C"; check "exit 0" "$?" 0
check "sh copied into the data dir" "$(cmp -s "$ROOT/cc-statusline.sh" "$C/data/cc-statusline.sh" && echo same)" same
check "ps1 not copied" "$([ -e "$C/data/cc-statusline.ps1" ] && echo exists || echo absent)" absent
check "statusLine.command still runs bash" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "bash '$C/data/cc-statusline.sh'"
check "says it kept the script" "$(grep -c -x -F "picked cc-statusline.sh: kept the script setup installed before" "$C/out")" 1

echo "install: auto mode keeps the PowerShell port setup installed before, even off Windows"
C="$TMP/sticky-ps1"; mkdir -p "$C/config"
stub "$C/bin" uname Linux
jq -n --arg c "pwsh -NoProfile -File '$C/data/cc-statusline.ps1'" '{statusLine: {type: "command", command: $c}}' >"$C/config/settings.json"
PATH="$C/bin:$PATH" run "$C"; check "exit 0" "$?" 0
check "ps1 copied into the data dir" "$(cmp -s "$ROOT/cc-statusline.ps1" "$C/data/cc-statusline.ps1" && echo same)" same
check "sh not copied" "$([ -e "$C/data/cc-statusline.sh" ] && echo exists || echo absent)" absent
check "statusLine.command still runs pwsh" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "pwsh -NoProfile -File '$C/data/cc-statusline.ps1'"
check "says it kept the script" "$(grep -c -x -F "picked cc-statusline.ps1: kept the script setup installed before" "$C/out")" 1

echo "install: auto mode detects again when the statusLine is not what setup wrote"
C="$TMP/sticky-elsewhere"; mkdir -p "$C/config"
stub "$C/bin" uname MINGW64_NT-10.0-19045; stub "$C/bin" pwsh ""
echo '{"statusLine": {"type": "command", "command": "bash ~/other.sh"}}' >"$C/config/settings.json"
PATH="$C/bin:$PATH" run "$C"; check "exit 0" "$?" 0
check "statusLine.command runs pwsh without a profile" \
  "$(jq -r .statusLine.command "$C/config/settings.json")" "pwsh -NoProfile -File '$C/data/cc-statusline.ps1'"
check "says what it picked" "$(grep -c -x -F "picked cc-statusline.ps1: Windows and pwsh on PATH" "$C/out")" 1

echo "install: a refused auto run prints no picked line"
C="$TMP/auto-refused"; mkdir -p "$C/config"
stub "$C/bin" uname Linux
printf '{not json' >"$C/config/settings.json"
PATH="$C/bin:$PATH" run "$C"; refused "$C" "$?" "is not valid JSON; left untouched" '{not json'
check "no picked line" "$(grep -c -F "picked" "$C/out")" 0

echo "install: an auto run that fails after the checks prints no picked line"
# A directory where the script copy should be makes the install fail at the copy.
C="$TMP/auto-copyfail"; mkdir -p "$C/config" "$C/data/cc-statusline.sh"
run "$C"; check "exits non-zero" "$([ $? -ne 0 ] && echo nonzero)" nonzero
check "no picked line" "$(grep -c -F "picked" "$C/out")" 0

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

for suffix in "" .orig .bak; do
  echo "install: cc-statusline.sh$suffix in the data dir is a symlink"
  C="$TMP/datalink$suffix"; mkdir -p "$C/config" "$C/data"
  echo '{"model": "opus"}' >"$C/config/settings.json"
  echo precious >"$C/outside"
  ln -s "$C/outside" "$C/data/cc-statusline.sh$suffix"
  run "$C"; RC=$?
  check "exits non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
  check "the file the link points at is unchanged" "$(cat "$C/outside")" precious
  check "settings.json left untouched" "$(cat "$C/config/settings.json")" '{"model": "opus"}'
  check "says why" "$(grep -c -F "$C/data/cc-statusline.sh$suffix is a symlink; left untouched" "$C/out")" 1
done

echo "remove: undoes an install and keeps every other key"
C="$TMP/rm"; mkdir -p "$C/config"
cat >"$C/config/settings.json" <<'JSON'
{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]}}
JSON
run "$C"; run "$C" remove; check "exit 0" "$?" 0
check "statusLine gone" "$(jq 'has("statusLine")' "$C/config/settings.json")" false
check "unrelated top-level key kept" "$(jq -r .model "$C/config/settings.json")" opus
check "nested key kept" "$(jq -r '.permissions.allow[0]' "$C/config/settings.json")" 'Bash(ls:*)'
check "says what it removed" "$(grep -c -F "statusLine removed from $C/config/settings.json" "$C/out")" 1
check "data-dir copy left for plugin uninstall" "$([ -e "$C/data/cc-statusline.sh" ] && echo kept)" kept
check "no temp file left beside settings.json" "$(ls -A "$C/config")" settings.json

echo "remove: undoes a pwsh install"
C="$TMP/rm-pwsh"; mkdir -p "$C/config"
echo '{"model": "opus"}' >"$C/config/settings.json"
run "$C" pwsh; run "$C" remove; check "exit 0" "$?" 0
check "settings.json is back to the other keys" "$(jq -c . "$C/config/settings.json")" '{"model":"opus"}'

echo "remove: undoes an auto install that picked the PowerShell port"
C="$TMP/rm-auto-win"; mkdir -p "$C/config"
echo '{"model": "opus"}' >"$C/config/settings.json"
stub "$C/bin" uname MINGW64_NT-10.0-19045; stub "$C/bin" pwsh ""
PATH="$C/bin:$PATH" run "$C"; PATH="$C/bin:$PATH" run "$C" remove; check "exit 0" "$?" 0
check "settings.json is back to the other keys" "$(jq -c . "$C/config/settings.json")" '{"model":"opus"}'

echo "remove: refuses a statusLine that is not the command setup wrote"
C="$TMP/rm-elsewhere"; mkdir -p "$C/config"
S='{"model": "opus", "statusLine": {"type": "command", "command": "bash ~/other.sh"}}'
printf '%s' "$S" >"$C/config/settings.json"
cp "$C/config/settings.json" "$C/before"
run "$C" remove; refused "$C" "$?" "statusLine is not the command setup wrote for $C/data; left untouched" "$S"
check "settings.json byte-identical" "$(cmp -s "$C/before" "$C/config/settings.json" && echo same)" same
check "the refusal names the manual way out" "$(grep -c -F "jq 'del(.statusLine)'" "$C/out")" 1

echo "remove: the manual command in a refusal runs as printed"
# The hint is the last line of the refusal. The config dir holds a space and a
# quote, so the command only works if its path is quoted for the shell.
C="$TMP/rm-hint it's"; mkdir -p "$C/config"
printf '%s' "$S" >"$C/config/settings.json"
chmod 600 "$C/config/settings.json"
run "$C" remove
HINT="$(tail -n 1 "$C/out")"
bash -c "$HINT" </dev/null >/dev/null 2>&1; check "hint exits 0" "$?" 0
check "hint keeps settings.json private" "$(ls -l "$C/config/settings.json" | cut -c5-10)" "------"
check "hint removed the statusLine" "$(jq 'has("statusLine")' "$C/config/settings.json")" false
check "hint kept the other keys" "$(jq -r .model "$C/config/settings.json")" opus
check "hint left no temp file" "$(ls -A "$C/config")" settings.json

C="$TMP/rm-suffix"; mkdir -p "$C/config"
S="{\"statusLine\": {\"type\": \"command\", \"command\": \"bash '$C/data/cc-statusline.sh' && echo hi\"}}"
printf '%s' "$S" >"$C/config/settings.json"
run "$C" remove; refused "$C" "$?" "statusLine is not the command setup wrote for $C/data; left untouched" "$S"
C="$TMP/rm-nocommand"; mkdir -p "$C/config"
S='{"statusLine": {"type": "command"}}'
printf '%s' "$S" >"$C/config/settings.json"
run "$C" remove; refused "$C" "$?" "statusLine is not the command setup wrote for $C/data; left untouched" "$S"

echo "remove: no settings.json"
C="$TMP/rm-fresh"; mkdir -p "$C/config"
run "$C" remove; check "exit 0" "$?" 0
check "says there is nothing to remove" "$(grep -c -F "no statusLine in $C/config/settings.json; nothing to remove" "$C/out")" 1
check "the success line carries no error prefix" "$(grep -c -F "install.sh:" "$C/out")" 0
check "creates no file" "$(ls -A "$C/config")" ""
check "creates no data dir" "$([ -e "$C/data" ] && echo exists || echo absent)" absent

echo "remove: settings.json without a statusLine"
C="$TMP/rm-none"; mkdir -p "$C/config"
S='{"model":  "opus"}'
printf '%s' "$S" >"$C/config/settings.json"
INODE="$(ls -i "$C/config/settings.json" | awk '{print $1}')"
run "$C" remove; check "exit 0" "$?" 0
check "settings.json byte-identical" "$(cat "$C/config/settings.json")" "$S"
check "settings.json not rewritten" "$(ls -i "$C/config/settings.json" | awk '{print $1}')" "$INODE"
check "says there is nothing to remove" "$(grep -c -F "nothing to remove" "$C/out")" 1
check "the success line carries no error prefix" "$(grep -c -F "install.sh:" "$C/out")" 0

echo "remove: deletes the whole statusLine object, extra keys included"
C="$TMP/rm-padding"; mkdir -p "$C/config"
echo '{"model": "opus", "statusLine": {"type": "command", "command": "old", "padding": 2}}' >"$C/config/settings.json"
run "$C"; run "$C" remove; check "exit 0" "$?" 0
check "padding went with the statusLine" "$(jq -c . "$C/config/settings.json")" '{"model":"opus"}'

echo "remove: a statusLine repointed between the guard and the write is refused"
# The wrapper rewrites settings.json just before the write jq runs, standing in
# for another process editing the file in that window.
C="$TMP/rm-race"; mkdir -p "$C/config" "$C/bin"
echo '{"model": "opus"}' >"$C/config/settings.json"
run "$C"
REAL_JQ="$(command -v jq)"
cat >"$C/bin/jq" <<EOF
#!/bin/bash
case "\$*" in *'del(.statusLine)'*)
  printf '%s' '{"statusLine": {"command": "bash ~/other.sh"}}' >"$C/config/settings.json" ;;
esac
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$C/bin/jq"
PATH="$C/bin:$PATH" run "$C" remove; RC=$?
check "exits non-zero" "$([ "$RC" -ne 0 ] && echo nonzero)" nonzero
check "the repointed statusLine survives" "$(jq -r .statusLine.command "$C/config/settings.json")" "bash ~/other.sh"
check "says why" "$(grep -c -F "statusLine is not the command setup wrote for $C/data; left untouched" "$C/out")" 1
check "no temp file left beside settings.json" "$(ls -A "$C/config")" settings.json

echo "remove: malformed settings.json"
C="$TMP/rm-badjson"; mkdir -p "$C/config"
printf '{not json' >"$C/config/settings.json"
run "$C" remove; refused "$C" "$?" "is not valid JSON; left untouched" '{not json'

echo "remove: settings.json whose statusLine is not an object"
C="$TMP/rm-badstatusline"; mkdir -p "$C/config"
printf '{"statusLine": "bash x"}' >"$C/config/settings.json"
run "$C" remove; refused "$C" "$?" "statusLine is not an object; left untouched" '{"statusLine": "bash x"}'

echo "remove: a symlinked settings.json stays a symlink"
C="$TMP/rm-symlink"; mkdir -p "$C/config" "$C/dotfiles"
echo '{"model": "opus"}' >"$C/dotfiles/settings.json"
ln -s "$C/dotfiles/settings.json" "$C/config/settings.json"
run "$C"; run "$C" remove; check "exit 0" "$?" 0
check "still a symlink" "$([ -L "$C/config/settings.json" ] && echo link)" link
check "target lost the statusLine" "$(jq 'has("statusLine")' "$C/dotfiles/settings.json")" false
check "target kept its other keys" "$(jq -r .model "$C/dotfiles/settings.json")" opus
check "no temp file left beside the target" "$(ls -A "$C/dotfiles")" settings.json

echo "remove: a data dir with shell metacharacters round-trips"
C="$TMP/rm-meta"; mkdir -p "$C/config"
D="$C/da ta \$(touch pwned) it's"
echo '{"model": "opus"}' >"$C/config/settings.json"
CLAUDE_CONFIG_DIR="$C/config" bash "$INSTALL" "$D" >"$C/out" 2>&1; check "install exit 0" "$?" 0
CLAUDE_CONFIG_DIR="$C/config" bash "$INSTALL" "$D" remove >"$C/out" 2>&1; check "remove exit 0" "$?" 0
check "statusLine gone" "$(jq -c . "$C/config/settings.json")" '{"model":"opus"}'
check "nothing in the path was executed" "$([ -e "$C/pwned" ] && echo ran || echo absent)" absent

C="$TMP/nodata"; mkdir -p "$C/config"
CLAUDE_CONFIG_DIR="$C/config" bash "$INSTALL" >"$C/out" 2>&1
check "missing data-dir argument exits non-zero" "$([ $? -ne 0 ] && echo nonzero)" nonzero

[ "$FAIL" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$FAIL"

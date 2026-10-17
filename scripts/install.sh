#!/bin/bash
# Installs cc-statusline as the Claude Code status line. Run by /cc-statusline:setup.
#
# Usage: install.sh <data-dir> [bash|pwsh]
#
# A plugin cannot set statusLine itself, and its own directory is versioned per
# commit, so the script is copied into <data-dir> (the plugin's data directory,
# kept across updates) and settings.json is pointed at that copy. Only
# statusLine.type and statusLine.command are written; every other key survives.

set -euo pipefail

DATA_DIR="${1:?usage: install.sh <data-dir> [bash|pwsh]}"
MODE="${2:-bash}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

case "$MODE" in
  bash) SCRIPT="cc-statusline.sh" ;;
  pwsh) SCRIPT="cc-statusline.ps1" ;;
  *) echo "install.sh: unknown mode '$MODE' (expected bash or pwsh)" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "install.sh: jq is required" >&2; exit 1; }

# A settings.json symlinked from a dotfiles repo is rewritten at its target, so
# the link itself survives.
TARGET="$SETTINGS"
[ -L "$SETTINGS" ] && TARGET="$(readlink -f "$SETTINGS")"

# Every refusal comes before the first write. An empty file reads as {}.
SRC="$TARGET"
[ -e "$TARGET" ] || SRC=/dev/null
if ! jq empty "$SRC" 2>/dev/null; then
  echo "install.sh: $SETTINGS is not valid JSON; left untouched" >&2
  exit 1
fi
if ! jq -s -e 'length == 0 or (length == 1 and (.[0] | type == "object"))' "$SRC" >/dev/null; then
  echo "install.sh: $SETTINGS does not hold a single JSON object; left untouched" >&2
  exit 1
fi
if ! jq -s -e '.[0].statusLine | . == null or type == "object"' "$SRC" >/dev/null; then
  echo "install.sh: $SETTINGS statusLine is not an object; left untouched" >&2
  exit 1
fi
for f in "$DATA_DIR/$SCRIPT" "$DATA_DIR/$SCRIPT.orig" "$DATA_DIR/$SCRIPT.bak"; do
  if [ -L "$f" ]; then
    echo "install.sh: $f is a symlink; left untouched" >&2
    exit 1
  fi
done

mkdir -p "$DATA_DIR" "$(dirname "$TARGET")"
# The data-dir copy is the live script, and users may customise it. <script>.orig
# is what the last setup installed; a copy that differs from it was edited by hand
# and is set aside rather than overwritten. (Comparing against the plugin's current
# script would flag every unedited copy after a plugin update.)
if [ -e "$DATA_DIR/$SCRIPT" ] && ! cmp -s "$DATA_DIR/$SCRIPT.orig" "$DATA_DIR/$SCRIPT"; then
  cp "$DATA_DIR/$SCRIPT" "$DATA_DIR/$SCRIPT.bak"
  echo "$SCRIPT was edited since setup installed it; saved as $DATA_DIR/$SCRIPT.bak"
fi
cp "$ROOT/$SCRIPT" "$DATA_DIR/$SCRIPT"
cp "$ROOT/$SCRIPT" "$DATA_DIR/$SCRIPT.orig"

# The command is re-parsed by a shell on every render, so the path goes in
# POSIX single quotes, each ' inside it written as '\''.
Q="'"
SCRIPT_PATH="'${DATA_DIR//$Q/$Q\\$Q$Q}/$SCRIPT'"
case "$MODE" in
  bash) CMD="bash $SCRIPT_PATH" ;;
  pwsh) CMD="pwsh -NoProfile -File $SCRIPT_PATH" ;;
esac

# Renamed over the target from the same directory, so a reader never sees a
# half-written settings.json.
TMP=""
trap '[ -z "$TMP" ] || rm -f "$TMP"' EXIT
TMP="$(mktemp "$(dirname "$TARGET")/.settings.json.XXXXXX")"
jq -s --arg cmd "$CMD" '(.[0] // {}) | .statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})' "$SRC" >"$TMP"
mv -f "$TMP" "$TARGET"

echo "statusLine.command = $CMD"
echo "written to $SETTINGS"

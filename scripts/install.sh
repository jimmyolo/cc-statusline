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

if [ -e "$SETTINGS" ] && ! jq empty "$SETTINGS" 2>/dev/null; then
  echo "install.sh: $SETTINGS is not valid JSON; left untouched" >&2
  exit 1
fi

mkdir -p "$DATA_DIR" "$(dirname "$SETTINGS")"
cp "$ROOT/$SCRIPT" "$DATA_DIR/$SCRIPT"

case "$MODE" in
  bash) CMD="bash \"$DATA_DIR/$SCRIPT\"" ;;
  pwsh) CMD="pwsh -NoProfile -File \"$DATA_DIR/$SCRIPT\"" ;;
esac

TMP="$SETTINGS.tmp.$$"
{ [ -e "$SETTINGS" ] && cat "$SETTINGS" || echo '{}'; } \
  | jq --arg cmd "$CMD" '.statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})' >"$TMP"
# Written back through cat rather than mv, so a settings.json symlinked from a
# dotfiles repo stays a symlink.
cat "$TMP" >"$SETTINGS"
rm -f "$TMP"

echo "statusLine.command = $CMD"
echo "written to $SETTINGS"

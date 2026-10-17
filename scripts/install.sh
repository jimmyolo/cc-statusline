#!/bin/bash
# Installs cc-statusline as the Claude Code status line. Run by /cc-statusline:setup.
#
# Usage: install.sh <data-dir> [bash|pwsh|remove]
#
# A plugin cannot set statusLine itself, and its own directory is versioned per
# commit, so the script is copied into <data-dir> (the plugin's data directory,
# kept across updates) and settings.json is pointed at that copy. Only
# statusLine.type and statusLine.command are written; every other key survives.
#
# "remove" undoes that: it deletes statusLine, but only while it still points at
# this data dir's copy. The data-dir files stay; uninstalling the plugin deletes them.

set -euo pipefail

DATA_DIR="${1:?usage: install.sh <data-dir> [bash|pwsh|remove]}"
MODE="${2:-bash}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

case "$MODE" in
  bash) SCRIPT="cc-statusline.sh" ;;
  pwsh) SCRIPT="cc-statusline.ps1" ;;
  remove) ;;
  *) echo "install.sh: unknown mode '$MODE' (expected bash, pwsh or remove)" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "install.sh: jq is required" >&2; exit 1; }

# The command is re-parsed by a shell on every render, so the path goes in
# POSIX single quotes, each ' inside it written as '\''. Install writes these
# strings and remove matches against them, so both build them here.
Q="'"
shq() { printf "'%s'" "${1//$Q/$Q\\$Q$Q}"; }
cmd_for() { # cmd_for <cc-statusline.sh|cc-statusline.ps1>
  local path
  path="$(shq "$DATA_DIR/$1")"
  case "$1" in
    *.sh) echo "bash $path" ;;
    *.ps1) echo "pwsh -NoProfile -File $path" ;;
  esac
}

# A settings.json symlinked from a dotfiles repo is rewritten at its target, so
# the link itself survives.
TARGET="$SETTINGS"
[ -L "$SETTINGS" ] && TARGET="$(readlink -f "$SETTINGS")"

# These input checks refuse before any write (remove's ownership check is made
# later, inside the write itself). An empty file reads as {}.
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

# Renamed over the target from the same directory, so a reader never sees a
# half-written settings.json. A failed jq leaves the target as it was, and its
# stderr is kept in WRITE_ERR for the caller.
TMP=""
WRITE_ERR=""
trap '[ -z "$TMP" ] || rm -f "$TMP"' EXIT
write_settings() { # write_settings <jq-filter> [jq args...]
  local filter="$1"; shift
  TMP="$(mktemp "$(dirname "$TARGET")/.settings.json.XXXXXX")"
  WRITE_ERR="$(jq -s "$@" "$filter" "$SRC" 2>&1 >"$TMP")" || return 1
  mv -f "$TMP" "$TARGET"
}

if [ "$MODE" = remove ]; then
  if ! jq -s -e '.[0].statusLine != null' "$SRC" >/dev/null; then
    echo "no statusLine in $SETTINGS; nothing to remove"
    exit 0
  fi
  # A statusLine the user pointed elsewhere is theirs, not setup's to delete.
  # The ownership test sits in the write's own filter, so the ownership check
  # and the content written come from the same read: the statusLine deleted is
  # the one checked. A write landing between that read and the rename is still
  # overwritten, as on install.
  if ! write_settings 'if .[0].statusLine.command == $sh or .[0].statusLine.command == $ps
    then .[0] | del(.statusLine) else error("not-setup-statusline") end' \
    --arg sh "$(cmd_for cc-statusline.sh)" --arg ps "$(cmd_for cc-statusline.ps1)"; then
    case "$WRITE_ERR" in
      *not-setup-statusline*)
        echo "install.sh: $SETTINGS statusLine is not the command setup wrote for $DATA_DIR; left untouched" >&2
        echo "  Setup did not write it, or it was edited by hand. To remove it anyway, run:" >&2
        echo "  t=\$(mktemp $(shq "$(dirname "$TARGET")/.settings.json.XXXXXX")) && jq 'del(.statusLine)' $(shq "$TARGET") > \"\$t\" && mv \"\$t\" $(shq "$TARGET")" >&2 ;;
      *) echo "install.sh: could not rewrite $SETTINGS; left untouched: $WRITE_ERR" >&2 ;;
    esac
    exit 1
  fi
  echo "statusLine removed from $SETTINGS"
else
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
  CMD="$(cmd_for "$SCRIPT")"
  write_settings '(.[0] // {}) | .statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})' \
    --arg cmd "$CMD" \
    || { echo "install.sh: could not rewrite $SETTINGS; left untouched: $WRITE_ERR" >&2; exit 1; }
  echo "statusLine.command = $CMD"
  echo "written to $SETTINGS"
fi

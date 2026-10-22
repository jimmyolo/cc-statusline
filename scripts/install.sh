#!/bin/bash
# Installs cc-statusline as the Claude Code status line. Run by /cc-statusline:setup.
#
# Usage: install.sh <data-dir> [auto|bash|pwsh|remove | editor <user|project> <vscode <host>|remove>]
#
# A plugin cannot set statusLine itself, and its own directory is versioned per
# commit, so the script is copied into <data-dir> (the plugin's data directory,
# kept across updates) and settings.json is pointed at that copy. Only
# statusLine.type and statusLine.command are written; every other key survives.
#
# "auto" (the default) installs the shell script, and the PowerShell port only on
# Windows with pwsh on PATH. An auto re-run keeps the script last installed, but
# only while statusLine still holds the exact command setup wrote for this data dir.
# "bash" and "pwsh" force one script.
#
# "remove" undoes that: it deletes statusLine, but only while it still points at
# this data dir's copy. The data-dir files stay; uninstalling the plugin deletes them.
#
# "editor <user|project> vscode <host>" sets env.CC_STATUSLINE_DIR_URL so a
# worktree's branch link opens in VS Code over Remote-SSH, and
# "editor <user|project> remove" deletes it. Run by /cc-statusline:setup-remote-editor.

set -euo pipefail

USAGE="usage: install.sh <data-dir> [auto|bash|pwsh|remove | editor <user|project> <vscode <host>|remove>]"
DATA_DIR="${1:?$USAGE}"
MODE="${2:-auto}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Project scope is the file Claude Code reads as project-local settings: at the
# main checkout's root inside a git repository, from any of its worktrees. It
# stays in the current directory outside one, on Windows, and when that root is
# $HOME, not owned by the user, or a bare repository with no checkout of its own.
if [ "$MODE" = editor ]; then
  SCOPE="${3:-}" ACTION="${4:-}" HOST="${5:-}"
  case "$SCOPE" in
    user) ;;
    project)
      PROJECT="$(pwd)"
      case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) WT_LIST="$(git worktree list --porcelain 2>/dev/null)" || WT_LIST=""
           MAIN="$(printf '%s\n' "$WT_LIST" | sed -n '1s/^worktree //p')"
           if [ -n "$MAIN" ] && [ "$(printf '%s\n' "$WT_LIST" | sed -n 2p)" != bare ] && [ -O "$MAIN" ] \
              && [ "$(cd -P "$MAIN" && pwd)" != "$(cd -P "$HOME" 2>/dev/null && pwd)" ]; then
             PROJECT="$MAIN"
           fi ;;
      esac
      SETTINGS="$PROJECT/.claude/settings.local.json" ;;
    *) echo "install.sh: unknown scope '$SCOPE' (expected user or project)" >&2; exit 2 ;;
  esac
fi

PICKED=""

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

# Auto keeps the script a statusLine written by an earlier setup run already
# points at, so a re-run never switches a user between the two scripts. Only a
# first install, or a statusLine setup did not write, is detected from the host.
pick_auto() {
  local current os s
  current="$(jq -s -r '.[0].statusLine.command // empty' "$SRC")"
  for s in cc-statusline.sh cc-statusline.ps1; do
    if [ "$current" = "$(cmd_for "$s")" ]; then
      SCRIPT="$s"; PICKED="kept the script setup installed before (run setup remove, then setup, to detect again)"
      return
    fi
  done
  os="$(uname -s 2>/dev/null)" || os=""
  case "$os" in
    "") SCRIPT="cc-statusline.sh"; PICKED="could not detect the OS" ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v pwsh >/dev/null; then
        SCRIPT="cc-statusline.ps1"; PICKED="Windows and pwsh on PATH"
      else
        SCRIPT="cc-statusline.sh"; PICKED="Windows but pwsh is not on PATH"
      fi ;;
    *) SCRIPT="cc-statusline.sh"; PICKED="not Windows" ;;
  esac
}

case "$MODE" in
  auto) pick_auto ;;
  bash) SCRIPT="cc-statusline.sh" ;;
  pwsh) SCRIPT="cc-statusline.ps1" ;;
  remove|editor) ;;
  *) echo "install.sh: unknown mode '$MODE' (expected auto, bash, pwsh, remove or editor)" >&2; exit 2 ;;
esac

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

if [ "$MODE" = editor ]; then
  if ! jq -s -e '.[0].env | . == null or type == "object"' "$SRC" >/dev/null; then
    echo "install.sh: $SETTINGS env is not an object; left untouched" >&2
    exit 1
  fi
  case "$ACTION" in
    vscode)
      # The host arrives as a slash-command argument and lands in a URL a click
      # opens, so only what an SSH host alias, IP or user@host is made of passes.
      if ! [[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]]; then
        echo "install.sh: '$HOST' is not a valid SSH host; left untouched" >&2
        exit 2
      fi
      URL="vscode://vscode-remote/ssh-remote+$HOST{path}?windowId=_blank"
      mkdir -p "$(dirname "$TARGET")"
      write_settings '(.[0] // {}) | .env = ((.env // {}) + {CC_STATUSLINE_DIR_URL: $url})' --arg url "$URL" \
        || { echo "install.sh: could not rewrite $SETTINGS; left untouched: $WRITE_ERR" >&2; exit 1; }
      echo "CC_STATUSLINE_DIR_URL = $URL"
      echo "written to $SETTINGS"
      # A hand-made local file is not covered by the excludes Claude Code adds
      # when it creates one, and this one names a host. Exit 1 is "not ignored";
      # anything else (no work tree, a path outside it) says nothing either way.
      if [ "$SCOPE" = project ] && git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
        RC=0; git -C "$PROJECT" check-ignore -q "$SETTINGS" 2>/dev/null || RC=$?
        [ "$RC" -ne 1 ] || echo "warning: $SETTINGS is not ignored by git; add .claude/settings.local.json to .gitignore"
      fi ;;
    remove)
      if ! jq -s -e '.[0].env.CC_STATUSLINE_DIR_URL != null' "$SRC" >/dev/null; then
        echo "no CC_STATUSLINE_DIR_URL in $SETTINGS; nothing to remove"
        exit 0
      fi
      write_settings '.[0] | del(.env.CC_STATUSLINE_DIR_URL) | if .env == {} then del(.env) else . end' \
        || { echo "install.sh: could not rewrite $SETTINGS; left untouched: $WRITE_ERR" >&2; exit 1; }
      echo "CC_STATUSLINE_DIR_URL removed from $SETTINGS" ;;
    *) echo "install.sh: unknown editor '$ACTION' (expected vscode or remove)" >&2; exit 2 ;;
  esac
  exit 0
fi

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
  [ -z "$PICKED" ] || echo "picked $SCRIPT: $PICKED"
  echo "statusLine.command = $CMD"
  echo "written to $SETTINGS"
fi

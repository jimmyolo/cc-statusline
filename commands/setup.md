---
description: Install cc-statusline as the Claude Code status line (writes statusLine into settings.json), or remove it again
argument-hint: "[remove]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}")
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" remove)
---

# cc-statusline setup

Point the status line at cc-statusline, or take it off again. The argument the
user passed picks what to do:

- none — install the status line; the installer picks `cc-statusline.sh` (needs
  `bash` 4+ and `jq`) and switches to `cc-statusline.ps1` (PowerShell 7+) only on
  Windows with `pwsh` on PATH
- `remove` — delete the `statusLine` that setup wrote, before uninstalling the plugin

Any other value: run nothing, and tell the user the accepted values (none, or `remove`).

## Run

Run exactly one of these, as one Bash call, copied character for character.
Never put the user's argument into the command.

For none:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}"
```

For `remove`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" remove
```

The installer copies the script into the plugin's data directory, which survives
plugin updates, and merges `statusLine` into
`settings.json` in `$CLAUDE_CONFIG_DIR` (default `~/.claude`). Only `statusLine.type` and
`statusLine.command` are written; every other setting is kept. It refuses a
`settings.json` that is not a single JSON object and leaves it untouched.

`remove` deletes the entire `statusLine` object from the same file, including
any keys the user added to it, such as `padding`. It does so only while the
command is still exactly what setup wrote; a `statusLine` the user pointed
elsewhere is left alone. The refusal prints a runnable command for the user to
remove it by hand (`jq 'del(.statusLine)'` on that `settings.json`, written to
a private `mktemp` file beside it and moved back over it); the user can also
just delete the `statusLine` key from that file. It deletes no files, since
uninstalling the plugin removes the data directory.

## Report

- On success, relay the `picked …` line it printed, so a Windows user who got
  `cc-statusline.sh` because `pwsh` is missing sees why, and the
  `statusLine.command` line. The status line picks it up on the next render; no
  restart is needed.
- If the installer printed a `saved as …bak` line, relay it verbatim: the user
  had edited the installed copy, and this is where that edit went.
- On `remove`, relay the line it printed (`statusLine removed from …`, or
  `no statusLine in …; nothing to remove`) and say the user can now run
  `/plugin uninstall cc-statusline`.
- On failure, relay the error verbatim. If `jq` is missing, say so and stop —
  do not edit `settings.json` by hand.
- Remind the user to run `/cc-statusline:setup` again after
  `/plugin update cc-statusline`: the status line runs the copy, so it stays on
  the old version until setup copies the new one. Skip this reminder after
  `remove`.

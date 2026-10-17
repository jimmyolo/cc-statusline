---
description: Install cc-statusline as the Claude Code status line (writes statusLine into settings.json)
argument-hint: "[bash|pwsh]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}")
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" pwsh)
---

# cc-statusline setup

Point the status line at cc-statusline. The argument the user passed picks the
implementation:

- none or `bash` — `cc-statusline.sh` (Linux / macOS; needs `bash` 4+ and `jq`)
- `pwsh` — `cc-statusline.ps1` (PowerShell 7+, for Windows)

Any other value: run nothing, and tell the user the two accepted values.

## Run

Run exactly one of these, as one Bash call, copied character for character.
Never put the user's argument into the command.

For none or `bash`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}"
```

For `pwsh`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" pwsh
```

The installer copies the script into the plugin's data directory, which survives
plugin updates, and merges `statusLine` into
`settings.json` in `$CLAUDE_CONFIG_DIR` (default `~/.claude`). Only `statusLine.type` and
`statusLine.command` are written; every other setting is kept. It refuses a
`settings.json` that is not a single JSON object and leaves it untouched.

## Report

- On success, relay the `statusLine.command` line it printed. The status line
  picks it up on the next render; no restart is needed.
- If the installer printed a `saved as …bak` line, relay it verbatim: the user
  had edited the installed copy, and this is where that edit went.
- On failure, relay the error verbatim. If `jq` is missing, say so and stop —
  do not edit `settings.json` by hand.
- Remind the user to run `/cc-statusline:setup` again after
  `/plugin update cc-statusline`: the status line runs the copy, so it stays on
  the old version until setup copies the new one.

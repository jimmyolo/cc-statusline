---
description: Make a worktree's branch link open in VS Code over Remote-SSH (writes env.CC_STATUSLINE_DIR_URL into user or project settings), or remove it again
argument-hint: "vscode <ssh-host> [user|project] | remove [user|project]"
disable-model-invocation: true
allowed-tools:
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" editor user vscode:*)
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" editor project vscode:*)
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" editor user remove)
  - Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" editor project remove)
  - AskUserQuestion
---

# cc-statusline remote editor

In a linked worktree the branch name on the status line links to the worktree
directory. By default that link is `file://`, which only a file manager on the
same machine can open. This command points it at VS Code Remote-SSH instead, so
a click on the user's own machine opens the worktree in VS Code, the way
`code <path>` would.

It writes `env.CC_STATUSLINE_DIR_URL =
vscode://vscode-remote/ssh-remote+<host>{path}?windowId=_blank`. `<host>` is the name the
user's **local** VS Code connects to this machine with: the `Host` entry in the
local `~/.ssh/config`, or the IP or `user@host` they typed into Remote-SSH.

## Arguments

- `vscode <host> [user|project]` sets the link.
- `remove [user|project]` deletes it.

Anything else: run nothing, and tell the user the accepted forms.

`<host>` must match `^[A-Za-z0-9][A-Za-z0-9._@-]*$`. If it does not, run
nothing and say why. An IPv6 literal or a `host:port` does not match: the user
needs an alias for it in their local `~/.ssh/config`. If `vscode` comes
without a host, run nothing. Tell the user to look the host up on the machine
VS Code runs on. On Windows that is:

```powershell
Select-String -Path "$HOME\.ssh\config" -Pattern '^\s*(Host|HostName)\s' | ForEach-Object { $_.Line.Trim() }
```

The `Host` above the `HostName` of this machine is the name to pass. No entry
means they connect by address, so the IP (or `user@IP`) is the host.

## Scope

If the arguments name no scope, ask with AskUserQuestion before running
anything. Offer exactly these two options:

- **User (Recommended)**: `~/.claude/settings.json`. Applies in every project
  on this machine. This is where `/cc-statusline:setup` writes `statusLine`.
- **Project**: `.claude/settings.local.json` at this repository's main checkout
  root. Applies to this repository and all of its worktrees only, and stays out
  of the shared `.claude/settings.json`. Outside git, on Windows, and for a
  repository rooted at `$HOME` or bare, the file goes in the working directory
  instead, as Claude Code reads it there.

## Run

Run exactly one command, as one Bash call. Substitute only `<scope>` (`user` or
`project`) and `<host>`. Put the host in single quotes and nothing else in the
command.

For `vscode`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" editor <scope> vscode '<host>'
```

For `remove`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install.sh" "${CLAUDE_PLUGIN_DATA}" editor <scope> remove
```

The installer checks the host again, changes only `env.CC_STATUSLINE_DIR_URL`
(dropping an `env` left empty on remove), and refuses a settings file that is
not a single JSON object or whose `env` is not an object. For project scope it
resolves the main checkout root itself, but where it falls back to the working
directory it uses the Bash tool's. If an earlier `cd` moved that away from the
session's primary working directory, first `cd` back to it in a separate call.

## Report

- On success, relay the `CC_STATUSLINE_DIR_URL = …` and `written to …` lines.
  The next render picks the link up, so no restart is needed. Tell the user to
  click the branch name inside a worktree to check it.
- Relay a `warning: … is not ignored by git` line verbatim. The file names a
  host and should not be committed.
- On `remove`, relay the line it printed.
- On failure, relay the error verbatim.
- If a click opens VS Code but it reports that the path does not exist on this
  computer, the link reached a local window instead of Remote-SSH. Check the host.

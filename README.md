# cc-statusline

A multi-line, ANSI-colored statusline renderer for [Claude Code](https://claude.com/claude-code). Surfaces model, cost, context, rate limits, token usage, cache hit rate, live agent/tool/todo activity, and the last prompt — all in 3–4 lines.

Two equivalent implementations, pick whichever fits your platform:

- **[`cc-statusline.sh`](cc-statusline.sh)** — pure `bash` + `jq`. The primary version (Linux/macOS). Chosen over a Node.js implementation to avoid an extra runtime binary and its higher idle memory footprint.
- **[`cc-statusline.ps1`](cc-statusline.ps1)** — PowerShell 7+ (`pwsh`), for Windows (also runs on macOS/Linux `pwsh`). Same field map, layout, and output — see [PowerShell version](#powershell-version) below for the install path and its trade-offs.

## Sample output

```
Opus 4.7 (high) | jimmy:ajent git:( main:f97c9bf) (5M 1A +16 -8) | NOR | 👤 v***@gmail.com
●●●◐●●●●●● 35% 987K | $1.23 (today $5.67) | 5h 23% (2h 14m) | 7d 57% (5d 8h)
cache 97% | in: 123.4K out: 7.8K | api wait 30m 00s (50%) | +42 -7 lines | #4f1c8e02-… | tools Read,Bash
todos 3/7 fix smoke test | 14:23 ❯ update README sample output
```

L3 groups "session-wide consumption" (cache, tokens, api wait) plus the active subagent indicator. L4 groups "live activity & user intent" (currently running tools, todo progress, last prompt). Both lines render conditionally — empty fields drop out.

The `agents …` indicator on L3 is dual-mode: **magenta** while subagent(s) are running (`agents N name1,name2`), **dim** as a fallback showing the most recent subagent_type once they finish — so the field doesn't vanish the moment a subagent completes.

## Requirements

- `bash` 4+
- `jq`
- `bc` (for token K/M formatting)
- `git` (optional — enables branch / repo-link / diff stats)
- A terminal that renders ANSI color + OSC 8 hyperlinks (most modern terminals do)

## Install

```bash
# 1. Clone anywhere
git clone https://github.com/jimmyolo/cc-statusline.git ~/projects/cc-statusline

# 2. Symlink into ~/.claude/ (or copy — symlink lets `git pull` pick up updates)
ln -s ~/projects/cc-statusline/cc-statusline.sh ~/.claude/cc-statusline.sh

# 3. Wire up in ~/.claude/settings.json
#    Add (or merge into existing settings):
#    {
#      "statusLine": {
#        "type": "command",
#        "command": "bash ~/.claude/cc-statusline.sh"
#      }
#    }
```

Statusline is hot-reloaded — next refresh picks up the new script. No session restart needed.

## PowerShell version

```powershell
# 1. Clone anywhere (same repo as the bash version)
git clone https://github.com/jimmyolo/cc-statusline.git ~/projects/cc-statusline

# 2. Symlink into ~/.claude/ (on Windows this needs Developer Mode enabled, or an
#    elevated shell — otherwise New-Item errors with "you do not have sufficient
#    privilege"; copying the file instead works without either)
New-Item -ItemType SymbolicLink -Path "$HOME/.claude/cc-statusline.ps1" -Target "~/projects/cc-statusline/cc-statusline.ps1"

# 3. Wire up in ~/.claude/settings.json
#    {
#      "statusLine": {
#        "type": "command",
#        "command": "pwsh -NoProfile -File \"$HOME/.claude/cc-statusline.ps1\""
#      }
#    }
```

Requires PowerShell 7+ (`pwsh`) — Windows PowerShell 5.1 does not have the `??` operator this script uses. **Always pass `-NoProfile`**: statusline commands run on every render, and a profile script re-sourcing on every invocation is a real, avoidable latency hit.

Field map, layout, and output are intended to be byte-identical to `cc-statusline.sh` for the same input — verified against `test/sample.json` and an active-transcript fixture (see [Testing](#testing)). Two trade-offs worth knowing before you rely on it:

- **Higher per-invocation floor.** PowerShell/.NET startup + cmdlet JIT warmup + the ~8 external `git` calls the script makes measure around 600–700ms end to end, versus bash's ~60ms. This is inherent to the runtime (same category of trade-off as the Node.js option that was passed over for the bash version), not something this script can optimize away without a much larger rewrite (e.g. a git library binding instead of shelling out).
- **Verified on Linux `pwsh`, not Windows Terminal.** Development/testing here ran on a portable `pwsh` on Linux — that confirms the logic and output are correct, but *not* how ANSI color, OSC 8 hyperlinks, or emoji width actually render in Windows Terminal / VS Code's integrated terminal. Sanity-check the rendered output there before trusting it blind.

## Field reference

Both scripts read the same 22 fields from the JSON Claude Code pipes to `statusLine.command` on stdin (same JSON paths, different variable-naming convention per language). Each field maps to a specific display block:

| Field | JSON path | Displayed in |
|---|---|---|
| `MODEL` | `.model.display_name` | L1 model badge (a trailing `(1M context)`-style variant is dropped) |
| `DIR` | `.workspace.current_dir` | L1 path fallback when `project_dir` is absent |
| `PROJECT_DIR` | `.workspace.project_dir` | L1 project root (name only) + `file://` hyperlink |
| `COST` | `.cost.total_cost_usd` | L2 cost + today tracker |
| `PCT` | `.context_window.used_percentage` | L2 context bar (fallback only — recomputed against `CTX_EFF`) |
| `CTX_SIZE` | `.context_window.context_window_size` | `CTX_EFF` → L2 window label + `%` denominator |
| `DURATION_MS` | `.cost.total_duration_ms` | L3 api-wait %, plus disabled blocks |
| `LINES_ADD` / `LINES_DEL` | `.cost.total_lines_{added,removed}` | L1 `+N -N lines` |
| `VIM_MODE` | `.vim.mode` | L1 NOR / INS |
| `VERSION` | `.version` | L1 `vX.Y.Z` |
| `RATE_5H` / `RATE_7D` | `.rate_limits.{five_hour,seven_day}.used_percentage` | L2 rate-limit % |
| `RESET_5H` / `RESET_7D` | `.rate_limits.{five_hour,seven_day}.resets_at` | L2 countdown |
| `TOTAL_IN_TOKENS` / `TOTAL_OUT_TOKENS` | `.context_window.total_{input,output}_tokens` | L3 `in:` / `out:` |
| `API_DURATION_MS` | `.cost.total_api_duration_ms` | L3 api wait |
| `CACHE_READ` / `CACHE_CREATE` / `CUR_INPUT` | `.context_window.current_usage.*` | L3 cache hit (cur detail disabled by default) + L2 `%` numerator |
| `SESSION_ID` | `.session_id` | L3 session id + today-cost tracker + last-prompt lookup |
| `TRANSCRIPT_PATH` | `.transcript_path` | L3 agents · L4 tools · todos |

The full mapping (with paired-disable annotations) lives at the top of [`cc-statusline.sh`](cc-statusline.sh).

## Layout

| Line | Contents |
|---|---|
| L1 | model · `user:project-root` · `branch:commit` · git-stats · vim · account (redacted email) |
| L2 | context-bar · window label · cost (session + today) · 5h limit · 7d limit |
| L3 | cache-hit · tokens in/out · api wait · session lines · session id · running tools |
| L4 | running tools · todos (with current task) · last prompt (with `❯` marker) — entire line conditionally rendered |

### Project state

L1's middle field mirrors the shell prompt — `user:project git:( branch:commit) (M A D +N -N)`, same colors and the same U+E0A0 branch glyph a Powerline-style `PS1` uses — `τ` instead of that glyph when the checkout is a linked worktree — so it reads as the prompt already being scanned rather than as a second, differently-shaped one. The path is the **name** of the project root Claude reports in `workspace.project_dir` — the last component only, with the full absolute path one hover away in its link — not the cwd: a session that wanders into a subdirectory still shows the project it is working on, and inside a worktree the path stays the checkout Claude was launched on rather than `…/.claude/worktrees/<name>`. A session *launched* inside a worktree reports that worktree as its project root, so that case collapses to the main checkout — the project is the same one either way. A Claude version old enough not to send the field falls back to the cwd. The git half is bracketed as `git:(…)` the way a zsh prompt theme does, since a bare project name no longer shows where it stops and the branch begins; outside a repository the whole group drops out. The worktree glyph keys on `git rev-parse --git-dir` differing from `--git-common-dir`, read in the same single `rev-parse` that already answers the git-dir, toplevel and short-hash questions — no extra process; `τ` says which checkout this is, and the branch name links to the worktree directory for whoever wants the real location. The parenthesised group is live working-tree state (modified / added / deleted files, then staged+unstaged line diff); it drops out entirely on a clean tree. Session-cumulative `+N -N lines` from the cost JSON is a separate field on L3.

### Session id

The full session id renders dim on L3, unabbreviated so it can be copied straight into `claude --resume <id>` or used to address the session when messaging it.

### L1 hyperlinks

Two OSC 8 links on L1 — no API call, and one local ref lookup for the branch link:

| Text | Opens |
|---|---|
| project root | `file://<absolute path>` — the directory in the desktop file manager |
| branch name | that branch's tree on the forge — **or**, inside a linked worktree, `file://` that worktree's own directory |

The path link keeps the absolute path even though the text shows it `~`-collapsed, and needs no remote — it works in a directory that is not a repository at all.

The branch link is derived from `origin`. An SSH remote is not browsable, so it is rewritten to the web URL of the same repository — the SSH user and the `ssh://` port are dropped, while a port on an `https` remote is kept, since a self-hosted forge often serves its UI there.

The SSH port says nothing about which port serves the web UI, and a self-hosted forge often puts them on different ones (`ssh://git@host:30023/…` answering at `https://host:30001/…`). Only the user knows, so:

```sh
export CC_STATUSLINE_WEB_PORT=30001   # appended to the host of an SSH remote
```

An `https` remote already carries its own port and is left alone. The value is spliced into a link target, so a non-numeric one is ignored rather than trusted.

The URL shape follows the forge, guessed from the **host** alone (matching the path too would read `github.com/gitlab-org/gitlab` as GitLab): a host containing `gitlab`, in any case, gets `/-/tree/<branch>`; everything else gets `/tree/<branch>`. A self-hosted instance whose host names no forge — an IP, a bare hostname — is beyond any guess:

```sh
export CC_STATUSLINE_FORGE=gitlab   # or github; overrides the host guess
```

Inside a worktree the branch link is the only way left to reach the checkout actually being worked in, since the path names the main one — so it takes the worktree's directory and the forge link steps aside.

Outside one, the forge link is omitted where it would resolve to nothing: on a detached HEAD, whose displayed name is a remote ref or the literal `detached`, and on a branch with no `refs/remotes/origin/<branch>` — a throwaway worktree's local branch being the usual one, though that case now takes the `file://` link above instead. Pushing the branch creates that ref, and the link appears; a `clone --single-branch`, whose refspec never fetches other branches, is the case where a pushed branch still has no link.

Both targets land in a URL *path*, so only the bytes that would break one are escaped: `%`, `#`, `?` and a space. `/` is deliberately left alone — `feat/x` is both a real ref and a real tree path, and `%2F` is resolved by neither forge.

### Context bar denominator

The context bar and its `%` are **not** the `used_percentage` Claude Code sends on stdin. That field divides current usage by the *raw* model window (1,000,000 for `[1m]` models) and ignores `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, while auto-compact measures against a window that *does* honour it — so with the env var set the bar could read ~17% at the moment compaction fires. Both scripts instead recompute the window as `min(context_window_size, CLAUDE_CODE_AUTO_COMPACT_WINDOW)`, then derive the budget from it as described below, and the L2 window label shows that budget. The displayed `%` divides by that budget instead, so it reads at or above stdin's `used_percentage` — the two often round to the same integer at low usage and diverge as the session fills, which is the point: the bar measures against where compaction actually fires.

Auto-compact does not wait for the window to fill: the CLI holds back a fixed **13,000-token reserve** and triggers there, whether or not any override is set. Both scripts reproduce the whole rule (CLI 2.1.227, `RIo()`):

```
CTX_EFF = pct set ? min(floor(window × pct / 100), window − 13000)
                  : window − 13000
```

So a 1M window shows a `987K` budget by default, and a 200K window shows `187K`. The reserve is a token count rather than a share — it reads as 98.7% of a 1M window but 93.5% of a 200K one — which is why no percentage is hardcoded anywhere. A window at or below 13,000 has nothing left to divide by, so the full window stands in rather than a zero or negative budget.

Because that constant lives inside the CLI, a release can move it. Re-check `RIo()` if the bar starts disagreeing with when compaction actually fires.

`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` only tightens the trigger further, and whichever arm of the `min()` is lower wins: on a 1M window `pct=98` binds at `980K`, while `pct=99` and `pct=100` both land on the `987K` reserve. When the variable is set the L2 label carries both numbers — `500K (1M·50%)` — with the budget first, because that is what the bar's `%` divides by; the percentage is echoed normalised, so `33.30` renders as `33.3`. Unset, there is no percentage to echo and the label stays plain.

The accepted form follows the CLI's `parseFloat`: a numeric *prefix*, so leading blanks, a leading `+`, a leading `.` and a trailing non-numeric tail are all tolerated (`50abc` is 50%). Exponent notation is the one exception — honouring only its mantissa would silently pick a wrong budget, so `1e2` is rejected rather than read as 1%. Six fractional digits are kept and the rest truncated. Anything landing outside `0 < pct ≤ 100` after that, and any value small enough to truncate the budget to zero tokens, is ignored and the label falls back to the plain window. (The CLI instead takes that zero literally and compacts immediately; a zero budget is not something a bar can divide by, so the scripts diverge here on purpose.)

Disabled by default (one-line uncomment to re-enable — see [Customization](#customization)): per-message duration (`DUR`), tokens-per-minute burn rate, and current-usage detail (`cur N in / N read / N write`).

## Performance

The agents/tools/todos widgets read `.transcript_path`, which grows for the life of a session. Both scripts bound that read to the last ~2000 lines instead of scanning the whole file, so render cost stays flat as sessions get longer instead of growing with total transcript size — the display only ever needs the 3 most recent agents/tools/todo anyway.

Measured before/after on a synthetic 89K-line/251MB transcript (20x a real 12MB session capture, as a worst-case stress test):

| | Unbounded (old) | Bounded (current) |
|---|---|---|
| `cc-statusline.sh` | 1.9s | 0.15s |
| `cc-statusline.ps1` | 9.7s (`Get-Content -Tail`) | 1.9s (`[System.IO.File]::ReadLines()`) |

The bash version gets a true flat cost (`tail -n` seeks from EOF, like GNU `tail` always has). The PowerShell version is bounded but still scales with total file size — .NET has no built-in seek-from-EOF line reader, and `Get-Content -Tail` is not one either (it was the original bottleneck here, at 8.6s alone on the same file). `File.ReadLines()` avoids `Get-Content`'s per-line pipeline overhead (measured 0.5s for a full scan of the same file) but still reads start-to-finish. In practice this is a non-issue: real transcripts measured on this machine top out around 12MB, where the difference between "flat" and "scales with size" doesn't matter.

## Customization

The script is annotated for surgical edits:

- **Field map at the top** — see which `F[N]` feeds which line.
- **Inline `# → L<n>` comments** on every variable assignment.
- **`# INPUTS:` banner** above each `L1`/`L2`/`L3`/`L4` block lists every variable that line consumes.
- **`Paired-disable note`** above each disabled block (Duration, Burn rate, cur-detail) tells you whether the underlying `F[N]` extraction can be commented out too.

To disable a display block:

1. Comment out the relevant `L1=`/`L2=`/`L3=`/`L4=` concat line(s).
2. Check the field map — if any `F[N]` is consumed *only* by what you disabled, comment its extraction too.
3. Re-run the smoke test (`bash test/smoke.sh`) to confirm no regression.

To re-enable the bundled disabled blocks (Duration, Burn rate, cur-detail):

1. Uncomment the block body.
2. For `DUR` / `BURN_PART`: inject the produced variable into the desired `L1`–`L4` line. For `cur-detail`: the block already self-appends to `L3` — just uncomment the four lines in place.

## Testing

```bash
bash test/smoke.sh          # cc-statusline.sh
pwsh test/smoke.ps1         # cc-statusline.ps1
```

Each runs its respective script against `test/sample.json` (plus an active-transcript fixture for the agents/tools/todos widgets) and asserts:

- Output contains at least 3 non-empty lines.
- Output contains expected markers (model name, version, context size, cost, rate limits, tokens, cache hit, vim mode, agents/tools/todos).
- Script does not crash.

Both smoke tests are robust to volatile fields (today-cost tracker, countdown timers) by checking for structural markers rather than exact byte equality. The two scripts are also cross-checked to produce byte-identical plain-text output for the same input (see [PowerShell version](#powershell-version)).

## License

[The Unlicense](LICENSE) — public domain, do whatever.

## Acknowledgements

Inspired by `claude-dashboard`'s per-session cost aggregation logic. Layout & feature set hand-tuned for personal workflow.

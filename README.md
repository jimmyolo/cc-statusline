# cc-statusline

A multi-line, ANSI-colored statusline for [Claude Code](https://claude.com/claude-code): model, cost, context, rate limits, tokens, cache hit rate, live agent/tool/todo activity and the last prompt, in 3–4 lines.

- **[`cc-statusline.sh`](cc-statusline.sh)** — `bash` + `jq`, Linux/macOS. Primary.
- **[`cc-statusline.ps1`](cc-statusline.ps1)** — PowerShell 7+ (`pwsh`), Windows. Same fields, layout and output.

## Sample output

```
Opus 4.7 (high) | jimmy:ajent git:( main:f97c9bf) (5M 1A +16 -8) | NOR | 👤 v***@gmail.com
●●●◐●●●●●● 35% 987K | $1.23 (today $5.67) | 5h:23% (↺ 2h 14m) | 7d:57% fable:10% (↺ 5d 8h)
cache 97% | in: 123.4K out: 7.8K | api wait 30m 00s (50%) | +42 -7 lines | #4f1c8e02-… | tools Read,Bash
todos 3/7 fix smoke test | 14:23 ❯ update README sample output
```

## Requirements

- `bash` 4+, `jq`
- `git` (optional: branch, repo link, diff stats)
- A terminal with ANSI color and OSC 8 hyperlinks

## Install

### Plugin

```
/plugin install cc-statusline --marketplace jimmyolo/cc-statusline
/cc-statusline:setup          # or: /cc-statusline:setup pwsh
```

- Claude Code < 2.1.275: `/plugin marketplace add jimmyolo/cc-statusline`, then `/plugin install cc-statusline@cc-statusline`.
- Setup copies the script to `~/.claude/plugins/data/cc-statusline-cc-statusline/` and merges `statusLine` into `settings.json`. It runs in `bash` and needs `jq`, Git Bash on Windows.
- After `/plugin update cc-statusline`, run setup again. An edited copy is kept as `<script>.bak`; `<script>.orig` is setup's reference for detecting edits.
- `/plugin disable` does not remove the status line, and `/plugin uninstall` leaves `statusLine` pointing at a deleted file. Remove the key first: `jq 'del(.statusLine)' ~/.claude/settings.json`, then write the result back.

### Manual

```bash
git clone https://github.com/jimmyolo/cc-statusline.git ~/projects/cc-statusline
ln -s ~/projects/cc-statusline/cc-statusline.sh ~/.claude/cc-statusline.sh   # or copy

# ~/.claude/settings.json
#   "statusLine": { "type": "command", "command": "bash ~/.claude/cc-statusline.sh" }
```

Hot-reloaded on the next refresh; no restart needed.

## Configuration

| Variable | Effect |
|---|---|
| `CC_STATUSLINE_MODEL_USAGE=0` | Hide the per-model weekly limit (`fable:10%`) on L2 |
| `CC_STATUSLINE_WEB_PORT=<port>` | Web UI port for an SSH remote (`ssh://git@host:30023/…` → `https://host:30001/…`). Non-numeric is ignored |
| `CC_STATUSLINE_FORGE=gitlab\|github` | Override the forge guessed from the remote host |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Read by the context bar, see [Context bar](#context-bar) |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | Read by the context bar, see [Context bar](#context-bar) |

## Field reference

Fields read from the stdin JSON, same paths in both scripts:

| Field | JSON path | Displayed in |
|---|---|---|
| `MODEL` | `.model.display_name` | L1 model badge (a trailing `(1M context)`-style variant is dropped) |
| `EFFORT_IN` | `.effort.level` | L1 effort badge; falls back to `~/.claude/settings.json` on an older Claude Code |
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

Full map, with paired-disable notes, at the top of [`cc-statusline.sh`](cc-statusline.sh).

Disabled by default, re-enabled by uncommenting in the script: per-message duration (`DUR`), burn rate, and `cur N in / N read / N write`.

## Layout

| Line | Contents |
|---|---|
| L1 | model · `user:project-root` · `branch:commit` · git-stats · vim · account (redacted email) |
| L2 | context-bar · window label · cost (session + today) · 5h limit · 7d limit · per-model weekly limit |
| L3 | cache-hit · tokens in/out · api wait · session lines · session id · running tools |
| L4 | running tools · todos (with current task) · last prompt (with `❯` marker) — entire line conditionally rendered |

Empty fields drop out.

### L1 hyperlinks

| Text | Opens |
|---|---|
| project root | `file://<absolute path>`; needs no remote |
| branch name | the branch's tree on the forge; inside a linked worktree, `file://` that worktree |

- Forge URL comes from `origin`. SSH remotes are rewritten to `https`, dropping the SSH user and port; an `https` port is kept.
- Forge guessed from the host: contains `gitlab` → `/-/tree/<branch>`, else `/tree/<branch>`.
- No forge link on a detached HEAD or a branch without `refs/remotes/origin/<branch>` (push it, or note `clone --single-branch` never fetches one).
- Only `%`, `#`, `?` and space are escaped; `/` stays, since `%2F` resolves on neither forge.

### Per-model weekly limit

`rate_limits` carries no per-model limit ([#92080](https://github.com/anthropics/claude-code/issues/92080), [#91920](https://github.com/anthropics/claude-code/issues/91920)), so it comes from the experimental `get_usage` control request.

- A detached headless `claude -p` sends it at most every 5 minutes and writes `~/.claude/cc-statusline-usage.tsv` (mode `600`). The render only reads that file.
- Uses your existing `claude` login; the script reads no token and calls no endpoint. The request is a fixed literal.
- Runs from `/` with `--setting-sources "" --strict-mcp-config --disable-slash-commands --no-session-persistence`: no hooks, MCP, skills or session record, no model call.
- Killed after 30 s; a failure retries on the next 5-minute window.
- Label sanitised to `[a-z0-9 ._-]`. Windows past reset, and caches older than 30 minutes, are dropped.
- `.sh` needs `setsid` and `timeout`; without them nothing is shown. `.ps1` re-invokes itself with `-RefreshUsage`; its Windows launch is untested.

### Context bar

Stdin's `used_percentage` divides by the raw window and ignores `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. The bar divides by where auto-compact actually fires (CLI 2.1.227, `RIo()`):

```
window  = min(context_window_size, CLAUDE_CODE_AUTO_COMPACT_WINDOW)
CTX_EFF = pct set ? min(floor(window × pct / 100), window − 13000)
                  : window − 13000
```

- 1M → `987K`, 200K → `187K`. A window ≤ 13,000 uses the full window.
- The 13,000 reserve is a CLI constant; re-check `RIo()` if the bar drifts from real compaction.
- `pct` is `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`. When set, the label is `500K (1M·50%)`.
- Parsed like `parseFloat` (`50abc` → 50), except exponents (`1e2`) are rejected. Kept to 6 decimals. Outside `0 < pct ≤ 100`, or a zero budget, is ignored.

## Testing

```bash
bash test/smoke.sh          # cc-statusline.sh
pwsh test/smoke.ps1         # cc-statusline.ps1
bash test/install.sh        # scripts/install.sh (the plugin's /cc-statusline:setup)
```

## License

[The Unlicense](LICENSE) — public domain, do whatever.

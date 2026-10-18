# cc-statusline

Multi-line, ANSI-colored statusline for [Claude Code](https://claude.com/claude-code).

- **[`cc-statusline.sh`](cc-statusline.sh)** — `bash` + `jq`, Linux/macOS
- **[`cc-statusline.ps1`](cc-statusline.ps1)** — PowerShell 7+ (`pwsh`), Windows; same output
- Shows model, cost, context, rate limits, tokens, cache hit, agents/tools/todos, last prompt

## Sample

```
Opus 4.7 (high) | jimmy:ajent git:( main:f97c9bf) (5M 1A +16 -8) | NOR | 👤 v***@gmail.com
●●●◐●●●●●● 35% 987K | $1.23 (today $5.67) | 5h:23% (↺ 2h 14m) | 7d:57% fable:10% (↺ 5d 8h)
cache 97% | in: 123.4K out: 7.8K | api wait 30m 00s (50%) | +42 -7 lines | #4f1c8e02-… | tools Read,Bash
todos 3/7 fix smoke test | 14:23 ❯ update README sample output
```

## Requirements

- `bash` 4+, `jq`
- `git` (optional: branch, repo link, diff stats)
- Terminal with ANSI color + OSC 8 hyperlinks
- `.ps1`: PowerShell 7+

## Install

Plugin:

```
/plugin install cc-statusline --marketplace jimmyolo/cc-statusline
/cc-statusline:setup
```

- On Windows, the first setup installs the PowerShell port when `pwsh` is on PATH, else the shell script; a re-run keeps the installed script. To detect again: `/cc-statusline:setup remove`, then `/cc-statusline:setup`
- Claude Code < 2.1.275: `/plugin marketplace add jimmyolo/cc-statusline` first, then `/plugin install cc-statusline@cc-statusline`
- After `/plugin update cc-statusline`: re-run `/cc-statusline:setup`
- Before `/plugin uninstall`: `/cc-statusline:setup remove` (deletes the whole `statusLine` object, if setup wrote it)

Manual:

```bash
git clone https://github.com/jimmyolo/cc-statusline.git ~/projects/cc-statusline
ln -s ~/projects/cc-statusline/cc-statusline.sh ~/.claude/cc-statusline.sh

# ~/.claude/settings.json
#   "statusLine": { "type": "command", "command": "bash ~/.claude/cc-statusline.sh" }
```

## Reference

### Layout

| Line | Contents |
|---|---|
| L1 | model · `user:project-root` · `branch:commit` · git-stats · vim · account (redacted email) |
| L2 | context-bar · window label · cost (session + today) · 5h limit · 7d limit · per-model weekly limit |
| L3 | cache-hit · tokens in/out · api wait · session lines · session id · running tools |
| L4 | running tools · todos (with current task) · last prompt (with `❯` marker) — entire line conditionally rendered |

### Fields

| Field | JSON path | Displayed in |
|---|---|---|
| `MODEL` | `.model.display_name` | L1 model badge |
| `EFFORT_IN` | `.effort.level` | L1 effort badge |
| `DIR` | `.workspace.current_dir` | L1 path fallback |
| `PROJECT_DIR` | `.workspace.project_dir` | L1 project root + `file://` link |
| `COST` | `.cost.total_cost_usd` | L2 cost + today tracker |
| `PCT` | `.context_window.used_percentage` | L2 context bar (fallback) |
| `CTX_SIZE` | `.context_window.context_window_size` | L2 window label + `%` denominator |
| `DURATION_MS` | `.cost.total_duration_ms` | L3 api-wait % |
| `LINES_ADD` / `LINES_DEL` | `.cost.total_lines_{added,removed}` | L1 `+N -N lines` |
| `VIM_MODE` | `.vim.mode` | L1 NOR / INS |
| `VERSION` | `.version` | L1 `vX.Y.Z` |
| `RATE_5H` / `RATE_7D` | `.rate_limits.{five_hour,seven_day}.used_percentage` | L2 rate-limit % |
| `RESET_5H` / `RESET_7D` | `.rate_limits.{five_hour,seven_day}.resets_at` | L2 countdown |
| `TOTAL_IN_TOKENS` / `TOTAL_OUT_TOKENS` | `.context_window.total_{input,output}_tokens` | L3 `in:` / `out:` |
| `API_DURATION_MS` | `.cost.total_api_duration_ms` | L3 api wait |
| `CACHE_READ` / `CACHE_CREATE` / `CUR_INPUT` | `.context_window.current_usage.*` | L3 cache hit + L2 `%` numerator |
| `SESSION_ID` | `.session_id` | L3 session id + today tracker + last prompt |
| `TRANSCRIPT_PATH` | `.transcript_path` | L3 agents · L4 tools · todos |

Full map at the top of [`cc-statusline.sh`](cc-statusline.sh).

### Environment

| Variable | Effect |
|---|---|
| `CC_STATUSLINE_MODEL_USAGE=0` | Hide the per-model weekly limit |
| `CC_STATUSLINE_WEB_PORT=<port>` | Web UI port for an SSH remote's branch link |
| `CC_STATUSLINE_FORGE=gitlab\|github` | Override the forge guessed from the host |

## Test

```bash
bash test/smoke.sh          # cc-statusline.sh
pwsh test/smoke.ps1         # cc-statusline.ps1
bash test/install.sh        # plugin installer
```

## License

[The Unlicense](LICENSE)

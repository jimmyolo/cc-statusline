# cc-statusline

A multi-line, ANSI-colored statusline renderer for [Claude Code](https://claude.com/claude-code), written in pure `bash` + `jq`. Surfaces model, cost, context, rate limits, token usage, cache hit rate, live agent/tool/todo activity, and the last prompt — all in 3–4 lines.

## Sample output

```
Opus 4.7 (1M context) (H) 1M v1.2.3 | repo (main) | +42 -7 lines | 3A | NOR
●●●◐●●●●●● 35% | $1.23 (today $5.67) | 5h 23% (2h 14m) | 7d 57% (5d 8h)
cache 97% | in: 123.4K out: 7.8K | api wait 30m 00s (50%) | cur 200 in 50.0K read 1.0K write
agents 2 reviewer-opus-high,coder-sonnet-max | tools Read,Bash | todos 3/7 fix smoke test
```

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

## Field reference

The script reads 22 fields from the JSON Claude Code pipes to its `statusLine.command` on stdin. Each field maps to a specific display block:

| Field | JSON path | Displayed in |
|---|---|---|
| `MODEL` | `.model.display_name` | L1 model badge |
| `DIR` | `.workspace.current_dir` | Repo-link basename fallback |
| `COST` | `.cost.total_cost_usd` | L2 cost + today tracker |
| `PCT` | `.context_window.used_percentage` | L2 context bar |
| `CTX_SIZE` | `.context_window.context_window_size` | L1 `1M`/`200K` label |
| `DURATION_MS` | `.cost.total_duration_ms` | L3 api-wait %, plus disabled blocks |
| `LINES_ADD` / `LINES_DEL` | `.cost.total_lines_{added,removed}` | L1 `+N -N lines` |
| `VIM_MODE` | `.vim.mode` | L1 NOR / INS |
| `VERSION` | `.version` | L1 `vX.Y.Z` |
| `RATE_5H` / `RATE_7D` | `.rate_limits.{five_hour,seven_day}.used_percentage` | L2 rate-limit % |
| `RESET_5H` / `RESET_7D` | `.rate_limits.{five_hour,seven_day}.resets_at` | L2 countdown |
| `TOTAL_IN_TOKENS` / `TOTAL_OUT_TOKENS` | `.context_window.total_{input,output}_tokens` | L3 `in:` / `out:` |
| `API_DURATION_MS` | `.cost.total_api_duration_ms` | L3 api wait |
| `CACHE_READ` / `CACHE_CREATE` / `CUR_INPUT` | `.context_window.current_usage.*` | L3 cache hit + cur detail |
| `SESSION_ID` | `.session_id` | Today-cost tracker + last-prompt lookup |
| `TRANSCRIPT_PATH` | `.transcript_path` | L4 agents / tools / todos |

The full mapping (with paired-disable annotations) lives at the top of [`cc-statusline.sh`](cc-statusline.sh).

## Layout

| Line | Contents |
|---|---|
| L1 | model · ctx-size · version · repo-link · branch · lines · git-stats · vim |
| L2 | context-bar · cost (session + today) · 5h limit · 7d limit |
| L3 | cache-hit · tokens in/out · api wait · current-usage detail |
| L4 | active agents · running tools · todos · last prompt (conditionally rendered) |

## Customization

The script is annotated for surgical edits:

- **Field map at the top** — see which `F[N]` feeds which line.
- **Inline `# → L<n>` comments** on every variable assignment.
- **`# INPUTS:` banner** above each `L1`/`L2`/`L3`/`L4` block lists every variable that line consumes.
- **`Paired-disable note`** above each disabled block (Duration, Burn rate) tells you whether the underlying `F[N]` extraction can be commented out too.

To disable a display block:

1. Comment out the relevant `L1=`/`L2=`/`L3=`/`L4=` concat line(s).
2. Check the field map — if any `F[N]` is consumed *only* by what you disabled, comment its extraction too.
3. Re-run the smoke test (`bash test/smoke.sh`) to confirm no regression.

To re-enable the bundled disabled blocks (Duration, Burn rate):

1. Uncomment the block body.
2. Inject the produced variable (`$DUR`, `$BURN_PART`) into the desired `L1`–`L4` line.

## Testing

```bash
bash test/smoke.sh
```

Runs the script against `test/sample.json` and asserts:

- Output contains at least 3 non-empty lines.
- Output contains expected markers (model name, version, context size, cost).
- Script does not crash.

The smoke test is robust to volatile fields (today-cost tracker, countdown timers) by checking for structural markers rather than exact byte equality.

## License

[The Unlicense](LICENSE) — public domain, do whatever.

## Acknowledgements

Inspired by `claude-dashboard`'s per-session cost aggregation logic. Layout & feature set hand-tuned for personal workflow.

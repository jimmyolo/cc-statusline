# cc-statusline

A multi-line, ANSI-colored statusline renderer for [Claude Code](https://claude.com/claude-code). Surfaces model, cost, context, rate limits, token usage, cache hit rate, live agent/tool/todo activity, and the last prompt — all in 3–4 lines.

Two equivalent implementations, pick whichever fits your platform:

- **[`cc-statusline.sh`](cc-statusline.sh)** — pure `bash` + `jq`. The primary version (Linux/macOS). Chosen over a Node.js implementation to avoid an extra runtime binary and its higher idle memory footprint.
- **[`cc-statusline.ps1`](cc-statusline.ps1)** — PowerShell 7+ (`pwsh`), for Windows (also runs on macOS/Linux `pwsh`). Same field map, layout, and output — see [PowerShell version](#powershell-version) below for the install path and its trade-offs.

## Sample output

```
Opus 4.7 (1M context) (H) 1M v1.2.3 | repo (main) | +42 -7 lines | 3A | NOR
●●●◐●●●●●● 35% | $1.23 (today $5.67) | 5h 23% (2h 14m) | 7d 57% (5d 8h)
cache 97% | in: 123.4K out: 7.8K | api wait 30m 00s (50%) | agents 2 reviewer-opus-high,coder-sonnet-max
tools Read,Bash | todos 3/7 fix smoke test | 14:23 ❯ update README sample output
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

- **Higher per-invocation floor.** PowerShell/.NET startup + cmdlet JIT warmup + the ~8 external `git` calls the script makes measure around 600–700ms end to end, versus bash's ~90ms. This is inherent to the runtime (same category of trade-off as the Node.js option that was passed over for the bash version), not something this script can optimize away without a much larger rewrite (e.g. a git library binding instead of shelling out).
- **Verified on Linux `pwsh`, not Windows Terminal.** Development/testing here ran on a portable `pwsh` on Linux — that confirms the logic and output are correct, but *not* how ANSI color, OSC 8 hyperlinks, or emoji width actually render in Windows Terminal / VS Code's integrated terminal. Sanity-check the rendered output there before trusting it blind.

## Field reference

Both scripts read the same 22 fields from the JSON Claude Code pipes to `statusLine.command` on stdin (same JSON paths, different variable-naming convention per language). Each field maps to a specific display block:

| Field | JSON path | Displayed in |
|---|---|---|
| `MODEL` | `.model.display_name` | L1 model badge |
| `DIR` | `.workspace.current_dir` | Repo-link basename fallback |
| `COST` | `.cost.total_cost_usd` | L2 cost + today tracker |
| `PCT` | `.context_window.used_percentage` | L2 context bar (fallback only — recomputed against `CTX_EFF`) |
| `CTX_SIZE` | `.context_window.context_window_size` | `CTX_EFF` → L1 window label + L2 `%` denominator |
| `DURATION_MS` | `.cost.total_duration_ms` | L3 api-wait %, plus disabled blocks |
| `LINES_ADD` / `LINES_DEL` | `.cost.total_lines_{added,removed}` | L1 `+N -N lines` |
| `VIM_MODE` | `.vim.mode` | L1 NOR / INS |
| `VERSION` | `.version` | L1 `vX.Y.Z` |
| `RATE_5H` / `RATE_7D` | `.rate_limits.{five_hour,seven_day}.used_percentage` | L2 rate-limit % |
| `RESET_5H` / `RESET_7D` | `.rate_limits.{five_hour,seven_day}.resets_at` | L2 countdown |
| `TOTAL_IN_TOKENS` / `TOTAL_OUT_TOKENS` | `.context_window.total_{input,output}_tokens` | L3 `in:` / `out:` |
| `API_DURATION_MS` | `.cost.total_api_duration_ms` | L3 api wait |
| `CACHE_READ` / `CACHE_CREATE` / `CUR_INPUT` | `.context_window.current_usage.*` | L3 cache hit (cur detail disabled by default) + L2 `%` numerator |
| `SESSION_ID` | `.session_id` | Today-cost tracker + last-prompt lookup |
| `TRANSCRIPT_PATH` | `.transcript_path` | L3 agents · L4 tools · todos |

The full mapping (with paired-disable annotations) lives at the top of [`cc-statusline.sh`](cc-statusline.sh).

## Layout

| Line | Contents |
|---|---|
| L1 | model · ctx-size · version · repo-link · branch · lines · git-stats · vim |
| L2 | context-bar · cost (session + today) · 5h limit · 7d limit |
| L3 | cache-hit · tokens in/out · api wait · agents (magenta=running, dim=last seen) |
| L4 | running tools · todos (with current task) · last prompt (with `❯` marker) — entire line conditionally rendered |

### Context bar denominator

The context bar and its `%` are **not** the `used_percentage` Claude Code sends on stdin. That field divides current usage by the *raw* model window (1,000,000 for `[1m]` models) and ignores `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, while auto-compact measures against a window that *does* honour it — so with the env var set the bar could read ~17% at the moment compaction fires. Both scripts instead recompute against `CTX_EFF = min(context_window_size, CLAUDE_CODE_AUTO_COMPACT_WINDOW)`, and the L1 window label shows that same effective window. With the env var unset, `CTX_EFF` is just the model window and the displayed `%` matches stdin.

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

#!/usr/bin/env pwsh
#Requires -Version 7.0
# =============================================================================
# Claude Code statusline renderer (PowerShell port of cc-statusline.sh)
# -----------------------------------------------------------------------------
# Field map: JSON input -> variable -> display block
#   [x] active   [ ] block currently commented out (paired-disable candidate)
#
#   Model              .model.display_name                         -> L1 model badge + Effort default lookup
#   Dir                .workspace.current_dir                      -> RepoLink basename fallback + Pwd subpath
#   ProjectDir         .workspace.project_dir                      -> L1 Pwd subpath (cwd relative to project root)
#   Cost               .cost.total_cost_usd                        -> L2 cost + today-cost tracker
#   Pct                .context_window.used_percentage              -> L2 context bar + % label (fallback only; recomputed vs CtxEff)
#   CtxSize            .context_window.context_window_size          -> CtxEff -> L1 window label + L2 % denominator
#   DurationMs         .cost.total_duration_ms                      -> L3 api wait %  [ ] Dur  [ ] burn rate
#   LinesAdd/LinesDel  .cost.total_lines_{added,removed}             -> L1 +N -N lines
#   VimMode            .vim.mode                                    -> L1 NOR / INS
#   Version            .version                                     -> L1 vX.Y.Z (hidden by default)
#   Rate5h/Rate7d       .rate_limits.{five_hour,seven_day}.used_percentage -> L2 rate-limit %
#   Reset5h/Reset7d     .rate_limits.{five_hour,seven_day}.resets_at       -> L2 countdown
#   TotalInTokens/TotalOutTokens .context_window.total_{input,output}_tokens -> L3 in:/out:  [ ] burn rate
#   ApiDurationMs      .cost.total_api_duration_ms                  -> L3 api wait
#   CacheRead/CacheCreate/CurInput .context_window.current_usage.*  -> L3 cache hit + L2 % numerator  [ ] cur detail
#   SessionId          .session_id                                  -> today-cost tracker + last-prompt lookup
#   TranscriptPath     .transcript_path                             -> agents / tools / todos widgets
#
# Display layout mirrors cc-statusline.sh:
#   L1: model . ctx-size . repo . branch . lines . git-stats . vim . account
#   L2: ctx-bar . cost (session + today) . 5h limit . 7d limit
#   L3: cache-hit . tokens in/out . api wait . session lines . tools
#   Agent lines: up to 3 most recent subagent dispatches, one per line
#   L4: todos . last prompt (conditionally printed)
# =============================================================================

<#
  Both console streams inherit the Windows console codepage (cp950 on zh-TW),
  which mangles the statusline's non-ASCII glyphs on the way out and the piped
  JSON on the way in. Two constraints:
    - InputEncoding must be set before the first [Console]::In access; the
      StreamReader is built once and cached.
    - The setters throw when the process has no console handle. Failing to set
      them must degrade to mojibake, never to no output at all.
#>
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
try { [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

# ── Colors (real control chars, not deferred-interpretation like bash's echo -e) ──
$Esc = [char]27
$Bel = [char]7
$Reset = "$Esc[0m"; $Bold = "$Esc[1m"; $Dim = "$Esc[2m"
$Cyan = "$Esc[36m"; $Green = "$Esc[32m"; $Yellow = "$Esc[33m"
$Red = "$Esc[31m"; $Magenta = "$Esc[35m"; $Blue = "$Esc[34m"
$White = "$Esc[37m"
$Sep = "${Dim} | ${Reset}"

# ── Helpers ─────────────────────────────────────────────────────
function Get-PctColor {
    param([double]$Val)
    if ($Val -ge 80) { return $Red }
    elseif ($Val -ge 50) { return $Yellow }
    else { return $Green }
}

function Format-Duration {
    param([double]$Ms)
    # [int64] on a double ROUNDS (banker's rounding), it does not truncate —
    # must Floor explicitly to match bash's truncating integer division.
    $totalSec = [int64][math]::Floor($Ms / 1000)
    $h = [int64][math]::Floor($totalSec / 3600)
    $m = [int64][math]::Floor(($totalSec % 3600) / 60)
    $s = [int64]($totalSec % 60)
    if ($h -gt 0) { return "{0}h {1:D2}m" -f $h, $m }
    elseif ($m -gt 0) { return "{0}m {1:D2}s" -f $m, $s }
    else { return "${s}s" }
}

function Format-Countdown {
    param([double]$ResetAt)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $diff = [int64]$ResetAt - $now
    if ($diff -le 0) { return 'now' }
    $h = [int64][math]::Floor($diff / 3600)
    $m = [int64][math]::Floor(($diff % 3600) / 60)
    return "{0}h {1}m" -f $h, $m
}

function Format-Tokens {
    # Matches cc-statusline.sh's `bc` formatting: truncates to 1 decimal, does
    # NOT round (bc's `scale=1` truncates) — keep both scripts' output identical.
    param($T)
    if ($null -eq $T -or $T -eq '') { return '0' }
    $val = [double]$T
    if ($val -ge 1000000) { return '{0:F1}M' -f ([math]::Truncate($val / 1000000 * 10) / 10) }
    elseif ($val -ge 1000) { return '{0:F1}K' -f ([math]::Truncate($val / 1000 * 10) / 10) }
    else { return [string][int64]$val }
}

function Format-Window {
    # Context-window sizes are round numbers — mirrors bash fmt_window().
    param([int64]$T)
    # [int64] cast would banker's-round; bash's $((t / 1000)) truncates.
    if ($T % 1000000 -eq 0) { return "$([math]::Truncate($T / 1000000))M" } else { return "$([math]::Truncate($T / 1000))K" }
}

function Get-TailLines {
    # `Get-Content -Tail` is NOT a seek-from-EOF tail like GNU `tail` — it reads
    # through the whole file (measured: 8.6s on a 251MB/89K-line transcript).
    # File.ReadLines() avoids Get-Content's per-line PSObject/pipeline overhead
    # (measured: 0.5s full-scan on the same file) — still O(file size), since
    # .NET has no built-in seek-from-end line reader, but real transcripts
    # (measured up to ~12MB) finish in low tens of ms this way.
    param([string]$Path, [int]$MaxLines)
    $buffer = [System.Collections.Generic.Queue[string]]::new($MaxLines + 1)
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($buffer.Count -eq $MaxLines) { [void]$buffer.Dequeue() }
        $buffer.Enqueue($line)
    }
    return $buffer.ToArray()
}

# ── Read + parse stdin JSON (single parse, like the one jq call in bash) ──
$rawInput = [Console]::In.ReadToEnd()
try { $Json = $rawInput | ConvertFrom-Json } catch { $Json = [PSCustomObject]@{} }

$Model = $Json.model.display_name
if ([string]::IsNullOrEmpty($Model)) { $Model = 'Claude' }
$Dir = $Json.workspace.current_dir
$Cost = $Json.cost.total_cost_usd
if ($null -eq $Cost) { $Cost = 0 }
$Pct = [math]::Floor([double]($(if ($null -eq $Json.context_window.used_percentage) { 0 } else { $Json.context_window.used_percentage })))  # fallback; recomputed vs $CtxEff
$CtxSize = $Json.context_window.context_window_size  # -> $CtxEff -> L1 window label + L2 % denominator
$DurationMs = $Json.cost.total_duration_ms
if ($null -eq $DurationMs) { $DurationMs = 0 }
$LinesAdd = $Json.cost.total_lines_added
$LinesDel = $Json.cost.total_lines_removed
$VimMode = $Json.vim.mode
$Rate5h = $Json.rate_limits.five_hour.used_percentage
$Rate7d = $Json.rate_limits.seven_day.used_percentage
$Reset5h = $Json.rate_limits.five_hour.resets_at
$Reset7d = $Json.rate_limits.seven_day.resets_at
$TotalInTokens = $Json.context_window.total_input_tokens
$TotalOutTokens = $Json.context_window.total_output_tokens
$ApiDurationMs = $Json.cost.total_api_duration_ms
if ($null -eq $ApiDurationMs) { $ApiDurationMs = 0 }
$CacheRead = $Json.context_window.current_usage.cache_read_input_tokens      # + L2 % numerator (shared)
$CacheCreate = $Json.context_window.current_usage.cache_creation_input_tokens # + L2 % numerator (shared)
$CurInput = $Json.context_window.current_usage.input_tokens                  # + L2 % numerator (shared)
$SessionId = $Json.session_id
$TranscriptPath = $Json.transcript_path
$ProjectDir = $Json.workspace.project_dir

# ── Effort / thinking level (from settings.json) ──────────────
$SettingsPath = "$HOME/.claude/settings.json"
$Effort = $null
if (Test-Path $SettingsPath) {
    try { $Effort = (Get-Content $SettingsPath -Raw | ConvertFrom-Json).effortLevel } catch {}
}
if ([string]::IsNullOrEmpty($Effort)) {
    if ($Model -match 'Opus') { $Effort = 'medium' }
    else { $Effort = 'high' }
}
$EffortLabel = switch ($Effort) {
    'low' { 'L' }
    'medium' { 'M' }
    'high' { 'H' }
    'xhigh' { 'xH' }
    default { '' }
}
if ($Model -match 'Opus|Sonnet') {
    $ModelDisp = "$Model ($EffortLabel)"
} else {
    $ModelDisp = $Model
}

# ── Today cost tracker ────────────────────────────────────────
# Mirror of cc-statusline.sh: track each session's running cost.total_cost_usd
# in a JSON file and sum across today's sessions.
$Tracker = "$HOME/.claude/cc-statusline-cost.json"
$Today = Get-Date -Format 'yyyy-MM-dd'
$TodayCost = 0.0
if ($SessionId) {
    $State = $null
    if (Test-Path $Tracker) {
        try { $State = Get-Content $Tracker -Raw | ConvertFrom-Json -AsHashtable } catch {}
    }
    if (-not $State -or $State['date'] -ne $Today) {
        $State = @{ date = $Today; sessions = @{} }
    }
    if (-not $State['sessions']) { $State['sessions'] = @{} }
    $State['sessions'][$SessionId] = [double]$Cost
    $TodayCost = ($State['sessions'].Values | Measure-Object -Sum).Sum
    ($State | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $Tracker -NoNewline
}

# ── Transcript-derived widgets (agents / tools / todos) ───────
# Perf: only the last TranscriptTailLines lines are read (Get-Content -Tail is
# efficient for this — it seeks from EOF rather than reading the whole file).
# Bounding the window keeps cost flat regardless of how long the session gets;
# see the equivalent note in cc-statusline.sh for the measured before/after.
$TranscriptTailLines = 2000
$ActiveAgents = ''
$ActiveAgentCount = 0
$LastAgent = ''
$RunningTools = ''
$RunningToolCount = 0
$TodoDone = 0
$TodoTotal = 0
$TodoCurrent = ''
$AgentsWithStatus = @()

if ($TranscriptPath -and (Test-Path $TranscriptPath)) {
    $tailLines = try { Get-TailLines -Path $TranscriptPath -MaxLines $TranscriptTailLines } catch { @() }

    $toolUses = [System.Collections.Generic.List[object]]::new()
    $completed = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($line in $tailLines) {
        if ($line -like '*"type":"tool_use"*') {
            try {
                $obj = $line | ConvertFrom-Json
                if ($obj.type -eq 'assistant') {
                    foreach ($c in $obj.message.content) {
                        if ($c.type -eq 'tool_use') {
                            $toolUses.Add([pscustomobject]@{
                                Id           = $c.id
                                Name         = $c.name
                                SubagentType = $c.input.subagent_type
                                Description  = $c.input.description
                            })
                        }
                    }
                }
            } catch {}
        }
        if ($line -like '*"tool_use_id":"toolu_*') {
            try {
                $obj = $line | ConvertFrom-Json
                foreach ($c in $obj.message.content) {
                    if ($c.type -eq 'tool_result' -and $c.tool_use_id) {
                        [void]$completed.Add($c.tool_use_id)
                    }
                }
            } catch {}
        }
    }

    if ($toolUses.Count -gt 0) {
        # Filter to active (tool_use_id NOT in completed); split Agent vs other tools
        $active = $toolUses | Where-Object { -not $completed.Contains($_.Id) }
        $agentsRaw = @($active | Where-Object { $_.Name -eq 'Agent' -and $_.SubagentType } | ForEach-Object { $_.SubagentType })
        $toolsRaw = @($active | Where-Object { $_.Name -ne 'Agent' } | ForEach-Object { $_.Name })

        if ($agentsRaw.Count -gt 0) {
            $ActiveAgentCount = $agentsRaw.Count
            $ActiveAgents = $agentsRaw -join ','
        }
        if ($toolsRaw.Count -gt 0) {
            $RunningToolCount = $toolsRaw.Count
            $RunningTools = $toolsRaw -join ','
        }

        # Last Agent invocation, regardless of completion — fallback for the L3
        # `agents` display when nothing is currently active.
        $lastAgentEntry = $toolUses | Where-Object { $_.Name -eq 'Agent' -and $_.SubagentType } | Select-Object -Last 1
        if ($lastAgentEntry) { $LastAgent = $lastAgentEntry.SubagentType }

        # Agents-with-status: both running + completed, up to 3 most recent.
        $AgentsWithStatus = @($toolUses | Where-Object { $_.Name -eq 'Agent' -and $_.SubagentType } | ForEach-Object {
            [pscustomobject]@{
                Status      = if ($completed.Contains($_.Id)) { 'done' } else { 'running' }
                Type        = $_.SubagentType
                Description = $_.Description
            }
        } | Select-Object -Last 3)
    }

    # Last TodoWrite invocation -> todo progress
    $todoLine = $tailLines | Where-Object { $_ -like '*"name":"TodoWrite"*' } | Select-Object -Last 1
    if ($todoLine) {
        try {
            $todoObj = $todoLine | ConvertFrom-Json
            $todos = $null
            foreach ($c in $todoObj.message.content) {
                if ($c.type -eq 'tool_use' -and $c.name -eq 'TodoWrite') { $todos = $c.input.todos }
            }
            if ($todos) {
                $todosArr = @($todos)
                if ($todosArr.Count -gt 0) {
                    $TodoTotal = $todosArr.Count
                    $TodoDone = @($todosArr | Where-Object { $_.status -in @('completed', 'complete', 'done') }).Count
                    $curTodo = $todosArr | Where-Object { $_.status -in @('in_progress', 'running') } | Select-Object -First 1
                    if ($curTodo) { $TodoCurrent = $curTodo.content }
                }
            }
        } catch {}
    }
}

# ── Last user prompt (from ~/.claude/history.jsonl) ───────────
$LastPrompt = ''
$LastPromptTime = ''
$HistoryFile = "$HOME/.claude/history.jsonl"
if ((Test-Path $HistoryFile) -and $SessionId) {
    # -Tail keeps cost bounded on a long history; 200 lines is plenty for the most-recent prompt
    $histTail = try { Get-TailLines -Path $HistoryFile -MaxLines 200 } catch { @() }
    $needle = "`"sessionId`":`"$SessionId`""
    $lastEntry = $histTail | Where-Object { $_.Contains($needle) } | Select-Object -Last 1
    if ($lastEntry) {
        try {
            $entryObj = $lastEntry | ConvertFrom-Json
            $LastPrompt = ($entryObj.display -replace '\s+', ' ')
            $tsMs = [int64]($(if ($entryObj.timestamp) { $entryObj.timestamp } else { 0 }))
            if ($tsMs -gt 0) {
                $LastPromptTime = [DateTimeOffset]::FromUnixTimeMilliseconds($tsMs).ToLocalTime().ToString('HH:mm')
            }
            if ($LastPrompt.Length -gt 60) {
                $LastPrompt = $LastPrompt.Substring(0, 57) + '...'
            }
        } catch {}
    }
}

# ── Effective context window + usage % ────────────────────────
# stdin's context_window.used_percentage divides by the RAW model window
# (CLI Xv(): 1e6 for [1m] models) and ignores CLAUDE_CODE_AUTO_COMPACT_WINDOW,
# while auto-compact measures against that env value — up to 5x under-report.
# Recompute against the window the compactor actually sees.
$CtxEff = $null
if ($CtxSize) { $CtxEff = [int64]$CtxSize }
$Acw = $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW
if ($Acw -match '^\d+$' -and [int64]$Acw -gt 0) {
    if ($null -eq $CtxEff -or [int64]$Acw -lt $CtxEff) { $CtxEff = [int64]$Acw }
}

<#
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE moves the compaction trigger down to that
  share of the window, so the budget the bar measures against shrinks with it:

    CLI Rko():  threshold = min(floor(window * pct/100), window - 13000)

  The second arm is deliberately not reproduced -- with no override this script
  already treats the whole window as 100%, so applying it only here would make
  the two paths disagree about the same session. Caveat: on a small window that
  arm is the binding one (200K window, pct=95 -> CLI compacts at 187000 while
  the bar divides by 190000).

  The CLI parses with parseFloat, so the accepted form is a numeric prefix --
  leading blanks, an optional '+', a leading '.', and a trailing non-numeric
  tail are all tolerated. Exponent notation is the one parseFloat form
  rejected: honouring only its mantissa would silently pick a wrong budget.
  Six fractional digits are kept and the rest truncated; the digits are read as
  integers rather than through [double], and [0-9] is spelled out because .NET's
  \d also matches non-ASCII digits, so this script and the sh accept exactly the
  same inputs.
#>
$CtxFull = $CtxEff
$Acp = $env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
$AcpOn = $false
$AcpLabel = ''
if ($null -ne $CtxEff -and $Acp -match '^[ \t]*\+?([0-9]*)(\.([0-9]*))?') {
    $AcpInt = $Matches[1]
    $AcpFrac = if ($null -ne $Matches[3]) { $Matches[3] } else { '' }
    $AcpRest = "$Acp".Substring($Matches[0].Length)
    if ("$AcpInt$AcpFrac" -ne '' -and $AcpInt.Length -le 3 -and $AcpRest -notmatch '^[eE]') {
        $AcpFrac = ($AcpFrac + '000000').Substring(0, 6)
        $AcpX = [int64]"0$AcpInt" * 1000000 + [int64]$AcpFrac
        if ($AcpX -gt 0 -and $AcpX -le 100000000) {
            $AcpEff = [int64][math]::Floor(($CtxFull * $AcpX) / 100000000)
            if ($AcpEff -gt 0) {
                $CtxEff = $AcpEff
                $AcpOn = $true
                $AcpLabel = [string][int64]"0$AcpInt"
                $AcpFrac = $AcpFrac -replace '0+$', ''
                if ($AcpFrac -ne '') { $AcpLabel = "$AcpLabel.$AcpFrac" }
            }
        }
    }
}

$CurTokens = [int64]0
foreach ($t in @($CurInput, $CacheRead, $CacheCreate)) {
    if ($null -ne $t -and $t -ne '') { $CurTokens += [int64]$t }
}
if ($null -ne $CtxEff -and $CtxEff -gt 0 -and $CurTokens -gt 0) {
    $Pct = [math]::Floor($CurTokens * 100 / $CtxEff)
    if ($Pct -gt 100) { $Pct = 100 }
}

# ── Context window size label ─────────────────────────────────
# Budget first, since that is what the bar's % divides by; the full window
# stays visible behind it, separated by U+00B7: 500K (1M<U+00B7>50%).
$CtxLabel = ''
if ($null -ne $CtxEff -and $CtxEff -gt 0) {
    if ($AcpOn) {
        $CtxLabel = "${Dim}$(Format-Window $CtxEff) ($(Format-Window $CtxFull)$([char]0x00B7)${AcpLabel}%)${Reset}"
    } else {
        $CtxLabel = "${Dim}$(Format-Window $CtxEff)${Reset}"
    }
}

# ── Git info ──────────────────────────────────────────────────
$Branch = ''
& git rev-parse --git-dir 2>$null 1>$null
$IsGit = ($LASTEXITCODE -eq 0)
if ($IsGit) {
    $Branch = (& git branch --show-current 2>$null)
    # Detached HEAD (checkout of a sha, rebase, bisect) prints nothing. Without a
    # placeholder the whole (branch* M A D +N -N) block on L1 is suppressed, taking
    # the working-tree stats with it. The @<hash> after it names the commit.
    #
    #   git checkout origin/main  -> origin/main   (a ref actually asked for)
    #   git checkout <sha>        -> detached      (nothing to name it)
    #
    # Scoped to refs/remotes/origin on purpose: `git name-rev` resolves to ANY ref
    # at the commit, including an unrelated worktree branch, and would show a name
    # the user is not on. The extra spawn only runs on this rare path.
    if (-not $Branch) {
        $Branch = (& git for-each-ref --count=1 --points-at HEAD `
                     --format='%(refname:short)' refs/remotes/origin 2>$null)
    }
    if (-not $Branch) { $Branch = 'detached' }
}

$RepoLink = Split-Path -Leaf $Dir
$Remote = (& git remote get-url origin 2>$null)
if ($Remote) {
    $Remote = ($Remote -replace '^git@github\.com:', 'https://github.com/') -replace '\.git$', ''
    $RepoName = Split-Path -Leaf $Remote
    $RepoLink = "$Esc]8;;$Remote$Bel$RepoName$Esc]8;;$Bel"
}

# Pwd subpath: show cwd relative to project root when inside a subdirectory.
# project_dir is supplied by the harness; fall back to git toplevel if absent.
$PwdSubpath = ''
$Proj = $ProjectDir
if (-not $Proj) {
    $toplevel = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0) { $Proj = $toplevel }
}
if ($Proj -and $Dir -and ($Dir -ne $Proj)) {
    if ($Dir.StartsWith("$Proj/") -or $Dir.StartsWith("$Proj\")) {
        $PwdSubpath = $Dir.Substring($Proj.Length + 1)
    }
}

# ── Context bar ───────────────────────────────────────────────
# Each cell represents 10%; any partial above a 10%-multiple lights a half-cell.
$BarColor = Get-PctColor $Pct
$BarW = 10
$Full = [int64][math]::Floor($Pct / 10)
if ($Full -gt $BarW) { $Full = $BarW }
$HasHalf = 0
if ($Pct -gt 0 -and ($Pct % 10) -gt 0 -and $Full -lt $BarW) { $HasHalf = 1 }
$Empty = $BarW - $Full - $HasHalf
$Bar = ''
for ($i = 0; $i -lt $Full; $i++) { $Bar += "$BarColor$([char]0x25CF)$Reset" }
if ($HasHalf -eq 1) { $Bar += "$BarColor$([char]0x25D0)$Reset" }
for ($i = 0; $i -lt $Empty; $i++) { $Bar += "$Dim$([char]0x25CF)$Reset" }

# ── Duration ──────────────────────────────────────────────────
# Status: DISABLED (mirrors cc-statusline.sh) — not rendered on any line.
# Consumes: DurationMs (also consumed by L3 api-wait % below — keep extraction).
# $Dur = Format-Duration $DurationMs

# ── Git file stats (M/A/D counts + working-tree line diff) ────
$GitM = 0; $GitA = 0; $GitD = 0; $GitLinesAdd = 0; $GitLinesDel = 0; $GitCommit = ''
if ($IsGit) {
    $GitM = @(& git diff --name-only 2>$null).Count
    $GitA = @(& git ls-files --others --exclude-standard 2>$null).Count
    $GitD = @(& git diff --diff-filter=D --name-only 2>$null).Count
    $shortstat = (& git diff HEAD --shortstat 2>$null) -join ' '
    if ($shortstat -match '(\d+) insertion') { $GitLinesAdd = [int]$Matches[1] }
    if ($shortstat -match '(\d+) deletion') { $GitLinesDel = [int]$Matches[1] }
    $GitCommit = (& git rev-parse --short HEAD 2>$null)
}

# ── Cache hit rate ────────────────────────────────────────────
$CacheHit = ''
if ($CacheRead -and $CurInput -and $CurInput -ne 0) {
    $cacheCreateVal = if ($CacheCreate) { [double]$CacheCreate } else { 0 }
    $cacheTotal = [double]$CacheRead + [double]$CurInput + $cacheCreateVal
    if ($cacheTotal -gt 0) {
        $cachePct = [math]::Floor([double]$CacheRead * 100 / $cacheTotal)
        $cacheColor = Get-PctColor (100 - $cachePct)
        $CacheHit = "${Dim}cache${Reset} ${cacheColor}${cachePct}%${Reset}"
    }
}

# ── Login account (from ~/.claude.json) ───────────────────────
$Account = ''
$ClaudeJsonPath = "$HOME/.claude.json"
$AcctName = ''
$AcctEmail = ''
if (Test-Path $ClaudeJsonPath) {
    try {
        $cj = Get-Content $ClaudeJsonPath -Raw | ConvertFrom-Json
        $AcctName = $cj.oauthAccount.displayName
        $AcctEmail = $cj.oauthAccount.emailAddress
    } catch {}
}
$AcctRedacted = ''
if ($AcctEmail) {
    $localPart = $AcctEmail.Split('@')[0]
    $domainPart = $AcctEmail.Substring($localPart.Length + 1)
    $AcctRedacted = "$($localPart.Substring(0, 1))***@$domainPart"
}
if ($AcctName -and $AcctRedacted) {
    $Account = "`u{1F464} ${AcctName} ${Dim}$([char]0x00B7)${Reset} ${Dim}${AcctRedacted}${Reset}"
} elseif ($AcctName) {
    $Account = "`u{1F464} ${AcctName}"
} elseif ($AcctRedacted) {
    $Account = "`u{1F464} ${Dim}${AcctRedacted}${Reset}"
}

# ══════════════════════════════════════════════════════════════
# LINE 1: Model + Context size + Repo + Branch + Lines + Files + Vim + Account
# ══════════════════════════════════════════════════════════════
$L1 = "${Cyan}${Bold}${ModelDisp}${Reset}"
if ($CtxLabel) { $L1 += " $CtxLabel" }
$L1 += "${Sep}${White}${RepoLink}${Reset}"
if ($PwdSubpath) { $L1 += "${Dim}/${PwdSubpath}${Reset}" }

# Consolidated git block: (branch* M A D +N -N) — suppress zero categories
if ($Branch) {
    $BranchParts = $Branch
    if ($GitM -gt 0 -or $GitA -gt 0 -or $GitD -gt 0) { $BranchParts += '*' }
    if ($GitM -gt 0) { $BranchParts += " ${Yellow}${GitM}M${Reset}${Dim}" }
    if ($GitA -gt 0) { $BranchParts += " ${Green}${GitA}A${Reset}${Dim}" }
    if ($GitD -gt 0) { $BranchParts += " ${Red}${GitD}D${Reset}${Dim}" }
    if ($GitLinesAdd -gt 0) { $BranchParts += " ${Green}+${GitLinesAdd}${Reset}${Dim}" }
    if ($GitLinesDel -gt 0) { $BranchParts += " ${Red}-${GitLinesDel}${Reset}${Dim}" }
    $L1 += " ${Dim}(${BranchParts})${Reset}"
}

if ($GitCommit) { $L1 += " ${Dim}@${Reset}${Magenta}${GitCommit}${Reset}" }

if ($VimMode) {
    if ($VimMode -eq 'NORMAL') { $L1 += "${Sep}${Blue}${Bold}NOR${Reset}" }
    else { $L1 += "${Sep}${Green}${Bold}INS${Reset}" }
}

if ($Account) { $L1 += "${Sep}${Account}" }

# ══════════════════════════════════════════════════════════════
# LINE 2: Context bar + Cost + Rate limits (5h & 7d with countdown)
# ══════════════════════════════════════════════════════════════
$CostFmt = '$' + ('{0:F2}' -f [double]$Cost)
$TodayFmt = '$' + ('{0:F2}' -f [double]$TodayCost)
$L2 = "$Bar ${Dim}${Pct}%${Reset}${Sep}${Yellow}${CostFmt}${Reset} ${Dim}(today ${TodayFmt})${Reset}"

if ($Rate5h) {
    $R5Int = [math]::Round([double]$Rate5h, [MidpointRounding]::AwayFromZero)
    $R5Color = Get-PctColor $R5Int
    $L2 += "${Sep}${Dim}5h${Reset} ${R5Color}${R5Int}%${Reset}"
    if ($Reset5h) {
        $R5Cd = Format-Countdown $Reset5h
        $L2 += " ${Dim}(${R5Cd})${Reset}"
    }
}

if ($Rate7d) {
    $R7Int = [math]::Round([double]$Rate7d, [MidpointRounding]::AwayFromZero)
    $R7Color = Get-PctColor $R7Int
    $L2 += "${Sep}${Dim}7d${Reset} ${R7Color}${R7Int}%${Reset}"
    if ($Reset7d) {
        $R7Cd = Format-Countdown $Reset7d
        $L2 += " ${Dim}(${R7Cd})${Reset}"
    }
}

# ══════════════════════════════════════════════════════════════
# LINE 3: Cache hit rate + Tokens + API wait + session lines + tools
# ══════════════════════════════════════════════════════════════
$L3 = ''
if ($CacheHit) { $L3 = $CacheHit }

$InFmt = Format-Tokens $TotalInTokens
$OutFmt = Format-Tokens $TotalOutTokens
$TokensPart = "${Dim}in:${Reset} ${Cyan}${InFmt}${Reset} ${Dim}out:${Reset} ${Magenta}${OutFmt}${Reset}"
if ($L3) { $L3 = "${L3}${Sep}${TokensPart}" } else { $L3 = $TokensPart }

# Burn rate: DISABLED (mirrors cc-statusline.sh). Consumes DurationMs/TotalInTokens/
# TotalOutTokens, all already extracted above for active blocks — do not remove them.
# $TotalTok = [double]$TotalInTokens + [double]$TotalOutTokens
# $BurnRate = $TotalTok * 60000 / $DurationMs
# $L3 += "${Sep}${Dim}burn${Reset} ${Yellow}$(Format-Tokens $BurnRate)/min${Reset}"

$ApiDur = Format-Duration $ApiDurationMs
if ($DurationMs -gt 0 -and $ApiDurationMs -gt 0) {
    $ApiPct = [math]::Floor([double]$ApiDurationMs * 100 / [double]$DurationMs)
    $L3 += "${Sep}${Dim}api wait${Reset} ${Cyan}${ApiDur}${Reset} ${Dim}(${ApiPct}%)${Reset}"
} else {
    $L3 += "${Sep}${Dim}api wait${Reset} ${Cyan}${ApiDur}${Reset}"
}

# Session-cumulative line diff (from cost.total_lines_*) — distinct from the
# git working-tree +N/-N inside the L1 parens; this is monotonic across the session.
$SessionLinesPart = ''
if ($LinesAdd) { $SessionLinesPart = "${Green}+${LinesAdd}${Reset}" }
if ($LinesDel) {
    if ($SessionLinesPart) { $SessionLinesPart = "${SessionLinesPart} ${Red}-${LinesDel}${Reset}" } else { $SessionLinesPart = "${Red}-${LinesDel}${Reset}" }
}
if ($SessionLinesPart) { $L3 += "${Sep}${SessionLinesPart} ${Dim}lines${Reset}" }

if ($RunningToolCount -gt 0) { $L3 += "${Sep}${Dim}tools${Reset} ${Yellow}${RunningTools}${Reset}" }

# Current token detail — DISABLED (mirrors cc-statusline.sh).
# $L3 += "${Sep}${Dim}cur${Reset} $(Format-Tokens $CurInput) ${Dim}in${Reset} $(Format-Tokens $CacheRead) ${Dim}read${Reset} $(Format-Tokens $CacheCreate) ${Dim}write${Reset}"

# ══════════════════════════════════════════════════════════════
# LINE 4: Live activity — todos + last prompt (conditionally printed)
# ══════════════════════════════════════════════════════════════
$L4 = ''
function Add-L4Part {
    param([string]$Text)
    if ($script:L4) { $script:L4 = "${script:L4}${Sep}$Text" } else { $script:L4 = $Text }
}

if ($TodoTotal -gt 0) {
    $TodoPart = "${Cyan}todos ${TodoDone}/${TodoTotal}${Reset}"
    if ($TodoCurrent) {
        $trunc = if ($TodoCurrent.Length -gt 40) { $TodoCurrent.Substring(0, 40) } else { $TodoCurrent }
        $TodoPart += " ${Dim}${trunc}${Reset}"
    }
    Add-L4Part $TodoPart
}
if ($LastPrompt) {
    $PromptPart = ''
    if ($LastPromptTime) { $PromptPart = "${Dim}${LastPromptTime}${Reset} " }
    $PromptPart += "${Dim}$([char]0x276F)${Reset} ${LastPrompt}"
    Add-L4Part $PromptPart
}

# ── Subagent dispatch lines ────────────────────────────────────
# Up to 3 most-recent agents, one per line. Half-circle = running, check = completed.
$AgentLines = @()
foreach ($ag in $AgentsWithStatus) {
    if (-not $ag.Type) { continue }
    $icon = if ($ag.Status -eq 'running') { "${Yellow}$([char]0x25D0)${Reset}" } else { "${Green}$([char]0x2713)${Reset}" }
    $descTrunc = if ($ag.Description -and $ag.Description.Length -gt 60) { $ag.Description.Substring(0, 60) } elseif ($ag.Description) { $ag.Description } else { '' }
    $AgentLines += "$icon ${Magenta}$($ag.Type)${Reset}: ${Dim}${descTrunc}${Reset}"
}

# ── Output ────────────────────────────────────────────────────
Write-Output $L1
Write-Output $L2
Write-Output $L3
if ($AgentLines.Count -gt 0) { $AgentLines | ForEach-Object { Write-Output $_ } }
if ($L4) { Write-Output $L4 }

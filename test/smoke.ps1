#!/usr/bin/env pwsh
#Requires -Version 7.0
# Smoke test for cc-statusline.ps1 — PowerShell counterpart of smoke.sh.
# Runs the script against test/sample.json and asserts structural markers.
# Exits 0 on pass, 1 on fail.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
$Script = Join-Path $Root 'cc-statusline.ps1'
$Sample = Join-Path $ScriptDir 'sample.json'

# The script reads [Console]::In, which only sees piped stdin when pwsh is
# spawned as a real child process (matching how Claude Code invokes it) —
# `& $Script` in-process does NOT redirect Console.In, so shell out properly.
$PwshExeName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
$PwshExe = Join-Path $PSHOME $PwshExeName

# Inherited from the developer's own shell, these rewrite the window label and
# would make every other assertion depend on their environment. Claude Code
# exports both when the user sets them in settings.json, so a developer running
# this suite from inside a session hits it without touching a shell at all.
Remove-Item Env:\CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -ErrorAction SilentlyContinue
Remove-Item Env:\CLAUDE_CODE_AUTO_COMPACT_WINDOW -ErrorAction SilentlyContinue
Remove-Item Env:\CC_STATUSLINE_FORGE -ErrorAction SilentlyContinue
Remove-Item Env:\CC_STATUSLINE_WEB_PORT -ErrorAction SilentlyContinue

$Pass = 0
$Fail = 0
function Test-Check {
    param([string]$Name, [bool]$Cond)
    if ($Cond) {
        Write-Output "  [PASS] $Name"
        $script:Pass++
    } else {
        Write-Output "  [FAIL] $Name"
        $script:Fail++
    }
}

Write-Output "Running cc-statusline.ps1 against test/sample.json..."
$out = Get-Content -Raw $Sample | & $PwshExe -NoProfile -File $Script
$plain = ($out -join "`n") -replace "`e\[[0-9;]*[a-zA-Z]", '' -replace "`e\]8;;[^`a]*`a", ''

Write-Output ""
Write-Output "Output (plain):"
($plain -split "`n") | ForEach-Object { Write-Output "  | $_" }
Write-Output ""

Test-Check "non-empty output" (-not [string]::IsNullOrEmpty($out))
Test-Check "at least 3 lines" (($plain -split "`n").Count -ge 3)
Test-Check "contains model name" ($plain -match 'Opus 4\.7')
Test-Check "contains 1M context label" ($plain -match '1M')
Test-Check "version hidden" (-not ($plain -match 'v1\.2\.3'))
Test-Check "contains session cost" ($plain -match '\$1\.23')
Test-Check "contains today cost label" ($plain -match '\(today \$')
Test-Check "contains 5h rate limit" ($plain -match '5h 23%')
Test-Check "contains 7d rate limit" ($plain -match '7d 57%')

# ── Countdown day unit ────────────────────────────────────────
# Mirrors smoke.sh. The 7d window resets up to 168h out, so its countdown has to
# read "2d 13h" rather than "61h 44m". Both cases are pinned relative to now: the
# sample's fixed resets_at sits in 2286, which proves the day branch renders and
# nothing else about what it renders.
function Get-Countdown7d {  # $Offset = seconds from now; returns the 7d group from L2
    param([int64]$Offset)
    $json = Get-Content -Raw $Sample | ConvertFrom-Json
    $json.rate_limits.seven_day.resets_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $Offset
    $o = ($json | ConvertTo-Json -Depth 10) | & $PwshExe -NoProfile -File $Script
    $p = ($o -join "`n") -replace "`e\[[0-9;]*[a-zA-Z]", '' -replace "`e\]8;;[^`a]*`a", ''
    if ($p -match '7d 57% \([^)]*\)') { return $Matches[0] }
    return ''
}
# The reported symptom. Operand order is load-bearing — swapped, this reads "13d 2h".
Test-Check "(countdown) 61h44m reads 2d 13h" ((Get-Countdown7d 222240) -eq '7d 57% (2d 13h)')
# Just past the inclusive boundary: pins the "1d 0h" spelling against "24h 0m".
Test-Check "(countdown) 24h+1m reads 1d 0h" ((Get-Countdown7d 86460) -eq '7d 57% (1d 0h)')
Test-Check "contains in/out tokens" (($plain -match 'in: 123\.4K') -and ($plain -match 'out: 7\.8K'))
Test-Check "contains api wait line" ($plain -match 'api wait')
Test-Check "contains cache hit %" ($plain -match 'cache 97%')
Test-Check "contains vim NORMAL marker" ($plain -match 'NOR')

# ── Second pass: with a real transcript that has active agents/tools/todos ──
Write-Output ""
Write-Output "Running with active transcript (agents/tools/todos)..."
$TranscriptTmp = [System.IO.Path]::GetTempFileName()
try {
    @'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"subagent_type":"reviewer-opus-high"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"/tmp/x"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_todo","name":"TodoWrite","input":{"todos":[{"content":"first","status":"completed"},{"content":"second","status":"in_progress"}]}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_todo","content":"ok"}]}}
'@ | Set-Content -Path $TranscriptTmp -NoNewline

    $sampleObj = Get-Content -Raw $Sample | ConvertFrom-Json
    $sampleObj.transcript_path = $TranscriptTmp
    $out2 = ($sampleObj | ConvertTo-Json -Depth 10) | & $PwshExe -NoProfile -File $Script
    $plain2 = ($out2 -join "`n") -replace "`e\[[0-9;]*[a-zA-Z]", '' -replace "`e\]8;;[^`a]*`a", ''

    Write-Output "Output (plain, with transcript):"
    ($plain2 -split "`n") | ForEach-Object { Write-Output "  | $_" }
    Write-Output ""

    Test-Check "(active) contains agents indicator" ($plain2 -match '[◐✓] reviewer-opus-high')
    Test-Check "(active) contains tools indicator" ($plain2 -match 'tools Read')
    Test-Check "(active) contains todos progress" ($plain2 -match 'todos 1/2')
    Test-Check "(active) contains current todo" ($plain2 -match 'second')
} finally {
    Remove-Item -Path $TranscriptTmp -ErrorAction SilentlyContinue
}

# ── Third pass: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE ────────────────────────────
# The bar divides by the override'd budget, so a wrong parse is invisible in the
# label but silently wrong in the %; both are asserted.
Write-Output ""
Write-Output "Running auto-compact percentage override cases..."
$Bullet = [char]0x25CF
function Get-WindowLabel {
    param([string]$Value)   # 'UNSET' = variable removed, not set to ''
    if ($Value -eq 'UNSET') {
        Remove-Item Env:\CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -ErrorAction SilentlyContinue
    } else {
        $env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = $Value
    }
    try {
        $o = Get-Content -Raw $Sample | & $PwshExe -NoProfile -File $Script
        $p = ($o -join "`n") -replace "`e\[[0-9;]*[a-zA-Z]", '' -replace "`e\]8;;[^`a]*`a", ''
        $lines = $p -split "`n"
        $win = if ($lines[0] -match '\(M\) ([^|]*) \|') { $Matches[1] } else { '?' }
        $bar = if ($lines[1] -match "[$Bullet ] ([0-9]+%)") { $Matches[1] } else { '?' }
        "$win $bar"
    } finally {
        Remove-Item Env:\CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -ErrorAction SilentlyContinue
    }
}

$Dot = [char]0x00B7
Test-Check "(pct) unset -> window less reserve"  ((Get-WindowLabel 'UNSET') -eq '987K 5%')
Test-Check "(pct) set-but-empty -> same as unset" ((Get-WindowLabel '') -eq '987K 5%')
Test-Check "(pct) 50 -> halved budget, 10%"      ((Get-WindowLabel '50') -eq "500K (1M${Dot}50%) 10%")
Test-Check "(pct) decimals kept"                 ((Get-WindowLabel '33.3') -eq "333K (1M${Dot}33.3%) 15%")
Test-Check "(pct) label normalised"              ((Get-WindowLabel '33.30') -eq "333K (1M${Dot}33.3%) 15%")
Test-Check "(pct) non-numeric ignored"           ((Get-WindowLabel 'abc') -eq '987K 5%')
Test-Check "(pct) out of range ignored"          ((Get-WindowLabel '150') -eq '987K 5%')
# Boundaries where a truncate-then-range-check gets it wrong; both scripts must
# agree on every one of them.
Test-Check "(pct) 100 -> reserve still binds"    ((Get-WindowLabel '100') -eq "987K (1M${Dot}100%) 5%")
Test-Check "(pct) just over 100 ignored"         ((Get-WindowLabel '100.004') -eq '987K 5%')
Test-Check "(pct) tiny fraction still applies"   ((Get-WindowLabel '0.001') -eq "0K (1M${Dot}0.001%) 100%")
Test-Check "(pct) zero ignored"                  ((Get-WindowLabel '0') -eq '987K 5%')
Test-Check "(pct) parseFloat prefix accepted"    ((Get-WindowLabel '50abc') -eq "500K (1M${Dot}50%) 10%")
Test-Check "(pct) exponent notation rejected"    ((Get-WindowLabel '1e2') -eq '987K 5%')
Test-Check "(pct) overlong digit run ignored"    ((Get-WindowLabel '99999999999999999999') -eq '987K 5%')
# The reserve is a fixed token count, so which arm of the CLI's min() binds
# depends on the window. Both arms are exercised here.
Test-Check "(pct) 99 on 1M -> reserve arm wins"  ((Get-WindowLabel '99') -eq "987K (1M${Dot}99%) 5%")
Test-Check "(pct) 98 on 1M -> pct arm wins"      ((Get-WindowLabel '98') -eq "980K (1M${Dot}98%) 5%")

$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = '200000'
try {
    Test-Check "(pct) applies to the ACW window" ((Get-WindowLabel '50') -eq "100K (200K${Dot}50%) 51%")
    Test-Check "(pct) reserve applies to ACW too" ((Get-WindowLabel 'UNSET') -eq '187K 27%')
    Test-Check "(pct) 95 on 200K -> reserve arm" ((Get-WindowLabel '95') -eq "187K (200K${Dot}95%) 27%")
} finally {
    Remove-Item Env:\CLAUDE_CODE_AUTO_COMPACT_WINDOW -ErrorAction SilentlyContinue
}

# A window at or below the reserve has nothing left to divide by; the full
# window stands in rather than a zero or negative budget.
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = '13000'
try {
    Test-Check "(pct) window at the reserve"     ((Get-WindowLabel 'UNSET') -eq '13K 100%')
    # ...and an override on such a window still takes its own arm. The CLI's
    # min() would pick the reserve arm's zero and compact at once; a zero budget
    # is not divisible, so pinning the pct arm pins the deliberate divergence.
    Test-Check "(pct) override on a reserve window" ((Get-WindowLabel '50') -eq "6K (13K${Dot}50%) 100%")
} finally {
    Remove-Item Env:\CLAUDE_CODE_AUTO_COMPACT_WINDOW -ErrorAction SilentlyContinue
}

# -- L1 hyperlink targets, in a throwaway repo -----------------------------
# The URLs live inside OSC 8 sequences, which every other assertion strips, so
# these read the raw output. Mirrors the (link) pass in smoke.sh.
Write-Output ""
Write-Output "Running hyperlink-target cases..."
$RepoTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-statusline-smoke-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $RepoTmp | Out-Null
try {
    Push-Location $RepoTmp
    git init -q -b main . 2>&1 | Out-Null
    git config user.email t@t; git config user.name t
    git commit -q --allow-empty -m one 2>&1 | Out-Null
    git remote add origin placeholder 2>&1 | Out-Null
    Pop-Location

    function Get-BranchLink {   # $Remote, $BranchName -> the last OSC 8 target
        param([string]$Remote, [string]$BranchName)
        Push-Location $RepoTmp
        git remote set-url origin $Remote 2>&1 | Out-Null
        git checkout -q -B $BranchName main 2>&1 | Out-Null
        # The branch link is built only for a branch the remote has, so the
        # scratch repo has to look pushed. Get-LocalBranchLink is the unpushed
        # counterpart.
        git update-ref "refs/remotes/origin/$BranchName" HEAD 2>&1 | Out-Null
        $raw = Get-Content -Raw $Sample | & $PwshExe -NoProfile -File $Script
        Pop-Location
        $line = ($raw -join "`n") -split "`n" | Select-Object -First 1
        $m = [regex]::Matches($line, "`e\]8;;([^`a]*)`a")
        if ($m.Count -eq 0) { return '' }
        return $m[$m.Count - 1].Groups[1].Value
    }

    # A branch the remote never saw filters nothing — a throwaway worktree's
    # local branch is the usual one. Only the repo link is left.
    function Get-LocalBranchLink {  # same, but the branch is never pushed
        param([string]$Remote, [string]$BranchName)
        Push-Location $RepoTmp
        git remote set-url origin $Remote 2>&1 | Out-Null
        git checkout -q -B $BranchName main 2>&1 | Out-Null
        git update-ref -d "refs/remotes/origin/$BranchName" 2>&1 | Out-Null
        $raw = Get-Content -Raw $Sample | & $PwshExe -NoProfile -File $Script
        Pop-Location
        $line = ($raw -join "`n") -split "`n" | Select-Object -First 1
        $m = [regex]::Matches($line, "`e\]8;;([^`a]*)`a")
        if ($m.Count -eq 0) { return '' }
        return $m[$m.Count - 1].Groups[1].Value
    }

    Test-Check "(link) unpushed branch -> repo link only" `
      ((Get-LocalBranchLink 'https://github.com/o/r.git' 'wt-scratch') -eq 'https://github.com/o/r')

    Test-Check "(link) scp remote -> https PR search" `
      ((Get-BranchLink 'git@github.com:o/r.git' 'b') -eq 'https://github.com/o/r/pulls?q=is%3Apr+head%3Ab')
    # An SSH remote is unbrowsable as given; the user and the SSH port are dropped.
    Test-Check "(link) ssh:// remote loses user+port" `
      ((Get-BranchLink 'ssh://git@gitlab.example.com:2222/g/p.git' 'b') -eq 'https://gitlab.example.com/g/p/-/merge_requests?scope=all&state=all&source_branch=b')
    # ...but a port on an https remote is the web UI's own and must survive.
    Test-Check "(link) https port survives" `
      ((Get-BranchLink 'https://10.0.0.1:30001/g/p.git' 'b') -eq 'https://10.0.0.1:30001/g/p/pulls?q=is%3Apr+head%3Ab')
    Test-Check "(link) non-git ssh user rewritten" `
      ((Get-BranchLink 'deploy@git.example.com:g/p.git' 'b') -eq 'https://git.example.com/g/p/pulls?q=is%3Apr+head%3Ab')
    # The forge guess reads the host only: this repo lives on GitHub.
    Test-Check "(link) gitlab in path is not gitlab" `
      ((Get-BranchLink 'https://github.com/gitlab-org/gitlab.git' 'b') -eq 'https://github.com/gitlab-org/gitlab/pulls?q=is%3Apr+head%3Ab')
    Test-Check "(link) mixed-case gitlab host matches" `
      ((Get-BranchLink 'git@GitLab.example.com:g/p.git' 'b') -eq 'https://GitLab.example.com/g/p/-/merge_requests?scope=all&state=all&source_branch=b')
    # Unencoded, the & would append a parameter and the # would truncate the URL.
    Test-Check "(link) branch & and = encoded" `
      ((Get-BranchLink 'https://github.com/o/r.git' 'x&y=z') -eq 'https://github.com/o/r/pulls?q=is%3Apr+head%3Ax%26y%3Dz')
    Test-Check "(link) branch # encoded" `
      ((Get-BranchLink 'https://github.com/o/r.git' 'x#y') -eq 'https://github.com/o/r/pulls?q=is%3Apr+head%3Ax%23y')

    # The SSH port is not the web port; only the user knows which serves the UI.
    $env:CC_STATUSLINE_WEB_PORT = '30001'
    try {
        Test-Check "(link) WEB_PORT added to ssh:// remote" `
          ((Get-BranchLink 'ssh://git@10.0.0.1:30023/g/p.git' 'b') -eq 'https://10.0.0.1:30001/g/p/pulls?q=is%3Apr+head%3Ab')
        Test-Check "(link) WEB_PORT added to scp remote" `
          ((Get-BranchLink 'git@10.0.0.1:g/p.git' 'b') -eq 'https://10.0.0.1:30001/g/p/pulls?q=is%3Apr+head%3Ab')
        # An https remote already carries the web port; don't double it.
        Test-Check "(link) WEB_PORT leaves https remote alone" `
          ((Get-BranchLink 'https://10.0.0.1:8080/g/p.git' 'b') -eq 'https://10.0.0.1:8080/g/p/pulls?q=is%3Apr+head%3Ab')
    } finally {
        Remove-Item Env:\CC_STATUSLINE_WEB_PORT -ErrorAction SilentlyContinue
    }

    # A self-hosted instance whose host names no forge is unreachable by any guess.
    $env:CC_STATUSLINE_FORGE = 'gitlab'
    try {
        Test-Check "(link) FORGE override wins" `
          ((Get-BranchLink 'https://10.0.0.1:30001/g/p.git' 'b') -eq 'https://10.0.0.1:30001/g/p/-/merge_requests?scope=all&state=all&source_branch=b')
    } finally {
        Remove-Item Env:\CC_STATUSLINE_FORGE -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -Recurse -Force $RepoTmp -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output "Result: $Pass passed, $Fail failed."
if ($Fail -eq 0) { exit 0 } else { exit 1 }

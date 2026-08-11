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
} finally {
    Remove-Item Env:\CLAUDE_CODE_AUTO_COMPACT_WINDOW -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output "Result: $Pass passed, $Fail failed."
if ($Fail -eq 0) { exit 0 } else { exit 1 }

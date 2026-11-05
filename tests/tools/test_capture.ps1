#requires -Version 7.0
param([ValidateSet('', 'Emit', 'Failure', 'Hang')][string] $Probe = '')
$ErrorActionPreference = 'Stop'
if ($Probe) {
    if ($Probe -eq 'Hang') { Start-Sleep -Seconds 60; exit 0 }
    $p = [Diagnostics.Process]::GetCurrentProcess()
    $bits = 0
    for ($i = 0; $i -lt 63; $i++) {
        if ($p.ProcessorAffinity.ToInt64() -band ([long]1 -shl $i)) { $bits++ }
    }
    if ($p.PriorityClass -ne 'BelowNormal' -or $bits -gt 2) { exit 98 }
    [Console]::WriteLine('Test #0 sample.first changed state to Running.')
    [Console]::Out.Flush()
    Start-Sleep -Milliseconds 80
    [Console]::WriteLine('[AIO-FIXTURE] sample setup 12.500 2 3')
    [Console]::Error.WriteLine('stderr receipt')
    $state = if ($Probe -eq 'Failure') { 'Failed' } else { 'Successful' }
    [Console]::WriteLine("Test #0 sample.first changed state to $state.")
    if ($Probe -eq 'Failure') { exit 7 }
    exit 0
}
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/tools/test-budget.ps1"
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw $Message } }
$directory = Join-Path ([IO.Path]::GetTempPath()) ('aio-cost-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $directory | Out-Null
$budget = Enter-TestBudget
Push-Location $directory
try {
    $shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    foreach ($mode in @('Emit', 'Failure', 'Hang')) {
        $log = Join-Path $directory "$mode.log"
        $timeout = if ($mode -eq 'Hang') { 1 } else { 10 }
        $code = Invoke-TestCommand $shell @('-NoLogo', '-NoProfile', '-File', $PSCommandPath, '-Probe', $mode) `
            $timeout (Split-Path $log -Leaf)
        $expected = switch ($mode) { 'Emit' {0}; 'Failure' {7}; 'Hang' {124} }
        Assert-True ($code -eq $expected) "Capture preserves $mode result"
        if ($mode -eq 'Hang') { continue }
        $cost = Get-Content -LiteralPath "$log.costs.json" -Raw | ConvertFrom-Json
        Assert-True ($cost.Tests.Count -eq 1) 'One timing per completed test'
        Assert-True ($cost.Tests[0].ObservedMilliseconds -ge 20) 'Observe an actual elapsed interval'
        Assert-True ($cost.Fixtures[0].Windows -eq 2 -and $cost.Fixtures[0].Sessions -eq 3) 'Fixture counts survive capture'
        Assert-True ($cost.Fixtures[0].Milliseconds -eq 12.5) 'Direct fixture timing survives capture'
        Assert-True (Select-String -LiteralPath $log -SimpleMatch 'stderr receipt' -Quiet) 'Drain stderr as well as stdout'
    }
} finally {
    Pop-Location
    Exit-TestBudget $budget
    Get-ChildItem -LiteralPath $directory -File | Remove-Item -Force
    Remove-Item -LiteralPath $directory
}
'PASS timing capture: scheduling limits, test/fixture receipts, exit failures and bounded timeout'

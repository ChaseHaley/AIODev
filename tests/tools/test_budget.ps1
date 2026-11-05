#requires -Version 7.0
param([ValidateSet('', 'busy', 'inherit', 'fail', 'hang', 'sleep')][string] $Probe = '', [string] $PidFile)
$ErrorActionPreference = 'Stop'
$repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repository 'tools/test-budget.ps1')
$shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
switch ($Probe) {
    'busy' {
        try { $other = Enter-TestBudget; Exit-TestBudget $other; exit 99 }
        catch { if ($_.Exception.Message -like 'Another AIODev test run*') { exit 23 }; throw }
    }
    'inherit' {
        $p = [Diagnostics.Process]::GetCurrentProcess()
        $mask = $p.ProcessorAffinity.ToInt64()
        $bits = 0
        for ($i = 0; $i -lt 63; $i++) { if ($mask -band ([long]1 -shl $i)) { $bits++ } }
        if ($bits -gt 2 -or $p.PriorityClass -ne 'BelowNormal') { exit 98 }
        exit 0
    }
    'fail' { exit 7 }
    'hang' {
        $child = Start-Process -FilePath $shell -WindowStyle Hidden -PassThru -ArgumentList (
            '-NoLogo -NoProfile -File "' + $PSCommandPath + '" -Probe sleep')
        [IO.File]::WriteAllText($PidFile, [string]$child.Id)
        Start-Sleep -Seconds 60
        exit 0
    }
    'sleep' { Start-Sleep -Seconds 60; exit 0 }
}
function Assert-True($Value, [string] $Message) {
    if (-not $Value) { throw $Message }
}
function Run-Probe([string] $Mode, [int] $Timeout = 10, [string] $PidPath = '') {
    $arguments = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath, '-Probe', $Mode)
    if ($PidPath) { $arguments += @('-PidFile', $PidPath) }
    Invoke-TestCommand $shell $arguments $Timeout
}

$hostProcess = [Diagnostics.Process]::GetCurrentProcess()
$affinity, $priority = $hostProcess.ProcessorAffinity, $hostProcess.PriorityClass
$budget = Enter-TestBudget
try {
    Assert-True ((Run-Probe busy) -eq 23) 'A competing process must fail fast before starting tests'
    Assert-True ((Run-Probe inherit) -eq 0) 'Children must inherit two CPUs maximum and below-normal priority'
    Assert-True ((Run-Probe fail) -eq 7) 'Preserve command failures'
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('aio-budget-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $directory | Out-Null
    try {
        $pidFile = Join-Path $directory 'child.pid'
        Assert-True ((Run-Probe hang 3 $pidFile) -eq 124) 'Hung commands must time out'
        Assert-True (Test-Path -LiteralPath $pidFile) 'Timeout fixture must start its descendant'
        $descendantId = [int](Get-Content -LiteralPath $pidFile)
        Assert-True (-not (Get-Process -Id $descendantId -ErrorAction SilentlyContinue)) 'Timeout must stop descendants'
    } finally {
        if ($descendantId -and (Get-Process -Id $descendantId -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $descendantId -Force
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $directory -Force
    }
} finally {
    Exit-TestBudget $budget
}
Assert-True ($hostProcess.ProcessorAffinity -eq $affinity) 'Restore caller affinity'
Assert-True ($hostProcess.PriorityClass -eq $priority) 'Restore caller priority'
$again = Enter-TestBudget
Exit-TestBudget $again
'PASS test budget: exclusion, inherited CPU limits, failure propagation, timeout tree cleanup, restoration and reacquisition'

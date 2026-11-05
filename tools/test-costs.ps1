[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidatePattern('^[a-z_-]+$')]
    [string] $Package = 'app'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$path = Join-Path $root "build/test/$Package.output.log.costs.json"
$cost = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
Write-Output 'Test durations are observed runner-state intervals, not CPU time.'
$cost.Tests | Sort-Object ObservedMilliseconds -Descending | Select-Object -First 15 Test, State,
    @{Name='ObservedMs'; Expression={[math]::Round($_.ObservedMilliseconds, 3)}} | Format-Table -AutoSize
if ($cost.Fixtures.Count) {
    Write-Output 'Shared palette fixture samples: direct elapsed time and window/session snapshots.'
    $cost.Fixtures | Group-Object Phase | ForEach-Object {
        [pscustomobject]@{Phase=$_.Name; Samples=$_.Count;
            TotalMs=[math]::Round(($_.Group.Milliseconds | Measure-Object -Sum).Sum, 3)}
    } | Format-Table -AutoSize
    $cost.Fixtures | Sort-Object Milliseconds -Descending |
        Select-Object -First 10 Name, Phase, Milliseconds, Windows, Sessions | Format-Table -AutoSize
}

#requires -Version 7.0
# Runs live journeys by lane (tests/live/lanes.json) and prints one line per journey, then a summary.
#   pwsh -NoProfile -File tests/live/run.ps1                       every headless journey
#   pwsh -NoProfile -File tests/live/run.ps1 -Lane native          the native lane, on the real desktop
#   pwsh -NoProfile -File tests/live/run.ps1 -Journeys a,b         named journeys, each in its own lane
# Headless journeys launch build\headless\aiodev-headless.exe through AIOCTL_HEADLESS=1 and draw nothing on
# the desktop. Journeys run one at a time; each owns its instance name. Build with build.ps1 verify first.
[CmdletBinding()]
param(
    [ValidateSet('headless', 'native', 'all')] [string] $Lane = 'headless',
    [string[]] $Journeys = @(),
    [int] $TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'lanes.json') -Raw | ConvertFrom-Json
$lanes = @{}
foreach ($entry in $manifest.journeys.PSObject.Properties) {
    if ($entry.Value.lane -notin @('headless', 'native', 'helper')) { throw "$($entry.Name): unknown lane $($entry.Value.lane)" }
    if ($entry.Value.lane -ne 'headless' -and -not "$($entry.Value.reason)".Trim()) { throw "$($entry.Name) gives no reason" }
    $lanes[$entry.Name] = $entry.Value.lane
}
$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File | Where-Object Name -ne 'run.ps1' |
    ForEach-Object BaseName)
$unlisted = @($files | Where-Object { -not $lanes.ContainsKey($_) })
if ($unlisted) { throw "tests/live/lanes.json does not list: $($unlisted -join ', ')" }
$stale = @($lanes.Keys | Where-Object { $_ -notin $files })
if ($stale) { throw "tests/live/lanes.json lists missing journeys: $($stale -join ', ')" }

$requested = @($Journeys | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$selected = if ($requested) {
    foreach ($name in $requested) {
        if (-not $lanes.ContainsKey($name)) { throw "no journey named $name" }
        if ($lanes[$name] -eq 'helper') { throw "$name is a helper, not a journey" }
        $name
    }
} else {
    @($files | Where-Object { $lanes[$_] -ne 'helper' -and ($Lane -eq 'all' -or $lanes[$_] -eq $Lane) } | Sort-Object)
}
$logs = Join-Path $repo 'build/journeys'
New-Item -ItemType Directory -Force $logs | Out-Null
$failed = @()
foreach ($name in $selected) {
    $env:AIOCTL_HEADLESS = if ($lanes[$name] -eq 'headless') { '1' } else { '' }
    $log = Join-Path $logs "$name.log"
    $started = Get-Date
    $process = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $PSScriptRoot "$name.ps1")) `
        -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $seconds = { [int]((Get-Date) - $started).TotalSeconds }
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process | Stop-Process -Force
        $failed += $name
        "$($lanes[$name]) $name TIMEOUT after $(& $seconds)s; log $log"
        continue
    }
    if ($process.ExitCode -eq 0) {
        "$($lanes[$name]) $name PASS $(& $seconds)s"
    } else {
        $failed += $name
        $last = @(Get-Content "$log.err", $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' } |
            Select-Object -Last 1)
        "$($lanes[$name]) $name FAIL($($process.ExitCode)) $(& $seconds)s: $last"
    }
}
$env:AIOCTL_HEADLESS = ''
"journeys: $($selected.Count) run, $($selected.Count - $failed.Count) passed, $($failed.Count) failed"
if ($failed) { "failed: $($failed -join ', ')"; exit 1 }

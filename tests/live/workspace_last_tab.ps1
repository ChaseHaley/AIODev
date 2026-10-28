[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'workspace-last-tab'
$directory = Join-Path $repo "build/verify/$name"

function Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function State {
    $state = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Equal($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Current-Rail {
    $s = State
    Equal $s['rail.rows'] $s['tabs.count'] 'rail contains exactly the current workspace tabs'
    for ($row = 1; $row -le [int]$s['rail.rows']; $row++) {
        Equal $s["rail.row.$row.kind"] tab 'rail has no workspace root'
        Equal $s["rail.row.$row.workspace"] $s['workspace.id'] 'rail excludes foreign tabs'
    }
}
function Click([string] $Rect) {
    $r = $Rect -split ','
    $x = [int]([double]$r[0] + [double]$r[2] / 2)
    $y = [int]([double]$r[1] + [double]$r[3] / 2)
    Aio mouse click "$x,$y" --px | Out-Null
}
function Await-Exit([System.Diagnostics.Process] $Process) {
    if (-not $Process.WaitForExit(5000)) { throw 'AIODev remained running after its last tab closed' }
    Equal $Process.ExitCode 0 'the last tab fully exits the process successfully'
}

Aio launch --fresh | Out-Null
try {
    Aio key Ctrl+Shift+L | Out-Null
    $initial = State
    $process = Get-Process -Id ([int]$initial['app.pid'])
    $null = $process.Handle
    $window = $initial['window.id']
    $workspace = $initial['workspace.id']
    $session = $initial['session.id']
    Aio command workspace.new | Out-Null
    Aio command tab.new | Out-Null
    Current-Rail
    Aio command tab.close | Out-Null
    $s = State
    Equal $s['workspaces.count'] 2 'closing a nonfinal tab keeps its workspace'
    Click $s['tab.1.close']
    $s = State
    Equal $s['workspaces.count'] 1 'closing the last tab deletes its workspace'
    Equal $s['window.id'] $window 'fallback reuses the same window'
    Equal $s['workspace.id'] $workspace 'fallback selects the existing workspace'
    Equal $s['session.id'] $session 'fallback preserves the existing runtime'
    Current-Rail
    Aio command window.new | Out-Null
    $s = State
    Aio window select $s['window.2.id'] | Out-Null
    Aio command tab.close | Out-Null
    $s = State
    Equal $s['windows.count'] 1 'an already displayed fallback keeps only its existing window'
    Equal $s['workspaces.count'] 1 'owned fallback creates no replacement workspace'
    Equal $s['workspace.id'] $workspace 'owned fallback keeps the original workspace'
    Aio tray hide | Out-Null
    Equal (State)['windows.count'] 0 'hiding a window preserves live work in the tray'
    Aio tray open | Out-Null
    Equal (State)['workspace.id'] $workspace 'tray reopen restores live work'
    $path = Join-Path $directory 'settings.ini'
    [IO.File]::AppendAllText($path, "`ntabs.vertical_scope = all`n")
    Aio command settings.reload | Out-Null
    Current-Rail
    Aio state | Set-Content -LiteralPath (Join-Path $directory 'current-workspace-state.txt')
    & "$repo/tools/win32.ps1" -Name $name -Frame -Shot (Join-Path $directory 'current-workspace.png') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed' }
    Aio command tab.close | Out-Null
    Await-Exit $process
    Aio launch | Out-Null
    $fresh = State
    $process = Get-Process -Id ([int]$fresh['app.pid'])
    $null = $process.Handle
    Equal $fresh['workspaces.count'] 1 'relaunch creates one fresh workspace'
    Equal $fresh['tabs.count'] 1 'relaunch has no deleted tabs to restore'
    Equal $fresh['tabs.orientation'] horizontal 'relaunch uses the horizontal default'
    Aio key Ctrl+Shift+W | Out-Null
    Await-Exit $process
} finally {
    if ($process -and -not $process.HasExited) { & $ctl --name $name stop | Out-Null }
}

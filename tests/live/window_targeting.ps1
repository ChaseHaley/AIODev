param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'window-targeting'

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $out) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}

Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    $initial = Read-State
    $windowId = $initial['window.id']
    $session = $initial['session.id']
    Invoke-Aio expect state windows.count=1
    Invoke-Aio expect state window.workspace_index=1
    Invoke-Aio expect state "window.1.id=$windowId"
    Invoke-Aio window select $windowId
    Invoke-Aio window move '-80,100'
    $moved = Read-State
    $origin = $moved['window.1.origin'] -split ','
    if ([int]$origin[0] -ge 0) { throw 'Window client origin did not preserve negative screen X.' }
    Invoke-Aio expect state "window.id=$windowId"
    Invoke-Aio command settings.open
    Invoke-Aio command tab.select_1
    $tabs = Read-State
    $x = [int]$origin[0] + [int](1.5 * [double]$tabs['tabs.width'])
    $y = [int]$origin[1] + [int](0.5 * [double]$tabs['tabs.height'])
    Invoke-Aio mouse click "$x,$y" --screen
    Invoke-Aio expect state settings.active=true
    Invoke-Aio expect state tabs.selected=2
    Invoke-Aio command tab.select_1
    Invoke-Aio mouse move '-300,-200' --screen
    Invoke-Aio window move '120,120'
    Invoke-Aio expect state "session.id=$session"
    $invalid = & $ctl --name $name window select 18446744073709551615
    if ($LASTEXITCODE -ne 1) { throw "Unknown target did not fail safely: $invalid" }
    Invoke-Aio expect state "window.id=$windowId"
    Invoke-Aio tray hide
    Invoke-Aio expect state windows.count=0
    Invoke-Aio expect state window.id=0
    Invoke-Aio tray open
    Invoke-Aio expect state windows.count=1
    $reopened = Read-State
    if ($reopened['window.id'] -eq $windowId) { throw 'Destroyed target was reused.' }
    Invoke-Aio expect state "session.id=$session"
    Invoke-Aio window select $reopened['window.id']
    Write-Output 'PASS window target persists, screen mouse selects a tab, movement is signed, and destruction falls back'
} finally {
    Invoke-Aio stop
}

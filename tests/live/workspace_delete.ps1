param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'workspace-delete'
$directory = Join-Path $repo "build/verify/$name"

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
function Request-Row([string] $WorkspaceName) {
    Invoke-Aio command workspace.change
    Invoke-Aio type $WorkspaceName
    Invoke-Aio key Shift+Delete
    Invoke-Aio expect state confirm.open=true
    Invoke-Aio expect state workspace.picker=false
}
function Shot([string] $Label) {
    & "$repo/tools/win32.ps1" -Name $name -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}

Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    $initial = Read-State
    $firstWindow = $initial['window.id']
    $firstSession = $initial['session.id']
    Invoke-Aio run '$global:deleteMarker = "UNRELATED_" + "SURVIVED"'
    Invoke-Aio command workspace.new
    Invoke-Aio expect state workspaces.count=2
    Invoke-Aio expect state sessions.count=2
    Request-Row 'Workspace 1'
    Invoke-Aio expect state confirm.workspace=1
    Invoke-Aio expect state 'confirm.body=Close 1 tabs (1 panes); stop 1 sessions.'
    Shot hidden-target-confirm
    Invoke-Aio key Esc
    Invoke-Aio expect state confirm.open=false
    Invoke-Aio expect state workspaces.count=2
    Invoke-Aio expect state sessions.count=2
    Invoke-Aio expect state workspace.id=2

    Invoke-Aio command window.new
    $secondWindow = (Read-State)['window.id']
    if ($secondWindow -eq $firstWindow) { throw 'New Window did not create a separate owner.' }
    Invoke-Aio window select $firstWindow
    Request-Row 'Workspace 3'
    Invoke-Aio expect state confirm.workspace=3
    Invoke-Aio key Enter
    Invoke-Aio expect state workspaces.count=2
    Invoke-Aio expect state sessions.count=2
    Invoke-Aio expect state windows.count=2
    Invoke-Aio expect state workspace.id=2
    Invoke-Aio window select $secondWindow
    Invoke-Aio expect state workspace.id=1
    Invoke-Aio expect state "session.id=$firstSession"
    Invoke-Aio run 'Write-Output $global:deleteMarker'
    Invoke-Aio expect text UNRELATED_SURVIVED

    Invoke-Aio window select $firstWindow
    Invoke-Aio command workspace.delete
    Invoke-Aio expect state confirm.workspace=2
    Invoke-Aio key Enter
    Invoke-Aio expect state workspaces.count=2
    Invoke-Aio expect state sessions.count=2
    Invoke-Aio expect state workspace.id=4
    Invoke-Aio expect state "window.id=$firstWindow"
    Invoke-Aio window select $secondWindow
    Invoke-Aio expect state workspace.id=1
    Invoke-Aio expect state "session.id=$firstSession"
    Invoke-Aio tray hide
    Invoke-Aio expect state windows.count=1
    Invoke-Aio expect state sessions.count=2
    Invoke-Aio window select $firstWindow
    Request-Row 'Workspace 1'
    Invoke-Aio key Enter
    Invoke-Aio expect state workspaces.count=1
    Invoke-Aio expect state sessions.count=1
    Invoke-Aio expect state workspace.id=4

    foreach ($dpi in @(96, 144)) {
        Invoke-Aio dpi $dpi
        Invoke-Aio command workspace.delete
        Invoke-Aio expect state confirm.open=true
        Invoke-Aio expect state confirm.workspace=4
        Shot "last-confirm-$dpi"
        Invoke-Aio key Tab
        Invoke-Aio key Enter
        Invoke-Aio expect state confirm.open=false
        Invoke-Aio expect state workspace.id=4
        Invoke-Aio expect state sessions.count=1
    }
    Invoke-Aio command workspace.delete
    Invoke-Aio key Enter
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state workspace.id=5
    Invoke-Aio expect state workspaces.count=1
    Invoke-Aio expect state sessions.count=1
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state windows.count=1
    Invoke-Aio expect state "window.id=$firstWindow"
    Write-Output 'PASS hidden, foreign-owner, current and last workspace deletion preserve unrelated runtime and window ownership'
} finally {
    Invoke-Aio stop
}

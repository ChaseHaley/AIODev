[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'settings-ui'
$path = Join-Path $repo "build/verify/$name/settings.ini"

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}

function Read-State {
    $result = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $result) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1]
    }
    return $state
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

function Open-Field([string] $Key) {
    if ((Read-State)['settings.open'] -eq 'true') { Invoke-Aio key Esc }
    Invoke-Aio key 'Ctrl+,'
    Invoke-Aio type $Key
    Assert-Value (Read-State)['settings.key'] $Key "select $Key"
    Invoke-Aio key Tab
}

function Save-Value([string] $Value) {
    Invoke-Aio key Ctrl+A
    Invoke-Aio type $Value
    Invoke-Aio key Enter
}

Invoke-Aio launch --fresh
try {
    $originalSession = (Read-State)['session.id']
    Open-Field font.size
    Save-Value 14
    Assert-Value (Read-State)['settings.error'] 'false' 'valid font applied'
    $saved = [IO.File]::ReadAllText($path)
    if ($saved -notmatch '(?m)^font.size = 14$') { throw 'Font size not persisted.' }
    Save-Value 0
    Assert-Value (Read-State)['settings.error'] 'true' 'out of range rejected'
    Assert-Value ([IO.File]::ReadAllText($path)) $saved 'invalid edit preserves file'
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 18
    Invoke-Aio key Esc
    Assert-Value ([IO.File]::ReadAllText($path)) $saved 'cancel preserves file'

    Open-Field font.size
    Invoke-Aio key Ctrl+R
    Assert-Value (Read-State)['settings.value'] '12' 'reset saves schema default'
    [IO.File]::AppendAllText($path, "`n# external comment`nfuture.key = retained`n")
    $external = [IO.File]::ReadAllText($path)
    Save-Value 13
    Assert-Value (Read-State)['settings.error'] 'true' 'external edit conflict reported'
    Assert-Value ([IO.File]::ReadAllText($path)) $external 'external edit preserved'

    Open-Field window.show_tab_bar_with_one_tab
    Save-Value false
    $state = Read-State
    Assert-Value $state['settings.error'] 'false' 'boolean saved despite unrelated unknown key'
    Assert-Value ($state['pane.0.rect'] -split ',')[1] '0' 'tab bar updates live'
    if ([IO.File]::ReadAllText($path) -notlike '*# external comment*future.key = retained*') {
        throw 'Unrelated text was lost.'
    }
    Open-Field shell.directory
    Save-Value $repo
    Assert-Value (Read-State)['session.id'] $originalSession 'shell setting does not restart session'
    if ((Read-State)['settings.message'] -notlike '*new or restarted shells*') { throw 'Missing restart guidance.' }

    Open-Field keys.tab.new
    $beforeConflict = [IO.File]::ReadAllText($path)
    Save-Value Ctrl+Shift+P
    Assert-Value (Read-State)['settings.error'] 'true' 'conflicting shortcut rejected'
    Assert-Value ([IO.File]::ReadAllText($path)) $beforeConflict 'conflict preserves shortcut file'
    Save-Value 'Leader+Left Ctrl'
    Assert-Value (Read-State)['settings.error'] 'true' 'modifier-only leader binding rejected'
    Save-Value 'Ctrl+Shift+T, Leader+T'
    Assert-Value (Read-State)['settings.error'] 'false' 'direct and leader binding saved'
    Open-Field input.leader
    Save-Value Ctrl+Shift+P
    Assert-Value (Read-State)['settings.error'] 'true' 'leader conflict rejected'
    Save-Value Ctrl+B
    Assert-Value (Read-State)['settings.error'] 'false' 'leader enabled explicitly'
    Invoke-Aio key Esc
    Invoke-Aio key Ctrl+Shift+T
    Assert-Value (Read-State)['tabs.count'] '2' 'direct shortcut remains available'
    Invoke-Aio key Ctrl+B
    Assert-Value (Read-State)['leader.pending'] 'true' 'leader prefix arms'
    Invoke-Aio key T
    Assert-Value (Read-State)['tabs.count'] '3' 'leader action dispatches'
    Invoke-Aio key Ctrl+B
    Invoke-Aio key Esc
    Assert-Value (Read-State)['leader.pending'] 'false' 'Escape cancels leader'
    Invoke-Aio key Ctrl+B
    Invoke-Aio focus out
    Assert-Value (Read-State)['leader.pending'] 'false' 'focus loss cancels leader'
    Invoke-Aio key Ctrl+B
    Invoke-Aio command settings.reload
    Assert-Value (Read-State)['leader.pending'] 'false' 'reload cancels leader'
    Invoke-Aio key Ctrl+B
    Start-Sleep -Milliseconds 2200
    Assert-Value (Read-State)['leader.pending'] 'false' 'leader expires after two seconds'
    Invoke-Aio key Ctrl+B
    Invoke-Aio key X
    Assert-Value (Read-State)['tabs.count'] '3' 'unmatched leader leaves layout unchanged'
    Assert-Value (Read-State)['leader.pending'] 'false' 'unmatched leader ends sequence'

    Open-Field keys.tab.new
    Invoke-Aio key Ctrl+R
    Assert-Value (Read-State)['settings.error'] 'false' 'shortcut reset saves direct defaults'
    Invoke-Aio key Esc
    Invoke-Aio key Ctrl+Shift+T
    Assert-Value (Read-State)['tabs.count'] '4' 'default shortcut restored'
    Invoke-Aio command settings.open
    Invoke-Aio dpi 168
    Assert-Value (Read-State)['settings.open'] 'true' 'settings remains open at 175 percent DPI'
    Invoke-Aio dpi 96
    Invoke-Aio key Esc
    Invoke-Aio stop
    Invoke-Aio launch
    Invoke-Aio key 'Ctrl+,'
    Invoke-Aio type shell.directory
    Invoke-Aio key Tab
    if ((Read-State)['settings.value'] -notlike "*$repo*") { throw 'Settings did not survive relaunch.' }
    Write-Output 'PASS settings persist across process restart'
} finally {
    & $ctl --name $name stop | Write-Output
}

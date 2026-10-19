param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'window-lifecycle'
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
function Shot([string] $Label) {
    & "$repo/tools/win32.ps1" -Name $name -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}

Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    $initial = Read-State
    Invoke-Aio run '$global:aioWindowMarker = "RUNTIME_" + "SURVIVED"'
    Invoke-Aio command settings.open
    $settingsTab = (Read-State)['tab.2.id']
    Invoke-Aio tray hide
    Invoke-Aio expect state window.visible=false
    Invoke-Aio expect state sessions.count=1
    Invoke-Aio tray open
    Invoke-Aio expect state window.visible=true
    Invoke-Aio expect state settings.active=true
    Invoke-Aio expect state settings.open=true
    Invoke-Aio expect state "tab.2.id=$settingsTab"
    Invoke-Aio type 'line height'
    Invoke-Aio expect state settings.key=font.line_height
    Shot settings-reopened
    Invoke-Aio key Esc
    Invoke-Aio command tab.select_1
    Invoke-Aio expect state "session.id=$($initial['session.id'])"
    Invoke-Aio run 'Write-Output $global:aioWindowMarker'
    Invoke-Aio expect text RUNTIME_SURVIVED

    # The Settings editor must also be restored when another tab was selected at closure.
    Invoke-Aio tray hide
    Invoke-Aio tray open
    Invoke-Aio command settings.open
    Invoke-Aio expect state settings.open=true
    Invoke-Aio type 'minimum pane width'
    Invoke-Aio expect state settings.key=pane.minimum_columns
    Invoke-Aio key Esc
    Invoke-Aio command tab.select_1
    Invoke-Aio run 'Start-Sleep -Milliseconds 1200; Write-Output ("OUTPUT_" + "WHILE_HIDDEN")' --idle 50
    Invoke-Aio tray hide
    Start-Sleep -Milliseconds 1500
    Invoke-Aio tray open
    Invoke-Aio wait text OUTPUT_WHILE_HIDDEN
    Invoke-Aio expect state "session.id=$($initial['session.id'])"
    Invoke-Aio expect state sessions.count=1

    # Settings can be the only remaining content, with no terminal available for initial geometry.
    Invoke-Aio command tab.close
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state sessions.count=0
    Invoke-Aio expect state settings.active=true
    foreach ($dpi in @(96, 144, 168)) {
        Invoke-Aio dpi $dpi
        Invoke-Aio tray hide
        Invoke-Aio tray open
        Invoke-Aio expect state tabs.count=1
        Invoke-Aio expect state sessions.count=0
        Invoke-Aio expect state settings.active=true
        Invoke-Aio expect state settings.open=true
        Invoke-Aio dpi $dpi
        Invoke-Aio type 'line height'
        Invoke-Aio expect state settings.key=font.line_height
        Shot "settings-only-$dpi"
        Invoke-Aio key Esc
    }
    Invoke-Aio command tab.close
    Invoke-Aio expect state window.visible=false
    Invoke-Aio expect state tabs.count=0
    Invoke-Aio tray open
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state sessions.count=1
    Invoke-Aio expect state session.status=running
} finally {
    Invoke-Aio stop
}

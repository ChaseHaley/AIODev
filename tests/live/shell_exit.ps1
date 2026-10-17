[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'pane-exit'

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}

function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect state.' }
    $state = @{}
    foreach ($line in $lines) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1]
    }
    return $state
}

function Wait-State([string] $Key, [string] $Value) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $state = Read-State
        if ($state[$Key] -eq $Value) { Write-Output "PASS $Key=$Value"; return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected $Key=$Value, observed $($state[$Key])"
}

function Ready { Invoke-Aio wait text 'PS ' }

Invoke-Aio launch --fresh
$settingsPath = Join-Path $repo "build/verify/$name/settings.ini"
$original = [IO.File]::ReadAllText($settingsPath)
try {
    $first = (Read-State)['session.id']
    Invoke-Aio key Ctrl+Shift+O
    Ready
    Invoke-Aio run 'exit 0'
    Wait-State panes.count 1
    Invoke-Aio expect state "session.id=$first"

    Invoke-Aio key Ctrl+Shift+O
    Ready
    $survivor = (Read-State)['session.id']
    Invoke-Aio key Ctrl+Alt+Left
    Invoke-Aio run 'Start-Sleep -Milliseconds 1800; exit 11' --idle 50
    Invoke-Aio key Ctrl+Alt+Right
    Invoke-Aio command terminal.find
    Invoke-Aio type 'keep query'
    Wait-State panes.count 1
    Invoke-Aio expect state "session.id=$survivor"
    Invoke-Aio expect state find.open=true
    Invoke-Aio key Esc
    Write-Output 'PASS unfocused exit preserves focused pane and find'

    Invoke-Aio key Ctrl+Shift+T
    Ready
    Invoke-Aio run 'exit 7'
    Wait-State tabs.count 1
    Invoke-Aio expect state "session.id=$survivor"
    Write-Output 'PASS final pane of a tab closes the tab'

    Invoke-Aio key Ctrl+Shift+T
    Ready
    Invoke-Aio run 'Start-Sleep -Milliseconds 1800; exit 0' --idle 50
    Invoke-Aio key Alt+1
    Invoke-Aio command terminal.find
    Invoke-Aio type 'keep query'
    Wait-State tabs.count 1
    Invoke-Aio expect state "session.id=$survivor"
    Invoke-Aio expect state find.open=true
    Invoke-Aio key Esc
    Write-Output 'PASS hidden tab exit preserves current tab and find'

    Invoke-Aio run 'Start-Sleep -Milliseconds 1800; exit 3' --idle 50
    Invoke-Aio key Ctrl+Shift+T
    Ready
    $shifted = (Read-State)['session.id']
    $tabId = (Read-State)['tab.2.id']
    Wait-State tabs.count 1
    Invoke-Aio expect state "session.id=$shifted"
    Invoke-Aio expect state "tab.1.id=$tabId"
    Invoke-Aio expect state tabs.selected=1
    Write-Output 'PASS closing an earlier hidden tab preserves tab identity'

    Invoke-Aio key Ctrl+Shift+O
    Ready
    $hiddenSurvivor = (Read-State)['session.id']
    Invoke-Aio key Ctrl+Alt+Left
    Invoke-Aio run 'Start-Sleep -Milliseconds 1800; exit 0' --idle 50
    Invoke-Aio key Ctrl+Shift+T
    Ready
    $visible = (Read-State)['session.id']
    Wait-State sessions.count 2
    Invoke-Aio expect state "session.id=$visible"
    Invoke-Aio key Alt+1
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state "session.id=$hiddenSurvivor"
    Write-Output 'PASS exit collapses a hidden split'

    Invoke-Aio run 'Start-Sleep -Milliseconds 1800; exit 0' --idle 50
    Invoke-Aio tray hide
    Wait-State tabs.count 1
    Invoke-Aio expect state window.visible=false
    Invoke-Aio expect state sessions.count=1
    Invoke-Aio tray open
    Invoke-Aio expect state "session.id=$visible"
    Write-Output 'PASS exits clean up while the window is hidden'

    Invoke-Aio run 'exit 0'
    Wait-State session.status exited
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state window.visible=true
    Invoke-Aio key Ctrl+Shift+T
    Ready
    Invoke-Aio run 'exit 0'
    Wait-State tabs.count 1
    Invoke-Aio expect state "session.id=$visible"
    Invoke-Aio expect state session.status=exited
    Invoke-Aio key Enter
    Ready
    Write-Output 'PASS the retained final pane stays available for restart'

    $signal = Join-Path $repo "build/verify/$name/exit.signal"
    $line = "while (-not (Test-Path -LiteralPath '$signal')) { Start-Sleep -Milliseconds 30 }; exit 0"
    Invoke-Aio run $line --idle 50
    Invoke-Aio key Ctrl+Shift+O
    Ready
    Invoke-Aio run $line --idle 50
    Invoke-Aio key Ctrl+Shift+E
    Ready
    Invoke-Aio run $line --idle 50
    [IO.File]::WriteAllText($signal, 'exit')
    Wait-State sessions.count 1
    Wait-State session.status exited
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state window.visible=true
    Invoke-Aio key Enter
    Ready
    Write-Output 'PASS simultaneous exits retain exactly one restartable pane'

    Invoke-Aio key Ctrl+Shift+O
    Ready
    $invalid = [regex]::Replace($original, '(?m)^shell.command = .*',
        'shell.command = aio_missing_exit_test_3317.exe')
    [IO.File]::WriteAllText($settingsPath, $invalid)
    Invoke-Aio command settings.reload
    Invoke-Aio command terminal.restart_shell
    Invoke-Aio expect state session.status=failed
    Invoke-Aio expect state panes.count=2
    [IO.File]::WriteAllText($settingsPath, $original)
    Invoke-Aio command settings.reload
    Invoke-Aio key Enter
    Ready
    Invoke-Aio run 'exit 0'
    Wait-State panes.count 1
    Write-Output 'PASS failed launches remain visible and recoverable'

    $quick = [regex]::Replace($original, '(?m)^shell.command = .*',
        'shell.command = cmd.exe /d /c exit 0')
    [IO.File]::WriteAllText($settingsPath, $quick)
    Invoke-Aio command settings.reload
    Invoke-Aio key Ctrl+Shift+T
    Wait-State tabs.count 1
    Invoke-Aio expect state sessions.count=1
    Write-Output 'PASS immediately exiting new sessions are removed'
} finally {
    [IO.File]::WriteAllText($settingsPath, $original)
    Invoke-Aio stop
}

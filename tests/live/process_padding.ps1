param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'process-padding'
$path = "$repo/build/verify/$name/settings.ini"
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $s = @{}
    foreach ($line in $out) { $pair = $line -split '=',2; $s[$pair[0]] = $pair[1].Trim('"') }
    return $s
}
function Await-Padding($Value) {
    $until = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $s = Read-State
        if ($s['grid.padding'] -eq "$Value") { Write-Output "PASS padding $Value for $($s['session.process'])"; return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "Expected padding $Value, observed $($s['grid.padding']) for $($s['session.process'])"
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    Invoke-Aio dpi 96
    [IO.File]::AppendAllText($path, "`nwindow.padding = 8`nprocess.padding_groups = shells:4:pwsh; editors:0:nvim; overlap:16:nvim`n")
    Invoke-Aio command settings.reload
    Await-Padding 4
    $shellGrid = (Read-State)['grid.size']
    $session = (Read-State)['session.id']
    Invoke-Aio run 'nvim -u NONE -i NONE -n'
    Await-Padding 0
    Invoke-Aio type ':echo "PADDING_NVIM"'
    Invoke-Aio key Enter
    Invoke-Aio wait text PADDING_NVIM
    if ((Read-State)['session.id'] -ne $session) { throw 'Process transition replaced the session.' }
    Invoke-Aio type ":call jobstart(['cmd', '/c', 'ping -n 8 127.0.0.1 > nul'])"
    Invoke-Aio key Enter
    Start-Sleep -Milliseconds 900
    Await-Padding 0
    if ((Read-State)['session.process'] -ne 'PING.EXE') {
        & $ctl --name $name screen | Write-Output
        throw "Neovim helper was not detected: $((Read-State)['session.process'])"
    }
    Write-Output 'PASS Neovim keeps its override while a helper runs'
    Invoke-Aio command pane.split_right
    Invoke-Aio wait text 'PS '
    Await-Padding 4
    Invoke-Aio command pane.focus_left
    Await-Padding 0
    Invoke-Aio command pane.focus_right
    Invoke-Aio command pane.close
    Await-Padding 0
    if ((Read-State)['session.id'] -ne $session) { throw 'Split changed the original runtime.' }
    & "$repo/tools/win32.ps1" -Name $name -Shot "$repo/build/verify/$name/neovim.png" -Frame | Out-Null
    Invoke-Aio key Esc
    Invoke-Aio type ':qa!'
    Invoke-Aio key Enter
    Await-Padding 4
    if ((Read-State)['grid.size'] -ne $shellGrid) { throw 'Shell grid did not restore.' }
    Invoke-Aio run 'cmd /k "echo UNMATCHED_PROCESS"'
    Await-Padding 8
    Invoke-Aio type exit
    Invoke-Aio key Enter
    Await-Padding 4
    Start-Sleep -Milliseconds 6600
    $frames = (Read-State)['frames.presented']
    Start-Sleep -Milliseconds 1200
    if ((Read-State)['frames.presented'] -ne $frames) { throw 'Process polling drew idle frames.' }
    Write-Output 'PASS configured process polling draws no idle frames'
    # The same setting can be edited and persisted through Settings.
    Invoke-Aio command settings.open
    Invoke-Aio type process.padding_groups
    Invoke-Aio key Tab Ctrl+A
    Invoke-Aio type 'editors:0:nvim; shells:6:pwsh'
    Invoke-Aio key Enter
    if ((Read-State)['settings.error'] -ne 'false') { throw 'Settings rejected a valid group.' }
    Invoke-Aio command tab.select_1
    Await-Padding 6
    Invoke-Aio dpi 144
    Await-Padding 9
    Invoke-Aio dpi 96
    [IO.File]::AppendAllText($path, "`nprocess.padding_groups = `n")
    Invoke-Aio command settings.reload
    Await-Padding 8
    Write-Output 'PASS process padding matching, fallback, return, persistence, DPI and idle'
} finally { & $ctl --name $name stop | Out-Null }

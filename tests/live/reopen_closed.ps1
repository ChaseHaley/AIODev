param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'reopen-closed'
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out
}
function Await-State([string] $Key, [string] $Value) {
    $until = [DateTime]::UtcNow.AddSeconds(6)
    do {
        $out = & $ctl --name $name state
        foreach ($line in $out) {
            $pair = $line -split '=', 2
            if ($pair[0] -eq $Key -and $pair[1].Trim('"') -like $Value) { return }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "Expected $Key like '$Value'"
}
$directory = Join-Path $repo "build/verify/$name-work"
New-Item -ItemType Directory -Force $directory | Out-Null
$settings = Join-Path $repo "build/verify/$name-settings.ini"
Set-Content -LiteralPath $settings -Value "cursor.blink = false`ntab.confirm_close = false"

Invoke-Aio launch --fresh --settings $settings | Out-Null
try {
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio run "Set-Location '$directory'; ping -n 60 127.0.0.1" | Out-Null
    Await-State 'session.program' '*PING.EXE'
    Invoke-Aio command pane.rename | Out-Null
    Invoke-Aio type 'pinger' | Out-Null
    Invoke-Aio key Enter | Out-Null

    # A closed pane returns beside the pane it was split from, named, in its directory, with a
    # note of what it ran above the new prompt.
    Invoke-Aio command pane.close | Out-Null
    Invoke-Aio expect state panes.count=1 | Out-Null
    Invoke-Aio command pane.reopen_closed | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    Invoke-Aio wait text 'Last running: PING -n 60 127.0.0.1' | Out-Null
    Invoke-Aio wait text 'reopen-closed-work>' | Out-Null
    Invoke-Aio expect text 'Last running: PING -n 60 127.0.0.1' | Out-Null
    Await-State 'session.name' 'pinger'
    Write-Output 'PASS pane reopens named, in its directory, noting its program'
    & "$repo/tools/win32.ps1" -Name $name -Shot "$repo/build/verify/$name/pane.png" -Frame | Out-Null

    # A pane whose shell exits can be reopened too.
    Invoke-Aio run 'exit' | Out-Null
    Invoke-Aio expect state panes.count=1 | Out-Null
    Invoke-Aio command pane.reopen_closed | Out-Null
    Invoke-Aio expect state panes.count=2 | Out-Null
    Invoke-Aio wait text 'reopen-closed-work>' | Out-Null
    Await-State 'session.name' 'pinger'
    Write-Output 'PASS pane whose shell exited reopens'

    # A closed split tab returns whole at its position.
    Invoke-Aio command tab.new | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio command tab.select_1 | Out-Null
    Invoke-Aio command tab.close | Out-Null
    Await-State 'tabs.count' '1'
    Invoke-Aio command pane.reopen_closed | Out-Null
    Await-State 'tabs.count' '2'
    Invoke-Aio expect state panes.count=2 | Out-Null
    Write-Output 'PASS split tab reopens whole'

    # After a full restart the pane notes what it was running.
    Invoke-Aio run 'ping -n 60 127.0.0.1' | Out-Null
    Await-State 'session.program' '*PING.EXE'
    Start-Sleep -Milliseconds 2500
    Invoke-Aio stop | Out-Null
    Invoke-Aio launch --keep-layout --settings $settings | Out-Null
    Invoke-Aio wait text 'Last running: PING -n 60 127.0.0.1' | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Write-Output 'PASS restored pane notes its program after restart'
    & "$repo/tools/win32.ps1" -Name $name -Shot "$repo/build/verify/$name/restart.png" -Frame | Out-Null

    # Without icon polling, closing and quitting read the running program then.
    Invoke-Aio stop | Out-Null
    Add-Content -LiteralPath $settings -Value 'tabs.program_icons = false'
    Invoke-Aio launch --fresh --settings $settings | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio run 'ping -n 60 127.0.0.2' | Out-Null
    Invoke-Aio wait text 'Pinging 127.0.0.2' | Out-Null
    Invoke-Aio command pane.close | Out-Null
    Invoke-Aio command pane.reopen_closed | Out-Null
    Invoke-Aio wait text 'Last running: PING -n 60 127.0.0.2' | Out-Null
    Invoke-Aio run 'ping -n 60 127.0.0.3' | Out-Null
    Invoke-Aio wait text 'Pinging 127.0.0.3' | Out-Null
    Invoke-Aio stop | Out-Null
    Invoke-Aio launch --keep-layout --settings $settings | Out-Null
    Invoke-Aio wait text 'Last running: PING -n 60 127.0.0.3' | Out-Null
    Write-Output 'PASS without icon polling, close and quit note the program'
} finally {
    & $ctl --name $name stop | Out-Null
}

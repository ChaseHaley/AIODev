param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'program-icons'
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
function Await-Program([string] $Executable, $Icon) {
    $until = [DateTime]::UtcNow.AddSeconds(6)
    do {
        $s = Read-State
        $program = [IO.Path]::GetFileName($s['session.program'])
        $iconMatches = $null -eq $Icon -or $s['session.program.icon'] -eq "$Icon".ToLower()
        if ($program -eq $Executable -and $iconMatches) {
            Write-Output "PASS program '$Executable' icon $Icon"
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "Expected program '$Executable' icon $Icon, observed '$program' icon $($s['session.program.icon'])"
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    Invoke-Aio dpi 96
    Await-Program '' $false
    Invoke-Aio run 'nvim -u NONE -i NONE -n'
    Await-Program 'nvim.exe' $true
    # A helper Neovim starts is not the shell's child, so the pane keeps Neovim's icon.
    Invoke-Aio type ":call jobstart(['cmd', '/c', 'ping -n 4 127.0.0.1 > nul'])"
    Invoke-Aio key Enter
    Start-Sleep -Milliseconds 1200
    Await-Program 'nvim.exe' $true
    & "$repo/tools/win32.ps1" -Name $name -Shot "$repo/build/verify/$name/neovim.png" -Frame | Out-Null
    Invoke-Aio key Esc
    Invoke-Aio type ':qa!'
    Invoke-Aio key Enter
    Await-Program '' $false
    Write-Output 'PASS returning to the shell restores the shell icon'
    # A program reporting status wins over the launcher between it and the shell.
    $report = "[Console]::Write([char]27 + ']7501;state=done:id=icons:app=PING' + [char]7); " +
        "cmd /c 'ping -n 6 127.0.0.1 > nul'"
    Invoke-Aio run $report
    Await-Program 'PING.EXE' $null
    Write-Output 'PASS a status reporter below a launcher names the pane'
    Await-Program '' $false
    Start-Sleep -Milliseconds 1500
    $frames = (Read-State)['frames.presented']
    Start-Sleep -Milliseconds 1500
    if ((Read-State)['frames.presented'] -ne $frames) { throw 'Program polling drew idle frames.' }
    Write-Output 'PASS program polling draws no idle frames'
} finally {
    & $ctl --name $name stop | Out-Null
}

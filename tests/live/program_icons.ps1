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
# Waits for the pane's program name and the icon source drawn for it, with that icon ready.
function Await-Name([string] $Program, [string] $Source) {
    $until = [DateTime]::UtcNow.AddSeconds(6)
    do {
        $s = Read-State
        if ($s['session.program.name'] -eq $Program -and $s['session.program.source'] -eq $Source -and
            $s['session.program.icon'] -eq 'true') {
            Write-Output "PASS program name '$Program' from $Source"
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "Expected '$Program' from $Source, observed '$($s['session.program.name'])' from " +
        "'$($s['session.program.source'])' icon $($s['session.program.icon'])"
}
# Stand-ins outside the data folder, which a fresh launch clears: copies of ping named like Codex
# and SSH, and a script where npm installs Codex.
$data = Join-Path $repo "build/verify/$name"
$programs = Join-Path $repo "build/verify/$name-programs"
New-Item -ItemType Directory -Force $programs | Out-Null
$ping = Join-Path $env:SystemRoot 'System32/PING.EXE'
Copy-Item $ping (Join-Path $programs 'codex.exe') -Force
Copy-Item $ping (Join-Path $programs 'ssh.exe') -Force
$script = Join-Path $programs 'node_modules/@openai/codex/bin/codex.js'
New-Item -ItemType Directory -Force (Split-Path $script) | Out-Null
Set-Content -LiteralPath $script -Value 'setTimeout(() => {}, 4000)'
$node = (Get-Command node -ErrorAction Stop).Source
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    Invoke-Aio dpi 96
    Await-Program '' $false
    Invoke-Aio run 'nvim -u NONE -i NONE -n'
    Await-Program 'nvim.exe' $true
    Await-Name 'nvim' 'artwork'
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
    # Codex's executable has no icon resource, so bundled artwork names it.
    Invoke-Aio run "& '$programs/codex.exe' -n 5 127.0.0.1"
    Await-Name 'codex' 'artwork'
    & "$repo/tools/win32.ps1" -Name $name -Shot "$data/codex.png" -Frame | Out-Null
    Await-Program '' $false
    # Through its Node launcher, the script's package names it rather than Node.
    Invoke-Aio run "& '$node' '$script'"
    Await-Name 'codex' 'artwork'
    if ((Read-State)['session.program'] -ne '') { throw 'A launcher kept its own executable icon.' }
    Await-Program '' $false
    Write-Output 'PASS Codex through its Node launcher shows Codex artwork'
    # A WSL or SSH session is named by the app its program reports.
    $bridge = "[Console]::Write([char]27 + ']7501;state=done:id=bridge:app=claude' + [char]7); " +
        "& '$programs/ssh.exe' -n 5 127.0.0.1"
    Invoke-Aio run $bridge
    Await-Name 'claude' 'artwork'
    Await-Program '' $false
    # The user's PNG takes precedence over bundled artwork.
    $png = Join-Path $repo 'assets/aiodev-notification.png'
    [IO.File]::AppendAllText((Join-Path $data 'settings.ini'), "`ntabs.program_icon_files = `"codex=$png`"`n")
    Invoke-Aio command settings.reload
    Invoke-Aio run "& '$programs/codex.exe' -n 5 127.0.0.1"
    Await-Name 'codex' 'file'
    & "$repo/tools/win32.ps1" -Name $name -Shot "$data/codex-override.png" -Frame | Out-Null
    Await-Program '' $false
    Start-Sleep -Milliseconds 1500
    $frames = (Read-State)['frames.presented']
    Start-Sleep -Milliseconds 1500
    if ((Read-State)['frames.presented'] -ne $frames) { throw 'Program polling drew idle frames.' }
    Write-Output 'PASS program polling draws no idle frames'
} finally {
    & $ctl --name $name stop | Out-Null
}

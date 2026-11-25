[CmdletBinding()]
param([string] $Name = 'neovim-directory')
# Panes opened from a Neovim pane start where Neovim is working (WORK-651): Split right from a Neovim pane
# starts the shell in Neovim's directory after :cd (relative), :lcd and :tcd, and Agent changes opened from it
# shows the repository there. With Neovim over a shell, a split takes Neovim's directory while Neovim shows
# and the shell's own once :q brings the shell back. Needs nvim and git on PATH. Neovim runs with XDG folders
# inside this journey's work folder, so the owner's Neovim config is neither read nor written.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$settings = Join-Path $work 'settings.ini'
$env:AIODEV_PANE = $null
$env:AIODEV_CLI = $null
$env:NVIM_APPNAME = $null
foreach ($folder in 'CONFIG', 'DATA', 'STATE', 'CACHE') {
    Set-Item "env:XDG_$($folder)_HOME" (Join-Path $work "xdg/$($folder.ToLower())")
}

function Invoke-Ctl {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Ctl state)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $state[$line.Substring(0, $at)] = $line.Substring($at + 1).Trim('"') }
    }
    return $state
}
function Wait-For([string] $Key, [string] $Value) {
    for ($i = 0; $i -lt 80; $i++) {
        if ((Read-State)[$Key] -eq $Value) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Key=$Value; saw $((Read-State)[$Key])."
}
function Check([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Send-Command([string] $Command) {
    Invoke-Ctl type ":$Command" | Out-Null
    Invoke-Ctl key Enter | Out-Null
}
function Wait-Drawn {
    for ($i = 0; $i -lt 200; $i++) {
        $state = Read-State
        if ($state['neovim.active'] -eq 'true' -and [int] $state['neovim.grids'] -gt 1) { return }
        Start-Sleep -Milliseconds 50
    }
    throw 'Neovim did not take the pane.'
}
# Split right from the focused Neovim pane with its shortcut, as a person would, and check the new shell
# works in `$Directory`: its header names it and the shell itself says so (the prompt wraps in a narrow
# pane, so the shell answers a question instead). Then close that shell, which gives Neovim the keyboard.
function Assert-SplitStartsIn([string] $Directory, [string] $Label, [string] $Capture = '') {
    Invoke-Ctl key Ctrl+Shift+O | Out-Null
    Wait-For 'neovim.active' 'false'
    Invoke-Ctl wait text 'PS ' | Out-Null
    try { Wait-For 'session.header.directory' $Directory }
    catch { throw "$Label`: the split's shell did not start in $Directory; $_" }
    Invoke-Ctl type "`$PWD.Path -eq '$Directory'" | Out-Null
    Invoke-Ctl key Enter | Out-Null
    Invoke-Ctl wait text 'True' | Out-Null
    Write-Output "$Label`: the split's shell works in $Directory"
    if ($Capture) { Invoke-Ctl capture --out (Join-Path $work $Capture) | Out-Null }
    Invoke-Ctl command pane.close | Out-Null
    Wait-For 'neovim.active' 'true'
}

foreach ($tool in 'nvim', 'git') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "This journey needs $tool on PATH." }
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
foreach ($folder in 'a', 'b', 'c', 'cwdrepo', 'xdg/config/nvim') {
    New-Item -ItemType Directory -Force (Join-Path $work $folder) | Out-Null
}
$a, $b, $c, $git = 'a', 'b', 'c', 'cwdrepo' | ForEach-Object { (Resolve-Path -LiteralPath (Join-Path $work $_)).Path }
$root = (Resolve-Path -LiteralPath $work).Path
Set-Content -LiteralPath (Join-Path $work 'xdg/config/nvim/init.lua') -Encoding utf8 ''
& git -C $git init -q
Set-Content -LiteralPath (Join-Path $git 'tracked.txt') -Encoding utf8 'first'
& git -C $git add tracked.txt
& git -C $git -c user.name=t -c user.email=t@t commit -q -m first
Set-Content -LiteralPath (Join-Path $git 'tracked.txt') -Encoding utf8 'changed'
@"
control.enabled = true
profile.default.command = pwsh.exe -NoLogo -NoProfile -NoExit
profile.default.directory = $root
shell.default_profile = default
profile.order = default
cursor.blink = false
window.columns = 160
window.rows = 40
"@ | Set-Content -LiteralPath $settings -Encoding utf8

Invoke-Ctl launch --fresh --settings $settings | Out-Null
try {
    Invoke-Ctl wait text 'PS ' | Out-Null

    # Neovim beside the shell, in the shell's folder; Neovim reports where it works as an absolute path.
    Invoke-Ctl command pane.open_neovim | Out-Null
    Wait-Drawn
    Wait-For 'neovim.directory' $root
    Assert-SplitStartsIn $root 'start'

    # An absolute :cd, then a relative one, which Neovim's own chdir UI event names as typed.
    Send-Command "cd $a"
    Wait-For 'neovim.directory' $a
    Assert-SplitStartsIn $a ':cd a'
    Send-Command 'cd ../b'
    Wait-For 'neovim.directory' $b
    Assert-SplitStartsIn $b ':cd ../b'

    # A window's own directory, and the directory of the window the cursor moves to.
    Send-Command 'vsplit | lcd ../c'
    Wait-For 'neovim.directory' $c
    Assert-SplitStartsIn $c ':lcd ../c' 'split-after-lcd.png'
    Send-Command 'wincmd w'
    Wait-For 'neovim.directory' $b
    Assert-SplitStartsIn $b ':wincmd w'

    # A tab page's directory.
    Send-Command "tabnew | tcd $a"
    Wait-For 'neovim.directory' $a
    Assert-SplitStartsIn $a ':tcd a'

    # Agent changes opened from Neovim shows the repository Neovim works in.
    Send-Command "tcd $git"
    Wait-For 'neovim.directory' $git
    Invoke-Ctl command pane.agent_changes | Out-Null
    Wait-For 'changes.active' 'true'
    Wait-For 'changes.settled' 'true'
    $state = Read-State
    Check ($state['changes.repository'] -like '*cwdrepo*') "Agent changes shows $($state['changes.repository']), not cwdrepo"
    Check ([int] $state['changes.files'] -ge 1) "Agent changes lists $($state['changes.files']) files in cwdrepo"
    Write-Output "Agent changes: repository $($state['changes.repository']), worktree $($state['changes.worktree']), files $($state['changes.files'])"
    Invoke-Ctl command pane.close | Out-Null
    Wait-For 'neovim.active' 'true'

    # Neovim over a shell: Neovim's directory while it shows, the shell's own after :q.
    Invoke-Ctl command tab.new | Out-Null
    Invoke-Ctl wait text "PS $root>" | Out-Null
    Invoke-Ctl type 'cd b' | Out-Null
    Invoke-Ctl key Enter | Out-Null
    Invoke-Ctl wait text "PS $b>" | Out-Null
    Invoke-Ctl type "& '$aio' pane.open_neovim" | Out-Null
    Invoke-Ctl key Enter | Out-Null
    Wait-Drawn
    Check ((Read-State)['neovim.shell'] -ne '0') 'Neovim has no shell behind it'
    Wait-For 'neovim.directory' $b
    Send-Command 'cd ../c'
    Wait-For 'neovim.directory' $c
    Assert-SplitStartsIn $c 'over a shell, :cd ../c'
    Send-Command 'q'
    Wait-For 'neovim.active' 'false'
    Wait-For 'neovim.count' '1'
    Check ((Read-State)['tab.2.panes'] -eq '1') 'the pane closed instead of showing its shell'
    Invoke-Ctl key Ctrl+Shift+O | Out-Null
    Wait-For 'tab.2.panes' '2'
    Invoke-Ctl wait text 'PS ' | Out-Null
    Wait-For 'session.header.directory' $b
    Invoke-Ctl type "`$PWD.Path -eq '$b'" | Out-Null
    Invoke-Ctl key Enter | Out-Null
    Invoke-Ctl wait text 'True' | Out-Null
    Write-Output "after :q: the split's shell works in the shell's own $b"
    Write-Output 'PASS neovim_directory'
} finally {
    & $ctl --name $Name stop | Out-Null
}

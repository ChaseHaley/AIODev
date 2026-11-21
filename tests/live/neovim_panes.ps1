[CmdletBinding()]
param([string] $Name = 'neovim-panes')
# Neovim panes (WORK-542): AIODev starts `nvim --embed` and draws its grid. Opens a file through aio, types
# and saves it, clicks and scrolls with the mouse, follows a resize, closes with :q, reopens the closed
# pane, restores it after a restart, and edits a file Agent changes shows a diff of. Needs nvim and git on
# PATH. Neovim runs with XDG folders inside this journey's work folder, so the owner's Neovim config,
# plugins and state are neither read nor written.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$settings = Join-Path $work 'settings.ini'
# aio must name this instance's focused pane, not the pane this script runs in.
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
function Wait-Until([scriptblock] $Condition, [string] $Message) {
    for ($i = 0; $i -lt 80; $i++) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw $Message
}
# Types a Neovim command line and runs it.
function Send-Command([string] $Command) {
    Invoke-Ctl type ":$Command" | Out-Null
    Invoke-Ctl key Enter | Out-Null
}

if (-not (Get-Command nvim -ErrorAction SilentlyContinue)) { throw 'This journey needs nvim on PATH.' }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
$file = Join-Path $work 'notes.txt'
Set-Content -LiteralPath $file -Encoding utf8 -NoNewline "first line`nsecond line`n"
# A repository with one uncommitted change on line 3, for Agent changes to show.
$repository = Join-Path $work 'repository'
New-Item -ItemType Directory -Force $repository | Out-Null
Set-Content -LiteralPath (Join-Path $repository 'code.txt') -Encoding utf8 -NoNewline "one`ntwo`nthree`nfour`n"
git -C $repository init --quiet
git -C $repository -c core.autocrlf=false add code.txt
git -C $repository -c user.name=journey -c user.email=journey@example.com commit --quiet -m start
Set-Content -LiteralPath (Join-Path $repository 'code.txt') -Encoding utf8 -NoNewline "one`ntwo`nchanged three`nfour`n"
@"
control.enabled = true
profile.default.command = pwsh.exe -NoLogo -NoProfile -NoExit
profile.default.directory = $repository
shell.default_profile = default
profile.order = default
cursor.blink = false
window.columns = 170
window.rows = 50
"@ | Set-Content -LiteralPath $settings -Encoding utf8

Invoke-Ctl launch --fresh --settings $settings | Out-Null
try {
    Invoke-Ctl wait text 'PS ' | Out-Null
    Check ((Read-State)['neovim.count'] -eq '0') 'a fresh instance has Neovim panes'

    # aio opens the file beside the shell; Neovim starts at the pane's size once it is laid out.
    $opened = & $aio --instance $Name pane.open_neovim $file --focus 2>&1
    Check ($LASTEXITCODE -eq 0) "aio pane.open_neovim: $opened"
    Wait-For 'neovim.started' 'true'
    Wait-For 'neovim.row.0' 'first line'
    $state = Read-State
    Check ($state['tab.1.panes'] -eq '2') "tab panes: $($state['tab.1.panes'])"
    Check ($state['neovim.file'] -eq $file) "file: $($state['neovim.file'])"
    Check ([int] $state['neovim.columns'] -gt 20) "columns: $($state['neovim.columns'])"

    # Keys and typed text reach Neovim; '<' is sent literally, and :w writes the file.
    Invoke-Ctl key i | Out-Null
    Invoke-Ctl type 'typed <x> ' | Out-Null
    Invoke-Ctl key Esc | Out-Null
    Wait-For 'neovim.row.0' 'typed <x> first line'
    Wait-For 'neovim.cursor_shape' 'block'
    Send-Command 'w'
    for ($i = 0; $i -lt 40 -and -not ((Get-Content -LiteralPath $file -Raw) -like 'typed <x> first line*'); $i++) {
        Start-Sleep -Milliseconds 100
    }
    Check ((Get-Content -LiteralPath $file -Raw) -like 'typed <x> first line*') 'the file was not written'

    # A click puts the cursor on the cell under the pointer. The cursor cell gives the grid's metrics.
    Invoke-Ctl focus in | Out-Null
    $caret = (Read-State)['caret.rect'] -split ','
    $width, $height = [int] $caret[2], [int] $caret[3]
    Check ($width -gt 0 -and $height -gt 0) "caret rect: $($caret -join ',')"
    $originX = [int] $caret[0] - [int] (Read-State)['neovim.cursor_column'] * $width
    $originY = [int] $caret[1] - [int] (Read-State)['neovim.cursor_row'] * $height
    $x, $y = ($originX + 3 * $width + [int]($width / 2)), ($originY + $height + [int]($height / 2))
    Invoke-Ctl mouse click "$x,$y" --px | Out-Null
    Wait-For 'neovim.cursor_row' '1'
    Wait-For 'neovim.cursor_column' '3'

    # The wheel scrolls as much as it does for Neovim in a terminal: one wheel line is three of Neovim's,
    # so the top line goes from line 1 to line 4, the second number put below "second line".
    Send-Command 'put =range(1,200)'
    Invoke-Ctl type 'gg' | Out-Null
    Wait-For 'neovim.row.0' 'typed <x> first line'
    Invoke-Ctl mouse wheel "$x,$y" -1 --px | Out-Null
    Wait-For 'neovim.row.0' '2'

    # The grid follows the window; aioctl's resize waits on a terminal grid, so only the pane is checked.
    $columns = (Read-State)['neovim.columns']
    & $ctl --name $Name resize 200x50 | Out-Null
    for ($i = 0; $i -lt 40 -and (Read-State)['neovim.columns'] -eq $columns; $i++) { Start-Sleep -Milliseconds 100 }
    Check ((Read-State)['neovim.columns'] -ne $columns) "columns stayed $columns after a resize"

    # :q closes the pane, and Reopen closed pane starts Neovim on the file again.
    Send-Command 'q!'
    Wait-For 'tab.1.panes' '1'
    Wait-For 'neovim.count' '0'
    Invoke-Ctl command pane.reopen_closed | Out-Null
    Wait-For 'neovim.count' '1'
    Wait-For 'neovim.row.0' 'typed <x> first line'

    # A restart brings the pane back. Focus goes to the shell first, which launch's readiness reads.
    Invoke-Ctl command pane.focus_left | Out-Null
    Wait-For 'neovim.active' 'false'
    Invoke-Ctl stop | Out-Null
    Invoke-Ctl launch --settings $settings --keep-layout | Out-Null
    Wait-For 'neovim.count' '1'
    $state = Read-State
    $id = ($state.Keys | Where-Object { $_ -match '^neovim\.pane\.(\d+)\.file$' } | Select-Object -First 1) -replace '^neovim\.pane\.(\d+)\.file$', '$1'
    Check ($state["neovim.pane.$id.file"] -like '*notes.txt') "restored file: $($state["neovim.pane.$id.file"])"
    Wait-For "neovim.pane.$id.started" 'true'

    # The owner's example: a file Agent changes shows a diff of opens in the tab's Neovim pane, at its first
    # changed line, from the pencil on the file's header.
    Invoke-Ctl command pane.agent_changes | Out-Null
    Wait-For 'changes.active' 'true'
    Wait-For 'changes.files' '1'
    Wait-For 'changes.file.0.path' 'code.txt'
    $edit = (Read-State)['changes.file.0.edit_rect'] -split ','
    Check ([int] $edit[2] -gt 0) "the file header has no edit button: $($edit -join ',')"
    $x, $y = ([int] $edit[0] + [int]([int] $edit[2] / 2)), ([int] $edit[1] + [int]([int] $edit[3] / 2))
    Invoke-Ctl mouse click "$x,$y" --px | Out-Null
    Wait-For 'neovim.active' 'true'
    Wait-Until { (Read-State)['neovim.buffer'] -like '*code.txt' } "Neovim did not open code.txt"
    $state = Read-State
    Check ($state['neovim.count'] -eq '1') "the edit opened another Neovim: $($state['neovim.count'])"
    Check ($state["neovim.row.$($state['neovim.cursor_row'])"] -eq 'changed three') 'the cursor is not on line 3'

    # A folder opens as `nvim .` opens it there: Neovim lists it and works in it, not in its parent.
    $opened = & $aio --instance $Name pane.open_neovim $repository --focus 2>&1
    Check ($LASTEXITCODE -eq 0) "aio pane.open_neovim <folder>: $opened"
    Wait-For 'neovim.count' '2'
    Wait-For 'neovim.started' 'true'
    Wait-For 'neovim.directory' $repository
    Write-Output 'PASS neovim_panes'
} finally {
    & $ctl --name $Name stop | Out-Null
}

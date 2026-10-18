[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'leader-status'
$directory = Join-Path $repo "build/verify/$name"
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $lines) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Assert-Value($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame -Shot (Join-Path $directory "$Label.png")
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
Invoke-Aio launch --fresh
try {
    $path = Join-Path $directory 'settings.ini'
    [IO.File]::AppendAllText($path, "`ninput.leader = Ctrl+B`nkeys.tab.new = Ctrl+Shift+T, Leader+T`n")
    Invoke-Aio command settings.reload
    Invoke-Aio command pane.split_right
    Invoke-Aio wait text 'PS '
    Start-Sleep -Milliseconds 6500
    $before = Read-State
    Invoke-Aio key Ctrl+B
    Assert-Value (Read-State)['leader.indicator'] pane-status-line 'leader draws the selected status line'
    Shot pending-dark
    Start-Sleep -Milliseconds 250
    $settled = Read-State
    Start-Sleep -Milliseconds 350
    Assert-Value (Read-State)['frames.presented'] $settled['frames.presented'] 'pending indicator does not animate or redraw while idle'
    Assert-Value (Read-State)['grid.size'] $before['grid.size'] 'arming leader never resizes the terminal'
    Invoke-Aio key Esc
    Assert-Value (Read-State)['leader.indicator'] none 'Escape clears the line'
    Invoke-Aio key Ctrl+B
    Start-Sleep -Milliseconds 2300
    Shot expired-dark
    Assert-Value (Read-State)['leader.indicator'] none 'timeout clears the line with cursor blink disabled'
    Invoke-Aio key Ctrl+B X
    Assert-Value (Read-State)['leader.indicator'] none 'unmatched key clears the line'
    Invoke-Aio key Ctrl+B
    Invoke-Aio focus out
    Assert-Value (Read-State)['leader.indicator'] none 'window focus loss clears the line'
    Invoke-Aio key Ctrl+B
    Invoke-Aio command pane.focus_left
    Assert-Value (Read-State)['leader.indicator'] none 'pane focus change clears the line'
    Invoke-Aio key Ctrl+B
    Invoke-Aio command settings.reload
    Assert-Value (Read-State)['leader.indicator'] none 'reload clears the line'
    Invoke-Aio key Ctrl+B T
    Assert-Value (Read-State)['tabs.count'] 2 'leader command still dispatches'
    Assert-Value (Read-State)['leader.indicator'] none 'dispatch clears the line'
    [IO.File]::AppendAllText($path, "`ntheme.mode = light`n")
    Invoke-Aio command settings.reload
    Start-Sleep -Milliseconds 6500
    Invoke-Aio key Ctrl+B
    Shot pending-light
    Invoke-Aio key Esc
    Write-Output 'PASS subtle pane status line lifecycle and idle behavior'
} finally {
    & $ctl --name $name stop | Out-Null
}

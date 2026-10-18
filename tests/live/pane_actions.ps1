[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'pane-actions'
$data = Join-Path $repo "build/verify/$name"

function Invoke-Aio {
    Write-Output ("> aioctl --name $name " + ($args -join ' '))
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl failed: $result" }
    $result | Write-Output
}

function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $lines) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1]
    }
    return $state
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label=$Expected"
}

function Set-Marker([string] $Marker) {
    Invoke-Aio run ('function prompt { "P> " }; Clear-Host; Write-Output "' + $Marker + '"')
    Invoke-Aio expect text $Marker
}

function Shot([string] $File) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $data $File)
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}

Invoke-Aio launch --fresh
try {
    Set-Marker 'PANE_A_ONLY'
    $state = Read-State
    $a = $state['panes.focused']
    $aSession = $state['session.id']
    $full = $state["pane.$a.rect"]
    Invoke-Aio command pane.split --direction left --ratio 0.25 --focus false
    Invoke-Aio expect state tab.1.panes=2
    Invoke-Aio expect state panes.focused=$a
    Invoke-Aio expect state session.id=$aSession
    $state = Read-State
    $b = @($state.Keys | Where-Object { $_ -match '^tab\.1\.pane\.\d+\.session$' } |
        ForEach-Object { ($_ -split '\.')[3] } | Where-Object { $_ -ne $a })[0]
    $bRect = $state["pane.$b.rect"] -split ','
    Assert-Value $bRect[0] ($full -split ',')[0] 'left split starts at content edge'
    $gap = [double]$state['panes.gap']
    $available = [double]($full -split ',')[2] - $gap
    Assert-Value $bRect[2] ([math]::Round($available * 0.25, 0, 'AwayFromZero')) 'new pane ratio'
    Invoke-Aio run 'Start-Sleep -Milliseconds 1400; Write-Output ("BACKGROUND_A_" + "ALIVE")' --idle 20
    Invoke-Aio command pane.focus_left
    Invoke-Aio wait text 'PS '
    Set-Marker 'PANE_B_ONLY'
    $bSession = (Read-State)['session.id']
    Invoke-Aio expect no-text PANE_A_ONLY
    Invoke-Aio key Ctrl+Shift+P
    Invoke-Aio type 'Toggle Pane Zoom'
    Invoke-Aio expect state palette.item=pane.zoom
    Invoke-Aio key Enter
    Invoke-Aio expect state tab.1.zoomed=true
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state tab.1.panes=2
    Invoke-Aio expect state session.id=$bSession
    Invoke-Aio expect no-text BACKGROUND_A_ALIVE
    Assert-Value (Read-State)["pane.$b.rect"] $full 'zoom fills tab content area'
    Shot 'zoom.png'
    Invoke-Aio command tab.new
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state tab.1.zoomed=true
    Invoke-Aio expect state tab.2.zoomed=false
    Invoke-Aio command tab.close
    Invoke-Aio expect state tabs.selected=1
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state session.id=$bSession
    Invoke-Aio command pane.focus_right
    Invoke-Aio expect state tab.1.zoomed=true
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state session.id=$aSession
    Invoke-Aio wait text BACKGROUND_A_ALIVE
    Invoke-Aio command pane.zoom
    Invoke-Aio expect state panes.count=2
    Assert-Value (Read-State)["pane.$b.rect"] ($bRect -join ',') 'zoom restores original ratios'
    Invoke-Aio command pane.keep_open
    Invoke-Aio expect state tab.1.pane.$a.keep_open=true
    Invoke-Aio command pane.swap_left
    Invoke-Aio expect state panes.focused=$b
    Invoke-Aio expect state session.id=$aSession
    Invoke-Aio expect state tab.1.pane.$b.keep_open=true
    Invoke-Aio expect state tab.1.pane.$a.keep_open=false
    Invoke-Aio expect text PANE_A_ONLY
    Invoke-Aio expect no-text PANE_B_ONLY
    Invoke-Aio command pane.swap_next
    Invoke-Aio expect state panes.focused=$a
    Invoke-Aio expect state session.id=$aSession
    Invoke-Aio command pane.swap_previous
    Invoke-Aio expect state panes.focused=$b
    Invoke-Aio command pane.swap_right
    Invoke-Aio expect state panes.focused=$a
    $oldWidth = [double]((Read-State)["pane.$b.rect"] -split ',')[2]
    Invoke-Aio command pane.resize_right_large
    Assert-Value (([double]((Read-State)["pane.$b.rect"] -split ',')[2]) - $oldWidth) 50 'large resize step'
    Invoke-Aio command pane.split --direction up --ratio 0.3 --focus true
    Invoke-Aio wait text 'PS '
    Set-Marker 'PANE_C_ONLY'
    $c = (Read-State)['panes.focused']
    Invoke-Aio command pane.balance
    $state = Read-State
    $left = $state["pane.$b.rect"] -split ','
    $top = $state["pane.$c.rect"] -split ','
    $bottom = $state["pane.$a.rect"] -split ','
    Assert-Value $left[2] ([math]::Round($available / 2, 0, 'AwayFromZero')) 'balance outer split'
    Assert-Value $top[3] ([math]::Round(([double]($full -split ',')[3] - $gap) / 2, 0, 'AwayFromZero')) 'balance nested split'
    Assert-Value $top[1] $left[1] 'up split appears above original'
    Invoke-Aio command pane.resize_down_large
    Assert-Value (([double]((Read-State)["pane.$c.rect"] -split ',')[3]) - [double]$top[3]) 50 'large vertical resize'
    Invoke-Aio command pane.resize_up_large
    Assert-Value (Read-State)["pane.$c.rect"] ($top -join ',') 'large vertical resize inverse'
    Invoke-Aio command pane.resize_left_large
    Assert-Value (([double]((Read-State)["pane.$b.rect"] -split ',')[2]) - [double]$left[2]) -50 'large resize left'
    Invoke-Aio command pane.resize_right_large
    Assert-Value (Read-State)["pane.$c.rect"] ($top -join ',') 'large horizontal resize inverse'
    Invoke-Aio command pane.swap_down
    Invoke-Aio expect state session.id=$($state['session.id'])
    Invoke-Aio expect state panes.focused=$a
    Invoke-Aio command pane.swap_up
    Invoke-Aio expect state panes.focused=$c
    Shot 'balanced.png'
    Invoke-Aio command pane.zoom
    Invoke-Aio command pane.close
    Invoke-Aio expect state tab.1.zoomed=false
    Invoke-Aio expect state panes.count=2
    Invoke-Aio command pane.focus_right
    Invoke-Aio expect state session.id=$aSession
    Invoke-Aio run 'exit 7'
    Invoke-Aio expect state tab.1.panes=2
    Invoke-Aio expect state session.status=exited
    Invoke-Aio expect state tab.1.pane.$a.keep_open=true
    Invoke-Aio key Enter
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state session.status=running
    Invoke-Aio expect state session.id=$aSession
    Invoke-Aio type 'Start-Sleep -Milliseconds 800; exit 9'
    Invoke-Aio key Enter
    Invoke-Aio command pane.focus_left
    Invoke-Aio wait idle 1200
    Invoke-Aio expect state tab.1.panes=2
    Invoke-Aio expect state session.id=$bSession
    Invoke-Aio command pane.focus_right
    Invoke-Aio expect state session.status=exited
    Invoke-Aio command pane.keep_open
    Invoke-Aio expect state tab.1.panes=1
    Invoke-Aio expect state session.id=$bSession
    Invoke-Aio command pane.split_left
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state tab.1.panes=2
    Invoke-Aio run 'exit 0'
    Invoke-Aio expect state tab.1.panes=1
    Invoke-Aio command pane.split_up
    Invoke-Aio wait text 'PS '
    Invoke-Aio command pane.close
    Invoke-Aio expect state tab.1.panes=1
    $path = Join-Path $data 'settings.ini'
    [IO.File]::AppendAllText($path, "`nkeys.pane.zoom = Ctrl+Shift+Z`n")
    Invoke-Aio command settings.reload
    Invoke-Aio key Ctrl+Shift+Z
    Invoke-Aio expect state tab.1.zoomed=true
    Invoke-Aio command pane.split_down
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state tab.1.zoomed=false
    Invoke-Aio expect state panes.count=2
    Invoke-Aio command pane.close
    Invoke-Aio expect state panes.count=1
    Write-Output 'PASS pane actions journey'
} finally {
    Invoke-Aio stop
}

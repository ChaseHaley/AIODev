param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'pane-tabs'
$directory = "$repo/build/verify/$name"
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Tab-Point([int] $Index) {
    $s = Read-State
    $key = "tab.$Index.rect"
    if (-not $s.ContainsKey($key)) { throw "State lacks $key; the tab rail row is unknown." }
    $r = $s[$key] -split ','
    return "$([int]([double]$r[0]+[double]$r[2]/2)),$([int]([double]$r[1]+[double]$r[3]/2))"
}
function New-Tab-Point {
    $s = Read-State
    $r = $s['rail.new_tab'] -split ','
    return "$([int]([double]$r[0]+[double]$r[2]/2)),$([int]([double]$r[1]+[double]$r[3]/2))"
}
function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $s = @{}
    foreach ($line in $out) { $pair = $line -split '=',2; $s[$pair[0]] = $pair[1].Trim('"') }
    return $s
}
function Assert-Value($Actual, $Expected, $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Grab {
    $s = Read-State
    $r = $s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ }
    $scale = [double]$s['window.scale']
    return "$([int]($r[0]+60*$scale)),$([int]($r[1]+14*$scale))"
}
function Drop-Point { return New-Tab-Point }
function Shot($Label) {
    & "$repo/tools/win32.ps1" -Name $name -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio key Ctrl+Shift+L
    Invoke-Aio wait text 'PS '
    foreach ($dpi in @(96,144,168)) {
        Invoke-Aio dpi $dpi
        Invoke-Aio command pane.split_right
        Invoke-Aio wait text 'PS '
        Invoke-Aio run "Write-Output 'PANE_TAB_MARKER'"
        $s = Read-State
        $runtime, $sessions, $tabs = $s['session.id'], $s['sessions.count'], [int]$s['tabs.count']
        $grab, $drop = (Grab), (Drop-Point)
        Invoke-Aio mouse down $grab --px
        Invoke-Aio mouse move $drop --px
        Assert-Value (Read-State)['panes.drop.new_tab'] true 'empty strip offers a new tab'
        Assert-Value (Read-State)['panes.drop.shown'] true 'new tab indicator is visible'
        Start-Sleep -Milliseconds 220
        Shot "new-tab-$dpi"
        $frames = (Read-State)['frames.presented']
        Start-Sleep -Milliseconds 250
        Assert-Value (Read-State)['frames.presented'] $frames 'settled ghost draws no idle frames'
        Invoke-Aio key Esc
        Invoke-Aio mouse up $drop --px
        Assert-Value (Read-State)['tabs.count'] $tabs 'Escape keeps the tab count'
        Assert-Value (Read-State)['panes.count'] 2 'Escape keeps both panes'
        Invoke-Aio mouse down $grab --px
        Invoke-Aio mouse move $drop --px
        Invoke-Aio focus out
        Invoke-Aio mouse up $drop --px
        Assert-Value (Read-State)['tabs.count'] $tabs 'focus loss cancels tab creation'
        Invoke-Aio focus in
        Invoke-Aio mouse drag $grab $drop --px
        $s = Read-State
        Assert-Value $s['tabs.count'] ($tabs+1) 'dropping a split pane appends a tab'
        Assert-Value $s['tabs.selected'] ($tabs+1) 'new tab is selected'
        Assert-Value $s['panes.count'] 1 'new tab has one pane'
        Assert-Value $s['session.id'] $runtime 'dragged runtime survives'
        Assert-Value $s['sessions.count'] $sessions 'drop creates no shell process'
        Invoke-Aio expect text PANE_TAB_MARKER
        Invoke-Aio command tab.previous
        Assert-Value (Read-State)['panes.count'] 1 'source keeps its remaining pane'
    }
    Invoke-Aio dpi 96
    Invoke-Aio command tab.select_1
    $s = Read-State
    $runtime, $tabId, $tabs = $s['session.id'], $s['tab.1.id'], $s['tabs.count']
    $grab, $drop = (Grab), (Drop-Point)
    Invoke-Aio mouse drag $grab $drop --px
    $s = Read-State
    Assert-Value $s['tabs.count'] $tabs 'sole pane reuses its tab'
    Assert-Value $s['session.id'] $runtime 'sole pane runtime survives'
    Assert-Value $s["tab.$tabs.id"] $tabId 'sole tab moves to the end'
    [IO.File]::AppendAllText("$directory/settings.ini", "`ntheme.name = studio-light`n")
    Invoke-Aio command settings.reload
    Invoke-Aio command pane.split_right
    Invoke-Aio wait text 'PS '
    $grab, $drop = (Grab), (Drop-Point)
    Invoke-Aio mouse down $grab --px
    Invoke-Aio mouse move $drop --px
    Start-Sleep -Milliseconds 220
    Shot new-tab-light
    Invoke-Aio key Esc
    Invoke-Aio mouse up $drop --px
    $before = Read-State
    $from = $grab -split ','
    $to = $drop -split ','
    & "$repo/tools/win32.ps1" -Name $name -Mouse drag -X ([int]$from[0]) -Y ([int]$from[1]) `
        -X2 ([int]$to[0]) -Y2 ([int]$to[1]) -Pointer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Native pointer drag failed.' }
    Assert-Value (Read-State)['tabs.count'] ([int]$before['tabs.count']+1) 'native mouse messages drop over the caption region'
    Write-Output 'PASS pane to new tab identity, cancellation, DPI, indicator and sole-pane behavior'
} finally { & $ctl --name $name stop | Out-Null }

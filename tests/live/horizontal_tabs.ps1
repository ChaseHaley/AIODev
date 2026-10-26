[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'horizontal-tabs'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'

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

function Rect-Center([string] $Rect) {
    $r = $Rect -split ','
    return "$([int]([double]$r[0]+[double]$r[2]/2)),$([int]([double]$r[1]+[double]$r[3]/2))"
}

function Tab-Point([int] $Index) {
    $s = Read-State
    $key = "tab.$Index.strip_rect"
    if (-not $s.ContainsKey($key)) { throw "State lacks $key; the horizontal strip is not laid out." }
    return (Rect-Center $s[$key])
}

function Close-Point([int] $Index) {
    return (Rect-Center (Read-State)["tab.$Index.strip_close"])
}

function Click([string] $Point) {
    Invoke-Aio mouse click $Point --px
}

Invoke-Aio launch --fresh
try {
    $initial = Read-State
    Assert-Value $initial['tabs.orientation'] vertical 'the default tab placement stays vertical'
    Assert-Value $initial['rail.visible'] true 'the default rail is visible'
    Invoke-Aio key Ctrl+Shift+L
    $horizontal = Read-State
    Assert-Value $horizontal['tabs.orientation'] horizontal 'Ctrl+Shift+L switches to horizontal tabs'
    Assert-Value $horizontal['rail.visible'] false 'the vertical rail leaves horizontal mode'
    if ([double]$horizontal['title.controls_end'] -ge [double]$horizontal['title.caption_start']) {
        throw 'the horizontal strip does not leave a caption drag region'
    }
    Write-Output 'PASS the horizontal strip leaves a caption drag region'
    $pane = $horizontal['pane.0.rect'] -split ','
    Assert-Value $pane[0] 5 'the pane starts at the outer gap without a rail'
    $tabsBefore = [int]$horizontal['tabs.count']
    Invoke-Aio command tab.new
    Invoke-Aio command tab.new
    Invoke-Aio command tab.new
    Assert-Value ([int](Read-State)['tabs.count']) ($tabsBefore + 3) 'the strip adds tabs'
    $before = Read-State
    if ([double]$before['tab.2.strip_rect'].Split(',')[2] -le 0) { throw 'the second strip tab has no width' }
    Write-Output 'PASS every strip tab has a rect'
    Click (Tab-Point 2)
    Assert-Value (Read-State)['tabs.selected'] 2 'clicking a strip tab selects it'
    Click (Close-Point 2)
    Assert-Value ([int](Read-State)['tabs.count']) ($tabsBefore + 2) 'the strip close control closes a tab'
    $before = Read-State
    $firstId = $before['tab.1.id']
    $secondId = $before['tab.2.id']
    Invoke-Aio mouse down (Tab-Point 2) --px
    Invoke-Aio mouse move (Tab-Point 1) --px
    Invoke-Aio mouse up (Tab-Point 1) --px
    $after = Read-State
    Assert-Value $after['tab.1.id'] $secondId 'dragging reorders the strip'
    Assert-Value $after['tab.2.id'] $firstId 'the displaced tab follows the dragged tab'
    $count = [int]$after['tabs.count']
    Click (Rect-Center $after['tabs.new_tab'])
    Assert-Value ([int](Read-State)['tabs.count']) ($count + 1) 'the strip plus button adds a tab'
    Invoke-Aio key 'Ctrl+,'
    Invoke-Aio type tabs.orientation
    Assert-Value (Read-State)['settings.value'] horizontal 'Settings shows the horizontal choice'
    Invoke-Aio key Ctrl+Shift+L
    $back = Read-State
    Assert-Value $back['tabs.orientation'] vertical 'Ctrl+Shift+L returns to vertical tabs'
    Assert-Value $back['settings.value'] vertical 'the open Settings page follows the shortcut'
    Assert-Value $back['rail.visible'] true 'the rail returns in vertical mode'
    if ([double]$back['rail.rows'] -lt 2) { throw 'the returned rail has no rows' }
    Write-Output 'PASS the returned rail has rows'
    Invoke-Aio key Ctrl+A
    Invoke-Aio type interface.hover_lift
    Invoke-Aio key Tab
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 1.6
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.error'] false 'an edit after the shortcut saves without a conflict'
    $saved = [IO.File]::ReadAllText($path)
    if ($saved -notmatch '(?m)^interface\.hover_lift = 1\.6$') { throw 'the edit after the shortcut was not saved.' }
    Write-Output 'PASS the edit after the shortcut is saved'
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 1.5
    Invoke-Aio key Enter
    Invoke-Aio command settings.open
    Invoke-Aio command tab.close
    $saved = [IO.File]::ReadAllText($path)
    if ($saved -notmatch '(?m)^tabs\.orientation = vertical$') { throw 'the orientation was not persisted.' }
    Write-Output 'PASS the orientation is persisted'
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame -Shot (Join-Path $directory 'horizontal-tabs.png')
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
} finally {
    & $ctl --name $name stop | Out-Null
}

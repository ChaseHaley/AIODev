[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'settings-ui'
$path = Join-Path $repo "build/verify/$name/settings.ini"

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}

function Read-State {
    $result = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $result) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1]
    }
    return $state
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

function Close-Settings {
    if ((Read-State)['settings.open'] -eq 'true') {
        Invoke-Aio command settings.open
        Invoke-Aio command tab.close
    }
}

function Open-Field([string] $Key, [switch] $NoFocus) {
    Close-Settings
    Invoke-Aio key 'Ctrl+,'
    Invoke-Aio type $Key
    Assert-Value (Read-State)['settings.key'] $Key "select $Key"
    if (-not $NoFocus) { Invoke-Aio key Tab }
}

function Capture-Keys([string[]] $Chords) {
    Assert-Value (Read-State)['settings.capturing'] 'true' 'shortcut field records keys'
    Invoke-Aio key @Chords
    Invoke-Aio key Enter
}

function Save-Value([string] $Value) {
    Invoke-Aio key Ctrl+A
    Invoke-Aio type $Value
    Invoke-Aio key Enter
}

Invoke-Aio launch --fresh
try {
    $originalSession = (Read-State)['session.id']
    Open-Field font.size
    Save-Value 14
    Assert-Value (Read-State)['settings.error'] 'false' 'valid font applied'
    $saved = [IO.File]::ReadAllText($path)
    if ($saved -notmatch '(?m)^font.size = 14$') { throw 'Font size not persisted.' }
    Save-Value 0
    Assert-Value (Read-State)['settings.error'] 'true' 'out of range rejected'
    Assert-Value ([IO.File]::ReadAllText($path)) $saved 'invalid edit preserves file'
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 18
    Invoke-Aio key Esc
    Assert-Value ([IO.File]::ReadAllText($path)) $saved 'cancel preserves file'

    Open-Field font.size
    Invoke-Aio key Ctrl+R
    Assert-Value (Read-State)['settings.value'] '12' 'reset saves schema default'
    [IO.File]::AppendAllText($path, "`n# external comment`nfuture.key = retained`n")
    $external = [IO.File]::ReadAllText($path)
    Save-Value 13
    Assert-Value (Read-State)['settings.error'] 'true' 'external edit conflict reported'
    Assert-Value ([IO.File]::ReadAllText($path)) $external 'external edit preserved'

    Open-Field window.show_tab_bar_with_one_tab -NoFocus
    Assert-Value (Read-State)['settings.title'].Trim('"') 'Show Tab Bar With One Tab' 'friendly setting name'
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.error'] 'false' 'boolean saved despite unrelated unknown key'
    Assert-Value (Read-State)['settings.value'] 'false' 'Enter flips an inline toggle'
    Close-Settings
    Assert-Value ((Read-State)['pane.0.rect'] -split ',')[1] '45' 'hidden tabs retain the window title bar'
    if ([IO.File]::ReadAllText($path) -notlike '*# external comment*future.key = retained*') {
        throw 'Unrelated text was lost.'
    }
    Open-Field shell.directory
    Save-Value $repo
    if ((Read-State)['settings.message'] -notlike '*new or restarted shells*') { throw 'Missing restart guidance.' }
    Close-Settings
    Assert-Value (Read-State)['session.id'] $originalSession 'shell setting does not restart session'

    Open-Field input.leader
    Capture-Keys Ctrl+Shift+P
    Assert-Value (Read-State)['settings.error'] 'false' 'leader conflict saves with source-order warning'
    if ((Read-State)['settings.message'] -notlike '*app.command_palette*') { throw 'Missing named conflict warning.' }
    Invoke-Aio key Enter
    Capture-Keys Ctrl+B
    Assert-Value (Read-State)['settings.error'] 'false' 'leader enabled explicitly'
    Open-Field keys.tab.new
    $beforeConflict = [IO.File]::ReadAllText($path)
    Capture-Keys Ctrl+Shift+P
    Assert-Value (Read-State)['settings.error'] 'true' 'conflicting shortcut rejected'
    Assert-Value ([IO.File]::ReadAllText($path)) $beforeConflict 'conflict preserves shortcut file'
    Invoke-Aio key Enter Shift+A
    Assert-Value (Read-State)['settings.error'] 'true' 'typing key without a modifier refused'
    $recorded = (Read-State)['settings.value']
    Invoke-Aio key 'Left Ctrl'
    Assert-Value (Read-State)['settings.value'] $recorded 'modifier presses alone record nothing'
    Capture-Keys Ctrl+Shift+T,Ctrl+B,T
    Assert-Value (Read-State)['settings.error'] 'false' 'direct and leader binding saved'
    if ([IO.File]::ReadAllText($path) -notmatch '(?m)^keys\.tab\.new = Ctrl\+Shift\+T, Leader\+T\r?$') {
        throw 'Captured binding not persisted.'
    }
    Close-Settings
    Invoke-Aio key Ctrl+Shift+T
    Assert-Value (Read-State)['tabs.count'] '2' 'direct shortcut remains available'
    Invoke-Aio key Ctrl+B
    Assert-Value (Read-State)['leader.pending'] 'true' 'leader prefix arms'
    Assert-Value (Read-State)['leader.indicator'] 'pane-status-line' 'pending leader shows the chosen status line'
    Invoke-Aio key T
    Assert-Value (Read-State)['tabs.count'] '3' 'leader action dispatches'
    Invoke-Aio key Ctrl+B
    Invoke-Aio key Esc
    Assert-Value (Read-State)['leader.pending'] 'false' 'Escape cancels leader'
    Assert-Value (Read-State)['leader.indicator'] 'none' 'cancel clears the status line'
    Invoke-Aio key Ctrl+B
    Invoke-Aio focus out
    Assert-Value (Read-State)['leader.pending'] 'false' 'focus loss cancels leader'
    Invoke-Aio key Ctrl+B
    Invoke-Aio command settings.reload
    Assert-Value (Read-State)['leader.pending'] 'false' 'reload cancels leader'
    Invoke-Aio key Ctrl+B
    Start-Sleep -Milliseconds 2200
    Assert-Value (Read-State)['leader.pending'] 'false' 'leader expires after two seconds'
    Assert-Value (Read-State)['leader.indicator'] 'none' 'timeout clears the status line'
    Invoke-Aio key Ctrl+B
    Invoke-Aio key X
    Assert-Value (Read-State)['tabs.count'] '3' 'unmatched leader leaves layout unchanged'
    Assert-Value (Read-State)['leader.pending'] 'false' 'unmatched leader ends sequence'

    Open-Field keys.tab.new -NoFocus
    Invoke-Aio key Ctrl+R
    Assert-Value (Read-State)['settings.error'] 'false' 'shortcut reset saves direct defaults'
    Close-Settings
    Invoke-Aio key Ctrl+Shift+T
    Assert-Value (Read-State)['tabs.count'] '4' 'default shortcut restored'
    Open-Field colors.cursor
    Save-Value 'rgb(255, 136, 0)'
    Assert-Value (Read-State)['settings.value'] '#ff8800' 'pasted rgb color normalized'
    if ([IO.File]::ReadAllText($path) -notmatch '(?m)^colors\.cursor = #ff8800\r?$') { throw 'Color not persisted as hex.' }
    Save-Value 'hsl(120, 100%, 25%)'
    Assert-Value (Read-State)['settings.value'] '#008000' 'pasted hsl color normalized'
    Close-Settings
    Invoke-Aio key 'Ctrl+,'
    Assert-Value (Read-State)['settings.active'] 'true' 'settings opens as the selected tab'
    Assert-Value (Read-State)['tabs.count'] '5' 'settings tab joins the tab strip'
    Invoke-Aio key Ctrl+Tab
    Assert-Value (Read-State)['settings.active'] 'false' 'tab shortcuts leave the settings tab'
    Assert-Value (Read-State)['settings.open'] 'true' 'settings tab stays open in the background'
    Invoke-Aio key 'Ctrl+,'
    Assert-Value (Read-State)['tabs.count'] '5' 'reopening selects the existing settings tab'
    Invoke-Aio type panes
    Assert-Value (Read-State)['settings.key'] 'pane.gap' 'group search finds pane settings'
    Invoke-Aio key Ctrl+N
    Assert-Value (Read-State)['settings.key'] 'pane.corner_radius' 'Ctrl+N selects next setting'
    Invoke-Aio key Ctrl+P
    Assert-Value (Read-State)['settings.key'] 'pane.gap' 'Ctrl+P selects previous setting'
    Invoke-Aio key Esc
    Invoke-Aio key Ctrl+Shift+P
    Invoke-Aio type 'stray text'
    Invoke-Aio key Ctrl+A Backspace
    Assert-Value (Read-State)['palette.query'] '""' 'Ctrl+A selects and clears palette query'
    Invoke-Aio type term
    if ([int](Read-State)['palette.items'] -lt 3) { throw 'Group search for term found too little.' }
    Write-Output 'PASS palette fuzzy-matches the Terminal group'
    Invoke-Aio key Ctrl+A Backspace
    Invoke-Aio type panes
    Invoke-Aio key Ctrl+N Ctrl+N Ctrl+P
    Assert-Value (Read-State)['palette.selected'] '1' 'palette Ctrl+N and Ctrl+P navigate'
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 'pane gap'
    Assert-Value (Read-State)['palette.item'] 'pane.gap' 'palette lists settings'
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.key'] 'pane.gap' 'palette opens the chosen setting'
    Assert-Value (Read-State)['settings.editing'] 'true' 'palette focuses the setting value'
    Close-Settings
    Invoke-Aio command settings.open
    Invoke-Aio dpi 168
    Assert-Value (Read-State)['settings.open'] 'true' 'settings remains open at 175 percent DPI'
    Invoke-Aio dpi 96
    Invoke-Aio key Esc
    Invoke-Aio stop
    Invoke-Aio launch
    Invoke-Aio key 'Ctrl+,'
    Invoke-Aio type shell.directory
    Invoke-Aio key Tab
    if ((Read-State)['settings.value'] -notlike "*$repo*") { throw 'Settings did not survive relaunch.' }
    Write-Output 'PASS settings persist across process restart'
} finally {
    & $ctl --name $name stop | Write-Output
}

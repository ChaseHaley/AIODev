[CmdletBinding()]
param()

# WORK-407: search the palette and Settings by keybinding. Typed shortcut text matches in the palette's
# All and Commands scopes with the matched keycaps lit; a free chord is offered and assigned; Alt+K and
# the keyboard button record a chord, the leader and a key-position binding as the query on both surfaces.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'keybinding-search'
$path = Join-Path $repo "build/verify/$name/settings.ini"
$shots = Join-Path $repo 'build/keybinding-search'
New-Item -ItemType Directory -Force $shots | Out-Null

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}

function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $state[$pair[0]] = $pair[1].Trim('"') }
    }
    return $state
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

function Shot([string] $Label) {
    Invoke-Aio capture --out (Join-Path $shots "$Label.png") | Out-Null
}

function Click-Rect([string] $Rect) {
    $r = @($Rect -split ',' | ForEach-Object { [double]$_ })
    Invoke-Aio mouse click "$([int]($r[0] + $r[2] / 2)),$([int]($r[1] + $r[3] / 2))" --px | Out-Null
}

function Set-Settings([string] $Lines, [string] $Expect) {
    $text = [IO.File]::ReadAllText($path).TrimEnd()
    [IO.File]::WriteAllText($path, "$text`n$Lines`n")
    Invoke-Aio command settings.reload | Out-Null
    Invoke-Aio expect state $Expect | Out-Null
}

# Both themes show the same surfaces: the palette recording and recorded, a text match, and Settings.
function Capture-Surfaces([string] $Theme) {
    Invoke-Aio key Ctrl+Shift+P | Out-Null
    Invoke-Aio type 'alt8' | Out-Null
    Assert-Value (Read-State)['palette.match'] '[Alt]+[8]' "$Theme palette lights Alt+8"
    Shot "palette-text-alt8-$Theme"
    Invoke-Aio key Ctrl+A | Out-Null
    Invoke-Aio type 'ctrl+alt+g' | Out-Null
    Assert-Value (Read-State)['palette.item'] 'unassigned' "$Theme palette offers Ctrl+Alt+G"
    Shot "palette-unassigned-$Theme"
    Invoke-Aio key Alt+K | Out-Null
    Shot "palette-recording-$Theme"
    Invoke-Aio key Ctrl+Shift+C | Out-Null
    Assert-Value (Read-State)['palette.match'] '[Ctrl]+[Shift]+[C]' "$Theme palette records Copy"
    Shot "palette-recorded-$Theme"
    Invoke-Aio key Backspace Ctrl+Space | Out-Null
    Shot "palette-leader-$Theme"
    # Esc first drops the pending leader, then leaves record mode, then closes the palette.
    Invoke-Aio key Esc | Out-Null
    Assert-Value (Read-State)['palette.keys.text'] '' "$Theme Esc drops the pending leader"
    Invoke-Aio key Esc Esc | Out-Null
    Assert-Value (Read-State)['palette.open'] 'false' "$Theme palette closed"
    Invoke-Aio key 'Ctrl+,' | Out-Null
    Invoke-Aio key Ctrl+A | Out-Null
    Invoke-Aio type 'cs c' | Out-Null
    Assert-Value (Read-State)['settings.match'] '[Ctrl]+[Shift]+[C]' "$Theme Settings lights cs c"
    Shot "settings-text-csc-$Theme"
    Invoke-Aio key Alt+K | Out-Null
    Shot "settings-recording-$Theme"
    Invoke-Aio key Ctrl+Shift+C | Out-Null
    Shot "settings-recorded-$Theme"
    Invoke-Aio key Esc Ctrl+A | Out-Null
    Invoke-Aio type 'ctrl alt g' | Out-Null
    Assert-Value (Read-State)['settings.free'] 'Ctrl+Alt+G' "$Theme Settings offers a free chord"
    Shot "settings-free-$Theme"
    Invoke-Aio command settings.open | Out-Null
    Invoke-Aio command tab.close | Out-Null
}

Invoke-Aio launch --fresh
try {
    Set-Settings ("input.leader = Ctrl+Space`nkeys.tab.select_8 = Alt+8`n" +
        "keys.pane.focus_left = Ctrl+Alt+Left, Leader+H`nkeys.status.panel = Physical+Ctrl+Shift+Y") `
        'leader.enabled=true'

    # A: shortcut text in All and Commands; titles still come first.
    foreach ($entry in @(@('all', 'Ctrl+Shift+P'), @('commands', $null))) {
        if ($entry[1]) { Invoke-Aio key $entry[1] | Out-Null } else { Invoke-Aio command app.palette_commands | Out-Null }
        Assert-Value (Read-State)['palette.mode'] $entry[0] "palette opens in $($entry[0])"
        foreach ($query in @('alt8', 'al8')) {
            Invoke-Aio key Ctrl+A | Out-Null
            Invoke-Aio type $query | Out-Null
            $state = Read-State
            Assert-Value $state['palette.item'] 'tab.select_8' "$($entry[0]) '$query' finds Select Tab 8"
            Assert-Value $state['palette.match'] '[Alt]+[8]' "$($entry[0]) '$query' lights both keycaps"
        }
        foreach ($query in @('ctrl+shift+c', 'cs c')) {
            Invoke-Aio key Ctrl+A | Out-Null
            Invoke-Aio type $query | Out-Null
            Assert-Value (Read-State)['palette.item'] 'edit.copy' "$($entry[0]) '$query' finds Copy"
        }
        Invoke-Aio key Ctrl+A | Out-Null
        Invoke-Aio type 'leader h' | Out-Null
        Assert-Value (Read-State)['palette.match'] '[Leader]+[H]' "$($entry[0]) 'leader h' finds the sequence"
        Invoke-Aio key Ctrl+A | Out-Null
        Invoke-Aio type 'find' | Out-Null
        Assert-Value (Read-State)['palette.item'] 'terminal.find' "$($entry[0]) 'find' still selects Find"
        Invoke-Aio key Esc | Out-Null
    }

    # A: a free chord is one Unassigned row; choosing a command adds it through the shortcut editor.
    Invoke-Aio key Ctrl+Shift+P | Out-Null
    Invoke-Aio type 'ctrl+shift+g' | Out-Null
    $state = Read-State
    Assert-Value $state['palette.item'] 'unassigned' 'free chord leads with Unassigned'
    Assert-Value $state['palette.value'] 'Ctrl+Shift+G' 'Unassigned names the chord'
    Invoke-Aio key Enter | Out-Null
    $state = Read-State
    Assert-Value $state['palette.assign'] 'Ctrl+Shift+G' 'Unassigned asks for a command'
    Assert-Value $state['palette.mode'] 'commands' 'the command list is shown'
    Invoke-Aio type 'Split Right' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Assert-Value (Read-State)['palette.edit'] 'Shortcut' 'the shortcut editor opens with the chord'
    Invoke-Aio key Enter | Out-Null
    Assert-Value (Read-State)['palette.value'] 'Ctrl+Shift+O, Ctrl+Shift+G' 'the chord is added and applied'
    if ([IO.File]::ReadAllText($path) -notmatch '(?m)^keys\.pane\.split_right = Ctrl\+Shift\+O, Ctrl\+Shift\+G\r?$') {
        throw 'Assigned shortcut did not reach the file.'
    }
    Write-Output 'PASS assigned shortcut saved'
    Invoke-Aio key Esc | Out-Null

    # B, palette: Alt+K records Copy's own chord, Esc returns to typing with the chord as text.
    Invoke-Aio key Ctrl+Shift+P Alt+K | Out-Null
    Assert-Value (Read-State)['palette.keys'] 'Recording' 'Alt+K records in the palette'
    Invoke-Aio key Ctrl+Shift+C | Out-Null
    $state = Read-State
    Assert-Value $state['palette.keys'] 'Recorded' 'a chord completes the recording'
    Assert-Value $state['palette.items'] '1' 'exact match only'
    Assert-Value $state['palette.item'] 'edit.copy' 'Ctrl+Shift+C shows Copy only'
    Invoke-Aio key Esc | Out-Null
    $state = Read-State
    Assert-Value $state['palette.keys'] 'Off' 'Esc returns to typing'
    Assert-Value $state['palette.query'] 'Ctrl+Shift+C' 'the recorded chord stays as text'
    Assert-Value $state['palette.item'] 'edit.copy' 'the text search keeps Copy'
    Assert-Value $state['palette.open'] 'true' 'Esc from recording keeps the palette'

    # The leader lists its sequences and the next key narrows them; a Physical binding matches by key.
    Invoke-Aio key Alt+K Ctrl+Space | Out-Null
    Assert-Value (Read-State)['palette.keys.text'] 'Leader' 'the leader waits for its key'
    Invoke-Aio key H | Out-Null
    $state = Read-State
    Assert-Value $state['palette.item'] 'pane.focus_left' 'Leader then H finds Focus Left'
    Assert-Value $state['palette.match'] '[Leader]+[H]' 'the leader sequence is lit'
    Invoke-Aio key Backspace Ctrl+Shift+Y | Out-Null
    $state = Read-State
    Assert-Value $state['palette.item'] 'status.panel' 'a key-position binding matches'
    Assert-Value $state['palette.match'] 'Physical+[Ctrl]+[Shift]+[Y]' 'the position binding is lit'
    Click-Rect $state['palette.keys.button']
    Assert-Value (Read-State)['palette.keys'] 'Off' 'the keyboard button leaves record mode'
    Click-Rect (Read-State)['palette.keys.button']
    Assert-Value (Read-State)['palette.keys'] 'Recording' 'the keyboard button records'
    Invoke-Aio key Esc Esc | Out-Null
    Assert-Value (Read-State)['palette.open'] 'false' 'the palette closes as before'

    # B, Settings: the same recording in the search field, where Ctrl+Shift+C is otherwise Copy.
    Invoke-Aio key 'Ctrl+,' Alt+K | Out-Null
    Assert-Value (Read-State)['settings.keys'] 'Recording' 'Alt+K records in Settings'
    Invoke-Aio key Ctrl+Shift+C | Out-Null
    $state = Read-State
    Assert-Value $state['settings.rows'] '1' 'Settings shows one shortcut'
    Assert-Value $state['settings.key'] 'keys.edit.copy' 'Settings finds Copy'
    Invoke-Aio key Esc | Out-Null
    $state = Read-State
    Assert-Value $state['settings.keys'] 'Off' 'Esc returns Settings to typing'
    Assert-Value $state['settings.filter'] 'Ctrl+Shift+C' 'the chord stays as Settings text'
    Click-Rect $state['settings.keys.button']
    Assert-Value (Read-State)['settings.keys'] 'Recording' 'the Settings keyboard button records'
    Invoke-Aio key Ctrl+Space H | Out-Null
    $state = Read-State
    Assert-Value $state['settings.key'] 'keys.pane.focus_left' 'Settings records a leader sequence'
    Assert-Value $state['settings.match'] '[Leader]+[H]' 'Settings lights the sequence'
    Invoke-Aio key Tab | Out-Null
    $state = Read-State
    Assert-Value $state['settings.keys'] 'Off' 'leaving the field leaves record mode'
    Assert-Value $state['settings.key'] 'keys.pane.focus_left' 'the row stays selected'
    Invoke-Aio key Esc Esc | Out-Null
    # The empty Settings search offers a free chord; Enter hands it to the palette's command list.
    Invoke-Aio key Ctrl+A | Out-Null
    Invoke-Aio type 'ctrl alt y' | Out-Null
    Assert-Value (Read-State)['settings.free'] 'Ctrl+Alt+Y' 'Settings offers the free chord'
    Invoke-Aio key Enter | Out-Null
    $state = Read-State
    Assert-Value $state['palette.assign'] 'Ctrl+Alt+Y' 'Enter asks the palette for a command'
    Assert-Value $state['palette.mode'] 'commands' 'the palette lists commands to assign'
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio command settings.open | Out-Null
    Invoke-Aio command tab.close | Out-Null

    Capture-Surfaces 'dark'
    Set-Settings 'theme.name = studio-light' 'theme.name=studio-light'
    Capture-Surfaces 'light'
    Write-Output "PASS keybinding search; screenshots in $shots"
} finally {
    & $ctl --name $name stop | Write-Output
}

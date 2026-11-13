[CmdletBinding()]
param()

# Keyboard pane moves and Arrange mode (WORK-477). The pane commands land where a header drag would, and
# Arrange Panes takes the keys, marks the pane with the drag's drop outline and shows a card of its keys.
# Captures of the card and outline in a dark and a light theme go to build/captures/arrange.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'arrange-mode'
$data = Join-Path $repo "build/verify/$name"
$captures = Join-Path $repo 'build/captures/arrange'
New-Item -ItemType Directory -Force -Path $captures | Out-Null

function Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    return $result
}

function State {
    $s = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        $s[$pair[0]] = $pair[1].Trim('"')
    }
    return $s
}

function Rect($s, $node) { return @($s["pane.$node.rect"] -split ',' | ForEach-Object { [double]$_ }) }

function Check([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "FAIL $Label" }
    Write-Output "PASS $Label"
}

# The panes of the shown tab, by node, with the session each shows.
function Pane-Of($s, $session) {
    foreach ($key in $s.Keys) {
        if ($key -match '^tab\.\d+\.pane\.(\d+)\.session$' -and $s[$key] -eq "$session") { return $Matches[1] }
    }
    throw "no pane shows session $session"
}

function Set-Theme([string] $Theme) {
    $settings = Join-Path $data 'settings.ini'
    $text = [IO.File]::ReadAllText($settings)
    $text = [regex]::Replace($text, '(?m)^theme\.name\s*=.*\r?\n?', '')
    [IO.File]::WriteAllText($settings, $text.TrimEnd() + "`ntheme.name = $Theme`n")
    Aio command settings.reload | Out-Null
    Aio wait idle | Out-Null
    Aio expect state "theme.name=$Theme" | Out-Null
}

Aio launch --fresh --size 140x40 | Out-Null
try {
    Aio wait text 'PS ' | Out-Null
    $a = (State)['session.id']
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    $b = (State)['session.id']

    # The commands, from the palette's command line.
    Aio command pane.move_left | Out-Null
    $s = State
    Check ((Rect $s (Pane-Of $s $b))[0] -lt (Rect $s (Pane-Of $s $a))[0]) 'Move pane left passes the neighbour'
    Aio command pane.move_right | Out-Null
    Aio command pane.rotate_split | Out-Null
    $s = State
    Check ((Rect $s (Pane-Of $s $b))[1] -gt (Rect $s (Pane-Of $s $a))[1]) 'Rotate split stacks the pair'
    Aio command pane.rotate_split | Out-Null
    Aio command pane.dock_down | Out-Null
    $s = State
    Check ((Rect $s (Pane-Of $s $b))[1] -gt (Rect $s (Pane-Of $s $a))[1]) 'Dock pane to bottom edge'
    Aio command pane.move_up | Out-Null
    $s = State
    Check ((Rect $s (Pane-Of $s $b))[1] -lt (Rect $s (Pane-Of $s $a))[1]) 'Move pane up passes the neighbour'
    Aio command pane.rotate_split | Out-Null
    Aio command pane.swap_right | Out-Null
    $s = State
    Check ((Rect $s (Pane-Of $s $b))[0] -gt (Rect $s (Pane-Of $s $a))[0]) 'Swap pane right'

    # The mode from the palette, as a person finds it.
    Aio key Ctrl+Shift+P | Out-Null
    Aio type 'Arrange panes' | Out-Null
    Aio expect state palette.item=pane.arrange | Out-Null
    Aio key Enter | Out-Null
    Aio expect state overlay=arrange | Out-Null
    Aio key Esc | Out-Null
    Aio expect state overlay=none | Out-Null
    Write-Output 'PASS Arrange panes from the palette'

    foreach ($theme in @('studio-dark', 'studio-light')) {
        Set-Theme $theme
        Aio command pane.arrange | Out-Null
        Aio expect state overlay=arrange | Out-Null
        Aio wait idle | Out-Null
        Aio capture --out "$captures/$theme-card.png" | Out-Null
        Aio key Left | Out-Null
        Aio wait idle | Out-Null
        $s = State
        Check ((Rect $s (Pane-Of $s $b))[0] -lt (Rect $s (Pane-Of $s $a))[0]) "$theme Left moves the pane"
        Aio capture --out "$captures/$theme-moved.png" | Out-Null
        Aio key Shift+Right | Out-Null
        $s = State
        Check ((Rect $s (Pane-Of $s $b))[0] -gt (Rect $s (Pane-Of $s $a))[0]) "$theme Shift+Right swaps"
        $width = (Rect $s (Pane-Of $s $b))[2]
        Aio key Ctrl+Left | Out-Null
        $s = State
        Check ((Rect $s (Pane-Of $s $b))[2] -ne $width) "$theme Ctrl+Left resizes"
        Aio type 'ZQZQ' | Out-Null
        Aio key Q | Out-Null
        Aio expect state overlay=arrange | Out-Null
        Aio expect no-text ZQZQ | Out-Null
        Write-Output "PASS $theme typing is swallowed"
        Aio key Esc | Out-Null
        Aio expect state overlay=none | Out-Null
        $s = State
        Check ((Rect $s (Pane-Of $s $b))[2] -ne $width) "$theme Esc keeps the change"
        Aio command pane.balance | Out-Null
    }

    # A click leaves the mode and reaches the pane it lands on; the palette leaves it too.
    Aio command pane.arrange | Out-Null
    $s = State
    $pane = Rect $s (Pane-Of $s $a)
    Aio mouse click "$([int]($pane[0] + $pane[2] / 2)),$([int]($pane[1] + $pane[3] / 2))" --px | Out-Null
    Aio expect state overlay=none | Out-Null
    Aio expect state "session.id=$a" | Out-Null
    Write-Output 'PASS a click leaves and focuses the pane under it'
    Aio command pane.arrange | Out-Null
    Aio key Ctrl+Shift+P | Out-Null
    Aio expect state overlay=palette | Out-Null
    Aio key Esc | Out-Null
    Write-Output 'PASS the palette leaves the mode'

    # Tabs and windows, as drops on the tab strip and outside the window.
    Aio command pane.move_new_tab | Out-Null
    Aio expect state tabs.count=2 | Out-Null
    Aio command pane.move_tab_1 | Out-Null
    Aio expect state tabs.count=1 | Out-Null
    Aio command pane.move_new_window | Out-Null
    Aio expect state windows.count=2 | Out-Null
    Write-Output 'PASS new tab, tab 1 and new window'

    # The new window took focus; the rest of the journey works in the first one.
    Aio window select ((State)['window.1.id']) | Out-Null

    # About 700 px wide the card flows into fewer columns and stays inside the panes. Resize sizes the
    # focused terminal, so a tab of one pane gives it a known width per column.
    Aio command tab.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    $s = State
    $grid = @($s['grid.size'] -split 'x' | ForEach-Object { [int]$_ })
    $wide = [int]($s['window.size'] -split 'x')[0]
    Aio resize "$($grid[0] - 40)x$($grid[1])" | Out-Null
    $narrower = [int]((State)['window.size'] -split 'x')[0]
    $cell = ($wide - $narrower) / 40
    $columns = [int]($grid[0] - 40 - ($narrower - 700) / $cell)
    Aio resize "$($columns)x$($grid[1])" | Out-Null
    $size = [int]((State)['window.size'] -split 'x')[0]
    Check ([math]::Abs($size - 700) -le 40) "window about 700 px wide ($size)"
    foreach ($theme in @('studio-light', 'studio-dark')) {
        Set-Theme $theme
        Aio command pane.arrange | Out-Null
        Aio expect state overlay=arrange | Out-Null
        Aio wait idle | Out-Null
        Aio capture --out "$captures/$theme-narrow-card.png" | Out-Null
        Aio key Esc | Out-Null
    }
} finally { & $ctl --name $name stop | Out-Null }

[CmdletBinding()]
param()

# Keyboard pane moves and Arrange mode (WORK-477). The pane commands land where a header drag would, and
# Arrange Panes takes the keys until Esc, marks the pane with the drag's drop outline and shows a card of its
# keys. Captures of the card and outline in a dark and a light theme, of the owner's column of three moved
# step by step, and of the card in a narrow window go to build/captures/arrange.
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
    Aio expect state arrange=true | Out-Null
    Aio key Esc | Out-Null
    Aio expect state arrange=false | Out-Null
    Write-Output 'PASS Arrange panes from the palette'

    foreach ($theme in @('studio-dark', 'studio-light')) {
        Set-Theme $theme
        Aio command pane.arrange | Out-Null
        Aio expect state arrange=true | Out-Null
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
        Aio expect state arrange=true | Out-Null
        Aio expect no-text ZQZQ | Out-Null
        Write-Output "PASS $theme typing is swallowed"
        Aio key Esc | Out-Null
        Aio expect state arrange=false | Out-Null
        $s = State
        Check ((Rect $s (Pane-Of $s $b))[2] -ne $width) "$theme Esc keeps the change"
        Aio command pane.balance | Out-Null
    }

    # A click keeps the mode and reaches the pane it lands on, which the mode moves to; the palette pauses
    # the mode and hides its card until it closes; Enter does nothing; only Esc leaves.
    Aio command pane.arrange | Out-Null
    $s = State
    $pane = Rect $s (Pane-Of $s $a)
    Aio mouse click "$([int]($pane[0] + $pane[2] / 2)),$([int]($pane[1] + $pane[3] / 2))" --px | Out-Null
    Aio expect state arrange=true | Out-Null
    Aio expect state "session.id=$a" | Out-Null
    Write-Output 'PASS a click keeps the mode and focuses the pane under it'
    Aio key Ctrl+Shift+P | Out-Null
    Aio expect state overlay=palette | Out-Null
    Aio wait idle | Out-Null
    Aio expect state arrange=true | Out-Null
    Aio expect state arrange.card=false | Out-Null
    Aio key Esc | Out-Null
    Aio expect state overlay=none | Out-Null
    Aio wait idle | Out-Null
    Aio expect state arrange.card=true | Out-Null
    Write-Output 'PASS the palette pauses the mode'
    Aio key Enter | Out-Null
    Aio expect state arrange=true | Out-Null
    Aio key Esc | Out-Null
    Aio expect state arrange=false | Out-Null
    Write-Output 'PASS only Esc leaves'

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

    # The owner's column of three: A over the top half, B and C a quarter each below. Right on C turns it
    # beside B under A; Right on B passes C; Right again docks B along the right edge at full height.
    Set-Theme 'studio-dark'
    Aio command tab.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    $ca = (State)['session.id']
    Aio command pane.split_down | Out-Null
    Aio wait text 'PS ' | Out-Null
    $cb = (State)['session.id']
    Aio command pane.split_down | Out-Null
    Aio wait text 'PS ' | Out-Null
    $cc = (State)['session.id']
    Aio command pane.arrange | Out-Null
    Aio wait idle | Out-Null
    Aio capture --out "$captures/abc-0-column.png" | Out-Null
    Aio key Right | Out-Null
    Aio wait idle | Out-Null
    $s = State
    $ra, $rb, $rc = (Rect $s (Pane-Of $s $ca)), (Rect $s (Pane-Of $s $cb)), (Rect $s (Pane-Of $s $cc))
    Check ($rb[1] -eq $rc[1] -and $rc[0] -gt $rb[0] -and $ra[2] -gt $rb[2] + $rc[2]) 'Right turns C beside B under A'
    Aio capture --out "$captures/abc-1-beside.png" | Out-Null
    Aio key Alt+Left | Out-Null
    Aio expect state "session.id=$cb" | Out-Null
    Aio key Right | Out-Null
    Aio wait idle | Out-Null
    $s = State
    $rb, $rc = (Rect $s (Pane-Of $s $cb)), (Rect $s (Pane-Of $s $cc))
    Check ($rb[0] -gt $rc[0] -and $rb[1] -eq $rc[1]) 'Right on B passes C'
    Aio capture --out "$captures/abc-2-passed.png" | Out-Null
    Aio key Right | Out-Null
    Aio wait idle | Out-Null
    $s = State
    $ra, $rb = (Rect $s (Pane-Of $s $ca)), (Rect $s (Pane-Of $s $cb))
    Check ($rb[1] -eq $ra[1] -and $rb[3] -gt $ra[3] -and $rb[0] -gt $ra[0]) 'Right again docks B at full height'
    Aio capture --out "$captures/abc-3-docked.png" | Out-Null
    Aio key Esc | Out-Null
    Aio expect state arrange=false | Out-Null

    # The owner's row: A and B a quarter each, C the right half, each pane named so the captures show
    # which is which. Each Right takes A one place: past B; into C's half beside C, still the middle pane;
    # past C; then the right half of the tab with B and C sharing the left half; then nothing.
    Aio command tab.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio run '$Host.UI.RawUI.WindowTitle = "A"; Clear-Host' | Out-Null
    $ra = (State)['session.id']
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio run '$Host.UI.RawUI.WindowTitle = "C"; Clear-Host' | Out-Null
    $rc = (State)['session.id']
    Aio command pane.focus_left | Out-Null
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio run '$Host.UI.RawUI.WindowTitle = "B"; Clear-Host' | Out-Null
    $rb = (State)['session.id']
    Aio command pane.focus_left | Out-Null
    Aio expect state "session.id=$ra" | Out-Null
    Aio command pane.arrange | Out-Null
    Aio wait idle | Out-Null
    Aio capture --out "$captures/row-0-start.png" | Out-Null
    $labels = @('', 'passed-b', 'entered-c-half', 'passed-c', 'right-half')
    foreach ($press in 1..4) {
        Aio key Right | Out-Null
        Aio wait idle | Out-Null
        Aio expect state "session.id=$ra" | Out-Null
        $s = State
        $pa, $pb, $pc = (Rect $s (Pane-Of $s $ra)), (Rect $s (Pane-Of $s $rb)), (Rect $s (Pane-Of $s $rc))
        $ok = switch ($press) {
            1 { $pb[0] -lt $pa[0] -and $pa[0] -lt $pc[0] -and $pc[2] -gt $pa[2] }
            2 { $pb[0] -lt $pa[0] -and $pa[0] -lt $pc[0] -and $pb[2] -gt $pa[2] -and $pa[2] -eq $pc[2] }
            3 { $pa[0] -gt $pc[0] -and $pc[0] -gt $pb[0] -and $pb[2] -gt $pa[2] }
            4 { $pa[0] -gt $pc[0] -and $pc[0] -gt $pb[0] -and $pa[2] -gt $pb[2] -and $pb[2] -eq $pc[2] }
        }
        Check $ok "row press $press $($labels[$press])"
        Aio capture --out "$captures/row-$press-$($labels[$press]).png" | Out-Null
    }
    $before = (State)["pane.$(Pane-Of (State) $ra).rect"]
    Aio key Right | Out-Null
    Aio wait idle | Out-Null
    $s = State
    Check ($s["pane.$(Pane-Of $s $ra).rect"] -eq $before) 'row press 5 changes nothing'
    Aio key Alt+Shift+Up | Out-Null
    Aio wait idle | Out-Null
    $s = State
    $pa, $pb = (Rect $s (Pane-Of $s $ra)), (Rect $s (Pane-Of $s $rb))
    Check ($pa[1] -lt $pb[1] -and $pa[2] -gt 2 * $pb[2]) 'Alt+Shift+Up makes A the top half'
    Aio capture --out "$captures/row-6-top-half.png" | Out-Null
    Aio key Esc | Out-Null

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
        Aio expect state arrange=true | Out-Null
        Aio wait idle | Out-Null
        Aio capture --out "$captures/$theme-narrow-card.png" | Out-Null
        Aio key Esc | Out-Null
    }
} finally { & $ctl --name $name stop | Out-Null }

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'tab-parity'
$directory = Join-Path $repo "build/verify/$name"
$source = Join-Path $repo 'build/tab-parity-settings.ini'

function Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
}
function State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect tab state.' }
    $state = @{}
    foreach ($line in $lines) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Equal($Actual, $Expected, $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Rect($Text) { return @($Text -split ',' | ForEach-Object { [double]$_ }) }
function Center($Text) {
    $r = Rect $Text
    return "$([int]($r[0]+$r[2]/2)),$([int]($r[1]+$r[3]/2))"
}
function Click($Text) { Aio mouse click (Center $Text) --px }
function Shot($Label) {
    Aio state | Out-Null
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame -Shot (Join-Path $directory "$Label.png") | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}

@'
tabs.orientation = vertical
profile.default.command = pwsh.exe -NoLogo -NoProfile
profile.cmd.name = Command Prompt
profile.cmd.command = cmd.exe
profile.cmd.directory = ~
profile.hidden.name = Hidden
profile.hidden.command = cmd.exe
profile.hidden.hidden = true
profile.order = cmd, default, hidden
shell.default_profile = default
cursor.blink = false
'@ | Set-Content -LiteralPath $source -Encoding utf8

Aio launch --fresh --settings $source
try {
    foreach ($orientation in @('vertical', 'horizontal')) {
        $s = State
        if ($s['tabs.orientation'] -ne $orientation) { Aio command view.tabs_orientation }
        $s = State
        $count = [int]$s['tabs.count']
        $dropdown = if ($orientation -eq 'vertical') { 'rail.profile' } else { 'tabs.chevron' }
        Click $s[$dropdown]
        Equal (State)['profile_menu.open'] true "$orientation has a visible profile dropdown"
        Equal (State)['tabs.count'] $count 'opening the profile dropdown creates no tab'
        Aio key Home Enter
        Equal (State)['tabs.count'] ($count + 1) "$orientation profile menu creates one tab"
        Aio expect state session.profile=cmd
        $s = State
        $plus = if ($orientation -eq 'vertical') { 'rail.new_tab' } else { 'tabs.new_tab' }
        Aio mouse click (Center $s[$plus]) --button right --px
        Equal (State)['profile_menu.open'] true "$orientation New tab right-click opens profiles"
        Aio key Esc
        Click (State)[$plus]
        Equal (State)['tabs.count'] ($count + 2) "$orientation New tab creates the default profile"
        Aio expect state session.profile=default
    }

    Aio command view.tabs_orientation
    foreach ($dpi in @(96, 144)) {
        Aio dpi $dpi
        Aio resize 120x32
        $s = State
        $scale = [double]$s['window.scale']
        $last = Rect $s["rail.row.$($s['rail.rows']).rect"]
        $plus = Rect $s['rail.new_tab']
        Equal ($plus[1] - $last[1] - $last[3]) (8 * $scale) "New tab follows the last tab at $dpi DPI"
        Shot "short-$dpi"
        Aio command pane.split_right
        Aio wait text 'PS '
        $before = State
        $pane = Rect $before["pane.$($before['panes.focused']).rect"]
        $grab = "$([int]($pane[0]+60*$scale)),$([int]($pane[1]+14*$scale))"
        $drop = Center $before['rail.new_tab']
        Aio mouse down $grab --px
        Aio mouse move $drop --px
        Equal (State)['panes.drop.new_tab'] true "New tab accepts a pane at $dpi DPI"
        Aio key Esc
        Aio mouse up $drop --px
        Equal (State)['tabs.count'] $before['tabs.count'] 'cancelling a pane drop preserves tabs'
        Aio mouse drag $grab $drop --px
        $after = State
        Equal $after['tabs.count'] ([int]$before['tabs.count'] + 1) 'dropping a pane creates a tab'
        Equal $after['session.id'] $before['session.id'] 'pane drop retains its runtime'
        Equal $after['sessions.count'] $before['sessions.count'] 'pane drop creates no shell process'
    }

    Aio dpi 96
    Aio resize 120x14
    while ([int](State)['tabs.count'] -lt 20) { Aio command tab.new }
    foreach ($dpi in @(96, 144)) {
        Aio dpi $dpi
        Aio resize 120x14
        $s = State
        $plus = $s['rail.new_tab']
        $profile = $s['rail.profile']
        $rail = Rect $s['rail.rect']
        $tile = Rect $plus
        $scale = [double]$s['window.scale']
        Equal ($tile[1] + $tile[3]) ($rail[1] + $rail[3] - 4 * $scale) "New tab is bottom pinned at $dpi DPI"
        $scrolls = @()
        foreach ($lines in @(100, -3, -100, 100)) {
            Aio mouse wheel '50,100' $lines --px
            $scrolls += (State)['rail.scroll']
            Equal (State)['rail.new_tab'] $plus 'scroll preserves the New tab position'
            Equal (State)['rail.profile'] $profile 'scroll preserves the profile dropdown position'
            Click $profile
            Equal (State)['profile_menu.open'] true 'pinned profile control remains clickable'
            Aio key Esc
        }
        if (@($scrolls | Sort-Object -Unique).Count -lt 2) { throw 'The tab list did not scroll.' }
        Write-Output "PASS overflow list actually scrolls at $dpi DPI"
        Shot "overflow-$dpi"
    }

    Aio resize 60x20
    Equal (State)['rail.visible'] false 'narrow windows hide the rail'
    Aio key Ctrl+Shift+B
    $s = State
    Equal $s['rail.overlay'] true 'narrow rail opens as an overlay'
    Click $s['rail.profile']
    Equal (State)['profile_menu.open'] true 'overlay exposes the same profile menu'
    Aio key Home Enter
    Aio expect state session.profile=cmd
    Equal (State)['rail.visible'] false 'choosing a profile dismisses the overlay'
} finally {
    & $ctl --name $name stop | Out-Null
}

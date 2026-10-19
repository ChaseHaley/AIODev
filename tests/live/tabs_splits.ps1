[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'tabs-splits'

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}

function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $values = @{}
    foreach ($line in $lines) {
        $pair = $line -split '=', 2
        $values[$pair[0]] = $pair[1]
    }
    return $values
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label=$Expected"
}

function Set-Marker([string] $Marker) {
    Invoke-Aio run ('function prompt { "P> " }; Clear-Host; $Host.UI.RawUI.WindowTitle = "' +
        $Marker + '"; Write-Output "' + $Marker + '"')
    Invoke-Aio expect text $Marker
    $state = Read-State
    Assert-Value $state["tab.$($state['tabs.selected']).title"] $Marker 'cached tab title'
}

function Assert-Isolated([string] $Marker, [string[]] $Others) {
    Invoke-Aio expect text $Marker
    foreach ($other in $Others) { Invoke-Aio expect no-text $other }
    $state = Read-State
    Assert-Value $state["tab.$($state['tabs.selected']).title"] $Marker 'focused-pane tab title'
}

$savedClipboard = Get-Clipboard -Raw
Invoke-Aio launch --fresh
try {
    $state = Read-State
    $node = $state['panes.focused']
    Assert-Value ($state["pane.$node.rect"] -split ',')[1] 45 'single-tab bar visible'
    Assert-Value $state['grid.size'] '120x32' 'startup grid reserves tab bar space'
    Invoke-Aio dpi 144
    Assert-Value ((Read-State)["pane.$node.rect"] -split ',')[1] 68 'single-tab bar scales with DPI'
    Invoke-Aio dpi 96
    Invoke-Aio resize 120x32
    Invoke-Aio expect state grid.size=120x32
    $windowSize = (Read-State)['window.size']
    Invoke-Aio tray hide
    Invoke-Aio tray open
    Assert-Value (Read-State)['window.size'] $windowSize 'tray reopen preserves bar-inclusive size'
    Invoke-Aio mouse click '225,15' --px
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state tabs.count=2
    Invoke-Aio key Ctrl+Shift+W
    Invoke-Aio expect state tabs.count=1
    Write-Output 'PASS single-tab new-tab button'
    Set-Marker 'TAB_ONE_ONLY'
    $firstId = (Read-State)['session.id']
    $firstGrid = (Read-State)['grid.size']
    Invoke-Aio run 'Start-Sleep -Milliseconds 1500; $Host.UI.RawUI.WindowTitle = "HIDDEN_TAB_TITLE"; Write-Output HIDDEN_TAB_ALIVE' --idle 50
    Invoke-Aio key Ctrl+Shift+T
    Invoke-Aio wait text 'PS '
    Assert-Value (Read-State)['tabs.count'] 2 'tab count'
    Assert-Value (Read-State)['tabs.selected'] 2 'selected tab'
    $firstGrid = (Read-State)['grid.size']
    Set-Marker 'LEFT_ONLY'
    $left = (Read-State)['session.id']
    Invoke-Aio key Ctrl+Shift+O
    Invoke-Aio wait text 'PS '
    Set-Marker 'TOP_ONLY'
    $top = (Read-State)['session.id']
    Invoke-Aio key Ctrl+Shift+E
    Invoke-Aio wait text 'PS '
    Set-Marker 'BOTTOM_ONLY'
    $bottom = (Read-State)['session.id']
    Invoke-Aio key 'Ctrl+Win+['
    Assert-Value (Read-State)['session.id'] $top 'previous split'
    Invoke-Aio key 'Ctrl+Win+]'
    Assert-Value (Read-State)['session.id'] $bottom 'next split'
    Invoke-Aio run 'Write-Output ("SHELL_PID=" + $PID)'
    $screen = & $ctl --name $name screen
    $shellPid = [int]([regex]::Match(($screen -join "`n"), '\|SHELL_PID=(\d+)').Groups[1].Value)
    if ($shellPid -le 0) { throw 'Missing child PID.' }
    Assert-Isolated 'BOTTOM_ONLY' @('TAB_ONE_ONLY', 'LEFT_ONLY', 'TOP_ONLY')
    Invoke-Aio key Ctrl+Alt+Up
    Assert-Value (Read-State)['session.id'] $top 'focus up'
    Assert-Isolated 'TOP_ONLY' @('TAB_ONE_ONLY', 'LEFT_ONLY', 'BOTTOM_ONLY')
    Invoke-Aio key Ctrl+Alt+Left
    Assert-Value (Read-State)['session.id'] $left 'focus left'
    Assert-Isolated 'LEFT_ONLY' @('TAB_ONE_ONLY', 'TOP_ONLY', 'BOTTOM_ONLY')
    Invoke-Aio key Ctrl+Alt+Right Ctrl+Alt+Down
    Assert-Value (Read-State)['session.id'] $bottom 'focus right and down'
    $beforeState = Read-State
    $beforeNode = $beforeState['panes.focused']
    $before = $beforeState["pane.$beforeNode.rect"]
    Invoke-Aio key Ctrl+Win+Shift+Up
    if ((Read-State)["pane.$beforeNode.rect"] -eq $before) { throw 'Keyboard resize did not change pane geometry.' }
    Write-Output 'PASS keyboard resize changes pane geometry'

    $state = Read-State
    $focusNode = $state['panes.focused']
    $r = $state["pane.$focusNode.rect"] -split ','
    $x = [int]([double]$r[0] - 0.5)
    $y = [int]([double]$r[1] + [double]$r[3] / 2)
    Invoke-Aio mouse drag "$x,$y" "$($x + 60),$y" --px
    if ((Read-State)["pane.$focusNode.rect"] -eq $state["pane.$focusNode.rect"]) {
        throw 'Divider drag did not change the rectangle.'
    }
    Write-Output 'PASS divider drag changes rectangle'

    Invoke-Aio command terminal.find
    Invoke-Aio type 'BOTTOM_ONLY'
    Invoke-Aio expect state 'find.matches=1 match'
    Invoke-Aio key Ctrl+Alt+Up
    Invoke-Aio expect state find.open=false
    Assert-Value (Read-State)['session.id'] $top 'find follows pane focus'

    Invoke-Aio command pane.focus_left
    Invoke-Aio command pane.split_down
    Invoke-Aio wait text 'PS '
    Set-Marker 'FOURTH_ONLY'
    $fourth = (Read-State)['session.id']
    Invoke-Aio key 'Ctrl+Win+['
    Assert-Value (Read-State)['session.id'] $bottom 'previous split uses creation order'
    Invoke-Aio key 'Ctrl+Win+]'
    Assert-Value (Read-State)['session.id'] $fourth 'next split uses creation order'
    $before = Read-State
    Invoke-Aio run '1..40 | ForEach-Object { Write-Output ("OUTPUT_" + $_); Start-Sleep -Milliseconds 20 }'
    $after = Read-State
    foreach ($id in @($left, $top, $bottom)) {
        Assert-Value $after["session.$id.builds"] $before["session.$id.builds"] "idle pane $id builds"
    }
    if ([int]$after["session.$fourth.builds"] -le [int]$before["session.$fourth.builds"]) {
        throw 'Active pane did not rebuild.'
    }
    Write-Output 'PASS four-pane output rebuilds only its own glyph runs'
    Invoke-Aio command pane.close

    Invoke-Aio command pane.focus_left
    Invoke-Aio run '1..80 | ForEach-Object { Write-Output ("LEFT_HISTORY_" + $_) }'
    $state = Read-State
    $node = $state['panes.focused']
    $rect = $state["pane.$node.rect"] -split ','
    $wheelX = [int]([double]$rect[0] + 30)
    $wheelY = [int]([double]$rect[1] + 80)
    Invoke-Aio command pane.focus_right
    $target = (Read-State)['session.id']
    Invoke-Aio mouse wheel "$wheelX,$wheelY" 5 --px
    Assert-Value (Read-State)['session.id'] $target 'wheel preserves keyboard focus'
    Invoke-Aio command pane.focus_left
    if ((Read-State)['session.viewport'] -eq 'bottom') { throw 'Wheel did not scroll the pane under pointer.' }
    Invoke-Aio run 'Clear-Host; Write-Output LEFT_SELECTION_ONLY'
    Invoke-Aio mouse drag '0,0' '19,0'
    $selection = (Read-State)['session.selection']
    if ($selection -notlike '*LEFT_SELECTION_ONLY*') { throw "Wrong pane selected: $selection" }
    Write-Output 'PASS mouse selection uses the clicked pane'
    Invoke-Aio command pane.focus_right
    Invoke-Aio expect state session.selection=none

    $hiddenGrid = (Read-State)['tab.1.pane.0.grid']
    Invoke-Aio dpi 144
    Assert-Value (Read-State)['tab.1.pane.0.grid'] $hiddenGrid 'hidden grid stays unchanged on DPI change'
    Invoke-Aio dpi 96
    Invoke-Aio command tab.select_1
    Assert-Value (Read-State)['session.id'] $firstId 'tab selection preserves session'
    Invoke-Aio wait text HIDDEN_TAB_ALIVE
    Invoke-Aio expect state tab.1.title=HIDDEN_TAB_TITLE
    Assert-Value (Read-State)['grid.size'] $firstGrid 'tab restores initial geometry'
    Invoke-Aio key Ctrl+Tab
    Assert-Value (Read-State)['tabs.selected'] 2 'next tab'
    Invoke-Aio key Ctrl+Shift+Tab
    Assert-Value (Read-State)['tabs.selected'] 1 'previous tab'
    Invoke-Aio mouse click '230,15' --px
    Assert-Value (Read-State)['tabs.selected'] 2 'tab click'
    Invoke-Aio mouse click '455,15' --px
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state tabs.count=3
    Invoke-Aio expect state tabs.selected=3
    Invoke-Aio key Alt+1 Alt+9
    Invoke-Aio expect state tabs.selected=3
    Invoke-Aio key Ctrl+PageUp Ctrl+PageDown Ctrl+Shift+Left Ctrl+Shift+Right
    Invoke-Aio expect state tabs.selected=3
    Invoke-Aio key Ctrl+Shift+O
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state panes.count=2
    Invoke-Aio key Ctrl+Shift+W
    Invoke-Aio expect state tabs.count=2
    Invoke-Aio expect state tabs.selected=2

    Invoke-Aio command pane.focus_right
    Invoke-Aio command pane.focus_down
    Assert-Value (Read-State)['session.id'] $bottom 'bottom pane before shell exit'
    Invoke-Aio run 'exit 7'
    Invoke-Aio expect state panes.count=2
    Assert-Value (Read-State)['session.id'] $top 'exit focuses surviving sibling'
    if (Get-Process -Id $shellPid -ErrorAction SilentlyContinue) { throw 'Exited shell still running.' }
    Write-Output 'PASS shell exit closes its pane'
    Invoke-Aio run 'Write-Output ("CLOSE_PID=" + $PID)'
    $screen = & $ctl --name $name screen
    $closePid = [int]([regex]::Match(($screen -join "`n"), '\|CLOSE_PID=(\d+)').Groups[1].Value)
    Invoke-Aio command pane.close
    Invoke-Aio expect state panes.count=1
    if (Get-Process -Id $closePid -ErrorAction SilentlyContinue) { throw 'Closed pane shell still running.' }
    Write-Output 'PASS manual pane close ends its shell process'
    Invoke-Aio tray hide
    Invoke-Aio expect state tabs.count=2
    Invoke-Aio tray open
    Invoke-Aio expect state tabs.selected=2
    Invoke-Aio expect state panes.count=1
    Invoke-Aio mouse click '230,15' --button middle --px
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state "session.id=$firstId"
    Invoke-Aio key Ctrl+Shift+W
    Invoke-Aio expect state window.visible=false
    Invoke-Aio expect state tabs.count=0
    Invoke-Aio expect state sessions.count=0
    Invoke-Aio tray open
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state panes.count=1
    if ((Read-State)['session.id'] -eq $firstId) { throw 'Reopen reused the closed session.' }
    Write-Output 'PASS last-tab close and fresh tray reopen'
    $soleId = (Read-State)['session.id']
    Invoke-Aio run 'exit 7'
    Invoke-Aio expect state session.status=exited
    Invoke-Aio expect state session.exit=7
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state panes.count=1
    Invoke-Aio expect state window.visible=true
    if ((Read-State)['session.message'] -notlike '*The shell exited with code 7.*') {
        throw 'The final pane must retain its exit message.'
    }
    Invoke-Aio key Enter
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state "session.id=$soleId"
    Invoke-Aio expect state session.status=running
    Write-Output 'PASS final-pane exception and Enter restart'
    $settingsPath = Join-Path $repo "build/verify/$name/settings.ini"
    $originalSettings = [IO.File]::ReadAllText($settingsPath)
    try {
        [IO.File]::AppendAllText($settingsPath, "`nkeys.tab.new = Ctrl+Alt+Y`n")
        Invoke-Aio command settings.reload
        Invoke-Aio key Ctrl+Alt+Y
        Invoke-Aio wait text 'PS '
        Invoke-Aio expect state tabs.count=2
        Write-Output 'PASS tab shortcut is rebindable'
    } finally {
        [IO.File]::WriteAllText($settingsPath, $originalSettings)
    }
} finally {
    Invoke-Aio stop
    Set-Clipboard -Value ($null -eq $savedClipboard ? '' : $savedClipboard)
}

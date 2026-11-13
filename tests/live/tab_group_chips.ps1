[CmdletBinding()]
param()
# Named tab groups (WORK-432, D-093): a chip before a run of tabs in the strip and in the rail, folding,
# menus, drag and keyboard membership, and the groups surviving a restart.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'tab-group-chips'
$directory = Join-Path $repo "build/verify/$name"
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect state.' }
    $state = @{}
    foreach ($line in $lines) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Center([string] $Key) {
    $s = Read-State
    if (-not $s.ContainsKey($Key)) { throw "State lacks $Key." }
    $r = $s[$Key] -split ','
    return "$([int]([double]$r[0]+[double]$r[2]/2)),$([int]([double]$r[1]+[double]$r[3]/2))"
}
function Groups {
    $s = Read-State
    return ((1..[int]$s['tabs.count'] | ForEach-Object { $s["tab.$_.group"] }) -join ',')
}
function Order {
    $s = Read-State
    return ((1..[int]$s['tabs.count'] | ForEach-Object { $s["tab.$_.id"] }) -join ',')
}
function Shot([string] $Label) {
    Invoke-Aio capture --out (Join-Path $directory "$Label.png")
}

Invoke-Aio launch --fresh
try {
    foreach ($i in 2..4) { Invoke-Aio command tab.new }
    Invoke-Aio wait text 'PS '
    Invoke-Aio command tab.select_2
    # Add to Group > New Group from the tab menu, named in the dialog that follows.
    Invoke-Aio mouse click (Center 'tab.2.strip_rect') --px --button right
    Invoke-Aio key Down Down Right Enter
    Assert-Equal (Read-State)['rename.open'] 'true' 'a new group opens its name field'
    Invoke-Aio type 'Build'
    Invoke-Aio key Enter
    Assert-Equal (Groups) '0,1,0,0' 'the tab is in the new group'
    Assert-Equal (Read-State)['group.1.name'] 'Build' 'the group takes its name'
    # The tab menu adds the next tab to the group.
    Invoke-Aio mouse click (Center 'tab.3.strip_rect') --px --button right
    Invoke-Aio key Down Down Right Down Enter
    Assert-Equal (Groups) '0,1,1,0' 'Add to Group joins an existing group'
    Shot 'strip'

    # A chip click folds the group: its tabs hide, and Ctrl+Tab passes over them.
    Invoke-Aio command tab.select_1
    Invoke-Aio mouse click (Center 'group.1.chip') --px
    $s = Read-State
    Assert-Equal $s['group.1.folded'] 'true' 'a chip click folds the group'
    Assert-Equal "$($s['tab.2.shown']),$($s['tab.3.shown'])" 'false,false' 'a folded group hides its tabs'
    Invoke-Aio key Ctrl+Tab
    Assert-Equal (Read-State)['tabs.selected'] '4' 'Ctrl+Tab skips the folded group'
    Shot 'strip-folded'
    # Showing a tab of a folded group, as Activity or the palette does, unfolds it.
    Invoke-Aio command tab.select_2
    Assert-Equal (Read-State)['group.1.folded'] 'false' 'showing a folded tab unfolds its group'

    # Dragging a tab between two tabs of the group joins it.
    Invoke-Aio command tab.select_4
    $from = Center 'tab.4.strip_rect'
    $to = Center 'tab.3.strip_rect'
    Invoke-Aio mouse drag $from $to --px
    Assert-Equal (Groups) '0,1,1,1' 'a drop between two tabs of a group joins it'
    Assert-Equal (Order) '1,2,4,3' 'the dropped tab lands between them'
    # Move Tab Left at the group's start leaves the group where it is.
    Invoke-Aio command tab.select_2
    Invoke-Aio command tab.move_left
    Assert-Equal (Groups) '0,0,1,1' 'a keyboard move at the edge leaves the group'

    # The rail gives the chip a row of its own above the group's tabs.
    Invoke-Aio key Ctrl+Shift+L
    $s = Read-State
    Assert-Equal $s['rail.rows'] '5' 'the rail adds a row for the chip'
    $chip = $s['group.1.chip'] -split ','
    $third = $s['tab.3.rect'] -split ','
    Assert-Equal ([double]$third[1] - [double]$chip[1]) $chip[3] 'the chip row sits just above its first tab'
    Shot 'rail'
    Invoke-Aio key Ctrl+Shift+L

    # The group's menu: Ungroup keeps the tabs where they are.
    $order = Order
    Invoke-Aio mouse click (Center 'group.1.chip') --px --button right
    Assert-Equal (Read-State)['tab_menu.group'] 'true' 'a right click on a chip opens the group menu'
    Invoke-Aio key End Up Enter
    Assert-Equal (Groups) '0,0,0,0' 'Ungroup takes every tab out'
    Assert-Equal (Read-State)['groups.count'] '0' 'an ungrouped group goes'
    Assert-Equal (Order) $order 'Ungroup leaves the tabs in place'

    # Groups, colours and folds are saved with the layout.
    Invoke-Aio command tab.select_1
    Invoke-Aio command tab.group_new
    Invoke-Aio type 'Docs'
    Invoke-Aio key Enter
    Invoke-Aio command tab.select_4
    Invoke-Aio mouse click (Center 'group.1.chip') --px
    Invoke-Aio stop
    Invoke-Aio launch --keep-layout
    $s = Read-State
    $saved = "$($s['group.1.name']),$($s['group.1.folded']),$($s['tab.1.group'] -eq $s['group.1.id'])"
    Assert-Equal $saved 'Docs,true,True' 'groups come back after a restart'
} finally {
    & $ctl --name $name stop | Out-Null
}

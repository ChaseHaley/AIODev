param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'pane-workspace-drag'
$data = Join-Path $repo "build/verify/$name"
function Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out
}
function State {
    $s = @{}
    foreach ($line in (Aio state)) { $pair = $line -split '=',2; $s[$pair[0]] = $pair[1].Trim('"') }
    $s
}
function Point($Rect) {
    $r = @($Rect -split ',' | ForEach-Object { [double]$_ })
    "$([int]($r[0]+$r[2]/2)),$([int]($r[1]+$r[3]/2))"
}
function Assert($Actual, $Expected, $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    "PASS $Label"
}
function Begin-Drag {
    $s = State
    $r = @($s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ })
    $scale = [double]$s['window.scale']
    $grab = "$([int]($r[0]+40*$scale)),$([int]($r[1]+2*$scale))"
    Aio mouse down $grab --px
    Aio mouse move (Point $s['workspace.button']) --px
    Assert (State)['workspace.picker'] true 'drag opens dropdown'
    Assert (State)['panes.dragging'] true 'dropdown preserves drag'
}
function Row-Point([int] $Index) {
    $s = State
    $scale = [double]$s['window.scale']
    $row = @($s['workspace.picker.row'] -split ',' | ForEach-Object { [double]$_ })
    $selected = [int]$s['workspace.picker.selected']
    $rows = [int]$s['workspace.picker.count']-2
    $top = $row[1]+($Index-$selected)*34*$scale
    if ($Index -ge $rows -and $selected -lt $rows) { $top += 8*$scale }
    "$([int]($row[0]+$row[2]/2)),$([int]($top+17*$scale))"
}
Aio launch --fresh
try {
    Aio command workspace.new
    Aio key Enter
    Aio command workspace.select_1
    Aio command pane.split_right
    Aio run "Write-Output 'WORK286_RUNNING_PANE'"
    Aio wait text WORK286_RUNNING_PANE
    foreach ($dpi in @(96,144,192)) {
        Aio dpi $dpi
        $before = State
        Begin-Drag
        $drop = Row-Point 0
        Aio mouse move $drop --px
        Assert (State)['workspace.picker.selected'] 0 'workspace highlights during drag'
        & "$repo/tools/win32.ps1" -Name $name -Shot "$data/workspace-$dpi.png" -Frame | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Dropdown capture failed' }
        Aio key Esc
        Aio mouse up $drop --px
        Assert (State)['session.id'] $before['session.id'] 'Escape preserves runtime'
        Assert (State)['panes.count'] 2 'Escape preserves panes'
    }
    Aio dpi 96
    $before = State
    Begin-Drag
    $drop = Row-Point 0
    Aio mouse move $drop --px
    Aio mouse up $drop --px
    Assert (State)['workspace.id'] 2 'drop selects existing workspace'
    Assert (State)['session.id'] $before['session.id'] 'workspace drop preserves runtime'
    Aio command pane.split_right
    $before = State
    Begin-Drag
    $drop = Row-Point ([int](State)['workspace.picker.count']-2)
    Aio mouse move $drop --px
    Aio mouse up $drop --px
    Assert (State)['rename.open'] true 'New Workspace drop names it in the chip'
    Assert (State)['workspaces.count'] 3 'New Workspace drop creates destination'
    Assert (State)['session.id'] $before['session.id'] 'New Workspace preserves runtime'
    Aio key Esc
    Assert (State)['rename.open'] false 'Escape keeps the suggested name'
    Assert (State)['workspaces.count'] 3 'Escape keeps the new workspace'
    Aio command pane.split_right
    $before = State
    Begin-Drag
    $drop = Row-Point ([int](State)['workspace.picker.count']-1)
    Aio mouse move $drop --px
    Aio mouse up $drop --px
    Assert (State)['windows.count'] 2 'New Window drop opens destination'
    Assert (State)['sessions.count'] $before['sessions.count'] 'New Window creates no extra shell'
    $s = State
    $opened = @(1..[int]$s['windows.count'] | ForEach-Object { $s["window.$_.id"] } | Where-Object { $_ -ne $s['window.id'] })[0]
    Aio window select $opened
    Assert (State)['rename.open'] true 'New Window drop names it in the new chip'
    Aio key Enter
} finally {
    Aio stop
}

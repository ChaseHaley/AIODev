[CmdletBinding()]
param()

# Pointer arrangement from the 2026-10-18 owner feedback: single-pane split controls, junction resizing,
# divider double-click balance, tab reordering, and header drag to move or swap panes.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'arrange'
$directory = Join-Path $repo "build/verify/$name"

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}

function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $values = @{}
    foreach ($line in $lines) {
        $pair = $line -split '=', 2
        $values[$pair[0]] = $pair[1].Trim('"')
    }
    return $values
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

function Assert-True([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "$Label failed" }
    Write-Output "PASS $Label"
}

function Focused-Rect { $s = Read-State; return @($s["pane.$($s['panes.focused'])"+'.rect'] -split ',' | ForEach-Object { [double]$_ }) }

function Pane-Rects {
    $s = Read-State
    $rects = @()
    foreach ($key in $s.Keys) {
        if ($key -match '^pane\.(\d+)\.rect$') {
            $r = @($s[$key] -split ',' | ForEach-Object { [double]$_ })
            $rects += ,([pscustomobject]@{ Node = $Matches[1]; X = $r[0]; Y = $r[1]; W = $r[2]; H = $r[3] })
        }
    }
    return $rects
}

function Px([double] $X, [double] $Y) { return "$([int]$X),$([int]$Y)" }

function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png") | Out-Null
}

Invoke-Aio launch --fresh
try {
    $s = Read-State
    $scale = [double]$s['window.scale']
    Assert-Value $s['panes.header_height'] 0 'single pane has no header row'
    $r = Focused-Rect
    Invoke-Aio mouse move (Px ($r[0]+$r[2]/2) ($r[1]+$r[3]/2)) --px
    Assert-Value (Read-State)['panes.split_overlay'] 'false' 'split controls stay hidden away from the top'
    Invoke-Aio mouse move (Px ($r[0]+$r[2]-30*$scale) ($r[1]+12*$scale)) --px
    Assert-Value (Read-State)['panes.split_overlay'] 'true' 'split controls appear near the top'
    Assert-Value $s['panes.header_height'] 0 'split controls take no terminal rows'
    Shot 'single-pane-split-controls'
    Invoke-Aio mouse click (Px ($r[0]+$r[2]-44*$scale) ($r[1]+20*$scale)) --px
    Assert-Value (Read-State)['panes.count'] 2 'single-pane split right button'
    $rects = Pane-Rects | Sort-Object X
    Assert-True ($rects[0].Y -eq $rects[1].Y -and $rects[1].X -gt $rects[0].X) 'split right places panes side by side'

    Invoke-Aio command tab.new
    $r = Focused-Rect
    Invoke-Aio mouse move (Px ($r[0]+$r[2]-30*$scale) ($r[1]+12*$scale)) --px
    Invoke-Aio mouse click (Px ($r[0]+$r[2]-20*$scale) ($r[1]+20*$scale)) --px
    Assert-Value (Read-State)['panes.count'] 2 'single-pane split down button'
    $rects = Pane-Rects | Sort-Object Y
    Assert-True ($rects[0].X -eq $rects[1].X -and $rects[1].Y -gt $rects[0].Y) 'split down stacks panes'

    Invoke-Aio command tab.select_1
    Invoke-Aio command pane.split_down
    $rects = Pane-Rects
    $left = $rects | Sort-Object X | Select-Object -First 1
    $top = $rects | Where-Object { $_.X -gt $left.X } | Sort-Object Y | Select-Object -First 1
    $gap = [double](Read-State)['panes.gap']
    $jx, $jy = ($left.X+$left.W+$gap/2), ($top.Y+$top.H+$gap/2)
    Invoke-Aio mouse drag (Px $jx $jy) (Px ($jx+40) ($jy+30)) --px
    $after = Pane-Rects
    $newLeft = $after | Where-Object { $_.Node -eq $left.Node }
    $newTop = $after | Where-Object { $_.Node -eq $top.Node }
    Assert-True ([math]::Abs($newLeft.W-$left.W-40) -le 2) 'junction drag moves the vertical divider'
    Assert-True ([math]::Abs($newTop.H-$top.H-30) -le 2) 'junction drag moves the horizontal divider'

    Invoke-Aio command tab.new
    Invoke-Aio command pane.split_right
    Invoke-Aio command pane.split_right
    $rects = Pane-Rects | Sort-Object X
    Assert-True ($rects[0].W -gt 1.5*$rects[1].W) 'nested splits start unbalanced'
    $gap = [double](Read-State)['panes.gap']
    $dx, $dy = ($rects[1].X+$rects[1].W+$gap/2), ($rects[1].Y+$rects[1].H/2)
    Invoke-Aio mouse click (Px $dx $dy) --px
    Invoke-Aio mouse click (Px $dx $dy) --px
    $rects = Pane-Rects | Sort-Object X
    $widths = $rects | ForEach-Object { $_.W }
    Assert-True ((($widths | Measure-Object -Maximum).Maximum-($widths | Measure-Object -Minimum).Minimum) -le 2*$gap+2) 'double-click balances the related splits'

    $s = Read-State
    $ids = 1..[int]$s['tabs.count'] | ForEach-Object { $s["tab.$_.id"] }
    $count = $ids.Count
    $tabWidth = [math]::Min(220*$scale, ([double]($s['window.size'] -split 'x')[0]-32*$scale)/$count)
    Invoke-Aio command tab.select_1
    Invoke-Aio mouse drag (Px ($tabWidth/2) (18*$scale)) (Px ($tabWidth*2.6) (18*$scale)) --px
    $s = Read-State
    Assert-Value $s['tab.3.id'] $ids[0] 'dragged tab lands at its drop position'
    Assert-Value $s['tab.1.id'] $ids[1] 'other tabs shift to make room'
    Assert-Value $s['tabs.selected'] 3 'dragged tab stays selected'
    $before = (1..$count | ForEach-Object { $s["tab.$_.id"] }) -join ','
    Invoke-Aio mouse down (Px ($tabWidth*2.5) (18*$scale)) --px
    Invoke-Aio mouse move (Px ($tabWidth*0.5) (18*$scale)) --px
    Invoke-Aio key Esc
    Invoke-Aio mouse up (Px ($tabWidth*0.5) (18*$scale)) --px
    $s = Read-State
    Assert-Value ((1..$count | ForEach-Object { $s["tab.$_.id"] }) -join ',') $before 'Escape cancels a tab drag'

    Invoke-Aio command tab.select_1
    $s = Read-State
    $session = $s['session.id']
    $paneCount = $s['panes.count']
    $source = Focused-Rect
    $target = Pane-Rects | Where-Object { $_.X -ne $source[0] -or $_.Y -ne $source[1] } | Sort-Object Y | Select-Object -First 1
    $start = Px ($source[0]+80*$scale) ($source[1]+14*$scale)
    Invoke-Aio mouse down $start --px
    Invoke-Aio mouse move (Px ($target.X+$target.W/2) ($target.Y+$target.H-15*$scale)) --px
    Assert-Value (Read-State)['panes.dragging'] 'true' 'header drag shows a landing preview'
    Shot 'header-drag-preview'
    Invoke-Aio key Esc
    Invoke-Aio mouse up (Px ($target.X+$target.W/2) ($target.Y+$target.H-15*$scale)) --px
    Assert-Value ((Focused-Rect) -join ',') ($source -join ',') 'Escape cancels a header drag'
    Invoke-Aio mouse drag $start (Px ($target.X+$target.W/2) ($target.Y+$target.H-15*$scale)) --px
    $s = Read-State
    Assert-Value $s['session.id'] $session 'moved pane keeps its session and focus'
    $moved = Focused-Rect
    Assert-True ($moved[1] -gt $target.Y -and $moved[0] -ge $target.X-1) 'header drag moves the pane below its target'
    Assert-Value $s['panes.count'] $paneCount 'move keeps every pane'

    $other = Pane-Rects | Where-Object { [math]::Abs($_.X-$moved[0]) -gt 1 -or [math]::Abs($_.Y-$moved[1]) -gt 1 } |
        Sort-Object X | Select-Object -First 1
    $grab = Px ($moved[0]+80*$scale) ($moved[1]+14*$scale)
    Invoke-Aio mouse drag $grab (Px ($other.X+$other.W/2) ($other.Y+$other.H/2)) --px --mods Shift
    $s = Read-State
    $swapped = Focused-Rect
    Assert-Value $s['session.id'] $session 'swap keeps the dragged session focused'
    Assert-Value ($swapped -join ',') (@($other.X, $other.Y, $other.W, $other.H) -join ',') 'Shift drag swaps with the target pane'
    Write-Output 'PASS arrangement journey'
} finally {
    & $ctl --name $name stop | Out-Null
}

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'docking'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'
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
function Assert-True([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "$Label failed" }
    Write-Output "PASS $Label"
}
function Rect([string] $Value) { return @($Value -split ',' | ForEach-Object { [double]$_ }) }
function Focused-Rect { $s = Read-State; return Rect $s["pane.$($s['panes.focused']).rect"] }
function Area {
    $s = Read-State
    $rects = @($s.Keys | Where-Object { $_ -match '^pane\.\d+\.rect$' } | ForEach-Object { ,(Rect $s[$_]) })
    $left = ($rects | ForEach-Object { $_[0] } | Measure-Object -Minimum).Minimum
    $top = ($rects | ForEach-Object { $_[1] } | Measure-Object -Minimum).Minimum
    $right = ($rects | ForEach-Object { $_[0]+$_[2] } | Measure-Object -Maximum).Maximum
    $bottom = ($rects | ForEach-Object { $_[1]+$_[3] } | Measure-Object -Maximum).Maximum
    return @($left, $top, ($right-$left), ($bottom-$top))
}
function Px([double] $X, [double] $Y) { return "$([int]$X),$([int]$Y)" }
function Grab {
    $r = Focused-Rect
    $scale = [double](Read-State)['window.scale']
    if ((Read-State)['panes.count'] -eq '1') { return Px ($r[0]+$r[2]-70*$scale) ($r[1]+20*$scale) }
    return Px ($r[0]+[math]::Min(80*$scale,$r[2]/3)) ($r[1]+14*$scale)
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png") -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
function Set-Gap([int] $Gap) {
    $text = [IO.File]::ReadAllText($path)
    if ($text -match '(?m)^pane.gap\s*=') { $text = [regex]::Replace($text, '(?m)^pane.gap\s*=.*$', "pane.gap = $Gap") }
    else { $text += "`npane.gap = $Gap`n" }
    [IO.File]::WriteAllText($path, $text)
}
Invoke-Aio launch --fresh
try {
    foreach ($dpi in @(96,144,168)) {
        Invoke-Aio dpi $dpi
        foreach ($gap in @(0,5)) {
            Set-Gap $gap
            Invoke-Aio command settings.reload
            Invoke-Aio command tab.new
            Invoke-Aio command pane.split_right
            Invoke-Aio command pane.focus_left
            Invoke-Aio command pane.split_down
            Invoke-Aio wait text 'PS '
            $session = (Read-State)['session.id']
            $sessions = (Read-State)['sessions.count']
            foreach ($edge in @('bottom','left','top','right')) {
                $a = Area
                $point = switch ($edge) {
                    bottom { Px ($a[0]+$a[2]/2) ($a[1]+$a[3]-2) }
                    top { Px ($a[0]+$a[2]/2) ($a[1]+2) }
                    left { Px ($a[0]+2) ($a[1]+$a[3]/2) }
                    right { Px ($a[0]+$a[2]-2) ($a[1]+$a[3]/2) }
                }
                $grab = Grab
                Invoke-Aio mouse move $grab --px
                Invoke-Aio mouse down $grab --px
                Invoke-Aio mouse move $point --px
                $s = Read-State
                Assert-Equal $s['panes.drop.root'] true "$dpi/$gap/$edge selects workspace docking"
                Assert-Equal $s['panes.drop.shown'] true 'valid landing preview'
                $preview = $s['panes.drop.rect']
                if ($dpi -eq 96 -and $gap -eq 5 -and $edge -eq 'bottom') { Shot root-bottom-preview }
                Invoke-Aio mouse up $point --px
                $s = Read-State
                Assert-Equal $s['session.id'] $session 'root move keeps the focused running session'
                Assert-Equal $s['sessions.count'] $sessions 'root move keeps all sessions'
                Assert-Equal $s["pane.$($s['panes.focused']).rect"] $preview 'preview equals post-drop rectangle'
                $r = Focused-Rect
                if ($edge -in @('top','bottom')) { Assert-Equal $r[2] $a[2] 'docked pane spans full width' }
                else { Assert-Equal $r[3] $a[3] 'docked pane spans full height' }
            }
            Invoke-Aio command tab.close
        }
    }
    Invoke-Aio dpi 96
    Invoke-Aio command pane.split_right
    Invoke-Aio command pane.split_down
    Invoke-Aio run 'Write-Output DOCK_MARKER'
    $s = Read-State
    $sourceTab = $s['tab.1.id']
    $session = $s['session.id']
    Invoke-Aio command tab.new
    Invoke-Aio wait text 'PS '
    $width = [double](Read-State)['tabs.width']
    $destination = Px ($width*1.5) 18
    Invoke-Aio command tab.select_1
    $grab = Grab
    Invoke-Aio mouse down $grab --px
    Invoke-Aio mouse move $destination --px
    Start-Sleep -Milliseconds 450
    Assert-Equal (Read-State)['tabs.selected'] 2 'hover selects destination after dwell'
    Invoke-Aio key Esc
    Invoke-Aio mouse up $destination --px
    Assert-Equal (Read-State)['tabs.selected'] 1 'Escape restores source tab'
    Assert-Equal (Read-State)['panes.count'] 3 'cancel preserves source layout'
    $grab = Grab
    Invoke-Aio mouse down $grab --px
    Invoke-Aio mouse move $destination --px
    Start-Sleep -Milliseconds 450
    $a = Area
    $point = Px ($a[0]+$a[2]/2) ($a[1]+$a[3]-2)
    Invoke-Aio mouse move $point --px
    $preview = (Read-State)['panes.drop.rect']
    Shot cross-tab-root-preview
    Invoke-Aio mouse up $point --px
    $s = Read-State
    Assert-Equal $s['session.id'] $session 'cross-tab move preserves session'
    Assert-Equal $s['panes.count'] 2 'destination gains pane'
    Assert-Equal $s['tab.1.panes'] 2 'source loses only moved pane'
    Assert-Equal $s["pane.$($s['panes.focused']).rect"] $preview 'cross-tab preview equals result'
    Invoke-Aio expect text DOCK_MARKER
    Invoke-Aio command tab.new
    Invoke-Aio wait text 'PS '
    $s = Read-State
    $sole = $s['session.id']
    $count = $s['sessions.count']
    $width = [double]$s['tabs.width']
    $grab = Grab
    Invoke-Aio mouse move $grab --px
    Shot sole-pane-grip
    Invoke-Aio mouse drag $grab (Px ($width/2) 18) --px
    $s = Read-State
    Assert-Equal $s['tabs.count'] 2 'successful sole-pane transfer closes empty source tab'
    Assert-Equal $s['session.id'] $sole 'sole-pane runtime preserved'
    Assert-Equal $s['sessions.count'] $count 'sole-pane transfer closes no runtime'
    Invoke-Aio command settings.open
    $width = [double](Read-State)['tabs.width']
    Invoke-Aio command tab.select_1
    $grab = Grab
    Invoke-Aio mouse down $grab --px
    Invoke-Aio mouse move (Px ($width*2.5) 18) --px
    Assert-Equal (Read-State)['panes.drop.shown'] false 'Settings rejects pane destination'
    Invoke-Aio mouse up (Px ($width*2.5) 18) --px
    Assert-Equal (Read-State)['tabs.selected'] 1 'invalid drop restores source tab'
    $grab = Grab
    Invoke-Aio mouse down $grab --px
    Invoke-Aio mouse move (Px ($width*1.5) 18) --px
    Start-Sleep -Milliseconds 450
    Invoke-Aio focus out
    Invoke-Aio mouse up (Px ($width*1.5) 18) --px
    Assert-Equal (Read-State)['tabs.selected'] 1 'focus loss restores original tab'
    Assert-Equal (Read-State)['panes.dragging'] false 'focus loss cancels docking'
    Write-Output 'PASS root and cross-tab docking journey'
} finally {
    & $ctl --name $name stop | Out-Null
}

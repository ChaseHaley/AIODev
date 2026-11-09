[CmdletBinding()]
param([string] $Name = 'tab-tear-off')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$directory = Join-Path $repo "build/verify/$Name"

# The thumbnail is composed by the desktop window manager, so only a capture of the screen shows it, and only on
# the Win32 build: a headless instance draws none and counts each placement in os.thumbnail_places instead.
function Screen-Shot([int] $X, [int] $Y, [int] $Width, [int] $Height, [string] $Path) {
    if (-not ('TabTearOffNative' -as [type])) {
        $assemblies = @('System.Drawing')
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $assemblies += 'System.Drawing.Primitives', 'System.Drawing.Common'
            foreach ($assemblyName in @('System.Private.Windows.GdiPlus.dll', 'System.Private.Windows.Core.dll')) {
                $assemblyPath = Join-Path $PSHOME $assemblyName
                if (Test-Path -LiteralPath $assemblyPath) { $assemblies += $assemblyPath }
            }
        }
        Add-Type -ReferencedAssemblies $assemblies -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TabTearOffNative {
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public static void Screen(int x, int y, int width, int height, string path) {
        // Per-monitor v2, so the rectangle is in the app's physical screen pixels.
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        using (var bitmap = new Bitmap(width, height))
        using (var g = Graphics.FromImage(bitmap)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(width, height));
            bitmap.Save(path, ImageFormat.Png);
        }
    }
}
'@
    }
    [TabTearOffNative]::Screen($X, $Y, $Width, $Height, $Path)
}

function Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function State {
    $state = @{}
    foreach ($line in (Aio state)) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Numbers([string] $Value, [string] $Separator = ',') {
    return @($Value -split $Separator | ForEach-Object { [double]$_ })
}
# Presses a tab and passes the drag threshold straight down, leaving the pointer held.
function Begin-Drag([int] $Index, [string] $Rect = 'strip_rect') {
    $r = Numbers (State)["tab.$Index.$Rect"]
    $x, $y = [int]($r[0]+$r[2]/3), [int]($r[1]+$r[3]/2)
    Aio mouse down "$x,$y" --px | Out-Null
    Aio mouse move "$x,$($y+24)" --px | Out-Null
    Assert-Equal (State)['tabs.dragging'] true 'tab press starts a drag'
}
function Other-Window($Source) {
    $s = State
    return @(1..[int]$s['windows.count'] | ForEach-Object { $s["window.$_.id"] } | Where-Object { $_ -ne $Source })[0]
}

Aio launch --fresh | Out-Null
try {
    $s = State
    $defaultSize = $s['window.size']
    # Only a headless instance reports what it asked of the operating system.
    $headless = $s.ContainsKey('os.thumbnail_places')
    # The first tab has three panes and an output line to follow; the second stays behind.
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio run 'Write-Output TORN$(6*7)' | Out-Null
    Aio wait text TORN42 | Out-Null
    Aio command pane.split_down | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio command tab.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio command tab.select_1 | Out-Null
    $work = Numbers (State)['window.work_area']
    Aio window move "$($work[0]+20),$($work[1]+20)" | Out-Null
    $s = State
    $source = $s['window.id']
    Assert-Equal $s['panes.count'] 3 'the tab holds three panes'
    Assert-Equal $s['tabs.count'] 2 'the workspace holds two tabs'
    $session = $s['session.id']
    $sessions = $s['sessions.count']
    $tabId = $s['tab.1.id']
    $desktop = "$([int]($work[2]-420)),$([int]($work[3]-280))"
    Assert-Equal (Aio window at $desktop) 'window=0' 'the drop point is on the desktop'
    $places = $s['os.thumbnail_places']

    # Over the desktop: a small live thumbnail of the whole tab and a hidden destination.
    Begin-Drag 1
    Aio mouse move $desktop --screen | Out-Null
    $s = State
    Assert-Equal $s['tabs.drop.new_window'] true 'desktop offers a new window'
    Assert-Equal $s['tabs.drop.thumbnail'] true 'thumbnail follows the pointer'
    Assert-Equal $s['tab.1.id'] $tabId 'the drag leaves the tab order alone'
    $thumbnail = Numbers $s['tabs.drop.thumbnail_size'] 'x'
    if ($thumbnail[0] -gt 300*[double]$s['window.scale'] -or $thumbnail[1] -gt 190*[double]$s['window.scale']) {
        throw "Thumbnail is too large: $($s['tabs.drop.thumbnail_size'])"
    }
    Write-Output "PASS thumbnail is $($s['tabs.drop.thumbnail_size'])"
    if ($headless) {
        Assert-Equal ([int]$s['os.thumbnail_places'] -gt [int]$places) $true 'the thumbnail is placed on the desktop'
    } else {
        Start-Sleep -Milliseconds 400
        $point = Numbers $desktop
        Screen-Shot ([int]$point[0]-20) ([int]$point[1]-20) ([int]$thumbnail[0]+80) ([int]$thumbnail[1]+80) `
            (Join-Path $directory 'thumbnail.png')
        Write-Output 'SHOT thumbnail'
    }
    Aio capture --out (Join-Path $directory 'source-during-drag.png') | Out-Null

    # Escape cancels everything.
    Aio key Esc | Out-Null
    Aio mouse up $desktop --screen | Out-Null
    $s = State
    Assert-Equal $s['windows.count'] 1 'Escape opens no window'
    Assert-Equal $s['tabs.drop.preview_window'] 0 'Escape releases the destination'
    Assert-Equal $s['tabs.count'] 2 'Escape keeps the tabs'
    Assert-Equal $s['panes.count'] 3 'Escape keeps the panes'
    Assert-Equal $s['session.id'] $session 'Escape keeps the focused pane'

    # Coming back over the window offers no new window any more.
    Begin-Drag 1
    Aio mouse move $desktop --screen | Out-Null
    $origin = Numbers (State)['window.origin']
    Aio mouse move "$([int]$origin[0]+200),$([int]$origin[1]+200)" --screen | Out-Null
    $s = State
    Assert-Equal $s['tabs.drop.new_window'] false 'the window takes the drag back'
    Assert-Equal $s['tabs.drop.thumbnail'] false 'the thumbnail hides over the window'
    Aio key Esc | Out-Null
    Aio mouse up "$([int]$origin[0]+200),$([int]$origin[1]+200)" --screen | Out-Null

    # Release: the window exists at once with every pane, at the default size, naming itself in its chip.
    Begin-Drag 1
    Aio mouse move $desktop --screen | Out-Null
    Aio mouse up $desktop --screen | Out-Null
    $s = State
    Assert-Equal $s['windows.count'] 2 'release opens the window immediately'
    Assert-Equal $s['tabs.count'] 1 'release takes the tab out of the source'
    Assert-Equal $s['panes.count'] 1 'the source shows the tab that stayed'
    Assert-Equal $s['rename.open'] false 'the source window asks for nothing'
    $torn = Other-Window $source
    Aio window select $torn | Out-Null
    $n = State
    Assert-Equal $n['window.preparing'] false 'the new window is an ordinary window'
    Assert-Equal $n['window.size'] $defaultSize 'the new window opens at the default size'
    Assert-Equal $n['tabs.count'] 1 'the new window holds the tab'
    Assert-Equal $n['panes.count'] 3 'every pane came with the tab'
    Assert-Equal $n['session.id'] $session 'the new window hosts the focused pane'
    Assert-Equal $n['sessions.count'] $sessions 'the move starts or closes no shell'
    Assert-Equal $n['rename.open'] true 'the new window asks for its name in its chip'

    Aio type 'Torn tab' | Out-Null
    Aio key Enter | Out-Null
    Assert-Equal (State)['workspace.name'] 'Torn tab' 'typing names the workspace'
    Aio run 'Write-Output ALIVE$(6*7)' | Out-Null
    Aio wait text ALIVE42 | Out-Null
    Write-Output 'PASS the shell takes the keyboard after naming'

    # The vertical rail tears off the same way, leaving the tab that stays selected.
    Aio window select $source | Out-Null
    Aio command tab.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio key Ctrl+Shift+L | Out-Null
    $s = State
    Assert-Equal $s['tabs.count'] 2 'the source has two tabs again'
    # The first torn-off window now covers the earlier drop point, so this drop lands past every monitor.
    $beyond = "$($work[0]-30000),$($work[1]-30000)"
    Begin-Drag ([int]$s['tabs.selected']) 'rect'
    Aio mouse move $beyond --screen | Out-Null
    Assert-Equal (State)['tabs.drop.thumbnail'] true 'the rail drag shows a thumbnail'
    Aio mouse up $beyond --screen | Out-Null
    $s = State
    Assert-Equal $s['windows.count'] 3 'the rail drop opens a window'
    Assert-Equal $s['tabs.count'] 1 'the rail drop takes the tab out of the source'
    Write-Output 'PASS tab tear-off journey'
} finally {
    & $ctl --name $Name stop | Out-Null
}

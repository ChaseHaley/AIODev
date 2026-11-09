[CmdletBinding()]
param([string] $Name = 'tear-off')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$directory = Join-Path $repo "build/verify/$Name"

# The thumbnail is composed by the desktop window manager, so only a capture of the screen shows it, and only on
# the Win32 build: a headless instance draws none and counts each placement in os.thumbnail_places instead.
# Window evidence is the app's own capture.
function Screen-Shot([int] $X, [int] $Y, [int] $Width, [int] $Height, [string] $Path) {
    if (-not ('TearOffNative' -as [type])) {
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
public static class TearOffNative {
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
    [TearOffNative]::Screen($X, $Y, $Width, $Height, $Path)
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
# Presses a header in the source and passes the drag threshold, leaving the pointer down.
function Begin-Drag {
    $s = State
    $r = Numbers $s["pane.$($s['panes.focused']).rect"]
    $scale = [double]$s['window.scale']
    $x, $y = [int]($r[0]+40*$scale), [int]($r[1]+14*$scale)
    Aio mouse down "$x,$y" --px | Out-Null
    Aio mouse move "$($x+24),$($y+24)" --px | Out-Null
    Assert-Equal (State)['panes.dragging'] true 'header press starts a drag'
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
    $work = Numbers $s['window.work_area']
    Aio window move "$($work[0]+20),$($work[1]+20)" | Out-Null
    # The source grows taller than the default size, keeping its width, so the drop point to its right stays
    # on the desktop even on the 1920x1080 virtual one. It grows before it splits: resize sizes the window for
    # the focused pane's grid as if it filled the window.
    $grid = Numbers $s['grid.size'] 'x'
    Aio resize "$($grid[0])x$($grid[1]+4)" | Out-Null
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio run 'Write-Output TORN$(6*7)' | Out-Null
    Aio wait text TORN42 | Out-Null
    $s = State
    $source = $s['window.id']
    $size = Numbers $s['window.size'] 'x'
    if ("$($size[0])x$($size[1])" -eq $defaultSize) { throw 'The source window did not grow past the default size.' }
    $session = $s['session.id']
    $sessions = $s['sessions.count']
    $desktop = "$([int]($work[2]-420)),$([int]($work[3]-280))"
    Assert-Equal (Aio window at $desktop) 'window=0' 'the drop point is on the desktop'
    $places = $s['os.thumbnail_places']

    # Over the desktop: a small live thumbnail, a hidden destination, and no source pane text covered.
    Begin-Drag
    Aio mouse move $desktop --screen | Out-Null
    $s = State
    Assert-Equal $s['panes.drop.new_window'] true 'desktop offers a new window'
    Assert-Equal $s['panes.drop.thumbnail'] true 'thumbnail follows the pointer'
    $thumbnail = Numbers $s['panes.drop.thumbnail_size'] 'x'
    if ($thumbnail[0] -gt 300*[double]$s['window.scale'] -or $thumbnail[1] -gt 190*[double]$s['window.scale']) {
        throw "Thumbnail is too large: $($s['panes.drop.thumbnail_size'])"
    }
    Write-Output "PASS thumbnail is $($s['panes.drop.thumbnail_size'])"
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
    Assert-Equal $s['panes.drop.preview_window'] 0 'Escape releases the destination'
    Assert-Equal $s['panes.count'] 2 'Escape keeps the source layout'
    Assert-Equal $s['session.id'] $session 'Escape keeps the running pane focused'

    # Release: the window exists at once, at the default size, with its name open in its own chip.
    Begin-Drag
    Aio mouse move $desktop --screen | Out-Null
    Aio mouse up $desktop --screen | Out-Null
    $s = State
    Assert-Equal $s['windows.count'] 2 'release opens the window immediately'
    Assert-Equal $s['panes.count'] 1 'release moves the pane out of the source'
    Assert-Equal $s['rename.open'] false 'the source window asks for nothing'
    $torn = Other-Window $source
    Aio window select $torn | Out-Null
    $n = State
    Assert-Equal $n['window.preparing'] false 'the new window is an ordinary window'
    Assert-Equal $n['window.size'] $defaultSize 'the new window opens at the default size'
    Assert-Equal $n['session.id'] $session 'the new window hosts the running pane'
    Assert-Equal $n['sessions.count'] $sessions 'the move starts or closes no shell'
    Assert-Equal $n['rename.open'] true 'the new window asks for its name in its chip'
    Assert-Equal $n['rename.value'] $n['workspace.name'] 'the chip holds the suggested name'
    $landed = Numbers $n['window.origin']
    if ($landed[0] -lt $work[0]-8 -or $landed[1] -lt $work[1]-8 -or
        $landed[0]+(Numbers $n['window.size'] 'x')[0] -gt $work[2]+8 -or $landed[1]+(Numbers $n['window.size'] 'x')[1] -gt $work[3]+8) {
        throw "The new window left the work area: origin $($n['window.origin'])"
    }
    Write-Output 'PASS the new window stays on the monitor'
    Start-Sleep -Milliseconds 300
    Aio capture --out (Join-Path $directory 'naming.png') | Out-Null

    # Typing replaces the selection, Enter hands the keyboard to the shell.
    Aio type 'Torn pane' | Out-Null
    Aio key Enter | Out-Null
    $n = State
    Assert-Equal $n['workspace.name'] 'Torn pane' 'typing names the workspace'
    Assert-Equal $n['rename.open'] false 'Enter closes the field'
    Aio run 'Write-Output ALIVE$(6*7)' | Out-Null
    Aio wait text ALIVE42 | Out-Null
    Write-Output 'PASS the shell takes the keyboard after naming'
    Write-Output 'PASS tear-off journey'
} finally {
    & $ctl --name $Name stop | Out-Null
}

[CmdletBinding()]
param([string] $Name = 'tab-across-windows')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$directory = Join-Path $repo "build/verify/$Name"

# The drop target comes from the OS hit test under the pointer, so the journey keeps its windows above other
# applications and proves each point lands on the window it claims. Screen capture shows what a person sees.
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TabAcrossNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint param, ref RECT rect, uint ini);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    public static void Aware() { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
    public static int[] WorkArea() {
        var r = new RECT();
        SystemParametersInfoW(0x0030, 0, ref r, 0);
        return new[] { r.Left, r.Top, r.Right, r.Bottom };
    }
    // Puts the app's window with this client origin above every other window, without activating it.
    public static bool Raise(uint pid, int x, int y) {
        var found = new List<IntPtr>();
        EnumWindows((h, d) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) found.Add(h); return true; }, IntPtr.Zero);
        foreach (var h in found) {
            var o = new POINT();
            ClientToScreen(h, ref o);
            if (o.X == x && o.Y == y) return SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
        }
        return false;
    }
    // The client origin of the top-level window under a screen point.
    public static string HitAt(int x, int y) {
        IntPtr h = GetAncestor(WindowFromPoint(new POINT { X = x, Y = y }), 2);
        var o = new POINT();
        ClientToScreen(h, ref o);
        return o.X + "," + o.Y;
    }
    public static void Screen(int x, int y, int width, int height, string path) {
        using (var bitmap = new Bitmap(width, height))
        using (var g = Graphics.FromImage(bitmap)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(width, height));
            bitmap.Save(path, ImageFormat.Png);
        }
    }
}
'@
[TabAcrossNative]::Aware()

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
function Numbers([string] $Value) { return @($Value -split ',' | ForEach-Object { [double]$_ }) }
function Select-Window([string] $Id) { Aio window select $Id | Out-Null }
# Presses a tab of the selected window and passes the drag threshold, leaving the pointer held.
function Begin-Drag([int] $Index, [string] $Rect) {
    $r = Numbers (State)["tab.$Index.$Rect"]
    $x, $y = [int]($r[0]+$r[2]/3), [int]($r[1]+$r[3]/2)
    Aio mouse down "$x,$y" --px | Out-Null
    Aio mouse move "$x,$($y+24)" --px | Out-Null
    Assert-Equal (State)['tabs.dragging'] true 'tab press starts a drag'
}
# The screen point at a fraction of a rectangle in the destination window, proved to land on that window.
function Target([string] $Rectangle, [double] $FractionX, [double] $FractionY) {
    $d = $script:destinationState
    $r, $o = (Numbers $Rectangle), (Numbers $d['window.origin'])
    $x, $y = [int]($o[0]+$r[0]+$r[2]*$FractionX), [int]($o[1]+$r[1]+$r[3]*$FractionY)
    $hit = [TabAcrossNative]::HitAt($x, $y)
    if ($hit -ne $d['window.origin']) { throw "Point $x,$y hits origin $hit, not $($d['window.origin'])" }
    return "$x,$y"
}
function Destination-Incoming([string] $Source, [int] $Count, [int] $Slot, [string] $Label) {
    Select-Window $script:destination
    $d = State
    Assert-Equal $d['tabs.incoming.count'] $Count "$Label opens a gap for $Count"
    Assert-Equal $d['tabs.incoming.slot'] $Slot "$Label puts the gap at slot $Slot"
    Select-Window $Source
}
function Capture([string] $Label) {
    Start-Sleep -Milliseconds 300
    $o, $size = (Numbers $script:destinationState['window.origin']), ($script:destinationState['window.size'] -split 'x')
    $work = [TabAcrossNative]::WorkArea()
    $width = [Math]::Min([int]$size[0], $work[2]-[int]$o[0])
    $height = [Math]::Min([int]$size[1], $work[3]-[int]$o[1])
    [TabAcrossNative]::Screen([int]$o[0], [int]$o[1], $width, $height, (Join-Path $directory "$Label.png"))
    Write-Output "SHOT $Label"
}

Aio launch --fresh | Out-Null
try {
    $s = State
    $appPid = [uint32]$s['app.pid']
    $source = $s['window.id']
    $sourceWorkspace = $s['workspace.id']
    Aio wait text 'PS ' | Out-Null
    Aio command window.new | Out-Null
    Aio expect state windows.count=2 | Out-Null
    $s = State
    $destination = @(1..2 | ForEach-Object { $s["window.$_.id"] } | Where-Object { $_ -ne $source })[0]
    Select-Window $destination
    if ((State)['rename.open'] -eq 'true') { Aio key Enter | Out-Null }
    Aio wait text 'PS ' | Out-Null
    Aio command tab.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio command tab.select_1 | Out-Null

    # The destination overlaps the source, leaving the source's tabs in view and sitting above it.
    $work = [TabAcrossNative]::WorkArea()
    $scale = [double](State)['window.scale']
    Select-Window $source
    Aio window move "$($work[0]+20),$($work[1]+20)" | Out-Null
    $sourceOrigin = Numbers (State)['window.origin']
    Select-Window $destination
    Aio window move "$($work[0]+20+[int](760*$scale)),$($work[1]+20+[int](140*$scale))" | Out-Null
    $destinationState = State
    $destinationOrigin = Numbers $destinationState['window.origin']
    Assert-Equal ([TabAcrossNative]::Raise($appPid, $sourceOrigin[0], $sourceOrigin[1])) $true 'source raised'
    Assert-Equal ([TabAcrossNative]::Raise($appPid, $destinationOrigin[0], $destinationOrigin[1])) $true 'destination raised'

    # The source's first tab has two panes, with output to follow; its second keeps the window open.
    Select-Window $source
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio run 'Write-Output CARRIED$(6*7)' | Out-Null
    Aio wait text CARRIED42 | Out-Null
    Aio command tab.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio command tab.select_1 | Out-Null
    $s = State
    Assert-Equal $s['tabs.count'] 2 'the source holds two tabs'
    Assert-Equal $s['panes.count'] 2 'the first tab holds two panes'
    $session = $s['session.id']
    $sessions = $s['sessions.count']
    $workspaces = $s['workspaces.count']

    # Over a tab: the gap opens there and the ghost shows the tab landing.
    $onSecondTab = Target $destinationState['tab.2.strip_rect'] 0.5 0.5
    Begin-Drag 1 'strip_rect'
    Aio mouse move $onSecondTab --screen | Out-Null
    $s = State
    Assert-Equal $s['tabs.drop.window'] $destination 'the pointer targets the other window'
    Assert-Equal $s['tabs.drop.new_window'] false 'another window is not a tear-off'
    Assert-Equal $s['tabs.drop.thumbnail'] false 'the thumbnail stays hidden over a window'
    Destination-Incoming $source 1 1 'the second tab'
    Capture 'strip-gap'

    # Over the terminal: the tab would land after the others.
    $onContent = Target "0,0,$($destinationState['window.size'] -replace 'x', ',')" 0.3 0.5
    Aio mouse move $onContent --screen | Out-Null
    Destination-Incoming $source 1 2 'the content'
    Capture 'strip-end'

    # Escape puts everything back.
    Aio key Esc | Out-Null
    Aio mouse up $onContent --screen | Out-Null
    $s = State
    Assert-Equal $s['tabs.count'] 2 'Escape keeps the source tabs'
    Assert-Equal $s['panes.count'] 2 'Escape keeps the source panes'
    Assert-Equal $s['session.id'] $session 'Escape keeps the focused pane'
    Assert-Equal $s['tabs.drop.window'] 0 'Escape clears the drop target'
    Destination-Incoming $source 0 0 'Escape'
    Assert-Equal (State)['windows.count'] 2 'Escape closes no window'

    # The drop moves the tab between the destination's tabs, with its panes and shells.
    Begin-Drag 1 'strip_rect'
    Aio mouse move $onSecondTab --screen | Out-Null
    Aio mouse up $onSecondTab --screen | Out-Null
    $s = State
    Assert-Equal $s['tabs.count'] 1 'the tab left the source'
    Assert-Equal $s['windows.count'] 2 'a source with a tab left stays open'
    Assert-Equal $s['sessions.count'] $sessions 'the move starts or closes no shell'
    Select-Window $destination
    $d = State
    Assert-Equal $d['tabs.count'] 3 'the destination gained the tab'
    Assert-Equal $d['tabs.selected'] 2 'the tab landed in the slot and is selected'
    Assert-Equal $d['panes.count'] 2 'both panes came with it'
    Assert-Equal $d['session.id'] $session 'the destination shows the focused pane'
    Aio run 'Write-Output ALIVE$(6*7)' | Out-Null
    Aio wait text ALIVE42 | Out-Null
    Write-Output 'PASS the moved shell takes the keyboard'
    Capture 'strip-dropped'

    # The last tab, this time into a rail: its window closes and its workspace is gone.
    Aio key Ctrl+Shift+L | Out-Null
    $destinationState = State
    $onFirstRow = Target $destinationState['tab.1.rect'] 0.5 0.1
    Select-Window $source
    $s = State
    Assert-Equal $s['tabs.count'] 1 'one tab is left in the source'
    $lastSession = $s['session.id']
    Begin-Drag 1 'rect'
    Aio mouse move $onFirstRow --screen | Out-Null
    Assert-Equal (State)['tabs.drop.window'] $destination 'the rail targets the other window'
    Destination-Incoming $source 1 0 'the first row'
    Capture 'rail-gap'
    Aio mouse up $onFirstRow --screen | Out-Null
    $d = State
    Assert-Equal $d['windows.count'] 1 'the emptied window closed'
    Assert-Equal $d['window.id'] $destination 'the destination remains'
    Assert-Equal $d['workspaces.count'] ([int]$workspaces-1) 'the emptied workspace is deleted'
    Assert-Equal $d['sessions.count'] $sessions 'no shell stopped with the window'
    Assert-Equal $d['tabs.count'] 4 'the destination holds every tab'
    Assert-Equal $d['tabs.selected'] 1 'the last tab landed first and is selected'
    Assert-Equal $d['session.id'] $lastSession 'the destination shows the last tab'
    Aio run 'Write-Output LAST$(6*7)' | Out-Null
    Aio wait text LAST42 | Out-Null
    Capture 'rail-dropped'
    Write-Output 'PASS tab across windows journey'
} finally {
    & $ctl --name $Name stop | Out-Null
}

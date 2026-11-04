[CmdletBinding()]
param([string] $Name = 'tear-off')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$directory = Join-Path $repo "build/verify/$Name"

# The thumbnail is composed by the desktop window manager, so only a capture of the screen shows it.
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TearOffNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint param, ref RECT rect, uint ini);
    public static void Aware() { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
    public static int[] WorkArea() {
        var r = new RECT();
        SystemParametersInfoW(0x0030, 0, ref r, 0);
        return new[] { r.Left, r.Top, r.Right, r.Bottom };
    }
    public static void Screen(int x, int y, int width, int height, string path) {
        using (var bitmap = new Bitmap(width, height))
        using (var g = Graphics.FromImage(bitmap)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(width, height));
            bitmap.Save(path, ImageFormat.Png);
        }
    }
    // Captures the app window whose client origin is (x, y), whatever covers it.
    public static void Window(uint pid, int x, int y, string path) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, d) => {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner != pid || !IsWindowVisible(h)) return true;
            var o = new POINT(); ClientToScreen(h, ref o);
            if (o.X == x && o.Y == y) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        if (found == IntPtr.Zero) throw new Exception("no window has client origin " + x + "," + y);
        RECT r;
        GetWindowRect(found, out r);
        using (var bitmap = new Bitmap(r.Right-r.Left, r.Bottom-r.Top))
        using (var g = Graphics.FromImage(bitmap)) {
            IntPtr dc = g.GetHdc();
            try { PrintWindow(found, dc, 2); } finally { g.ReleaseHdc(dc); }
            bitmap.Save(path, ImageFormat.Png);
        }
    }
}
'@
[TearOffNative]::Aware()

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
    $defaultSize = (State)['window.size']
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio run 'Write-Output TORN$(6*7)' | Out-Null
    Aio wait text TORN42 | Out-Null
    $work = [TearOffNative]::WorkArea()
    Aio window move "$($work[0]+20),$($work[1]+20)" | Out-Null
    # Resizing a split reports a timeout on its grid; the window size is what this journey needs.
    & $ctl --name $Name resize 150x45 | Out-Null
    $s = State
    $source = $s['window.id']
    $size = Numbers $s['window.size'] 'x'
    if ("$($size[0])x$($size[1])" -eq $defaultSize) { throw 'The source window did not grow past the default size.' }
    $session = $s['session.id']
    $sessions = $s['sessions.count']
    $origin = Numbers $s['window.origin']
    $desktop = "$([int]($work[2]-420)),$([int]($work[3]-280))"

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
    Start-Sleep -Milliseconds 400
    $point = Numbers $desktop
    [TearOffNative]::Screen([int]$point[0]-20, [int]$point[1]-20, [int]$thumbnail[0]+80, [int]$thumbnail[1]+80,
        (Join-Path $directory 'thumbnail.png'))
    [TearOffNative]::Window([uint32]$s['app.pid'], [int]$origin[0], [int]$origin[1], (Join-Path $directory 'source-during-drag.png'))

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
    [TearOffNative]::Window([uint32]$n['app.pid'], [int]$landed[0], [int]$landed[1], (Join-Path $directory 'naming.png'))

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

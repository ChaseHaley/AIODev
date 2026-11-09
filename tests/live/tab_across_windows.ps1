[CmdletBinding()]
param([string] $Name = 'tab-across-windows')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$directory = Join-Path $repo "build/verify/$Name"

# The drop target comes from the hit test under the pointer, so the journey proves each point lands on the
# window it claims with aioctl window at. On the Win32 build other applications share the desktop, so the
# journey also keeps its windows above them; a headless instance has the virtual desktop to itself.
# Evidence is the app's own capture of the destination.
function Raise([uint32] $AppPid, [double[]] $Origin) {
    if ($script:headless) { return }
    if (-not ('TabAcrossNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class TabAcrossNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    // Puts the app's window with this client origin above every other window, without activating it.
    public static bool Raise(uint pid, int x, int y) {
        // Per-monitor v2, so client origins match the app's physical screen pixels.
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        var found = new List<IntPtr>();
        EnumWindows((h, d) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) found.Add(h); return true; }, IntPtr.Zero);
        foreach (var h in found) {
            var o = new POINT();
            ClientToScreen(h, ref o);
            if (o.X == x && o.Y == y) return SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
        }
        return false;
    }
}
'@
    }
    if (-not [TabAcrossNative]::Raise($AppPid, [int]$Origin[0], [int]$Origin[1])) {
        throw "No window of the app has client origin $($Origin -join ',')."
    }
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
function Numbers([string] $Value) { return @($Value -split ',' | ForEach-Object { [double]$_ }) }
function Select-Window([string] $Id) {
    Aio window select $Id | Out-Null
    $script:selected = $Id
}
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
    $hit = "$(Aio window at "$x,$y")" -replace '^window=', ''
    if ($hit -ne $d['window.id']) { throw "Point $x,$y hits window $hit, not $($d['window.id'])" }
    return "$x,$y"
}
function Destination-Incoming([string] $Source, [int] $Count, [int] $Slot, [string] $Label) {
    Select-Window $script:destination
    $d = State
    Assert-Equal $d['tabs.incoming.count'] $Count "$Label opens a gap for $Count"
    Assert-Equal $d['tabs.incoming.slot'] $Slot "$Label puts the gap at slot $Slot"
    Select-Window $Source
}
function Middle([string] $Rectangle) {
    $r = Numbers $Rectangle
    return "$([int]($r[0]+$r[2]/2)),$([int]($r[1]+$r[3]/2))"
}
# A dropdown row's center. Its rows are 34 DIP apart, with 8 more before the rows that make something new.
function Row-Point([int] $Index) {
    $s = State
    $scale = [double]$s['window.scale']
    $row = Numbers $s['workspace.picker.row']
    $selected = [int]$s['workspace.picker.selected']
    $rows = [int]$s['workspace.picker.count']-2
    $top = $row[1]+($Index-$selected)*34*$scale
    if ($Index -ge $rows -and $selected -lt $rows) { $top += 8*$scale }
    return "$([int]($row[0]+$row[2]/2)),$([int]($top+17*$scale))"
}
# Captures the destination, then gives the selection back to the window driving if it is still open.
function Capture([string] $Label) {
    Start-Sleep -Milliseconds 300
    $driving = $script:selected
    Select-Window $script:destination
    Aio capture --out (Join-Path $directory "$Label.png") | Out-Null
    $s = State
    if (@(1..[int]$s['windows.count'] | ForEach-Object { $s["window.$_.id"] }) -contains $driving) {
        Select-Window $driving
    }
    Write-Output "SHOT $Label"
}

Aio launch --fresh | Out-Null
try {
    $s = State
    $appPid = [uint32]$s['app.pid']
    # Only a headless instance reports what it asked of the operating system.
    $headless = $s.ContainsKey('os.thumbnail_places')
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

    # The destination overlaps the source, leaving the source's tabs in view and sitting above it. The
    # destination opened last, so it is already above the source on the virtual desktop.
    $work = @((State)['window.work_area'] -split ',' | ForEach-Object { [int]$_ })
    $scale = [double](State)['window.scale']
    Select-Window $source
    Aio window move "$($work[0]+20),$($work[1]+20)" | Out-Null
    $sourceOrigin = Numbers (State)['window.origin']
    Select-Window $destination
    Aio window move "$($work[0]+20+[int](760*$scale)),$($work[1]+20+[int](140*$scale))" | Out-Null
    $destinationState = State
    Raise $appPid $sourceOrigin
    Raise $appPid (Numbers $destinationState['window.origin'])

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

    # The workspace dropdown takes a tab as it does a pane, here in a window with a workspace to go to.
    $first = State
    $firstWorkspace = $first['workspace.id']
    Aio command workspace.new | Out-Null
    Aio key Enter | Out-Null
    Aio wait text 'PS ' | Out-Null
    $second = (State)['workspace.id']
    Aio command workspace.change | Out-Null
    Aio type $first['workspace.name'] | Out-Null
    Aio key Enter | Out-Null
    Aio expect state "workspace.id=$firstWorkspace" | Out-Null
    $tabs = [int](State)['tabs.count']
    $sessions = (State)['sessions.count']

    # Escape from the dropdown keeps everything.
    Begin-Drag 1 'rect'
    Aio mouse move (Middle (State)['workspace.button']) --px | Out-Null
    $s = State
    Assert-Equal $s['workspace.picker'] true 'the chip opens the dropdown'
    Assert-Equal $s['tabs.dragging'] true 'the dropdown keeps the drag'
    $row = Row-Point 0
    Aio mouse move $row --px | Out-Null
    Assert-Equal (State)['workspace.picker.selected'] 0 'the row under the pointer highlights'
    $destinationState = State
    Capture 'dropdown-row'
    Aio key Esc | Out-Null
    Aio mouse up $row --px | Out-Null
    $s = State
    Assert-Equal $s['workspace.picker'] false 'Escape closes the dropdown'
    Assert-Equal $s['tabs.count'] $tabs 'Escape keeps the tabs'
    # The next press reads the row's place, so the tab must finish sliding back first.
    Start-Sleep -Milliseconds 300

    # A row moves the tab to that workspace, which this window then shows, as for a pane.
    $moving = (State)['session.id']
    Begin-Drag 1 'rect'
    Aio mouse move (Middle (State)['workspace.button']) --px | Out-Null
    $row = Row-Point 0
    Aio mouse move $row --px | Out-Null
    Aio mouse up $row --px | Out-Null
    $s = State
    Assert-Equal $s['workspace.id'] $second 'the window shows the chosen workspace'
    Assert-Equal $s['tabs.count'] 2 'the workspace gained the tab'
    Assert-Equal $s['session.id'] $moving 'the moved tab is focused'
    Assert-Equal $s['sessions.count'] $sessions 'the move starts or closes no shell'
    Aio run 'Write-Output ROW$(6*7)' | Out-Null
    Aio wait text ROW42 | Out-Null

    # The row after the workspaces makes a new one, which names itself in its chip.
    $workspaces = [int]$s['workspaces.count']
    Begin-Drag 2 'rect'
    Aio mouse move (Middle (State)['workspace.button']) --px | Out-Null
    $row = Row-Point ([int](State)['workspace.picker.count']-2)
    Aio mouse move $row --px | Out-Null
    Aio mouse up $row --px | Out-Null
    $s = State
    Assert-Equal $s['workspaces.count'] ($workspaces+1) 'the row makes a workspace'
    Assert-Equal $s['rename.open'] true 'the new workspace names itself in its chip'
    Assert-Equal $s['tabs.count'] 1 'the new workspace holds the tab'
    Aio key Enter | Out-Null

    # That workspace's last tab, dropped on another workspace, deletes it and keeps the window showing the drop.
    $emptied = (State)['workspace.id']
    Begin-Drag 1 'rect'
    Aio mouse move (Middle (State)['workspace.button']) --px | Out-Null
    $row = Row-Point 0
    Aio mouse move $row --px | Out-Null
    Aio mouse up $row --px | Out-Null
    $s = State
    Assert-Equal $s['workspaces.count'] $workspaces 'the emptied workspace is deleted'
    Assert-Equal $s['windows.count'] 1 'the window stays to show the destination'
    if ($s['workspace.id'] -eq $emptied) { throw 'The window still shows the emptied workspace.' }
    Assert-Equal $s['sessions.count'] $sessions 'no shell stopped with the workspace'

    # The last row opens a window.
    Assert-Equal ([int]$s['tabs.count'] -ge 2) $true 'a tab stays behind'
    $count = [int]$s['tabs.count']
    Begin-Drag 1 'rect'
    Aio mouse move (Middle (State)['workspace.button']) --px | Out-Null
    $row = Row-Point ([int](State)['workspace.picker.count']-1)
    Aio mouse move $row --px | Out-Null
    Aio mouse up $row --px | Out-Null
    $s = State
    Assert-Equal $s['windows.count'] 2 'the last row opens a window'
    Assert-Equal $s['tabs.count'] ($count-1) 'the tab left this window'
    Assert-Equal $s['sessions.count'] $sessions 'the new window starts no shell'
    Write-Output 'PASS tab across windows journey'
} finally {
    & $ctl --name $Name stop | Out-Null
}

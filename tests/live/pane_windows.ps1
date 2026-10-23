[CmdletBinding()]
param([string] $Name = 'pane-windows')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'

# Cross-window steps rely on the OS hit test under the pointer, so the journey keeps its windows
# above other applications and proves each target point really lands where it claims. Evidence
# captures the window identified by its client origin, not the process's first visible window.
$assemblies = @('System.Drawing')
if ($PSVersionTable.PSEdition -eq 'Core') {
    $assemblies += 'Microsoft.Win32.Primitives', 'System.Drawing.Primitives', 'System.Drawing.Common', 'System.Collections'
    foreach ($assemblyName in @('System.Private.Windows.GdiPlus.dll', 'System.Private.Windows.Core.dll')) {
        $assemblyPath = Join-Path $PSHOME $assemblyName
        if (Test-Path -LiteralPath $assemblyPath) { $assemblies += $assemblyPath }
    }
}
Add-Type -ReferencedAssemblies $assemblies -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class PaneWindowsNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint param, ref RECT rect, uint ini);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    // Per-monitor v2, so coordinates match the app's physical screen pixels.
    static void Aware() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }
    static List<IntPtr> Windows(uint pid) {
        var found = new List<IntPtr>();
        EnumWindows((h, d) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }
    static POINT Origin(IntPtr h) { var o = new POINT(); ClientToScreen(h, ref o); return o; }
    public static int RaiseProcess(uint pid) {
        Aware();
        var found = Windows(pid);
        // HWND_TOPMOST without moving, sizing or activating.
        foreach (var h in found) SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
        return found.Count;
    }
    // Returns "pid,clientX,clientY" for the top-level window under a screen point.
    public static string HitAt(int x, int y) {
        Aware();
        IntPtr h = WindowFromPoint(new POINT { X = x, Y = y });
        if (h == IntPtr.Zero) return "0,0,0";
        h = GetAncestor(h, 2);
        uint pid; GetWindowThreadProcessId(h, out pid);
        var o = Origin(h);
        return pid + "," + o.X + "," + o.Y;
    }
    public static int[] WorkArea() {
        Aware();
        var r = new RECT();
        SystemParametersInfoW(0x0030, 0, ref r, 0);
        return new[] { r.Left, r.Top, r.Right, r.Bottom };
    }
    // Captures the frame of the visible window whose client origin is (x, y).
    public static string Shot(uint pid, int x, int y, string path) {
        Aware();
        foreach (var h in Windows(pid)) {
            var o = Origin(h);
            if (o.X != x || o.Y != y) continue;
            RECT r;
            if (!GetWindowRect(h, out r)) throw new Exception("GetWindowRect failed");
            int width = r.Right-r.Left, height = r.Bottom-r.Top;
            using (var bitmap = new Bitmap(width, height))
            using (var g = Graphics.FromImage(bitmap)) {
                IntPtr dc = g.GetHdc();
                bool ok;
                try { ok = PrintWindow(h, dc, 2); } finally { g.ReleaseHdc(dc); }
                if (!ok) throw new Exception("PrintWindow failed");
                bitmap.Save(path, ImageFormat.Png);
            }
            return width + "x" + height + " " + path;
        }
        throw new Exception("no visible window of pid " + pid + " has client origin " + x + "," + y);
    }
}
'@

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Tab-X($State) { if (-not $State.ContainsKey('tabs.x')) { throw 'State lacks tabs.x; the tab strip offset is unknown.' }; return [double]$State['tabs.x'] }
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
function Shot($State, [string] $Label) {
    $o = Origin $State
    [void][PaneWindowsNative]::Shot([uint32]$script:appPid, $o[0], $o[1], (Join-Path $directory "$Label.png"))
    Write-Output "SHOT $Label window=$($State['window.id'])"
}
function Select-Window([string] $Id) { Invoke-Aio window select $Id | Out-Null }
function Window-State([string] $Id) { Select-Window $Id; return Read-State }
function Window-Ids {
    $s = Read-State
    return @(1..[int]$s['windows.count'] | ForEach-Object { $s["window.$_.id"] })
}
function Inventory([string] $Id, [string] $Key) {
    $s = Read-State
    foreach ($i in 1..[int]$s['windows.count']) {
        if ($s["window.$i.id"] -eq $Id) { return $s["window.$i.$Key"] }
    }
    throw "window $Id is not in the inventory"
}
function Rect([string] $Value) { return @($Value -split ',' | ForEach-Object { [double]$_ }) }
function Origin($State) { return @($State['window.origin'] -split ',' | ForEach-Object { [int]$_ }) }
function Pane-Rects($State) {
    # A list keeps a single rectangle from being unrolled into four numbers.
    $rects = [Collections.Generic.List[object]]::new()
    foreach ($key in $State.Keys) { if ($key -match '^pane\.\d+\.rect$') { $rects.Add((Rect $State[$key])) } }
    return ,$rects
}
function Area($State) {
    $rects = Pane-Rects $State
    $left = ($rects | ForEach-Object { $_[0] } | Measure-Object -Minimum).Minimum
    $top = ($rects | ForEach-Object { $_[1] } | Measure-Object -Minimum).Minimum
    $right = ($rects | ForEach-Object { $_[0]+$_[2] } | Measure-Object -Maximum).Maximum
    $bottom = ($rects | ForEach-Object { $_[1]+$_[3] } | Measure-Object -Maximum).Maximum
    return @($left, $top, ($right-$left), ($bottom-$top))
}
# Screen point for a client point of the window whose state is supplied.
function Screen($State, [double] $X, [double] $Y) {
    $o = Origin $State
    return "$($o[0]+[int]$X),$($o[1]+[int]$Y)"
}
function Grab($State) {
    $r = Rect $State["pane.$($State['panes.focused']).rect"]
    $scale = [double]$State['window.scale']
    return "$([int]($r[0]+[math]::Min(80*$scale,$r[2]/3))),$([int]($r[1]+14*$scale))"
}
function Raise { [void][PaneWindowsNative]::RaiseProcess([uint32]$script:appPid) }
# Proves a screen point hits the AIODev window with the given client origin (or no AIODev window).
function Assert-Hit([string] $Point, $State, [string] $Label) {
    $xy = $Point -split ','
    $hit = ([PaneWindowsNative]::HitAt([int]$xy[0], [int]$xy[1])) -split ','
    if ($null -eq $State) {
        if ($hit[0] -eq "$script:appPid") { throw "$Label point $Point is covered by an AIODev window" }
        return
    }
    if ($hit[0] -ne "$script:appPid" -or "$($hit[1]),$($hit[2])" -ne $State['window.origin']) {
        throw "$Label point $Point hits pid $($hit[0]) origin $($hit[1]),$($hit[2]), not $($State['window.origin'])"
    }
}
function Shell-Pid {
    Invoke-Aio run 'Write-Output ("SHELL" + "PID_" + $PID)' | Out-Null
    Invoke-Aio wait text SHELLPID_ | Out-Null
    $match = [regex]::Matches((Invoke-Aio screen) -join "`n", 'SHELLPID_(\d+)')
    if ($match.Count -eq 0) { throw 'Shell PID marker is missing.' }
    return $match[$match.Count-1].Groups[1].Value
}
function Set-Minimum([int] $Columns, [int] $Rows) {
    $text = [IO.File]::ReadAllText($path)
    $text = [regex]::Replace($text, '(?m)^pane\.minimum_(columns|rows)\s*=.*\r?\n?', '')
    [IO.File]::WriteAllText($path, $text.TrimEnd()+"`npane.minimum_columns = $Columns`npane.minimum_rows = $Rows`n")
    Invoke-Aio command settings.reload | Out-Null
}
# Presses on the source pane header and starts a drag inside the source; later moves use screen points.
function Begin-Drag([string] $SourceId) {
    $s = Window-State $SourceId
    $grab = Grab $s
    Invoke-Aio mouse down $grab --px | Out-Null
    $nudge = $grab -split ','
    Invoke-Aio mouse move "$([int]$nudge[0]+24),$([int]$nudge[1]+24)" --px | Out-Null
    if ((Read-State)['panes.dragging'] -ne 'true') { throw 'Header press did not start a pane drag.' }
    return $s
}

Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    $s = Read-State
    $script:appPid = $s['app.pid']
    $source = $s['window.id']
    $sourceWorkspace = $s['workspace.id']
    Assert-True ($sourceWorkspace -ne '' -and $s['workspace.name'] -ne '') 'root workspace has a stable ID and name'

    # Root workspace controls: an explicit new window shows a distinct workspace; selecting an
    # already displayed workspace focuses its owner and leaves the requesting window unchanged.
    Invoke-Aio command window.new | Out-Null
    Invoke-Aio expect state windows.count=2
    $destination = @(Window-Ids | Where-Object { $_ -ne $source })[0]
    $d = Window-State $destination
    Invoke-Aio wait text 'PS '
    Assert-True ($d['workspace.id'] -ne $sourceWorkspace) 'new window displays a distinct workspace'
    Invoke-Aio command workspace.rename | Out-Null
    Invoke-Aio expect state "workspace.picker.rename_target=$($d['workspace.id'])"
    Invoke-Aio expect state rename.open=false
    Invoke-Aio type 'Destination' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Invoke-Aio expect state workspace.name=Destination
    Invoke-Aio key Esc | Out-Null
    $destinationWorkspace = $d['workspace.id']
    Select-Window $source
    Invoke-Aio command workspace.change | Out-Null
    Invoke-Aio expect state workspace.picker=true
    Invoke-Aio type 'Destination' | Out-Null
    Invoke-Aio key Enter | Out-Null
    $s = Read-State
    Assert-Equal $s['workspace.picker'] false 'choosing an open workspace closes the picker'
    Assert-Equal $s['workspace.id'] $sourceWorkspace 'requesting window keeps its workspace (D-051)'
    Assert-Equal $s['windows.count'] 2 'owner activation opens no window'
    Assert-Equal (Window-State $destination)['workspace.id'] $destinationWorkspace 'owner keeps the selected workspace'

    # Place both windows side by side with room for a desktop point below them.
    $work = [PaneWindowsNative]::WorkArea()
    foreach ($id in @($source, $destination)) { Select-Window $id; Invoke-Aio resize 72x16 | Out-Null }
    $size = @((Window-State $source)['window.size'] -split 'x' | ForEach-Object { [int]$_ })
    if (2*$size[0]+120 -gt $work[2]-$work[0] -or $size[1]+200 -gt $work[3]-$work[1]) {
        throw "Work area $($work -join ',') cannot hold two $($size -join 'x') windows and a desktop point."
    }
    Select-Window $source
    Invoke-Aio window move "$($work[0]+40),$($work[1]+40)" | Out-Null
    Select-Window $destination
    Invoke-Aio window move "$($work[0]+$size[0]+100),$($work[1]+40)" | Out-Null
    Raise

    # Source layout: four panes, so the first moves leave a populated source.
    Select-Window $source
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio command pane.split_down | Out-Null
    Invoke-Aio command pane.focus_left | Out-Null
    Invoke-Aio command pane.split_down | Out-Null
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state panes.count=4
    $shellPid = Shell-Pid
    $s = Read-State
    $moving = $s['session.id']
    $sessions = $s['sessions.count']
    # Output keeps arriving while the pane crosses windows; the last tick lands after the move.
    Invoke-Aio type '1..60 | ForEach-Object { "TICK_$_"; Start-Sleep -Milliseconds 250 }' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Invoke-Aio wait text TICK_2 | Out-Null

    # Escape over another window cancels without touching either layout.
    $d = Window-State $destination
    $a = Area $d
    $edge = Screen $d ($a[0]+$a[2]/2) ($a[1]+$a[3]-3)
    Assert-Hit $edge $d 'destination edge'
    Begin-Drag $source | Out-Null
    Invoke-Aio mouse move $edge --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.drop.window'] $destination 'pointer over another window targets it'
    Assert-Equal $s['panes.drop.root'] true 'destination edge offers workspace docking'
    Assert-Equal $s['panes.drop.shown'] true 'remote edge preview is shown'
    Assert-Equal $s['panes.drop.new_window'] false 'existing window is not a tear-off'
    Start-Sleep -Milliseconds 300
    Shot $d remote-edge-preview
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio mouse up $edge --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.count'] 4 'Escape keeps the source layout'
    Assert-Equal $s['panes.drop.window'] 0 'Escape clears the drop target'
    Assert-Equal (Window-State $destination)['panes.count'] 1 'Escape keeps the destination layout'

    # Edge drop into another window.
    Invoke-Aio expect no-text TICK_60
    Begin-Drag $source | Out-Null
    Invoke-Aio mouse move $edge --screen | Out-Null
    $preview = Rect (Read-State)['panes.drop.rect']
    Invoke-Aio mouse up $edge --screen | Out-Null
    Assert-Equal (Read-State)['panes.count'] 3 'source loses only the moved pane'
    $d = Window-State $destination
    Assert-Equal $d['panes.count'] 2 'destination gains the pane'
    Assert-Equal $d['session.id'] $moving 'moved runtime is focused in the destination'
    Assert-Equal $d['sessions.count'] $sessions 'cross-window move starts or closes no runtime'
    $landed = Rect $d["pane.$($d['panes.focused']).rect"]
    Assert-Equal ($landed -join ',') ($preview -join ',') 'remote edge preview equals the landed rectangle'
    Assert-Equal $landed[2] (Area $d)[2] 'edge-docked pane spans the destination width'
    Invoke-Aio wait text TICK_60 --timeout 20000 | Out-Null
    Assert-Equal (Shell-Pid) $shellPid 'moved shell keeps its process and receives later output'

    # Pane-targeted drop into a specific destination pane.
    $d = Window-State $destination
    $targetNode = @($d.Keys | Where-Object { $_ -match '^pane\.(\d+)\.rect$' } | ForEach-Object { $Matches[1] } |
        Where-Object { $_ -ne $d['panes.focused'] })[0]
    $t = Rect $d["pane.$targetNode.rect"]
    $inside = Screen $d ($t[0]+$t[2]*0.8) ($t[1]+$t[3]/2)
    Assert-Hit $inside $d 'destination pane'
    $s = Begin-Drag $source
    $second = $s['session.id']
    Invoke-Aio mouse move $inside --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.drop.window'] $destination 'pane target is in the destination'
    Assert-Equal $s['panes.drop.root'] false 'pane interior is not an edge dock'
    Assert-Equal $s['panes.drop.shown'] true 'pane target preview is shown'
    $preview = $s['panes.drop.rect']
    Start-Sleep -Milliseconds 300
    Shot $d remote-pane-preview
    Invoke-Aio mouse up $inside --screen | Out-Null
    $d = Window-State $destination
    Assert-Equal $d['panes.count'] 3 'pane drop splits the targeted destination pane'
    Assert-Equal $d['session.id'] $second 'pane-targeted runtime is focused'
    Assert-Equal $d["pane.$($d['panes.focused']).rect"] $preview 'pane target preview equals the result'
    Assert-Equal (Window-State $source)['panes.count'] 2 'source keeps its remaining panes'

    # Remote tab hover: dwelling over another window's background tab selects it; Escape restores it.
    Select-Window $destination
    Invoke-Aio command tab.new | Out-Null
    Invoke-Aio wait text 'PS '
    Invoke-Aio command tab.select_1 | Out-Null
    $d = Read-State
    $sessions = $d['sessions.count']
    $tab2 =Screen $d ((Tab-X $d)+[double]$d['tabs.width']*1.5) ([double]$d['tabs.height']/2)
    Assert-Hit $tab2 $d 'destination tab'
    Begin-Drag $source | Out-Null
    Invoke-Aio mouse move $tab2 --screen | Out-Null
    Start-Sleep -Milliseconds 500
    Invoke-Aio mouse move $tab2 --screen | Out-Null
    Assert-Equal (Window-State $destination)['tabs.selected'] 2 'remote tab dwell selects the hovered tab'
    Select-Window $source
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio mouse up $tab2 --screen | Out-Null
    $d = Window-State $destination
    Assert-Equal $d['tabs.selected'] 1 'Escape restores the destination tab'
    Assert-Equal $d['tab.2.panes'] 1 'Escape leaves the hovered tab unchanged'

    # Empty tab-strip space in another window creates a tab there from the running pane.
    $d = Window-State $destination
    $tabs = [int]$d['tabs.count']
    $strip = Screen $d ((Tab-X $d)+[double]$d['tabs.width']*$tabs+16*[double]$d['window.scale']) ([double]$d['tabs.height']/2)
    Assert-Hit $strip $d 'destination empty strip'
    $s = Begin-Drag $source
    $third = $s['session.id']
    Invoke-Aio mouse move $strip --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.drop.window'] $destination 'empty strip targets the destination'
    Assert-Equal $s['panes.drop.new_tab'] true 'remote empty strip offers a new tab'
    Assert-Equal $s['panes.drop.shown'] true 'remote new-tab indicator is shown'
    Start-Sleep -Milliseconds 300
    Shot $d remote-new-tab
    Invoke-Aio mouse up $strip --screen | Out-Null
    $d = Window-State $destination
    Assert-Equal $d['tabs.count'] ($tabs+1) 'remote strip drop appends a tab'
    Assert-Equal $d['tabs.selected'] ($tabs+1) 'new remote tab is selected'
    Assert-Equal $d['session.id'] $third 'new remote tab hosts the dragged runtime'
    Assert-Equal $d['sessions.count'] $sessions 'remote new tab starts no runtime'
    Assert-Equal (Window-State $source)['panes.count'] 1 'source keeps its last pane'

    # Settings accepts a pane: its tab offers a split destination and the terminal joins it.
    Select-Window $destination
    Invoke-Aio command settings.open | Out-Null
    $d = Read-State
    $settingsIndex = [int]$d['tabs.selected']
    Invoke-Aio command tab.select_1 | Out-Null
    $d = Read-State
    $settingsTab = Screen $d ((Tab-X $d)+[double]$d['tabs.width']*($settingsIndex-0.5)) ([double]$d['tabs.height']/2)
    Assert-Hit $settingsTab $d 'destination Settings tab'
    Select-Window $source
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    $sessions = (Read-State)['sessions.count']
    Begin-Drag $source | Out-Null
    Invoke-Aio mouse move $settingsTab --screen | Out-Null
    Start-Sleep -Milliseconds 500
    Invoke-Aio mouse move $settingsTab --screen | Out-Null
    Assert-Equal (Read-State)['panes.drop.shown'] true 'remote Settings tab accepts the pane'
    Invoke-Aio mouse up $settingsTab --screen | Out-Null
    $d = Window-State $destination
    Assert-Equal $d['tabs.selected'] $settingsIndex 'Settings drop keeps the destination tab'
    Assert-Equal $d['tabs.count'] $settingsIndex 'Settings drop adds no tab'
    Assert-Equal $d["tab.$settingsIndex.panes"] 2 'Settings tab gains the dragged pane'
    Assert-Equal $d['sessions.count'] $sessions 'Settings drop starts no runtime'
    $sourceState = Window-State $source
    Assert-Equal $sourceState['panes.count'] 1 'Settings drop keeps the rest of the source pane'

    # Minimum size: an oversize requirement rejects both a remote edge and a tear-off window.
    Select-Window $source
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS '
    $sessions = (Read-State)['sessions.count']
    Set-Minimum 10000 10000
    $windowsBefore = (Read-State)['windows.count']
    $d = Window-State $destination
    $a = Area $d
    $edge = Screen $d ($a[0]+$a[2]/2) ($a[1]+$a[3]-3)
    $desktop = "$($work[0]+60),$($work[3]-40)"
    Assert-Hit $desktop $null 'desktop'
    Begin-Drag $source | Out-Null
    Invoke-Aio mouse move $edge --screen | Out-Null
    Assert-Equal (Read-State)['panes.drop.shown'] false 'minimum size rejects the remote edge'
    Invoke-Aio mouse move $desktop --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.drop.shown'] false 'minimum size rejects a tear-off window'
    Assert-Equal $s['panes.drop.preview_window'] 0 'rejected tear-off keeps no preview'
    Invoke-Aio mouse up $desktop --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['windows.count'] $windowsBefore 'minimum rejection opens no window'
    Assert-Equal $s['panes.count'] 2 'minimum rejection keeps the source layout'
    Assert-Equal $s['sessions.count'] $sessions 'minimum rejection keeps every runtime'
    Assert-Equal (Window-State $destination)['panes.count'] 3 'minimum rejection keeps the destination layout'
    Select-Window $source
    Set-Minimum 0 0

    # Desktop tear-off: a prepared preview follows the pointer, is reused across window crossings,
    # and Escape discards it without closing the borrowed runtime.
    $s = Begin-Drag $source
    $torn = $s['session.id']
    $sourceGrid = $s['grid.size']
    Invoke-Aio mouse move $desktop --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.drop.new_window'] true 'desktop offers a new window'
    Assert-Equal $s['panes.drop.shown'] true 'tear-off source indicator is shown'
    $previewId = $s['panes.drop.preview_window']
    Assert-True ($previewId -ne '0') 'tear-off prepares a preview window'
    Assert-Equal (Inventory $previewId 'preparing') true 'preview window is provisional'
    Assert-Equal (Inventory $previewId 'preview_visible') true 'preview window is visible over the desktop'
    Assert-Equal $s['grid.size'] $sourceGrid 'source grid is preserved while previewing'
    Start-Sleep -Milliseconds 300
    Shot $s tear-off-preview-source
    Shot @{ 'window.id' = $previewId; 'window.origin' = (Inventory $previewId 'origin') } tear-off-preview-window
    Invoke-Aio mouse move $edge --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.drop.window'] $destination 'returning over a window retargets it'
    Assert-Equal $s['panes.drop.preview_window'] $previewId 'cached preview survives a window crossing'
    Assert-Equal (Inventory $previewId 'preview_visible') false 'cached preview hides over a window'
    Invoke-Aio mouse move $desktop --screen | Out-Null
    Assert-Equal (Read-State)['panes.drop.preview_window'] $previewId 'desktop reuses the same preview'
    Assert-Equal (Inventory $previewId 'preview_visible') true 'cached preview reappears over the desktop'
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio mouse up $desktop --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['windows.count'] $windowsBefore 'Escape discards the preview window'
    Assert-True (-not ((Window-Ids) -contains $previewId)) 'discarded preview leaves the inventory'
    Assert-Equal $s['panes.count'] 2 'tear-off cancel keeps the source layout'
    Assert-Equal $s['sessions.count'] $sessions 'tear-off cancel closes no runtime'
    Assert-Equal $s['grid.size'] $sourceGrid 'tear-off cancel keeps the source grid'

    # Focus loss while a preview is allocated cancels the gesture and discards the preview.
    Begin-Drag $source | Out-Null
    Invoke-Aio mouse move $desktop --screen | Out-Null
    $previewId = (Read-State)['panes.drop.preview_window']
    Assert-True ($previewId -ne '0') 'tear-off preview is allocated before focus loss'
    Invoke-Aio focus out | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.dragging'] false 'focus loss cancels the tear-off'
    Assert-Equal $s['panes.drop.preview_window'] 0 'focus loss releases the preview'
    Assert-Equal $s['windows.count'] $windowsBefore 'focus loss discards the preview window'
    Assert-True (-not ((Window-Ids) -contains $previewId)) 'focus-loss preview leaves the inventory'
    Invoke-Aio mouse up $desktop --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['windows.count'] $windowsBefore 'release after focus loss opens no window'
    Assert-Equal $s['panes.count'] 2 'focus-loss cancel keeps the source layout'
    Assert-Equal $s['sessions.count'] $sessions 'focus-loss cancel closes no runtime'
    Invoke-Aio focus in | Out-Null

    # Tear-off commit moves the running pane into a new window with its own workspace.
    Select-Window $source
    Invoke-Aio command pane.focus_left | Out-Null
    $s = Begin-Drag $source
    $torn = $s['session.id']
    Invoke-Aio mouse move $desktop --screen | Out-Null
    $previewId = (Read-State)['panes.drop.preview_window']
    Invoke-Aio mouse up $desktop --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['windows.count'] ([int]$windowsBefore+1) 'tear-off commit adds a window'
    Assert-Equal $s['panes.count'] 1 'tear-off commit removes the pane from the source'
    Assert-Equal $s['sessions.count'] $sessions 'tear-off commit starts or closes no runtime'
    $n = Window-State $previewId
    Assert-Equal $n['window.preparing'] false 'committed tear-off is an ordinary window'
    Assert-Equal $n['panes.count'] 1 'new window shows the torn-off pane'
    Assert-Equal $n['session.id'] $torn 'new window hosts the dragged runtime'
    Assert-True ($n['workspace.id'] -ne $sourceWorkspace -and $n['workspace.id'] -ne $destinationWorkspace) 'tear-off window has its own workspace'
    Invoke-Aio run 'Write-Output ("TORN" + "_ALIVE")' | Out-Null
    Invoke-Aio expect text TORN_ALIVE
    Shot $n tear-off-window
    Raise

    # The workspace's final pane cannot prepare or commit a tear-off.
    $s = Window-State $source
    $last = $s['session.id']
    $count = [int]$s['windows.count']
    $workspaceCount = $s['workspaces.count']
    $lastTab = $s['tab.1.id']
    $lastGrid = $s['grid.size']
    Begin-Drag $source | Out-Null
    $desktop2 = "$($work[0]+60),$($work[3]-90)"
    Assert-Hit $desktop2 $null 'second desktop'
    Invoke-Aio mouse move $desktop2 --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['panes.drop.new_window'] false 'final workspace pane offers no tear-off'
    Assert-Equal $s['panes.drop.shown'] false 'final workspace pane shows no drop indicator'
    Assert-Equal $s['panes.drop.preview_window'] 0 'final workspace pane prepares no window'
    Assert-Equal $s['windows.count'] $count 'rejected preview creates no window'
    Assert-Equal $s['workspaces.count'] $workspaceCount 'rejected preview creates no workspace'
    Invoke-Aio mouse up $desktop2 --screen | Out-Null
    $s = Read-State
    Assert-Equal $s['windows.count'] $count 'final-pane release creates no window'
    Assert-Equal $s['workspaces.count'] $workspaceCount 'final-pane release creates no workspace'
    Assert-Equal $s['workspace.id'] $sourceWorkspace 'final-pane release preserves workspace identity'
    Assert-Equal $s['tab.1.id'] $lastTab 'final-pane release preserves tab identity'
    Assert-Equal $s['session.id'] $last 'final-pane release preserves runtime identity'
    Assert-Equal $s['sessions.count'] $sessions 'final-pane release closes no runtime'
    Assert-Equal $s['grid.size'] $lastGrid 'final-pane release preserves geometry'
    Invoke-Aio run 'Write-Output ("LAST" + "_PRESERVED")' | Out-Null
    Invoke-Aio expect text LAST_PRESERVED

    # A one-pane tab may still tear off while another tab keeps the workspace populated.
    Invoke-Aio command tab.new | Out-Null
    Invoke-Aio wait text 'PS '
    $s = Read-State
    $oneTabSession = $s['session.id']
    $sessions = $s['sessions.count']
    Begin-Drag $source | Out-Null
    Invoke-Aio mouse move $desktop2 --screen | Out-Null
    $soleId = (Read-State)['panes.drop.preview_window']
    Assert-True ($soleId -ne '0') 'one-pane tab in multi-pane workspace prepares a preview'
    Invoke-Aio mouse up $desktop2 --screen | Out-Null
    $ids = Window-Ids
    Assert-True ($ids -contains $source) 'multi-tab tear-off preserves the source window'
    Assert-Equal $ids.Count ($count+1) 'multi-tab tear-off adds one window'
    $n = Window-State $soleId
    Assert-Equal $n['session.id'] $oneTabSession 'one-pane tab runtime survives in its new window'
    Assert-Equal $n['sessions.count'] $sessions 'multi-tab tear-off closes no runtime'
    Invoke-Aio run 'Write-Output ("SOLE" + "_ALIVE")' | Out-Null
    Invoke-Aio expect text SOLE_ALIVE
    Shot (Read-State) sole-tear-off-window
    $s = Window-State $source
    Assert-Equal $s['tabs.count'] 1 'multi-tab tear-off removes only the exhausted tab'
    Assert-Equal $s['tab.1.id'] $lastTab 'remaining tab keeps its stable ID'
    Assert-Equal $s['session.id'] $last 'remaining tab keeps its runtime'
    Invoke-Aio expect text LAST_PRESERVED

    # The final workspace pane may still move to an existing window.
    $d = Window-State $destination
    Invoke-Aio command tab.select_1 | Out-Null
    $d = Read-State
    $a = Area $d
    $edge = Screen $d ($a[0]+$a[2]/2) ($a[1]+$a[3]-3)
    Assert-Hit $edge $d 'final-pane existing destination'
    $beforeWindows = [int]$d['windows.count']
    $beforeWorkspaces = $d['workspaces.count']
    Begin-Drag $source | Out-Null
    Invoke-Aio mouse move $edge --screen | Out-Null
    Assert-Equal (Read-State)['panes.drop.shown'] true 'final workspace pane can target an existing window'
    Invoke-Aio mouse up $edge --screen | Out-Null
    Assert-True (-not ((Window-Ids) -contains $source)) 'existing-window transfer closes the exhausted source view'
    $d = Window-State $destination
    Assert-Equal $d['windows.count'] ($beforeWindows-1) 'existing-window final-pane transfer creates no window'
    Assert-Equal $d['workspaces.count'] ([int]$beforeWorkspaces-1) 'existing-window transfer removes the exhausted workspace'
    Assert-Equal $d['session.id'] $last 'existing-window transfer preserves final-pane runtime identity'
    Assert-Equal $d['sessions.count'] $sessions 'existing-window final-pane transfer closes no runtime'
    Invoke-Aio expect text LAST_PRESERVED

    # The first moved runtime still answers in the destination window.
    Select-Window $destination
    Invoke-Aio command tab.select_1 | Out-Null
    $d = Read-State
    $paneNode = @($d.Keys | Where-Object { $_ -match '^tab\.1\.pane\.(\d+)\.session$' -and $d[$_] -eq $moving } |
        ForEach-Object { ($_ -split '\.')[3] })[0]
    Assert-True ($null -ne $paneNode) 'first moved runtime remains in the destination tab'
    Write-Output "PASS shell pid=$shellPid runtime=$moving"
    Write-Output 'PASS cross-window, remote tab, tear-off, rejection and runtime continuity journey'
} catch {
    & $ctl --name $name state | Out-File (Join-Path $directory 'failure-state.txt')
    & $ctl --name $name screen | Out-File (Join-Path $directory 'failure-screen.txt')
    throw
} finally {
    & $ctl --name $name stop | Out-Null
}

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')]
    [string] $Name = 'work134-row-management',
    [switch] $Capture
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$data = Join-Path $repo "build/verify/$Name"
function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Rect($State, [string] $Key) {
    return @($State[$Key] -split ',' | ForEach-Object {
        [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture)
    })
}
function Click-Rect($Rect) {
    Invoke-Aio mouse click "$([int]($Rect[0]+$Rect[2]/2)),$([int]($Rect[1]+$Rect[3]/2))" --px
}
function Check([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "FAIL $Label" }
    Write-Output "PASS $Label"
}
function Shot([string] $Label) {
    Invoke-Aio wait idle | Out-Null
    if ($Capture) {
        if (-not ('Workspace134Capture' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Workspace134Capture {
    public delegate bool Callback(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint processId);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref Point point);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public static long Find(uint processId, int x, int y) {
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero) throw new Exception("Cannot inspect physical client origins.");
        IntPtr found = IntPtr.Zero;
        try {
            EnumWindows((h,p) => {
                uint owner; GetWindowThreadProcessId(h,out owner);
                Point origin = new Point();
                if (owner == processId && IsWindowVisible(h) && ClientToScreen(h,ref origin) &&
                    origin.X == x && origin.Y == y) { found = h; return false; }
                return true;
            },IntPtr.Zero);
        } finally { SetThreadDpiAwarenessContext(previous); }
        if (found == IntPtr.Zero) throw new Exception("No owned window matches the selected client origin.");
        return found.ToInt64();
    }
}
'@
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $s = Read-State
            $notices = @($s.Keys | Where-Object { $_.StartsWith('notice.') -and $s[$_] })
            if ($notices.Count -eq 0) { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw "Notice obscures capture: $Label" }
            Start-Sleep -Milliseconds 100
        } while ($true)
        Start-Sleep -Milliseconds 250
        $s = Read-State
        $origin = $s['window.origin'] -split ','
        $handle = [Workspace134Capture]::Find([uint32]$s['app.pid'], [int]$origin[0], [int]$origin[1])
        Invoke-Aio state | Set-Content -LiteralPath "$data/$Label-state.txt" -Encoding utf8
        & (Join-Path $repo 'tools/win32.ps1') -Name $Name -WindowHandle $handle -Shot "$data/$Label.png" -Frame
        if ($LASTEXITCODE -ne 0) { throw "Capture failed: $Label" }
    } else {
        Invoke-Aio state | Set-Content -LiteralPath "$data/$Label-state.txt" -Encoding utf8
    }
}
function Open-Row([string] $Filter, [string] $Id) {
    Invoke-Aio command workspace.change
    if ($Filter) { Invoke-Aio type $Filter }
    Click-Rect (Rect (Read-State) 'workspace.picker.menu_button')
    Invoke-Aio expect state "workspace.picker.menu_target=$Id"
}
function Check-Inline([string] $Id, [string] $Label) {
    Invoke-Aio wait idle | Out-Null
    $s = Read-State
    $panel = Rect $s 'workspace.picker.rect'
    $row = Rect $s 'workspace.picker.row'
    $field = Rect $s 'workspace.picker.rename_field'
    $size = $s['window.size'] -split 'x'
    Check ($s['workspace.picker.rename_target'] -eq $Id -and $s['rename.open'] -eq 'false') "$Label inline target without popup"
    Check ($field[1] -ge $row[1]+$row[3] -and $field[1]+$field[3] -le $panel[1]+$panel[3]) "$Label field below visible row"
    Check ($panel[0]+$panel[2] -le [double]$size[0] -and $panel[1]+$panel[3] -le [double]$size[1]) "$Label panel fits client"
    Shot $Label
}

# Root owns execution. All input uses the named instance's control path; no host clipboard/input.
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    $first = Read-State
    $current, $session, $window = $first['workspace.id'], $first['session.id'], $first['window.id']
    Invoke-Aio command workspace.change
    # The same requirement fails against the unmodified dropdown (six, rather than three, stops).
    Invoke-Aio expect state workspace.picker.count=3
    Invoke-Aio key Ctrl+P
    Invoke-Aio expect state workspace.picker.selected=2
    Invoke-Aio key Ctrl+N
    Invoke-Aio expect state workspace.picker.selected=0
    Shot 'main-only-creation-actions'
    Invoke-Aio key Esc

    Invoke-Aio command workspace.new
    Invoke-Aio wait text 'PS '
    $target = (Read-State)['workspace.id']
    Invoke-Aio command workspace.select_1
    Open-Row 'Workspace 2' $target
    Shot 'noncurrent-row-context'
    Invoke-Aio key Enter
    Check-Inline $target 'noncurrent-inline-rename'
    Invoke-Aio expect state "workspace.id=$current"
    Invoke-Aio type '  Build tools  '
    Invoke-Aio key Enter
    Invoke-Aio expect state workspace.picker.rename_target=0
    Invoke-Aio expect state "workspace.id=$current"
    Invoke-Aio command workspace.change
    Invoke-Aio type 'Build tools'
    Invoke-Aio expect state workspace.picker.count=3
    Invoke-Aio key F2
    Invoke-Aio type '   '
    Invoke-Aio key Enter
    Invoke-Aio expect state workspace.picker.rename_error=true
    Shot 'empty-rename-stays-open'
    Invoke-Aio key Esc
    Invoke-Aio expect state workspace.picker=true
    Invoke-Aio key F2
    Invoke-Aio type 'Canceled blur'
    Invoke-Aio focus out
    Invoke-Aio expect state workspace.picker=false
    Invoke-Aio focus in

    Open-Row 'Build tools' $target
    Invoke-Aio key Ctrl+N Enter
    Invoke-Aio expect state "workspace.picker.icon_target=$target"
    Invoke-Aio key Right Enter
    Invoke-Aio expect state workspace.picker.icons=false
    Invoke-Aio expect state 'workspace.picker.query=Build tools'
    Invoke-Aio expect state "workspace.id=$current"
    Invoke-Aio expect state workspace.icon.preset=0
    Invoke-Aio key Right Ctrl+N Enter
    $emoji = -join (@(0x1F469,0x1F3FD,0x200D,0x1F4BB) | ForEach-Object { [char]::ConvertFromUtf32($_) })
    Invoke-Aio type $emoji
    Shot 'target-custom-emoji'
    Invoke-Aio key Esc
    Invoke-Aio expect state 'workspace.picker.query=Build tools'
    Invoke-Aio key Right Ctrl+N Enter
    Invoke-Aio type $emoji
    Invoke-Aio key Tab Enter
    Invoke-Aio expect state workspace.picker.icons=false
    Invoke-Aio key Enter
    Invoke-Aio expect state "workspace.id=$target"
    Invoke-Aio expect state 'workspace.name=Build tools'
    Invoke-Aio expect state "workspace.icon.emoji=$emoji"
    Invoke-Aio command workspace.select_1
    Invoke-Aio expect state "session.id=$session"

    Open-Row 'Build tools' $target
    Invoke-Aio key End Enter
    Invoke-Aio expect state "confirm.workspace=$target"
    Invoke-Aio expect state workspace.picker=false
    Shot 'noncurrent-delete-confirm'
    Invoke-Aio key Esc
    Invoke-Aio expect state workspaces.count=2
    Invoke-Aio expect state "workspace.id=$current"

    foreach ($mode in @('dark','light')) {
        $path = Join-Path $data 'settings.ini'
        $text = [IO.File]::ReadAllText($path)
        $text = [regex]::Replace($text, '(?m)^theme\.name\s*=.*\r?\n?', '')
        [IO.File]::WriteAllText($path, $text.TrimEnd()+"`ntheme.name = studio-$mode`n")
        Invoke-Aio command settings.reload
        foreach ($dpi in @(96,144,168,192)) {
            Invoke-Aio dpi $dpi
            Invoke-Aio resize 40x10
            Open-Row 'Build tools' $target
            Shot "$mode-$dpi-context"
            Invoke-Aio key Enter
            Check-Inline $target "$mode-$dpi-inline"
            Invoke-Aio key Esc Esc
        }
    }
    Invoke-Aio dpi 96
    Invoke-Aio resize 100x30
    Invoke-Aio command window.new
    $foreign = Read-State
    $owner = $foreign['window.2.id']
    Invoke-Aio window select $owner
    Invoke-Aio wait text 'PS '
    $foreign = Read-State
    $foreignId = $foreign['workspace.id']
    Invoke-Aio command workspace.rename
    Invoke-Aio type 'Foreign owner'
    Invoke-Aio key Enter
    Invoke-Aio window select $window
    Open-Row 'Foreign owner' $foreignId
    Invoke-Aio key Enter
    Invoke-Aio type 'Foreign renamed'
    Invoke-Aio key Enter
    Invoke-Aio expect state "workspace.id=$current"
    Invoke-Aio window select $owner
    Invoke-Aio expect state 'workspace.name=Foreign renamed'
    Invoke-Aio window select $window
    Open-Row 'Foreign renamed' $foreignId
    Invoke-Aio key End Enter
    Invoke-Aio expect state "confirm.workspace=$foreignId"
    Shot 'foreign-owner-delete-confirm'
    Invoke-Aio key Esc
    Invoke-Aio expect state "workspace.id=$current"
    Invoke-Aio expect state "session.id=$session"
    Write-Output 'PASS row-target management, inline rename, compact chooser, cancellation, themes/DPI and ownership'
} finally {
    Invoke-Aio stop
}

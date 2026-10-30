[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'settings-publication'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SettingsPublicationWindow {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref Point point);
    public static long Find(uint pid, int x, int y) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, d) => {
            uint owner; GetWindowThreadProcessId(h, out owner);
            var p = new Point();
            if (owner == pid && ClientToScreen(h, ref p) && p.X == x && p.Y == y) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        if (found == IntPtr.Zero) throw new Exception("Cannot find the selected window.");
        return found.ToInt64();
    }
}
'@

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $state = @{}
    foreach ($line in (& $ctl --name $name state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect state.' }
    return $state
}
function Assert-Value($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
function Save-Value([string] $Value) {
    Invoke-Aio key Ctrl+A
    Invoke-Aio type $Value
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.error'] false 'the inline write succeeds'
}
function Shot([string] $Label) {
    & $ctl --name $name state | Set-Content (Join-Path $directory "$Label-state.txt")
    $state = Read-State
    $origin = $state['window.origin'] -split ','
    $handle = [SettingsPublicationWindow]::Find([uint32]$state['app.pid'], [int]$origin[0], [int]$origin[1])
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -WindowHandle $handle -Frame -Shot (Join-Path $directory "$Label.png") | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}

Invoke-Aio launch --fresh
try {
    $first = (Read-State)['window.id']
    Invoke-Aio command settings.open
    Invoke-Aio type font.size
    Invoke-Aio key Tab Ctrl+A
    Invoke-Aio type 19
    Invoke-Aio command window.new
    $windows = Read-State
    Assert-Value $windows['windows.count'] 2 'the second window is created'
    $second = @($windows.Keys | Where-Object { $_ -match '^window\.\d+\.id$' } |
        ForEach-Object { $windows[$_] } | Where-Object { $_ -ne $first })[0]
    if (-not $second) { throw 'The second window has no ID.' }
    Invoke-Aio window select $second
    Invoke-Aio command settings.open
    Invoke-Aio type pane.gap
    Invoke-Aio key Tab
    Save-Value 9
    Invoke-Aio window select $first
    Assert-Value (Read-State)['settings.key'] font.size 'the other page keeps its selected field'
    Assert-Value (Read-State)['settings.value'] 19 'an inline save preserves the other windows draft'
    Invoke-Aio command view.tabs_orientation
    Assert-Value (Read-State)['settings.value'] 19 'a disk writer also preserves the pending draft'
    Assert-Value (Read-State)['tabs.orientation'] vertical 'the orientation write applies'
    Shot dark-draft
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.error'] false 'the preserved draft saves without an internal conflict'
    $saved = [IO.File]::ReadAllText($path)
    foreach ($line in @('font.size = 19', 'pane.gap = 9', 'tabs.orientation = vertical')) {
        if (-not $saved.Contains($line)) { throw "The combined settings file lacks $line" }
    }
    Write-Output 'PASS the combined file keeps all three writers'
    Invoke-Aio window select $second
    Invoke-Aio key Esc
    Invoke-Aio key Ctrl+A
    Invoke-Aio type theme.name
    Invoke-Aio key Tab Down Enter
    Assert-Value (Read-State)['settings.error'] false 'the second page can save after the first page'
    Assert-Value (Read-State)['theme.name'] studio-light 'the light theme applies to both windows'
    Invoke-Aio window select $first
    Assert-Value (Read-State)['settings.value'] 19 'a clean selected field follows the next publication'
    Shot light-saved
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 21
    [IO.File]::AppendAllText($path, "`n# external owner edit`n")
    $external = [IO.File]::ReadAllText($path)
    Invoke-Aio key Enter
    Assert-Value (Read-State)['settings.error'] true 'a real external edit still conflicts'
    Assert-Value (Read-State)['settings.value'] 21 'a rejected save keeps draft text'
    Assert-Value ([IO.File]::ReadAllText($path)) $external 'a rejected save keeps the external file'
} finally {
    & $ctl --name $name stop | Out-Null
}

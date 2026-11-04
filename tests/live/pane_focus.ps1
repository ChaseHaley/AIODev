[CmdletBinding()]
param([string] $Name = 'pane-focus', [switch] $Translated)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$native = Join-Path $repo 'tools/win32.ps1'
$data = Join-Path $repo "build/verify/$Name"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PaneFocusNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public static long AtOrigin(uint pid, int x, int y) {
        var prior = SetThreadDpiAwarenessContext(new IntPtr(-4));
        IntPtr found = IntPtr.Zero;
        try {
            EnumWindows((h, d) => {
                uint p; GetWindowThreadProcessId(h, out p);
                var o = new POINT();
                if (p == pid && IsWindowVisible(h) && ClientToScreen(h, ref o) && o.X == x && o.Y == y) found = h;
                return true;
            }, IntPtr.Zero);
        } finally { SetThreadDpiAwarenessContext(prior); }
        return found.ToInt64();
    }
}
'@

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out
}
function Read-State {
    $s = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $s[$pair[0]] = $pair[1].Trim('"') }
    }
    $s
}
function Select-Window([string] $Id) { Invoke-Aio window select $Id | Out-Null }
function Handle([string] $Id) {
    Select-Window $Id
    $s = Read-State
    $origin = $s['window.origin'] -split ','
    $h = [PaneFocusNative]::AtOrigin([uint32]$s['app.pid'], [int]$origin[0], [int]$origin[1])
    if ($h -eq 0) { throw "Cannot find owned window $Id" }
    $h
}
function Activate-Window([string] $Id, [string] $Marker) {
    if ($Translated) {
        $s = Read-State
        foreach ($key in @($s.Keys | Where-Object { $_ -match '^window\.\d+\.id$' })) {
            Select-Window $s[$key]
            Invoke-Aio focus out | Out-Null
        }
        Select-Window $Id
        Invoke-Aio focus in | Out-Null
        Invoke-Aio type "# $Marker" | Out-Null
        Invoke-Aio wait text $Marker | Out-Null
        Invoke-Aio key Enter | Out-Null
        return
    }
    & $native -Name $Name -WindowHandle (Handle $Id) -SendText "# $Marker" -Activate | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Native focus/text failed.' }
    Invoke-Aio expect state window.focused=true | Out-Null
    Invoke-Aio wait text $Marker | Out-Null
    & $native -Name $Name -WindowHandle (Handle $Id) -Chord '0x0D' -Activate | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Native Enter failed.' }
}
function Assert-Appearance([string] $Id, [bool] $Focused, [string] $Color, [string] $Label) {
    Select-Window $Id
    $s = Read-State
    Invoke-Aio expect state "window.focused=$($Focused.ToString().ToLowerInvariant())" | Out-Null
    $count = 0
    foreach ($key in @($s.Keys | Where-Object { $_ -match '^pane\.\d+\.rect$' })) {
        $r = $s[$key] -split ',' | ForEach-Object { [double]$_ }
        $region = "$([int]$r[0]),$([int]$r[1]),$([int]$r[2]),$([int]$r[3])"
        $draws = Invoke-Aio draws --region $region --kind rect
        if (@($draws | Where-Object { $_ -match [regex]::Escape($Color) }).Count -gt 0) { $count++ }
    }
    $expected = if ($Focused) { 1 } else { 0 }
    if ($count -ne $expected) { throw "$Label expected $expected outlined panes, observed $count" }
    Invoke-Aio capture --out (Join-Path $data "$Label.png") | Out-Null
    Write-Output "PASS $Label ($count focused pane outlines)"
}

Invoke-Aio launch --fresh | Out-Null
try {
    Invoke-Aio doctor
    Invoke-Aio wait text 'PS ' | Out-Null
    $first = (Read-State)['window.id']
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio command window.new | Out-Null
    $s = Read-State
    $second = @($s.Keys | Where-Object { $_ -match '^window\.\d+\.id$' } |
        ForEach-Object { $s[$_] } | Where-Object { $_ -ne $first })[0]
    if (-not $second) { throw 'Second window was not created.' }
    Select-Window $second
    Invoke-Aio expect state rename.open=true | Out-Null
    Invoke-Aio type FocusSecond | Out-Null
    Invoke-Aio key Enter | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio window move '700,100' | Out-Null
    $selected = @{}
    foreach ($id in @($first, $second)) {
        Select-Window $id
        $selected[$id] = (Read-State)['panes.focused']
        Invoke-Aio run "function prompt { 'P> ' }; Clear-Host" | Out-Null
    }

    $settingsPath = Join-Path $data 'settings.ini'
    $baseSettings = [IO.File]::ReadAllText($settingsPath)
    foreach ($theme in @('studio-dark', 'studio-light')) {
        foreach ($gap in @(4, 0)) {
            [IO.File]::WriteAllText($settingsPath,
                $baseSettings + "`ntheme.name = $theme`npane.gap = $gap`npane.focus_border = 4`npane.unfocused_dim = 45`n")
            Invoke-Aio command settings.reload | Out-Null
            $focusColor = if ($theme -eq 'studio-dark') { '#a194ff80' } else { '#5b45e080' }
            Activate-Window $first "focus-first-$theme-$gap"
            Assert-Appearance $first $true $focusColor "$theme-gap$gap-first-active"
            Assert-Appearance $second $false $focusColor "$theme-gap$gap-second-inactive"
            $screen = (Invoke-Aio screen) -join "`n"
            if ($screen.Contains("focus-first-$theme-$gap")) { throw 'Keyboard input reached the inactive window.' }
            Activate-Window $second "focus-second-$theme-$gap"
            Assert-Appearance $first $false $focusColor "$theme-gap$gap-first-inactive"
            Assert-Appearance $second $true $focusColor "$theme-gap$gap-second-active"
            foreach ($id in @($first, $second)) {
                Select-Window $id
                if ((Read-State)['panes.focused'] -ne $selected[$id]) { throw 'Window activation lost pane selection.' }
            }
        }
    }
    Select-Window $second
    Invoke-Aio command pane.linked_window | Out-Null
    $s = Read-State
    $linked = $null
    for ($i = 1; $i -le [int]$s['windows.count']; $i++) {
        if ($s["window.$i.linked"] -eq 'true') { $linked = $s["window.$i.id"] }
    }
    if (-not $linked) { throw 'Linked window was not created.' }
    Activate-Window $linked 'focus-linked'
    Assert-Appearance $first $false $focusColor 'linked-first-inactive'
    Assert-Appearance $second $false $focusColor 'linked-host-inactive'
    Assert-Appearance $linked $true $focusColor 'linked-active'
    Select-Window $first
    Invoke-Aio command settings.open | Out-Null
    if ($Translated) {
        foreach ($id in @($first, $second, $linked)) { Select-Window $id; Invoke-Aio focus out | Out-Null }
        Select-Window $first
        Invoke-Aio focus in | Out-Null
    } else {
        & $native -Name $Name -WindowHandle (Handle $first) -Chord '0x10' -Activate | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Native settings activation failed.' }
    }
    Assert-Appearance $first $true $focusColor 'settings-active'
    Assert-Appearance $linked $false $focusColor 'linked-inactive'
    if ($Translated) {
        foreach ($id in @($first, $second, $linked)) {
            Select-Window $id
            Invoke-Aio focus out | Out-Null
            Assert-Appearance $id $false $focusColor "all-inactive-$id"
        }
    }
    Invoke-Aio doctor
    $route = if ($Translated) { 'translated focus events' } else { 'native focus and keyboard routing' }
    Write-Output "PASS $route across workspace windows, a linked pane and Settings"
} finally {
    & $ctl --name $Name stop | Write-Output
    if ($LASTEXITCODE -ne 0) { throw 'Owned instance cleanup failed.' }
}

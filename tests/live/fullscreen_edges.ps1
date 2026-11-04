[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'fullscreen-edges'
$data = Join-Path $repo "build/verify/$name"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FullscreenEdges {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO {
        public int size; public RECT monitor, work; public uint flags;
    }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT point);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr h, ref MONITORINFO info);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@
$previousDpi = [FullscreenEdges]::SetThreadDpiAwarenessContext([IntPtr](-4))
if ($previousDpi -eq [IntPtr]::Zero) {
    throw "SetThreadDpiAwarenessContext failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $args failed: $result" }
    $result | Write-Output
}

function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $lines) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1]
    }
    return $state
}

function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ($Actual -cne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label=$Actual"
}

function Read-Bounds {
    $state = Read-State
    $process = Get-Process -Id ([int]$state['app.pid'])
    $hwnd = $process.MainWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { throw 'Owned verification window not found.' }
    $outer = New-Object FullscreenEdges+RECT
    $client = New-Object FullscreenEdges+RECT
    $origin = New-Object FullscreenEdges+POINT
    $monitor = New-Object FullscreenEdges+MONITORINFO
    $monitor.size = [Runtime.InteropServices.Marshal]::SizeOf($monitor)
    if (-not [FullscreenEdges]::GetWindowRect($hwnd, [ref]$outer) -or
        -not [FullscreenEdges]::GetClientRect($hwnd, [ref]$client) -or
        -not [FullscreenEdges]::ClientToScreen($hwnd, [ref]$origin) -or
        -not [FullscreenEdges]::GetMonitorInfoW(
            [FullscreenEdges]::MonitorFromWindow($hwnd, 2), [ref]$monitor)) {
        throw 'Cannot inspect native window geometry.'
    }
    return @{
        outer = "$($outer.left),$($outer.top),$($outer.right),$($outer.bottom)"
        client = "$($origin.x),$($origin.y),$($origin.x+$client.right),$($origin.y+$client.bottom)"
        monitor = "$($monitor.monitor.left),$($monitor.monitor.top),$($monitor.monitor.right),$($monitor.monitor.bottom)"
    }
}

try {
    Invoke-Aio launch --fresh
    Invoke-Aio doctor
    foreach ($maximized in @($false, $true)) {
        if ($maximized) {
            $width = [double]((Read-State)['window.size'] -split 'x')[0]
            $scale = [double](Read-State)['window.scale']
            $point = "$([int]($width-69*$scale)),$([int](20*$scale))"
            Invoke-Aio mouse click $point --px
            Invoke-Aio expect state window.maximized=true
        }
        $prior = Read-Bounds
        $priorSize = (Read-State)['window.size']
        foreach ($cycle in 1..2) {
            Invoke-Aio key F11
            Invoke-Aio expect state window.pane_view=Screen
            $bounds = Read-Bounds
            Assert-Equal $bounds.outer $bounds.monitor 'native window covers monitor'
            Assert-Equal $bounds.client $bounds.monitor 'native client covers monitor'
            $state = Read-State
            $pane = $state['panes.focused']
            $size = $state['window.size'] -split 'x'
            Invoke-Aio capture --out (Join-Path $data "fullscreen-$maximized-$cycle.png")
            & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame `
                -Shot (Join-Path $data "fullscreen-native-$maximized-$cycle.png")
            if ($LASTEXITCODE -ne 0) { throw 'Native screenshot failed.' }
            Assert-Equal $state["pane.$pane.rect"] "0,0,$($size[0]),$($size[1])" 'pane reaches all edges'
            $pixels = & $ctl --name $name pixels --region "0,0,$($size[0]),1"
            if ($LASTEXITCODE -ne 0) { throw 'Top edge pixel read failed.' }
            $expected = '0 coverage=1.000 colors=1 color='+$state['terminal.background']+'ff'
            Assert-Equal $pixels $expected 'entire top edge is pane background'
            Invoke-Aio key F11
            Invoke-Aio expect state window.pane_view=Split
            Invoke-Aio expect state "window.maximized=$($maximized.ToString().ToLowerInvariant())"
            $restored = Read-Bounds
            Assert-Equal $restored.outer $prior.outer 'restored native placement'
            Assert-Equal (Read-State)['window.size'] $priorSize 'restored client size'
        }
    }
    Invoke-Aio doctor
    Write-Output 'PASS fullscreen edges from normal and maximized placement'
} finally {
    & $ctl --name $name stop | Write-Output
    if ([FullscreenEdges]::SetThreadDpiAwarenessContext($previousDpi) -eq [IntPtr]::Zero) {
        throw "Restore DPI context failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

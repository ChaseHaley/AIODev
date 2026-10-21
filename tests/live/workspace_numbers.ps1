[CmdletBinding()]
param(
    [string] $Name = ('work131-' + [guid]::NewGuid().ToString('N').Substring(0, 12)),
    [string] $Repository = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string] $DesktopPoint = '-30000,-30000'
)
$ErrorActionPreference = 'Stop'
$ctl = Join-Path $Repository 'build/aioctl.exe'
$directory = Join-Path $Repository "build/verify/$Name"
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
function Assert-Equal($Actual, $Expected, [string] $Label) {
    if ("$Actual" -ne "$Expected") { throw "$Label expected $Expected, observed $Actual" }
    Write-Host "PASS $Label"
}
function Assert-True([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "$Label failed" }
    Write-Host "PASS $Label"
}
function Select-Window([string] $Id) { Invoke-Aio window select $Id | Out-Null }
function Save-State([string] $Label) { Invoke-Aio state | Set-Content -LiteralPath "$directory/$Label-state.txt" }
function Begin-Drag {
    Select-Window $script:source
    $s = Read-State
    $r = @($s["pane.$($s['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ })
    $scale = [double]$s['window.scale']
    $x = [int]($r[0] + [math]::Min(80*$scale, $r[2]/3))
    $y = [int]($r[1] + 14*$scale)
    Invoke-Aio mouse down "$x,$y" --px | Out-Null
    Invoke-Aio mouse move "$($x+24),$($y+24)" --px | Out-Null
    Assert-Equal (Read-State)['panes.dragging'] true 'header drag started'
}
function Preview {
    Invoke-Aio mouse move $DesktopPoint --screen | Out-Null
    $s = Read-State
    $id = $s['panes.drop.preview_window']
    Assert-True ($id -ne '0') 'tear-off preview allocated'
    foreach ($index in 1..[int]$s['windows.count']) {
        if ($s["window.$index.id"] -ne $id) { continue }
        Assert-Equal $s["window.$index.preparing"] true 'preview remains provisional'
        Write-Host "RECEIPT preview window=$id preparing=$($s["window.$index.preparing"])"
        return $id
    }
    throw 'Preview is absent from the actual window inventory.'
}
function Snapshot([string] $Label) {
    Save-State $Label
    $s = Read-State
    $origin = $s['window.origin'] -split ','
    $handle = [WorkspaceNumberCapture]::Find([uint32]$s['app.pid'], [int]$origin[0], [int]$origin[1])
    & "$Repository/tools/win32.ps1" -Name $Name -WindowHandle $handle -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Read-only PrintWindow capture failed.' }
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WorkspaceNumberCapture {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll", SetLastError=true)] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public static long Find(uint pid, int x, int y) {
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            long result = 0;
            bool duplicate = false;
            if (!EnumWindows((h, p) => {
                uint owner;
                if (GetWindowThreadProcessId(h, out owner) == 0 || owner != pid || !IsWindowVisible(h)) return true;
                POINT origin = new POINT();
                if (!ClientToScreen(h, ref origin)) throw new System.ComponentModel.Win32Exception();
                if (origin.x == x && origin.y == y) { duplicate |= result != 0; result = h.ToInt64(); }
                return true;
            }, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
            if (result == 0 || duplicate) throw new Exception("selected window origin is not unique");
            return result;
        } finally { SetThreadDpiAwarenessContext(previous); }
    }
}
'@

try {
    Invoke-Aio launch --fresh
    $initial = Read-State
    Write-Host "RECEIPT app=$($initial['app.pid']) build=$($initial['app.build']) instance=$Name"
    $script:source = $initial['window.id']
    foreach ($number in 2..4) {
        Invoke-Aio command workspace.new | Out-Null
        Invoke-Aio wait text 'PS ' | Out-Null
        Assert-Equal (Read-State)['workspace.name'] "Workspace $number" 'ordinary creation name'
    }
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    $before = Read-State
    $runtime = $before['session.id']
    Invoke-Aio run 'Write-Output (''WORK131_PID_'' + $PID)' | Out-Null
    Invoke-Aio wait text WORK131_PID_ | Out-Null
    $shell = [regex]::Matches(((Invoke-Aio screen) -join "`n"), 'WORK131_PID_(\d+)')
    Assert-True ($shell.Count -gt 0) 'shell process receipt exists'
    $shellPid = $shell[$shell.Count-1].Groups[1].Value
    $grid = (Read-State)['grid.size']

    # Preparation fails after provisional allocation; it must not consume a visible default name.
    $settings = Join-Path $directory 'settings.ini'
    $originalSettings = [IO.File]::ReadAllText($settings)
    try {
        [IO.File]::WriteAllText($settings, $originalSettings + "`npane.minimum_columns = 10000`n")
        Invoke-Aio command settings.reload | Out-Null
        Begin-Drag
        Invoke-Aio mouse move $DesktopPoint --screen | Out-Null
        Assert-Equal (Read-State)['panes.drop.preview_window'] 0 'failed preparation releases its preview'
        Invoke-Aio key Esc | Out-Null
        Invoke-Aio mouse up $DesktopPoint --screen | Out-Null
        Assert-Equal (Read-State)['workspaces.count'] 4 'failed preparation retains only committed workspaces'
    } finally {
        [IO.File]::WriteAllText($settings, $originalSettings)
        Invoke-Aio command settings.reload | Out-Null
    }

    $lastPreviewWindow = 0
    foreach ($cancel in @('escape', 'focus-loss')) {
        Begin-Drag
        $previewWindow = Preview
        Assert-True ([int]$previewWindow -gt $lastPreviewWindow) 'preview window identity advances'
        $lastPreviewWindow = [int]$previewWindow
        if ($cancel -eq 'escape') {
            Invoke-Aio mouse move '100,100' --px | Out-Null
            Assert-Equal (Read-State)['panes.drop.preview_window'] $previewWindow 'reentry caches the same preview'
            $again = Preview
            Assert-Equal $again $previewWindow 'reentry preserves preview identity'
            Invoke-Aio key Esc | Out-Null
        } else { Invoke-Aio focus out | Out-Null }
        Invoke-Aio mouse up $DesktopPoint --screen | Out-Null
        $s = Read-State
        Assert-Equal $s['windows.count'] 1 'cancel releases provisional window'
        Assert-Equal $s['workspaces.count'] 4 'cancel releases provisional workspace'
        Assert-Equal $s['panes.count'] 2 'cancel preserves both source panes'
        Assert-Equal $s['session.id'] $runtime 'cancel preserves runtime identity'
        Assert-Equal $s['sessions.count'] $before['sessions.count'] 'cancel preserves all sessions'
        Assert-Equal $s['grid.size'] $grid 'cancel restores source grid'
        Invoke-Aio focus in | Out-Null
    }

    Begin-Drag
    $tornWindow = Preview
    Assert-True ([int]$tornWindow -gt $lastPreviewWindow) 'commit preview has a fresh window identity'
    Invoke-Aio mouse up $DesktopPoint --screen | Out-Null
    Select-Window $tornWindow
    # Bring only this own inactive window into capture range; no activation or host cursor input.
    Invoke-Aio window move '160,120' | Out-Null
    $torn = Read-State
    Snapshot 'committed-default'
    Write-Host "RECEIPT committed window=$tornWindow workspace=$($torn['workspace.id']) name=$($torn['workspace.name']) runtime=$runtime shell=$shellPid"
    Assert-Equal $torn['workspace.name'] 'Workspace 5' 'previews do not skip the committed visible default number'
    Assert-Equal $torn['workspace.id'] 8 'canceled and failed previews do not reuse stable workspace IDs'
    Assert-Equal $torn['session.id'] $runtime 'commit preserves runtime identity'
    Invoke-Aio expect text "WORK131_PID_$shellPid" | Out-Null
    Invoke-Aio run 'Write-Output (''WORK131_AFTER_'' + $PID)' | Out-Null
    Invoke-Aio expect text "WORK131_AFTER_$shellPid" | Out-Null
    Assert-Equal $torn['window.preparing'] false 'commit releases provisional state'

    Select-Window $script:source
    Invoke-Aio command workspace.rename | Out-Null
    Invoke-Aio type 'Workspace 6' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Invoke-Aio command workspace.new | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    $seven = Read-State
    Assert-Equal $seven['workspace.name'] 'Workspace 7' 'default creation avoids existing manual default-like name'
    Invoke-Aio command workspace.delete | Out-Null
    Invoke-Aio key Enter | Out-Null
    Invoke-Aio command workspace.new | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
    $eight = Read-State
    Assert-Equal $eight['workspace.name'] 'Workspace 8' 'deletion does not renumber or rewind committed names'
    Assert-True ([int]$eight['workspace.id'] -gt [int]$seven['workspace.id']) 'deletion never reuses stable IDs'
    Snapshot 'after-deletion'
    Select-Window $tornWindow
    Assert-Equal (Read-State)['workspace.name'] 'Workspace 5' 'existing default name stays unchanged'
    Invoke-Aio command workspace.select_4 | Out-Null
    Assert-Equal (Read-State)['workspace.name'] 'Workspace 6' 'manual default-like name stays unchanged'
    Write-Host 'PASS WORK-131 controller-only numbering journey'
} catch {
    if (Test-Path -LiteralPath $directory) {
        & $ctl --name $Name state | Set-Content -LiteralPath "$directory/failure-state.txt"
        & $ctl --name $Name screen | Set-Content -LiteralPath "$directory/failure-screen.txt"
    }
    throw
} finally {
    & $ctl --name $Name stop
    if ($LASTEXITCODE -ne 0) { throw "Could not stop own instance $Name" }
    Write-Host "CLEANUP stopped own instance $Name"
}

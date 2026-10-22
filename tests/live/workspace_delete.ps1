param([switch] $Prepared, [switch] $NativeInput)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'workspace-delete'
$directory = Join-Path $repo "build/verify/$name"
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $out) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Request-Row([string] $WorkspaceName) {
    Invoke-Aio command workspace.change
    Invoke-Aio type $WorkspaceName
    Invoke-Aio key Shift+Delete
    Invoke-Aio expect state confirm.open=true
    Invoke-Aio expect state workspace.picker=false
}
function Shot([string] $Label) {
    if ((Read-State).ContainsKey('session.id')) { Invoke-Aio wait frame | Out-Null }
    $state = Read-State
    $origin = $state['window.origin'] -split ','
    $handle = [DeleteForeground]::Find([uint32]$state['app.pid'], [int]$origin[0], [int]$origin[1])
    & "$repo/tools/win32.ps1" -Name $name -WindowHandle $handle -Shot "$directory/$Label.png" -Frame | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
    & $ctl --name $name state | Set-Content -LiteralPath "$directory/$Label-state.txt"
}
function Shell-Process([string] $Label) {
    Invoke-Aio wait text 'PS ' | Out-Null
    $path = "$directory/pid-$Label.txt"
    $quotedPath = $path.Replace("'", "''")
    Invoke-Aio run "Set-Content -LiteralPath '$quotedPath' -Value `$PID; Write-Output ('WORKSPACE_PID_' + '$Label')" | Out-Null
    Invoke-Aio wait text "WORKSPACE_PID_$Label" | Out-Null
    $p = [Diagnostics.Process]::GetProcessById([int](Get-Content -LiteralPath $path))
    $null = $p.Handle
    $processes.Add($p)
    Write-Host "RECEIPT shell $Label pid=$($p.Id) handle=$($p.Handle)"
    return $p
}
function Assert-Alive($Processes, [string] $Label) {
    foreach ($p in $Processes) {
        if ($p.HasExited) { throw "$Label shell $($p.Id) unexpectedly exited" }
        Write-Output "PASS $Label shell pid=$($p.Id) alive"
    }
}
function Assert-Exited($Processes, [string] $Label) {
    foreach ($p in $Processes) {
        if (-not $p.WaitForExit(3000)) { throw "$Label shell $($p.Id) did not exit" }
        Write-Output "PASS $Label shell pid=$($p.Id) exited"
    }
}
function Confirm-Point([string] $Button) {
    $s = Read-State
    $size = $s['window.size'] -split 'x'
    $scale = [double]$s['window.scale']
    $width = [double]$size[0]; $height = [double]$size[1]
    $panelWidth = [Math]::Min(540*$scale, [Math]::Max(0,$width-32*$scale))
    $x = ($width-$panelWidth)/2+$panelWidth-64*$scale
    if ($Button -eq 'cancel') { $x -= 104*$scale }
    $y = [Math]::Max(24*$scale,$height*0.22)+119*$scale
    return "$([int]$x),$([int]$y)"
}
function Row-Menu-Delete([string] $Query) {
    Invoke-Aio command workspace.change
    Invoke-Aio type $Query
    $r = (Read-State)['workspace.picker.row'] -split ','
    $scale = [double](Read-State)['window.scale']
    $point = "$([int]([double]$r[0]+[double]$r[2]-18*$scale)),$([int]([double]$r[1]+17*$scale))"
    Invoke-Aio mouse move $point --px
    Invoke-Aio mouse click $point --px
    Invoke-Aio key End Enter
    Invoke-Aio expect state confirm.open=true
}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DeleteForeground {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll", SetLastError=true)] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    public static long Find(uint pid, int x, int y) {
        long result = 0;
        bool ambiguous = false;
        bool enumerated = EnumWindows((h, p) => {
            uint owner;
            if (GetWindowThreadProcessId(h, out owner) == 0 || owner != pid || !IsWindowVisible(h)) return true;
            POINT origin = new POINT();
            if (!ClientToScreen(h, ref origin)) throw new System.ComponentModel.Win32Exception();
            if (origin.x == x && origin.y == y) {
                if (result != 0) ambiguous = true;
                result = h.ToInt64();
            }
            return true;
        }, IntPtr.Zero);
        if (!enumerated) throw new System.ComponentModel.Win32Exception();
        if (result == 0 || ambiguous) throw new Exception("cannot uniquely match selected window client origin");
        return result;
    }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
}
"@
function Foreground([string] $Label) {
    $h = [DeleteForeground]::GetForegroundWindow(); [uint32]$owner = 0
    if (-not [DeleteForeground]::GetWindowThreadProcessId($h,[ref]$owner)) { throw 'Cannot read foreground owner' }
    $title = [Text.StringBuilder]::new(512)
    $null = [DeleteForeground]::GetWindowTextW($h,$title,$title.Capacity)
    Write-Host "RECEIPT foreground $Label hwnd=$h pid=$owner title=$title"
    return $h
}
if (-not $Prepared) { Invoke-Aio launch --fresh }
try {
    Invoke-Aio wait text 'PS '
    $initial = Read-State
    $firstWindow = $initial['window.id']
    if ($NativeInput) {
        Invoke-Aio expect state window.focused=true
        $foreground = Foreground 'owner-ready'
    }
    Invoke-Aio command workspace.rename
    Invoke-Aio type 'Disposable tabs and panes'
    Invoke-Aio key Enter
    Invoke-Aio key Esc
    Invoke-Aio expect state workspace.picker=false
    $one = Shell-Process one
    Invoke-Aio command pane.split_right
    $two = Shell-Process two
    Invoke-Aio command tab.new
    $three = Shell-Process three
    Invoke-Aio command settings.open
    $original = Read-State
    $identity = @($original.GetEnumerator() | Where-Object { $_.Key -match '^tab\.\d+\.(id|panes|pane\.\d+\.session)$' } | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
    foreach ($cancel in @('native-escape','keyboard','pointer','outside','mismatch')) {
        if ($cancel -eq 'native-escape' -and $NativeInput) {
            Invoke-Aio command workspace.change
            & "$repo/tools/win32.ps1" -Name $name -Chord '0x10+0x2e' -Activate
            if ($LASTEXITCODE -ne 0) { throw 'Native Shift+Delete failed' }
        } else { Invoke-Aio command workspace.delete }
        Invoke-Aio expect state confirm.open=true
        Invoke-Aio expect state confirm.workspace=1
        Invoke-Aio expect state 'confirm.title=Delete #1 “Disposable tabs and panes”?'
        Invoke-Aio expect state 'confirm.body=Close 3 tabs (4 panes); stop 3 sessions.'
        if ($cancel -eq 'native-escape') { Shot 'multiple-tabs-last-confirm' }
        switch ($cancel) {
            'native-escape' {
                if ($NativeInput) {
                    & "$repo/tools/win32.ps1" -Name $name -Chord '0x1b' -Activate
                    if ($LASTEXITCODE -ne 0) { throw 'Native Escape failed' }
                } else { Invoke-Aio key Esc }
            }
            'keyboard' { Invoke-Aio key Left Space }
            'pointer' { Invoke-Aio mouse click (Confirm-Point cancel) --px }
            'outside' { Invoke-Aio mouse click '2,2' --px }
            'mismatch' {
                Invoke-Aio mouse down (Confirm-Point accept) --px
                Invoke-Aio mouse up (Confirm-Point cancel) --px
                Invoke-Aio expect state confirm.open=true
                Invoke-Aio key Esc
            }
        }
        Invoke-Aio expect state confirm.open=false
        Invoke-Aio expect state workspace.id=1
        Invoke-Aio expect state tabs.count=3
        Invoke-Aio expect state sessions.count=3
        $after = Read-State
        $afterIdentity = @($after.GetEnumerator() | Where-Object { $_.Key -match '^tab\.\d+\.(id|panes|pane\.\d+\.session)$' } | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
        if ($afterIdentity -cne $identity) { throw "Cancellation changed identities: $afterIdentity" }
        Assert-Alive @($one,$two,$three) "cancel-$cancel"
        Write-Output "PASS cancel-$cancel preserves exact tab/pane/session identity $identity"
    }
    Invoke-Aio command workspace.new
    $unrelated = Shell-Process unrelated
    Invoke-Aio run '$global:deleteMarker = "UNRELATED_" + "SURVIVED"'
    Row-Menu-Delete 'Disposable tabs and panes'
    Invoke-Aio expect state confirm.workspace=1
    Shot 'hidden-row-x-confirm'
    Invoke-Aio key Esc
    Invoke-Aio expect state sessions.count=4
    Invoke-Aio command window.new
    $secondWindow = (Read-State)['window.2.id']
    if (-not $secondWindow -or $secondWindow -eq $firstWindow) { throw 'New Window did not create another owner' }
    Invoke-Aio window select $secondWindow
    $foreign = Shell-Process foreign
    Invoke-Aio command workspace.change
    Invoke-Aio window select $firstWindow
    if ($NativeInput) {
        Invoke-Aio expect state window.focused=true
        $beforeForeign = Foreground 'before-foreign-deletion'
        if ($beforeForeign -ne $foreground) { throw 'Requester foreground changed before deletion' }
    }
    Request-Row 'Workspace 3'
    Invoke-Aio expect state confirm.workspace=3
    Shot 'foreign-owner-destination-confirm'
    Invoke-Aio key Enter
    Invoke-Aio expect state workspaces.count=2
    Invoke-Aio expect state sessions.count=4
    Invoke-Aio expect state windows.count=2
    Invoke-Aio expect state workspace.id=2
    Assert-Exited @($foreign) foreign-target
    Assert-Alive @($one,$two,$three,$unrelated) foreign-unrelated
    if ($NativeInput) {
        Invoke-Aio expect state window.focused=true
        if ((Foreground 'after-foreign-deletion') -ne $beforeForeign) { throw 'Deleting foreign owner stole OS foreground' }
        Write-Output 'PASS foreign deletion preserves exact requester foreground HWND'
    }
    Invoke-Aio window select $secondWindow
    Invoke-Aio expect state workspace.id=1
    Invoke-Aio expect state workspace.picker=false
    Invoke-Aio expect state tabs.count=3
    Invoke-Aio window select $firstWindow
    Invoke-Aio run 'Write-Output $global:deleteMarker'
    Invoke-Aio expect text UNRELATED_SURVIVED
    Invoke-Aio command app.command_palette
    Invoke-Aio type 'Delete Workspace'
    Invoke-Aio expect state palette.item=workspace.delete
    Invoke-Aio key Enter
    Invoke-Aio expect state confirm.workspace=2
    Shot 'palette-current-fresh-confirm'
    Invoke-Aio key Enter
    Invoke-Aio expect state workspaces.count=2
    Invoke-Aio expect state sessions.count=4
    Invoke-Aio expect state workspace.id=4
    Invoke-Aio expect state "window.id=$firstWindow"
    Assert-Exited @($unrelated) current-target
    Assert-Alive @($one,$two,$three) current-unrelated
    Invoke-Aio wait text 'PS '
    $replacement = Shell-Process replacement
    Invoke-Aio window select $secondWindow
    Invoke-Aio expect state workspace.id=1
    Invoke-Aio tray hide
    Invoke-Aio expect state windows.count=1
    Invoke-Aio expect state sessions.count=4
    Assert-Alive @($one,$two,$three) ordinary-window-close
    Invoke-Aio window select $firstWindow
    Row-Menu-Delete 'Disposable tabs and panes'
    Invoke-Aio expect state 'confirm.body=Close 3 tabs (4 panes); stop 3 sessions.'
    Shot 'hidden-delete-confirm'
    Invoke-Aio mouse click (Confirm-Point accept) --px
    Invoke-Aio expect state workspaces.count=1
    Invoke-Aio expect state sessions.count=1
    Invoke-Aio expect state workspace.id=4
    Assert-Exited @($one,$two,$three) hidden-target
    Assert-Alive @($replacement) hidden-unrelated
    Invoke-Aio command workspace.change
    Invoke-Aio type 'Disposable tabs and panes'
    Invoke-Aio expect state workspace.picker.count=2
    Invoke-Aio key Esc
    foreach ($dpi in @(96,144)) {
        Invoke-Aio dpi $dpi
        Invoke-Aio command workspace.change
        Invoke-Aio key Right End Enter
        Invoke-Aio expect state confirm.open=true
        Invoke-Aio expect state confirm.workspace=4
        Shot "last-dropdown-confirm-$dpi"
        Invoke-Aio key Tab Enter
        Invoke-Aio expect state confirm.open=false
        Invoke-Aio expect state workspace.id=4
        Invoke-Aio expect state sessions.count=1
        Assert-Alive @($replacement) "last-cancel-$dpi"
    }
    Invoke-Aio dpi 96
    Invoke-Aio command workspace.delete
    Invoke-Aio key Space
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state workspace.id=5
    Invoke-Aio expect state workspaces.count=1
    Invoke-Aio expect state sessions.count=1
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state windows.count=1
    Invoke-Aio expect state "window.id=$firstWindow"
    Assert-Exited @($replacement) last-target
    $final = Shell-Process final
    Shot 'final-fresh-workspace'
    Write-Output 'PASS fresh workspace IDs 1,2,3,4,5 are never reused; final native window identity is stable'
    Write-Output 'PASS hidden, foreign-owner, current and last deletion; control cancellation; X/dropdown/palette/ShiftDelete hooks; PID termination and unrelated survival'
    if ($NativeInput) { Write-Output 'PASS native Shift+Delete and Escape; foreign deletion preserves OS requester foreground' }
} finally {
    Invoke-Aio stop
    foreach ($p in $processes) { $p.Dispose() }
}

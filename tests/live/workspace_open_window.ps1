[CmdletBinding()]
param([string]$Name='work133-open-window',[switch]$Capture)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl=Join-Path $repo 'build/aioctl.exe'
$data=Join-Path $repo "build/verify/$Name"
function Aio {
    $out=& $ctl --name $Name @args
    if($LASTEXITCODE -ne 0){throw "aioctl $($args -join ' '): $out"}
    $out | Write-Output
}
function State {
    $s=@{}
    foreach($line in (Aio state)){$p=$line -split '=',2;$s[$p[0]]=$p[1].Trim('"')}
    return $s
}
function Check([bool]$ok,[string]$label){if(!$ok){throw $label};"PASS $label"}
function Click([string]$key){
    $r=@((State)[$key] -split ',' | ForEach-Object{[double]::Parse($_,[Globalization.CultureInfo]::InvariantCulture)})
    Aio mouse click "$([int]($r[0]+$r[2]/2)),$([int]($r[1]+$r[3]/2))" --px | Out-Null
}
function Open-Row([string]$query,[string]$id){
    Aio command workspace.change | Out-Null
    Aio type $query | Out-Null
    Click 'workspace.picker.menu_button'
    Aio expect state "workspace.picker.menu_target=$id"
    Aio key Home Down Down | Out-Null
    Aio expect state workspace.picker.menu_selected=2
}
function Rename([string]$title){
    Aio command workspace.rename | Out-Null
    Aio type $title | Out-Null
    Aio key Enter Esc | Out-Null
}
function Shell-Pid([string]$label){
    Aio run "Write-Output ('WORK133_${label}_' + `$PID)" | Out-Null
    Aio wait text "WORK133_${label}_" | Out-Null
    $matches=[regex]::Matches(((Aio screen) -join "`n"),"WORK133_${label}_(\d+)")
    if(!$matches.Count){throw "Missing shell PID receipt: $label"}
    return $matches[$matches.Count-1].Groups[1].Value
}
function Shot([string]$label){
    if($Capture){
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        do {
            $s=State
            $notices=@($s.Keys | Where-Object{$_.StartsWith('notice.') -and $s[$_]})
            if(!$notices.Count){break}
            if([DateTime]::UtcNow -ge $deadline){throw "Notice obscures capture: $label"}
            Start-Sleep -Milliseconds 100
        } while($true)
    }
    Start-Sleep -Milliseconds 300
    Aio state | Set-Content "$data/$label-state.txt" -Encoding utf8
    if($Capture){
        $s=State;$origin=$s['window.origin'] -split ','
        $handle=[Workspace133Capture]::Find([uint32]$s['app.pid'],[int]$origin[0],[int]$origin[1])
        & "$repo/tools/win32.ps1" -Name $Name -WindowHandle $handle -Frame -Shot "$data/$label.png" | Out-Null
        if($LASTEXITCODE -ne 0){throw "Capture failed: $label"}
    }
}
if($Capture){Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Workspace133Capture {
 public delegate bool Callback(IntPtr h,IntPtr p);
 [StructLayout(LayoutKind.Sequential)] public struct Point {public int X,Y;}
 [DllImport("user32.dll")] static extern bool EnumWindows(Callback c,IntPtr p);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref Point p);
 [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
 public static long Find(uint pid,int x,int y) {
  IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4)),found=IntPtr.Zero;
  if(old==IntPtr.Zero)throw new Exception("Cannot inspect client origins");
  try {EnumWindows((h,p)=>{uint id;GetWindowThreadProcessId(h,out id);Point o=new Point();
   if(id==pid&&IsWindowVisible(h)&&ClientToScreen(h,ref o)&&o.X==x&&o.Y==y){found=h;return false;}return true;},IntPtr.Zero);
  }finally{SetThreadDpiAwarenessContext(old);}
  if(found==IntPtr.Zero)throw new Exception("No exact owned window");return found.ToInt64();
 }
}
'@}
Aio launch --fresh | Out-Null
try {
    Aio wait text 'PS ' | Out-Null
    Aio window move '20,60' | Out-Null
    Aio resize 100x30 | Out-Null
    $source=State;$requester=$source['window.id'];$sourceSession=$source['session.id']
    $sourcePid=Shell-Pid 'source_before'
    Open-Row 'Workspace 1' '1'
    Aio expect state workspace.picker.window_enabled=false
    Shot 'current-workspace-disabled'
    Click 'workspace.picker.menu_item'
    Aio expect state windows.count=1
    Aio expect state workspace.picker.menu_target=1
    Aio expect state workspace.id=1
    Aio key Esc Esc | Out-Null
    Aio command workspace.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    Rename 'Split target'
    $leftSession=(State)['session.id'];$leftPid=Shell-Pid 'left_before'
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    $split=State;$splitSession=$split['session.id'];$sessions=$split['sessions.count']
    $rightPid=Shell-Pid 'right_before'
    Aio command workspace.select_1 | Out-Null
    Open-Row 'Split target' '2'
    Aio expect state 'workspace.picker.window_title=Open in New Window'
    Aio expect state workspace.picker.window_enabled=true
    Shot 'hidden-workspace-open'
    Aio key Enter | Out-Null
    Aio expect state windows.count=2
    Aio expect state workspace.id=1
    Aio expect state "session.id=$sourceSession"
    Aio expect state "sessions.count=$sessions"
    Aio expect state workspace.picker=false
    $owner=(State)['window.2.id']
    Aio window select $owner | Out-Null
    Aio window move '500,80' | Out-Null
    Aio expect state workspace.id=2
    Aio expect state panes.count=2
    Aio expect state "session.id=$splitSession"
    Check ((Shell-Pid 'right_opened') -eq $rightPid) 'opening workspace preserves right shell PID'
    Aio command pane.focus_left | Out-Null
    Aio expect state "session.id=$leftSession"
    Check ((Shell-Pid 'left_opened') -eq $leftPid) 'opening workspace preserves left shell PID'
    Aio command pane.focus_right | Out-Null
    Shot 'opened-split-workspace'
    Aio window select $requester | Out-Null
    Open-Row 'Split target' '2'
    Aio expect state 'workspace.picker.window_title=Show Existing Window'
    Shot 'foreign-owner-reuse'
    Click 'workspace.picker.menu_item'
    Aio expect state windows.count=2
    Aio expect state workspace.id=1
    Aio expect state "sessions.count=$sessions"
    Aio window select $owner | Out-Null
    Aio expect state workspace.id=2
    Aio expect state "session.id=$splitSession"
    Check ((Shell-Pid 'right_reused') -eq $rightPid) 'reusing owner preserves right shell PID'
    Aio window select $requester | Out-Null
    Aio command workspace.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    Rename 'Settings only'
    Aio command settings.open | Out-Null
    Aio command tab.select_1 | Out-Null
    Aio command tab.close | Out-Null
    Aio expect state tabs.count=1
    Aio expect state settings.active=true
    Aio command workspace.select_1 | Out-Null
    Open-Row 'Settings only' '3'
    Aio key Enter | Out-Null
    Aio expect state windows.count=3
    Aio expect state workspace.id=1
    $settingsOwner=(State)['window.3.id']
    Aio window select $settingsOwner | Out-Null
    Aio expect state workspace.id=3
    Aio expect state tabs.count=1
    Aio expect state settings.active=true
    Shot 'opened-settings-only'
    Aio window select $requester | Out-Null
    Check ((Shell-Pid 'source_after') -eq $sourcePid) 'all workspace-window operations preserve requester shell PID'
    foreach($v in @(@{mode='light';dpi=192},@{mode='dark';dpi=144})){
        $path=Join-Path $data 'settings.ini';$text=[IO.File]::ReadAllText($path)
        $text=[regex]::Replace($text,'(?m)^theme\.name\s*=.*\r?\n?','')
        [IO.File]::WriteAllText($path,$text.TrimEnd()+"`ntheme.name = studio-$($v.mode)`n")
        Aio command settings.reload | Out-Null
        Aio dpi $v.dpi | Out-Null
        Aio resize 40x10 | Out-Null
        Open-Row 'Split target' '2'
        Aio expect state 'workspace.picker.window_title=Show Existing Window'
        Shot "short-$($v.mode)$($v.dpi)"
        Aio key Esc Esc | Out-Null
    }
    Aio expect state windows.count=3
    Aio expect state "session.id=$sourceSession"
    Check ((State)['window.2.id'] -eq $owner) 'existing split-workspace owner remains stable'
    Check ((State)['sessions.count'] -eq $sessions) 'no session restarted or added by workspace-window actions'
} finally { Aio stop }

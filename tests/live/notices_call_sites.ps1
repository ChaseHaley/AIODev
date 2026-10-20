$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl=Join-Path $repo 'build/aioctl.exe'
$name='w116-call-sites'
function A { $out=& $ctl --name $name @args; if($LASTEXITCODE){throw ($out -join "`n")}; $out | Write-Output }
function State { $s=@{}; foreach($line in (& $ctl --name $name state)){ $p=$line -split '=',2; $s[$p[0]]=$p[1].Trim('"') }; return $s }
function Check([bool]$ok,[string]$label){if(!$ok){throw $label}; "PASS $label"}
function Configure([string]$extra){[IO.File]::WriteAllText((Join-Path $repo "build/verify/$name/settings.ini"),"shell.command = pwsh.exe -NoLogo -NoProfile`ncursor.blink = false`n$extra`n"); A command settings.reload}
A launch --fresh
try {
 A wait text 'PS '
 Configure 'pane.minimum_columns = 200'
 A command pane.split_right
 Check ((State)['panes.count'] -eq '1') 'pane limit preserves pane count'
 Check ((State)['notice.transient'] -like 'warning:*') 'pane-limit refusal is Warning'
 Configure "keys.tab.new = Ctrl+[`ninput.leader = Ctrl+B"
 A command settings.open
 A type input.leader
 A key Tab 'Ctrl+[' Enter
 $inline=State
 Check ($inline['settings.error'] -eq 'false') 'bracket leader inline save remains nonfatal'
 Check ($inline['settings.message'].Contains('Ctrl+[') -and $inline['settings.message'].Contains('tab.new') -and $inline['settings.message'].Contains('input.leader wins')) 'bracket leader inline warning preserves action and winner'
 A state | Set-Content (Join-Path $repo 'build/work116-inline-bracket-state.txt')
 A command tab.select_1
 Configure ''
 A run '[Console]::Write("`e[?2004l"); Write-Output ("PASTE_"+"FIXTURE_READY"); $null=[Console]::ReadKey($true); Write-Output ("PASTE_"+"EXECUTED")'
 A wait text PASTE_FIXTURE_READY
 A command edit.select_all
 Start-Sleep -Milliseconds 150
 A command edit.copy
 Check ((State)['notice.copy'] -like 'success:*') 'existing copy confirmation is Success'
 A command edit.paste
 Check ((State)['notice.paste'] -like 'warning:*') 'multiline paste confirmation is Warning'
 A expect no-text PASTE_EXECUTED
 A state | Set-Content (Join-Path $repo 'build/work116-call-sites-state.txt')
 A key X
 A wait text PASTE_EXECUTED
} finally { A stop }
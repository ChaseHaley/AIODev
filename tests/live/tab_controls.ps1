$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl=Join-Path $repo 'build/aioctl.exe'
$name='tab-controls'
$directory=Join-Path $repo "build/verify/$name"
function Aio { $out=& $ctl --name $name @args; if($LASTEXITCODE -ne 0){throw "aioctl: $out"}; $out }
function State {
    $state=@{}
    foreach($line in (Aio state)){ $pair=$line -split '=',2; $state[$pair[0]]=$pair[1].Trim('"') }
    return $state
}
function Equal($actual,$expected,$label){if("$actual" -ne "$expected"){throw "$label : $actual != $expected"}; Write-Output "PASS $label"}
function Click($rect){$r=$rect -split ','; $x=[int]([double]$r[0]+[double]$r[2]/2); $y=[int]([double]$r[1]+[double]$r[3]/2); Aio mouse click "$x,$y" --px | Out-Null}
function Shot($label){Aio mouse move '1100,650' --px | Out-Null; Start-Sleep -Milliseconds 200; Aio state | Set-Content "$directory/$label-state.txt"; & "$repo/tools/win32.ps1" -Name $name -Shot "$directory/$label.png" -Frame | Out-Null}
Aio launch --fresh | Out-Null
try {
    $initial=State
    Equal $initial['tabs.orientation'] horizontal 'horizontal tabs are the default'
    $button=$initial['tabs.orientation_button']
    Click $button
    Equal (State)['tabs.orientation'] vertical 'button changes horizontal to vertical'
    Equal @((State).Values | Where-Object { $_ -match '(Horizontal|Vertical) tabs\.' }).Count 0 'button switches to vertical quietly'
    Click $button
    Equal (State)['tabs.orientation'] horizontal 'button changes vertical to horizontal'
    Equal @((State).Values | Where-Object { $_ -match '(Horizontal|Vertical) tabs\.' }).Count 0 'button switches to horizontal quietly'
    Equal (State)['tabs.orientation_button'] $button 'button is stationary in horizontal mode'
    Click $button
    Equal (State)['tabs.orientation'] vertical 'button changes horizontal to vertical'
    Aio command workspace.new | Out-Null
    Aio command tab.new | Out-Null
    Aio command workspace.new | Out-Null
    Aio command tab.new | Out-Null
    foreach($index in 1,2,3){
        Aio key "Ctrl+Shift+$index" | Out-Null
        $s=State
        Equal $s['workspace.name'] "Workspace $index" "Ctrl+Shift+$index selects workspace index"
        Equal $s['tabs.orientation_button'] $button 'workspace changes preserve button position'
    }
    Aio key Ctrl+Shift+2 | Out-Null
    $s=State
    $selected=0
    for($row=1;$row -le [int]$s['rail.rows'];$row++){
        if($s["rail.row.$row.kind"] -ne 'tab'){continue}
        if($s["rail.row.$row.selected"] -eq 'true'){$selected++}
        if($s["rail.row.$row.workspace"] -ne $s['workspace.id']){
            Equal $s["rail.row.$row.marked"] false 'other workspaces have no highlighted tab'
        }
    }
    Equal $selected 1 'only one tab is selected in the workspace tree'
    Shot vertical-workspaces
    Click $s['workspace.button']
    Equal (State)['workspace.picker'] true 'workspace dropdown remains clickable'
    Aio key Esc | Out-Null
    Aio resize 40x24 | Out-Null
    Equal (State)['tabs.orientation_button'] $button 'button remains fixed in a narrow window'
    Click $button
    Equal (State)['tabs.orientation'] horizontal 'button remains usable in a narrow window'
    Click $button
    Aio resize 120x32 | Out-Null
    Aio command app.command_palette | Out-Null
    foreach($prefix in 't:','w:','s:','c:'){
        Aio key Ctrl+A | Out-Null
        Aio type $prefix | Out-Null
        Equal (State)['palette.chip'] $prefix 'typed prefix selects category'
        Shot ('category-'+$prefix.Substring(0,1))
    }
    Aio key Esc | Out-Null
    $settings=Join-Path $directory settings.ini
    $text=[IO.File]::ReadAllText($settings)
    [IO.File]::WriteAllText($settings,$text+"`ntheme.mode = light`n")
    Aio command settings.reload | Out-Null
    Aio command app.command_palette | Out-Null
    Aio type t: | Out-Null
    Shot category-tabs-light
} finally {Aio stop | Out-Null}

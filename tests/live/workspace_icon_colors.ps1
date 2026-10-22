[CmdletBinding()]
param([string]$Name='work143-icon-colors',[switch]$Capture)
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
    $state=@{}
    foreach($line in (Aio state)){$pair=$line -split '=',2;$state[$pair[0]]=$pair[1].Trim('"')}
    return $state
}
function Click([string]$Key) {
    $r=@((State)[$Key] -split ',' | ForEach-Object{[double]::Parse($_,[Globalization.CultureInfo]::InvariantCulture)})
    Aio mouse click "$([int]($r[0]+$r[2]/2)),$([int]($r[1]+$r[3]/2))" --px
}
function Shot([string]$Label) {
    Aio wait idle | Out-Null
    Start-Sleep -Milliseconds 250
    Aio state | Set-Content -LiteralPath "$data/$Label-state.txt" -Encoding utf8
    if($Capture){
        & "$repo/tools/win32.ps1" -Name $Name -Frame -Shot "$data/$Label.png" | Out-Null
        if($LASTEXITCODE -ne 0){throw "Capture failed: $Label"}
    }
}
function Colors {
    Aio command workspace.change_icon | Out-Null
    Click 'workspace.picker.color_button' | Out-Null
    Aio expect state workspace.picker.colors=true
    Aio expect state workspace.picker.count=10
}
function Target-Colors([string]$Filter,[string]$Target) {
    Aio command workspace.change | Out-Null
    Aio type $Filter | Out-Null
    Click 'workspace.picker.menu_button' | Out-Null
    Aio key Ctrl+N Enter | Out-Null
    Aio expect state "workspace.picker.icon_target=$Target"
    Click 'workspace.picker.color_button' | Out-Null
    Aio expect state workspace.picker.colors=true
}
Aio launch --fresh
try {
    Aio wait text 'PS ' | Out-Null
    Aio resize 100x30 | Out-Null
    $first=State
    $sourceWindow=$first['window.id']
    $sourceSession=$first['session.id']
    Colors
    Aio key Down | Out-Null
    Aio expect state workspace.picker.selected=5
    Aio key Up | Out-Null
    Aio expect state workspace.picker.selected=0
    Aio type ignored | Out-Null
    Aio expect state 'workspace.picker.query='
    Aio key Esc | Out-Null
    Aio expect state workspace.picker.colors=false
    Aio expect state workspace.picker.selected=12
    Aio expect state workspace.icon.tint=0
    Aio key Esc Esc | Out-Null
    Aio command workspace.new | Out-Null
    $targetSession=(State)['session.id']
    Aio expect state workspace.id=2
    Aio command workspace.select_1 | Out-Null
    Target-Colors 'Workspace 2' '2'
    Aio key Home Right Right Right Right Right Right | Out-Null
    Aio expect state workspace.picker.selected=6
    Shot 'hidden-target-blue-chooser'
    Aio key Enter | Out-Null
    Aio expect state workspace.picker.colors=false
    Aio expect state 'workspace.picker.query=Workspace 2'
    Aio expect state workspace.id=1
    Aio expect state workspace.icon.tint=0
    Aio expect state "session.id=$sourceSession"
    Shot 'hidden-target-blue-row'
    Aio key Enter | Out-Null
    Aio expect state workspace.id=2
    Aio expect state workspace.icon.tint=6
    Aio expect state "session.id=$targetSession"
    Aio command workspace.change_icon | Out-Null
    Aio key Home Right Right Right Enter Esc | Out-Null
    Aio expect state workspace.icon.preset=3
    Aio expect state workspace.icon.tint=6
    Shot 'blue-header'
    Aio command workspace.change_icon | Out-Null
    $emoji=[char]::ConvertFromUtf32(0x1F308)
    Aio type $emoji | Out-Null
    Aio key Tab Enter Esc | Out-Null
    Aio expect state "workspace.icon.emoji=$emoji"
    Aio expect state workspace.icon.tint=6
    Shot 'emoji-blue'
    Colors
    Aio key Home Right Enter Esc | Out-Null
    Aio expect state workspace.icon.tint=1
    Aio expect state "workspace.icon.emoji=$emoji"
    Shot 'emoji-red'
    if($Capture){
        Add-Type -AssemblyName System.Drawing
        $before=[Drawing.Bitmap]::new("$data/emoji-blue.png")
        $after=[Drawing.Bitmap]::new("$data/emoji-red.png")
        try{
            for($y=8;$y -lt 32;$y++){for($x=10;$x -lt 34;$x++){
                if($before.GetPixel($x,$y).ToArgb() -ne $after.GetPixel($x,$y).ToArgb()){
                    throw 'Tint changed emoji pixels.'
                }
            }}
            Write-Output 'PASS emoji pixels unchanged across tint choices'
        }finally{$before.Dispose();$after.Dispose()}
    }
    Aio command workspace.change_icon | Out-Null
    Aio key Home Right Right Right Enter Esc | Out-Null
    foreach($mode in @('dark','light')){
        $path=Join-Path $data 'settings.ini'
        $text=[IO.File]::ReadAllText($path)
        $text=[regex]::Replace($text,'(?m)^theme.mode\s*=.*\r?\n?','')
        [IO.File]::WriteAllText($path,$text.TrimEnd()+"`ntheme.mode = $mode`n")
        Aio command settings.reload | Out-Null
        Start-Sleep -Seconds 3
        foreach($dpi in @(96,144,192)){
            Aio dpi $dpi | Out-Null
            Aio resize 55x18 | Out-Null
            Colors
            Shot "$mode-$dpi-choices"
            Aio key End | Out-Null
            Aio expect state workspace.picker.selected=8
            Aio resize 40x10 | Out-Null
            Shot "$mode-$dpi-short-last"
            Click 'workspace.picker.row' | Out-Null
            Aio expect state workspace.icon.tint=8
            Aio key Esc | Out-Null
        }
    }
    Aio dpi 96 | Out-Null
    Aio resize 100x30 | Out-Null
    Colors
    Aio key Home Enter Esc | Out-Null
    Aio expect state workspace.icon.tint=0
    Shot 'theme-default-reset'
    Aio command window.new | Out-Null
    $owner=(State)['window.2.id']
    Aio window select $owner | Out-Null
    $foreignSession=(State)['session.id']
    Aio expect state workspace.id=3
    Aio window select $sourceWindow | Out-Null
    Target-Colors 'Workspace 3' '3'
    Aio key Home Right Enter Esc | Out-Null
    Aio expect state workspace.id=2
    Aio expect state workspace.icon.tint=0
    Aio expect state "session.id=$targetSession"
    Aio window select $owner | Out-Null
    Aio expect state workspace.icon.tint=1
    Aio expect state "session.id=$foreignSession"
    Aio expect state windows.count=2
    Write-Output 'PASS targeted colors/reset, glyph and emoji persistence, keyboard/pointer, themes/DPI, hidden and foreign owners'
}finally{Aio stop}

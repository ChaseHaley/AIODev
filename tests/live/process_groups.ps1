[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl=Join-Path $repo 'build/aioctl.exe'
$name='process-groups-editor'
$data=Join-Path $repo "build/verify/$name"
$path=Join-Path $data 'settings.ini'
$source=Join-Path $repo 'build/work146-source.ini'
function Aio {
    $result=& $ctl --name $name @args
    if($LASTEXITCODE -ne 0){throw "aioctl $($args -join ' '): $result"}
    return $result
}
function State {
    $state=@{}
    foreach($line in (Aio state)){$pair=$line -split '=',2;$state[$pair[0]]=$pair[1].Trim('"')}
    return $state
}
function Expect($actual,$expected,$label){
    if("$actual" -ne "$expected"){throw "$label expected $expected, got $actual"}
    Write-Output "PASS $label"
}
function Row($key){
    foreach($part in (State)['settings.process.rows'] -split ';'){
        $pair=$part -split '@',2
        if($pair[0] -ne $key){continue}
        $r=$pair[1] -split ','
        return [pscustomobject]@{x=[double]$r[0];y=[double]$r[1];w=[double]$r[2];h=[double]$r[3]}
    }
    throw "Missing process row $key"
}
function Click-Header($id){$r=Row "process.group.$id";Aio mouse click "$($r.x+65),$($r.y+$r.h/2)" --px|Out-Null}
function Field($key,$text){
    $r=Row $key;$scale=[double](State)['window.scale']
    $left=[math]::Min(120*$scale,$r.w*.38)
    Aio mouse click "$($r.x+$left+15),$($r.y+$r.h/2)" --px|Out-Null
    Aio key Ctrl+A|Out-Null;Aio type $text|Out-Null;Aio key Enter|Out-Null
}
function Add($key){$r=Row $key;Aio mouse click "$($r.x+70),$($r.y+$r.h/2)" --px|Out-Null}
function Trash($id){$r=Row "process.group.$id";$scale=[double](State)['window.scale'];Aio mouse click "$($r.x+$r.w-18*$scale),$($r.y+$r.h/2)" --px|Out-Null}
function Shot($label){& "$repo/tools/win32.ps1" -Name $name -Shot "$data/$label.png" -Frame|Out-Null;if($LASTEXITCODE -ne 0){throw 'Screenshot failed'}}
@'
shell.command = pwsh.exe -NoLogo -NoProfile
window.padding = 12
process.padding_groups = Editors:0:nvim,vim;Tools:8:less
'@|Set-Content -LiteralPath $source -Encoding utf8
Aio launch --fresh --settings $source|Out-Null
try{
    Aio dpi 96|Out-Null;Aio resize 150x48|Out-Null
    Aio command settings.open|Out-Null;Aio type process|Out-Null
    Expect (State)['settings.key'] 'process.group.1' 'process header replaces raw setting'
    Click-Header 1
    Expect (State)['settings.process.expanded'] 1 'group expands'
    Field 'process.group.1.padding' '4'
    Expect (State)['settings.process.value'] 'Editors:4:nvim,vim;Tools:8:less' 'padding saves existing grammar'
    Add 'process.group.1.add'
    Expect (State)['settings.key'] 'process.group.1.program.new1' 'Add program focuses its row'
    Aio type helix|Out-Null;Aio key Enter|Out-Null
    Expect (State)['settings.process.value'] 'Editors:4:nvim,vim,helix;Tools:8:less' 'program add persists'
    $before=[IO.File]::ReadAllText($path)
    Field 'process.group.1.program.new1' 'VIM.exe'
    Expect (State)['settings.error'] true 'duplicate program rejected'
    Expect ([IO.File]::ReadAllText($path)) $before 'invalid draft leaves file unchanged'
    Field 'process.group.1.program.new1' 'micro'
    $r=Row 'process.group.1.program.1';Aio mouse click "$($r.x+$r.w-19),$($r.y+$r.h/2)" --px|Out-Null
    Expect (State)['settings.process.value'] 'Editors:4:vim,micro;Tools:8:less' 'program remove persists'
    Shot expanded-dark
    Click-Header 1
    $first=Row 'process.group.1';$second=Row 'process.group.2'
    Aio mouse down "$($first.x+18),$($first.y+$first.h/2)" --px|Out-Null
    Expect (State)['settings.process.dragging'] true 'six-dot handle starts order drag'
    Aio mouse move "$($second.x+60),$($second.y+$second.h-3)" --px|Out-Null
    Aio mouse move '5,100' --px|Out-Null;Aio mouse up '5,100' --px|Out-Null
    Expect (State)['settings.process.value'] 'Editors:4:vim,micro;Tools:8:less' 'outside drop cancels order change'
    Aio mouse down "$($first.x+18),$($first.y+$first.h/2)" --px|Out-Null
    Aio mouse move "$($second.x+60),$($second.y+$second.h-3)" --px|Out-Null
    Shot reorder-drag
    Aio mouse up "$($second.x+60),$($second.y+$second.h-3)" --px|Out-Null
    Expect (State)['settings.process.value'] 'Tools:8:less;Editors:4:vim,micro' 'drop saves first-match order'
    Trash 2
    Expect (State)['settings.process.confirming'] true 'trash asks before deleting'
    Expect (State)['settings.process.confirm_option'] false 'confirmation has no disable option'
    Shot delete-prompt
    Aio key Esc|Out-Null
    Expect (State)['settings.process.value'] 'Tools:8:less;Editors:4:vim,micro' 'cancel preserves groups'
    Trash 2;Aio key Tab Enter|Out-Null
    Expect (State)['settings.process.value'] 'Editors:4:vim,micro' 'confirmation deletes group'
    Click-Header 1
    Aio dpi 144|Out-Null;Shot expanded-144
    Aio dpi 96|Out-Null;Aio command tab.select_1|Out-Null
    Aio resize 65x35|Out-Null;Aio command settings.open|Out-Null;Shot expanded-narrow
    [IO.File]::AppendAllText($path,"`ntheme.name = studio-light`n")
    Aio command settings.reload|Out-Null
    Shot expanded-light
    $persisted=Join-Path $data 'persisted.ini'
    Copy-Item -LiteralPath $path -Destination $persisted
    Aio stop|Out-Null;Aio launch --settings $persisted|Out-Null
    Expect (State)['settings.process.value'] 'Editors:4:vim,micro' 'rules survive restart'
}finally{& $ctl --name $name stop|Out-Null}

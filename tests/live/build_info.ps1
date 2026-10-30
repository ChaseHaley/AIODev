[CmdletBinding()]
param([string]$Name='work041-build-info',[string]$ExpectedBuild,[switch]$Capture)
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
function Check([bool]$Condition,[string]$Label){if(!$Condition){throw $Label};"PASS $Label"}
function Show-Info {
    Aio command app.command_palette | Out-Null
    Aio type 'Show Build Info' | Out-Null
    Aio expect state palette.items=1
    Aio expect state palette.item=app.build_info
    Aio key Enter | Out-Null
    Aio expect state palette.open=false
    $s=State
    $expected='info: AIODev | Revision: '+$ExpectedBuild+' | Build: verify ('
    Check ($s['notice.build_info'].StartsWith($expected)) 'notice contains exact embedded revision and build kind'
    Check ($s['app.build_kind'] -eq 'verify') 'running executable identifies verification mode'
    Check ($s['app.build'] -eq $ExpectedBuild) 'notice agrees with running executable identity'
}
function Shot([string]$Label){
    # Controller frame/idle waits require a focused terminal; Settings has none.
    Start-Sleep -Milliseconds 300
    Aio state | Set-Content -LiteralPath "$data/$Label-state.txt" -Encoding utf8
    if($Capture){
        & "$repo/tools/win32.ps1" -Name $Name -Frame -Shot "$data/$Label.png" | Out-Null
        if($LASTEXITCODE -ne 0){throw "Capture failed: $Label"}
    }
}
if(!$ExpectedBuild){throw 'Pass the exact revision embedded by build.ps1 verify.'}
Aio launch --fresh | Out-Null
try {
    Aio wait text 'PS ' | Out-Null
    Aio resize 90x26 | Out-Null
    $initial=State
    Show-Info
    Check ((State)['session.id'] -eq $initial['session.id']) 'build info preserves terminal session'
    Shot 'terminal-dark96'
    Aio command app.build_info | Out-Null
    Check (@((State).Keys | Where-Object{$_ -eq 'notice.build_info'}).Count -eq 1) 'repeated dispatch has one build-info state entry'
    Aio command settings.open | Out-Null
    Aio expect state settings.active=true
    Show-Info
    Aio expect state settings.active=true
    Shot 'settings-dark96'
    Aio command tab.select_1 | Out-Null
    foreach($variant in @(@{mode='light';dpi=192},@{mode='dark';dpi=144})){
        $settings=Join-Path $data 'settings.ini'
        $text=[IO.File]::ReadAllText($settings)
        $text=[regex]::Replace($text,'(?m)^theme\.name\s*=.*\r?\n?','')
        [IO.File]::WriteAllText($settings,$text.TrimEnd()+"`ntheme.name = studio-$($variant.mode)`n")
        Aio command settings.reload | Out-Null
        Aio dpi $variant.dpi | Out-Null
        Aio resize 60x18 | Out-Null
        Show-Info
        Shot "terminal-$($variant.mode)$($variant.dpi)"
    }
    Check ((State)['session.id'] -eq $initial['session.id']) 'all palette/theme journeys preserve original session'
} finally { Aio stop }

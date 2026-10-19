[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'notice-severity'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $out) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Assert-True([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw $Label }
    Write-Output "PASS $Label"
}
function Configure([string] $Extra = '', [string] $Mode = 'dark', [string] $Family = 'Cascadia Mono') {
    $source = "shell.command = pwsh.exe -NoLogo -NoProfile`nfont.family = $Family`n" +
        "cursor.blink = false`ntheme.mode = $Mode`n$Extra`n"
    [IO.File]::WriteAllText($path, $source)
    Invoke-Aio command settings.reload
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame -Shot (Join-Path $directory "$Label.png")
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio wait text 'PS '
    Configure 'input.leader = Ctrl+Shift+A'
    $first = Read-State
    Assert-True ($first['notice.settings'] -like 'warning: *only one is active*Review Leader Key*') 'leader overlap is an actionable warning'
    Assert-True ($first['notice.settings'] -notlike '*settings.ini:*') 'toast omits technical source locations'
    $log = [IO.File]::ReadAllText($first['app.log'])
    Assert-True ($log -like '*input.leader*Select All*edit.select_all*input.leader wins*defaults*') 'full source-order conflict details remain in the log'
    Assert-True ($first['leader.enabled'] -eq 'true') 'accepted leader winner remains enabled'
    Start-Sleep -Milliseconds 1200
    Configure "`ninput.leader = Ctrl+Shift+A"
    $second = Read-State
    $remainingFirst = [int]([regex]::Match($first['notice.settings'], '\((\d+)ms\)$').Groups[1].Value)
    $remainingSecond = [int]([regex]::Match($second['notice.settings'], '\((\d+)ms\)$').Groups[1].Value)
    Assert-True ($remainingSecond -lt $remainingFirst - 800) 'unchanged conflict with moved line does not renew expiry'
    Start-Sleep -Milliseconds ($remainingSecond + 400)
    Configure "`ninput.leader = Ctrl+Shift+A"
    Assert-True (-not (Read-State).ContainsKey('notice.settings')) 'expired unchanged warning stays quiet on reload'
    Configure "keys.tab.new = Ctrl+B`ninput.leader = Ctrl+B"
    Assert-True ((Read-State)['notice.settings'] -like 'warning:*') 'a new actionable conflict is shown'
    Configure 'font.size = not-a-number'
    Assert-True ((Read-State)['notice.settings'] -like 'error: *could not be applied*log*') 'invalid setting is an error with recovery guidance'
    Configure
    Assert-True (-not (Read-State).ContainsKey('notice.settings')) 'clean reload clears settings problems'
    Configure 'font.size = not-a-number'
    Assert-True ((Read-State)['notice.settings'] -like 'error:*') 'a resolved problem is shown when reintroduced'
    foreach ($mode in 'dark','light') {
        Configure '' $mode
        Configure "keys.tab.new = Ctrl+B`ninput.leader = Ctrl+B" $mode 'AIODev Missing Notice Test Font'
        Invoke-Aio command pane.keep_open
        Invoke-Aio command edit.select_all
        Invoke-Aio command edit.copy
        $state = Read-State
        Assert-True ($state['notice.settings'] -like 'warning:*') "$mode warning classification"
        Assert-True ($state['notice.font'] -like 'error:*') "$mode error classification"
        Assert-True ($state['notice.transient'] -like 'info:*') "$mode info classification"
        Assert-True ($state['notice.copy'] -like 'success:*') "$mode success classification"
        Shot "all-four-$mode"
    }
    Configure
    Start-Sleep -Milliseconds 12500
    $settled = Read-State
    Start-Sleep -Milliseconds 500
    Assert-True ((Read-State)['frames.presented'] -eq $settled['frames.presented']) 'expired notices do not add idle redraws'
} finally {
    & $ctl --name $name quit | Out-Null
}

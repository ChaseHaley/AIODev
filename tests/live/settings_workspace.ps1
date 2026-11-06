param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'settings-workspace'
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
}
function Read-State {
    $out = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $out) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Assert-Scroll($Expected, $Label) {
    $actual = (Read-State)['settings.scroll']
    if ("$actual" -ne "$Expected") { throw "$Label expected $Expected, observed $actual" }
    Write-Output "PASS $Label ($actual)"
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio command settings.open
    Invoke-Aio key Alt+Down Alt+Down
    $one = (Read-State)['settings.scroll']
    if ([int]$one -le 1) { throw 'First Settings page did not scroll.' }
    Invoke-Aio command workspace.new
    Invoke-Aio key Enter | Out-Null
    Invoke-Aio command workspace.select_1
    Assert-Scroll $one 'Settings scroll survives a workspace without Settings'
    $settingsWorkspace = (Read-State)['workspace.id']
    $tabs = (Read-State)['tabs.count']
    foreach ($round in 1..3) {
        Invoke-Aio command workspace.select_2
        Invoke-Aio command workspace.select_1
        Assert-Scroll $one "the page retains its offset, round $round"
    }
    # Opening Settings elsewhere goes to the one tab, at its reading position.
    Invoke-Aio command workspace.select_2
    Invoke-Aio command settings.open
    $s = Read-State
    if ($s['workspace.id'] -ne $settingsWorkspace) { throw 'Settings opened in a second workspace.' }
    if ($s['tabs.count'] -ne $tabs) { throw 'Opening Settings again added a tab.' }
    Assert-Scroll $one 'opening Settings again returns to the tab at its offset'
    Write-Output 'PASS opening Settings again focuses the existing tab'
    Invoke-Aio command tab.close
    Invoke-Aio command workspace.select_2
    Invoke-Aio command workspace.select_1
    Invoke-Aio command settings.open
    if ([int](Read-State)['settings.scroll'] -gt 1) { throw 'Reopened Settings retained a closed page offset.' }
    Write-Output 'PASS closing Settings discards its saved offset'
} finally { & $ctl --name $name stop | Out-Null }

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'status-notifications'
$data = Join-Path $repo "build/verify/$name"
function Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    return $result
}
function State {
    $result = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        $result[$pair[0]] = $pair[1].Trim('"')
    }
    return $result
}
function Expect($actual, $expected, $label) {
    if ("$actual" -ne "$expected") { throw "$label expected $expected, observed $actual" }
    Write-Output "PASS $label"
}
function Report($state, $id, $message) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message))
    $command = "[Console]::Write([char]27 + ']7501;state={0}:id={1}:app=AIODevTest:msg={2}' + [char]7); Start-Sleep -Seconds 2"
    Aio run ($command -f $state, $id, $encoded) | Out-Null
}
Aio launch --fresh --shell 'pwsh.exe -NoLogo -NoProfile' | Out-Null
try {
    Aio wait text 'PS ' --timeout 10000 | Out-Null
    Add-Content -LiteralPath "$data/settings.ini" -Value @'

status.notify_focused = true
status.sound_blocked = false
status.banner_error = false
status.sound_error = false
status.notice_error = true
'@
    Aio command settings.reload | Out-Null
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $history = [Windows.UI.Notifications.ToastNotificationManager]::History
    $message = "Native banner <&> $([DateTime]::UtcNow.Ticks)"
    Report blocked native-banner $message
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $xml = @($history.GetHistory('AIODev.ProgramStatus') | ForEach-Object { $_.Content.GetXml() })
        $toast = @($xml | Where-Object { $_ -like "*AIODevTest: Needs you*" -and $_ -like "*$($message.Split(' ')[-1])*" })
        if ($toast.Count -gt 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Expect $toast.Count 1 'native toast delivered to Windows notification history'
    Expect ($toast[0] -match 'silent="true"') True 'sound can be disabled independently'
    Expect ($toast[0] -match '&lt;&amp;&gt;') True 'program text is escaped as XML text'

    Aio key 'Ctrl+,' | Out-Null
    Aio type status.banner_blocked | Out-Null
    Expect (State)['settings.key'] status.banner_blocked 'banner setting is searchable'
    Aio key Enter | Out-Null
    Expect (State)['settings.value'] false 'banner toggle saves independently'
    Expect ([IO.File]::ReadAllText("$data/settings.ini") -match 'status.banner_blocked\s*=\s*false') True 'banner choice persists'
    Aio capture --out "$data/banner-setting.png" | Out-Null
    Aio key Esc | Out-Null
    Aio command settings.open | Out-Null
    Aio command tab.close | Out-Null

    Start-Sleep -Seconds 6
    $before = @($history.GetHistory('AIODev.ProgramStatus')).Count
    Report error in-app-only 'Independent in-app error'
    Expect ((State)['notice.transient'] -like '*Independent in-app error*') True 'in-app channel works without Windows banner'
    Expect @($history.GetHistory('AIODev.ProgramStatus')).Count $before 'disabled banner creates no Windows notification'
    $stream = [IO.File]::Open("$data/logs/aiodev.$name.log", [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $reader = [IO.StreamReader]::new($stream)
    try { $log = $reader.ReadToEnd() } finally { $reader.Dispose() }
    Expect ($log -match 'Windows notification .*failed') False 'native API reported no delivery errors'
} finally {
    Aio stop | Out-Null
}

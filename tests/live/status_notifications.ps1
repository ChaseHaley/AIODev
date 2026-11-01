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
status.notify_blocked = banner
status.notify_error = notice
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
    $identity = Get-ItemProperty 'HKCU:/Software/Classes/AppUserModelId/AIODev.ProgramStatus'
    Expect ([IO.Path]::GetExtension($identity.IconUri)) '.png' 'notification identity uses a PNG icon'
    Expect (Test-Path -LiteralPath $identity.IconUri) True 'notification icon exists'
    Expect ((Get-FileHash -LiteralPath $identity.IconUri).Hash) `
        ((Get-FileHash -LiteralPath "$repo/assets/aiodev-notification.png").Hash) 'notification uses the AIODev icon'
    Expect ($toast[0] -match 'silent="true"') True 'sound can be disabled independently'
    Expect ($toast[0] -match '&lt;&amp;&gt;') True 'program text is escaped as XML text'

    Aio key 'Ctrl+,' | Out-Null
    Aio type status.notify_blocked | Out-Null
    Expect (State)['settings.key'] status.notify_blocked 'blocked channels are searchable'
    Aio key Enter | Out-Null
    Aio key Enter | Out-Null
    Expect (State)['settings.value'] none 'banner option saves from the multiselect'
    Expect ([IO.File]::ReadAllText("$data/settings.ini") -match 'status.notify_blocked\s*=\s*none') True 'banner choice persists'
    Aio capture --out "$data/banner-setting.png" | Out-Null
    Aio key Esc | Out-Null
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

    Aio stop | Out-Null
    $icon_time = (Get-Item -LiteralPath $identity.IconUri).LastWriteTimeUtc
    $icon_reader = [IO.File]::Open($identity.IconUri, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Aio launch --fresh --shell 'pwsh.exe -NoLogo -NoProfile' | Out-Null
        Aio wait text 'PS ' --timeout 10000 | Out-Null
        Add-Content -LiteralPath "$data/settings.ini" -Value "`nstatus.notify_focused = true`nstatus.notify_blocked = banner"
        Aio command settings.reload | Out-Null
        $message = "Shared icon $([DateTime]::UtcNow.Ticks)"
        Report blocked shared-icon $message
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $shared = @($history.GetHistory('AIODev.ProgramStatus') | Where-Object { $_.Content.GetXml().Contains($message) })
            if ($shared.Count -gt 0) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        Expect $shared.Count 1 'notification works while Windows is reading the icon'
        Expect (Get-Item -LiteralPath $identity.IconUri).LastWriteTimeUtc $icon_time 'matching icon is reused without rewriting'
    } finally {
        $icon_reader.Dispose()
    }
} finally {
    Aio stop | Out-Null
}

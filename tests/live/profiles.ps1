[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'profile-table'
$data = Join-Path $repo "build/verify/$name"
$path = Join-Path $data 'settings.ini'
$source = Join-Path $repo 'build/work196-profile-source.ini'

function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}

function Read-State {
    $result = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read state.' }
    $state = @{}
    foreach ($line in $result) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

function Assert-Contains([string] $Actual, [string] $Expected, [string] $Label) {
    if (-not $Actual.Contains($Expected)) { throw "$Label expected to contain $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}

function Rows([string] $text) {
    foreach ($part in $text -split ';') {
        if ($part -eq '') { continue }
        $at = $part.IndexOf('@')
        if ($at -lt 1) { continue }
        $fields = $part.Substring($at + 1) -split ','
        [pscustomobject]@{
            id = $part.Substring(0, $at)
            x = [double] $fields[0]
            y = [double] $fields[1]
            w = [double] $fields[2]
            h = [double] $fields[3]
        }
    }
}

function Row([string] $text, [string] $id) {
    return Rows $text | Where-Object { $_.id -eq $id } | Select-Object -First 1
}

function Rect([string] $text) {
    $at = $text.IndexOf('@')
    if ($at -lt 0) { return $null }
    $fields = $text.Substring($at + 1) -split ','
    return [pscustomobject]@{
        x = [double] $fields[0]
        y = [double] $fields[1]
        w = [double] $fields[2]
        h = [double] $fields[3]
    }
}

function Click-Row([string] $text, [string] $id) {
    $row = Row $text $id
    if ($null -eq $row) { throw "No profile row $id." }
    Invoke-Aio mouse click "$($row.x + 120),$($row.y + $row.h / 2)" --px | Out-Null
}

function File-Text { return [IO.File]::ReadAllText($path) }

function Jump-Profiles {
    $state = Read-State
    $rect = $state['settings.outline_rect'] -split ','
    $scale = [double] $state['window.dpi'] / 96
    $group = [int] $state['settings.profile.group']
    $x = [double] $rect[0] + 100 * $scale
    $y = [double] $rect[1] + ($group * 30 + 15) * $scale
    Invoke-Aio mouse click "$x,$y" --px | Out-Null
    $state = Read-State
    if ($null -eq (Row $state['settings.profile.rows'] 'alpha')) { throw 'Profiles group is not visible.' }
}

function Assert-FileLine([string] $line, [string] $Label) {
    if ((File-Text) -notmatch ('(?m)^' + [regex]::Escape($line) + '\r?$')) {
        throw "$Label missing line $line"
    }
    Write-Output "PASS $Label"
}

@'
profile.alpha.name = Alpha
profile.alpha.command = pwsh.exe -NoLogo -NoProfile
profile.alpha.directory = ~
profile.beta.name = Beta
profile.beta.command = pwsh.exe -NoLogo -NoProfile
profile.beta.directory = ~
profile.gamma.name = Gamma
profile.gamma.command = pwsh.exe -NoLogo -NoProfile
profile.gamma.directory = ~
profile.order = alpha, beta, gamma
shell.default_profile = default
shell.command = pwsh.exe -NoLogo -NoProfile
'@ | Set-Content -LiteralPath $source -Encoding utf8

Invoke-Aio launch --fresh --settings $source
try {
    Invoke-Aio key 'Ctrl+,' | Out-Null
    Invoke-Aio type profile | Out-Null
    $state = Read-State
    Assert-Value $state['settings.open'] 'true' 'Settings opens'
    $profileRows = $state['settings.profile.rows']
    foreach ($id in @('alpha', 'beta', 'gamma')) {
        if ($null -eq (Row $profileRows $id)) { throw "Missing table row $id" }
    }
    Write-Output 'PASS table lists the three profiles'

    Click-Row $profileRows 'alpha'
    $state = Read-State
    Assert-Value $state['settings.profile.expanded'] 'alpha' 'row click expands Alpha inline'
    if ((Row $state['settings.profile.rows'] 'alpha') -eq $null) { throw 'Alpha row vanished.' }

    # Duplicate name: the row keeps the typed value and reports inline; the file is unchanged.
    $before = File-Text
    Invoke-Aio key Down Enter Ctrl+A | Out-Null
    Invoke-Aio type Beta | Out-Null
    Invoke-Aio key Enter | Out-Null
    $state = Read-State
    Assert-Value $state['settings.profile.error_key'] 'profile.alpha.name' 'duplicate name marks the field'
    Assert-Contains $state['settings.profile.error'] 'Another profile uses this name' 'duplicate name reads inline'
    Assert-Value $state['settings.error'] 'true' 'duplicate name is a validation error'
    Assert-Value (File-Text) $before 'duplicate name preserves the file'
    for ($attempt = 0; $attempt -lt 4; $attempt += 1) {
        $state = Read-State
        if ($state['settings.profile.expanded'] -eq '' -and $state['settings.filter'] -eq '') { break }
        Invoke-Aio key Esc | Out-Null
    }
    $state = Read-State
    Assert-Value $state['settings.profile.expanded'] '' 'Escape collapses the row'
    Assert-Value $state['settings.filter'] '' 'Escape clears the table search'

    # Default radio: D is the keyboard path to the same action as the row radio.
    Jump-Profiles
    $state = Read-State
    Click-Row $state['settings.profile.rows'] 'beta'
    Invoke-Aio key Tab Enter | Out-Null
    Assert-FileLine 'shell.default_profile = "beta"' 'default radio writes shell.default_profile'
    $state = Read-State
    Assert-Value $state['settings.profile.default'] 'beta' 'one profile reads as default'

    # Hidden toggle: Space on the hidden control writes profile.ID.hidden.
    Invoke-Aio key Esc | Out-Null
    Jump-Profiles
    $state = Read-State
    Click-Row $state['settings.profile.rows'] 'gamma'
    Invoke-Aio key Tab Right Space | Out-Null
    Assert-FileLine 'profile.gamma.hidden = true' 'hidden toggle writes profile.ID.hidden'

    # Drag the order handle: the row follows the pointer and the drop rewrites profile.order.
    Invoke-Aio key Esc | Out-Null
    Jump-Profiles
    $state = Read-State
    $rows = $state['settings.profile.rows']
    $alpha = Row $rows 'alpha'
    $gamma = Row $rows 'gamma'
    Invoke-Aio mouse down "$($alpha.x + 20),$($alpha.y + $alpha.h / 2)" --px | Out-Null
    Assert-Value (Read-State)['settings.profile.dragging'] 'true' 'order drag starts on the handle'
    Invoke-Aio mouse move "$($gamma.x + 40),$($gamma.y + $gamma.h - 4)" --px | Out-Null
    if ([int](Read-State)['settings.profile.drag_target'] -lt 1) { throw 'No drop indicator target.' }
    Write-Output 'PASS order drag paints a drop target'
    Invoke-Aio mouse up "$($gamma.x + 40),$($gamma.y + $gamma.h - 4)" --px | Out-Null
    Assert-FileLine 'profile.order = beta, gamma, alpha, default' 'order drag rewrites profile.order'

    # Detected section: open it, then Enable the first shell detection found on this PC.
    Jump-Profiles
    $state = Read-State
    $header = Rect $state['settings.profile.detected_header']
    if ($null -eq $header) { throw 'No detected section on this PC.' }
    Invoke-Aio mouse click "$($header.x + 120),$($header.y + $header.h / 2)" --px | Out-Null
    Assert-Value (Read-State)['settings.profile.detected_open'] 'true' 'detected section opens'
    $state = Read-State
    $detected = @(Rows $state['settings.profile.detected_rows'])
    if ($detected.Count -eq 0) { throw 'No detected shell to enable on this PC.' }
    $beforeCount = [int] $state['settings.profile.app_detected']
    $target = $detected[0].id
    Click-Row $state['settings.profile.detected_rows'] $target
    Invoke-Aio key Enter | Out-Null
    Assert-FileLine "profile.$target.hidden = false" 'Enable writes explicit overrides'
    $state = Read-State
    Assert-Value $state['settings.profile.expanded'] $target 'enabled profile opens in the main table'
    if ([int] $state['settings.profile.app_detected'] -ne $beforeCount - 1) {
        throw 'Enabled detected profile stayed in the detected section.'
    }
    Write-Output 'PASS enabling removes the detected row'

    # Remove through the row confirmation.
    Invoke-Aio key Esc | Out-Null
    Jump-Profiles
    $state = Read-State
    $beforeCount = [int] $state['settings.profile.app_count']
    Click-Row $state['settings.profile.rows'] 'gamma'
    Invoke-Aio key Tab Delete | Out-Null
    Assert-Value (Read-State)['settings.profile.removing'] 'gamma' 'Delete asks inside the row'
    Invoke-Aio key Enter | Out-Null
    $state = Read-State
    Assert-Value $state['settings.profile.removing'] '' 'confirmation removes the row'
    if ([int] $state['settings.profile.app_count'] -ne $beforeCount - 1) {
        throw 'Profile count did not fall after removal.'
    }
    if ((File-Text) -match '(?m)^profile\.gamma\.') { throw 'Removed profile left file lines.' }
    Write-Output 'PASS confirmation removes profile lines'

    # Only profile and shell keys are present; the table introduced no new settings key.
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
        $key = ($trimmed -split '=', 2)[0].Trim()
        if ($key -notmatch '^(profile|shell)\.') { throw "Unexpected settings key $key" }
    }
    Write-Output 'PASS settings file keeps existing key families'
} finally {
    & $ctl --name $name stop | Write-Output
    if (Test-Path $source) { Remove-Item -LiteralPath $source -Force }
}

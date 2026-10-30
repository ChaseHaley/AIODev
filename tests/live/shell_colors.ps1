[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'shell-colors'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'
function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Read-State {
    $lines = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect state.' }
    $state = @{}
    foreach ($line in $lines) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Set-Option([string] $Key, [string] $Value) {
    $text = [IO.File]::ReadAllText($path)
    $pattern = '(?m)^' + [regex]::Escape($Key) + '\s*=.*$'
    if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, "$Key = $Value") }
    else { $text += "`n$Key = $Value`n" }
    [IO.File]::WriteAllText($path, $text)
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png") -Frame
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
}
Invoke-Aio launch --fresh
try {
    $session = (Read-State)['session.id']
    Invoke-Aio run 'function prompt { "T> " }; Clear-Host; Write-Output THEME_READY'
    Set-Option theme.mode light
    Set-Option colors.background '#0f1115'
    Set-Option colors.foreground '#d6dae0'
    Set-Option colors.palette.1 '#112233'
    Set-Option colors.cursor ''
    Invoke-Aio command settings.reload
    Invoke-Aio expect state terminal.background=#0f1115
    Invoke-Aio expect state terminal.foreground=#d6dae0
    Invoke-Aio expect state theme.name=studio-custom
    Invoke-Aio expect state "session.id=$session"
    $saved = [IO.File]::ReadAllText($path)
    if ($saved -match '(?m)^colors\.') { throw 'Legacy color lines survived migration.' }
    foreach ($entry in @('theme.custom.studio-custom.base = studio-light',
                         'theme.custom.studio-custom.palette.1 = #112233')) {
        if (-not $saved.Contains($entry)) { throw "Lost override: $entry" }
    }
    Write-Output 'PASS legacy color overrides migrate into a custom theme'
    Invoke-Aio command settings.open
    Invoke-Aio type colors.background
    Invoke-Aio expect state settings.key=colors.background
    Invoke-Aio key Ctrl+R
    Invoke-Aio expect state settings.error=false
    Invoke-Aio expect state terminal.background=#ffffff
    Invoke-Aio expect state "session.id=$session"
    Invoke-Aio expect text THEME_READY
    Shot custom-theme-reset-color
    Write-Output 'PASS reset returns one color to the base theme'
    Set-Option theme.name tide
    Invoke-Aio command settings.reload
    Invoke-Aio command settings.open
    Invoke-Aio type colors.tab_bar
    Invoke-Aio expect state settings.key=colors.tab_bar
    [IO.File]::AppendAllText($path, "`n# concurrent owner edit`n")
    $external = [IO.File]::ReadAllText($path)
    Invoke-Aio key Tab
    Invoke-Aio key Ctrl+A
    Invoke-Aio type '#203040'
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.error=true
    if ([IO.File]::ReadAllText($path) -ne $external) { throw 'A stale editor overwrote an external change.' }
    Write-Output 'PASS theme edits reject a stale editor source'
    Invoke-Aio command tab.close
    Invoke-Aio command settings.open
    Invoke-Aio type colors.tab_bar
    Invoke-Aio key Tab
    Invoke-Aio key Ctrl+A
    Invoke-Aio type '#203040'
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.error=false
    Invoke-Aio expect state theme.name=tide-custom
    Shot builtin-edit-saves-theme
    Invoke-Aio command tab.close
    Invoke-Aio command tab.new
    Invoke-Aio wait text 'PS '
    $persisted = Join-Path $directory 'persisted.ini'
    Copy-Item -LiteralPath $path -Destination $persisted
    Invoke-Aio stop
    Invoke-Aio launch --settings $persisted
    Invoke-Aio expect state theme.name=tide-custom
    Write-Output 'PASS editing a built-in color saves and persists a custom theme'
} finally {
    & $ctl --name $name stop | Write-Output
}

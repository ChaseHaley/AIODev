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
    Set-Option colors.cursor '#445566'
    Invoke-Aio command settings.reload
    Invoke-Aio expect state terminal.background=#0f1115
    Invoke-Aio expect state terminal.foreground=#d6dae0
    Invoke-Aio command settings.open
    Invoke-Aio type colors.follow_theme
    Invoke-Aio expect state settings.key=colors.follow_theme
    Shot legacy-reset-control
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.error=false
    Invoke-Aio command tab.close
    Invoke-Aio expect state terminal.background=#ffffff
    Invoke-Aio expect state terminal.foreground=#18181b
    Invoke-Aio expect state "session.id=$session"
    Invoke-Aio expect text THEME_READY
    Shot light-reset-shell
    $saved = [IO.File]::ReadAllText($path)
    foreach ($entry in @('colors.palette.1 = #112233', 'colors.cursor = #445566')) {
        if (-not $saved.Contains($entry)) { throw "Lost override: $entry" }
    }
    Write-Output 'PASS explicit reset keeps other color overrides'
    Set-Option theme.mode dark
    Invoke-Aio command settings.reload
    Invoke-Aio expect state terminal.background=#121215
    Invoke-Aio expect state terminal.foreground=#ececf1
    Invoke-Aio expect state "session.id=$session"
    Set-Option theme.mode light
    Set-Option colors.background '#123456'
    Set-Option colors.foreground '#abcdef'
    Invoke-Aio command settings.reload
    Invoke-Aio expect state terminal.background=#123456
    Invoke-Aio expect state terminal.foreground=#abcdef
    Invoke-Aio command settings.open
    Invoke-Aio type colors.follow_theme
    [IO.File]::AppendAllText($path, "`n# concurrent owner edit`n")
    $external = [IO.File]::ReadAllText($path)
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.error=true
    if ([IO.File]::ReadAllText($path) -ne $external) { throw 'Reset overwrote an external change.' }
    Write-Output 'PASS atomic reset rejects stale editor source'
    Invoke-Aio command tab.close
    Invoke-Aio command settings.follow_theme_colors
    Invoke-Aio expect state terminal.background=#ffffff
    Invoke-Aio expect state terminal.foreground=#18181b
    Invoke-Aio expect state "session.id=$session"
    Invoke-Aio command tab.new
    Invoke-Aio expect state terminal.background=#ffffff
    Invoke-Aio expect state terminal.foreground=#18181b
    Invoke-Aio wait text 'PS '
    Shot light-new-shell
    $persisted = Join-Path $directory 'persisted.ini'
    Copy-Item -LiteralPath $path -Destination $persisted
    Invoke-Aio stop
    Invoke-Aio launch --settings $persisted
    Invoke-Aio expect state terminal.background=#ffffff
    Invoke-Aio expect state terminal.foreground=#18181b
    Write-Output 'PASS follow-theme colors persist for existing, new and relaunched shells'
} finally {
    & $ctl --name $name stop | Write-Output
}

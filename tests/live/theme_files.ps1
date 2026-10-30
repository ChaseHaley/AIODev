[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'creator-theme-files'
$id = 'live-theme-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$themes = Join-Path $repo 'build/themes'
$fixture = Join-Path $themes "$id.theme.json"
$path = Join-Path $repo "build/verify/$name/settings.ini"
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    $result | Write-Output
}
if (Test-Path -LiteralPath $fixture) { throw 'Fixture already exists.' }
[IO.File]::WriteAllText($fixture, (@{
    version = 1; id = $id; base = 'tide-dark'
    colors = @{ background = '#102030'; tab_bar = '#203040'; border = '#abcdef80' }
} | ConvertTo-Json))
try {
    Invoke-Aio launch --fresh
    [IO.File]::AppendAllText($path, "`ntheme.name = $id`n")
    Invoke-Aio command settings.reload
    Invoke-Aio expect state "theme.name=$id"
    Invoke-Aio expect state terminal.background=#102030
    Invoke-Aio command settings.open
    Invoke-Aio type theme.export
    Invoke-Aio expect state settings.key=theme.export
    Invoke-Aio key Tab
    Invoke-Aio expect state settings.error=false
    $exports = @(Get-ChildItem -LiteralPath $themes -Filter "export-$id-*.theme.json")
    if ($exports.Count -ne 1) { throw 'Export did not create one file.' }
    $export = Get-Content -LiteralPath $exports[0].FullName -Raw | ConvertFrom-Json
    if ($export.colors.background -ne '#102030') { throw 'Export lost the active colors.' }
    if (@($export.colors.PSObject.Properties).Count -ne 48) { throw 'Export omitted colors.' }
    Invoke-Aio command tab.close
    Invoke-Aio command settings.open
    Invoke-Aio type colors.background
    Invoke-Aio key Tab
    Invoke-Aio key Ctrl+A
    Invoke-Aio type '#112233'
    Invoke-Aio key Enter
    Invoke-Aio expect state settings.error=false
    Invoke-Aio expect state "theme.name=$id-custom"
    Invoke-Aio expect state terminal.background=#112233
    $original = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
    if ($original.colors.background -ne '#102030') { throw 'Editing changed the shared file.' }
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Frame -Shot (
        Join-Path $repo "build/verify/$name/file-theme-copy.png")
    if ($LASTEXITCODE -ne 0) { throw 'Screenshot failed.' }
    Invoke-Aio stop
    Invoke-Aio launch --settings $path
    Invoke-Aio expect state "theme.name=$id-custom"
    Invoke-Aio expect state terminal.background=#112233
    Write-Output 'PASS file discovery, export, shared-file preservation, local copy and restart persistence'
} finally {
    & $ctl --name $name stop | Write-Output
    Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $themes -Filter "export-$id-*.theme.json" |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName }
}

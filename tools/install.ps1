[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'aiodev.exe'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'Extract the AIODev package, then run its install.ps1.'
}
$destination = Join-Path $env:LOCALAPPDATA 'Programs\AIODev'
New-Item -ItemType Directory -Force $destination | Out-Null
foreach ($name in @('aiodev.exe', 'aio.exe', 'conpty.dll', 'OpenConsole.exe', 'Ghostty-LICENSE.txt', 'ConPTY-LICENSE.txt', 'build.txt')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $destination $name)
}
$themeDestination = Join-Path $destination 'themes'
New-Item -ItemType Directory -Force $themeDestination | Out-Null
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'themes') -File) {
    $target = Join-Path $themeDestination $file.Name
    if ($file.Name -eq 'theme.schema.json' -or -not (Test-Path -LiteralPath $target)) {
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}
$shell = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'AIODev.lnk'
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $destination 'aiodev.exe'
$shortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
$shortcut.IconLocation = "$($shortcut.TargetPath),0"
$shortcut.Save()
Write-Output "Installed: $destination"
Write-Output "Start menu shortcut: $shortcutPath"

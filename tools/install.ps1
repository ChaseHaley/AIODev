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
# Adds a directory to the user's PATH once. Raw registry access keeps %VARIABLE% entries unexpanded,
# which [Environment]::SetEnvironmentVariable would flatten.
function Add-UserPath([Microsoft.Win32.RegistryKey] $Key, [string] $Directory) {
    $raw = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    if ($Key.GetValueNames() -contains 'Path') { $kind = $Key.GetValueKind('Path') }
    $entries = @(([string] $Key.GetValue('Path', '', $raw)) -split ';' | Where-Object { $_ -ne '' })
    $present = $entries | Where-Object { $_.TrimEnd('\') -eq $Directory.TrimEnd('\') }
    if ($present) { return $false }
    $Key.SetValue('Path', (($entries + $Directory) -join ';'), $kind)
    return $true
}

# Coding agents run aio from any terminal, not only AIODev panes, so it goes on the user's PATH.
$environment = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
try { $pathAdded = Add-UserPath $environment $destination } finally { $environment.Dispose() }
if ($pathAdded) {
    Add-Type -Namespace AIODevInstall -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
    uint flags, uint timeout, out UIntPtr result);
'@
    # WM_SETTINGCHANGE tells Explorer, and terminals it starts later, that the environment changed.
    $result = [UIntPtr]::Zero
    [void] [AIODevInstall.Native]::SendMessageTimeout([IntPtr] 0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000,
        [ref] $result)
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
if ($pathAdded) {
    Write-Output "Added $destination to your PATH; terminals opened from now on can run aio."
} else {
    Write-Output "aio is on your PATH: $destination"
}

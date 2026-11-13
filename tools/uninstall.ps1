# Removes what install.ps1 and AIODev added for the current user: the program files install.ps1 lists in
# its files.txt receipt, the PATH entry, the Start menu shortcut and the notification registration.
# Settings (%APPDATA%\AIODev) and saved layouts and logs (%LOCALAPPDATA%\AIODev) are kept; the output says
# where they are. Run it with:
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\AIODev\uninstall.ps1"
& {
    $ErrorActionPreference = 'Stop'
    $destination = Join-Path $env:LOCALAPPDATA 'Programs\AIODev'
    $installed = Join-Path $destination 'aiodev.exe'
    $receipt = Join-Path $destination 'files.txt'
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) {
        throw "No AIODev install receipt at $receipt, so nothing was removed."
    }
    $running = @(Get-Process -Name aiodev -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $installed })
    if ($running.Count -gt 0) {
        throw 'AIODev is running. Quit it, including from the notification area, then uninstall again.'
    }

    # Only the files the receipt names, never the whole folder, so anything else kept there survives, and the
    # previous versions install.ps1 moved aside under .replaced while they ran.
    $names = @(Get-Content -LiteralPath $receipt | Where-Object { $_ -ne '' })
    foreach ($name in $names + 'files.txt') {
        Remove-Item -LiteralPath (Join-Path $destination $name) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $destination '.replaced') -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($directory in @($names | ForEach-Object { Split-Path $_ } | Where-Object { $_ } | Sort-Object -Unique -Descending) + '') {
        $path = Join-Path $destination $directory
        if ((Test-Path -LiteralPath $path) -and -not (Get-ChildItem -LiteralPath $path -Force)) {
            Remove-Item -LiteralPath $path
        }
    }

    # Raw registry access keeps the other entries' %VARIABLE% references unexpanded.
    $environment = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $raw = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        $entries = @(([string] $environment.GetValue('Path', '', $raw)) -split ';' | Where-Object { $_ -ne '' })
        $kept = @($entries | Where-Object { $_.TrimEnd('\') -ne $destination.TrimEnd('\') })
        $pathRemoved = $kept.Count -ne $entries.Count
        if ($pathRemoved) { $environment.SetValue('Path', ($kept -join ';'), $environment.GetValueKind('Path')) }
    } finally { $environment.Dispose() }
    if ($pathRemoved) {
        Add-Type -Namespace AIODevUninstall -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
    uint flags, uint timeout, out UIntPtr result);
'@
        # WM_SETTINGCHANGE tells Explorer, and terminals it starts later, that the environment changed.
        $result = [UIntPtr]::Zero
        [void] [AIODevUninstall.Native]::SendMessageTimeout([IntPtr] 0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2,
            5000, [ref] $result)
    }

    # The shortcut is install.ps1's and AIODev's own; one pointing anywhere else is left alone.
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'AIODev.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        $target = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath).TargetPath
        if ($target -eq $installed) { Remove-Item -LiteralPath $shortcutPath }
    }
    # AIODev registers this key for its notifications (native/windows_notifications.cpp).
    Remove-Item -LiteralPath 'HKCU:\Software\Classes\AppUserModelId\AIODev.ProgramStatus' -Recurse -ErrorAction SilentlyContinue

    $left = @(if (Test-Path -LiteralPath $destination) { Get-ChildItem -LiteralPath $destination -Recurse -File })
    Write-Output "Removed AIODev from $destination."
    if ($left.Count -gt 0) { Write-Output "Kept $($left.Count) files there that the install did not list." }
    if ($pathRemoved) { Write-Output 'Removed it from your PATH.' }
    Write-Output "Kept your settings in $(Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AIODev')"
    Write-Output "and saved layouts and logs in $(Join-Path $env:LOCALAPPDATA 'AIODev'); delete them to remove everything."
    # Install Agent Session Hooks adds an "aio agent-session" hook to these files; it now names a missing aio.
    # The files are JSON, so the command's quotes around aio's path appear escaped.
    $aio = (Join-Path $destination 'aio.exe') -replace '\\', '/'
    $claude = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $codex = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    foreach ($file in (Join-Path $claude 'settings.json'), (Join-Path $codex 'hooks.json')) {
        if ((Test-Path -LiteralPath $file) -and (Get-Content -LiteralPath $file -Raw).Contains("$aio\`" agent-session")) {
            Write-Output "Remove the SessionStart hook running `"$aio`" agent-session from $file."
        }
    }
}

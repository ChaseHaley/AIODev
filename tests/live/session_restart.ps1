[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build\aioctl.exe'
$name = 't1-session-restart'
$settingsPath = Join-Path $repo "build\verify\$name\settings.ini"

function Invoke-Aio {
    Write-Output ("> aioctl --name $name " + ($args -join ' '))
    & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw 'AIODev request failed.' }
}

function Assert-SessionMessage([string] $Expected) {
    $state = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect session state.' }
    $notice = @($state | Where-Object { $_ -like 'session.message=*' })
    if ($notice.Count -ne 1 -or $notice[0] -notlike "*$Expected*") {
        $state | Write-Output
        throw "FAIL pane message: expected $Expected"
    }
    Write-Output "PASS pane message contains $Expected"
}

Invoke-Aio launch
$original = $null
try {
    $original = [IO.File]::ReadAllText($settingsPath)
    $invalid = [regex]::Replace($original, '(?m)^shell.command = .*',
        'shell.command = aio_t1_missing_program_9821.exe')
    [IO.File]::WriteAllText($settingsPath, $invalid)
    Invoke-Aio command settings.reload
    Invoke-Aio command terminal.restart_shell
    Invoke-Aio expect state session.status=failed
    Assert-SessionMessage 'aio_t1_missing_program_9821.exe'

    $invalid = [regex]::Replace($original, '(?m)^shell.directory = .*',
        'shell.directory = "C:\AIODev_t1_nonexistent_directory_9821"')
    [IO.File]::WriteAllText($settingsPath, $invalid)
    Invoke-Aio command settings.reload
    Invoke-Aio command terminal.restart_shell
    Invoke-Aio expect state session.status=failed
    Assert-SessionMessage 'working directory'

    Invoke-Aio key Enter
    Invoke-Aio expect state session.status=failed
    Assert-SessionMessage 'working directory'

    [IO.File]::WriteAllText($settingsPath, $original)
    Invoke-Aio command settings.reload
    Invoke-Aio command terminal.restart_shell
    Invoke-Aio wait text 'PS '
    Invoke-Aio expect state session.status=running
    $state = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0 -or $state -notcontains 'session.message=""') {
        throw 'FAIL recovery: stale pane message.'
    }
    Write-Output 'PASS recovery clears the pane message'
} finally {
    if ($null -ne $original) { [IO.File]::WriteAllText($settingsPath, $original) }
    Invoke-Aio stop
}

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'shell-metadata'
$path = Join-Path $repo "build/verify/$name/settings.ini"
$variable = 'AIODEV_TEST_' + [Guid]::NewGuid().ToString('N')
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    $result | Write-Output
}
function Read-State {
    $state = @{}
    foreach ($line in (& $ctl --name $name state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1]
    }
    return $state
}
function Set-Option([string] $Key, [string] $Value) {
    $text = [IO.File]::ReadAllText($path)
    $text = [regex]::Replace($text, '(?m)^' + [regex]::Escape($Key) + ' = .*\r?\n?', '')
    [IO.File]::WriteAllText($path, $text.TrimEnd()+"`n$Key = $Value`n")
}
function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected $Expected, observed $Actual" }
    Write-Output "PASS $Label"
}
Invoke-Aio launch --fresh
try {
    Invoke-Aio run 'function prompt { "M> " }; [Console]::Write(([char]27).ToString()+"]2;Process one"+([char]7))'
    Invoke-Aio expect state 'tab.1.title=Process one'
    Invoke-Aio command pane.rename
    Invoke-Aio type 'Named pane'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'tab.1.title=Named pane'
    Invoke-Aio run '[Console]::Write(([char]27).ToString()+"]2;Changed process"+([char]7))'
    Invoke-Aio expect state 'session.header.title=Changed process'
    Invoke-Aio expect state 'tab.1.title=Named pane'
    Invoke-Aio command tab.rename
    Invoke-Aio type 'Named tab'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'tab.1.title=Named tab'
    Invoke-Aio command pane.split_right
    Invoke-Aio expect state 'tab.1.title=Named tab'
    Invoke-Aio command tab.rename
    Invoke-Aio key Ctrl+A Backspace Enter
    Invoke-Aio command pane.focus_left
    Invoke-Aio expect state 'tab.1.title=Named pane'
    Invoke-Aio command pane.rename
    Invoke-Aio key Ctrl+A Backspace Enter
    Invoke-Aio expect state 'tab.1.title=Changed process'
    Invoke-Aio command tab.rename
    Invoke-Aio type 'Cancelled'
    Invoke-Aio key Esc
    Invoke-Aio expect state 'tab.1.title=Changed process'
    Write-Output 'PASS process titles, focus tracking, rename precedence, clearing, and cancel'

    [Environment]::SetEnvironmentVariable($variable, 'fresh-value', 'User')
    Invoke-Aio command tab.new
    Invoke-Aio run ('[Console]::WriteLine("FRESH="+$env:' + $variable + ')')
    Invoke-Aio wait text 'FRESH=fresh-value'
    Invoke-Aio command pane.split_down
    Invoke-Aio run ('[Console]::WriteLine("SPLIT="+$env:' + $variable + ')')
    Invoke-Aio wait text 'SPLIT=fresh-value'
    Write-Output 'PASS new tabs and splits see environment changes after app launch'
    Set-Option shell.report_directory true
    Set-Option shell.command 'pwsh.exe -NoLogo -NoProfile'
    Invoke-Aio command settings.reload
    Invoke-Aio command tab.new
    Invoke-Aio run 'Set-Location C:\Windows; Write-Output ("DIRECTORY_"+"READY")'
    Invoke-Aio wait text DIRECTORY_READY
    Invoke-Aio expect state 'session.header.directory=C:\Windows'
    Invoke-Aio run 'Set-Location C:\Windows\System32; Write-Output ("DIRECTORY_"+"SECOND")'
    Invoke-Aio wait text DIRECTORY_SECOND
    Invoke-Aio expect state 'session.header.directory=C:\Windows\System32'
    Write-Output 'PASS opt-in PowerShell directory reporting follows Set-Location'
} finally {
    [Environment]::SetEnvironmentVariable($variable, $null, 'User')
    & $ctl --name $name stop | Write-Output
}

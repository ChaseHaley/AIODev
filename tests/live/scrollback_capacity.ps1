[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')]
    [string] $Name = 'work328-scrollback'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$settings = Join-Path $repo "build/verify/$Name/settings.ini"

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}

function Set-Limit([int] $Lines) {
    $text = [IO.File]::ReadAllText($settings)
    $text = [regex]::Replace($text, '(?m)^scrollback\.lines\s*=.*\r?\n?', '')
    [IO.File]::WriteAllText($settings, $text.TrimEnd()+"`nscrollback.lines = $Lines`n")
    Invoke-Aio command settings.reload
}

function Find-Numbers {
    Invoke-Aio key Ctrl+Shift+F
    Invoke-Aio key Ctrl+A
    Invoke-Aio type '^\d+$'
    $state = Invoke-Aio state
    if ($state -contains 'find.regex=false') { Invoke-Aio key Alt+R }
}

function Expect-Count([int] $Minimum, [int] $Maximum) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = ''
    $stable = 0
    do {
        $state = Invoke-Aio state
        $line = $state | Where-Object { $_ -match '^find\.matches=' }
        if ($line -eq $last) { $stable++ } else { $stable = 0; $last = $line }
        if ($stable -ge 5 -and $line -match '\d+ matches') { break }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt 10)
    if ($stable -lt 5) { throw "Search did not settle: $line" }
    if ($line -notmatch '"?(\d+) matches') { throw "Missing match count: $line" }
    $count = [int]$Matches[1]
    if ($count -lt $Minimum -or $count -gt $Maximum) {
        throw "Expected $Minimum..$Maximum retained numbered lines; observed $count"
    }
    Write-Output "PASS retained numbered lines: $count (expected $Minimum..$Maximum)"
}

Invoke-Aio launch --fresh --size 240x24
try {
    Invoke-Aio doctor
    Set-Limit 10000
    Invoke-Aio run '1..500'
    Find-Numbers
    Expect-Count 500 500
    Invoke-Aio key Esc
    Invoke-Aio run '1..500'
    Find-Numbers
    Expect-Count 1000 1000
    Invoke-Aio key Esc
    Invoke-Aio run '1..9500'
    Find-Numbers
    Expect-Count 9400 10600
    Invoke-Aio key Esc
    Set-Limit 1000
    Find-Numbers
    Expect-Count 400 1600
    Invoke-Aio key Esc
    Set-Limit 10000
    Invoke-Aio run 'Clear-Host'
    Invoke-Aio command terminal.clear_scrollback
    Invoke-Aio run '1..500'
    Invoke-Aio run '1..500'
    Find-Numbers
    Expect-Count 1000 1000
    Invoke-Aio doctor
} finally {
    Invoke-Aio stop
}

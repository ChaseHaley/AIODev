$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'

function Invoke-Aio {
    & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) {
        & $ctl --name $name screen | Write-Output
        throw "AIODev request failed: $($args -join ' ')"
    }
}

function Start-Journey([string] $Journey) {
    $script:name = "unicode-$Journey"
    Invoke-Aio launch --fresh
    Invoke-Aio run "function prompt { 'U> ' }; Clear-Host"
    Invoke-Aio expect text 'U>'
}

function New-UnicodeFixture {
    $path = Join-Path $repo "build/verify/$name/unicode.txt"
    $lines = foreach ($raw in [IO.File]::ReadLines((Join-Path $repo 'tests/fixtures/unicode.txt'))) {
        $fields = (($raw -split '#', 2)[0].Trim() -split '\s+')
        if ($fields.Count -lt 3) { continue }
        $encoded = if ($fields.Count -ge 4) { $fields[3] } else { $fields[2] }
        $text = [regex]::Replace($encoded, '<([0-9A-Fa-f]+)>', {
            param($match)
            [char]::ConvertFromUtf32([Convert]::ToInt32($match.Groups[1].Value, 16))
        })
        "$($fields[0]) $text"
    }
    [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
    return $path
}

function Require-Application([string] $Application) {
    $command = Get-Command $Application -ErrorAction SilentlyContinue
    if (-not $command) {
        Write-Output "INCONCLUSIVE: $Application is not installed."
        exit 2
    }
    return $command.Source
}

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $root 'build/ghostty_abi'
New-Item -ItemType Directory -Force $output | Out-Null

Push-Location $root
try {
    & zig cc -I vendor/ghostty/include tools/ghostty_abi/abi.c -o "$output/abi.exe"
    if ($LASTEXITCODE -ne 0) { throw "ABI compilation failed: $LASTEXITCODE" }
    $expected = & "$output/abi.exe"
    if ($LASTEXITCODE -ne 0) { throw "ABI probe failed: $LASTEXITCODE" }
    $encoding = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $root 'tests/ghostty/abi_expected.odin'), ($expected -join "`n") + "`n", $encoding)
}
finally {
    Pop-Location
}

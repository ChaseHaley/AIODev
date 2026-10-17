[CmdletBinding()]
param()
. "$PSScriptRoot/compatibility_common.ps1"
$git = Require-Application git
$less = Get-Command less -ErrorAction SilentlyContinue
$lessPath = if ($less) { $less.Source } else { Join-Path (Split-Path (Split-Path $git -Parent) -Parent) 'usr/bin/less.exe' }
if (-not (Test-Path -LiteralPath $lessPath)) { Write-Output 'INCONCLUSIVE: less is not installed.'; exit 2 }
& $git --version
& $lessPath --version | Select-Object -First 1
Start-Journey pager
try {
    $fixture = New-UnicodeFixture
    $sandbox = Join-Path $repo "build/verify/$name/pager-repo"
    $null = New-Item -ItemType Directory -Force $sandbox
    & $git -C $sandbox init -q
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize pager fixture repository.' }
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $sandbox 'unicode.txt')
    [IO.File]::AppendAllText((Join-Path $sandbox 'unicode.txt'), "`né界👩‍💻`n")
    & $git -C $sandbox add unicode.txt
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage pager fixture.' }
    & $git -C $sandbox -c user.name=Fixture -c user.email=fixture@example.invalid -c core.hooksPath=NUL commit -qm 'Unicode fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot commit pager fixture.' }
    [IO.File]::AppendAllText((Join-Path $sandbox 'unicode.txt'), "`né界👩‍💻`n")
    $pagerCommand = '"' + $lessPath.Replace('\', '/') + '"'
    Invoke-Aio run "Write-Output 'PAGER_HISTORY_MARKER'; `$env:LESSCHARSET='utf-8'; `$env:LESS='-R'; `$env:GIT_PAGER='$pagerCommand'"
    foreach ($subcommand in @('log -p', 'diff')) {
        Invoke-Aio run "git -C '$sandbox' $subcommand"
        Invoke-Aio wait text 'unicode.txt'
        Invoke-Aio expect no-text PAGER_HISTORY_MARKER
        Invoke-Aio resize 47x18
        Invoke-Aio key End
        Invoke-Aio wait text 'é界👩‍💻'
        Invoke-Aio resize 120x32
        Invoke-Aio key q
        Invoke-Aio wait text PAGER_HISTORY_MARKER
        Invoke-Aio expect text 'U>'
    }
} finally { Invoke-Aio stop }

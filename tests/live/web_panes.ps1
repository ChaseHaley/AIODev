[CmdletBinding()]
param([string] $Name = 'web-panes')
# Web panes through the CLI and URL bar: normalised web addresses, a local HTML file, and refused schemes.
# Closing a pane preserves its address on reopen; open panes survive a restart.
# Runs headless, where a web pane is placed, listed and saved but shows a message instead of a page.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$settings = Join-Path $work 'settings.ini'
# aio must name this instance's focused pane, not the pane this script runs in.
$env:AIODEV_PANE = $null
$env:AIODEV_CLI = $null

function Invoke-Ctl {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Invoke-Aio {
    $out = & $aio --instance $Name @args 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String).Trim() }
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Ctl state)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $state[$line.Substring(0, $at)] = $line.Substring($at + 1).Trim('"') }
    }
    return $state
}
function Wait-For([string] $Key, [string] $Value) {
    for ($i = 0; $i -lt 60; $i++) {
        if ((Read-State)[$Key] -eq $Value) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Key=$Value; saw $((Read-State)[$Key])."
}
function Check([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Open-Web([string[]] $Arguments) {
    $result = Invoke-Aio (@('pane.open_web') + $Arguments)
    if ($result.Code -ne 0) { throw "aio pane.open_web $($Arguments -join ' '): $($result.Text)" }
}
# The address of every web pane the state names, sorted.
function Web-Urls {
    $state = Read-State
    return @($state.Keys | Where-Object { $_ -match '^web\.pane\.\d+\.url$' } | ForEach-Object { $state[$_] } | Sort-Object)
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
$localFile = Join-Path $work 'local preview.html'
Set-Content -LiteralPath $localFile -Encoding utf8 '<!doctype html><title>Local preview</title><h1 id="preview">Preview</h1>'
$localUrl = [Uri]::new($localFile).AbsoluteUri
@"
control.enabled = true
shell.command = pwsh.exe -NoLogo -NoProfile -NoExit
cursor.blink = false
window.columns = 170
window.rows = 50
"@ | Set-Content -LiteralPath $settings -Encoding utf8

Invoke-Ctl launch --fresh --settings $settings | Out-Null
try {
    Invoke-Ctl wait text 'PS ' | Out-Null
    Check ((Read-State)['web.count'] -eq '0') 'a fresh instance has web panes'

    # Addresses are normalised; --direction places the second pane below the focused one.
    Open-Web @('https://example.com/docs')
    Wait-For 'web.count' '1'
    Open-Web @('--direction', 'down', 'localhost:3000')
    Wait-For 'web.count' '2'
    $urls = Web-Urls
    Check ($urls.Count -eq 2) "expected two web pane urls, saw $($urls -join ', ')"
    Check ($urls[0] -eq 'http://localhost:3000') "first url: $($urls[0])"
    Check ($urls[1] -eq 'https://example.com/docs') "second url: $($urls[1])"
    $state = Read-State
    Check ($state['tab.1.panes'] -eq '3') "tab panes: $($state['tab.1.panes'])"
    $kinds = @($state.Keys | Where-Object { $_ -match '^tab\.1\.pane\.\d+\.kind$' } | ForEach-Object { $state[$_] } | Sort-Object)
    Check (($kinds -join ',') -eq 'terminal,web,web') "pane kinds: $($kinds -join ',')"
    $first = @($state.Keys | Where-Object { $_ -match '^web\.pane\.(\d+)\.url$' })[0] -replace '\.url$', ''
    Check ($state["$first.kind"] -eq 'web') 'web pane kind'
    Check ($state["$first.zoom"] -eq '1') "web zoom: $($state["$first.zoom"])"
    Check ($state["$first.crashed"] -eq 'none') "web crash state: $($state["$first.crashed"])"
    Check ($state["$first.find_count"] -eq '0') "web find count: $($state["$first.find_count"])"

    # Explicit local HTML works through both the CLI and the focused pane's URL bar.
    Open-Web @('--focus', $localUrl)
    Wait-For 'web.url' $localUrl
    Invoke-Ctl key Ctrl+L | Out-Null
    Invoke-Ctl type "$localUrl#preview" | Out-Null
    Invoke-Ctl key Enter | Out-Null
    Wait-For 'web.url' "$localUrl#preview"
    $urls = Web-Urls
    Check ($urls.Count -eq 3) "expected three web panes, saw $($urls -join ', ')"

    # Disallowed addresses must not open a pane.
    $refused = Invoke-Aio @('pane.open_web', 'file://server/share/preview.html')
    Check ($refused.Code -ne 0) 'a file URL with an authority was accepted'
    Check ((Read-State)['web.count'] -eq '3') 'a refused address opened a pane'

    # Close the focused web pane, then bring it back.
    $focus = "$localUrl#preview"
    Invoke-Ctl command pane.close | Out-Null
    Wait-For 'web.count' '2'
    Check (-not ((Web-Urls) -contains $focus)) "$focus is still open"
    Invoke-Ctl command pane.reopen_closed | Out-Null
    Wait-For 'web.count' '3'
    Check (((Web-Urls) -join ',') -eq ($urls -join ',')) "reopened urls: $((Web-Urls) -join ', ')"

    # The panes survive a restart with their addresses.
    Invoke-Ctl command pane.focus_next | Out-Null
    Invoke-Ctl stop | Out-Null
    Invoke-Ctl launch --settings $settings --keep-layout | Out-Null
    Wait-For 'web.count' '3'
    Check (((Web-Urls) -join ',') -eq ($urls -join ',')) "restored urls: $((Web-Urls) -join ', ')"
    Write-Output "PASS web panes journey; restored $((Web-Urls).Count) web panes"
} finally {
    & $ctl --name $Name stop | Out-Null
}

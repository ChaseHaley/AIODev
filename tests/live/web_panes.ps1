[CmdletBinding()]
param([string] $Name = 'web-panes')
# WORK-315: web panes through the CLI. aio pane.open_web opens normalised addresses beside the terminal,
# refuses other schemes, a closed web pane comes back with its address, and the panes survive a restart.
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

    # Other schemes are a usage error and open nothing.
    $refused = Invoke-Aio @('pane.open_web', 'file:///x')
    Check ($refused.Code -ne 0) 'file:///x was accepted'
    Check ($refused.Text -match 'http') "the refusal does not name http: $($refused.Text)"
    Check ((Read-State)['web.count'] -eq '2') 'a refused address opened a pane'

    # Close the focused web pane, then bring it back.
    $focus = $null
    for ($i = 0; $i -lt 6 -and -not $focus; $i++) {
        $s = Read-State
        if ($s['web.active'] -eq 'true') { $focus = $s['web.url']; break }
        Invoke-Ctl command pane.focus_next | Out-Null
    }
    Check ($null -ne $focus) 'no web pane took focus'
    Invoke-Ctl command pane.close | Out-Null
    Wait-For 'web.count' '1'
    Check (-not ((Web-Urls) -contains $focus)) "$focus is still open"
    Invoke-Ctl command pane.reopen_closed | Out-Null
    Wait-For 'web.count' '2'
    Check (((Web-Urls) -join ',') -eq ($urls -join ',')) "reopened urls: $((Web-Urls) -join ', ')"

    # The panes survive a restart with their addresses.
    Invoke-Ctl command pane.focus_next | Out-Null
    Invoke-Ctl stop | Out-Null
    Invoke-Ctl launch --settings $settings --keep-layout | Out-Null
    Wait-For 'web.count' '2'
    Check (((Web-Urls) -join ',') -eq ($urls -join ',')) "restored urls: $((Web-Urls) -join ', ')"

    # --float is per open, and creates its own group even when the target already floats.
    $before = Read-State
    Check ($before['tab.1.floating'] -eq '0') 'default opens unexpectedly floated a pane'
    Open-Web @('--float', '--focus', 'https://example.com/float')
    Wait-For 'web.url' 'https://example.com/float'
    Wait-For 'tab.1.floating' '1'
    Open-Web @('--pane', 'focused', 'https://example.com/second-float', '--float')
    Wait-For 'tab.1.floating' '2'
    Check ((Web-Urls) -contains 'https://example.com/second-float') 'second URL did not open'
    Check ((Read-State)['web.url'] -eq 'https://example.com/float') 'opening without --focus moved focus'

    $paneCount = (Read-State)['web.count']
    $splitOptions = @(@('--direction', 'down'), @('--ratio', '0.3'))
    foreach ($options in $splitOptions) {
        $refused = Invoke-Aio (@('pane.open_web', '--float', 'https://example.com/conflict') + $options)
        Check ($refused.Code -ne 0 -and $refused.Text -match '--float') "accepted --float with $($options[0])"
    }
    Check ((Read-State)['web.count'] -eq $paneCount) 'a conflicting command opened a pane'
    $preference = Invoke-Aio @('settings.get', '--name', 'pane.web_floating')
    Check ($preference.Code -eq 0 -and $preference.Text -eq 'false') 'the flag changed the saved preference'

    # The same CLI flag works on every single-pane opener.
    $markdown = Join-Path $work 'float.md'
    Set-Content -LiteralPath $markdown '# Floating Markdown'
    $openers = @(
        @{ Kind = 'terminal'; Args = @('pane.split', '--float', '--bounds', '0.1,0.1,0.6,0.6') }
        @{ Kind = 'markdown'; Args = @('pane.open_markdown', '--float', $markdown) }
        @{ Kind = 'changes'; Args = @('pane.agent_changes', '--float') }
        @{ Kind = 'settings'; Args = @('settings.open', '--float') }
    )
    $count = 2
    foreach ($opener in $openers) {
        $result = Invoke-Aio $opener.Args
        Check ($result.Code -eq 0) "$($opener.Args[0]): $($result.Text)"
        $count++
        Wait-For 'tab.1.floating' "$count"
        $state = Read-State
        $matches = @($state.Keys | Where-Object {
            $_ -match '^tab\.1\.pane\.\d+\.kind$' -and $state[$_] -eq $opener.Kind -and
                $state.ContainsKey(($_ -replace '\.kind$', '.float'))
        })
        Check ($matches.Count -eq 1) "expected one floating $($opener.Kind) pane"
    }
    Check ((Read-State)['settings.active'] -eq 'true') 'floating Settings did not take focus'
    $again = Invoke-Aio @('settings.open', '--float')
    Check ($again.Code -eq 0 -and (Read-State)['tab.1.floating'] -eq "$count") 'Settings opened a duplicate'

    Write-Output "PASS panes journey; --float placed every pane kind and restored $($urls.Count) web panes"
} finally {
    & $ctl --name $Name stop | Out-Null
}

[CmdletBinding()]
param([string] $Name = 'web-page-motion')
# A web pane's page takes part in tab, zoom and workspace transitions: it stays shown, moving with its pane
# or its workspace's card, until the motion ends, and hides at once when the motion is off.
# Runs headless, which has no WebView2 but decides where each page shows: web.pane.<id>.page_* in `state`.
# Samples go to build/verify/<Name>-files/samples.json.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$settings = Join-Path $work 'settings.ini'
# The instance reads its own copy; settings.reload rereads it.
$instanceSettings = Join-Path $repo "build/verify/$Name/settings.ini"
$env:AIODEV_PANE = $null
$env:AIODEV_CLI = $null

function Invoke-Ctl {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Ctl state)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $state[$line.Substring(0, $at)] = $line.Substring($at + 1).Trim('"') }
    }
    return $state
}
function Check([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Wait-Settled {
    for ($i = 0; $i -lt 200; $i++) {
        if ((Read-State)['ui.animating'] -eq 'false') { return }
        Start-Sleep -Milliseconds 50
    }
    throw 'Motion did not settle.'
}
# The page of web pane $Id in state $s: shown, level, rect as [x, y, w, h] and scale.
function Page($s, [string] $Id) {
    $prefix = "web.pane.$Id"
    return [pscustomobject]@{
        Shown = $s["$prefix.page_shown"] -eq 'true'
        Level = [int]$s["$prefix.page_level"]
        Rect  = @($s["$prefix.page_rect"] -split ',' | ForEach-Object { [double]$_ })
        Scale = [double]$s["$prefix.page_scale"]
    }
}
$log = [ordered]@{}
# Runs aioctl `command`, then samples the page while the window moves. A command replies within about a
# second even while a longer motion runs, so the long motions below are sampled after the reply.
function Sample-Motion([string] $Label, [string[]] $Command, [string] $Id) {
    Wait-Settled
    Invoke-Ctl command @Command | Out-Null
    $samples = @()
    for ($i = 0; $i -lt 400; $i++) {
        $s = Read-State
        if ($s['ui.animating'] -ne 'true') { break }
        $samples += , (Page $s $Id)
    }
    $after = Page (Read-State) $Id
    Wait-Settled
    $settled = Page (Read-State) $Id
    $log[$Label] = [ordered]@{ samples = $samples; settled = $settled }
    return [pscustomobject]@{ Samples = $samples; After = $after; Settled = $settled }
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
$base = @"
control.enabled = true
shell.command = pwsh.exe -NoLogo -NoProfile -NoExit
cursor.blink = false
window.columns = 170
window.rows = 50
"@
# Long, linear motions keep the window moving well past each command's reply.
"$base`nmotion.panes.switch = 3000ms linear`nmotion.panes.view = 3000ms linear`nmotion.panes.workspace = 4000ms" |
    Set-Content -LiteralPath $settings -Encoding utf8

Invoke-Ctl launch --fresh --settings $settings | Out-Null
try {
    Invoke-Ctl wait text 'PS ' | Out-Null
    $open = & $aio --instance $Name pane.open_web https://example.com/docs 2>&1
    Check ($LASTEXITCODE -eq 0) "aio pane.open_web: $open"
    Wait-Settled
    $state = Read-State
    $id = @($state.Keys | Where-Object { $_ -match '^web\.pane\.(\d+)\.url$' } | ForEach-Object { $Matches[1] })[0]
    Check ($null -ne $id) 'no web pane in state'
    $rest = Page $state $id
    Check ($rest.Shown -and $rest.Scale -eq 1) "the page does not show at rest: $($rest | ConvertTo-Json -Compress)"
    $log['rest'] = $rest

    # A new tab slides the page's tab out to the left; the page goes with it and hides when it has gone.
    $tab = Sample-Motion 'tab.new' @('tab.new') $id
    $moving = @($tab.Samples | Where-Object { $_.Shown -and $_.Rect[0] -lt $rest.Rect[0] })
    Check ($moving.Count -gt 0) 'the page never showed sliding left with its tab'
    Check (-not $tab.Settled.Shown) 'the page still shows after its tab slid away'
    Write-Output "PASS tab.new: the page slid out with its tab in $($moving.Count) samples, then hid"

    $back = Sample-Motion 'tab.previous' @('tab.previous') $id
    $entering = @($back.Samples | Where-Object { $_.Shown -and $_.Rect[0] -lt $rest.Rect[0] })
    Check ($entering.Count -gt 0) 'the page never showed sliding back in'
    Check ($back.Settled.Shown -and ($back.Settled.Rect -join ',') -eq ($rest.Rect -join ',')) 'the page is not back in place'
    Write-Output "PASS tab.previous: the page slid back in over $($entering.Count) samples"

    # Zooming the terminal grows it over the page, which stays beneath it until covered.
    Invoke-Ctl command pane.focus_left | Out-Null
    $zoom = Sample-Motion 'pane.zoom in' @('pane.zoom') $id
    $beneath = @($zoom.Samples | Where-Object { $_.Shown -and ($_.Rect -join ',') -eq ($rest.Rect -join ',') })
    Check ($beneath.Count -gt 0) 'the page vanished as the terminal began to grow over it'
    Check (-not $zoom.Settled.Shown) 'the page shows over the zoomed terminal'
    Write-Output "PASS pane.zoom: the page stayed beneath the growing terminal in $($beneath.Count) samples"

    $unzoom = Sample-Motion 'pane.zoom out' @('pane.zoom') $id
    $uncovered = @($unzoom.Samples | Where-Object { $_.Shown })
    Check ($uncovered.Count -gt 0) 'the page stayed hidden while the terminal shrank off it'
    Check ($unzoom.Settled.Shown) 'the page is hidden after the zoom ended'
    Write-Output "PASS pane.zoom back: the page showed beneath the shrinking terminal in $($uncovered.Count) samples"

    # A new workspace flies the window into its card in the overview; the page shrinks with the card.
    $away = Sample-Motion 'workspace.new' @('workspace.new') $id
    Invoke-Ctl key Esc | Out-Null
    $shrunk = @($away.Samples | Where-Object { $_.Shown -and $_.Scale -lt 1 })
    Check ($shrunk.Count -gt 0) 'the page never shrank with the card of the workspace left'
    Check (-not $away.Settled.Shown) 'the page still shows after the switch'
    $smallest = ($shrunk | Measure-Object -Property Scale -Minimum).Minimum
    Write-Output "PASS workspace.new: the page stayed in its card in $($shrunk.Count) samples, down to scale $smallest"

    $return = Sample-Motion 'workspace.previous' @('workspace.previous') $id
    $arriving = @($return.Samples | Where-Object { $_.Shown -and $_.Scale -lt 1 })
    Check ($arriving.Count -gt 0) 'the page never showed in the card it arrived with'
    Check ($return.Settled.Shown -and $return.Settled.Scale -eq 1) 'the page is not back at full size'
    Write-Output "PASS workspace.previous: the page flew in with its card in $($arriving.Count) samples"

    # With the Switch Pane motion off, changing tabs is instant and the page hides with its tab at once.
    "$base`nmotion.panes.switch = off" | Set-Content -LiteralPath $instanceSettings -Encoding utf8
    Invoke-Ctl command settings.reload | Out-Null
    $instant = Sample-Motion 'tab.next off' @('tab.next') $id
    Check ($instant.Samples.Count -eq 0 -and -not $instant.After.Shown) 'the page lingered with Switch Pane off'
    Write-Output 'PASS tab.next with motion off: the page hid at once'
} finally {
    $log | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $work 'samples.json') -Encoding utf8
    Invoke-Ctl stop | Out-Null
}

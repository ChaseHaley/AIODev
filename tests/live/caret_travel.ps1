[CmdletBinding()]
param([string] $Name = 'caret-travel')
# WORK-497: one cursor everywhere. The window has one caret; moving the keyboard between a shell, the
# palette, the find bar, a Markdown editor and a Settings field flies it there with the chosen preset,
# in one colour, and the caret.* state keys say who holds it. Runs headless.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$captures = Join-Path $repo "build/verify/$Name-captures"
$settings = Join-Path $work 'settings.ini'
$accent = ((Get-Content -Raw (Join-Path $repo 'themes/studio-dark.theme.json') | ConvertFrom-Json).colors.accent).ToLower()
# aio must name this instance's focused pane, not the pane this script runs in.
$env:AIODEV_PANE = $null
$env:AIODEV_CLI = $null

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Invoke-Command-Now { $out = & $aio --instance $Name @args; if ($LASTEXITCODE -ne 0) { throw "aio $($args -join ' '): $out" } }
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $state[$line.Substring(0, $at)] = $line.Substring($at + 1).Trim('"') }
    }
    return $state
}
function Expect([string] $Pair) { Invoke-Aio expect state $Pair | Out-Null }
function Wait-For([string] $Key, [string] $Value) {
    for ($i = 0; $i -lt 60; $i++) {
        if ((Read-State)[$Key] -eq $Value) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Key=$Value; saw $((Read-State)[$Key])."
}
function Rect([string] $Text) { return @($Text -split ',' | ForEach-Object { [double]$_ }) }
function Shot([string] $Label) { Invoke-Aio capture --out (Join-Path $captures "$Label.png") | Out-Null }
function Check([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

# Starts `aio <args>`, which returns before the caret lands, and reads the state until it has landed.
# The samples are what each read saw: owner, phase, rect and colour.
function Watch-Flight([string[]] $Arguments, [switch] $Shoot, [string] $Label = '') {
    & $aio --instance $Name @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "aio $($Arguments -join ' ')" }
    $samples = @()
    $shot = $false
    for ($i = 0; $i -lt 40; $i++) {
        $s = Read-State
        $samples += [pscustomobject]@{ Owner = $s['caret.owner']; Phase = $s['caret.phase']; Rect = (Rect $s['caret.rect']); Color = $s['caret.color'] }
        if ($Shoot -and -not $shot -and $s['caret.phase'] -eq 'flying') { Shot $Label; $shot = $true }
        if ($s['caret.phase'] -eq 'rest' -and $s['ui.animating'] -eq 'false') { break }
    }
    return , $samples
}
function Flights([object[]] $Samples) { return @($Samples | Where-Object { $_.Phase -eq 'flying' }) }

Remove-Item -LiteralPath $work, $captures -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $captures | Out-Null
$note = Join-Path $work 'note.md'
"# Title`n`nSome words here to edit.`n" | Set-Content -LiteralPath $note -Encoding utf8
function Write-Settings([string] $Extra) {
    @"
control.enabled = true
shell.command = pwsh.exe -NoLogo -NoProfile -NoExit
cursor.blink = false
cursor.style = bar
cursor.animation = smear
cursor.animation_duration = 500
cursor.animation_strength = 65
window.columns = 120
window.rows = 32
$Extra
"@ | Set-Content -LiteralPath $settings -Encoding utf8
}
Write-Settings ''

Invoke-Aio launch --fresh --settings $settings | Out-Null
try {
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio focus in | Out-Null
    $s = Read-State
    Check ($s['caret.owner'] -match '^pane:\d+$') "the shell holds the caret, saw $($s['caret.owner'])"
    $shell = $s['caret.owner']
    Expect "caret.color=$accent"
    Expect 'caret.phase=rest'
    Expect 'caret.shape=bar'
    $prompt = Rect $s['caret.rect']

    # Shell to palette and back: the caret flies there between the two, in the accent, and lands on the query.
    $samples = Watch-Flight @('app.command_palette') -Shoot -Label 'shell-to-palette'
    $flying = Flights $samples
    Check ($flying.Count -gt 0) 'the caret flew into the palette'
    Check (($flying | Where-Object { $_.Owner -eq 'palette.query' }).Count -gt 0) 'the flight is bound for the query field'
    $query = $samples[-1].Rect
    Check ($samples[-1].Owner -eq 'palette.query' -and $samples[-1].Phase -eq 'rest') 'the palette query holds the caret at rest'
    Check ($query[0] -gt $prompt[0] -and $query[1] -gt $prompt[1]) 'the query field is down and right of the prompt'
    foreach ($f in $flying) {
        Check ($f.Rect[0] -ge $prompt[0] - 1 -and $f.Rect[0] -le $query[0] + 1) "flight x $($f.Rect[0]) between $($prompt[0]) and $($query[0])"
        Check ($f.Rect[1] -ge $prompt[1] - 1 -and $f.Rect[1] -le $query[1] + 1) "flight y $($f.Rect[1]) between $($prompt[1]) and $($query[1])"
    }
    Expect "caret.color=$accent"
    Invoke-Aio expect state palette.open=true | Out-Null
    Shot 'palette-rest'
    Start-Sleep -Milliseconds 1200
    $samples = Watch-Flight @('app.command_palette') -Shoot -Label 'palette-to-shell'
    Check ((Flights $samples).Count -gt 0) 'the caret flew back to the shell'
    Check ($samples[-1].Owner -eq $shell) 'the shell holds the caret again'
    Check (($samples[-1].Rect -join ',') -eq ($prompt -join ',')) 'the caret landed on the prompt cell'
    Expect 'ui.animating=false'

    # The find bar.
    $samples = Watch-Flight @('terminal.find') -Shoot -Label 'shell-to-find'
    Check ((Flights $samples).Count -gt 0 -and $samples[-1].Owner -eq 'find') 'the caret flew into the find bar'
    Invoke-Aio key Esc | Out-Null
    Expect "caret.owner=$shell"

    # A program's cursor colour (OSC 12) applies only while the caret rests in its pane.
    Invoke-Aio type "printf '\e]12;#ff0000\a'" | Out-Null
    Invoke-Aio key Enter | Out-Null
    Wait-For 'caret.color' '#ff0000'
    $samples = Watch-Flight @('app.command_palette')
    Check ((Flights $samples).Count -gt 0) 'the caret still flew'
    $mid = @((Flights $samples) | Where-Object { $_.Color -ne '#ff0000' -and $_.Color -ne $accent })
    Check ($mid.Count -gt 0) 'the head turned from red to the accent on the way'
    Expect "caret.color=$accent"
    Start-Sleep -Milliseconds 1200
    Invoke-Aio key Esc | Out-Null
    Expect 'caret.color=#ff0000'
    Invoke-Aio type "printf '\e]112\a'" | Out-Null
    Invoke-Aio key Enter | Out-Null
    Wait-For 'caret.color' $accent

    # DECTCEM: a terminal that hides its cursor holds no caret, so nothing flies into or out of it.
    Invoke-Aio type "printf '\e[?25l'" | Out-Null
    Invoke-Aio key Enter | Out-Null
    Wait-For 'caret.present' 'false'
    $samples = Watch-Flight @('app.command_palette')
    Check ((Flights $samples).Count -eq 0) 'no caret flies out of a hidden cursor'
    Expect 'caret.owner=palette.query'
    Start-Sleep -Milliseconds 1200
    $samples = Watch-Flight @('app.command_palette')
    Check ((Flights $samples).Count -eq 0) 'no caret flies into a hidden cursor'
    Expect 'caret.present=false'
    Invoke-Aio type "printf '\e[?25h'" | Out-Null
    Invoke-Aio key Enter | Out-Null
    Wait-For 'caret.owner' $shell

    # Markdown editing: a split Markdown pane, and the caret flies between it and the shell.
    Invoke-Command-Now 'pane.open_markdown' '--focus' $note
    Wait-For 'markdown.active' 'true'
    Invoke-Command-Now 'pane.edit_markdown'
    Wait-For 'caret.owner' 'markdown'
    Start-Sleep -Milliseconds 800
    $samples = Watch-Flight @('pane.focus_left') -Shoot -Label 'markdown-to-shell'
    Check ((Flights $samples).Count -gt 0 -and $samples[-1].Owner -eq $shell) 'the caret flew from the Markdown editor to the shell'
    Start-Sleep -Milliseconds 800
    $samples = Watch-Flight @('pane.focus_right') -Shoot -Label 'shell-to-markdown'
    Check ((Flights $samples).Count -gt 0 -and $samples[-1].Owner -eq 'markdown') 'the caret flew from the shell to the Markdown editor'
    Start-Sleep -Milliseconds 800

    # A Settings field.
    $samples = Watch-Flight @('settings.open') -Shoot -Label 'markdown-to-settings'
    Invoke-Aio type 'cursor' | Out-Null
    Expect 'settings.filter=cursor'
    Check ((Read-State)['caret.owner'] -ne 'none') 'the Settings search holds the caret'
    Shot 'settings-search'
    Start-Sleep -Milliseconds 600

    # Blocks: cursor.style = block gives every surface a block, in the cursor text colour over its text.
    Write-Settings "cursor.style = block`ncursor.blink_interval = 200"
    Copy-Item -LiteralPath $settings -Destination (Read-State)['app.settings'] -Force
    Invoke-Aio command settings.reload | Out-Null
    Wait-For 'caret.shape' 'block'
    Invoke-Aio key Ctrl+Shift+P | Out-Null
    Invoke-Aio type 'blo' | Out-Null
    Expect 'caret.owner=palette.query'
    Expect 'caret.shape=block'
    Shot 'palette-block'
    Invoke-Aio key Esc | Out-Null

    # cursor.blink follows the one window phase in every surface, and cursor.blink_interval sets it.
    Write-Settings "cursor.style = bar`ncursor.blink = true`ncursor.blink_interval = 200"
    Copy-Item -LiteralPath $settings -Destination (Read-State)['app.settings'] -Force
    Invoke-Aio command settings.reload | Out-Null
    Invoke-Aio key Ctrl+Shift+P | Out-Null
    $seen = @{}
    for ($i = 0; $i -lt 30; $i++) { $seen[(Read-State)['caret.blink']] = $true; Start-Sleep -Milliseconds 70 }
    Check ($seen.ContainsKey('shown') -and $seen.ContainsKey('hidden')) "the palette caret blinks: saw $($seen.Keys -join ', ')"
    Invoke-Aio key Esc | Out-Null

    # Off: focus changes do not fly, and the loop is quiet afterwards.
    Write-Settings "cursor.animation = off`ncursor.blink = false"
    Copy-Item -LiteralPath $settings -Destination (Read-State)['app.settings'] -Force
    Invoke-Aio command settings.reload | Out-Null
    Start-Sleep -Milliseconds 500
    $samples = Watch-Flight @('app.command_palette')
    Check ((Flights $samples).Count -eq 0) 'no flight with the preset off'
    Invoke-Aio key Esc | Out-Null
    # A settings reload's notice counts down on screen for a few seconds and presents while it does; once
    # it has gone, the caret must not keep the loop awake.
    $quiet = $false
    for ($i = 0; $i -lt 14 -and -not $quiet; $i++) {
        $before = [int](Read-State)['frames.presented']
        Start-Sleep -Milliseconds 800
        $quiet = ([int](Read-State)['frames.presented']) -eq $before
    }
    Check $quiet 'idle presents stop once the caret has landed'
    Expect 'ui.animating=false'
    Write-Host 'caret travel: ok'
} finally {
    & $ctl --name $Name stop | Out-Null
}

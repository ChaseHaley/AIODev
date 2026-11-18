[CmdletBinding()]
param([string] $Name = 'middle-click-scroll')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$captures = Join-Path $repo "build/verify/$Name-captures"

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $state[$line.Substring(0, $at)] = $line.Substring($at + 1).Trim('"') }
    }
    return $state
}
function Assert([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "FAIL $Label" }
    Write-Output "PASS $Label"
}
function Up { $v = (Read-State)['session.viewport']; if ($v -eq 'bottom') { 0 } else { [int]($v -replace 'up:', '') } }
function Settled([scriptblock] $Read) {
    $a = & $Read; Start-Sleep -Milliseconds 300; $b = & $Read
    return $a -eq $b
}
function Shot([string] $Label) { Invoke-Aio capture --out (Join-Path $captures "$Label.png") | Out-Null }

Remove-Item -LiteralPath $work, $captures -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $captures | Out-Null
$doc = Join-Path $work 'long.md'
(1..400 | ForEach-Object { "Paragraph $_ of a long document." }) -join "`n`n" | Set-Content -LiteralPath $doc -Encoding utf8

# Command line control lets the shell's aio open the document.
$settings = Join-Path $work 'settings.ini'
"control.enabled = true`ncursor.blink = false`n" | Set-Content -LiteralPath $settings -Encoding utf8
Invoke-Aio launch --fresh --settings $settings | Out-Null
try {
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio run '1..300 | % { "line $_" }' | Out-Null

    # Click and release in place: the anchor stays and the pointer's distance sets the speed.
    Invoke-Aio mouse click '60,25' --button middle | Out-Null
    Assert ((Read-State)['pointer.shape'] -eq 'resize_vertical') 'a middle click drops the anchor'
    Assert ((Up) -eq 0) 'the click alone does not scroll'
    Shot 'anchor'
    Invoke-Aio mouse move '60,15' | Out-Null
    Start-Sleep -Milliseconds 300
    $near = Up
    Start-Sleep -Milliseconds 300
    Assert ((Up) -gt $near -and $near -gt 0) 'above the anchor scrolls toward the top and keeps going'
    Invoke-Aio mouse move '60,25' | Out-Null
    Assert (Settled { Up }) 'back in the dead zone it rests'
    Invoke-Aio mouse move '60,30' | Out-Null
    $before = Up
    Start-Sleep -Milliseconds 300
    Assert ((Up) -lt $before) 'below the anchor scrolls toward the bottom'
    Invoke-Aio mouse click '60,30' | Out-Null
    Assert (Settled { Up }) 'a click ends scrolling'
    Assert ((Read-State)['session.selection'] -eq 'none') 'the ending click starts no selection'
    Assert ((Read-State)['pointer.shape'] -ne 'resize_vertical') 'the pointer returns to its usual shape'

    # Press, drag past the dead zone and release: scrolling lasts while the button is down.
    Invoke-Aio key End | Out-Null
    Invoke-Aio run 'cls; 1..300 | % { "line $_" }' | Out-Null
    Invoke-Aio mouse down '60,25' --button middle | Out-Null
    Invoke-Aio mouse move '60,15' --button middle | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-Aio mouse up '60,15' --button middle | Out-Null
    Assert ((Up) -gt 0) 'a middle drag scrolls'
    Assert (Settled { Up }) 'releasing after a drag ends scrolling'

    # Escape and the wheel end it too.
    Invoke-Aio mouse click '60,25' --button middle | Out-Null
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio mouse move '60,30' | Out-Null
    Assert (Settled { Up }) 'Escape ends scrolling'
    Invoke-Aio mouse click '60,25' --button middle | Out-Null
    Invoke-Aio mouse wheel '60,25' 1 | Out-Null
    Invoke-Aio mouse move '60,30' | Out-Null
    Assert (Settled { Up }) 'the wheel ends scrolling'

    # A program that reports the mouse keeps its middle presses.
    Invoke-Aio run 'cls; Write-Host -NoNewline "$([char]27)[?1000h"' | Out-Null
    Invoke-Aio mouse click '60,25' --button middle | Out-Null
    Assert ((Read-State)['pointer.shape'] -ne 'resize_vertical') 'a mouse-reporting program keeps the middle button'
    Invoke-Aio key Ctrl+C | Out-Null
    Invoke-Aio run 'Write-Host -NoNewline "$([char]27)[?1000l"; cls' | Out-Null

    # A Markdown document scrolls by the pixel.
    Invoke-Aio type "& '$aio' pane.open_markdown '$doc'" | Out-Null
    Invoke-Aio key Enter | Out-Null
    for ($i = 0; $i -lt 50 -and (Read-State)['markdown.count'] -ne '1'; $i++) { Start-Sleep -Milliseconds 100 }
    $width = [int]((Read-State)['window.size'] -split 'x')[0]
    $x = [int]($width * 0.6)
    Invoke-Aio mouse click "$x,300" --px --button middle | Out-Null
    Assert ((Read-State)['markdown.active'] -eq 'true') 'the middle click focuses the document'
    Invoke-Aio mouse move "$x,500" --px | Out-Null
    Start-Sleep -Milliseconds 400
    $scroll = [int](Read-State)['markdown.scroll']
    Assert ($scroll -gt 0) "the document scrolls down ($scroll)"
    Invoke-Aio key Esc | Out-Null

    # The settings page.
    Invoke-Aio command settings.open | Out-Null
    Invoke-Aio mouse click '500,300' --px --button middle | Out-Null
    Invoke-Aio mouse move '500,500' --px | Out-Null
    Start-Sleep -Milliseconds 400
    $settings = [int](Read-State)['settings.scroll']
    Assert ($settings -gt 0) "the settings page scrolls down ($settings)"
    Invoke-Aio key Esc | Out-Null
} catch { Shot "failure"; throw } finally {
    & $ctl --name $Name stop | Out-Null
}

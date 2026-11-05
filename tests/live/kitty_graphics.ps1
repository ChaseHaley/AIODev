[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'kitty-graphics'
$data = Join-Path $repo "build/verify/$name"
$fixture = Join-Path $PSScriptRoot 'kitty_graphics_output.ps1'
function Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Fixture([string] $Mode, [string] $Done) {
    Aio run "& '$fixture' $Mode" | Out-Null
    Aio wait text $Done --timeout 15000 | Out-Null
}
function Pass([string] $Text) { Write-Output "PASS $Text" }
# The placed images, from the frame the app last drew: x, y, width and height of each.
function Images {
    $state = @{}
    foreach ($line in (Aio state)) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    $size = $state['window.size'] -split 'x'
    Aio wait frame | Out-Null
    $found = @()
    foreach ($line in (Aio draws --region "0,0,$($size[0]),$($size[1])")) {
        if ($line -match '^image \d+ (-?\d+),(-?\d+) (\d+)x(\d+)$') {
            $found += , @([int] $Matches[1], [int] $Matches[2], [int] $Matches[3], [int] $Matches[4])
        }
    }
    return , $found
}
# The colour at an offset inside a rectangle, as #rrggbbaa.
function Sample($Image, [int] $X, [int] $Y) {
    $region = "$($Image[0]),$($Image[1]),$($Image[2]),$($Image[3])"
    $line = Aio pixels --region $region --sample "$X,$Y"
    if ($line -notmatch '#[0-9a-f]{8}') { throw "Cannot read a colour from: $line" }
    return $Matches[0]
}
function Expect-Color($Image, [int] $X, [int] $Y, [string] $Expected, [string] $What) {
    $actual = Sample $Image $X $Y
    if ($actual -ne $Expected) { throw "$What at $X,$Y was $actual, expected $Expected" }
}
Aio launch --fresh --size 100x40 | Out-Null
try {
    Aio run 'function prompt { "K> " }; Clear-Host' | Out-Null

    # Both directions through the real ConPTY: a program sends a query and reads the answer.
    Fixture probe PROBE_DONE
    Aio expect text 'QUERY:_Gi=31;OK' | Out-Null
    Pass 'a=q reply reached a program through ConPTY'
    Aio expect text 'CELL:[6;' | Out-Null
    Pass 'CSI 16t reported the cell size to a program through ConPTY'
    Aio run 'Clear-Host' | Out-Null
    if ((Images).Count -ne 0) { throw 'An image appeared without being placed.' }
    Pass 'frames without images draw none'

    # A large chunked image, drawn at its natural size.
    Fixture chunked CHUNKED_DONE
    $images = Images
    if ($images.Count -ne 1) { throw "Expected one image, found $($images.Count)." }
    $image = $images[0]
    if ($image[2] -ne 200 -or $image[3] -ne 100) { throw "Natural size was $($image[2])x$($image[3])." }
    Expect-Color $image 10 10 '#ff0000ff' 'top left'
    Expect-Color $image 190 10 '#00ff00ff' 'top right'
    Expect-Color $image 10 90 '#0000ffff' 'bottom left'
    Expect-Color $image 190 90 '#ffffffff' 'bottom right'
    Expect-Color $image 99 49 '#ff0000ff' 'inner edge of the top left quadrant'
    Expect-Color $image 100 49 '#00ff00ff' 'inner edge of the top right quadrant'
    Pass 'chunked RGBA image shows its exact pixels'
    Aio capture --out (Join-Path $data 'chunked.png') | Out-Null

    # Scrolling moves it with the text, and it returns from scrollback.
    $top = $image[1]
    $moved = $image
    for ($try = 0; $try -lt 12 -and $moved[1] -ge $top; $try++) {
        Aio run '1..4 | ForEach-Object { "line $_" }' | Out-Null
        $moved = (Images)[0]
    }
    if ($moved[1] -ge $top) { throw "Image stayed at y=$top after output scrolled, now $($moved[1])." }
    if ($moved[0] -ne $image[0] -or $moved[2] -ne 200) { throw 'Scrolling changed more than the row.' }
    Aio run '1..60 | ForEach-Object { "line $_" }' | Out-Null
    if ((Images).Count -ne 0) { throw 'A scrolled away image is still drawn.' }
    Pass 'image follows scrolling and leaves the viewport'
    $back = @()
    for ($page = 0; $page -lt 6 -and $back.Count -eq 0; $page++) {
        Aio command terminal.scroll_page_up | Out-Null
        $back = Images
    }
    if ($back.Count -ne 1) { throw 'Image did not return from scrollback.' }
    Aio capture --out (Join-Path $data 'scrollback.png') | Out-Null
    Pass "image returns from scrollback after $page pages"
    for ($page = 0; $page -lt 6; $page++) { Aio command terminal.scroll_page_down | Out-Null }

    # A PNG, scaled to cells, in a split pane, which draws through a retained list.
    Aio command pane.split --direction right | Out-Null
    Aio run 'function prompt { "K> " }; Clear-Host' | Out-Null
    Fixture png PNG_DONE
    $images = Images
    if ($images.Count -ne 1) { throw "Expected one image in view, found $($images.Count)." }
    $scaled = $images[0]
    Expect-Color $scaled 2 ([int] ($scaled[3] / 2)) '#ff0000ff' 'scaled PNG left edge'
    Expect-Color $scaled ($scaled[2] - 3) ([int] ($scaled[3] / 2)) '#00ff00ff' 'scaled PNG right edge'
    Pass 'scaled PNG draws in a split pane'
    Aio capture --out (Join-Path $data 'split-png.png') | Out-Null

    # Repaints with nothing new keep the retained list's image.
    Aio command pane.focus_left | Out-Null
    Aio wait frame | Out-Null
    Expect-Color (Images)[0] 2 ([int] ($scaled[3] / 2)) '#ff0000ff' 'scaled PNG after focus moves away'
    Pass 'retained pane list keeps its image'
    Aio command pane.focus_right | Out-Null

    # The default placement moves the cursor past the image, which conhost cannot see. The shell's
    # next output must land below the image, not over it.
    Aio run 'Clear-Host' | Out-Null
    Fixture moves MOVES_DONE
    Aio run '"AFTER_PROMPT"' | Out-Null
    Aio type 'typed' | Out-Null
    Aio wait idle | Out-Null
    $rows = (Aio screen) -join "`n"
    if ($rows -notmatch '(?m)^\s*(\d+)-(\d+) blank\s*\n\s*\d+\|MOVES_DONE') { throw "No gap for the image:`n$rows" }
    if ([int] $Matches[2] - [int] $Matches[1] -ne 3) { throw "Expected four rows for the image:`n$rows" }
    if ($rows -notmatch '\|AFTER_PROMPT' -or $rows -notmatch '\|K> typed') { throw "Shell lost its place:`n$rows" }
    Pass 'shell output continues below a placement that moved the cursor'
    Aio key Ctrl+C | Out-Null

    # The protocol's delete removes it, and the pane keeps working.
    Fixture delete DELETE_DONE
    if ((Images).Count -ne 0) { throw 'A deleted image is still drawn.' }
    Aio run '"AFTER_IMAGES"' | Out-Null
    Aio wait text AFTER_IMAGES | Out-Null
    Pass 'delete removes the image and the pane keeps working'
    $doctor = & $ctl --name $name doctor
    if ($LASTEXITCODE -ne 0) { throw "Doctor failed: $doctor" }
    Pass 'instance stayed healthy'
} finally {
    & $ctl --name $name stop | Out-Null
}

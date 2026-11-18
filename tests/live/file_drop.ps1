[CmdletBinding()]
param([string] $Name = 'file-drop', [string] $Evidence = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$work = Join-Path $repo "build/verify/$Name-files"
if (-not $Evidence) { $Evidence = Join-Path $repo "build/verify/$Name-captures" }
$settings = Join-Path $work 'settings.ini'
$savedPath = $env:PATH

function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $state[$line.Substring(0, $at)] = $line.Substring($at + 1) }
    }
    return $state
}
function Expect([string] $Pair) { Invoke-Aio expect state $Pair | Out-Null }
function Wait-For([string] $Key, [string] $Value) {
    for ($i = 0; $i -lt 50; $i++) {
        if ((Read-State)[$Key] -eq $Value) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Key=$Value; saw $((Read-State)[$Key])."
}
function Shot([string] $Label) { Invoke-Aio capture --out (Join-Path $Evidence "$Label.png") | Out-Null }
# The tiled panes' node, rectangle and place, left to right then top to bottom.
function Get-Panes {
    $found = @()
    foreach ($entry in (Read-State).GetEnumerator()) {
        if ($entry.Key -match '^pane\.(\d+)\.rect$') {
            $r = $entry.Value -split ','
            $found += [pscustomobject]@{ Node = [int]$Matches[1]; X = [double]$r[0]; Y = [double]$r[1]; W = [double]$r[2]; H = [double]$r[3] }
        }
    }
    return $found | Sort-Object X, Y
}
# A point in the pane nearest one of its sides, clear of the window's edge bands.
function Zone($Pane, [string] $Side) {
    $x = $Pane.X + $Pane.W / 2
    $y = $Pane.Y + $Pane.H / 2
    switch ($Side) {
        'left' { $x = $Pane.X + $Pane.W * 0.2 }
        'right' { $x = $Pane.X + $Pane.W * 0.8 }
        'up' { $y = $Pane.Y + $Pane.H * 0.2 }
        'down' { $y = $Pane.Y + $Pane.H * 0.8 }
    }
    return "$([int]$x),$([int]$y)"
}
function Drop-At([string] $Point, [string[]] $Paths) {
    return (Invoke-Aio drop $Point --px @Paths) -join "`n"
}
function Start-Instance {
    Invoke-Aio launch --fresh --settings $settings | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
}
# What the drop outline reports while files are dragged over the window.
function Expect-Outline([string] $Place, [string] $Direction) {
    Expect 'files.dragging=true'
    Expect 'files.drop.shown=true'
    Expect "files.drop.place=$Place"
    if ($Direction) { Expect "files.drop.direction=$Direction" }
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $Evidence | Out-Null
$bin = Join-Path $work 'bin'
$docs = Join-Path $work 'docs'
$many = Join-Path $work 'many'
$folder = Join-Path $work 'some folder'
New-Item -ItemType Directory -Force $bin, $docs, $many, $folder | Out-Null
$markdown = Join-Path $docs 'dropped.md'
$second = Join-Path $docs 'second.md'
$third = Join-Path $docs 'third.md'
$text = Join-Path $docs 'notes.txt'
"# Dropped`n`nBody text.`n" | Set-Content -LiteralPath $markdown -Encoding utf8
"# Second`n`nDropped on chrome.`n" | Set-Content -LiteralPath $second -Encoding utf8
"# Third`n`nDropped on the edge.`n" | Set-Content -LiteralPath $third -Encoding utf8
"plain text`n" | Set-Content -LiteralPath $text -Encoding utf8
1..10 | ForEach-Object { "# Doc $_`n" | Set-Content -LiteralPath (Join-Path $many "doc$_.md") -Encoding utf8 }
# A stand-in for Neovim that shows what it was started with and waits, so the journey does not depend on
# the machine having it. It is a batch file, which also takes the batch command line path.
@'
@echo off
echo FAKE-NVIM %*
echo CWD=%CD%
set /p wait=
'@ | Set-Content -LiteralPath (Join-Path $bin 'nvim.cmd') -Encoding ascii
$pwsh = (Get-Command pwsh.exe).Source
@"
control.enabled = true
shell.command = $pwsh -NoLogo -NoProfile -NoExit
cursor.blink = false
window.columns = 120
window.rows = 36
"@ | Set-Content -LiteralPath $settings -Encoding utf8

try {
    # With Neovim on PATH.
    $env:PATH = "$bin;$savedPath"
    Start-Instance
    Expect 'files.dragging=false'
    Invoke-Aio command pane.split | Out-Null
    Expect 'panes.count=2'
    $panes = @(Get-Panes)

    # Dragging over a pane's left zone shows the header drag's outline: the left half of that pane.
    Invoke-Aio drag enter (Zone $panes[0] 'left') --px | Out-Null
    Expect-Outline 'beside' 'left'
    $rect = (Read-State)['files.drop.rect'] -split ','
    if ([math]::Abs([double]$rect[0] - $panes[0].X) -gt 1.5 -or [math]::Abs([double]$rect[2] - $panes[0].W / 2) -gt 4) {
        throw "The outline is not the pane's left half: $($rect -join ',') for pane $($panes[0] | Out-String)"
    }
    Start-Sleep -Milliseconds 300
    Shot '1-outline-left'
    # The outline follows the pointer to another zone, and onto another pane.
    Invoke-Aio drag over (Zone $panes[0] 'down') --px | Out-Null
    Expect-Outline 'beside' 'down'
    Invoke-Aio drag over (Zone $panes[1] 'right') --px | Out-Null
    Expect-Outline 'beside' 'right'
    Expect "files.drop.target=$($panes[1].Node)"
    # Leaving takes it away and changes nothing.
    Invoke-Aio drag leave | Out-Null
    Expect 'files.dragging=false'
    Expect 'files.drop.shown=false'
    Expect 'panes.count=2'
    Expect 'markdown.count=0'
    Shot '2-after-leave'

    # A window edge band docks along the edge: the outline spans the whole side, and the drop fills it.
    $content = @(Get-Panes)
    $edge = "6,$([int]($content[0].Y + $content[0].H / 2))"
    Invoke-Aio drag enter $edge --px | Out-Null
    Expect-Outline 'edge' 'left'
    Expect 'files.drop.root=true'
    $rect = (Read-State)['files.drop.rect'] -split ','
    if ([double]$rect[3] -lt $content[0].H - 2) { throw "The edge outline is not the full height: $($rect -join ',')" }
    Start-Sleep -Milliseconds 300
    Shot '3-outline-edge'
    Drop-At $edge @($third) | Out-Null
    Wait-For 'markdown.count' 1
    Expect "markdown.path=$third"
    Expect 'panes.count=3'
    Expect 'files.dragging=false'
    $docked = @(Get-Panes)
    if ($docked[0].Node -ne ($docked | Measure-Object Node -Maximum).Maximum -or [math]::Abs($docked[0].H - $content[0].H) -gt 2) {
        throw "The viewer is not docked along the left edge: $($docked | Out-String)"
    }
    Shot '4-docked-edge'

    # The left zone of that viewer puts a second one to its left.
    Drop-At (Zone $docked[0] 'left') @($markdown) | Out-Null
    Wait-For 'markdown.count' 2
    Expect "markdown.path=$markdown"
    $order = @(Get-Panes)
    if ($order[0].Node -ne ($order | Measure-Object Node -Maximum).Maximum) { throw 'The viewer is not left of the panes.' }
    Shot '5-markdown-left'

    # The bottom zone of the right terminal puts one below it, in its column.
    $last = @(Get-Panes)[3]
    Drop-At (Zone $last 'down') @($second) | Out-Null
    Wait-For 'markdown.count' 3
    $column = @(Get-Panes | Where-Object { [math]::Abs($_.X - $last.X) -lt 2 } | Sort-Object Y)
    if ($column.Count -ne 2 -or $column[1].Node -ne ((@(Get-Panes) | Measure-Object Node -Maximum).Maximum)) {
        throw "The viewer is not below the terminal: $($column | Out-String)"
    }
    Shot '6-markdown-below'

    # The tab strip's New tab zone opens a tab.
    $tabs = [int](Read-State)['tabs.count']
    Invoke-Aio drag enter '700,20' --px | Out-Null
    Expect-Outline 'new_tab' ''
    Expect 'files.drop.new_tab=true'
    Shot '7-outline-new-tab'
    Drop-At '700,20' @($second) | Out-Null
    Expect 'files.dragging=false'
    Expect "tabs.count=$($tabs + 1)"
    Expect "tabs.selected=$($tabs + 1)"
    Invoke-Aio stop | Out-Null

    # Any other file starts Neovim on it in a new pane, in the file's folder.
    Start-Instance
    Invoke-Aio command pane.split | Out-Null
    $panes = @(Get-Panes)
    $sessions = [int](Read-State)['sessions.count']
    Drop-At (Zone $panes[1] 'right') @($text) | Out-Null
    Wait-For 'sessions.count' ($sessions + 1)
    Invoke-Aio wait text 'FAKE-NVIM' | Out-Null
    # The pane is narrow, so each line wraps; join the rows and drop their numbers.
    $screen = ((Invoke-Aio screen) -join '') -replace '\s*\d+\|', ''
    if ($screen -notmatch [regex]::Escape($text)) { throw "Neovim was not given the file: $screen" }
    if ($screen -notmatch [regex]::Escape("CWD=$docs")) { throw "Neovim did not start in the file's folder: $screen" }
    Shot '8-neovim-pane'

    # A folder opens a shell in it.
    $sessions = [int](Read-State)['sessions.count']
    Drop-At (Zone @(Get-Panes)[0] 'up') @($folder) | Out-Null
    Wait-For 'sessions.count' ($sessions + 1)
    $shown = ''
    for ($i = 0; $i -lt 50 -and $shown -notmatch 'some folder>'; $i++) {
        Start-Sleep -Milliseconds 100
        $shown = ((Invoke-Aio screen) -join '') -replace '\s*\d+\|', ''
    }
    if ($shown -notmatch 'some folder>') { throw "The shell did not start in the folder: $shown" }
    Shot '9-folder-shell'

    # A path that is not there is reported.
    $reply = Invoke-Aio drop '300,300' --px (Join-Path $docs 'gone.txt')
    if ("$reply" -notmatch 'not available') { throw "No notice for a missing file: $reply" }

    # Ten files open eight, and say so.
    $markdownCount = [int](Read-State)['markdown.count']
    $files = 1..10 | ForEach-Object { Join-Path $many "doc$_.md" }
    $reply = Drop-At (Zone @(Get-Panes)[0] 'left') $files
    Wait-For 'markdown.count' ($markdownCount + 8)
    if ($reply -notmatch 'first 8 of 10') { throw "No notice for the limit: $reply" }
    Shot '10-limit'
    Invoke-Aio stop | Out-Null

    # Without Neovim on PATH the drop says so and still opens what it can.
    $env:PATH = "$env:SystemRoot\System32;$(Split-Path $pwsh)"
    Start-Instance
    $sessions = [int](Read-State)['sessions.count']
    $reply = Drop-At (Zone @(Get-Panes)[0] 'right') @($text, $markdown)
    Wait-For 'markdown.count' 1
    Expect "sessions.count=$sessions"
    if ($reply -notmatch 'nvim is not on PATH') { throw "No notice for missing Neovim: $reply" }
    Shot '11-no-neovim'
    Invoke-Aio stop | Out-Null

    # A Link Program offered for files opens a non-Markdown file instead of Neovim, in a pane at the outline,
    # and pane.drop_limit caps the drop.
    Add-Content -LiteralPath $settings -Value @'
pane.drop_limit = 2
opener.echo.name = Echo
opener.echo.command = cmd.exe /d /k echo LINKPROG %1
opener.echo.placement = right
'@
    Start-Instance
    $sessions = [int](Read-State)['sessions.count']
    $reply = Drop-At (Zone @(Get-Panes)[0] 'down') @($markdown, $text, $second, $third)
    Wait-For 'sessions.count' ($sessions + 1)
    Wait-For 'markdown.count' 1
    if ($reply -match 'nvim is not on PATH') { throw "Neovim was looked for although a Link Program is offered: $reply" }
    if ($reply -notmatch 'first 2 of 4') { throw "No notice for the limit setting: $reply" }
    Invoke-Aio wait text 'LINKPROG' | Out-Null
    $screen = ((Invoke-Aio screen) -join '') -replace '\s*\d+\|', ''
    if ($screen -notmatch [regex]::Escape($text)) { throw "The Link Program was not given the file: $screen" }
    Shot '12-link-program'
    Write-Output 'PASS file drop journey'
} finally {
    $env:PATH = $savedPath
    & $ctl --name $Name stop | Out-Null
}

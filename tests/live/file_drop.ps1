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
# The tiled panes' node, x and width, left to right.
function Get-Panes {
    $found = @()
    foreach ($entry in (Read-State).GetEnumerator()) {
        if ($entry.Key -match '^pane\.(\d+)\.rect$') {
            $r = $entry.Value -split ','
            $found += [pscustomobject]@{ Node = [int]$Matches[1]; X = [double]$r[0]; Y = [double]$r[1]; W = [double]$r[2]; H = [double]$r[3] }
        }
    }
    return $found | Sort-Object X
}
function Drop-On($Pane, [string[]] $Paths) {
    $x = [int]($Pane.X + $Pane.W / 2)
    $y = [int]($Pane.Y + $Pane.H / 2)
    return (Invoke-Aio drop "$x,$y" --px @Paths) -join "`n"
}
function Start-Instance {
    Invoke-Aio launch --fresh --settings $settings | Out-Null
    Invoke-Aio wait text 'PS ' | Out-Null
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
$text = Join-Path $docs 'notes.txt'
"# Dropped`n`nBody text.`n" | Set-Content -LiteralPath $markdown -Encoding utf8
"# Second`n`nDropped on chrome.`n" | Set-Content -LiteralPath $second -Encoding utf8
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
    Invoke-Aio command pane.split | Out-Null
    Expect 'panes.count=2'
    $panes = @(Get-Panes)

    # A Markdown file opens in a Markdown pane to the right of the pane it was dropped on, between the two.
    Drop-On $panes[0] @($markdown)
    Wait-For 'markdown.count' 1
    Expect "markdown.path=$markdown"
    Expect 'panes.count=3'
    $order = @(Get-Panes)
    if ($order[1].Node -ne ($order | Measure-Object Node -Maximum).Maximum) { throw 'The viewer is not between the panes.' }
    Shot '1-markdown-between'

    # Any other file starts Neovim on it in a new pane, in the file's folder.
    $sessions = [int](Read-State)['sessions.count']
    Drop-On @(Get-Panes)[-1] @($text)
    Wait-For 'sessions.count' ($sessions + 1)
    Invoke-Aio wait text 'FAKE-NVIM' | Out-Null
    # The pane is narrow, so each line wraps; join the rows and drop their numbers.
    $screen = ((Invoke-Aio screen) -join '') -replace '\s*\d+\|', ''
    if ($screen -notmatch [regex]::Escape($text)) { throw "Neovim was not given the file: $screen" }
    if ($screen -notmatch [regex]::Escape("CWD=$docs")) { throw "Neovim did not start in the file's folder: $screen" }
    Shot '2-neovim-pane'

    # A folder opens a shell in it.
    $sessions = [int](Read-State)['sessions.count']
    Drop-On @(Get-Panes)[0] @($folder)
    Wait-For 'sessions.count' ($sessions + 1)
    $shown = ''
    for ($i = 0; $i -lt 50 -and $shown -notmatch 'some folder>'; $i++) {
        Start-Sleep -Milliseconds 100
        $shown = ((Invoke-Aio screen) -join '') -replace '\s*\d+\|', ''
    }
    if ($shown -notmatch 'some folder>') { throw "The shell did not start in the folder: $shown" }
    Shot '3-folder-shell'

    # A drop on no pane opens beside the focused one.
    $markdownCount = [int](Read-State)['markdown.count']
    Invoke-Aio drop '2,2' --px $second | Out-Null
    Wait-For 'markdown.count' ($markdownCount + 1)
    Expect "markdown.path=$second"

    # A path that is not there is reported.
    $reply = Invoke-Aio drop '300,300' --px (Join-Path $docs 'gone.txt')
    if ("$reply" -notmatch 'not available') { throw "No notice for a missing file: $reply" }

    # Ten files open eight, and say so.
    $markdownCount = [int](Read-State)['markdown.count']
    $files = 1..10 | ForEach-Object { Join-Path $many "doc$_.md" }
    $reply = Drop-On @(Get-Panes)[0] $files
    Wait-For 'markdown.count' ($markdownCount + 8)
    if ($reply -notmatch 'first 8 of 10') { throw "No notice for the limit: $reply" }
    Shot '4-limit'
    Invoke-Aio stop | Out-Null

    # Without Neovim on PATH the drop says so and still opens what it can.
    $env:PATH = "$env:SystemRoot\System32;$(Split-Path $pwsh)"
    Start-Instance
    $sessions = [int](Read-State)['sessions.count']
    $reply = Drop-On @(Get-Panes)[0] @($text, $markdown)
    Wait-For 'markdown.count' 1
    Expect "sessions.count=$sessions"
    if ($reply -notmatch 'nvim is not on PATH') { throw "No notice for missing Neovim: $reply" }
    Shot '5-no-neovim'
    Write-Output 'PASS file drop journey'
} finally {
    $env:PATH = $savedPath
    & $ctl --name $Name stop | Out-Null
}

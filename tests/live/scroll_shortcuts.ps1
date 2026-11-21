[CmdletBinding()]
param([string] $Name = 'scroll-shortcuts')
# WORK-540: Shift+PageUp/PageDown (a page) and Ctrl+PageUp/PageDown (terminal.scroll_page_length of a page)
# scroll a shell, a Markdown document and an Agent changes diff alike. Run it headless:
# AIOCTL_HEADLESS=1 pwsh -NoProfile -File tests/live/scroll_shortcuts.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$captures = Join-Path $repo "build/verify/$Name-captures"
$repoDir = Join-Path $work 'repo'
$log = Join-Path $captures 'scroll-shortcuts.txt'

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
function Note([string] $Line) { Write-Host $Line; Add-Content -LiteralPath $log -Value $Line }
function Assert([bool] $Condition, [string] $Label) {
    if (-not $Condition) { Note "FAIL $Label"; throw "FAIL $Label" }
    Note "PASS $Label"
}
function Shot([string] $Label) { Invoke-Aio capture --out (Join-Path $captures "$Label.png") | Out-Null }
# Waits until the number a reader returns stops moving.
function Settle([scriptblock] $Read) {
    $last = & $Read
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 150
        $now = & $Read
        if ($now -eq $last) { return $now }
        $last = $now
    }
    return $last
}
function Shell-Up { $v = (Read-State)['session.viewport']; if ($v -eq 'bottom') { 0 } else { [int]($v -replace 'up:', '') } }
function Markdown-At { [int](Read-State)['markdown.scroll'] }
function Changes-At { [int](Read-State)['changes.diff_scroll'] }

# Presses `$key`, waits for `$read` to settle and reports the value; `$label` names the pane and key.
function Press([string] $Key, [scriptblock] $Read, [string] $Label) {
    Invoke-Aio key $Key | Out-Null
    $value = Settle $Read
    Note "STATE $Label after ${Key}: $value"
    return $value
}

Remove-Item -LiteralPath $work, $captures -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $captures, $repoDir | Out-Null
$doc = Join-Path $work 'long.md'
(1..400 | ForEach-Object { "Paragraph $_ of a long document." }) -join "`n`n" | Set-Content -LiteralPath $doc -Encoding utf8

# A repository whose one file changes on every line, so its uncommitted diff is many pages long.
function Git { $p = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $out = & git.exe -C $repoDir -c user.name=journey -c user.email=journey@example.invalid @args 2>&1; $code = $LASTEXITCODE; $ErrorActionPreference = $p; if ($code -ne 0) { throw "git $($args -join ' '): $out" } }
Git init -q
Set-Content -LiteralPath (Join-Path $repoDir 'big.txt') -Value (1..400 | ForEach-Object { "old line $_" })
Git add -A
Git commit -q -m initial
Set-Content -LiteralPath (Join-Path $repoDir 'big.txt') -Value (1..400 | ForEach-Object { "new line $_" })

$settings = Join-Path $work 'settings.ini'
"control.enabled = true`ncursor.blink = false`nshell.command = pwsh.exe -NoLogo -NoProfile -NoExit`n" | Set-Content -LiteralPath $settings -Encoding utf8
Invoke-Aio launch --fresh --settings $settings | Out-Null
try {
    # The prompt is whatever the user's profile draws, so readiness is a marker the shell prints.
    Start-Sleep -Seconds 3
    Invoke-Aio run "Write-Output ('READY_' + 'SHELL')" | Out-Null
    Invoke-Aio wait text 'READY_SHELL' | Out-Null
    Invoke-Aio focus in | Out-Null

    # Shell: the keys a user already knows.
    Invoke-Aio run '1..300 | % { "line $_" }' | Out-Null
    Invoke-Aio wait text 'line 300' | Out-Null
    $rows = [int]((Read-State)['grid.size'] -split 'x')[1]
    Note "STATE shell grid rows: $rows"
    Assert ((Shell-Up) -eq 0) 'shell starts at the bottom'
    Shot 'shell-before'
    $page = Press 'Shift+PageUp' { Shell-Up } 'shell'
    Assert ($page -eq $rows - 1) "shell Shift+PageUp scrolls one page ($page rows of $rows)"
    Shot 'shell-after-shift-pageup'
    $back = Press 'Shift+PageDown' { Shell-Up } 'shell'
    Assert ($back -eq 0) 'shell Shift+PageDown returns to the bottom'
    $half = Press 'Ctrl+PageUp' { Shell-Up } 'shell'
    Assert ($half -gt 0 -and $half -lt $page) "shell Ctrl+PageUp scrolls part of a page ($half rows)"
    $back = Press 'Ctrl+PageDown' { Shell-Up } 'shell'
    Assert ($back -eq 0) 'shell Ctrl+PageDown returns to the bottom'

    # Markdown: the same four keys.
    Invoke-Aio type "& '$aio' pane.open_markdown '$doc'" | Out-Null
    Invoke-Aio key Enter | Out-Null
    for ($i = 0; $i -lt 50 -and (Read-State)['markdown.count'] -ne '1'; $i++) { Start-Sleep -Milliseconds 100 }
    Invoke-Aio command pane.focus_next | Out-Null
    Assert ((Read-State)['markdown.active'] -eq 'true') 'the document has the keyboard'
    Assert ((Markdown-At) -eq 0) 'the document starts at the top'
    Shot 'markdown-before'
    $mpage = Press 'Shift+PageDown' { Markdown-At } 'markdown'
    Assert ($mpage -gt 0) "markdown Shift+PageDown scrolls a page ($mpage)"
    Shot 'markdown-after-shift-pagedown'
    $back = Press 'Shift+PageUp' { Markdown-At } 'markdown'
    Assert ($back -eq 0) 'markdown Shift+PageUp returns to the top'
    $mhalf = Press 'Ctrl+PageDown' { Markdown-At } 'markdown'
    Assert ($mhalf -gt 0 -and $mhalf -lt $mpage) "markdown Ctrl+PageDown scrolls part of a page ($mhalf)"
    $back = Press 'Ctrl+PageUp' { Markdown-At } 'markdown'
    Assert ($back -eq 0) 'markdown Ctrl+PageUp returns to the top'
    Invoke-Aio command pane.close | Out-Null
    for ($i = 0; $i -lt 50 -and (Read-State)['markdown.count'] -ne '0'; $i++) { Start-Sleep -Milliseconds 100 }

    # Agent changes: a pane on the shell's repository, uncommitted changes.
    Invoke-Aio run "cd '$repoDir'; Write-Output ('READY_' + 'REPO')" | Out-Null
    Invoke-Aio wait text 'READY_REPO' | Out-Null
    Invoke-Aio command pane.agent_changes | Out-Null
    for ($i = 0; $i -lt 100; $i++) {
        $s = Read-State
        if ($s['changes.active'] -eq 'true' -and $s['changes.loaded'] -eq 'true' -and $s['changes.settled'] -eq 'true') { break }
        Start-Sleep -Milliseconds 100
    }
    Note "STATE changes scope: $($s['changes.scope']) files: $($s['changes.files'])"
    Assert ($s['changes.active'] -eq 'true') 'the Agent changes pane has the keyboard'
    Assert ((Changes-At) -eq 0) 'the diff starts at the top'
    Shot 'changes-before'
    $cpage = Press 'Shift+PageDown' { Changes-At } 'changes'
    Assert ($cpage -gt 0) "changes Shift+PageDown scrolls a page ($cpage)"
    Shot 'changes-after-shift-pagedown'
    $back = Press 'Shift+PageUp' { Changes-At } 'changes'
    Assert ($back -eq 0) 'changes Shift+PageUp returns to the top'
    $chalf = Press 'Ctrl+PageDown' { Changes-At } 'changes'
    Assert ($chalf -gt 0 -and $chalf -lt $cpage) "changes Ctrl+PageDown scrolls part of a page ($chalf)"
    $back = Press 'Ctrl+PageUp' { Changes-At } 'changes'
    Assert ($back -eq 0) 'changes Ctrl+PageUp returns to the top'
    # The key only this pane type had keeps working.
    $bare = Press 'PageDown' { Changes-At } 'changes'
    Assert ($bare -gt 0) "changes bare PageDown still scrolls ($bare)"
} catch { Shot 'failure'; throw } finally {
    & $ctl --name $Name stop | Out-Null
}

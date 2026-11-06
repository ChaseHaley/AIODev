[CmdletBinding()]
param([string] $Name = 'markdown-find')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$aio = Join-Path $repo 'build/aio.exe'
$work = Join-Path $repo "build/verify/$Name-files"
$captures = Join-Path $repo "build/verify/$Name-captures"
$settings = Join-Path $work 'settings.ini'

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
function Expect([string] $Pair) { Invoke-Aio expect state $Pair | Out-Null }
function Wait-For([string] $Key, [string] $Value) {
    for ($i = 0; $i -lt 50; $i++) {
        if ((Read-State)[$Key] -eq $Value) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for $Key=$Value; saw $((Read-State)[$Key])."
}
function Point([string] $Button) {
    $rect = (Read-State)["find.$Button"] -split ',' | ForEach-Object { [double]$_ }
    return "$([int]($rect[0]+$rect[2]/2)),$([int]($rect[1]+$rect[3]/2))"
}
function Step-Find([string] $Button) { Invoke-Aio mouse click (Point $Button) --px | Out-Null }
function Shot([string] $Label) {
    Invoke-Aio capture --out (Join-Path $captures "$Label.png") | Out-Null
}

Remove-Item -LiteralPath $work, $captures -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $captures | Out-Null
$plan = Join-Path $work 'plan.md'
# Eleven matches for 'entry 5': 5 and 50 through 59. Numbers past the window's height force scrolling.
$lines = @('# Find target', '', 'A **styled needle** and a [linked needle](https://example.invalid), Needle again.', '')
foreach ($i in 1..120) { $lines += "- entry $i" }
$lines | Set-Content -LiteralPath $plan -Encoding utf8
@"
control.enabled = true
shell.command = pwsh.exe -NoLogo -NoProfile -NoExit
cursor.blink = false
window.columns = 170
window.rows = 40
"@ | Set-Content -LiteralPath $settings -Encoding utf8

Invoke-Aio launch --fresh --settings $settings | Out-Null
try {
    Invoke-Aio wait text 'PS ' | Out-Null
    Invoke-Aio type "& '$aio' pane.open_markdown --focus '$plan'" | Out-Null
    Invoke-Aio key Enter | Out-Null
    Wait-For 'markdown.count' 1
    Expect 'markdown.active=true'
    Wait-For 'markdown.state' 'Loaded'

    # Opening, counting and stepping both ways, by key and by button.
    Invoke-Aio key Ctrl+Shift+F | Out-Null
    Expect 'find.open=true'
    Expect 'find.count=0 of 0'
    Invoke-Aio type 'entry 5' | Out-Null
    Expect 'find.query=entry 5'
    Wait-For 'find.count' '0 of 11'
    Expect 'find.matches=11 matches'
    Expect 'markdown.scroll=0'
    Shot 'matches-dark'

    # Enter reads top down. The first match already shows, so the view stays put.
    Invoke-Aio key Enter | Out-Null
    Expect 'find.count=1 of 11'
    Expect 'markdown.scroll=0'
    # The next one is off screen and scrolls into view.
    Invoke-Aio key Enter | Out-Null
    Expect 'find.count=2 of 11'
    $reached = [int](Read-State)['markdown.scroll']
    if ($reached -le 0) { throw 'The selected match did not scroll into view.' }
    Shot 'selected-dark'
    # A match that already shows does not move the view.
    Invoke-Aio key Enter | Out-Null
    Expect 'find.count=3 of 11'
    Expect "markdown.scroll=$reached"
    Invoke-Aio key Shift+Enter | Out-Null
    Expect 'find.count=2 of 11'
    Invoke-Aio key Shift+Enter | Out-Null
    Expect 'find.count=1 of 11'
    # The arrows move the way they point and wrap.
    Step-Find older
    Expect 'find.count=11 of 11'
    Step-Find newer
    Expect 'find.count=1 of 11'

    # A mismatched release neither navigates nor changes tabs.
    $before = Read-State
    Invoke-Aio mouse down (Point older) --px | Out-Null
    Invoke-Aio mouse up '5,5' --px | Out-Null
    Expect 'find.count=1 of 11'
    Expect "tabs.count=$($before['tabs.count'])"

    # Keys edit the query and none scroll the document.
    Invoke-Aio key Ctrl+A | Out-Null
    Invoke-Aio type 'absent' | Out-Null
    Wait-For 'find.count' '0 of 0'
    Expect 'find.query=absent'
    Expect 'find.matches=No matches'
    Shot 'none-dark'
    Step-Find older
    Expect 'find.count=0 of 0'

    # Closing keeps the view; history comes back on Up and Down.
    $kept = (Read-State)['markdown.scroll']
    Invoke-Aio key Esc | Out-Null
    Expect 'find.open=false'
    Expect "markdown.scroll=$kept"
    Invoke-Aio key Ctrl+Shift+F | Out-Null
    Expect 'find.query='
    Invoke-Aio key Up | Out-Null
    Expect 'find.query=absent'
    Invoke-Aio key Up | Out-Null
    Expect 'find.query=entry 5'
    Invoke-Aio key Down | Out-Null
    Invoke-Aio key Down | Out-Null
    Expect 'find.query='

    # Case sensitivity and expressions, on their usual keys.
    Invoke-Aio type 'NEEDLE' | Out-Null
    Wait-For 'find.count' '0 of 3'
    Invoke-Aio key Alt+C | Out-Null
    Expect 'find.case_sensitive=true'
    Wait-For 'find.matches' 'No matches'
    Invoke-Aio key Alt+C | Out-Null
    Wait-For 'find.count' '0 of 3'
    Invoke-Aio key Ctrl+A | Out-Null
    Invoke-Aio type 'entry 5\d$' | Out-Null
    Invoke-Aio key Alt+R | Out-Null
    Expect 'find.regex=true'
    Wait-For 'find.matches' '10 matches'
    Invoke-Aio key Enter | Out-Null
    Expect 'find.count=1 of 10'
    Shot 'regex-dark'
    Invoke-Aio key Ctrl+A | Out-Null
    Invoke-Aio type '(' | Out-Null
    Wait-For 'find.count' 'Invalid expression'
    Invoke-Aio key Ctrl+A | Out-Null
    Invoke-Aio type 'entry 5\d$' | Out-Null
    Wait-For 'find.matches' '10 matches'

    # A click on the document hands it the keyboard; the bar and its matches stay.
    Invoke-Aio key Enter | Out-Null
    Expect 'find.count=1 of 10'
    $rect = (Read-State)['find.close'] -split ',' | ForEach-Object { [double]$_ }
    Invoke-Aio mouse click "$([int]($rect[0]-200)),$([int]($rect[1]+300))" --px | Out-Null
    Expect 'find.focused=false'
    Expect 'find.open=true'
    Expect 'find.count=1 of 10'
    Shot 'blurred-dark'
    # Keys now reach the document, including Escape.
    $scroll = [int](Read-State)['markdown.scroll']
    Invoke-Aio key Home | Out-Null
    if ([int](Read-State)['markdown.scroll'] -ge $scroll) { throw 'Home did not reach the document.' }
    Invoke-Aio key Esc | Out-Null
    Expect 'find.open=true'
    Invoke-Aio key Ctrl+Shift+F | Out-Null
    Expect 'find.focused=true'
    Step-Find close
    Expect 'find.open=false'
    Invoke-Aio command terminal.find | Out-Null
    Invoke-Aio key Alt+R | Out-Null
    Expect 'find.regex=false'
    Invoke-Aio key Esc | Out-Null

    # The bar follows the rewritten file and keeps its place.
    Invoke-Aio key Ctrl+Shift+F | Out-Null
    Invoke-Aio type 'entry 5' | Out-Null
    Wait-For 'find.count' '0 of 11'
    Invoke-Aio key Enter | Out-Null
    Expect 'find.count=1 of 11'
    ($lines + '- entry 500') | Set-Content -LiteralPath $plan -Encoding utf8
    Wait-For 'find.count' '1 of 12'
    Invoke-Aio key Esc | Out-Null

    # Find is scoped to the focused pane, which closes it on the way out.
    Invoke-Aio key Ctrl+Shift+F | Out-Null
    Invoke-Aio type 'entry 5' | Out-Null
    Wait-For 'find.count' '0 of 12'
    Invoke-Aio command pane.focus_next | Out-Null
    Expect 'markdown.active=false'
    Expect 'find.open=false'
    Invoke-Aio run 'Write-Output TERMINAL_ONLY' | Out-Null
    Invoke-Aio key Ctrl+Shift+F | Out-Null
    Invoke-Aio type 'TERMINAL_ONLY' | Out-Null
    Invoke-Aio key Esc | Out-Null
    Invoke-Aio command pane.focus_next | Out-Null
    Expect 'markdown.active=true'

    # Themes and DPI.
    $live = Join-Path (Join-Path $repo "build/verify/$Name") 'settings.ini'
    foreach ($theme in @('studio-dark', 'studio-light')) {
        $text = [regex]::Replace([IO.File]::ReadAllText($live), '(?m)^theme\.name\s*=.*\r?\n?', '')
        [IO.File]::WriteAllText($live, $text.TrimEnd() + "`ntheme.name = $theme`n")
        Invoke-Aio command settings.reload | Out-Null
        foreach ($dpi in @(96, 192)) {
            Invoke-Aio dpi $dpi | Out-Null
            Invoke-Aio key Ctrl+Shift+F | Out-Null
            Invoke-Aio key Ctrl+A | Out-Null
            Invoke-Aio type 'needle' | Out-Null
            Wait-For 'find.count' '0 of 3'
            Invoke-Aio key Enter | Out-Null
            Expect 'find.count=1 of 3'
            Shot "$theme-$dpi"
            Invoke-Aio key Esc | Out-Null
        }
    }
    Write-Output 'PASS markdown find: counts, wrap, reveal, history, case and regex, blur, close, reload, pane scope, theme and DPI'
} finally {
    & $ctl --name $Name stop | Out-Null
}

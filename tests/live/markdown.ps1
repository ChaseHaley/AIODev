[CmdletBinding()]
param([string] $Name = 'markdown')
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
function Shot([string] $Label) {
    Invoke-Aio capture --out (Join-Path $captures "$Label.png") | Out-Null
}
function In-Shell([string] $Command) {
    Invoke-Aio type $Command | Out-Null
    Invoke-Aio key Enter | Out-Null
}
# Puts the keyboard back in the terminal, whichever pane holds it.
function Focus-Terminal {
    for ($i = 0; $i -lt 6; $i++) {
        if ((Read-State)['markdown.active'] -eq 'false') { return }
        Invoke-Aio command pane.focus_next | Out-Null
    }
    throw 'No terminal pane took focus.'
}

Remove-Item -LiteralPath $work, $captures -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $captures | Out-Null
$plan = Join-Path $work 'plan.md'
$notes = Join-Path $work 'notes.md'
$first = Join-Path $work 'first.md'
@'
# Migration plan

This plan was **written by an agent** and covers the *database* move, with `inline code`, ~~old ideas~~, a [web link](https://example.invalid/docs) and [the notes](notes.md).

## Steps

1. Export the current schema
2. Transform rows in batches
   - Validate foreign keys
   - Rebuild the indexes when the batch is complete and everything has been checked twice over
3. Cut over

### Progress

- [x] Write the export script
- [ ] Dry run on staging

> Run the dry run outside business hours.
>
> > Nested caveat about replicas.

## Results

| Table | Rows | Status | Notes |
|:------|-----:|:------:|-------|
| users | 120,422 | **done** | Migrated with no conflicts |
| orders | 9,881,120 | running | Long tail of historical rows that need a slower path and manual review |

```odin
main :: proc() {
	fmt.println("hello")
}
```

---

Final paragraph with a hard break\
right here.
'@ | Set-Content -LiteralPath $plan -Encoding utf8
"# Notes`n`nOpened from a link.`n" | Set-Content -LiteralPath $notes -Encoding utf8
"# First`n`nOpened by a printed path.`n" | Set-Content -LiteralPath $first -Encoding utf8
@"
control.enabled = true
shell.command = pwsh.exe -NoLogo -NoProfile -NoExit
cursor.blink = false
window.columns = 170
window.rows = 50
"@ | Set-Content -LiteralPath $settings -Encoding utf8

Invoke-Aio launch --fresh --settings $settings | Out-Null
try {
    Invoke-Aio wait text 'PS ' | Out-Null
    In-Shell "Set-Location '$work'"

    # The CLI: a relative path, focus stays with the agent's terminal.
    In-Shell "& '$aio' pane.open_markdown plan.md"
    Wait-For 'markdown.count' 1
    Expect 'markdown.active=false'
    Expect 'tab.1.panes=2'
    Invoke-Aio command pane.focus_next | Out-Null
    Expect 'markdown.active=true'
    Expect 'markdown.state=Loaded'
    Expect "markdown.path=$plan"
    Shot 'dark-96'

    # Reading keys and the wheel; the document is taller than the window at this DPI.
    Invoke-Aio dpi 192 | Out-Null
    $tall = Read-State
    if ([int]$tall['markdown.total'] -le 0) { throw 'The document did not lay out.' }
    Invoke-Aio key End | Out-Null
    $bottom = [int](Read-State)['markdown.scroll']
    if ($bottom -le 0) { throw 'End did not scroll.' }
    Invoke-Aio key Home | Out-Null
    Expect 'markdown.scroll=0'
    Invoke-Aio key PageDown | Out-Null
    if ([int](Read-State)['markdown.scroll'] -le 0) { throw 'PageDown did not scroll.' }
    Invoke-Aio key Home | Out-Null
    Shot 'dark-192'
    Invoke-Aio dpi 96 | Out-Null

    # Selection and copy from the document's plain text.
    Invoke-Aio key Ctrl+a | Out-Null
    $selected = (Read-State)['markdown.selection']
    if ($selected -notmatch 'Migration plan') { throw "Select all missed the heading: $selected" }
    if ($selected -match '\*\*|```') { throw 'Selection carries Markdown syntax.' }
    Invoke-Aio key Esc | Out-Null
    Expect 'markdown.selection='

    # A second copy of the same file reuses its pane.
    Focus-Terminal
    In-Shell "& '$aio' pane.open_markdown '$plan'"
    Start-Sleep -Milliseconds 500
    Expect 'markdown.count=1'

    # Ctrl+click on a printed path opens a split beside the terminal, not the Windows association.
    In-Shell 'Clear-Host'
    In-Shell "[Console]::WriteLine('$first')"
    Invoke-Aio wait text 'first.md' | Out-Null
    $row = -1
    $screen = Invoke-Aio screen
    foreach ($line in $screen) {
        if ($line -match '^\s*(\d+)\|[A-Za-z]:\\') { $row = [int]$Matches[1]; break }
    }
    if ($row -lt 0) { throw "The printed path was not found on screen: $screen" }
    Invoke-Aio mouse click "4,$row" --mods Ctrl | Out-Null
    Wait-For 'markdown.count' 2
    Expect 'markdown.active=true'
    Expect "markdown.path=$first"
    Shot 'three-panes'

    # The file follows rewrites, disappears and comes back, all without a command.
    $before = [int](Read-State)['markdown.total']
    "# First`n`nRewritten.`n`nA second paragraph after the rewrite.`n" | Set-Content -LiteralPath $first -Encoding utf8
    for ($i = 0; $i -lt 30 -and [int](Read-State)['markdown.total'] -le $before; $i++) { Start-Sleep -Milliseconds 100 }
    if ([int](Read-State)['markdown.total'] -le $before) { throw 'The pane did not follow the rewrite.' }
    Remove-Item -LiteralPath $first
    Wait-For 'markdown.state' 'Missing'
    Shot 'missing'
    "# First`n`nBack again.`n" | Set-Content -LiteralPath $first -Encoding utf8
    Wait-For 'markdown.state' 'Loaded'

    # An ordinary pane: swaps, zooms and splits.
    Invoke-Aio command pane.swap_previous | Out-Null
    Expect 'markdown.active=true'
    Invoke-Aio command pane.swap_next | Out-Null
    Invoke-Aio command pane.zoom | Out-Null
    Expect 'markdown.active=true'
    Shot 'zoomed'
    Invoke-Aio command pane.zoom | Out-Null
    Invoke-Aio command pane.split_down | Out-Null
    Expect 'markdown.active=false'
    Invoke-Aio command pane.close | Out-Null
    Expect 'markdown.count=2'

    # A move between workspaces keeps the document and the runtimes.
    $sessions = (Read-State)['sessions.count']
    Invoke-Aio command pane.focus_previous | Out-Null
    if ((Read-State)['markdown.active'] -ne 'true') { Invoke-Aio command pane.focus_previous | Out-Null }
    Expect 'markdown.active=true'
    $moved = (Read-State)['markdown.path']
    Invoke-Aio command pane.move_new_workspace | Out-Null
    if ((Read-State)['rename.open'] -eq 'true') { Invoke-Aio key Enter | Out-Null }
    Start-Sleep -Milliseconds 700
    Expect 'markdown.count=2'
    Expect "sessions.count=$sessions"

    # Light theme.
    Add-Content -LiteralPath (Join-Path (Join-Path $repo "build/verify/$Name") 'settings.ini') "`ntheme.name = studio-light"
    Invoke-Aio command settings.reload | Out-Null
    Start-Sleep -Milliseconds 300
    Shot 'light-moved'

    # Layout restore reopens the documents.
    # aioctl's launch waits on a focused terminal, so the moved document gets one beside it.
    Invoke-Aio command pane.split_down | Out-Null
    Invoke-Aio stop | Out-Null
    Copy-Item -LiteralPath (Join-Path (Join-Path $repo "build/verify/$Name") 'settings.ini') -Destination $settings -Force
    Invoke-Aio launch --settings $settings --keep-layout | Out-Null
    Wait-For 'markdown.count' 2
    Shot 'restored'
    $state = Read-State
    Write-Output "PASS markdown journey; restored $($state['markdown.count']) documents"
} finally {
    & $ctl --name $Name stop | Out-Null
}

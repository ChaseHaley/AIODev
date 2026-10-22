[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')]
    [string] $Name = 'work138-find-navigation',
    [switch] $NoShots
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$directory = Join-Path $repo "build/verify/$Name"
$noMatches = '0 of 0 '+[char]0xB7+' No matches'
function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}
function Read-State {
    $lines = & $ctl --name $Name state
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect find state.' }
    $state = @{}
    foreach ($line in $lines) { $pair = $line -split '=', 2; $state[$pair[0]] = $pair[1].Trim('"') }
    return $state
}
function Point([string] $Button) {
    $rect = (Read-State)["find.$Button"] -split ',' | ForEach-Object { [double]$_ }
    return "$([int]($rect[0]+$rect[2]/2)),$([int]($rect[1]+$rect[3]/2))"
}
function Step-Find([string] $Button) { Invoke-Aio mouse click (Point $Button) --px }
function Shot([string] $Label) {
    if ($NoShots) { return }
    & (Join-Path $repo 'tools/win32.ps1') -Name $Name -Frame -Shot (Join-Path $directory "$Label.png")
    if ($LASTEXITCODE -ne 0) { throw 'Find screenshot failed.' }
}
function Set-Option([string] $Key, [string] $Value) {
    $path = Join-Path $directory 'settings.ini'
    $text = [IO.File]::ReadAllText($path)
    $text = [regex]::Replace($text, '(?m)^'+[regex]::Escape($Key)+'\s*=.*\r?\n?', '')
    [IO.File]::WriteAllText($path, $text.TrimEnd()+"`n$Key = $Value`n")
}
# launch always passes --no-activate. No desktop pointer, clipboard or foreground input is used.
Invoke-Aio launch --fresh
try {
    Invoke-Aio doctor
    Invoke-Aio run '1..300 | ForEach-Object { "WORK138_line $_" }'
    Invoke-Aio key Ctrl+Shift+F
    Invoke-Aio expect state 'find.count=0 of 0'
    Invoke-Aio type 'WORK138_line 5'
    Invoke-Aio expect state 'find.matches=11 matches'
    Invoke-Aio expect state 'find.count=0 of 11'
    Step-Find older
    Invoke-Aio expect state 'find.count=1 of 11'
    if ((Read-State)['session.viewport'] -eq 'bottom') { throw 'Older match did not scroll into history.' }
    Step-Find older
    Invoke-Aio expect state 'find.count=2 of 11'
    Step-Find newer
    Invoke-Aio expect state 'find.count=1 of 11'
    Step-Find newer
    Invoke-Aio expect state 'find.count=11 of 11'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'find.count=1 of 11'
    Invoke-Aio key Shift+Enter
    Invoke-Aio expect state 'find.count=11 of 11'
    Invoke-Aio key Up
    Invoke-Aio expect state 'find.count=1 of 11'
    Invoke-Aio key Down
    Invoke-Aio expect state 'find.count=11 of 11'
    # A mismatched release, including over title chrome, must neither navigate nor change tabs.
    $before = Read-State
    Invoke-Aio mouse down (Point older) --px
    Shot pressed-dark
    Invoke-Aio mouse up '5,5' --px
    Invoke-Aio expect state 'find.count=11 of 11'
    Invoke-Aio expect state "tabs.count=$($before['tabs.count'])"
    Invoke-Aio type 9
    Invoke-Aio expect state 'find.query=WORK138_line 59'
    Invoke-Aio expect state 'find.count=0 of 1'
    Step-Find older
    Invoke-Aio expect state 'find.count=1 of 1'
    Step-Find older
    Invoke-Aio expect state 'find.count=1 of 1'
    Shot selected-dark
    Invoke-Aio key Ctrl+A
    Invoke-Aio type 'WORK138_absent_query'
    Invoke-Aio expect state 'find.matches=No matches'
    Invoke-Aio expect state "find.count=$noMatches"
    Step-Find older
    Step-Find newer
    Invoke-Aio expect state "find.count=$noMatches"
    Shot disabled-dark
    Invoke-Aio key Esc
    Invoke-Aio expect state find.open=false
    Invoke-Aio expect state session.viewport=bottom
    # Theme/DPI snapshots are translated app control evidence, not native monitor-transition proof.
    foreach ($theme in @('studio','tide','ember')) {
        foreach ($mode in @('dark','light')) {
            Set-Option theme.name $theme
            Set-Option theme.mode $mode
            Invoke-Aio command settings.reload
            foreach ($dpi in @(96,144,192)) {
                Invoke-Aio dpi $dpi
                Invoke-Aio resize 40x24
                Invoke-Aio command terminal.find
                Invoke-Aio type 'WORK138_line 5'
                Invoke-Aio expect state 'find.count=0 of 11'
                Invoke-Aio mouse move (Point older) --px
                Shot "$theme-$mode-dpi$dpi-narrow"
                Step-Find older
                Invoke-Aio expect state 'find.count=1 of 11'
                Invoke-Aio key Esc
            }
        }
    }
    Invoke-Aio dpi 96
    Invoke-Aio resize 120x32
    Invoke-Aio command pane.split_right
    Invoke-Aio wait text 'PS '
    Invoke-Aio run 'Write-Output WORK138_OTHER_PANE'
    Invoke-Aio command terminal.find
    Invoke-Aio type 'WORK138_line 5'
    Invoke-Aio expect state 'find.matches=No matches'
    Invoke-Aio command pane.focus_left
    Invoke-Aio expect state find.open=false
    Invoke-Aio command terminal.find
    Invoke-Aio type 'WORK138_line 5'
    Invoke-Aio expect state 'find.count=0 of 11'
    Step-Find older
    Invoke-Aio expect state 'find.count=1 of 11'
    Invoke-Aio key Ctrl+Shift+F
    Invoke-Aio expect state find.open=false
    Invoke-Aio expect state session.viewport=bottom
    Write-Output 'PASS find count, pointer/key wrap, disabled controls, retained query focus, narrow DPI/theme and focused-pane scope'
} finally {
    Invoke-Aio stop
}

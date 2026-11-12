[CmdletBinding()]
param()

# WORK-408: a clashing shortcut opens a conflict chain in Settings and in the palette. Covers the owner's
# example (Find, Show Command Palette, Copy) saved in one write and undone in one write, a swap, and
# Escape cancelling a recording before the chain, with dark and light screenshots of each state.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'keybinding-conflicts'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'
$shots = Join-Path $repo 'build/keybinding-conflicts'
New-Item -ItemType Directory -Force $shots | Out-Null

function Invoke-Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out | Write-Output
}

function Read-State {
    $state = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $state[$pair[0]] = $pair[1].Trim('"') }
    }
    return $state
}

function Assert-Value($Actual, $Expected, [string] $Label) {
    if ($Actual -ne $Expected) { throw "$Label expected '$Expected', observed '$Actual'" }
    Write-Output "PASS $Label"
}

function Shot([string] $Label) {
    Invoke-Aio capture --out (Join-Path $shots "$Label.png") | Out-Null
}

function Set-Theme([string] $Theme) {
    $text = [IO.File]::ReadAllText($path)
    $pattern = '(?m)^theme\.name\s*=.*$'
    if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, "theme.name = $Theme") }
    else { $text += "`ntheme.name = $Theme`n" }
    [IO.File]::WriteAllText($path, $text)
    Invoke-Aio command settings.reload | Out-Null
    Invoke-Aio expect state "theme.name=$Theme" | Out-Null
}

# Clicks the remove mark of the chip `$Label` on the row of `$Key`, from the surface's chip report.
function Remove-Chip([string] $Surface, [string] $Key, [string] $Label) {
    foreach ($chip in ((Read-State)["$Surface.chain.chips"] -split ';')) {
        $fields = $chip -split '\|'
        if ($fields[0] -ne $Key -or $fields[1] -ne $Label) { continue }
        $remove = $fields[4] -split ','
        $x = [double] $remove[0] + [double] $remove[2] / 2
        $y = [double] $remove[1] + [double] $remove[3] / 2
        Invoke-Aio mouse click "$([int]$x),$([int]$y)" --px | Out-Null
        return
    }
    throw "No $Label chip on $Key in the $Surface chain."
}

function Click-Rect([string] $Rect) {
    $r = $Rect -split ','
    $x = [double] $r[0] + [double] $r[2] / 2
    $y = [double] $r[1] + [double] $r[3] / 2
    Invoke-Aio mouse click "$([int]$x),$([int]$y)" --px | Out-Null
}

function Assert-Saved([string] $Label) {
    $text = [IO.File]::ReadAllText($path)
    foreach ($line in 'keys.terminal.find = Ctrl+Shift+P', 'keys.app.command_palette = Ctrl+Shift+C',
        'keys.edit.copy = Ctrl+Insert') {
        if ($text -notmatch "(?m)^$([regex]::Escape($line))\r?$") { throw "$Label did not save '$line'." }
    }
    Write-Output "PASS $Label saves all three shortcuts"
}

$find = 'keys.terminal.find'
$palette = 'keys.app.command_palette'
$copy = 'keys.edit.copy'

Invoke-Aio launch --fresh
try {
    foreach ($mode in 'dark', 'light') {
        Set-Theme "studio-$mode"
        $before = [IO.File]::ReadAllText($path)

        # Settings: the owner's example.
        Invoke-Aio key 'Ctrl+,' | Out-Null
        Invoke-Aio type $find | Out-Null
        Assert-Value (Read-State)['settings.key'] $find "$mode Settings selects Find"
        Invoke-Aio key Enter Enter Ctrl+Shift+P | Out-Null
        Assert-Value (Read-State)['settings.used_by'] 'Used by Show Command Palette' "$mode Settings names the owner"
        Assert-Value (Read-State)['settings.chain'] '' "$mode recording alone opens no chain"
        Shot "settings-note-$mode"
        Invoke-Aio key Enter | Out-Null
        Assert-Value (Read-State)['settings.chain'] "$find,$palette" "$mode Enter opens the chain"
        Assert-Value (Read-State)['settings.chain.context'] 'Ctrl+Shift+P is used twice. Change one to save.' `
            "$mode chain line"
        Shot "settings-chain-two-$mode"
        Invoke-Aio key Down Enter Ctrl+Shift+C | Out-Null
        Assert-Value (Read-State)['settings.used_by'] 'Used by Copy' "$mode re-recording names Copy"
        Shot "settings-chain-recording-$mode"
        Invoke-Aio key Enter | Out-Null
        Assert-Value (Read-State)['settings.chain'] "$find,$palette,$copy" "$mode Copy is appended"
        Assert-Value ([IO.File]::ReadAllText($path)) $before "$mode nothing saves while a clash remains"
        Shot "settings-chain-three-$mode"
        Remove-Chip settings $copy 'Ctrl+Shift+C'
        Assert-Value (Read-State)['settings.chain'] '' "$mode removing the last clash closes the chain"
        Assert-Saved "$mode Settings"
        Assert-Value (Read-State)['settings.filter'] $find "$mode Settings keeps its search"
        Assert-Value (Read-State)['settings.key'] $find "$mode Settings keeps its selection"
        if (-not (Read-State)['notice.shortcut_undo']) { throw 'No Saved notice.' }
        Shot "settings-saved-$mode"
        Invoke-Aio key Ctrl+Z | Out-Null
        Assert-Value ([IO.File]::ReadAllText($path)) $before "$mode Ctrl+Z restores the file in one write"

        # Settings: Escape cancels the recording first, then the chain.
        Invoke-Aio key Enter Enter Ctrl+Shift+P Enter Down Enter Ctrl+Shift+K | Out-Null
        Assert-Value (Read-State)['settings.chain.recording'] 'true' "$mode a chip records"
        Invoke-Aio key Esc | Out-Null
        Assert-Value (Read-State)['settings.chain.recording'] 'false' "$mode Escape ends only the recording"
        Assert-Value (Read-State)['settings.chain'] "$find,$palette" "$mode the chain stays"
        Invoke-Aio key Esc | Out-Null
        Assert-Value (Read-State)['settings.chain'] '' "$mode Escape again drops the chain"
        Assert-Value ([IO.File]::ReadAllText($path)) $before "$mode a dropped chain saves nothing"

        # Settings: a swap resolves itself.
        Invoke-Aio key Enter Enter Ctrl+Shift+P Enter Down Enter Ctrl+Shift+F Enter | Out-Null
        Assert-Value (Read-State)['settings.chain'] '' "$mode the swap saves"
        $text = [IO.File]::ReadAllText($path)
        if ($text -notmatch '(?m)^keys\.terminal\.find = Ctrl\+Shift\+P\r?$' -or
            $text -notmatch '(?m)^keys\.app\.command_palette = Ctrl\+Shift\+F\r?$') { throw 'Swap not saved.' }
        Write-Output "PASS $mode swap saves both"
        Invoke-Aio key Ctrl+Z | Out-Null
        Assert-Value ([IO.File]::ReadAllText($path)) $before "$mode the swap undoes"
        Invoke-Aio command tab.close | Out-Null

        # Palette: the owner's example, undone by the notice's Undo button.
        Invoke-Aio command app.palette_commands | Out-Null
        Invoke-Aio type 'Find' | Out-Null
        for ($i = 0; $i -lt 12 -and (Read-State)['palette.item'] -ne 'terminal.find'; $i++) {
            Invoke-Aio key Down | Out-Null
        }
        Assert-Value (Read-State)['palette.item'] 'terminal.find' "$mode palette selects Find"
        $selected = (Read-State)['palette.selected']
        Invoke-Aio key Ctrl+Enter Enter Ctrl+Shift+P | Out-Null
        Assert-Value (Read-State)['palette.used_by'] 'Used by Show Command Palette' "$mode palette names the owner"
        Shot "palette-note-$mode"
        Invoke-Aio key Enter | Out-Null
        Assert-Value (Read-State)['palette.edit'] 'Chain' "$mode palette opens the chain"
        Assert-Value (Read-State)['palette.chain'] "$find,$palette" "$mode palette chain rows"
        Invoke-Aio key Down Enter Ctrl+Shift+C Enter | Out-Null
        Assert-Value (Read-State)['palette.chain'] "$find,$palette,$copy" "$mode palette appends Copy"
        Assert-Value (Read-State)['palette.chain.context'] 'Ctrl+Shift+C is used twice. Change one to save.' `
            "$mode palette chain line"
        Shot "palette-chain-$mode"
        Remove-Chip palette $copy 'Ctrl+Shift+C'
        Assert-Value (Read-State)['palette.edit'] 'None' "$mode palette chain saves and closes"
        Assert-Saved "$mode palette"
        Assert-Value (Read-State)['palette.query'] 'Find' "$mode palette keeps its query"
        Assert-Value (Read-State)['palette.selected'] $selected "$mode palette keeps its selection"
        Shot "palette-saved-$mode"
        Click-Rect (Read-State)['notice.shortcut_undo.action']
        Assert-Value ([IO.File]::ReadAllText($path)) $before "$mode Undo restores the file in one write"
        Invoke-Aio key Esc | Out-Null
    }
} finally {
    & $ctl --name $name stop | Write-Output
}

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'feedback-controls'
$directory = Join-Path $repo "build/verify/$name"
$path = Join-Path $directory 'settings.ini'
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    $result | Write-Output
}
function Set-Option([string] $Key, [string] $Value) {
    $text = [IO.File]::ReadAllText($path)
    $text = [regex]::Replace($text, '(?m)^'+[regex]::Escape($Key)+' = .*\r?\n?', '')
    [IO.File]::WriteAllText($path, $text.TrimEnd()+"`n$Key = $Value`n")
}
function Shot([string] $Label) {
    & (Join-Path $repo 'tools/win32.ps1') -Name $name -Shot (Join-Path $directory "$Label.png") | Out-Null
}
function Read-State {
    $state = @{}
    foreach ($line in (& $ctl --name $name state)) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Tab-X($State) { if (-not $State.ContainsKey('tabs.x')) { throw 'State lacks tabs.x; the tab strip offset is unknown.' }; return [double]$State['tabs.x'] }
function Tab-Center([int] $Index) { $s = Read-State; return "$([int]((Tab-X $s)+[double]$s['tabs.width']*($Index-0.5))),20" }
Invoke-Aio launch --fresh
try {
    Invoke-Aio command pane.split_right
    Invoke-Aio expect state panes.count=2
    $splitState = Read-State
    $inactive = $splitState.Keys | Where-Object {
        $_ -match '^pane\.\d+\.rect$' -and $_ -ne "pane.$($splitState['panes.focused']).rect"
    } | Select-Object -First 1
    $inactiveRect = $splitState[$inactive] -split ',' | ForEach-Object { [double]$_ }
    Invoke-Aio mouse click "$([int]($inactiveRect[0]+$inactiveRect[2]-64)),$([int]($inactiveRect[1]+14))" --px
    Invoke-Aio expect state panes.count=3
    Invoke-Aio command pane.close
    Invoke-Aio expect state panes.count=2
    Write-Output 'PASS one click on an unfocused pane control splits that pane'
    Set-Option pane.minimum_columns 100
    Invoke-Aio command settings.reload
    Invoke-Aio command pane.split_right
    Invoke-Aio expect state panes.count=2
    Invoke-Aio expect state sessions.count=2
    Set-Option pane.minimum_columns 0
    Set-Option pane.minimum_rows 0
    Invoke-Aio command settings.reload
    Invoke-Aio command pane.split_right
    Invoke-Aio expect state panes.count=3
    Set-Option pane.minimum_columns 100
    Set-Option pane.minimum_rows 100
    Invoke-Aio command settings.reload
    Invoke-Aio expect state panes.count=3
    $paneState = Read-State
    $paneRect = $paneState["pane.$($paneState['panes.focused']).rect"] -split ',' | ForEach-Object { [double]$_ }
    $grab = "$([int]($paneRect[0]+40)),$([int]($paneRect[1]+14))"
    Invoke-Aio mouse down $grab --px
    Invoke-Aio mouse move '7,350' --px
    Invoke-Aio expect state panes.drop.shown=false
    Invoke-Aio mouse up '7,350' --px
    Invoke-Aio expect state panes.count=3
    $drop = "$([int]((Tab-X $paneState)+[double]$paneState['tabs.width']+16)),20"
    Invoke-Aio mouse drag $grab $drop --px
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state panes.count=3
    Invoke-Aio command tab.duplicate
    Invoke-Aio expect state tabs.count=1
    foreach ($dpi in @(144,168,96)) {
        Invoke-Aio dpi $dpi
        Invoke-Aio command tab.new
        Invoke-Aio expect state tabs.count=1
        Invoke-Aio expect state panes.count=3
    }
    Invoke-Aio command tab.new
    Invoke-Aio expect state tabs.count=1
    Set-Option pane.minimum_columns 20
    Set-Option pane.minimum_rows 5
    Invoke-Aio command settings.reload
    Write-Output 'PASS minimum size prevents creation, zero disables, existing panes survive stricter limits'
    Set-Option keys.tab.new 'F5, F6, F7, F8, F9, F10'
    Invoke-Aio command settings.reload
    Invoke-Aio key F10
    Invoke-Aio expect state tabs.count=2
    Invoke-Aio command tab.close
    Set-Option keys.tab.new 'Ctrl+Shift+T'
    Invoke-Aio command settings.reload
    Write-Output 'PASS sixth persisted shortcut alternative dispatches'

    Invoke-Aio mouse click (Tab-Center 1) --button right --px
    Invoke-Aio expect state tab_menu.open=true
    Invoke-Aio expect state tab_menu.count=13
    Shot single-menu
    Invoke-Aio key Enter
    Invoke-Aio expect state rename.open=true
    Invoke-Aio type 'Menu renamed'
    Shot rename
    Invoke-Aio key Enter
    Invoke-Aio expect state 'tab.1.title=Menu renamed'
    Invoke-Aio key Shift+F10
    Invoke-Aio key End Enter
    Invoke-Aio expect state settings.active=true
    Invoke-Aio expect state settings.key=tab.confirm_close
    Invoke-Aio expect state settings.filter=
    Invoke-Aio key Menu
    Invoke-Aio expect state tab_menu.count=5
    Invoke-Aio key Esc
    Invoke-Aio command tab.close
    Invoke-Aio command tab.new
    Invoke-Aio command tab.new
    Invoke-Aio mouse click (Tab-Center 1) --mods Ctrl --px
    Invoke-Aio mouse click (Tab-Center 1) --button right --px
    Invoke-Aio expect state tab_menu.count=5
    Shot multiple-menu
    Invoke-Aio key Down Enter
    Invoke-Aio expect state tabs.selected=2
    Invoke-Aio expect state tab.2.marked=true
    Invoke-Aio expect state tab.3.marked=true
    Invoke-Aio key Shift+F10
    Invoke-Aio focus out
    Invoke-Aio expect state tab_menu.open=false
    Invoke-Aio command tab.select_1
    Invoke-Aio command tab.close_others
    Invoke-Aio expect state confirm.open=true
    Invoke-Aio key Esc
    Invoke-Aio expect state tab.1.marked=true
    Invoke-Aio expect state tabs.count=3
    Invoke-Aio command tab.close_others
    Invoke-Aio key Enter
    Invoke-Aio expect state tabs.count=1
    Write-Output 'PASS tab menus, keyboard access, rename, group move, settings destination, and focus-loss dismissal'

    Add-Type -AssemblyName System.Drawing
    $iconPath = Join-Path $directory 'shell.png'
    $image = [Drawing.Bitmap]::new(24,16)
    $graphics = [Drawing.Graphics]::FromImage($image)
    $graphics.Clear([Drawing.Color]::CornflowerBlue)
    $image.Save($iconPath, [Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $image.Dispose()
    Set-Option shell.icon shell.png
    Invoke-Aio command settings.reload
    Invoke-Aio expect state shell.icon.loaded=true
    Shot image-icon
    Set-Option shell.icon missing.png
    Invoke-Aio command settings.reload
    Invoke-Aio expect state shell.icon.loaded=false
    Invoke-Aio expect state 'session.header.icon=>_'
    Set-Option shell.icon shell.png
    Set-Option theme.mode light
    Invoke-Aio command settings.reload
    Invoke-Aio run 'Clear-Host; $e=[char]27; [Console]::WriteLine("${e}[37mArgument ${e}[97mNumber ${e}[2mPrediction${e}[0m")'
    Shot light-contrast
    Write-Output 'PASS PNG icon loading, relative paths, fallback, and light-theme contrast fixture'
    Set-Option interface.font_size 14
    Invoke-Aio command settings.reload
    Invoke-Aio command settings.open
    Invoke-Aio type font
    Shot gui-font-14
    Invoke-Aio dpi 168
    Shot gui-font-14-dpi168
    Invoke-Aio dpi 96
    Invoke-Aio key Esc
    Invoke-Aio type keys.tab.new
    Invoke-Aio key Tab Enter Ctrl+Shift+P Enter
    Invoke-Aio expect state settings.error=true
    Shot shortcut-conflict
    Invoke-Aio key Esc
    Invoke-Aio expect state settings.error=false
    Invoke-Aio key Esc
    Invoke-Aio type font.line_height
    $slider = (Read-State)['settings.slider'] -split ',' | ForEach-Object { [double]$_ }
    Invoke-Aio mouse click "$([int]($slider[0]+$slider[2]*0.375)),$([int]($slider[1]+$slider[3]/2))" --px
    Invoke-Aio expect state settings.value=1.25
    Invoke-Aio command tab.select_1
    Shot line-height-125
    Write-Output 'PASS native line-height slider uses 0.05 steps'
} finally {
    & $ctl --name $name stop | Write-Output
}

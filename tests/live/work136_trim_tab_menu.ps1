[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'work136-trim-menu'
$directory = Join-Path $repo "build/verify/$name"
$settings = Join-Path $directory 'settings.ini'
function Invoke-Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    $result | Write-Output
}
function Read-State {
    $result = & $ctl --name $name state
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    $state = @{}
    foreach ($line in $result) {
        $pair = $line -split '=', 2
        $state[$pair[0]] = $pair[1].Trim('"')
    }
    return $state
}
function Set-Option([string] $Key, [string] $Value) {
    $text = [IO.File]::ReadAllText($settings)
    $text = [regex]::Replace($text, '(?m)^'+[regex]::Escape($Key)+' = .*\r?\n?', '')
    [IO.File]::WriteAllText($settings, $text.TrimEnd()+"`n$Key = $Value`n")
}
function Tab-Center([int] $Index) {
    $state = Read-State
    return "$([int]([double]$state['tabs.x']+[double]$state['tabs.width']*($Index-0.5))),20"
}
function Assert-Menu([string[]] $Labels, [int[]] $Disabled = @()) {
    Invoke-Aio expect state tab_menu.open=true
    Invoke-Aio expect state "tab_menu.count=$($Labels.Count)"
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $row = $i+1
        $separator = $Labels[$i] -eq '-'
        $label = if ($separator) { '' } else { $Labels[$i] }
        $enabled = -not $separator -and $row -notin $Disabled
        Invoke-Aio expect state "tab_menu.row.$row.label=$label"
        Invoke-Aio expect state "tab_menu.row.$row.separator=$($separator.ToString().ToLowerInvariant())"
        Invoke-Aio expect state "tab_menu.row.$row.enabled=$($enabled.ToString().ToLowerInvariant())"
    }
}
function Click-Row([int] $Row) {
    $state = Read-State
    $rect = $state["tab_menu.row.$Row.rect"] -split ',' | ForEach-Object { [double]$_ }
    if ($rect.Count -ne 4) { throw "Missing menu row $Row geometry" }
    Invoke-Aio mouse click "$([int]($rect[0]+$rect[2]/2)),$([int]($rect[1]+$rect[3]/2))" --px
}
function Choose-Menu([string] $Label) {
    $state = Read-State
    for ($row = 1; $row -le [int]$state['tab_menu.count']; $row++) {
        if ($state["tab_menu.row.$row.label"] -eq $Label) {
            Invoke-Aio expect state "tab_menu.row.$row.label=$Label"
            Click-Row $row
            return
        }
    }
    throw "Menu lacks '$Label'"
}
$single = @('Rename', 'Duplicate', '-', 'Close to the Right', 'Close Others', 'Close', '-', 'Tab Settings')
Invoke-Aio launch --fresh
Start-Transcript -LiteralPath (Join-Path $directory 'journey.log') | Out-Null
try {
    Invoke-Aio doctor
    Invoke-Aio mouse click (Tab-Center 1) --button right --px
    Assert-Menu $single @(4,5)
    Click-Row 3
    Invoke-Aio expect state tab_menu.open=true
    Click-Row 4
    Invoke-Aio expect state tab_menu.open=true
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio key Home Down Down
    Invoke-Aio expect state tab_menu.action=Close_Tab
    Invoke-Aio key Down
    Invoke-Aio expect state tab_menu.action=Tab_Settings
    Invoke-Aio key Down
    Invoke-Aio expect state tab_menu.action=Rename_Tab
    Invoke-Aio key Esc
    Invoke-Aio key Shift+F10 Enter
    Invoke-Aio expect state rename.open=true
    Invoke-Aio type 'WORK136 renamed'
    Invoke-Aio key Enter
    Invoke-Aio expect state 'tab.1.title=WORK136 renamed'
    Write-Output 'PASS exact single menu, separators, unavailable close rows, keyboard skip/wrap and rename'

    Set-Option shell.command 'pwsh.exe -NoLogo -NoProfile'
    Set-Option shell.directory 'C:\Windows'
    Set-Option shell.report_directory false
    Invoke-Aio command settings.reload
    Invoke-Aio command tab.new
    Set-Option shell.command 'cmd.exe /D /Q'
    Set-Option shell.directory 'C:\Windows\System32'
    Invoke-Aio command settings.reload
    Invoke-Aio key Menu
    Choose-Menu Duplicate
    Invoke-Aio expect state tabs.count=3
    Invoke-Aio expect state tabs.selected=3
    Invoke-Aio run 'Write-Output ("FALLBACK_"+(Get-Location).Path+"|")'
    Invoke-Aio wait text 'FALLBACK_C:\Windows|'
    Invoke-Aio run 'Set-Location C:\Windows\Temp; [Console]::Write(([char]27).ToString()+"]7;file://localhost/C:/Windows/Temp"+([char]7))'
    Invoke-Aio expect state 'session.header.directory=C:\Windows\Temp'
    Invoke-Aio key Shift+F10
    Choose-Menu Duplicate
    Invoke-Aio expect state tabs.count=4
    Invoke-Aio expect state tabs.selected=4
    Invoke-Aio run 'Write-Output ("REPORTED_"+(Get-Location).Path+"|")'
    Invoke-Aio wait text 'REPORTED_C:\Windows\Temp|'
    Set-Option shell.command 'pwsh.exe -NoLogo -NoProfile'
    Invoke-Aio command settings.reload
    Write-Output 'PASS Duplicate preserves source PowerShell command after changing default shell and uses launch/report directory'

    Invoke-Aio command tab.select_1
    Invoke-Aio command tab.close_others
    Invoke-Aio command pane.split_right
    Invoke-Aio command tab.new
    Invoke-Aio command tab.new
    Invoke-Aio mouse click (Tab-Center 1) --mods Ctrl --px
    Invoke-Aio mouse click (Tab-Center 1) --button right --px
    Assert-Menu @('Close Others', 'Close 2 Selected Tabs', '-', 'Tab Settings')
    Invoke-Aio expect state tab.1.marked=true
    Invoke-Aio expect state tab.2.marked=false
    Invoke-Aio expect state tab.3.marked=true
    Choose-Menu 'Close Others'
    Invoke-Aio expect state tabs.count=2
    Invoke-Aio expect state tab.1.marked=true
    Invoke-Aio expect state tab.2.marked=true
    Invoke-Aio key Menu
    Assert-Menu @('Close Others', 'Close 2 Selected Tabs', '-', 'Tab Settings') @(1)
    Choose-Menu 'Close 2 Selected Tabs'
    Invoke-Aio expect state confirm.open=true
    Invoke-Aio key Esc
    Invoke-Aio expect state tabs.count=2
    Invoke-Aio expect state tab.1.marked=true
    Invoke-Aio expect state tab.2.marked=true
    Write-Output 'PASS selected-group right click, reduced group menu, unavailable Close Others and group close cancellation'

    Invoke-Aio command tab.select_2
    Invoke-Aio key Shift+F10
    Assert-Menu $single @(4)
    Choose-Menu 'Close Others'
    Invoke-Aio expect state confirm.open=true
    Invoke-Aio key Esc
    Invoke-Aio expect state tab.1.marked=false
    Invoke-Aio expect state tab.2.marked=true
    Invoke-Aio expect state tabs.selected=2
    Invoke-Aio key Menu
    Choose-Menu 'Close Others'
    Invoke-Aio key Enter
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio command tab.new
    Invoke-Aio command pane.split_right
    Invoke-Aio mouse click (Tab-Center 1) --button right --px
    Assert-Menu $single
    Invoke-Aio expect state tab.1.marked=true
    Invoke-Aio expect state tab.2.marked=false
    Choose-Menu 'Close to the Right'
    Invoke-Aio expect state confirm.open=true
    Invoke-Aio key Esc
    Invoke-Aio expect state tab.1.marked=true
    Invoke-Aio expect state tab.2.marked=false
    Invoke-Aio key Menu
    Choose-Menu 'Close to the Right'
    Invoke-Aio key Enter
    Invoke-Aio expect state tabs.count=1
    Write-Output 'PASS right click unselected tab selects alone; close subsets confirm, restore on cancel and close on accept'

    Invoke-Aio key Menu End Enter
    Invoke-Aio expect state settings.active=true
    Invoke-Aio expect state settings.key=tab.confirm_close
    Invoke-Aio expect state settings.filter=
    Invoke-Aio type unrelated
    Invoke-Aio key Menu
    Assert-Menu @('Close to the Right', 'Close Others', 'Close', '-', 'Tab Settings') @(1)
    Choose-Menu 'Tab Settings'
    Invoke-Aio expect state settings.key=tab.confirm_close
    Invoke-Aio expect state settings.filter=
    Invoke-Aio key Menu
    Choose-Menu Close
    Invoke-Aio expect state tabs.count=1
    Invoke-Aio expect state settings.active=false
    Invoke-Aio key Shift+F10
    Invoke-Aio focus out
    Invoke-Aio expect state tab_menu.open=false
    Invoke-Aio focus in
    Invoke-Aio key Menu
    Invoke-Aio mouse click '1,500' --px
    Invoke-Aio expect state tab_menu.open=false
    Write-Output 'PASS Settings capabilities, Tab Settings search reset/destination, close, focus and outside dismissal'
} finally {
    & $ctl --name $name stop | Write-Output
    Stop-Transcript | Out-Null
}

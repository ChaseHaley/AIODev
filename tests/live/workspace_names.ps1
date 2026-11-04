param([string] $Name = 'work285-names')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
function Invoke-Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $args : $out" }
    return $out
}
function Read-State {
    $s = @{}
    foreach ($line in (Invoke-Aio state)) {
        $pair = $line -split '=',2
        $s[$pair[0]] = $pair[1].Trim('"')
    }
    return $s
}
function Check($Condition, $Label) {
    if (!$Condition) { throw "FAIL $Label" }
    Write-Output "PASS $Label"
}
try {
    Invoke-Aio launch --fresh | Out-Null
    $initial = Read-State
    Check ($initial['rename.open'] -eq 'false') 'bootstrap skips prompt'
    Check ($initial['workspace.name'] -match '^[A-Za-z]+ [A-Za-z]+ [A-Za-z]+$') 'bootstrap uses a phrase'
    Invoke-Aio command workspace.new | Out-Null
    Start-Sleep -Milliseconds 200
    & "$repo/tools/win32.ps1" -Name $Name -Shot "$repo/build/verify/$Name/name-chip.png" -Frame | Out-Null
    $prompt = Read-State
    Check ($prompt['rename.open'] -eq 'true') 'command opens the name in the chip'
    Check ($prompt['workspaces.count'] -eq '2') 'the workspace exists while it is named'
    Check ($prompt['workspace.name'] -eq $prompt['rename.value']) 'the field holds the suggested name'
    Invoke-Aio key Esc | Out-Null
    $kept = Read-State
    Check ($kept['workspaces.count'] -eq '2' -and $kept['workspace.name'] -eq $prompt['rename.value']) 'Escape keeps the suggestion'
    Invoke-Aio command workspace.new | Out-Null
    $suggestion = (Read-State)['rename.value']
    Invoke-Aio key Enter | Out-Null
    Check ((Read-State)['workspace.name'] -eq $suggestion) 'Enter accepts generated phrase'
    Invoke-Aio command workspace.new | Out-Null
    Invoke-Aio type 'Build tools' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Check ((Read-State)['workspace.name'] -eq 'Build tools') 'typing replaces selected phrase'
    Invoke-Aio command workspace.change | Out-Null
    $menu = Read-State
    $row = @($menu['workspace.picker.row'] -split ',' | ForEach-Object { [double]$_ })
    $scale = [double]$menu['window.scale']
    $index = [int]$menu['workspace.picker.selected']
    $count = [int]$menu['workspaces.count']
    $x = [int]($row[0] + $row[2]/2)
    $y = [int]($row[1] + ($count-$index)*34*$scale + 8*$scale + 17*$scale)
    Invoke-Aio mouse click "$x,$y" --px | Out-Null
    Check ((Read-State)['rename.open'] -eq 'true') 'New Workspace menu action opens the chip name'
    Invoke-Aio type 'Button workspace' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Check ((Read-State)['workspace.name'] -eq 'Button workspace') 'menu names the workspace'
    Invoke-Aio command pane.split_right | Out-Null
    Invoke-Aio command pane.move_new_workspace | Out-Null
    Check ((Read-State)['rename.open'] -eq 'true') 'moving into a new workspace names it in the chip'
    Invoke-Aio type 'Button workspace' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Check ((Read-State)['rename.open'] -eq 'true') 'a used name keeps the field open'
    Start-Sleep -Milliseconds 200
    & "$repo/tools/win32.ps1" -Name $Name -Shot "$repo/build/verify/$Name/name-in-use.png" -Frame | Out-Null
    Invoke-Aio key Esc | Out-Null
    Check ((Read-State)['workspace.name'] -ne 'Button workspace') 'Escape keeps the suggestion after a used name'
    $before = Read-State
    Invoke-Aio command window.new | Out-Null
    $after = Read-State
    Check ([int]$after['windows.count'] -eq [int]$before['windows.count']+1) 'New Window opens immediately'
    $opened = @(1..[int]$after['windows.count'] | ForEach-Object { $after["window.$_.id"] } | Where-Object { $_ -ne $before['window.id'] })[0]
    Invoke-Aio window select $opened | Out-Null
    Check ((Read-State)['rename.open'] -eq 'true') 'the new window names itself in its own chip'
    Invoke-Aio type 'Window workspace' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Check ((Read-State)['workspace.name'] -eq 'Window workspace') 'New Window takes the typed name'
    $chip = @((Read-State)['workspace.button'] -split ',' | ForEach-Object { [double]$_ })
    $point = "$([int]($chip[0]+$chip[2]/2)),$([int]($chip[1]+$chip[3]/2))"
    Invoke-Aio mouse click $point --px | Out-Null
    Check ((Read-State)['workspace.picker'] -eq 'true') 'one click on the chip opens the menu'
    Invoke-Aio mouse click $point --px | Out-Null
    $double = Read-State
    Check ($double['rename.open'] -eq 'true' -and $double['workspace.picker'] -eq 'false') 'a double-click on the chip renames in place'
    Invoke-Aio key Esc | Out-Null
    Write-Output 'PASS workspace phrase and chip naming journey'
} finally { Invoke-Aio stop | Out-Null }

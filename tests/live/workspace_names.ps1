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
    & "$repo/tools/win32.ps1" -Name $Name -Shot "$repo/build/verify/$Name/name-prompt.png" -Frame | Out-Null
    $prompt = Read-State
    Check ($prompt['rename.open'] -eq 'true') 'command opens prompt'
    Check ($prompt['workspaces.count'] -eq '1') 'prompt creates no workspace yet'
    Invoke-Aio key Esc | Out-Null
    Check ((Read-State)['workspaces.count'] -eq '1') 'Escape creates nothing'
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
    Check ((Read-State)['rename.open'] -eq 'true') 'New Workspace menu action opens prompt'
    Invoke-Aio type 'Button workspace' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Check ((Read-State)['workspace.name'] -eq 'Button workspace') 'menu prompt creates named workspace'
    Invoke-Aio command pane.move_new_workspace | Out-Null
    Check ((Read-State)['rename.open'] -eq 'true') 'moving into a new workspace prompts'
    Invoke-Aio key Esc | Out-Null
    Check ((Read-State)['workspace.name'] -eq 'Button workspace') 'cancelled move preserves source'
    Invoke-Aio command window.new | Out-Null
    Check ((Read-State)['windows.count'] -eq '1') 'New Window waits for name'
    Invoke-Aio type 'Window workspace' | Out-Null
    Invoke-Aio key Enter | Out-Null
    Check ((Read-State)['windows.count'] -eq '2') 'New Window creates after confirmation'
    Write-Output 'PASS workspace phrase and prompt journey'
} finally { Invoke-Aio stop | Out-Null }

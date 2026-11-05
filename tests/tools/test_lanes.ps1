#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/tools/test-lanes.ps1"
function Assert-True($Value, [string] $Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Message) {
    try { & $Action } catch { return }
    throw $Message
}
$all = @('cheap', 'native', 'new_unclassified')
$fast = @(Select-AppTests $all @('cheap') Fast '')
$native = @(Select-AppTests $all @('cheap') Native '')
Assert-True ($fast.Count -eq 1 -and $fast[0] -eq 'cheap') 'Fast uses only reviewed names'
Assert-True ('new_unclassified' -in $native) 'New tests default to native'
Assert-True (@($fast + $native | Sort-Object -Unique).Count -eq $all.Count) 'Lanes cover every test'
Assert-True (@($fast | Where-Object { $_ -in $native }).Count -eq 0) 'Lanes are disjoint'
Assert-Throws { Select-AppTests $all @('renamed') All '' } 'Stale allowlists must fail'
Assert-Throws { Select-AppTests $all @('cheap', 'cheap') All '' } 'Duplicate allowlists must fail'
Assert-Throws { Select-AppTests $all @('cheap') Fast 'native' } 'Wrong-lane selectors must fail'
Assert-Throws { Select-AppTests $all @('cheap') All 'missing' } 'Missing selectors must fail'
Assert-Throws { Select-AppTests $all @() Fast '' } 'Empty lanes must fail'
Assert-True ((@(Select-AppTests $all @('cheap') Fast 'app_test.cheap'))[0] -eq 'cheap') 'Qualified names work'
$inventory = @(Get-AppTestInventory $root)
$manifest = Get-Content -LiteralPath "$root/tests/app/lanes.json" -Raw | ConvertFrom-Json
$fast = @(Select-AppTests $inventory $manifest.fast Fast '')
$native = @(Select-AppTests $inventory $manifest.fast Native '')
Assert-True (($fast.Count + $native.Count) -eq $inventory.Count) 'Repository partition is complete'
"PASS app lane selection: $($fast.Count) fast + $($native.Count) native = $($inventory.Count) tests"

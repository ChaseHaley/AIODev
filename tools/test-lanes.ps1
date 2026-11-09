function Get-AppTestInventory([string] $Root) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Root 'tests/app') -Filter *.odin -File) {
        $source = [IO.File]::ReadAllText($file.FullName)
        foreach ($match in [regex]::Matches($source, '@\(test\)\s*(\w+)\s*::\s*proc')) {
            $match.Groups[1].Value
        }
    }
}

# The tests lanes.json lists under "desktop": they run on the Win32 backend, every other app test headless.
function Get-AppDesktopTests($Manifest) {
    if ($null -eq $Manifest.desktop) { return @() }
    foreach ($entry in $Manifest.desktop.PSObject.Properties) {
        if (-not "$($entry.Value)".Trim()) { throw "Desktop test $($entry.Name) gives no reason." }
        $entry.Name
    }
}

function Select-AppTests(
    [string[]] $Inventory, [string[]] $Fast, [string] $Lane, [string] $Names, [string[]] $Desktop = @()
) {
    if (@($Inventory | Sort-Object -Unique).Count -ne $Inventory.Count) { throw 'Duplicate app test names.' }
    if (@($Fast | Sort-Object -Unique).Count -ne $Fast.Count) { throw 'Duplicate fast test names.' }
    $stale = @($Fast | Where-Object { $_ -notin $Inventory })
    if ($stale) { throw "Fast test manifest has missing tests: $($stale -join ', ')" }
    $staleDesktop = @($Desktop | Where-Object { $_ -notin $Inventory })
    if ($staleDesktop) { throw "Desktop test manifest has missing tests: $($staleDesktop -join ', ')" }
    $both = @($Desktop | Where-Object { $_ -in $Fast })
    if ($both) { throw "Tests cannot be both fast and desktop: $($both -join ', ')" }
    $selected = switch ($Lane) {
        'Fast' { @($Inventory | Where-Object { $_ -in $Fast }) }
        'Native' { @($Inventory | Where-Object { $_ -notin $Fast }) }
        'Desktop' { @($Inventory | Where-Object { $_ -in $Desktop }) }
        'All' { $Inventory }
        default { throw "Unknown app test lane: $Lane" }
    }
    if ($Names) {
        $requested = @($Names.Split(',') | ForEach-Object { $_ -replace '^app_test\.', '' })
        $missing = @($requested | Where-Object { $_ -notin $selected })
        if ($missing) { throw "Tests absent from app lane ${Lane}: $($missing -join ', ')" }
        $selected = $requested
    }
    if (-not $selected.Count) { throw "App test lane $Lane selected no tests." }
    $selected | Sort-Object -Unique
}

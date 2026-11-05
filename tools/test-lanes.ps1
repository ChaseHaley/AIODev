function Get-AppTestInventory([string] $Root) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Root 'tests/app') -Filter *.odin -File) {
        $source = [IO.File]::ReadAllText($file.FullName)
        foreach ($match in [regex]::Matches($source, '@\(test\)\s*(\w+)\s*::\s*proc')) {
            $match.Groups[1].Value
        }
    }
}

function Select-AppTests([string[]] $Inventory, [string[]] $Fast, [string] $Lane, [string] $Names) {
    if (@($Inventory | Sort-Object -Unique).Count -ne $Inventory.Count) { throw 'Duplicate app test names.' }
    if (@($Fast | Sort-Object -Unique).Count -ne $Fast.Count) { throw 'Duplicate fast test names.' }
    $stale = @($Fast | Where-Object { $_ -notin $Inventory })
    if ($stale) { throw "Fast test manifest has missing tests: $($stale -join ', ')" }
    $selected = switch ($Lane) {
        'Fast' { @($Inventory | Where-Object { $_ -in $Fast }) }
        'Native' { @($Inventory | Where-Object { $_ -notin $Fast }) }
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

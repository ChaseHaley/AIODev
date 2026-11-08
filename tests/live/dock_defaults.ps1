param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'dock-defaults'
$data = Join-Path $repo "build/verify/$name"
function Aio {
    $result = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $result" }
    return $result
}
function State {
    $s = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        $s[$pair[0]] = $pair[1].Trim('"')
    }
    return $s
}
function Rect($s, $key) { return @($s[$key] -split ',' | ForEach-Object { [double]$_ }) }
function Equal($actual, $expected, $label) {
    if ("$actual" -ne "$expected") { throw "$label expected $expected, observed $actual" }
    Write-Output "PASS $label"
}
$paneGap = 4
Aio launch --fresh --size 140x40 | Out-Null
try {
    Add-Content -LiteralPath "$data/settings.ini" `
        -Value "`nstatus.panel = true`ntabs.orientation = vertical`npane.gap = $paneGap"
    Aio command settings.reload | Out-Null
    foreach ($dpi in @(96, 144)) {
        Aio dpi $dpi | Out-Null
        foreach ($kind in @('rail', 'width', 'height')) {
            $s = State
            $side = if ($kind -eq 'height') { 'left' } else { 'right' }
            if ($s['activity.side'] -ne $side) {
                $r = Rect $s 'activity.side_button'
                Aio mouse click "$([int]($r[0]+$r[2]/2)),$([int]($r[1]+$r[3]/2))" --px | Out-Null
                $s = State
            }
            $scale = [double]$s['window.scale']
            $rail = Rect $s 'rail.rect'
            $panel = Rect $s 'activity.rect'
            $gap = [math]::Max(1, [math]::Round($paneGap*$scale))
            $x, $y = [int]($panel[0]-$gap/2), [int]($panel[1]+60*$scale)
            if ($kind -eq 'rail') { $x, $y = [int]($rail[0]+$rail[2]), [int]($rail[1]+60*$scale) }
            if ($kind -eq 'height') { $x, $y = [int]($rail[0]+$rail[2]/2), [int]$panel[1] }
            $endX, $endY = $x, $y
            if ($kind -eq 'height') { $endY -= [int](28*$scale) }
            elseif ($kind -eq 'rail') { $endX += [int](24*$scale) }
            else { $endX -= [int](24*$scale) }
            Aio mouse drag "$x,$y" "$endX,$endY" --px | Out-Null
            $before = State
            $rail = Rect $before 'rail.rect'
            $panel = Rect $before 'activity.rect'
            $endX, $endY = [int]($panel[0]-$gap/2), [int]($panel[1]+60*$scale)
            if ($kind -eq 'rail') { $endX, $endY = [int]($rail[0]+$rail[2]), [int]($rail[1]+60*$scale) }
            if ($kind -eq 'height') { $endX, $endY = [int]($rail[0]+$rail[2]/2), [int]$panel[1] }
            $fileBefore = Get-Content -LiteralPath "$data/settings.ini" -Raw
            Aio mouse click "$endX,$endY" --button right --px | Out-Null
            Equal (State)['tab_menu.open'] true "$kind $dpi opens"
            Equal (State)['tab_menu.row.1.label'] 'Set as Default Size' "$kind $dpi menu"
            Aio key Esc | Out-Null
            Equal (Get-Content -LiteralPath "$data/settings.ini" -Raw) $fileBefore "$kind $dpi cancel"
            Aio mouse click "$endX,$endY" --button right --px | Out-Null
            Equal (State)['tab_menu.open'] true "$kind $dpi reopens"
            Aio capture --out "$data/$kind-$dpi-menu.png" | Out-Null
            Aio key Enter | Out-Null
            $after = State
            Equal $after['tab_menu.open'] false "$kind $dpi choose closes"
            Equal $after['rail.rect'] $before['rail.rect'] "$kind $dpi rail stays"
            Equal $after['activity.rect'] $before['activity.rect'] "$kind $dpi Activity stays"
            $key = switch ($kind) { rail { 'tabs.rail_width' } width { 'status.panel_width' } height { 'status.panel_height' } }
            $expected = switch ($kind) {
                rail { [int][math]::Round((Rect $before 'rail.rect')[2]/$scale) }
                width { [int][math]::Round(((Rect $before 'activity.rect')[2]+$gap)/$scale) }
                height { [int][math]::Round(100*(Rect $before 'activity.rect')[3]/$rail[3]) }
            }
            if (-not (Select-String -LiteralPath "$data/settings.ini" -SimpleMatch "$key = $expected" -Quiet)) {
                throw "$kind $dpi did not save $key = $expected"
            }
            Write-Output "PASS $kind $dpi persisted $key = $expected"
        }
    }
} finally { & $ctl --name $name stop | Out-Null }

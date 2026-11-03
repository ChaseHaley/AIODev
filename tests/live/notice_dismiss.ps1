[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'toast-dismiss'
$data = Join-Path $repo "build/verify/$name"
function Aio {
    $out = & $ctl --name $name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    return $out
}
function State {
    $result = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        $result[$pair[0]] = $pair[1].Trim('"')
    }
    return $result
}
function Check([bool]$Condition, [string]$Label) {
    if (!$Condition) { throw $Label }
    "PASS $Label"
}
function Close-Point([double]$Scale) {
    $size = (State)['window.1.size'] -split 'x'
    $rects = Aio draws --region "0,0,$($size[0]),$($size[1])" --kind rect
    $points = foreach ($line in $rects) {
        if ($line -match '^rect \d+ ([\d.]+),([\d.]+) ([\d.]+)x([\d.]+) .* radius=([\d.]+)$') {
            $x, $y, $w, $h, $radius = 1..5 | ForEach-Object { [double]$Matches[$_] }
            if ([Math]::Abs($x - ([double]$size[0] - 52*$Scale)) -lt 0.1 -and
                $w -eq 24*$Scale -and $h -eq $w -and $radius -eq 4*$Scale) {
                [pscustomobject]@{x=$x+$w/2; y=$y+$h/2}
            }
        }
    }
    $point = $points | Sort-Object y -Descending | Select-Object -First 1
    if (!$point) { throw 'No toast close button in the rendered frame.' }
    return "$([int]$point.x),$([int]$point.y)"
}
Aio launch --fresh | Out-Null
try {
    Start-Sleep -Milliseconds 5500
    foreach ($variant in @(@{theme='dark';dpi=96}, @{theme='light';dpi=144}, @{theme='dark';dpi=192})) {
        $path = Join-Path $data 'settings.ini'
        $settings = [IO.File]::ReadAllText($path)
        $settings = [regex]::Replace($settings, '(?m)^theme\.name\s*=.*\r?\n?', '')
        [IO.File]::WriteAllText($path, $settings.TrimEnd()+"`ntheme.name = studio-$($variant.theme)`n")
        Aio command settings.reload | Out-Null
        Aio dpi $variant.dpi | Out-Null
        Aio command pane.keep_open | Out-Null
        Aio command app.build_info | Out-Null
        Start-Sleep -Milliseconds 200
        $point = Close-Point ($variant.dpi/96)
        $before = State
        Check ($before.ContainsKey('notice.build_info') -and $before.ContainsKey('notice.transient')) 'two notices are stacked'
        Aio mouse move $point --px | Out-Null
        Check ((State)['pointer.shape'] -eq 'hand') 'close button uses the hand pointer'
        Aio capture --out (Join-Path $data "close-$($variant.theme)-$($variant.dpi).png") | Out-Null
        Aio mouse down $point --px | Out-Null
        Aio mouse up '200,200' --px | Out-Null
        Check ((State).ContainsKey('notice.build_info')) 'release outside cancels dismissal'
        Aio mouse click $point --px --button right | Out-Null
        Check ((State).ContainsKey('notice.build_info')) 'right click preserves the notice'
        Aio mouse click $point --px | Out-Null
        $after = State
        Check (!$after.ContainsKey('notice.build_info')) 'close dismisses the notice before its timer expires'
        Check ($after.ContainsKey('notice.transient')) 'the other stacked notice stays visible'
        Check ($after['session.id'] -eq $before['session.id']) 'dismissal preserves the terminal session'
        Start-Sleep -Milliseconds 200
        Aio mouse click (Close-Point ($variant.dpi/96)) --px | Out-Null
        Check (!(State).ContainsKey('notice.transient')) 'the remaining notice can also be dismissed'
    }
    Aio command app.build_info | Out-Null
    Start-Sleep -Milliseconds 12500
    Check (!(State).ContainsKey('notice.build_info')) 'automatic expiry still removes a notice'
} finally { Aio stop | Out-Null }

[CmdletBinding()]
param([string] $Name = 'notice-windows')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$data = Join-Path $repo "build/verify/$Name"
function Aio {
    $out = & $ctl --name $Name @args
    if ($LASTEXITCODE -ne 0) { throw "aioctl $($args -join ' '): $out" }
    $out
}
function State {
    $s = @{}
    foreach ($line in (Aio state)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $s[$pair[0]] = $pair[1].Trim('"') }
    }
    $s
}
function Select-Window([string] $Id) { Aio window select $Id | Out-Null }
function Focus-Window([string] $Id) {
    $s = State
    foreach ($key in @($s.Keys | Where-Object { $_ -match '^window\.\d+\.id$' })) {
        Select-Window $s[$key]
        Aio focus out | Out-Null
    }
    if ($Id) { Select-Window $Id; Aio focus in | Out-Null }
}
function Close-Points {
    $s = State
    $size = $s['window.size'] -split 'x'
    $scale = [double]$s['window.dpi'] / 96
    foreach ($line in (Aio draws --region "0,0,$($size[0]),$($size[1])" --kind rect)) {
        if ($line -match '^rect \d+ ([\d.]+),([\d.]+) ([\d.]+)x([\d.]+) .* radius=([\d.]+)$') {
            $x, $y, $w, $h, $radius = 1..5 | ForEach-Object { [double]$Matches[$_] }
            if ([Math]::Abs($x - ([double]$size[0] - 52*$scale)) -lt 0.1 -and
                $w -eq 24*$scale -and $h -eq $w -and $radius -eq 4*$scale) {
                "$([int]($x+$w/2)),$([int]($y+$h/2))"
            }
        }
    }
}
function Assert-Owner([string] $Owner, [string[]] $Windows, [string] $Label) {
    foreach ($id in $Windows) {
        Select-Window $id
        $s = State
        if ($s['notices.window'] -ne $Owner) { throw "$Label wrong destination: $($s['notices.window'])" }
        $count = @(Close-Points | Sort-Object -Unique).Count
        $expected = if ($id -eq $Owner) { @($s.Keys | Where-Object { $_ -match '^notice\.' }).Count } else { 0 }
        if ($id -eq $Owner -and $expected -eq 0) { throw "$Label has no notices to verify" }
        if ($count -ne $expected) { throw "$Label window $id expected $expected toast, observed $count" }
        Aio capture --out (Join-Path $data "$Label-window$id.png") | Out-Null
    }
    "PASS $Label (toasts rendered only in window $Owner)"
}

# Focus injection proves app event handling and rendering; it does not prove native OS activation.
Aio launch --fresh | Out-Null
try {
    Aio doctor
    Aio wait text 'PS ' | Out-Null
    $first = (State)['window.id']
    Aio command pane.split_right | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio command window.new | Out-Null
    $s = State
    $second = @($s.Keys | Where-Object { $_ -match '^window\.\d+\.id$' } |
        ForEach-Object { $s[$_] } | Where-Object { $_ -ne $first })[0]
    if (!$second) { throw 'No second workspace window.' }
    Select-Window $second
    Aio type ToastSecond | Out-Null
    Aio key Enter | Out-Null
    Aio wait text 'PS ' | Out-Null
    Select-Window $first
    Aio command pane.linked_window | Out-Null
    $s = State
    $linked = $null
    for ($i = 1; $i -le [int]$s['windows.count']; $i++) {
        if ($s["window.$i.linked"] -eq 'true') { $linked = $s["window.$i.id"] }
    }
    if (!$linked) { throw 'No linked pane window.' }
    $windows = @($first, $second, $linked)
    # Let the startup migration notice expire before counting rendered notices.
    Start-Sleep -Milliseconds 5500
    $settingsPath = Join-Path $data 'settings.ini'
    $baseSettings = [IO.File]::ReadAllText($settingsPath)
    foreach ($variant in @(@{theme='dark';dpi=96}, @{theme='light';dpi=144})) {
        [IO.File]::WriteAllText($settingsPath,
            $baseSettings + "`ntheme.name = studio-$($variant.theme)`n")
        Select-Window $first
        Aio command settings.reload | Out-Null
        foreach ($id in $windows) { Select-Window $id; Aio dpi $variant.dpi | Out-Null }
        Focus-Window $first
        Aio command app.build_info | Out-Null
        Start-Sleep -Milliseconds 200
        Assert-Owner $first $windows "$($variant.theme)-first"
        Focus-Window $second
        Assert-Owner $second $windows "$($variant.theme)-second"
        Focus-Window ''
        Assert-Owner $second $windows "$($variant.theme)-none-focused"
        if (!(State).ContainsKey('notice.build_info')) { throw 'Focus change lost the notice.' }
        Focus-Window $linked
        Assert-Owner $linked $windows "$($variant.theme)-linked"
        Focus-Window ''
        Assert-Owner $linked $windows "$($variant.theme)-linked-last"
        Select-Window $linked
        $point = @(Close-Points | Sort-Object { [double](($_ -split ',')[1]) } -Descending)[0]
        $before = State
        Aio mouse click $point --px | Out-Null
        if ((State).ContainsKey('notice.build_info')) { throw 'Dismissal did not remove the shared notice.' }
        if ((State)['session.id'] -ne $before['session.id']) { throw 'Dismissal changed pane ownership.' }
        'PASS shared dismissal from the last-focused linked window'
    }
    Select-Window $linked
    Aio command app.build_info | Out-Null
    Start-Sleep -Milliseconds 200
    Focus-Window $first
    Focus-Window $linked
    Focus-Window ''
    Select-Window $first
    Aio command tab.new | Out-Null
    Aio wait text 'PS ' | Out-Null
    Aio expect state window.3.link_shown=false | Out-Null
    Assert-Owner $first @($first, $second) 'hidden-linked-fallback'
    Select-Window $first
    Aio key Ctrl+Shift+Tab | Out-Null
    Aio expect state window.3.link_shown=true | Out-Null
    Assert-Owner $linked $windows 'linked-restored'
    Select-Window $linked
    Aio command pane.linked_window | Out-Null
    Aio expect state windows.count=2 | Out-Null
    Assert-Owner $first @($first, $second) 'closed-linked-fallback'
    Aio doctor
} finally {
    Aio stop
}

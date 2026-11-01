$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ctl = Join-Path $repo 'build/aioctl.exe'
$name = 'title-actions'
function Aio { $r = & $ctl --name $name @args; if ($LASTEXITCODE) {throw ($r -join "`n")}; return $r }
function State { $s=@{}; Aio state | ForEach-Object { $p=$_ -split '=',2; $s[$p[0]]=$p[1].Trim('"') }; return $s }
function Click($r) { $v=$r -split ','; Aio mouse click "$([int]([double]$v[0]+[double]$v[2]/2)),$([int]([double]$v[1]+[double]$v[3]/2))" --px }
Aio launch --fresh
try {
 foreach ($mode in @('horizontal','vertical')) {
  if ((State)['tabs.orientation'] -ne $mode) { Aio command view.tabs_orientation }
  $s=State
  $layout=$s['tabs.orientation_button'] -split ','
  $settings=$s['title.settings'] -split ','
  $palette=$s['title.palette'] -split ','
  if ([double]$settings[0] -ne ([double]$layout[0]+[double]$layout[2])) { throw 'Settings is not after layout' }
  if ([double]$palette[0] -ne ([double]$settings[0]+[double]$settings[2])) { throw 'Palette is not after Settings' }
  Click $s['title.settings']
  Aio expect state settings.active=true
  Aio command tab.close
  Click (State)['title.palette']
  Aio expect state palette.open=true
  Aio key Esc
  $s=State
  $key=if($mode -eq 'horizontal'){'tabs.chevron'}else{'rail.profile'}
  Click $s[$key]
  Aio expect state profile_menu.open=true
  $s=State
  foreach($k in $s.Keys) { if ($k -match '^profile_menu.row.\d+.label$' -and $s[$k] -in @('Settings','Command Palette')) {throw 'App action remains in profile menu'} }
  Aio key Esc
  Aio capture --out "build/verify/title-actions/$mode.png"
  Write-Output "PASS $mode geometry, settings, palette and profile-only dropdown"
 }
} finally { Aio stop }

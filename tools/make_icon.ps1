[CmdletBinding()]
param()

# Renders assets/aiodev.svg (32 px and up) and assets/aiodev-small.svg (16 to 24 px, drawn without
# blur so it stays sharp) with headless Microsoft Edge, then writes assets/aiodev.ico and the 256 px
# assets/aiodev-notification.png.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
$edge = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) { throw 'make_icon.ps1 needs Microsoft Edge to render the icon SVGs.' }

$sizes = @(16, 20, 24, 32, 40, 48, 64, 256)
$sources = @{
    full  = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $assets 'aiodev.svg')))
    small = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $assets 'aiodev-small.svg')))
}
$work = Join-Path ([IO.Path]::GetTempPath()) ('aiodev-icon-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$entries = New-Object 'System.Collections.Generic.List[byte[]]'

try {
    foreach ($size in $sizes) {
        $source = if ($size -le 24) { $sources.small } else { $sources.full }
        $html = Join-Path $work "icon-$size.html"
        $shot = Join-Path $work "icon-$size.png"
        [IO.File]::WriteAllText($html, "<!doctype html><html><body style=`"margin:0;background:transparent`"><img src=`"data:image/svg+xml;base64,$source`" width=`"$size`" height=`"$size`" style=`"display:block`"></body></html>")
        # A window smaller than Edge's minimum is widened, so render into a 256 px window and crop.
        $arguments = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
            '--force-device-scale-factor=1', '--default-background-color=00000000',
            "--user-data-dir=`"$(Join-Path $work 'profile')`"", '--window-size=256,256',
            "--screenshot=`"$shot`"", ('"file:///' + ($html -replace '\\', '/') + '"'))
        Start-Process -FilePath $edge -ArgumentList $arguments -Wait -WindowStyle Hidden
        if (-not (Test-Path -LiteralPath $shot)) { throw "Edge did not write $shot." }

        $full = [Drawing.Bitmap]::FromFile($shot)
        $stream = New-Object IO.MemoryStream
        try {
            $crop = $full.Clone((New-Object Drawing.Rectangle(0, 0, $size, $size)), [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                if ($crop.GetPixel(0, 0).A -ne 0) { throw "The $size px render has an opaque corner; Edge did not keep the background transparent." }
                $crop.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $crop.Dispose() }
            $entries.Add($stream.ToArray())
        }
        finally {
            $stream.Dispose()
            $full.Dispose()
        }
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

[IO.File]::WriteAllBytes((Join-Path $assets 'aiodev-notification.png'), $entries[$sizes.Count - 1])
$file = [IO.File]::Create((Join-Path $assets 'aiodev.ico'))
$writer = New-Object IO.BinaryWriter($file)
try {
    $writer.Write([UInt16]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([UInt32]$entries[$i].Length)
        $writer.Write([UInt32]$offset)
        $offset += $entries[$i].Length
    }
    foreach ($entry in $entries) { $writer.Write([byte[]]$entry) }
}
finally {
    $writer.Dispose()
    $file.Dispose()
}

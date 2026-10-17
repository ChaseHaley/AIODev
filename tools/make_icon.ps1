[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$sizes = @(16, 20, 24, 32, 40, 48, 64, 256)
$entries = New-Object 'System.Collections.Generic.List[byte[]]'

foreach ($size in $sizes) {
    $bitmap = New-Object System.Drawing.Bitmap($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $gradient = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect, [System.Drawing.ColorTranslator]::FromHtml('#1b1e24'),
        [System.Drawing.ColorTranslator]::FromHtml('#0f1115'), 90)
    $pen = New-Object System.Drawing.Pen(
        [System.Drawing.ColorTranslator]::FromHtml('#e6e9ef'), ([single]($size / 8)))
    $cursor = New-Object System.Drawing.SolidBrush(
        [System.Drawing.ColorTranslator]::FromHtml('#61afef'))
    $stream = New-Object System.IO.MemoryStream
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $radius = [single]($size / 4)
        $path.AddArc(0, 0, $radius, $radius, 180, 90)
        $path.AddArc($size - $radius, 0, $radius, $radius, 270, 90)
        $path.AddArc($size - $radius, $size - $radius, $radius, $radius, 0, 90)
        $path.AddArc(0, $size - $radius, $radius, $radius, 90, 90)
        $path.CloseFigure()
        $graphics.FillPath($gradient, $path)
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Square
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Square
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Miter
        $points = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF(($size * 0.28), ($size * 0.31))),
            (New-Object System.Drawing.PointF(($size * 0.46), ($size * 0.5))),
            (New-Object System.Drawing.PointF(($size * 0.28), ($size * 0.69))))
        $graphics.DrawLines($pen, $points)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        $graphics.FillRectangle($cursor, [single][Math]::Round($size * 0.56),
            [single][Math]::Round($size * 0.63), [single][Math]::Round($size * 0.22),
            [single][Math]::Max(2, [Math]::Round($size / 8)))
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $entries.Add($stream.ToArray())
    }
    finally {
        $stream.Dispose()
        $cursor.Dispose()
        $pen.Dispose()
        $gradient.Dispose()
        $path.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$output = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\aiodev.ico'
$file = [System.IO.File]::Create($output)
$writer = New-Object System.IO.BinaryWriter($file)
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

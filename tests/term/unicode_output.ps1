$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$output = [Console]::OpenStandardOutput()
$escape = [char]27
$output.Write([Text.Encoding]::UTF8.GetBytes("$escape[2J$escape[H"))
foreach ($line in [IO.File]::ReadLines((Join-Path $PSScriptRoot '../fixtures/unicode.txt'))) {
    $fields = (($line -split '#', 2)[0].Trim() -split '\s+')
    if ($fields.Count -lt 3) { continue }
    $bytes = [Collections.Generic.List[byte]]::new()
    foreach ($match in [regex]::Matches($fields[2], '<(x[0-9A-Fa-f]{2}|[0-9A-Fa-f]+)>|.')) {
        $token = $match.Groups[1].Value
        if ($token.StartsWith('x')) { $bytes.Add([Convert]::ToByte($token.Substring(1), 16)) }
        elseif ($token) {
            $bytes.AddRange([Text.Encoding]::UTF8.GetBytes([char]::ConvertFromUtf32([Convert]::ToInt32($token, 16))))
        } else { $bytes.AddRange([Text.Encoding]::UTF8.GetBytes($match.Value)) }
    }
    $output.Write($bytes.ToArray())
    $output.Write([Text.Encoding]::UTF8.GetBytes("!`r`n"))
}
$output.Write([Text.Encoding]::UTF8.GetBytes('UNICODE_COMPLETE'))
$output.Flush()

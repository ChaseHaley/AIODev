[CmdletBinding()]
param()

# Regenerates assets/program_art.txt, the bundled program artwork (WORK-279), from pinned icon
# packages and the SVGs in assets/program_art. Each line is `names|layer[|layer...]`: executable
# stems or reported app keys separated by commas, then one layer per SVG path, drawn in order. A
# layer is `colour:rule:path`: the path's fill as six hex digits or empty for the theme text
# colour, the SVG fill rule, and path data drawn in a 24-unit square (WORK-290). Every logo with
# a licence other than CC0 must be credited in THIRD_PARTY_NOTICES.txt. Needs npm and tar on PATH.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$sources = @{
    si   = @{ package = 'simple-icons'; version = '16.36.0'; licence = 'CC0-1.0 unless listed' }
    lobe = @{ package = '@lobehub/icons-static-svg'; version = '1.101.0'; licence = 'MIT' }
}
# Artwork kept in this repository, each SVG crediting its source and licence in a comment.
$local = Join-Path $root 'assets/program_art'
$notices = Get-Content (Join-Path $root 'THIRD_PARTY_NOTICES.txt') -Raw

# names, source:slug, and a colour for LobeHub artwork, whose monochrome files carry none. Simple
# Icons entries take the package's brand colour unless one is given.
$manifest = @(
    # Agents
    ,@('claude,claude-code', 'lobe:claudecode', 'D97757')
    ,@('codex,codex-x86_64-pc-windows-msvc,codex-aarch64-pc-windows-msvc', 'lobe:codex', '7A9DFF')
    ,@('gemini', 'si:googlegemini', '')
    ,@('copilot,github-copilot', 'si:githubcopilot', '')
    ,@('opencode', 'lobe:opencode', '')
    ,@('amp', 'lobe:amp', 'F34E3F')
    ,@('cursor-agent,cursor', 'lobe:cursor', '')
    ,@('qwen', 'lobe:qwen', '082DFF')
    ,@('kimi', 'lobe:kimi', '1783FF')
    ,@('goose', 'lobe:goose', '')
    ,@('cline', 'lobe:cline', '')
    ,@('kilocode,kilo', 'lobe:kilocode', '')
    ,@('junie', 'lobe:junie', '47E054')
    ,@('ollama', 'si:ollama', '')
    ,@('omp,pi-coding-agent', 'file:omp', '')
    # Editors
    ,@('nvim,neovim', 'file:neovim', '')
    ,@('vim,gvim', 'si:vim', '')
    ,@('hx,helix', 'si:helix', '')
    # Runtimes and REPLs
    ,@('node,nodejs', 'si:nodedotjs', '')
    ,@('deno', 'si:deno', '')
    ,@('bun,bunx', 'si:bun', '')
    ,@('python,python3,pythonw,py,ipython,uvicorn', 'si:python', '')
    ,@('ruby,irb,rails', 'si:ruby', '')
    ,@('lua,luajit', 'si:lua', '')
    ,@('go', 'si:go', '')
    ,@('cargo,rustc,rustup', 'si:rust', '')
    ,@('dotnet', 'si:dotnet', '')
    ,@('php', 'si:php', '')
    ,@('java,javaw,jshell', 'si:openjdk', '')
    ,@('kotlin,kotlinc', 'si:kotlin', '')
    ,@('zig', 'si:zig', '')
    ,@('elixir,iex,mix', 'si:elixir', '')
    ,@('erl,werl', 'si:erlang', '')
    ,@('ghc,ghci,cabal,stack', 'si:haskell', '')
    ,@('julia', 'si:julia', '')
    ,@('r,rterm', 'si:r', '')
    ,@('perl', 'si:perl', '')
    ,@('ocaml,utop,dune', 'si:ocaml', '')
    ,@('swift', 'si:swift', '')
    ,@('scala,sbt', 'si:scala', '')
    ,@('clojure,clj,lein', 'si:clojure', '')
    ,@('gleam', 'si:gleam', '')
    # Package managers and builds
    ,@('npm', 'si:npm', '')
    ,@('pnpm,pnpx', 'si:pnpm', '')
    ,@('yarn', 'si:yarn', '')
    ,@('pip,pip3', 'si:pypi', '')
    ,@('uv,uvx', 'si:uv', '')
    ,@('poetry', 'si:poetry', '')
    ,@('gradle,gradlew', 'si:gradle', '')
    ,@('mvn', 'si:apachemaven', '')
    ,@('cmake,ctest', 'si:cmake', '')
    # Tools
    ,@('git', 'si:git', '')
    ,@('gh', 'si:github', '')
    ,@('docker,docker-compose', 'si:docker', '')
    ,@('podman', 'si:podman', '')
    ,@('kubectl,k9s,minikube,kind', 'si:kubernetes', '')
    ,@('helm', 'si:helm', '')
    ,@('terraform,tofu', 'si:terraform', '')
    ,@('ansible,ansible-playbook', 'si:ansible', '')
    ,@('gcloud', 'si:googlecloud', '')
    ,@('psql,postgres,pg_dump', 'si:postgresql', '')
    ,@('mysql,mysqld,mariadb', 'si:mysql', '')
    ,@('redis-cli,redis-server', 'si:redis', '')
    ,@('sqlite3,sqlite', 'si:sqlite', '')
    ,@('mongosh,mongod', 'si:mongodb', '')
    ,@('htop', 'si:htop', '')
    ,@('curl', 'si:curl', '')
    ,@('ffmpeg,ffprobe,ffplay', 'si:ffmpeg', '')
    ,@('tmux', 'si:tmux', '')
)

$work = Join-Path ([IO.Path]::GetTempPath()) "aiodev-program-art-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
try {
    $folders = @{}
    foreach ($key in $sources.Keys) {
        $source = $sources[$key]
        $folder = Join-Path $work $key
        New-Item -ItemType Directory -Force $folder | Out-Null
        Push-Location $folder
        try {
            $tarball = & npm pack "$($source.package)@$($source.version)" --silent
            if ($LASTEXITCODE -ne 0) { throw "npm pack $($source.package) failed." }
            & tar -xzf $tarball
            if ($LASTEXITCODE -ne 0) { throw "Extracting $tarball failed." }
        } finally {
            Pop-Location
        }
        $folders[$key] = Join-Path $folder 'package'
    }
    $brand = @{}
    # Simple Icons slugs whose logos carry a licence other than CC0, and the title they are credited by.
    $credit = @{}
    foreach ($icon in (Get-Content (Join-Path $folders.si 'data/simple-icons.json') -Raw | ConvertFrom-Json)) {
        $slug = $icon.slug
        if (-not $slug) {
            # Simple Icons derives a missing slug from the title (titleToSlug in its SDK).
            $slug = $icon.title.ToLowerInvariant().Replace('+', 'plus').Replace('.', 'dot').Replace('&', 'and')
            $slug = $slug.Normalize([Text.NormalizationForm]::FormD) -replace '[^a-z0-9]', ''
        }
        $brand[$slug] = $icon.hex
        if ($icon.license -and $icon.license.type -ne 'CC0-1.0') { $credit[$slug] = $icon.title }
    }

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Bundled program artwork (WORK-279). Generated by tools/program_art.ps1; do not edit.')
    foreach ($key in ($sources.Keys | Sort-Object)) {
        $source = $sources[$key]
        $lines.Add("# $key = $($source.package) $($source.version), $($source.licence)")
    }
    $lines.Add('# file = assets/program_art, licences in each file')
    $lines.Add('# names|colour:rule:path[|colour:rule:path...]')
    $seen = @{}
    foreach ($entry in $manifest) {
        $names, $from, $colour = $entry
        foreach ($name in $names.Split(',')) {
            if ($name -cne $name.ToLowerInvariant()) { throw "Name $name must be lower case." }
            if ($seen.ContainsKey($name)) { throw "Name $name is listed twice." }
            $seen[$name] = $true
        }
        $set, $slug = $from.Split(':')
        $file = if ($set -eq 'file') { Join-Path $local "$slug.svg" } else { Join-Path $folders[$set] "icons/$slug.svg" }
        $svg = Get-Content $file -Raw
        if ($set -eq 'file') {
            if ($svg -notmatch 'Source: (\S+)') { throw "$from does not name its source." }
            if (-not $notices.Contains($Matches[1])) { throw "$from is not credited in THIRD_PARTY_NOTICES.txt." }
            $svg = $svg -replace '(?s)<!--.*?-->', ''
        }
        if ($credit.ContainsKey($slug) -and $set -eq 'si' -and -not $notices.Contains("$($credit[$slug]) logo")) {
            throw "$from has its own licence; credit `"$($credit[$slug]) logo`" in THIRD_PARTY_NOTICES.txt."
        }
        if ($svg -match '<(circle|rect|ellipse|polygon|polyline|line|use|g)\b|opacity|transform|gradient') {
            throw "$from uses SVG features the rasterizer does not draw."
        }
        if ($svg -notmatch 'viewBox="0 0 24 24"') { throw "$from is not drawn in a 24-unit square." }
        $rule = if ($svg -match '<svg[^>]*fill-rule="evenodd"') { 'evenodd' } else { 'nonzero' }
        if ($set -eq 'si' -and -not $colour) { $colour = $brand[$slug] }
        $layers = @(foreach ($tag in [regex]::Matches($svg, '<path\b[^>]*>')) {
            $text = $tag.Value
            if ($text -notmatch '\sd="([^"]+)"') { throw "$from has a path without data." }
            $data = $Matches[1]
            if ($data -match '[:|]') { throw "$from has path data the table cannot hold." }
            $fill = $colour
            if ($text -match '\sfill="#([0-9A-Fa-f]{6})"') {
                $fill = $Matches[1].ToUpperInvariant()
            } elseif ($text -match '\sfill=') {
                throw "$from has a fill other than six-digit hex."
            }
            $layerRule = $rule
            if ($text -match '\sfill-rule="(evenodd|nonzero)"') { $layerRule = $Matches[1] }
            "${fill}:${layerRule}:$data"
        })
        if ($layers.Count -eq 0) { throw "$from has no path data." }
        $lines.Add("$names|$($layers -join '|')")
    }
    $out = Join-Path $root 'assets/program_art.txt'
    [IO.File]::WriteAllText($out, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Output "Wrote $($manifest.Count) programs to $out"
} finally {
    Remove-Item -Recurse -Force $work
}

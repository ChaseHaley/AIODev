[CmdletBinding()]
param()

# Regenerates assets/program_art.txt, the bundled program artwork (WORK-279), from pinned icon
# packages. Each line is `names|colour|rule|path[|path...]`: executable stems or reported app keys
# separated by commas, a brand colour as six hex digits or empty for the theme text colour, the SVG
# fill rule, and path data drawn in a 24-unit square. Needs npm and tar on PATH.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$sources = @{
    si   = @{ package = 'simple-icons'; version = '16.36.0'; licence = 'CC0-1.0' }
    lobe = @{ package = '@lobehub/icons-static-svg'; version = '1.101.0'; licence = 'MIT' }
}

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
    # Editors
    ,@('nvim,neovim', 'si:neovim', '')
    ,@('vim,gvim', 'si:vim', '')
    ,@('hx,helix', 'si:helix', '')
    ,@('emacs,emacsclient', 'si:gnuemacs', '')
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
    foreach ($icon in (Get-Content (Join-Path $folders.si 'data/simple-icons.json') -Raw | ConvertFrom-Json)) {
        $slug = $icon.slug
        if (-not $slug) {
            # Simple Icons derives a missing slug from the title (titleToSlug in its SDK).
            $slug = $icon.title.ToLowerInvariant().Replace('+', 'plus').Replace('.', 'dot').Replace('&', 'and')
            $slug = $slug.Normalize([Text.NormalizationForm]::FormD) -replace '[^a-z0-9]', ''
        }
        $brand[$slug] = $icon.hex
    }

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Bundled program artwork (WORK-279). Generated by tools/program_art.ps1; do not edit.')
    foreach ($key in ($sources.Keys | Sort-Object)) {
        $source = $sources[$key]
        $lines.Add("# $key = $($source.package) $($source.version), $($source.licence)")
    }
    $lines.Add('# names|colour|rule|path[|path...]')
    $seen = @{}
    foreach ($entry in $manifest) {
        $names, $from, $colour = $entry
        foreach ($name in $names.Split(',')) {
            if ($name -cne $name.ToLowerInvariant()) { throw "Name $name must be lower case." }
            if ($seen.ContainsKey($name)) { throw "Name $name is listed twice." }
            $seen[$name] = $true
        }
        $set, $slug = $from.Split(':')
        $file = Join-Path $folders[$set] "icons/$slug.svg"
        $svg = Get-Content $file -Raw
        if ($svg -match '<(circle|rect|ellipse|polygon|polyline|line|use|g)\b|opacity|transform') {
            throw "$from uses SVG features the rasterizer does not draw."
        }
        if ($svg -notmatch 'viewBox="0 0 24 24"') { throw "$from is not drawn in a 24-unit square." }
        $paths = @([regex]::Matches($svg, '<path[^>]*\sd="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        if ($paths.Count -eq 0) { throw "$from has no path data." }
        $rule = if ($svg -match 'fill-rule="evenodd"') { 'evenodd' } else { 'nonzero' }
        if ($set -eq 'si' -and -not $colour) { $colour = $brand[$slug] }
        $lines.Add("$names|$colour|$rule|$($paths -join '|')")
    }
    $out = Join-Path $root 'assets/program_art.txt'
    [IO.File]::WriteAllText($out, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Output "Wrote $($manifest.Count) programs to $out"
} finally {
    Remove-Item -Recurse -Force $work
}

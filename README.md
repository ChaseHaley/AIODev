# AIODev

AIODev is a terminal emulator for Windows 11, built in [Odin](https://odin-lang.org) on
[libghostty-vt](https://github.com/ghostty-org/ghostty) and ConPTY.

It exists because other Windows terminals did not provide the UX I want in a modern terminal.
It is heavily inspired by [Rex](https://www.superlogical.com/rex) (without the multiplexing) and
the Vivaldi browser.

> [!WARNING]
> AIODev is very early access and heavily vibe coded, with the slop slowly being cleaned up
> alongside new features and bug fixes. Expect rough edges and breaking changes between releases.

## Features

- Workspaces, tabs (horizontal or vertical) and nested split panes, with drag to rearrange
  panes and tabs, including across windows
- An everything palette that runs every command and edits settings in place
- A Settings tab, plus a reloadable settings file and JSON themes
- Find in scrollback, clickable links, ligatures and Unicode-correct rendering through a
  bundled ConPTY
- Program status and native Windows notifications per pane
- `aio`, a command line for scripts and coding agents to open, split, type into and read panes

Menus, naming fields, the workspace picker and confirmation dialogs take turns owning a window's
input. Opening one dismisses the previous surface without saving an unfinished rename. Leaving a
workspace's name chip by clicking elsewhere or changing focus keeps the name when it is available;
Enter leaves a duplicate name open for correction. The everything palette belongs to one window at
a time, including while it fades out.

## Install

In PowerShell, to install or upgrade:

```powershell
irm https://github.com/ChaseHaley/AIODev/releases/latest/download/install.ps1 | iex
```

Each release's `install.ps1` downloads that release's zip and refuses it unless its SHA256 matches.
To install from the zip instead, download `AIODev-<version>-windows-x64.zip` from
[Releases](https://github.com/ChaseHaley/AIODev/releases), extract it and run
`powershell -ExecutionPolicy Bypass -File AIODev\install.ps1`; the policy applies to that run only.

An installed AIODev updates itself: run Update AIODev from the everything palette. It installs the
latest release while AIODev keeps running, then offers to restart into it. Restarting ends the
programs running in panes; your layout and agent conversations come back. Installing while AIODev
runs also works from any terminal; AIODev keeps running the previous version until Restart AIODev
(also in the everything palette) starts the new one.

The installer is per user: it copies AIODev to `%LOCALAPPDATA%\Programs\AIODev`, adds `aio` to your
PATH and creates a Start menu shortcut. Settings live in `%APPDATA%\AIODev`; saved layouts and logs
live in `%LOCALAPPDATA%\AIODev`.

To uninstall, quit AIODev and run:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\AIODev\uninstall.ps1"
```

It removes the installed files, the PATH entry, the Start menu shortcut and AIODev's notification
registration. It keeps your settings, layouts and logs, and says where they are.

"Reload settings" refreshes open settings pages while keeping pending fields whose rows still exist.
A save refuses to overwrite an external file edit; reload before saving that draft again. Delete Theme
asks for a second press on the same theme; navigation, Escape, a settings revision or closing Settings
ends that prompt.

Releases are not code signed yet, so Windows SmartScreen may warn on first launch. See the
[code signing policy](#code-signing-policy).

## Neovim follows the theme

Neovim run in an AIODev pane can follow the active theme, live. AIODev writes the theme to
`<data folder>\nvim\current.json` whenever it changes and gives panes its path in `AIODEV_THEME_FILE`.
The plugin that reads it is the `nvim` folder beside `aiodev.exe`. Add this to your `init.lua`:

```lua
if vim.env.AIODEV_CLI then vim.opt.rtp:append(vim.fs.dirname(vim.env.AIODEV_CLI) .. "/nvim") require("aiodev_theme").setup() end
```

The plugin sets `background`, applies the theme's colorscheme when it is installed and otherwise one
generated from the theme's palette (`:colorscheme aiodev`). It installs nothing. Outside AIODev
`AIODEV_CLI` is unset and nothing happens. Neovim configs that do not use the plugin and follow
`background` also switch live, because AIODev reports light or dark to programs that ask for it.

A theme file names its colorscheme in an optional `neovim` object, and AIODev's themes name these
plugins. With lazy.nvim, `lazy = true` is enough: it loads the plugin when the colorscheme is applied.

| Themes | lazy.nvim spec | Colorscheme |
| --- | --- | --- |
| Tokyo Night, Moon, Storm and Day | `{ "folke/tokyonight.nvim", lazy = true }` | `tokyonight-night`, `-moon`, `-storm`, `-day` |
| Catppuccin Latte, Frappe, Macchiato, Mocha | `{ "catppuccin/nvim", name = "catppuccin", lazy = true }` | `catppuccin-latte`, `-frappe`, `-macchiato`, `-mocha` |
| Gruvbox Dark, Light | `{ "ellisonleao/gruvbox.nvim", lazy = true }` | `gruvbox` |
| Dracula | `{ "Mofiqul/dracula.nvim", lazy = true }` | `dracula` |
| One Dark | `{ "navarasu/onedark.nvim", lazy = true }` | `onedark` |
| Nord | `{ "gbprod/nord.nvim", lazy = true }` | `nord` |
| Palenight | `{ "drewtempelmeyer/palenight.vim", lazy = true }` | `palenight` |

Studio, Tide and Ember use the generated colorscheme. A custom theme uses the colorscheme of the theme
it is based on, so customizing Tokyo Night Day keeps `tokyonight-day`, and one based on Studio uses
the generated colorscheme. To name another, add `theme.custom.ID.neovim = name` to `settings.ini`, or
`"neovim": { "plugin": "owner/repository", "colorscheme": "name" }` to a theme file (`plugin` is
optional). The name `aiodev` picks the generated colorscheme. Theme files hold data only, never Lua.

## Build from source

Requirements:

- Windows 11 x64
- PowerShell 7
- Visual Studio 2022 (or Build Tools) with the C++ x64 tools and a Windows SDK
- Odin `dev-2026-09` (developed against nightly `a2fb372`)

```powershell
./build.ps1          # debug build: build/aiodev.exe
./build.ps1 run      # build and launch
./build.ps1 check    # vet, style and type checks
./build.ps1 test     # all test packages (or ./build.ps1 test <package>)
./build.ps1 release  # optimized build: build/release/aiodev.exe
./build.ps1 package  # release zip and SHA256 in build/
./build.ps1 types    # regenerate types/aio.lua, the aio Lua API for lua-language-server
```

`vendor/ghostty` holds a prebuilt libghostty-vt release pinned by version and SHA256 in
`vendor/ghostty/VERSION`, with local patches in `vendor/ghostty/patches`. Rebuilding it needs Zig
0.17: `tools/build_ghostty.ps1 -Zig <path to zig.exe>`. `tools/toolchain.ps1 -Destination <dir>`
downloads the pinned Odin and Zig and checks their SHA256.

Releases are built on GitHub Actions by `.github/workflows/release.yml`, which rebuilds libghostty-vt
for `x86_64_v2` from the pinned source before packaging. Every pushed commit's run offers its unsigned
package as a download; `tools/release.ps1 <version>` runs `build.ps1 check`, then tags and pushes,
and the tag's run publishes the release.

Floating UI surfaces use `ui.Presence` transitions for opening, closing and releasing their
payloads. Toasts live in one list with entering, timed, sticky or fading state; fading a toast
also releases its close-button press and hover. The `ui` and `app` test packages cover these
lifetimes with and without animations.

Pane focus changes are bracketed in `src/focus_bracket.odin`: each window records the pane it
entered, so repeating an enter or leave does not repeat a terminal focus report. Layout saving
uses Disabled, Idle and Scheduled states in `src/layout_state.odin`; disabling it drops any
pending save and releases its path.

## Code signing policy

Windows releases are to be signed with a free code signing certificate from
[SignPath Foundation](https://signpath.org), through [SignPath.io](https://about.signpath.io), once
the project's application is accepted. Until then releases are unsigned.

- Only release builds made by `.github/workflows/release.yml` on GitHub-hosted runners, from a
  tagged commit of this repository, are submitted for signing. The bundled Microsoft ConPTY files keep
  Microsoft's own signatures and are not re-signed.
- Committers and reviewers: [Chase Haley](https://github.com/ChaseHaley)
- Approvers: [Chase Haley](https://github.com/ChaseHaley)

Privacy: AIODev does not transfer any information to other networked systems unless specifically
requested by the user or the person installing or operating it. Programs you run inside AIODev
follow their own privacy policies.

## License

AIODev is released under the [MIT License](LICENSE). Release packages include third-party
components under their own licenses, listed in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

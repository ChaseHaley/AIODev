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
- A command palette that runs every command and edits settings in place
- A Settings tab, plus a reloadable settings file and JSON themes
- Find in scrollback, clickable links, ligatures and Unicode-correct rendering through a
  bundled ConPTY
- Program status and native Windows notifications per pane
- `aio`, a command line for scripts and coding agents to open, split, type into and read panes

## Install

1. Download the latest `AIODev-<version>-windows-x64.zip` from
   [Releases](https://github.com/ChaseHaley/AIODev/releases) and check it against the `.sha256` file.
2. Extract it and run `AIODev\install.ps1` in PowerShell.

The installer is per user: it copies AIODev to `%LOCALAPPDATA%\Programs\AIODev`, adds `aio` to your
PATH and creates a Start menu shortcut. Settings live in `%LOCALAPPDATA%\AIODev`.

Releases are not code signed yet, so Windows SmartScreen may warn on first launch.

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
```

`vendor/ghostty` holds a prebuilt libghostty-vt pinned to `vendor/ghostty/REVISION`. Rebuilding it
needs Zig 0.16: `tools/build_ghostty.ps1`.

Pane focus changes are bracketed in `src/focus_bracket.odin`: each window records the pane it
entered, so repeating an enter or leave does not repeat a terminal focus report. Layout saving
uses Disabled, Idle and Scheduled states in `src/layout_state.odin`; disabling it drops any
pending save and releases its path.

## License

AIODev is released under the [MIT License](LICENSE). Release packages include third-party
components under their own licenses, listed in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

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

Menus, naming fields, the workspace picker and confirmation dialogs take turns owning a window's
input. Opening one dismisses the previous surface without saving an unfinished rename. Leaving a
workspace's name chip by clicking elsewhere or changing focus keeps the name when it is available;
Enter leaves a duplicate name open for correction. The command palette belongs to one window at a
time, including while it fades out.

## Install

Quit AIODev if it is running, then in PowerShell, to install or upgrade:

```powershell
irm https://github.com/ChaseHaley/AIODev/releases/latest/download/install.ps1 | iex
```

Each release's `install.ps1` downloads that release's zip and refuses it unless its SHA256 matches.
To install from the zip instead, download `AIODev-<version>-windows-x64.zip` from
[Releases](https://github.com/ChaseHaley/AIODev/releases), extract it and run
`powershell -ExecutionPolicy Bypass -File AIODev\install.ps1`; the policy applies to that run only.

The installer is per user: it copies AIODev to `%LOCALAPPDATA%\Programs\AIODev`, adds `aio` to your
PATH and creates a Start menu shortcut. Settings live in `%APPDATA%\AIODev`; saved layouts and logs
live in `%LOCALAPPDATA%\AIODev`.

To uninstall, quit AIODev and run:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\AIODev\uninstall.ps1"
```

It removes the installed files, the PATH entry, the Start menu shortcut and AIODev's notification
registration. It keeps your settings, layouts and logs, and says where they are.

Reload Settings refreshes open settings pages while keeping pending fields whose rows still exist.
A save refuses to overwrite an external file edit; reload before saving that draft again. Delete Theme
asks for a second press on the same theme; navigation, Escape, a settings revision or closing Settings
ends that prompt.

Releases are not code signed yet, so Windows SmartScreen may warn on first launch. See the
[code signing policy](#code-signing-policy).

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

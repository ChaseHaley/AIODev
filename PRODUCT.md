# Product

<!-- impeccable:product-schema 1 -->

## Platform

windows

## Users

The owner comes first: a developer on Windows 11 who uses PowerShell 7 daily, is replacing WezTerm with AIODev, and runs coding agents in panes. When needs conflict, the owner's daily workflow decides.

Early-access Windows developers come second. They benefit from the same choices but do not outrank them.

Scripts and coding agents also use the product, driving panes through the `aio` command line and the same commands as the interface.

## Product Purpose

AIODev is a local terminal workspace for Windows 11. It exists because other Windows terminals did not provide the UX the owner wants in a modern terminal. WezTerm's capabilities are good, but its UI is not: panes can't be grabbed and moved with the cursor, tabs aren't modern, configuration requires Lua and a leader key is forced.

Success means completing real development sessions without abandoning AIODev because of missing or broken terminal behavior.

The longer-term vision is one environment that also replaces the editor, notes and agent harness, with Git and code review as likely additions. That design is intentionally fuzzy and uncommitted. Design for the terminal workspace that ships today, and treat nothing beyond it as a shipped feature.

## Positioning

A native Windows terminal with direct manipulation at its center: panes and tabs can be dragged anywhere, including across windows, and one palette runs every command and edits settings in place. It takes strong inspiration from Rex (without its multiplexer or server model) and from the Vivaldi browser. These are design references, not products to imitate wholesale.

## Operating Context

AIODev is meant to be the daily terminal, across workspaces and multiple OS windows. Coding agents run in panes, so seeing which program is working, blocked, finished or in error, and jumping to it, is part of the normal workflow.

## Capabilities and Constraints

Shipped: workspaces, horizontal or vertical tabs, nested split panes, command palette, Settings as ordinary pane content, reloadable settings file, JSON themes, shell profiles, program status and native notifications, multiple windows, layout restore, terminal links, find in scrollback, and the `aio` command line. The feature map in the vault (`AIODev/Validation Tooling/Recipes/Feature map.md`) is the authoritative list.

Terminology: workspaces group tabs, tabs group panes. One shared set of workspaces spans all OS windows.

Lifecycle: closing the GUI keeps the app and its processes running, and reopening returns to live sessions. A full exit stops the work, and the next launch restores layout and directories with fresh shells.

Technical: written in Odin on libghostty-vt and a bundled ConPTY, with a custom renderer. There is no web layer, so web tooling and browser-based previews don't apply. Windows 11 x64 is the only working platform. Linux and macOS are unbuilt, and any port is undecided.

Settings: everything is available through the UI with direct shortcuts by default. Scriptable configuration and leader keys are welcome as options, never as requirements.

Undecided: tabs inside panes and nested workspace containers remain proposed and deferred.

The interface's visual rules are recorded in the vault (`AIODev/Product/Visual language.md`) and enforced from `src/ui/design.odin`.

## Brand Commitments

The name is AIODev. The command line is `aio`.

Interaction feel is a stated commitment: smooth, frame-perfect animation, snappy response and graceful handling of process failures.

Public copy is candid about maturity. The README states that AIODev is very early access and heavily vibe coded, and warns of rough edges and breaking changes.

## Evidence on Hand

- Performance measurements in the vault under `AIODev/Terminal/Evidence/Performance`. Faster than Windows Terminal and WezTerm is a goal being climbed toward, so cite a specific dated result rather than claiming a general lead.
- App icon and notification artwork in `assets/`, and bundled program artwork in `assets/program_art`.
- MIT license, with third-party licenses in `THIRD_PARTY_NOTICES.txt`.
- Releases are not code signed yet.

No testimonials, customer names, user counts, press or pricing exist. Do not invent them.

## Product Principles

- Include only what helps the user act, understand state or decide. Removing an element should make the task less clear, or the element goes.
- Performance is a top priority, and changes that could affect it get measured.
- Grab it and move it: direct manipulation comes before configuration.
- Offer power as an option. Nothing advanced should be required to use the basics.
- Judge progress by real use and demonstrated behavior.

Vibe coded slop terminal for Windows powered by [libghostty-vt from the Ghostty project](https://github.com/ghostty-org/ghostty/tree/main). Read the code at your own risk.

The goal is a terminal with great UX. Or at least, what is great UX to my specific taste. Very early work in progress.

This is also a bit of a test for how lazy I can be with AI. I'm a full time developer. I take great care with my work. This is made in my free time, I like my free time. So I did not take great care with this.
This project is one of my attempts at testing frontier (for now) models (Opus 5.5, Sol 6.1) with no code review. I made choices in the languages (Odin is fun! Maybe my agents will enjoy it too?), the libraries (libghostty-vt, without which this project would not exist), and of course creative choices.
I know what I wanted in a terminal. So I continuously use the terminal and give feedback in addition to the initial long winded vision I described to my agents.
This has gone surprisingly well (from a user perspective anyways, the code is _u_ _g_ _l_ _y_), so I've uploaded it to GitHub for others to use. I am terrified to look at the code closely. But maybe a good user experience, at the end of the day, is all that matters (_cope_).

# Showcase (a bad one)
https://github.com/user-attachments/assets/121ed4ec-85ea-4a96-810d-a93f5c0d93b7
* I'm missing a lot. I'll make another one eventually. But look at that pane dragging!

## Another showcase. I forgot about the Settings page
https://github.com/user-attachments/assets/28d9fb77-be30-4786-b758-f88f1e93023f
* In case you thought that last showcase couldn't get any worse!
* Added because settings are pretty important. It's one of my complaints about WezTerm. Lua scripting is awesome! But sometimes I just want a GUI to tweak things.
* I'll have Lua scripting for advanced tweaks too! But I'm starting with GUI settings for now.
* Oh and yes themes! There are three built in, each with a light and dark mode. There will be support for community themes of course. It's a requirement.

# Features

## Windows
* It's the window! You know what a window is. It displays a single workspace.
* You can have more than one. Revolutionary.
* All windows share the same pool of workspaces.

## Workspaces
* Groups of tabs
* All workspaces are available to all windows.
* A workspace can only be open in one window at a time, this it NOT a multiplexer. Read FAQ question 1 for more info on why.
* Attempting to open a workspace that's already opened in another window will focus that window.

## Splits and Panes
* Draggable to move and reshape within a tab, across tabs, and across windows.
* Will soon support moving panes across workspaces

## Tabs
* Groups of panes
* You can open a lot of them very quickly! Some might say too quickly...
* Supports multi-select. Useful for when you open too many by accident and need to mass close! Or just move a couple of tabs at the same time.

## Settings

# Inspiration
* [Ghostty](https://ghostty.org), [Rex](https://www.superlogical.com/rex/docs/installation), [Superlogical](https://www.superlogical.com), and basically everything Mitchell Hashimoto has done with terminals. Please make a Superlogical terminal for Windows. It will definitely be better than this one (obviously in code quality, but in UX too!).
* [WezTerm](https://wezterm.org/index.html), my daily driver (before this)! It does just about everything I want... except look nice and provide a more sane defaults out of the box.
* [Windows Terminal](https://github.com/microsoft/terminal). Yes, that one. It's good! It's just missing a few things...
* [Vivaldi](https://vivaldi.com). The browser? Yes! I love the behavior of its workspaces, so that's how AIODev's workspace behave. Also, you should use Vivaldi. It's the best browser I've ever used.

# FAQ
## Q: Is there multiplexing like Rex?
Nope! That sounds way too difficult. Please re-read the first 4 words of this README for more information.
## Q: Does this track coding agent statuses?
Not yet, but soon! When I get to getting an agent to get to it. But soon! Probably.

   And that's the end of my very long FAQ. Thank you for reading.

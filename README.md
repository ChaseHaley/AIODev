Vibe coded slop terminal for Windows powered by [libghostty-vt from the Ghostty project](https://github.com/ghostty-org/ghostty/tree/main). Read the code at your own risk.

The goal is a terminal with great UX. Or at least, what is great UX to my specific taste. Very early work in progress.

This is also a bit of a test for how lazy I can be with AI. I'm a full time developer. I take great care with my work. This is made in my free time, I like my free time. So I did not take great care with this.
This project is one of my attempts at testing frontier (for now) models (Opus 5.5, Sol 6.1) with no code review. I made choices in the languages (Odin is fun! Maybe my agents will enjoy it too?), the libraries (libghostty-vt, without which this project would not exist), and of course creative choices.
I know what I wanted in a terminal. So I continuously use the terminal and give feedback in addition to the initial long winded vision I described to my agents.
This has gone surprisingly well (from a user perspective anyways, the code is _u_ _g_ _l_ _y_), so I've uploaded it to GitHub for others to use. I am terrified to look at the code closely. But maybe a good user experience, at the end of the day, is all that matters (_cope_).

# Features
## Splits and Panes
https://github.com/user-attachments/assets/121ed4ec-85ea-4a96-810d-a93f5c0d93b7
* Draggable to move and reshape within a tab, across tabs, and across windows.
* Will soon support moving panes across workspaces

## Workspaces
* Groups of tabs
* A workspace can only be open in one window at a time, this it NOT a multiplexer. Read FAQ question 1 for more info.
* 

## Tabs
* Groups of panes
* You can open a lot of them very quickly! Some might say too quickly...
* Supports multi-select. Useful for when you open too many by accident and need to mass close! Or just move a couple of tabs at the same time.

# Inspiration
* Ghostty, Rex, Superlogical, and basically everything Mitchell Hashimoto has done with terminals. Please make a Superlogical terminal for Windows.
* WezTerm, my daily driver (before this)! It does just about everything I want... except look nice and provide a more sane defaults out of the box.
* Windows Terminal. Yes, that one. It's good! It's just missing a few things...

# FAQ
1. Is there multiplexing like Rex?
   Nope! That sounds way too difficult. Please re-read the first 4 words of this README for more information as to why I'm not doing that.
And that's the end of my very long FAQ. Thank you for reading.

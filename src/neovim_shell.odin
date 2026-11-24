package main

import "aio:layout"
import "aio:neovim"
import "cosmos:platform"
import "aio:settings"
import "core:fmt"
import "core:log"
import "core:time"
import "cosmos:host"

// A Neovim pane behaves as Neovim run from a shell does (WORK-545): `aio pane.open_neovim` from a shell
// opens it in that pane, over the shell, which keeps running out of sight; quitting Neovim shows the
// shell again. Closing a pane, tab or AIODev with unsaved buffers asks first, and the pointer hides
// while typing.

// Shows `to` in the pane at `node` of `workspace`'s tab `tab_index` in place of `from`, keeping its split,
// float or linked slot. Windows that had `from` focused leave it and enter `to`.
@(private)
neovim_content_swap :: proc(
	app: ^App,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
	from, to: layout.Content,
) {
	tab := workspace.tabs[tab_index]
	focused := make([dynamic]^Window, 0, len(app.windows), context.temp_allocator)
	for w in app.windows {
		if current, ok := window_focused_content(w); ok && current == from {
			focus_leave(app, w)
			_, _ = append(&focused, w)
		}
	}
	pane := &tab.tree.nodes[node].(layout.Pane)
	pane.content = to
	focus_jumps_replace(&app.focus_jumps, workspace, from, to)
	tab_update_title(app, tab)
	workspace_mutation_finish(app, workspace, {.Names})
	for w in app.windows {if w.workspace == workspace {window_relayout(app, w)}}
	for w in focused {focus_enter(app, w)}
}

// How long a Neovim opened over a shell may take to draw before it takes the shell's pane anyway.
@(private)
NEOVIM_TAKE_WAIT :: time.Second

// Opens Neovim over the shell of the pane at `node`, whose session keeps running behind it. Neovim starts
// at once at the size the pane gives it but takes the pane only at its first screen (neovim_take_pane), so
// the shell stays in view until then rather than an empty grid. False when Neovim could not start.
@(private, require_results)
neovim_open_over :: proc(
	app: ^App,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
	shell: u32,
	file, directory: string,
) -> bool {
	pane := neovim_pane_create(app, file, directory)
	if pane == nil {return false}
	pane.shell = shell
	shell_content := layout.Content{.Terminal, shell}
	for w in app.windows {
		for shown in w.panes {
			if shown.content != shell_content {continue}
			box := pane_box(w.metrics, shown.rect, neovim_insets(app, w))
			neovim_pane_start(app, pane, int(box.columns), int(box.rows))
			if pane.exited {
				notify(app, .Error, pane.message)
				pane.shell = 0
				neovim_pane_remove(app, pane.id)
				return false
			}
			pane.pending, pane.opened = true, host.clock_now(&app.clock)
			return true
		}
	}
	// No window shows the shell, so nothing can flicker: Neovim starts once its pane is laid out.
	neovim_content_swap(app, workspace, tab_index, node, shell_content, {.Neovim, pane.id})
	return true
}

// The pending Neovim takes the pane its shell is in now. Without that pane the shell has closed with it,
// and the next sweep lets the Neovim go.
@(private)
neovim_take_pane :: proc(app: ^App, pane: ^Neovim_Pane) {
	pane.pending = false
	shell := layout.Content{.Terminal, pane.shell}
	for workspace in app.workspaces {
		for tab, index in workspace.tabs {
			node := layout.find_content(&tab.tree, shell)
			if node == layout.INVALID_NODE {continue}
			neovim_content_swap(app, workspace, index, node, shell, {.Neovim, pane.id})
			return
		}
	}
	pane.shell = 0
}

// A pending Neovim takes its pane once it shows a window; one that quits first leaves the shell where it
// was. Neovim's first flush comes before its config runs and holds only an empty base grid, without even
// its colours, and a config that waits on the event loop while it loads (as plugin managers do) leaves
// that empty screen up long enough to be seen.
@(private)
neovim_pending_poll :: proc(app: ^App, pane: ^Neovim_Pane, polled: neovim.Poll) {
	if polled.exited {
		pane.pending, pane.shell, pane.exited = false, 0, true
		notify(app, .Error, "Neovim quit before it showed anything.")
		return
	}
	if !polled.flushed {return}
	for grid in pane.client.screen.grids {
		if grid.kind == .Window {
			neovim_take_pane(app, pane)
			return
		}
	}
}

// Choosing the profile of the shell a Neovim pane opened over shows that shell: Neovim quits as `:qa`
// would, asking first about unsaved buffers, and the pane shows the shell as after any quit.
@(private, require_results)
neovim_shell_show :: proc(app: ^App, content: layout.Content, profile: string) -> bool {
	if content.kind != .Neovim {return false}
	pane := neovim_find(app, content.id)
	if pane == nil || pane.shell == 0 || !pane.started || pane.exited || pane.pending {return false}
	entry := session_find(app, pane.shell)
	if entry == nil || entry.status != .Running {return false}
	behind, _ := settings.profile_resolve(&app.settings, entry.profile_id)
	chosen, found := settings.profile_resolve(&app.settings, profile)
	if !found || behind != chosen {return false}
	return neovim.quit_confirm(&pane.client) == .None
}

// The content menu's Neovim on a shell pane of w opens over that shell, so nothing is lost and nothing is
// asked.
@(private)
neovim_open_over_menu :: proc(app: ^App, w: ^Window, shell: layout.Content, directory: string) {
	workspace := w.workspace
	tab_index := workspace.selected
	node := layout.find_content(window_tree(w), shell)
	if window_linked(w) {
		home, found := pane_link_home(app, shell)
		if !found {return}
		workspace, tab_index, node = home.workspace, tab_index_by_id(home.workspace, home.tab.id), home.node
	}
	if tab_index < 0 || node == layout.INVALID_NODE {return}
	if !neovim_open_over(app, workspace, tab_index, node, shell.id, "", directory) {
		notify(app, .Error, "Could not open Neovim.")
	}
}

// Neovim quit. A close it was asked about closes the pane. Otherwise the pane shows the shell it opened
// over, or, with neovim.exit_to_shell, a new shell of the default profile in Neovim's folder, as quitting
// Neovim in a terminal leaves its shell. Without one the pane closes, as a pane whose shell exits does;
// the last pane of a workspace then stays, saying so.
neovim_exited :: proc(app: ^App, pane: ^Neovim_Pane) {
	content := layout.Content{.Neovim, pane.id}
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		for tab, index in workspace.tabs {
			node := layout.find_content(&tab.tree, content)
			if node == layout.INVALID_NODE {continue}
			if !pane.closing {
				if shell := neovim_shell_take(app, pane); shell != 0 {
					neovim_content_swap(app, workspace, index, node, content, {.Terminal, shell})
					return
				}
				if len(workspace.tabs) == 1 && tab.tree.root == node {return}
			}
			pane_close_at(app, workspace, index, node)
			return
		}
	}
}

// The shell the pane shows once Neovim quits, which the pane no longer owns: the one it opened over while
// that still runs, else a new one when neovim.exit_to_shell is on; 0 for none.
@(private = "file")
neovim_shell_take :: proc(app: ^App, pane: ^Neovim_Pane) -> u32 {
	if pane.shell != 0 {
		shell := pane.shell
		pane.shell = 0
		if entry := session_find(app, shell); entry != nil && entry.status == .Running {return shell}
		session_close(app, shell)
	}
	if !app.settings.neovim.exit_to_shell {return 0}
	shell, opened := session_open(app, directory = neovim_directory(pane))
	if !opened {
		notify(app, .Error, "Could not start a shell after Neovim quit.")
		return 0
	}
	return shell
}

// --- Unsaved buffers ---

// A running Neovim with buffers it would ask about before quitting.
@(private, require_results)
neovim_unsaved :: proc(app: ^App, content: layout.Content) -> bool {
	if content.kind != .Neovim {return false}
	pane := neovim_find(app, content.id)
	return pane != nil && pane.started && !pane.exited && pane.client.unsaved > 0
}

// Whether a pane of `tree` shows a Neovim with unsaved buffers.
@(private, require_results)
neovim_unsaved_in :: proc(app: ^App, tree: ^layout.Layout) -> bool {
	for i in 0 ..< len(tree.nodes) {
		content, is_pane := layout.pane_content(tree, layout.Node_Id(i))
		if is_pane && neovim_unsaved(app, content) {return true}
	}
	return false
}

@(private, require_results)
workspace_has_unsaved :: proc(app: ^App, workspace: ^Workspace) -> bool {
	for tab in workspace.tabs {if neovim_unsaved_in(app, &tab.tree) {return true}}
	return false
}

// A Neovim pane with unsaved buffers does not close at once: Neovim asks about them, as `:confirm qa`
// does, in the pane, which takes the focus where its tab shows, and the pane closes once Neovim quits.
// True while the close waits on that question.
@(require_results)
neovim_close_deferred :: proc(
	app: ^App,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
) -> bool {
	if tab_index < 0 || tab_index >= len(workspace.tabs) {return false}
	content, is_pane := layout.pane_content(&workspace.tabs[tab_index].tree, node)
	if !is_pane || content.kind != .Neovim {return false}
	pane := neovim_find(app, content.id)
	if pane == nil || !pane.started || pane.exited {return false}
	if !pane.closing && pane.client.unsaved == 0 {return false}
	if !pane.closing {
		if neovim.quit_confirm(&pane.client) != .None {return false}
		pane.closing = true
	}
	for w in app.windows {
		if w.workspace == workspace && workspace.selected == tab_index {
			pane_focus(app, w, node)
			w.dirty = true
		}
	}
	return true
}

// Running Neovims with unsaved buffers, in every workspace.
@(private, require_results)
neovim_unsaved_count :: proc(app: ^App) -> int {
	count := 0
	for pane in app.neovim_panes {
		if pane.started && !pane.exited && pane.client.unsaved > 0 {count += 1}
	}
	return count
}

// Quitting or restarting AIODev ends every Neovim; with unsaved buffers in any, AIODev asks first.
Quit_Unsaved :: struct {
	restart: bool,
	panes:   int,
}

app_quit_request :: proc(app: ^App, restart: bool) {
	panes := neovim_unsaved_count(app)
	w := window_focused_or_recent(app)
	if panes > 0 && w == nil {
		show_window(app)
		w = window_focused_or_recent(app)
	}
	if panes == 0 || w == nil || !gesture_cancel(app, w) {
		quit_unsaved_finish(app, {restart, panes}, true)
		return
	}
	if !w.focused && !window_activate(app, w) {log.error("bringing the window forward to ask failed")}
	confirmation_ask(app, w, Quit_Unsaved{restart, panes})
}

quit_unsaved_text :: proc(subject: Quit_Unsaved) -> Confirmation_Text {
	verb := subject.restart ? "Restart" : "Quit"
	panes := "A Neovim pane has"
	if subject.panes > 1 {panes = fmt.tprintf("%d Neovim panes have", subject.panes)}
	return {
		title = fmt.tprintf("%s with unsaved changes?", verb),
		body = fmt.tprintf("%s unsaved changes, which are lost when Neovim ends.", panes),
		label = verb,
	}
}

@(private)
quit_unsaved_finish :: proc(app: ^App, subject: Quit_Unsaved, accepted: bool) {
	if !accepted {return}
	if subject.restart {host.restart(&app.run)} else {host.quit(&app.run)}
}

// --- Pointer ---

// Typing into Neovim hides the pointer, as Neovim's 'mousehide' asks, until the mouse next moves.
@(private)
neovim_pointer_hide :: proc(app: ^App, w: ^Window, pane: ^Neovim_Pane) {
	if pane.client.pointer_kept || app.neovim_drag.active {return}
	pointer_set(app, w, platform.Cursor_Shape.Hidden)
}

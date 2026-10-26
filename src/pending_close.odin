package main

import "aio:ui"
import "core:fmt"
import "core:strings"

Pending_Close_Kind :: enum {
	None,
	Tab,
	Workspace,
}

// The destructive close being asked about, the subject that must still be live when it is
// accepted, and the counts and names the prompt shows. The plan is the workspace subject's
// identity and policy; a tab close leaves it empty.
Pending_Close :: struct {
	confirm:          ui.Confirm,
	kind:             Pending_Close_Kind,
	tab:              u32,
	using plan:       Workspace_Delete_Plan,
	workspace_name:   string,
	destination_name: string,
	tabs, panes, sessions: int,
}

Pending_Close_Text :: struct {
	title, body, label, note: string,
}

// Releases the cached subject names and returns the question to no subject.
pending_close_clear :: proc(pc: ^Pending_Close) {
	delete(pc.workspace_name)
	delete(pc.destination_name)
	pc^ = {}
}

// Opens the tab question, cancelling the gesture and palette that requested it.
pending_close_open_tab :: proc(app: ^App, w: ^Window, index: int) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if !gesture_cancel(app, w) {return}
	palette_close(app, w)
	pc := &w.pending_close
	delete(pc.workspace_name)
	delete(pc.destination_name)
	pc.workspace_name, pc.destination_name = "", ""
	pc.kind = .Tab
	pc.tab = w.workspace.tabs[index].id
	pc.plan = {}
	pc.tabs, pc.panes, _ = tab_close_scope(w.workspace, index)
	pc.sessions = 0
	pc.confirm.extended = false
	ui.confirm_open(&pc.confirm)
	w.dirty = true
}

// Opens the workspace question. Names are cloned before the gesture and overlay cancellation
// so an allocation failure leaves the window exactly as it was.
pending_close_open_workspace :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	plan: Workspace_Delete_Plan,
) {
	name, err := strings.clone(workspace.name)
	if err != nil {
		notify(app, .Error, "Could not prepare workspace deletion.")
		return
	}
	destination := plan.destination != 0 ? workspace_find(app, plan.destination) : nil
	destination_name: string
	if destination != nil {
		destination_name, err = strings.clone(destination.name)
		if err != nil {
			delete(name)
			notify(app, .Error, "Could not prepare workspace deletion.")
			return
		}
	}
	if !gesture_cancel(app, w) {
		delete(name)
		delete(destination_name)
		return
	}
	window_overlays_cancel(app, w)
	pc := &w.pending_close
	delete(pc.workspace_name)
	delete(pc.destination_name)
	pc.workspace_name, pc.destination_name = name, destination_name
	pc.kind = .Workspace
	pc.plan = plan
	pc.tab = 0
	counts := workspace_pane_counts(workspace)
	pc.tabs, pc.panes, pc.sessions = counts.tabs, counts.panes, counts.sessions
	ui.confirm_open(&pc.confirm)
	pc.confirm.extended = true
	w.dirty = true
}

// Counts follow panes that exit while the question is open, then stay fixed while it fades out.
pending_close_text :: proc(
	app: ^App,
	pc: ^Pending_Close,
	workspace: ^Workspace,
) -> Pending_Close_Text {
	text: Pending_Close_Text
	switch pc.kind {
	case .None:
	case .Tab:
		if index := tab_index_by_id(workspace, pc.tab); pc.confirm.open && index >= 0 {
			pc.tabs, pc.panes, _ = tab_close_scope(workspace, index)
		}
		if pc.tabs > 1 {
			text.title = fmt.tprintf("Close %d tabs with %d panes?", pc.tabs, pc.panes)
			text.body = "The shells running in them will exit."
		} else {
			text.title = fmt.tprintf("Close this tab and its %d panes?", pc.panes)
			text.body = "The shells running in it will exit."
		}
		text.label = "Close"
		text.note = "Turn this off with Confirm Closing Split Tabs in Settings."
	case .Workspace:
		name := pc.workspace_name
		if found := workspace_find(app, pc.plan.workspace); pc.confirm.open && found != nil {
			name = found.name
			counts := workspace_pane_counts(found)
			pc.tabs, pc.panes, pc.sessions = counts.tabs, counts.panes, counts.sessions
		}
		text.title = fmt.tprintf("Delete “%s”?", name)
		text.body = fmt.tprintf(
			"Close %d tabs (%d panes); stop %d sessions.",
			pc.tabs,
			pc.panes,
			pc.sessions,
		)
		text.label = "Delete"
		switch {
		case pc.plan.owner == 0:
			text.note = "Other workspaces and their sessions stay open."
		case pc.plan.destination != 0:
			text.note = fmt.tprintf(
				"Switch its window to #%d “%s”.",
				pc.plan.destination,
				pc.destination_name,
			)
		case:
			text.note = "Replace it with a fresh default workspace and shell."
		}
	}
	return text
}

// Closes the question. Acceptance dispatches to the subject's owner; cancellation restores the
// tab selection that a subset close replaced.
pending_close_finish :: proc(app: ^App, w: ^Window, accept: bool) {
	pc := &w.pending_close
	kind := pc.kind
	ui.confirm_close(&pc.confirm)
	w.dirty = true
	switch kind {
	case .None:
	case .Tab:
		if accept {
			if index := tab_index_by_id(w.workspace, pc.tab); index >= 0 {
				id := w.id
				tab_close(app, w, index)
				// Closing the last tab frees this window through hide_to_tray.
				if current := window_find(app, id); current != nil {tab_close_restore(current)}
				return
			}
		}
		tab_close_restore(w)
	case .Workspace:
		if accept {workspace_delete_accept(app, w)}
	}
}

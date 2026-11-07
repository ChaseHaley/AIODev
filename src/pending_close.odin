package main

import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:strings"

// The destructive close a confirmation asks about, and the counts its text shows. The counts follow
// panes that exit while the question asks, then stay fixed while it closes.
Pending_Close :: struct {
	target:                Close_Target,
	tabs, panes, sessions: int,
}

Close_Target :: union {
	Close_Tab,
	Close_Workspace,
}

// The tab to close: the recorded one, or with its marked group.
Close_Tab :: struct {
	tab:     u32,
	// The marks a close subset replaced with the tabs it closes, which tab.marked means while the
	// question asks. The answer takes them and puts them back through tab_close_restore; empty when the
	// close named its tab directly.
	restore: [dynamic]u32,
}

// The plan is the workspace subject's identity and policy; the names keep the text while it closes.
Close_Workspace :: struct {
	using plan:                       Workspace_Delete_Plan,
	workspace_name, destination_name: string,
}

pending_close_destroy :: proc(pc: ^Pending_Close) {
	switch &target in pc.target {
	case Close_Tab:
		delete(target.restore)
	case Close_Workspace:
		delete(target.workspace_name)
		delete(target.destination_name)
	}
	pc^ = {}
}

// Opens the tab question, cancelling the gesture and palette that requested it, and takes `restore`,
// the marks a close subset replaced. An asking close question is rewritten in place: the tabs its
// caller just marked stay, and marks it already holds remain the ones to put back.
pending_close_open_tab :: proc(app: ^App, w: ^Window, index: int, restore: ^[dynamic]u32 = nil) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if !gesture_cancel(app, w) {return}
	close := Close_Tab{tab = w.workspace.tabs[index].id}
	if restore != nil {close.restore, restore^ = restore^, {}}
	reopening: ^ui.Confirm
	if asking := confirmation_asking(w, Pending_Close); asking != nil {
		reopening = confirmation_current(w)
		if held, ok := &asking.target.(Close_Tab); ok && len(held.restore) > 0 {
			delete(close.restore)
			close.restore, held.restore = held.restore, {}
		}
	}
	overlay_close_all(app, w, reopening)
	pc := Pending_Close{target = close}
	pc.tabs, pc.panes, _ = tab_close_scope(w.workspace, index)
	confirmation_open(w, pc)
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
	pc := Pending_Close {
		target = Close_Workspace{plan = plan, workspace_name = name, destination_name = destination_name},
	}
	counts := workspace_pane_counts(workspace)
	pc.tabs, pc.panes, pc.sessions = counts.tabs, counts.panes, counts.sessions
	confirmation_open(w, pc, extended = true)
}

// Counts follow panes that exit while the question is `open`, then stay fixed while it closes.
pending_close_text :: proc(
	app: ^App,
	pc: ^Pending_Close,
	open: bool,
	workspace: ^Workspace,
) -> Confirmation_Text {
	text: Confirmation_Text
	switch target in pc.target {
	case Close_Tab:
		if index := tab_index_by_id(workspace, target.tab); open && index >= 0 {
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
		if index := tab_index_by_id(workspace, target.tab); tab_close_has_work(app, workspace, index) {
			text.title = pc.tabs > 1 ? "Close tabs with ongoing work?" : "Close tab with ongoing work?"
			text.body = "Closing will interrupt this work."
		} else {
			setting := settings.schema_find("tab.confirm_close")
			text.note = fmt.tprintf("Turn this off with %s in Settings.", setting.title)
		}
	case Close_Workspace:
		name := target.workspace_name
		found := workspace_find(app, target.workspace)
		if open && found != nil {
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
		case target.owner == 0:
			text.note = "Other workspaces and their sessions stay open."
		case target.destination != 0:
			text.note = fmt.tprintf(
				"Switch its window to #%d “%s”.",
				target.destination,
				target.destination_name,
			)
		case:
			text.note = "Replace it with a fresh default workspace and shell."
		}
	}
	return text
}

// Acts on the answer. Acceptance dispatches to the subject's owner; either answer puts back the tab
// marks a subset close replaced. The subject is not read once acceptance has run, since that may
// retire the window or ask again.
@(private)
pending_close_finish :: proc(app: ^App, w: ^Window, pc: ^Pending_Close, accept: bool) {
	switch &target in pc.target {
	case Close_Tab:
		restore := target.restore
		target.restore = {}
		if index := tab_index_by_id(w.workspace, target.tab); accept && index >= 0 {
			id := w.id
			tab_close(app, w, index)
			// Closing the last tab may retire this window.
			if current := window_find(app, id); current != nil {tab_close_restore(current, &restore)}
			else {delete(restore)}
			return
		}
		tab_close_restore(w, &restore)
	case Close_Workspace:
		if accept {workspace_delete_accept(app, w, target.plan)}
	}
}

package main

import "aio:layout"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

Pane_Swap :: struct {
	confirm:                 ui.Confirm,
	pane:                    layout.Node_Id,
	profile_id, profile_name: string,
	current_name:            string,
}

pane_swap_clear :: proc(swap: ^Pane_Swap) {
	delete(swap.profile_id)
	delete(swap.profile_name)
	delete(swap.current_name)
	swap^ = {}
}

@(private)
shell_is_windows :: proc(command: string) -> bool {
	executable := settings.shell_executable(command)
	for unix in ([?]string{"wsl", "bash", "zsh", "fish", "sh"}) {
		if strings.equal_fold(executable, unix) {return false}
	}
	return true
}

// Opens the confirmation for replacing a running pane's shell, or swaps immediately when the
// pane has exited or the warning is off.
pane_shell_swap_request :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	profile_id: string,
) {
	pane, is_pane := w.tree.nodes[node].(layout.Pane)
	if !is_pane || pane.content.kind != .Terminal {return}
	entry := session_find(app, pane.content.id)
	if entry == nil {return}
	if entry.profile_id == profile_id {return}
	profile, requested := settings.profile_resolve(&app.settings, profile_id)
	if !requested {
		notify(app, .Error, "That shell profile is not available.")
		return
	}
	if entry.status != .Running || !app.settings.pane.confirm_shell_switch {
		pane_shell_swap(app, w, node, profile_id)
		return
	}
	current := entry.profile_id
	if found := settings.profile_find(&app.settings.profiles, entry.profile_id); found != nil {
		current = found.name
	}
	if !gesture_cancel(app, w) {return}
	swap := &w.pending_swap
	pane_swap_clear(swap)
	owned_id, id_error := strings.clone(profile.id)
	if id_error != nil {notify(app, .Error, "Could not prepare the shell switch."); return}
	owned_name, name_error := strings.clone(profile.name)
	if name_error != nil {
		delete(owned_id)
		notify(app, .Error, "Could not prepare the shell switch.")
		return
	}
	owned_current, current_error := strings.clone(current)
	if current_error != nil {
		delete(owned_id)
		delete(owned_name)
		notify(app, .Error, "Could not prepare the shell switch.")
		return
	}
	swap.pane = node
	swap.profile_id, swap.profile_name, swap.current_name = owned_id, owned_name, owned_current
	swap.confirm.show_option = true
	swap.confirm.option = false
	ui.confirm_open(&swap.confirm)
	w.dirty = true
}

pane_swap_text :: proc(swap: ^Pane_Swap) -> (title, body, note, label: string) {
	title = fmt.tprintf("Switch to %s?", swap.profile_name)
	body = fmt.tprintf("The current %s session in this pane will be lost.", swap.current_name)
	label = "Switch"
	return
}

pane_swap_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Confirm_Outcome) {
	switch outcome {
	case .None:
	case .Changed:
		w.dirty = true
	case .Cancel:
		pane_swap_finish(app, w, false)
	case .Accept:
		pane_swap_finish(app, w, true)
	}
}

pane_swap_finish :: proc(app: ^App, w: ^Window, accept: bool) {
	swap := &w.pending_swap
	if !swap.confirm.open {return}
	option := swap.confirm.option
	node, profile_id := swap.pane, swap.profile_id
	ui.confirm_close(&swap.confirm)
	if accept {
		if option {pane_swap_opt_out(app)}
		pane_shell_swap(app, w, node, profile_id)
	}
	w.dirty = true
}

@(private)
pane_swap_opt_out :: proc(app: ^App) {
	data, read_error := os.read_entire_file(app.settings_path, context.temp_allocator)
	if read_error != nil {
		notify(app, .Error, "Could not save the shell-switch warning preference.")
		return
	}
	updated, message, edit_error := settings.edit_text(
		string(data),
		"pane.confirm_shell_switch",
		"false",
	)
	defer delete(updated)
	defer delete(message)
	if edit_error != nil || message != "" {
		notify(app, .Error, "Could not save the shell-switch warning preference.")
		return
	}
	if settings_commit(app, string(data), updated) != .None {
		notify(app, .Error, "Could not save the shell-switch warning preference.")
		return
	}
	notify(app, .Info, "Won't ask again. Turn it back on in Settings.")
}

// Replaces the session's process in place. The session ID, pane, focus and name are unchanged;
// scrollback is cleared by the restart.
pane_shell_swap :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	profile_id: string,
) {
	pane, is_pane := w.tree.nodes[node].(layout.Pane)
	if !is_pane || pane.content.kind != .Terminal {return}
	entry := session_find(app, pane.content.id)
	if entry == nil {return}
	profile, requested := settings.profile_resolve(&app.settings, profile_id)
	if !requested {
		notify(app, .Error, "That shell profile is not available.")
		return
	}
	owned_id, id_error := strings.clone(profile.id)
	if id_error != nil {
		notify(app, .Error, "Could not switch the pane's shell.")
		return
	}
	geometry := term.geometry(entry.session)
	config := session_config(app, geometry, profile)
	raw_directory := term.working_directory(entry.session, context.temp_allocator)
	carry :=
		raw_directory != "" &&
		shell_is_windows(profile.command) &&
		shell_is_windows(entry.header.command)
	if carry {
		label, label_error := settings.directory_label(
			raw_directory,
			context.temp_allocator,
		)
		if label_error != nil {
			log.errorf("resolving the pane directory failed: %v", label_error)
		} else if label != "" {
			config.working_directory = label
		}
	}
	term.restart(entry.session, config)
	delete(entry.profile_id)
	entry.profile_id = owned_id
	pane_header_launch(&entry.header, config)
	pane_header_refresh(entry)
	entry.status = term.status(entry.session).kind
	mark_all_dirty(app)
}

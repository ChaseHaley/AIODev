package main

import "aio:layout"
import "aio:localpath"
import "aio:settings"
import "aio:term"
import "core:fmt"
import "core:log"
import "core:strings"

// The shell switch a confirmation asks about: the pane, the profile it switches to, and the names its
// text shows.
Pane_Swap :: struct {
	pane:                     layout.Node_Id,
	profile_id, profile_name: string,
	current_name:             string,
}

pane_swap_destroy :: proc(swap: ^Pane_Swap) {
	delete(swap.profile_id)
	delete(swap.profile_name)
	delete(swap.current_name)
	swap^ = {}
}

// Opens the confirmation for replacing a running pane's shell, or swaps immediately when the
// pane has exited or the warning is off.
pane_shell_swap_request :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	profile_id: string,
) {
	content, is_pane := layout.pane_content(window_tree(w), node)
	if !is_pane || !pane_owns_session(content.kind) {return}
	entry := session_find(app, content.id)
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
	overlay_open(app, w, nil)
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
	swap := Pane_Swap {
		pane         = node,
		profile_id   = owned_id,
		profile_name = owned_name,
		current_name = owned_current,
	}
	confirmation_open(w, swap, show_option = true)
}

pane_swap_text :: proc(swap: Pane_Swap) -> Confirmation_Text {
	return {
		title = fmt.tprintf("Switch to %s?", swap.profile_name),
		body = fmt.tprintf("The current %s session in this pane will be lost.", swap.current_name),
		label = "Switch",
		option = "Don't ask again",
	}
}

// `opt_out` is the question's "Don't ask again" option.
@(private)
pane_swap_finish :: proc(app: ^App, w: ^Window, swap: Pane_Swap, opt_out, accept: bool) {
	if !accept {return}
	if opt_out {pane_swap_opt_out(app)}
	pane_shell_swap(app, w, swap.pane, swap.profile_id)
}

@(private)
pane_swap_opt_out :: proc(app: ^App) {
	failure :: "Could not save the shell-switch warning preference."
	if settings_save_value(app, "pane.confirm_shell_switch", "false", failure) {
		notify(app, .Info, "Won't ask again. Turn it back on in Settings.")
	}
}

// Replaces the session's process in place. The session ID, pane, focus and name are unchanged;
// scrollback is cleared by the restart.
pane_shell_swap :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	profile_id: string,
) {
	content, is_pane := layout.pane_content(window_tree(w), node)
	if !is_pane || !pane_owns_session(content.kind) {return}
	entry := session_find(app, content.id)
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
	config := session_config(app, entry.id, geometry, profile)
	raw_directory := term.working_directory(entry.session, context.temp_allocator)
	carry :=
		raw_directory != "" &&
		!settings.shell_definitions[settings.shell_kind(profile.command)].unix &&
		!settings.shell_definitions[settings.shell_kind(entry.header.command)].unix
	if carry {
		label, label_error := localpath.directory_label(
			raw_directory,
			context.temp_allocator,
		)
		if label_error != nil {
			log.errorf("resolving the pane directory failed: %v", label_error)
		} else if label != "" {
			directory, refused := local_launch_directory(label, "")
			if refused {
				notify(
					app,
					.Warning,
					"The pane's directory is remote or unavailable; using the profile's default.",
				)
			} else {
				config.working_directory = directory
			}
		}
	}
	term.restart(entry.session, config)
	delete(entry.profile_id)
	entry.profile_id = owned_id
	pane_header_launch(&entry.header, config)
	pane_header_refresh(entry)
	session_status_sync(entry)
	mark_all_dirty(app)
}

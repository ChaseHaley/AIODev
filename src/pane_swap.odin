package main

import "aio:layout"
import "aio:localpath"
import "aio:settings"
import "aio:term"
import "core:fmt"
import "core:log"
import "core:strings"

// A pending switch keeps the content it was asked about, not a node another pane could reuse.
Pane_Swap :: struct {
	pane:                     layout.Content,
	kind:                     layout.Content_Kind,
	path:                     string,
	profile_id, profile_name: string,
	current_name:             string,
}

pane_swap_destroy :: proc(swap: ^Pane_Swap) {
	delete(swap.profile_id)
	delete(swap.profile_name)
	delete(swap.current_name)
	delete(swap.path)
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
	if entry.status != .Running || .Shell_Switch not_in app.settings.interface.confirm {
		pane_shell_swap(app, w, node, profile_id)
		return
	}
	pane_swap_ask(app, w, content, entry, .Terminal, profile.id, profile.name, "")
}

@(private)
pane_swap_ask :: proc(
	app: ^App, w: ^Window, content: layout.Content, entry: ^Session_Entry,
	kind: layout.Content_Kind, profile_id, name, path: string,
) {
	current := entry.profile_id
	if found := settings.profile_find(&app.settings.profiles, entry.profile_id); found != nil {
		current = found.name
	}
	if !gesture_cancel(app, w) {return}
	owned_id, id_error := strings.clone(profile_id)
	if id_error != nil {notify(app, .Error, "Could not prepare the shell switch."); return}
	owned_name, name_error := strings.clone(name)
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
	owned_path, path_error := strings.clone(path)
	if path_error != nil {
		delete(owned_id)
		delete(owned_name)
		delete(owned_current)
		notify(app, .Error, "Could not prepare the pane switch.")
		return
	}
	confirmation_ask(app, w, Pane_Swap{content, kind, owned_path, owned_id, owned_name, owned_current},
		show_option = true)
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
	if swap.kind == .Terminal {
		node := pane_content_menu_node(w, swap.pane)
		if node == layout.INVALID_NODE {return}
		pane_shell_swap(app, w, node, swap.profile_id)
	} else {
		pane_content_replace(app, w, swap.pane, swap.kind, swap.path)
	}
}

@(private)
pane_swap_opt_out :: proc(app: ^App) {
	failure :: "Could not save the shell-switch warning preference."
	prompts := app.settings.interface.confirm - {.Shell_Switch}
	value := settings.set_text(settings.CONFIRM_PROMPT_NAMES, transmute(u32)prompts)
	if settings_save_value(app, "interface.confirm", value, failure) {
		title := settings.schema_find("interface.confirm").title
		notify(app, .Info, fmt.tprintf("Won't ask again. Turn it back on with \"%s\" in Settings.", title))
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
	config := session_config(app, entry.id, entry.key, geometry, profile)
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
			directory, refused := local_launch_directory(label)
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
	delete(entry.profile_id)
	entry.profile_id = owned_id
	session_relaunch(app, entry, config)
}

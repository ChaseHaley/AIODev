package main

import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:slice"
import "core:strings"

Tab :: struct {
	id: u32,
	marked: bool,
	tree: layout.Layout,
	title: string,
	name: string,
	documents: Document_List,
}

Workspace :: struct {
	provisional: bool, // A tear-off preview borrows a runtime until the drop commits.
	id: u32,
	name: string,
	icon: Workspace_Icon,
	tabs: [dynamic]^Tab,
	selected: int,
	next_tab_id: u32,
	selection_anchor: u32,
	settings_scroll: int,
	documents: Document_List,
}

@(require_results)
workspace_default_name :: proc(app: ^App) -> string {
	adjectives := [?]string{
		"Quiet", "Bright", "Gentle", "Brave", "Curious", "Happy", "Misty", "Sunny",
		"Calm", "Clever", "Cozy", "Daring", "Distant", "Dreamy", "Eager", "Fair",
		"Friendly", "Hidden", "Jolly", "Kind", "Lively", "Lucky", "Merry", "Nimble",
		"Peaceful", "Playful", "Quick", "Soft", "Still", "Swift", "Warm", "Wild",
	}
	colors := [?]string{
		"Amber", "Azure", "Blue", "Bronze", "Coral", "Crimson", "Emerald", "Golden",
		"Green", "Indigo", "Ivory", "Jade", "Lavender", "Lilac", "Lime", "Maroon",
		"Mint", "Olive", "Orange", "Peach", "Pearl", "Pink", "Plum", "Purple",
		"Rose", "Ruby", "Saffron", "Scarlet", "Silver", "Teal", "Violet", "White",
	}
	nouns := [?]string{
		"Badger", "Brook", "Canyon", "Cedar", "Cloud", "Comet", "Cove", "Dawn",
		"Dune", "Falcon", "Fern", "Finch", "Forest", "Fox", "Glen", "Grove",
		"Harbor", "Heron", "Hill", "Island", "Lake", "Lark", "Maple", "Meadow",
		"Moon", "Otter", "Panda", "Pine", "River", "Sparrow", "Star", "Willow",
	}
	// Probe from a random phrase: even repeated collisions terminate without numbered suffixes.
	count := len(adjectives) * len(colors) * len(nouns)
	start := rand.int_max(count)
	for offset in 0 ..< count {
		index := (start + offset) % count
		noun := index % len(nouns)
		index /= len(nouns)
		candidate := fmt.tprintf("%s %s %s", adjectives[index / len(colors)],
			colors[index % len(colors)], nouns[noun])
		if workspace_name_taken(app, candidate, 0) {continue}
		owned, err := strings.clone(candidate)
		if err != nil {return ""}
		return owned
	}
	return ""
}

// Provisional previews never reserve names; an editor may exclude its own workspace.
workspace_name_taken :: proc(app: ^App, name: string, except: u32) -> bool {
	for workspace in app.workspaces {
		if !workspace.provisional && workspace.id != except && strings.equal_fold(workspace.name, name) {
			return true
		}
	}
	return false
}

selected_tab :: proc(workspace: ^Workspace) -> ^Tab {
	if workspace == nil || len(workspace.tabs) == 0 {return nil}
	return workspace.tabs[workspace.selected]
}

// Opens a tab holding one new terminal session and returns that session's id.
@(require_results)
tab_create :: proc(
	app: ^App,
	workspace: ^Workspace,
	command: string = "",
	directory: string = "",
	profile_id: string = "",
) -> (
	session: u32,
	ok: bool,
) {
	tab, reserved := tab_record_reserve(workspace)
	if !reserved {return 0, false}
	id, opened := session_open(app, command, directory, profile_id)
	if !opened {
		tab_record_free(tab)
		return 0, false
	}
	if layout.init(&tab.tree, {.Terminal, id}) != nil {
		session_close(app, id)
		tab_record_free(tab)
		return 0, false
	}
	tab_record_commit(app, workspace, tab)
	return id, true
}

workspace_destroy :: proc(workspace: ^Workspace) {
	for tab in workspace.tabs {tab_record_free(tab)}
	documents_destroy(&workspace.documents)
	delete(workspace.tabs)
	delete(workspace.name)
	delete(workspace.icon.emoji)
	free(workspace)
}

// What showing a tab does to the marked tabs: a plain choice marks only it, while multiselection and moves
// that already set the marks keep them.
Tab_Selection_Mode :: enum {
	Replace_Marks,
	Preserve_Marks,
}

tab_select :: proc(app: ^App, w: ^Window, index: int, mode := Tab_Selection_Mode.Replace_Marks) {
	if index < 0 || index >= len(w.workspace.tabs) {return}
	if mode == .Replace_Marks {tab_select_one(w.workspace, index); mark_all_dirty(app)}
	focus_leave(app, w)
	w.workspace.selected = index
	window_relayout(app, w)
	rail_reveal_active(w)
	focus_enter(app, w)
}

// Shows a tab a person chose, as tab_select, and puts away the rail overlay that may have shown it.
tab_show :: proc(app: ^App, w: ^Window, index: int) {
	tab_select(app, w, index)
	rail_overlay_dismiss(app, w)
}

tab_select_one :: proc(workspace: ^Workspace, index: int) {
	for tab, i in workspace.tabs {tab.marked = i == index}
	workspace.selection_anchor = workspace.tabs[index].id
}

// Chooses a tab without a window's focus transition, keeping selection and its marks together.
workspace_tab_choose :: proc(workspace: ^Workspace, index: int) {
	workspace.selected = index
	tab_select_one(workspace, index)
}

tab_pointer_select :: proc(app: ^App, w: ^Window, index: int, toggle, range: bool) {
	tabs := w.workspace.tabs
	if index < 0 || index >= len(tabs) {return}
	if toggle || range || !tabs[index].marked {
		marked, err := make([]bool, len(tabs), context.temp_allocator)
		if err != nil {notify(app, .Error, "Could not select tabs."); return}
		anchor := w.workspace.selected
		for tab, i in tabs {
			marked[i] = tab.marked
			if tab.id == w.workspace.selection_anchor {anchor = i}
		}
		ui.tab_selection_update(marked, index, anchor, toggle = toggle, range = range)
		for tab, i in tabs {tab.marked = marked[i]}
	}
	if !range {w.workspace.selection_anchor = tabs[index].id}
	tab_select(app, w, index, .Preserve_Marks)
	mark_all_dirty(app)
}

tab_new :: proc(app: ^App, w: ^Window) {
	if !pane_minimum_single(app, w) {return}
	if _, created := tab_create(app, w.workspace); !created {
		notify(app, .Error, "Could not create a tab.")
		return
	}
	tab_show(app, w, len(w.workspace.tabs) - 1)
}

// Opens the Nth visible profile from profile.order, matching the profile.open_N shortcuts.
tab_new_profile :: proc(app: ^App, w: ^Window, index: int) {
	if !pane_minimum_single(app, w) {return}
	indices: [settings.PROFILE_LIMIT]int
	count := settings.profiles_in_order(&app.settings.profiles, indices[:], visible_only = true)
	if index < 0 || index >= count {
		notify(app, .Error, "That shell profile is not available.")
		return
	}
	tab_new_profile_id(app, w, app.settings.profiles.items[indices[index]].id)
}

// Opens a tab running the profile `profile_id` names, which must still have a shell to launch.
tab_new_profile_id :: proc(app: ^App, w: ^Window, profile_id: string) {
	if !pane_minimum_single(app, w) {return}
	if _, requested := settings.profile_resolve(&app.settings, profile_id); !requested {
		notify(app, .Error, "That shell profile is not available.")
		return
	}
	if _, created := tab_create(app, w.workspace, profile_id = profile_id); !created {
		notify(app, .Error, "Could not create a tab.")
		return
	}
	tab_show(app, w, len(w.workspace.tabs) - 1)
}

tab_close :: proc(app: ^App, w: ^Window, index: int) {
	workspace := w.workspace
	if index < 0 || index >= len(workspace.tabs) {return}
	group := workspace.tabs[index].marked
	if group {
		// Closing one tab can clear the marks on the rest, so the group is named by id before any close.
		ids := make([dynamic]u32, 0, len(workspace.tabs), context.temp_allocator)
		for tab in workspace.tabs {if tab.marked {_ = append(&ids, tab.id)}}
		for id in ids {
			if current := tab_index_by_id(workspace, id); current >= 0 {
				closed_record_tab(app, workspace, current)
				workspace_close_tab(app, workspace, current)
			}
		}
	} else {
		closed_record_tab(app, workspace, index)
		workspace_close_tab(app, workspace, index)
	}
	if group && len(workspace.tabs) > 0 {tab_select_one(workspace, workspace.selected)}
	workspace_close_empty(app, workspace)
}

// The tabs a close of `index` affects, its whole selected group when marked, and their panes.
@(private)
tab_close_scope :: proc(workspace: ^Workspace, index: int) -> (tabs, panes: int, split: bool) {
	if index < 0 || index >= len(workspace.tabs) {return}
	group := workspace.tabs[index].marked
	for tab, i in workspace.tabs {
		if group ? !tab.marked : i != index {continue}
		count := tab_pane_count(tab)
		tabs, panes = tabs + 1, panes + count
		split ||= count > 1
	}
	return
}

// Reported running or blocked work always needs confirmation, including in selected groups.
tab_close_has_work :: proc(app: ^App, workspace: ^Workspace, index: int) -> bool {
	if index < 0 || index >= len(workspace.tabs) {return false}
	group := workspace.tabs[index].marked
	for tab, i in workspace.tabs {
		if group ? !tab.marked : i != index {continue}
		walk := tab_session_panes(app, &tab.tree, i)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			if pane.session == nil {continue}
			for record in pane.session.statuses {
				if record.state == .Working || record.state == .Blocked {return true}
			}
		}
	}
	return false
}

// The split-tab preference does not disable protection for explicitly reported ongoing work. `restore`
// is a close subset's replaced marks, which a question takes when it asks.
tab_close_request :: proc(app: ^App, w: ^Window, index: int, restore: ^[dynamic]u32 = nil) {
	_, _, split := tab_close_scope(w.workspace, index)
	if !tab_close_has_work(app, w.workspace, index) && (!split || !app.settings.tab.confirm_close) {
		tab_close(app, w, index)
		return
	}
	pending_close_open_tab(app, w, index, restore)
}

tab_duplicate :: proc(app: ^App, w: ^Window, index: int) {
	pane, _ := workspace_focused_session_pane(app, w.workspace, index)
	entry := pane.session
	if entry == nil || !pane_minimum_single(app, w) {return}
	directory, refused := pane_directory(app, entry)
	if refused {notify_directory_refused(app)}
	// Opening a session can move app.sessions, and `entry` with it.
	pinned := entry.documents[:]
	session, created := tab_create(app, w.workspace, entry.header.command, directory, entry.profile_id)
	if !created {
		notify(app, .Error, "Could not duplicate the tab.")
		return
	}
	copy_tab := w.workspace.tabs[len(w.workspace.tabs) - 1]
	documents_copy(&copy_tab.documents, w.workspace.tabs[index].documents[:])
	documents_copy(&session_find(app, session).documents, pinned)
	tab_show(app, w, len(w.workspace.tabs) - 1)
}

tab_move_group :: proc(app: ^App, w: ^Window, end: bool) {
	order := slice.clone(w.workspace.tabs[:], context.temp_allocator)
	marked := make([]bool, len(order), context.temp_allocator)
	indices := make([]int, len(order), context.temp_allocator)
	slot := 0
	for tab, i in order {marked[i] = tab.marked; if end && !tab.marked {slot += 1}}
	if !ui.tab_group_order(marked, slot, indices) {return}
	for original, to in indices {
		for current, from in w.workspace.tabs {
			if current == order[original] {tab_move(app, w, from, to); break}
		}
	}
}

// Puts back the marks a subset close replaced and releases the list, falling back to the active tab
// when all of them closed. The one exit of a close subset, whether its question was answered,
// dismissed or never asked.
tab_close_restore :: proc(w: ^Window, restore: ^[dynamic]u32) {
	defer {
		delete(restore^)
		restore^ = {}
	}
	if len(restore^) == 0 {return}
	kept := false
	for tab in w.workspace.tabs {
		tab.marked = false
		for id in restore^ {tab.marked ||= tab.id == id}
		kept ||= tab.marked
	}
	if !kept && len(w.workspace.tabs) > 0 {tab_select_one(w.workspace, w.workspace.selected)}
	w.dirty = true
}

// Closes the tabs right of `anchor`, or every tab outside it: its marked group when it is marked,
// otherwise every other tab. The marks show the tabs closing until the question, if one asks, is
// answered; the question then holds the marks to put back.
tab_close_subset :: proc(app: ^App, w: ^Window, right: bool, anchor: int) {
	if anchor < 0 || anchor >= len(w.workspace.tabs) {return}
	group := w.workspace.tabs[anchor].marked
	restore, err := make([dynamic]u32, 0, len(w.workspace.tabs))
	if err != nil {
		notify(app, .Error, "Could not select tabs to close.")
		return
	}
	for tab in w.workspace.tabs {if tab.marked {append(&restore, tab.id)}}
	first := -1
	for tab, i in w.workspace.tabs {
		tab.marked = right ? i > anchor : (group ? !tab.marked : i != anchor)
		if tab.marked && first < 0 {first = i}
	}
	if first >= 0 {tab_close_request(app, w, first, &restore)}
	tab_close_restore(w, &restore)
}

tab_index_by_id :: proc(workspace: ^Workspace, id: u32) -> int {
	for tab, i in workspace.tabs {if tab.id == id {return i}}
	return -1
}

@(private)
workspace_close_tab :: proc(app: ^App, workspace: ^Workspace, original_index: int) {
	index := original_index
	if index < 0 || index >= len(workspace.tabs) {return}
	tab := workspace.tabs[index]
	for w in app.windows {if w.workspace == workspace {_ = gesture_cancel(app, w)}}
	for current, i in workspace.tabs {if current == tab {index = i; break}}
	was_selected := index == workspace.selected
	if was_selected {
		for w in app.windows {if w.workspace == workspace {focus_leave(app, w)}}
	}
	terminal := tab_session_panes(app, &tab.tree, index)
	for pane, ok := workspace_pane_next(&terminal); ok; pane, ok = workspace_pane_next(&terminal) {
		session_close(app, pane.content.id)
	}
	// The record leaves the list and selection names a remaining tab before anything can observe either.
	ordered_remove(&workspace.tabs, index)
	workspace.selected = tab_selected_after_remove(workspace.selected, index, len(workspace.tabs))
	tab_record_free(tab)
	workspace_mutation_finish(app, workspace, {.Structure})
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		w := app.windows[i]
		if w.workspace != workspace {continue}
		tab_presentation_remove(&w.presentation, index)
		if len(workspace.tabs) > 0 {
			window_relayout(app, w)
			rail_reveal_active(w)
			if was_selected {focus_enter(app, w)}
		}
	}
}

window_update_title :: proc(app: ^App, w: ^Window) {
	tab := selected_tab(w.workspace)
	tab_update_title(app, tab)
	title := tab.title != "" ? tab.title : app.app_id
	if !app.platform_ready {return}
	if platform.window_set_title(&app.platform, w.id, title) != .None {
		log.error("setting the window title failed")
	}
}

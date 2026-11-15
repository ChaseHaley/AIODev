package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:turns"
import "aio:ui"
import "core:reflect"
import "core:strings"
import "core:time"

// Agent changes panes: what agents changed per turn, and plain git diffs. A pane follows one agent (the
// pane that ran it and its session, either of which may be unknown) and a directory inside the repository.

@(private)
CHANGES_POLL :: 500 * time.Millisecond

// What the pane shows. changes_model.odin fills the view from the worker's results and owns what is
// listed here; the pane's input only reads it and changes the selection and the folds.
Changes_Model :: struct {
	view:           ui.Changes_View,
	// The id of the newest read asked for; an older result is stale.
	request:        u64,
	// The id of the read the view shows; equal to `request` once the newest read has answered.
	answered:       u64,
	// The result the view borrows its diff and titles from.
	content:        Turn_Result,
	// Parallel to view.turns, whose details are the strings in `details`.
	row_ids:        []u64,
	details:        []string,
	// The repository the last turn query found, "" until one answered.
	repository_key: string,
	// Paths the user folded; they stay folded whenever a diff shows them again.
	folded:         map[string]struct{},
	// Whether the view holds a result for `shown`.
	loaded:         bool,
	shown:          ui.Changes_Scope,
	// The worker is watching the pane's worktree for a git scope.
	watching:       bool,
	// The folder the view watch is on; it follows the worktree the result shows.
	watched:        string,
	// The worktree dropdown's choices: "Follow the agent", then one per worktree, and the worktrees'
	// absolute paths, parallel to the choices after the first. Kept here because the dropdown borrows them.
	worktree_labels: []string,
	worktree_paths: []string,
	// The repository's agents from the last result that read them, newest first, owned here so the source
	// dropdown keeps them while the next read runs.
	agents:         []Changes_Agent,
	// The source dropdown's choices: one label per agent, owned, then the fixed scope labels.
	sources:        []string,
	// The label of the pane's own agent, which the source field shows in the Agent scope.
	agent_label:    string,
	// The file list's choices, parallel to view.files and owned: "<status mark> <path>  +A −R".
	file_labels:    []string,
	// turns.record when the pane last asked, so a change is noticed.
	recording:      bool,
	// The wall-clock minute the row ages were written for.
	aged:           i64,
}

// What a press on the turns holds while the pointer moves: a drag across the strip's bars or the turn
// list's rows extends the selection.
@(private)
Changes_Drag :: enum u8 {
	None,
	Strip,
	Turn_List,
}

// Owned by App.changes_panes; windows refer to it by id and the poll frees it once none does.
Changes_Pane :: struct {
	id:         u32,
	// The agent the pane follows; its strings are owned.
	agent:      turns.Session,
	directory:  string,
	scope:      ui.Changes_Scope,
	state:      ui.Changes_State,
	model:      Changes_Model,
	comments:   Changes_Comments,
	dropdown:   ui.Dropdown,
	scope_open: bool,
	// The worktree dropdown is open; it shares `dropdown` with the source's, and only one opens.
	worktree_open: bool,
	// The worktree the git scopes show; "" follows the agent. Not persisted.
	worktree_pick: string,
	// The file list is open; it shares `dropdown` too.
	files_open: bool,
	// The diff shows old and new side by side. Persisted, and copied by a pane opened from this one.
	side_by_side: bool,
	// The turn a selection extends from, and the turn the keys move; -1 for none.
	anchor:     int,
	cursor:     int,
	dragging:   Changes_Drag,
	moving:     bool,
}

// App embeds it; this file owns it, and changes_app_destroy releases it.
Changes_App :: struct {
	changes_panes:    [dynamic]^Changes_Pane,
	next_changes_id:  u32,
	// Zero while no pane is registered, so nothing polls.
	changes_deadline: time.Tick,
	// Whether the turn hooks are installed; read from the settings files once, not per pane.
	turn_hooks:       Changes_Hooks,
}

@(require_results)
changes_find :: proc(app: ^App, id: u32) -> ^Changes_Pane {
	for pane in app.changes_panes {if pane.id == id {return pane}}
	return nil
}

// Frees the pane and its model. The worker is not told: app destroy has stopped it.
@(private)
changes_pane_free :: proc(pane: ^Changes_Pane) {
	changes_model_destroy(pane)
	changes_comments_destroy(&pane.comments)
	ui.dropdown_destroy(&pane.dropdown)
	ui.changes_state_destroy(&pane.state)
	changes_session_delete(&pane.agent)
	delete(pane.directory)
	delete(pane.worktree_pick)
	free(pane)
}

// Tells the worker the pane is gone, then frees it. The worker hears this even for a pane that never
// watched a worktree, because it also stops live updates for a pane that read turns.
@(private)
changes_pane_destroy :: proc(app: ^App, pane: ^Changes_Pane) {
	if pane.model.watching {changes_model_unwatch(app, pane)} else {turn_worker_view_unwatch(app, pane.id)}
	changes_pane_free(pane)
}

changes_app_destroy :: proc(state: ^Changes_App) {
	for pane in state.changes_panes {changes_pane_free(pane)}
	delete(state.changes_panes)
	state^ = {}
}

// The scope as the layout file names it.
@(require_results)
changes_scope_name :: proc(scope: ui.Changes_Scope) -> string {
	return reflect.enum_string(scope)
}

// The scope a layout file names; an unknown name is Uncommitted, which always works.
@(require_results)
changes_scope_parse :: proc(name: string) -> ui.Changes_Scope {
	scope, ok := reflect.enum_from_name(ui.Changes_Scope, name)
	return ok ? scope : .Uncommitted
}

// Registers a pane. `agent` and `directory` are copied.
@(require_results)
changes_pane_create :: proc(
	app: ^App,
	agent: turns.Session,
	directory: string,
	scope: ui.Changes_Scope,
	side_by_side := false,
) -> ^Changes_Pane {
	pane, err := new(Changes_Pane)
	if err != nil {return nil}
	cloned_agent, agent_cloned := changes_session_clone(agent)
	cloned_directory, directory_error := strings.clone(directory)
	if !agent_cloned || directory_error != nil {
		changes_session_delete(&cloned_agent)
		delete(cloned_directory)
		free(pane)
		return nil
	}
	pane.agent, pane.directory, pane.scope = cloned_agent, cloned_directory, scope
	pane.side_by_side, pane.model.view.side_by_side = side_by_side, side_by_side
	pane.anchor, pane.cursor = -1, -1
	pane.model.view.first, pane.model.view.last = -1, -1
	pane.comments.editing, pane.model.view.editing = -1, -1
	ui.dropdown_init(&pane.dropdown)
	if _, append_error := append(&app.changes_panes, pane); append_error != nil {
		changes_pane_free(pane)
		return nil
	}
	app.next_changes_id += 1
	pane.id = app.next_changes_id
	app.turn_hooks = .Unknown
	_ = changes_sources_refresh(app, pane)
	changes_model_changed(app, pane)
	if app.changes_deadline == {} {app.changes_deadline = time.tick_add(clock_now(&app.clock), CHANGES_POLL)}
	return pane
}

@(private, require_results)
changes_referenced :: proc(app: ^App, id: u32) -> bool {
	content := layout.Content{.Changes, id}
	for workspace in app.workspaces {if workspace_has_content(workspace, content) {return true}}
	return false
}

// Frees panes nothing shows any more and follows the recording setting.
changes_tick :: proc(app: ^App) {
	if app.changes_deadline == {} {return}
	now := clock_now(&app.clock)
	if time.tick_diff(now, app.changes_deadline) > 0 {return}
	changed := false
	for i := len(app.changes_panes) - 1; i >= 0; i -= 1 {
		pane := app.changes_panes[i]
		if !changes_referenced(app, pane.id) {
			changes_pane_destroy(app, pane)
			ordered_remove(&app.changes_panes, i)
			continue
		}
		changed = changes_model_poll(app, pane) || changed
	}
	app.changes_deadline = len(app.changes_panes) > 0 ? time.tick_add(now, CHANGES_POLL) : {}
	if changed {mark_all_dirty(app)}
}

changes_poll_deadline :: proc(app: ^App) -> (next: time.Tick, pending: bool) {
	if app.changes_deadline == {} {return}
	return app.changes_deadline, true
}

// Opens another Agent changes pane beside the focused pane: for the focused pane's agent in the default
// diff view, or with the agent, scope, directory and diff view of the focused Agent changes pane.
changes_open :: proc(app: ^App, w: ^Window) {
	acting := pane_link_acting_window(app, w)
	workspace := acting.workspace
	if workspace == nil || workspace.selected < 0 || workspace.selected >= len(workspace.tabs) {return}
	tab := workspace.selected
	agent: turns.Session
	directory := ""
	scope := ui.Changes_Scope.Uncommitted
	side_by_side := app.settings.turns.diff_view == .Side_By_Side
	if from := changes_focused(app, acting); from != nil {
		agent, directory, scope, side_by_side = from.agent, from.directory, from.scope, from.side_by_side
	} else if entry := focused_session(app, acting); entry != nil {
		agent = turn_recorder_session(app, entry.key)
		directory, _ = pane_directory(app, entry)
		if pane_agent(app, entry, nil).launch.harness != .None || len(entry.statuses) > 0 {scope = .Agent}
	} else if page := markdown_focused(app, acting); page != nil {
		directory = page.directory
	}
	if directory == "" {directory = home_directory()}
	pane := changes_pane_create(app, agent, directory, scope, side_by_side)
	if pane == nil {
		notify(app, .Error, "Could not open Agent changes.")
		return
	}
	content := layout.Content{.Changes, pane.id}
	if !pane_place(app, acting, workspace, tab, window_tree(acting).focus, content, .Split_Right, true) {
		notify(app, .Error, "Could not open Agent changes.")
	}
}

@(require_results)
changes_focused :: proc(app: ^App, w: ^Window) -> ^Changes_Pane {
	content, ok := window_focused_content(w)
	if !ok || content.kind != .Changes {return nil}
	return changes_find(app, content.id)
}

changes_active :: proc(w: ^Window) -> bool {
	content, ok := window_focused_content(w)
	return ok && content.kind == .Changes
}

@(private, require_results)
changes_pane_rect :: proc(w: ^Window, id: u32) -> (layout.Pane_Rect, bool) {
	for pane in w.panes {if pane.content == {.Changes, id} {return pane, true}}
	return {}, false
}

@(private, require_results)
changes_under_pointer :: proc(app: ^App, w: ^Window, x, y: f32) -> (^Changes_Pane, layout.Pane_Rect) {
	shown, found := layout.hit_test(w.panes[:], x, y)
	if !found || shown.content.kind != .Changes {return nil, {}}
	return changes_find(app, shown.content.id), shown
}

// The pane's geometry with its diff rows laid out. The comments' part of the view is filled first: it is
// temporary memory, and the rows, the draw and every hit test read it.
@(require_results)
changes_geometry_of :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Changes_Pane,
	shown: layout.Pane_Rect,
) -> ui.Changes_Geometry {
	changes_comments_view(app, pane)
	mono := ui.text_mono(&w.ui_text, app.family)
	g := ui.changes_geometry(pane_body_rect(w, shown), w.scale, &pane.model.view, &w.ui_text)
	ui.changes_layout(&pane.state, &pane.model.view, &w.ui_text, &mono, g.diff.width, w.scale)
	return g
}

// Keeps the selection's newest end in the strip of the first window that shows the pane.
@(private)
changes_reveal :: proc(app: ^App, pane: ^Changes_Pane) {
	for w in app.windows {
		shown, found := changes_pane_rect(w, pane.id)
		if !found {continue}
		g := changes_geometry_of(app, w, pane, shown)
		_ = ui.changes_strip_reveal(&pane.state, g, &pane.model.view)
		return
	}
}

@(private = "file", require_results)
changes_list_open :: proc(pane: ^Changes_Pane) -> bool {
	return pane.scope_open || pane.worktree_open || pane.files_open
}

@(private = "file")
CHANGES_FILE_LIST_WIDTH :: f32(360)

@(private = "file")
changes_dropdown_choices :: proc(pane: ^Changes_Pane) -> ui.Dropdown_Choices {
	if pane.worktree_open {
		return {
			choices = pane.model.worktree_labels,
			value = changes_worktree_value(pane),
			searchable = true,
			placeholder = "Search worktrees",
		}
	}
	if pane.files_open {
		return {
			choices = pane.model.file_labels,
			searchable = true,
			placeholder = "Search files",
			min_width = CHANGES_FILE_LIST_WIDTH,
		}
	}
	return {choices = pane.model.sources, value = pane.model.view.source_label}
}

@(private = "file")
changes_dropdown_anchor :: proc(pane: ^Changes_Pane, g: ui.Changes_Geometry) -> ui.Dropdown_Anchor {
	if pane.files_open {
		return {field = g.files_button, row = g.files_button, bounds = g.area, align_end = true}
	}
	field := pane.worktree_open ? g.worktree : g.scope
	return {field = field, row = field, bounds = g.area}
}

@(private = "file")
changes_list_close :: proc(w: ^Window, pane: ^Changes_Pane) {
	if !changes_list_open(pane) {return}
	pane.scope_open, pane.state.scope_open = false, false
	pane.worktree_open, pane.state.worktree_open = false, false
	pane.files_open, pane.state.files_open = false, false
	ui.dropdown_close(&pane.dropdown)
	w.dirty = true
}

// What the open list's highlighted choice is, so a new result can find it again: a file's path, a
// worktree's path ("" for following the agent) or a source's label. In temporary memory.
@(private)
changes_list_highlight :: proc(pane: ^Changes_Pane) -> (identity: string, highlighted: bool) {
	if !changes_list_open(pane) {return}
	index := ui.dropdown_highlighted(&pane.dropdown, changes_dropdown_choices(pane))
	if index < 0 {return}
	return strings.clone(changes_list_identity(pane, index), context.temp_allocator), true
}

@(private = "file", require_results)
changes_list_identity :: proc(pane: ^Changes_Pane, choice: int) -> string {
	model := &pane.model
	if pane.files_open {
		return choice < len(model.view.files) ? changes_file_path(model.view.files[choice]) : ""
	}
	if pane.worktree_open {
		return choice > 0 && choice <= len(model.worktree_paths) ? model.worktree_paths[choice - 1] : ""
	}
	return choice < len(model.sources) ? model.sources[choice] : ""
}

// A new result rebuilt the open list's choices: its search runs again over them, and the highlight stays
// on the choice it was on (`kept`, from changes_list_highlight) at the same row of the list, or on the
// nearest row when that choice is gone.
@(private)
changes_list_refilter :: proc(pane: ^Changes_Pane, kept: string, highlighted: bool) {
	if !changes_list_open(pane) {return}
	d := &pane.dropdown
	choices := changes_dropdown_choices(pane)
	index, scroll := d.list.index, d.list.scroll
	if choices.searchable {
		query := strings.clone(ui.field_string(&d.search), context.temp_allocator)
		ui.dropdown_restore(d, choices, query, false)
	}
	count := ui.dropdown_count(d, choices)
	position := -1
	for i in 0 ..< count {
		if !highlighted {break}
		choice := choices.searchable ? d.matches[i] : i
		if changes_list_identity(pane, choice) == kept {
			position = i
			break
		}
	}
	if position < 0 {position = min(index, count - 1)}
	d.list.index = position
	d.list.scroll = clamp(scroll + position - index, 0, max(0, count - 1))
}

// A list opening takes the keyboard from the comment editor, which keeps what it holds, as a press on a
// line does.
@(private = "file")
changes_list_begin :: proc(app: ^App, pane: ^Changes_Pane) {
	changes_editor_close(app, pane, true)
}

// Applies the highlighted choice of the open list.
@(private = "file")
changes_list_choose :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, index: int) {
	if index < 0 {return}
	if pane.worktree_open {
		changes_worktree_pick(app, pane, index)
	} else if pane.files_open {
		changes_file_pick(app, w, pane, index)
	} else {
		changes_source_pick(app, pane, index)
	}
}

// Unfolds file `index` and scrolls the diff so its header is at the top.
changes_file_pick :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, index: int) {
	view := &pane.model.view
	if index < 0 || index >= len(view.files) {return}
	if index < len(view.collapsed) && view.collapsed[index] {changes_model_fold(&pane.model, index)}
	shown, found := changes_pane_rect(w, pane.id)
	if !found {return}
	// Laid out first, so the file's top counts the unfolded body; then kept within what can scroll.
	g := changes_geometry_of(app, w, pane, shown)
	pane.state.diff_scroll = ui.changes_diff_file_top(&pane.state, view, index)
	_ = ui.changes_scroll_diff(&pane.state, g, 0)
	w.dirty = true
}

// Switches the pane between the unified and side-by-side diff, keeping the file at the top in view.
changes_layout_toggle :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	view := &pane.model.view
	shown, found := changes_pane_rect(w, pane.id)
	top := -1
	if found {
		_ = changes_geometry_of(app, w, pane, shown)
		top = ui.changes_top_file(&pane.state, view)
	}
	pane.side_by_side = !pane.side_by_side
	view.side_by_side = pane.side_by_side
	view.revision += 1
	if found && top >= 0 {
		g := changes_geometry_of(app, w, pane, shown)
		pane.state.diff_scroll = ui.changes_diff_file_top(&pane.state, view, top)
		_ = ui.changes_scroll_diff(&pane.state, g, 0)
	}
	layout_state_touch(app)
	w.dirty = true
}

// Typed or pasted text goes to the open list's search, else to the comment being written.
changes_text :: proc(app: ^App, w: ^Window, text: string) -> bool {
	pane := changes_focused(app, w)
	if pane == nil {return false}
	if changes_list_open(pane) {
		if ui.dropdown_text(&pane.dropdown, changes_dropdown_choices(pane), text) {w.dirty = true}
		return true
	}
	return changes_comments_text(app, w, pane, text)
}

// Selects turn `index`, or with `extend` the run from the anchor to it, and keeps it in the strip.
@(private = "file")
changes_select :: proc(app: ^App, pane: ^Changes_Pane, g: ui.Changes_Geometry, index: int, extend: bool) {
	view := &pane.model.view
	if index < 0 || index >= len(view.turns) {return}
	if !extend {
		pane.anchor = index
	} else if pane.anchor < 0 || pane.anchor >= len(view.turns) {
		// The selection the worker chose on its own, such as the newest turn, has no anchor yet.
		pane.anchor = view.first >= 0 && view.first < len(view.turns) ? view.first : index
	}
	first, last := min(pane.anchor, index), max(pane.anchor, index)
	pane.cursor = index
	if first == view.first && last == view.last {return}
	view.first, view.last = first, last
	changes_model_changed(app, pane)
	_ = ui.changes_strip_reveal(&pane.state, g, view)
}

// Steps the selection `step` turns older, or newer when negative.
@(private = "file")
changes_move :: proc(app: ^App, pane: ^Changes_Pane, g: ui.Changes_Geometry, step: int, extend: bool) {
	view := &pane.model.view
	if len(view.turns) == 0 {return}
	from := pane.cursor
	if from < 0 || from >= len(view.turns) {from = view.first >= 0 ? view.first : (step > 0 ? -1 : 0)}
	changes_select(app, pane, g, clamp(from + step, 0, len(view.turns) - 1), extend)
}

@(private = "file")
changes_diff_scroll :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, shown: layout.Pane_Rect, delta: int) {
	g := changes_geometry_of(app, w, pane, shown)
	if ui.changes_scroll_diff(&pane.state, g, delta) {w.dirty = true}
}

@(private = "file")
changes_turn_list_set :: proc(w: ^Window, pane: ^Changes_Pane, g: ui.Changes_Geometry, open: bool) {
	if pane.state.turn_list_open == open {return}
	pane.state.turn_list_open = open
	pane.state.turn_list_bar = {}
	if open {
		at := pane.cursor >= 0 ? pane.cursor : pane.model.view.first
		_ = ui.changes_turn_list_reveal(&pane.state, g, &pane.model.view, at)
	}
	w.dirty = true
}

// Drives the hover and press fades of every Changes pane in the window.
@(private)
changes_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := false
	for shown in w.panes {
		if shown.content.kind != .Changes {continue}
		pane := changes_find(app, shown.content.id)
		if pane == nil {continue}
		pane.moving = ui.changes_animate(&pane.state, app.animations, frame)
		changed = changed || pane.moving
	}
	return changed
}

@(private)
changes_animating :: proc(app: ^App, w: ^Window) -> bool {
	for shown in w.panes {
		if shown.content.kind != .Changes {continue}
		if pane := changes_find(app, shown.content.id); pane != nil && pane.moving {return true}
	}
	return false
}

@(private = "file", require_results)
changes_has_live :: proc(view: ^ui.Changes_View) -> bool {
	for turn in view.turns {if turn.live {return true}}
	return false
}

// The pane's toolbar and diff, or its notice, inside the card; `scrollable` when its diff scrolls and a
// scrollbar belongs beside it.
@(require_results)
changes_pane_draw :: proc(
	app: ^App,
	w: ^Window,
	shown: layout.Pane_Rect,
) -> (
	scrollable: bool,
	result: render.Build_Status,
) {
	pane := changes_find(app, shown.content.id)
	if pane == nil {return false, .Ok}
	g := changes_geometry_of(app, w, pane, shown)
	mono := ui.text_mono(&w.ui_text, app.family)
	view := &pane.model.view
	// status_phase keeps the window repainting while a spinner shows, so the draw's own flag is not needed.
	phase: f32
	if changes_has_live(view) {phase = status_phase(app, w, {glyph = .Working, progress = -1})}
	result, _ = ui.changes_draw(
		&w.list, &w.ui_text, &mono, &app.theme, g, view, &pane.state, w.scale, w.pointer, phase,
	)
	if result != .Ok {return true, result}
	if changes_list_open(pane) {
		result = ui.dropdown_draw(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), &w.list, &w.ui_text,
			app.theme, w.pointer, w.scale,
		)
	}
	return view.notice == .None, result
}

changes_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	pane_header_cancel(w)
	key_suppress(w, e)
	key, consumed := content_key_prelude(app, w, e, true)
	if consumed {return}
	if !e.pressed {return}
	pane := changes_focused(app, w)
	shown: layout.Pane_Rect
	found := false
	if pane != nil {shown, found = changes_pane_rect(w, pane.id)}
	if pane != nil && changes_list_open(pane) && found {
		g := changes_geometry_of(app, w, pane, shown)
		outcome, taken := ui.dropdown_key(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), e, w.scale,
		)
		#partial switch outcome {
		case .Chosen:
			changes_list_choose(
				app, w, pane, ui.dropdown_highlighted(&pane.dropdown, changes_dropdown_choices(pane)),
			)
			changes_list_close(w, pane)
		case .Closed:
			changes_list_close(w, pane)
		case:
			w.dirty = true
		}
		if taken {return}
	}
	if pane != nil && found && pane.state.turn_list_open && key.logical.key == .Escape {
		changes_turn_list_set(w, pane, changes_geometry_of(app, w, pane, shown), false)
		return
	}
	// The comment editor's keys come before shortcuts, as the Settings fields' do.
	if pane != nil && found && changes_comments_key(app, w, pane, e) {return}
	if key.found && (key.runtime || action_available(app, w, key.action)) {
		run_window_command(app, w, key.command, .Key)
		return
	}
	status_inbox_typed(w, e)
	if pane == nil || !found {return}
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	extend := modifiers == {.Shift}
	if modifiers != {} && !extend {return}
	g := changes_geometry_of(app, w, pane, shown)
	view := &pane.model.view
	turn_scope := ui.changes_scope_turns(pane.scope)
	page := max(1, int(g.diff.height))
	#partial switch key.logical.key {
	case .Arrow_Left:
		// Older turns sit to the left in the strip.
		if turn_scope {changes_move(app, pane, g, 1, extend)}
	case .Arrow_Right:
		if turn_scope {changes_move(app, pane, g, -1, extend)}
	case .Page_Up:
		if !extend {changes_diff_scroll(app, w, pane, shown, -page)}
	case .Page_Down:
		if !extend {changes_diff_scroll(app, w, pane, shown, page)}
	case .Home:
		if turn_scope {
			changes_select(app, pane, g, len(view.turns) - 1, extend)
		} else if !extend {
			changes_diff_scroll(app, w, pane, shown, -max(int))
		}
	case .End:
		if turn_scope {
			changes_select(app, pane, g, 0, extend)
		} else if !extend {
			changes_diff_scroll(app, w, pane, shown, max(int))
		}
	}
}

// Rows are the scrolled lines, positive toward the top, as the mouse wheel reports them.
@(require_results)
changes_wheel :: proc(app: ^App, w: ^Window, x, y: f32, rows: int) -> bool {
	pane, shown := changes_under_pointer(app, w, x, y)
	if shown.content.kind != .Changes {return false}
	if pane == nil {return true}
	g := changes_geometry_of(app, w, pane, shown)
	if changes_list_open(pane) {
		_ = ui.dropdown_wheel(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), rows, w.scale,
		)
		w.dirty = true
		return true
	}
	view := &pane.model.view
	mono := ui.text_mono(&w.ui_text, app.family)
	delta := -rows * int(mono.line_height)
	if pane.state.turn_list_open && render.rect_contains(g.turn_list, x, y) {
		if ui.changes_scroll_turn_list(&pane.state, g, view, delta) {w.dirty = true}
	} else if render.rect_contains(g.strip, x, y) {
		// Scrolling up shows older bars, which sit to the left.
		if ui.changes_scroll_strip(&pane.state, g, view, -rows) {w.dirty = true}
	} else {
		changes_diff_scroll(app, w, pane, shown, delta)
	}
	return true
}

// Pointer surface

changes_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	shown, found := layout.hit_test(w.panes[:], x, y)
	return found && shown.content.kind == .Changes
}

@(private = "file")
changes_hover_clear :: proc(app: ^App, w: ^Window) {
	for shown in w.panes {
		if shown.content.kind != .Changes {continue}
		pane := changes_find(app, shown.content.id)
		if pane != nil && pane.state.hover != {} {pane.state.hover, w.dirty = {}, true}
	}
}

// The pointer is off every Agent changes pane.
changes_leave :: proc(app: ^App, w: ^Window) {
	changes_hover_clear(app, w)
	pane_scrollbar_hover_leave(w, .Changes)
}

@(private = "file", require_results)
changes_cursor :: proc(hit: ui.Changes_Hit) -> platform.Cursor_Shape {
	#partial switch hit.part {
	case .Scope, .Worktree, .Hooks, .Notice_Button, .File_Header, .Strip_Bar, .Step_Back, .Step_Forward,
	     .Range_Label, .Hunk_Comment, .Comment_Button, .Comment_Card, .Comment_Delete, .Send, .Copy, .Discard,
	     .Files_Button, .Layout_Button:
		return .Hand
	case .Turn_List_Row:
		if hit.index >= 0 {return .Hand}
	case .Comment_Editor:
		return .Text
	}
	return .Arrow
}

// A held press on the strip or the turn list extends the selection to the bar or row under the pointer.
@(private = "file")
changes_drag_turns :: proc(app: ^App, pane: ^Changes_Pane, g: ui.Changes_Geometry, hit: ui.Changes_Hit) {
	wanted := pane.dragging == .Strip ? ui.Changes_Part.Strip_Bar : ui.Changes_Part.Turn_List_Row
	if hit.part != wanted || hit.index < 0 || hit.index == pane.cursor {return}
	changes_select(app, pane, g, hit.index, true)
}

changes_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	if owner != .Changes_Page {
		changes_leave(app, w)
		return
	}
	pane, shown := changes_under_pointer(app, w, x, y)
	if pane == nil {
		changes_leave(app, w)
		pointer_set(app, w, .Arrow)
		return
	}
	g := changes_geometry_of(app, w, pane, shown)
	view := &pane.model.view
	if pane.state.turn_list_bar.active {
		bar, visible := ui.changes_turn_list_scrollbar(&pane.state, g, view)
		if visible && .Left in e.buttons {
			pane.state.turn_list_scroll = ui.scrollbar_drag(pane.state.turn_list_bar, bar, y)
		} else {
			pane.state.turn_list_bar = {}
		}
		w.dirty = true
		return
	}
	if changes_list_open(pane) {
		if ui.dropdown_hover(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), x, y, w.scale,
		) {w.dirty = true}
		shape := ui.dropdown_pointer(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), x, y, w.scale,
		)
		pointer_set(app, w, shape)
		return
	}
	if .Left not_in e.buttons {pane.dragging = .None}
	shape := platform.Cursor_Shape.Arrow
	hit: ui.Changes_Hit
	bar, visible := pane_scrollbar_geometry(app, w, shown)
	if pane.dragging == .None && !pane.comments.dragging && visible && ui.scrollbar_contains(bar, x, y) {
		pane_scrollbar_hover_set(w, shown.content)
	} else {
		pane_scrollbar_hover_leave(w, .Changes)
		hit = ui.changes_hit(g, view, &pane.state, x, y)
		shape = changes_cursor(hit)
		if pane.dragging != .None {
			changes_drag_turns(app, pane, g, hit)
		} else if pane.comments.dragging && .Left in e.buttons {
			if changes_comments_drag(app, w, pane, hit) {w.dirty = true}
		}
	}
	if pane.state.hover != hit {pane.state.hover, w.dirty = hit, true}
	pointer_set(app, w, shape)
}

changes_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	pane, shown := changes_under_pointer(app, w, x, y)
	if shown.content.kind != .Changes {return}
	pane_focus(app, w, shown.node)
	if pane == nil || e.button != .Left {return}
	w.dirty = true
	g := changes_geometry_of(app, w, pane, shown)
	if changes_list_open(pane) {
		choices, anchor := changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g)
		switch ui.dropdown_press(&pane.dropdown, choices, anchor, &w.ui_text, x, y, false, w.scale) {
		case .Chosen:
			changes_list_choose(app, w, pane, ui.dropdown_highlighted(&pane.dropdown, choices))
			changes_list_close(w, pane)
		case .None:
			changes_list_close(w, pane)
		case .Changed, .Closed, .Font_Filter:
		}
		return
	}
	view := &pane.model.view
	if pane.state.turn_list_open {
		if bar, visible := ui.changes_turn_list_scrollbar(&pane.state, g, view);
		   visible && ui.scrollbar_contains(bar, x, y) {
			pane.state.turn_list_scroll = ui.scrollbar_press(&pane.state.turn_list_bar, bar, y)
			return
		}
	}
	if pane_scrollbar_press(app, w, shown, x, y) {return}
	hit := ui.changes_hit(g, view, &pane.state, x, y)
	pane.state.press = hit
	extend := .Shift in e.modifiers
	// A press outside the open turn list only closes it, as a press outside a dropdown does.
	if pane.state.turn_list_open && hit.part != .Turn_List_Row && hit.part != .Range_Label {
		changes_turn_list_set(w, pane, g, false)
		return
	}
	#partial switch hit.part {
	case .Scope:
		changes_list_begin(app, pane)
		_ = changes_sources_refresh(app, pane)
		pane.scope_open, pane.state.scope_open = true, true
		ui.dropdown_open(&pane.dropdown, changes_dropdown_choices(pane))
	case .Worktree:
		if len(pane.model.worktree_labels) > 0 {
			changes_list_begin(app, pane)
			pane.worktree_open, pane.state.worktree_open = true, true
			ui.dropdown_open(&pane.dropdown, changes_dropdown_choices(pane))
		}
	case .Hooks:
		run_action(app, w, .Install_Turn_Hooks, .Button)
	case .Notice_Button:
		_ = settings_save_value(app, "turns.record", "true", "Could not turn on turn recording.")
		changes_model_changed(app, pane)
	case .Strip_Bar:
		changes_select(app, pane, g, hit.index, extend)
		pane.dragging = .Strip
	case .Step_Back:
		changes_move(app, pane, g, 1, extend)
	case .Step_Forward:
		changes_move(app, pane, g, -1, extend)
	case .Range_Label:
		changes_turn_list_set(w, pane, g, !pane.state.turn_list_open)
	case .Turn_List_Row:
		if hit.index >= 0 {
			changes_select(app, pane, g, hit.index, extend)
			pane.dragging = .Turn_List
		}
	case .File_Header:
		changes_model_fold(&pane.model, hit.index)
	case .Files_Button:
		if len(pane.model.file_labels) > 0 {
			changes_list_begin(app, pane)
			pane.files_open, pane.state.files_open = true, true
			ui.dropdown_open(&pane.dropdown, changes_dropdown_choices(pane))
		}
	case .Layout_Button:
		changes_layout_toggle(app, w, pane)
	case .Line, .Hunk_Comment, .Comment_Button, .Comment_Card, .Comment_Delete, .Comment_Editor, .Send, .Copy,
	     .Discard:
		_ = changes_comments_press(app, w, pane, hit, e)
	}
}

changes_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left {return false}
	if pane_scrollbar_end(w, .Changes) {
		w.dirty = true
		return true
	}
	cleared := false
	for shown in w.panes {
		if shown.content.kind != .Changes {continue}
		pane := changes_find(app, shown.content.id)
		if pane == nil {continue}
		if pane.state.turn_list_bar.active {pane.state.turn_list_bar, cleared = {}, true}
		if pane.state.press != {} {pane.state.press, cleared = {}, true}
		if pane.dragging != .None {pane.dragging, cleared = .None, true}
		if pane.comments.dragging {cleared = true}
		changes_comments_release(app, w, pane)
	}
	if cleared {w.dirty = true}
	return cleared
}

// Ends whatever the pointer holds on an Agent changes pane: a press, a drag or a scrollbar thumb.
changes_cancel :: proc(app: ^App, w: ^Window) {
	_ = changes_release(app, w, {button = .Left})
}

// The strip bar's turn, why Send is off, and what the toolbar and hunk buttons do.
@(private)
changes_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	pane, shown := changes_under_pointer(app, w, x, y)
	if pane == nil || changes_list_open(pane) {return ""}
	g := changes_geometry_of(app, w, pane, shown)
	view := &pane.model.view
	hit := ui.changes_hit(g, view, &pane.state, x, y)
	#partial switch hit.part {
	case .Strip_Bar:
		return ui.changes_turn_tooltip(view, hit.index, context.temp_allocator)
	case .Send:
		if !view.send.can_send {return view.send.reason}
	case .Hunk_Comment:
		return "Comment on this hunk"
	case .Layout_Button:
		return pane.side_by_side ? "Unified view" : "Side-by-side view"
	case .Files_Button:
		return "Files in this diff"
	}
	return ""
}

when AIO_CONTROL {
	// "changes.<kind>.<index>.<field>"
	@(private = "file")
	changes_report_key :: proc(kind: string, index: int, field: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "changes.")
		strings.write_string(&b, kind)
		strings.write_byte(&b, '.')
		strings.write_int(&b, index)
		strings.write_byte(&b, '.')
		strings.write_string(&b, field)
		return strings.to_string(b)
	}

	@(private = "file")
	changes_highlighted :: proc(view: ^ui.Changes_View, file: int) -> bool {
		if file >= len(view.highlights) {return false}
		for spans in view.highlights[file].lines {if len(spans) > 0 {return true}}
		return false
	}

	// The focused Agent changes pane's verification keys; the rectangles are where the draw puts the
	// controls, zero when a control is not shown.
	changes_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		pane := changes_focused(app, w)
		scope, notice, range_label := "none", "none", ""
		turn_count, first, last, files := 0, -1, -1, 0
		scope_rect, worktree_rect, notice_rect, hooks_rect: render.Rect
		step_back_rect, step_forward_rect, range_label_rect: render.Rect
		files_button_rect, layout_button_rect: render.Rect
		top_file := -1
		label_buffer: [64]u8
		if pane != nil {
			view := &pane.model.view
			scope = strings.to_lower(changes_scope_name(pane.scope), context.temp_allocator)
			notice = strings.to_lower(reflect.enum_string(view.notice), context.temp_allocator)
			turn_count, first, last, files = len(view.turns), view.first, view.last, len(view.files)
			if shown, found := changes_pane_rect(w, pane.id); found {
				g := changes_geometry_of(app, w, pane, shown)
				scope_rect, worktree_rect = g.scope, g.worktree
				step_back_rect, step_forward_rect, range_label_rect = g.step_back, g.step_forward, g.range_label
				if view.notice == .Recording_Off {notice_rect = g.notice_button}
				if view.hooks_offer {hooks_rect = g.hooks}
				files_button_rect, layout_button_rect = g.files_button, g.layout_button
				top_file = ui.changes_top_file(&pane.state, view)
				for i in 0 ..< len(view.turns) {
					rect := ui.changes_strip_bar_rect(g, &pane.state, view, i)
					if rect.width <= 0 || rect.height <= 0 {continue}
					state_rect(r, changes_report_key("strip", i, "rect"), rect)
				}
			}
			// State entries borrow their text until the report is written, after this returns.
			if ui.changes_scope_turns(pane.scope) {
				range_label = strings.clone(ui.changes_range_label(view, label_buffer[:]), context.temp_allocator)
			}
			for turn, i in view.turns {state_value(r, changes_report_key("turn", i, "live"), turn.live)}
			for i in 0 ..< min(len(pane.model.agents), len(pane.model.sources)) {
				state_text(r, changes_report_key("agent", i, "label"), pane.model.sources[i])
			}
			for file, i in view.files {
				state_text(r, changes_report_key("file", i, "path"), file.new_path)
				state_value(r, changes_report_key("file", i, "added"), file.added)
				state_value(r, changes_report_key("file", i, "removed"), file.removed)
				marked := i < len(view.marked) && view.marked[i]
				state_value(r, changes_report_key("file", i, "marked"), marked)
				ambiguous := i < len(view.ambiguous) && view.ambiguous[i]
				state_value(r, changes_report_key("file", i, "ambiguous"), ambiguous)
				folded := i < len(view.collapsed) && view.collapsed[i]
				state_value(r, changes_report_key("file", i, "collapsed"), folded)
				state_value(r, changes_report_key("file", i, "highlighted"), changes_highlighted(view, i))
			}
			if pane.files_open {
				choices := changes_dropdown_choices(pane)
				for match, i in pane.dropdown.matches {
					if i >= 20 {break}
					if match < len(choices.choices) {
						state_text(r, changes_report_key("file_list", i, "label"), choices.choices[match])
					}
				}
			}
		}
		state_value(r, "changes.count", len(app.changes_panes))
		state_value(r, "changes.active", changes_active(w))
		worktree := ""
		if pane != nil {
			if plain, ok := pane.model.content.(Result_Plain); ok {worktree = plain.worktree}
		}
		state_text(r, "changes.scope", scope)
		state_text(r, "changes.agent", pane != nil ? pane.model.agent_label : "")
		state_value(r, "changes.agents", pane != nil ? len(pane.model.agents) : 0)
		state_text(r, "changes.worktree", worktree)
		state_value(r, "changes.following", pane != nil && pane.model.view.following)
		state_value(r, "changes.worktrees", pane != nil ? len(pane.model.worktree_paths) : 0)
		state_text(r, "changes.notice", notice)
		state_value(r, "changes.turns", turn_count)
		state_value(r, "changes.first", first)
		state_value(r, "changes.last", last)
		state_value(r, "changes.files", files)
		state_value(r, "changes.recording", app.settings.turns.record)
		state_value(r, "changes.loaded", pane != nil && pane.model.loaded)
		state_value(r, "changes.settled", pane != nil && pane.model.answered == pane.model.request)
		state_value(r, "changes.hooks_offer", pane != nil && pane.model.view.hooks_offer)
		state_text(r, "changes.repository", pane != nil ? pane.model.view.repository : "")
		state_text(r, "changes.detail", pane != nil ? pane.model.view.detail : "")
		state_value(r, "changes.omitted", pane != nil ? pane.model.view.omitted : 0)
		state_value(r, "changes.dropdown_open", pane != nil && changes_list_open(pane))
		state_value(r, "changes.turn_list_open", pane != nil && pane.state.turn_list_open)
		state_value(r, "changes.files_open", pane != nil && pane.files_open)
		state_value(r, "changes.side_by_side", pane != nil && pane.side_by_side)
		state_value(r, "changes.diff_scroll", pane != nil ? pane.state.diff_scroll : 0)
		state_value(r, "changes.top_file", top_file)
		state_text(r, "changes.range_label", range_label)
		state_rect(r, "changes.scope_rect", scope_rect)
		state_rect(r, "changes.worktree_rect", worktree_rect)
		state_rect(r, "changes.notice_button_rect", notice_rect)
		state_rect(r, "changes.hooks_rect", hooks_rect)
		state_rect(r, "changes.step_back_rect", step_back_rect)
		state_rect(r, "changes.step_forward_rect", step_forward_rect)
		state_rect(r, "changes.range_label_rect", range_label_rect)
		state_rect(r, "changes.files_button_rect", files_button_rect)
		state_rect(r, "changes.layout_button_rect", layout_button_rect)
		changes_comments_state_report(r, app, w, pane)
	}
}

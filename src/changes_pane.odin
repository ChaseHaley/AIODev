package main

import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:syntax"
import "aio:turns"
import "aio:ui"
import "core:fmt"
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
	// The worktree chips' labels: "Follow the agent", then one per worktree, and the worktrees' absolute
	// paths, parallel to the labels after the first. Kept here because the view borrows them.
	worktree_labels: []string,
	worktree_paths: []string,
	// The repository's agents from the last result that read them, newest first, owned here so the source
	// chips keep them while the next read runs.
	agents:         []Changes_Agent,
	// The source chips' labels: one per agent, owned, then the fixed scope labels.
	sources:        []string,
	// The label of the pane's own agent, which the summary names in the Agent scope.
	agent_label:    string,
	// The result's files and what runs parallel to them, borrowed from the result, so the diff filter can
	// refill the view without asking the worker again.
	diff:           Changes_Diff,
	// The file list's choices, parallel to diff.files and owned: "<status mark> <path>  +A −R".
	file_labels:    []string,
	// What the file list's search matches, parallel to file_labels: each path as the diff header shows it,
	// borrowed from the result like `diff`.
	file_paths:     []string,
	// Parallel to file_labels: the file list's rows, borrowing from file_paths, and a number that changes
	// with every result so the list measures them again.
	file_rows:      []ui.Dropdown_Row,
	file_serial:    int,
	// Parallel to diff.files: the filter hides the file and it was not picked; the file list fades it.
	faded:          []bool,
	// Parallel to view.files: each shown file's index in diff.files.
	file_index:     []int,
	// What view.files and view.highlights point at: the shown files' entries, owned.
	shown_files:    []turns.Diff_File,
	shown_highlights: []syntax.File_Lines,
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

Changes_Divider_Drag :: struct {
	pane:   u32,
	offset: f32,
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
	// The worktree the git scopes show; "" follows the agent. Not persisted.
	worktree_pick: string,
	// The diff shows old and new side by side. Persisted, and copied by a pane opened from this one.
	side_by_side: bool,
	// The diff filter: its text is what `filter_editor` holds (persisted, and copied by a pane opened from
	// this one), `filter` its parsed terms and `filter_error` why they do not compile, owned.
	filter_editor: ui.Text_Field,
	filter:     Changes_Filter,
	filter_error: string,
	// The saved filters (`turns.saved_filters`) the text's tokens were resolved against, owned; the tokens
	// and the field's atoms made of them; and the saved filters an `@` being typed can complete to, as
	// slices of the library.
	filter_library: string,
	filter_tokens: [dynamic]ui.Filter_Token,
	filter_atoms: [dynamic]ui.Field_Atom,
	filter_picks: [dynamic]ui.Filter_Pick,
	filter_pick_row: int,
	// The saved filters list is open (`filter_typing`). `filter_pending` is where an `@` being typed starts:
	// the text from there to the caret is neither a token nor a term, and the list completes it; -1 when the
	// field's @ button opened the list, which then inserts at the caret.
	filter_typing: bool,
	filter_pending: int,
	// Why saving the text as a filter was refused, and what the bar names as filtering; owned.
	filter_notice: string,
	filter_on_labels: string,
	filter_savable: bool,
	// Paths picked from the file list that show despite the filter, until its text changes; owned keys.
	revealed:   map[string]struct{},
	// The turn a selection extends from, and the turn the keys move; -1 for none.
	anchor:     int,
	cursor:     int,
	dragging:   Changes_Drag,
	moving:     bool,
	// Where the pointer was at the last move of a text drag, and when the code last scrolled sideways for it.
	drag_point: [2]f32,
	edge_tick:  time.Tick,
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
	changes_filter_release(pane)
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

// Registers a pane. `agent`, `directory` and `filter` are copied.
@(require_results)
changes_pane_create :: proc(
	app: ^App,
	agent: turns.Session,
	directory: string,
	scope: ui.Changes_Scope,
	side_by_side := false,
	filter := "",
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
	_ = changes_filter_library_set(pane, app.settings.turns.saved_filters)
	_ = ui.field_set(&pane.filter_editor, filter)
	changes_filter_parse(pane)
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
changes_open :: proc(app: ^App, w: ^Window, placement := Pane_Placement.Split_Right) {
	acting := pane_link_acting_window(app, w)
	workspace := acting.workspace
	if workspace == nil || workspace.selected < 0 || workspace.selected >= len(workspace.tabs) {return}
	tab := workspace.selected
	agent: turns.Session
	directory := ""
	scope := ui.Changes_Scope.Uncommitted
	side_by_side := app.settings.turns.diff_view == .Side_By_Side
	filter := changes_default_filter(app)
	if from := changes_focused(app, acting); from != nil {
		agent, directory, scope, side_by_side = from.agent, from.directory, from.scope, from.side_by_side
		filter = changes_filter_text(from)
	} else if entry := focused_session(app, acting); entry != nil {
		agent = turn_recorder_session(app, entry.key)
		directory, _ = pane_directory(app, entry)
		if pane_agent(app, entry, nil).launch.harness != .None || len(entry.statuses) > 0 {scope = .Agent}
	} else if page := markdown_focused(app, acting); page != nil {
		directory = page.directory
	}
	if directory == "" {directory = home_directory()}
	pane := changes_pane_create(app, agent, directory, scope, side_by_side, filter)
	if pane == nil {
		notify(app, .Error, "Could not open Agent changes.")
		return
	}
	content := layout.Content{.Changes, pane.id}
	if !pane_place(app, acting, workspace, tab, window_tree(acting).focus, content, placement, true) {
		notify(app, .Error, "Could not open Agent changes.")
	}
}

// The work tree the shown diff's paths are relative to; "" until a read has answered.
@(private = "file")
changes_worktree :: proc(pane: ^Changes_Pane) -> string {
	#partial switch result in pane.model.content {
	case Result_Query:
		return result.worktree
	case Result_Plain:
		return result.worktree
	}
	return ""
}

// Edits shown file `index` in Neovim beside the pane at `node`, at its first changed line (WORK-542).
@(private = "file")
changes_edit_file :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, node: layout.Node_Id, index: int) {
	view := &pane.model.view
	worktree := changes_worktree(pane)
	if index < 0 || index >= len(view.files) || worktree == "" {return}
	file := &view.files[index]
	line := 0
	if len(file.hunks) > 0 {
		hunk := &file.hunks[0]
		line = int(hunk.new_start)
		for diff_line in hunk.lines {
			if diff_line.kind == .Added {
				line = int(diff_line.new_line)
				break
			}
		}
	}
	path := strings.concatenate({worktree, "/", file.new_path}, context.temp_allocator)
	neovim_edit_beside(app, w, node, path, max(line, 1))
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

// Whether a Middle press at the point drops the scroll anchor on an Agent changes pane: on the diff's lines,
// numbers and empty space, not on a control, a panel or list over it, a header or a note's card.
@(private, require_results)
changes_anchor_hit :: proc(app: ^App, w: ^Window, shown: layout.Pane_Rect, x, y: f32) -> bool {
	pane := changes_find(app, shown.content.id)
	if pane == nil || changes_list_open(pane) {return false}
	g := changes_geometry_of(app, w, pane, shown)
	#partial switch ui.changes_hit(g, &pane.model.view, &pane.state, x, y).part {
	case .Diff, .Line, .Gutter:
		return true
	}
	return false
}

// The pane's geometry with its diff rows laid out. The comments' part of the view and the chips' are filled
// first: they are temporary memory or borrowed from the model, and the rows, the draw and every hit test
// read them. The code text contrast follows the setting here, so a settings reload shows on the next frame.
@(require_results)
changes_geometry_of :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Changes_Pane,
	shown: layout.Pane_Rect,
) -> ui.Changes_Geometry {
	changes_comments_view(app, pane)
	changes_chips_view(pane)
	pane.model.view.minimum_contrast = f32(app.settings.turns.diff_minimum_contrast)
	pane.model.view.wrap = app.settings.turns.diff_long_lines == .Wrap
	changes_filter_view(pane)
	mono := ui.text_mono(&w.ui_text, app.family)
	g := ui.changes_geometry(pane_body_rect(w, shown), w.scale, &pane.model.view, &w.ui_text, &pane.state)
	ui.changes_layout(&pane.state, &pane.model.view, &w.ui_text, &mono, g.diff.width, w.scale)
	g.selection_bar = ui.changes_selection_place(g, &pane.model.view, &pane.state, &w.ui_text, &mono)
	return g
}

// Points the view at the model's source and worktree labels and says which chip of each is current.
@(private = "file")
changes_chips_view :: proc(pane: ^Changes_Pane) {
	model, view := &pane.model, &pane.model.view
	view.sources, view.source_current = model.sources, changes_source_current(pane)
	view.source_agent = changes_own_agent(pane)
	view.worktree_labels, view.worktree_current = model.worktree_labels, changes_worktree_current(pane)
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
	return pane.state.files_open
}

@(private = "file")
CHANGES_FILE_LIST_WIDTH :: f32(420)
@(private = "file")
CHANGES_FILE_LIST_ROWS :: 16

// The file list's choices: one per file of the result, searched by path or regular expression, the files
// the filter hides faded.
@(private = "file")
changes_dropdown_choices :: proc(pane: ^Changes_Pane) -> ui.Dropdown_Choices {
	return {
		choices = pane.model.file_labels,
		search_text = pane.model.file_paths,
		faded = pane.model.faded,
		searchable = true,
		regex_toggle = true,
		placeholder = "Search files",
		empty_text = "No matching files",
		min_width = CHANGES_FILE_LIST_WIDTH,
		rows = pane.model.file_rows,
		rows_serial = pane.model.file_serial,
		fit_content = true,
		max_rows = CHANGES_FILE_LIST_ROWS,
	}
}

// The file list hangs under the files button, right-aligned to it and inside the pane.
@(private = "file")
changes_dropdown_anchor :: proc(pane: ^Changes_Pane, g: ui.Changes_Geometry) -> ui.Dropdown_Anchor {
	// The room it may use starts just under the button, so a tall list never flips over the row.
	top := g.files_button.y + g.files_button.height - ui.SPACE_1 * g.scale
	bounds := render.Rect{g.area.x, top, g.area.width, max(0, g.area.y + g.area.height - top)}
	return {field = g.files_button, row = g.files_button, bounds = bounds, align_end = true}
}

@(private = "file")
changes_list_close :: proc(w: ^Window, pane: ^Changes_Pane) {
	if !pane.state.files_open {return}
	pane.state.files_open = false
	ui.dropdown_close(&pane.dropdown)
	w.dirty = true
}

// Closes the panel with the turn list that belongs to it.
@(private = "file")
changes_panel_close :: proc(w: ^Window, pane: ^Changes_Pane) {
	state := &pane.state
	if !state.panel_open && !state.turn_list_open {return}
	state.panel_open = false
	state.turn_list_open, state.turn_list_bar = false, {}
	w.dirty = true
}

// The pane's popovers: each is open alone, so opening one closes the rest.
@(private)
Changes_Popover :: enum {
	Panel,
	Files,
	Tools,
	Filter,
	Labels,
}

// Closes the panel with its turn list, the file list, the ⋯ menu, the filter popover and the label menu,
// except `keep`. Opening a popover keeps itself and closes the others; a new popover is a case here.
@(private)
changes_popovers_close :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, keep: Changes_Popover) {
	if keep != .Panel {changes_panel_close(w, pane)}
	if keep != .Files {changes_list_close(w, pane)}
	if keep != .Tools {changes_tools_close(w, pane)}
	if keep != .Filter {changes_filter_popover(app, w, pane, false)}
	if keep != .Labels {changes_labels_close(pane)}
}

// Opens the file list under the files button when the result has files. Opening closes the other popovers,
// and keeps the comment being written, as a list opening does.
@(private = "file")
changes_files_open :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	if pane.state.files_open || len(pane.model.file_labels) == 0 {return}
	changes_popovers_close(app, w, pane, .Files)
	changes_list_begin(app, pane)
	pane.state.files_open = true
	ui.dropdown_open(&pane.dropdown, changes_dropdown_choices(pane))
	w.dirty = true
}

// Opens or closes the panel. Opening closes the other popovers, keeps the comment being written as a list
// opening does, and reads the agents again for the chips.
@(private = "file")
changes_panel_set :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, open: bool) {
	if pane.state.panel_open == open {return}
	if !open {
		changes_panel_close(w, pane)
		return
	}
	changes_popovers_close(app, w, pane, .Panel)
	changes_list_begin(app, pane)
	_ = changes_sources_refresh(app, pane)
	pane.state.panel_open = true
	w.dirty = true
}

@(private = "file")
changes_tools_close :: proc(w: ^Window, pane: ^Changes_Pane) {
	if !pane.state.tools_open {return}
	pane.state.tools_open = false
	w.dirty = true
}

// Opens the ⋯ menu, closing the other popovers.
@(private = "file")
changes_tools_open :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	changes_popovers_close(app, w, pane, .Tools)
	changes_list_begin(app, pane)
	pane.state.tools_open = true
	w.dirty = true
}

// Runs a header-row button's action, from the button or from its row in the ⋯ menu: the layout toggle, fold
// all, or the filter popover.
@(private = "file")
changes_row_button_run :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, button: ui.Row_Button) {
	switch button {
	case .Layout:
		changes_layout_toggle(app, w, pane)
	case .Fold:
		changes_fold_all(app, w, pane)
	case .Filter:
		changes_filter_popover(app, w, pane, true)
	case .Select_Lines:
		pane.comments.select_lines = !pane.comments.select_lines
		w.dirty = true
	case .Wrap:
		value := "scroll" if app.settings.turns.diff_long_lines == .Wrap else "wrap"
		_ = settings_save_value(app, "turns.diff_long_lines", value, "Could not save the long line setting.")
	}
}

// Runs row `row` of the ⋯ menu, which closes with it.
@(private = "file")
changes_tools_row :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, row: int) {
	changes_tools_close(w, pane)
	changes_row_button_run(app, w, pane, ui.Row_Button(row))
}

// What the open list's highlighted choice is, so a new result can find it again: a file's path. In
// temporary memory.
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
	return choice < len(model.diff.files) ? changes_file_path(model.diff.files[choice]) : ""
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

// Applies the highlighted choice of the open list: shows that file.
@(private = "file")
changes_list_choose :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, index: int) {
	if index < 0 {return}
	changes_file_pick(app, w, pane, index)
}

// Shows file `choice` of the result at the top of the diff: picked past the filter when it hides the
// file, unfolded, and scrolled to its header.
changes_file_pick :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, choice: int) {
	model, view := &pane.model, &pane.model.view
	if choice < 0 || choice >= len(model.diff.files) {return}
	if choice < len(model.faded) && model.faded[choice] {
		changes_filter_reveal(pane, changes_file_path(model.diff.files[choice]))
	}
	index := -1
	for at, i in model.file_index {
		if at == choice {
			index = i
			break
		}
	}
	if index < 0 {return}
	if index < len(view.collapsed) && view.collapsed[index] {changes_model_fold(model, index)}
	changes_scroll_to_file(app, w, pane, index)
}

// Lays the pane out again and scrolls the diff so shown file `index` has its header at the top. Laid out
// first, so the file's top counts a body just folded or unfolded; then kept within what can scroll.
@(private = "file")
changes_scroll_to_file :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, index: int) {
	w.dirty = true
	shown, found := changes_pane_rect(w, pane.id)
	if !found {return}
	g := changes_geometry_of(app, w, pane, shown)
	pane.state.diff_scroll = ui.changes_diff_file_top(&pane.state, &pane.model.view, index)
	_ = ui.changes_scroll_diff(&pane.state, g, 0)
}

// Collapses every file while any shown one is expanded, else expands them all; the file at the top of the
// diff stays there.
changes_fold_all :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	view := &pane.model.view
	top := -1
	if shown, found := changes_pane_rect(w, pane.id); found {
		_ = changes_geometry_of(app, w, pane, shown)
		top = ui.changes_top_file(&pane.state, view)
	}
	changes_model_fold_all(&pane.model, view.any_expanded)
	w.dirty = true
	if top >= 0 {changes_scroll_to_file(app, w, pane, top)}
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

// Opens or closes the diff filter's popover. Opening closes the other popovers and keeps the comment being
// written, as a list opening does; closing keeps the text, which turns an `@` still being typed into a token.
@(private)
changes_filter_popover :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, open: bool) {
	if pane.state.filter_open == open {return}
	if open {
		changes_popovers_close(app, w, pane, .Filter)
		changes_list_begin(app, pane)
	} else {
		_ = ui.field_release(&pane.filter_editor)
		changes_filter_typing_end(app, w, pane)
	}
	pane.state.filter_open = open
	w.dirty = true
}

// The filter text changed in window `w`: the view shows what the new filter lets through, and the file
// that was at the top stays there while it still shows.
changes_filter_edited :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	view := &pane.model.view
	shown, found := changes_pane_rect(w, pane.id)
	top_path := ""
	if found {
		_ = changes_geometry_of(app, w, pane, shown)
		if top := ui.changes_top_file(&pane.state, view); top >= 0 && top < len(view.files) {
			top_path = strings.clone(changes_file_path(view.files[top]), context.temp_allocator)
		}
	}
	changes_filter_ids_resolve(pane)
	changes_filter_changed(pane)
	if found {
		g := changes_geometry_of(app, w, pane, shown)
		for file, i in view.files {
			if top_path == "" || changes_file_path(file) != top_path {continue}
			pane.state.diff_scroll = ui.changes_diff_file_top(&pane.state, view, i)
			break
		}
		_ = ui.changes_scroll_diff(&pane.state, g, 0)
	}
	layout_state_touch(app)
	w.dirty = true
}

// Empties the filter, tokens included, so every file shows.
changes_filter_clear :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	if changes_filter_text(pane) == "" {return}
	_ = ui.field_set(&pane.filter_editor, "")
	pane.filter_typing = false
	changes_filter_edited(app, w, pane)
}

// Keys while the filter popover is open. While the saved filters list is open Up and Down move through it,
// Enter or Tab inserts the row the keys are on, and Escape only closes the list. Otherwise Enter and Escape
// close the popover and keep the text, Down in an empty field opens the list, Ctrl+S saves the field's terms
// as a saved filter, Space toggles a token that is the selection, and the field takes its editing keys.
// Chords the field has no use for go on to the shortcuts.
@(private = "file")
changes_filter_key :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Changes_Pane,
	logical, e: input.Key_Event,
) -> bool {
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	#partial switch logical.key {
	case .Enter, .Numpad_Enter, .Tab:
		if modifiers == {} && pane.filter_typing {
			changes_filter_pick_choose(app, w, pane, pane.filter_pick_row)
			return true
		}
		if modifiers == {} && logical.key != .Tab {
			changes_filter_popover(app, w, pane, false)
			return true
		}
	case .Escape:
		if modifiers == {} {
			if pane.filter_typing {
				changes_filter_list_cancel(app, w, pane)
			} else {
				changes_filter_popover(app, w, pane, false)
			}
			return true
		}
	case .Arrow_Up, .Arrow_Down:
		if modifiers == {} && pane.filter_typing {
			step := logical.key == .Arrow_Down ? 1 : -1
			pane.filter_pick_row = clamp(pane.filter_pick_row + step, 0, max(0, len(pane.filter_picks) - 1))
			changes_filter_view(pane)
			w.dirty = true
			return true
		}
		if modifiers == {} && logical.key == .Arrow_Down && changes_filter_open_list_by_key(app, w, pane) {
			return true
		}
	case .S:
		if modifiers == {.Control} {
			changes_filter_save(app, w, pane)
			return true
		}
	}
	if modifiers == {} && e.text == " " && changes_filter_toggle_selected(app, w, pane) {return true}
	if e.text != "" && modifiers - {.Shift} == {} {
		changes_filter_type(app, w, pane, e.text)
		return true
	}
	if changes_filter_key_edit(app, w, pane, logical) {return true}
	chord := clipboard_chord(logical) != .None
	return chord || modifiers - {.Shift} == {} || e.text != ""
}

// Typed or pasted text goes to the filter field or the open list's search, else to the comment being
// written.
changes_text :: proc(app: ^App, w: ^Window, text: string) -> bool {
	pane := changes_focused(app, w)
	if pane == nil {return false}
	if pane.state.filter_open {
		changes_filter_type(app, w, pane, text)
		w.dirty = true
		return true
	}
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

@(private)
changes_diff_scroll :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, shown: layout.Pane_Rect, delta: int) {
	g := changes_geometry_of(app, w, pane, shown)
	if ui.changes_scroll_diff(&pane.state, g, delta) {w.dirty = true}
}

// Pages the strip by as many bars as it shows, toward older turns (`step` -1) or newer ones (+1), as
// the wheel moves it; the selection stays. The new page's edge bar sits next to the old page's edge: a
// newer page starts right after it, and an older page, which may show fewer bars once a newer marker
// takes room, is moved to end right before it.
@(private = "file")
changes_strip_page :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Changes_Pane,
	shown: layout.Pane_Rect,
	step: int,
) {
	view := &pane.model.view
	g := changes_geometry_of(app, w, pane, shown)
	from, _ := ui.changes_strip_hidden(g, &pane.state, view)
	if !ui.changes_scroll_strip(&pane.state, g, view, step * max(1, g.strip_bars)) {return}
	w.dirty = true
	if step > 0 {return}
	g = changes_geometry_of(app, w, pane, shown)
	at, _ := ui.changes_strip_hidden(g, &pane.state, view)
	if target := max(0, from - g.strip_bars); target != at {
		_ = ui.changes_scroll_strip(&pane.state, g, view, target - at)
	}
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
		if changes_edge_scroll(app, w, pane, shown, frame) {pane.moving = true}
		changed = changed || pane.moving
	}
	return changed
}

// How long a text drag waits between sideways steps while its pointer is out of the cell.
@(private = "file")
CHANGES_EDGE_STEP :: 50 * time.Millisecond

// While a text selection is dragged, with the pointer left or right of the text it started in, scrolls the
// code a few columns each CHANGES_EDGE_STEP, more the farther out the pointer is, and extends the selection
// to the text now under the pointer's edge. True while the pointer is out, so frames keep coming.
@(private = "file")
changes_edge_scroll :: proc(
	app: ^App, w: ^Window, pane: ^Changes_Pane, shown: layout.Pane_Rect, frame: ui.Frame_Time,
) -> bool {
	c := &pane.comments
	if !c.dragging || !c.by_text || c.drag_cell.width <= 0 {return false}
	g := changes_geometry_of(app, w, pane, shown)
	view := &pane.model.view
	mono := ui.text_mono(&w.ui_text, app.family)
	_, column, found := ui.changes_line_code(g, view, &pane.state, &mono, c.drag_file, c.anchor, c.drag_cell.x)
	if !found {return false}
	right := c.drag_cell.x + c.drag_cell.width
	x := pane.drag_point.x
	over := x < column.text_x ? x - column.text_x : max(0, x - right)
	if over == 0 {
		pane.edge_tick = {}
		return false
	}
	if pane.edge_tick != {} && time.tick_diff(pane.edge_tick, frame.display) < CHANGES_EDGE_STEP {return true}
	pane.edge_tick = frame.display
	columns := 1 + min(7, int(abs(over) / (2 * ui.text_width(&mono, "0"))))
	if over < 0 {columns = -columns}
	if !ui.changes_scroll_columns(&pane.state, g, view, columns) {return false}
	reach := clamp(x, c.drag_cell.x, right - 1)
	hit := ui.changes_hit(g, view, &pane.state, reach, pane.drag_point.y)
	_ = changes_comments_drag(app, w, pane, hit, changes_text_at(app, w, pane, g, hit, reach, pane.drag_point.y))
	w.dirty = true
	return true
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

// The pane's row, diff and overview strip, or its notice, inside the card. `scrollable` is always false:
// the overview strip scrolls the diff, so no pane scrollbar belongs beside it.
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
	if result != .Ok {return false, result}
	if changes_list_open(pane) {
		result = ui.dropdown_draw(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), &w.list, &w.ui_text,
			app.theme, w.pointer, w.scale,
		)
	}
	return false, result
}

changes_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	pane_header_cancel(w)
	// Alt alone changes how a press picks, so its press and its release redraw the rows' hover. Alt is the one
	// key whose release the pane sees: every other key's press is suppressed, which drops its release.
	alt_key := e.key == .Alt_Left || e.key == .Alt_Right
	if !alt_key {key_suppress(w, e)}
	if pane := changes_focused(app, w); pane != nil && pane.comments.alt != (.Alt in e.modifiers) {
		pane.comments.alt, w.dirty = .Alt in e.modifiers, true
	}
	key, consumed := content_key_prelude(app, w, e, true)
	if consumed {return}
	if !e.pressed {return}
	pane := changes_focused(app, w)
	shown: layout.Pane_Rect
	found := false
	if pane != nil {shown, found = changes_pane_rect(w, pane.id)}
	toggle := (e.modifiers & {.Control, .Shift, .Alt, .Super}) == {.Control}
	if pane != nil && found && key.logical.key == .K && toggle {
		changes_panel_set(app, w, pane, !pane.state.panel_open)
		return
	}
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
	if pane != nil && found && pane.state.filter_open && changes_filter_key(app, w, pane, key.logical, e) {
		return
	}
	if pane != nil && found && pane.state.turn_list_open && key.logical.key == .Escape {
		changes_turn_list_set(w, pane, changes_geometry_of(app, w, pane, shown), false)
		return
	}
	if pane != nil && found && pane.state.tools_open && key.logical.key == .Escape {
		changes_tools_close(w, pane)
		return
	}
	if pane != nil && found && pane.state.panel_open && key.logical.key == .Escape {
		changes_panel_close(w, pane)
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
	// A page leaves out the row a pinned header covers, so nothing slides under it unseen.
	page := max(1, int(g.diff.height) - pane.state.rows.header)
	for shortcut, i in CHANGES_STEP_KEYS {
		if key.logical.key != shortcut.key || !turn_scope {continue}
		// Older turns sit to the left in the strip; the table lists the older key first.
		changes_move(app, pane, g, i == 0 ? 1 : -1, extend)
		return
	}
	#partial switch key.logical.key {
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

// How many text columns one wheel row scrolls the code sideways.
@(private = "file")
CHANGES_WHEEL_COLUMNS :: 2

// Rows are the scrolled lines, positive toward the top, as the mouse wheel reports them, and `columns` the
// scrolled sideways, positive toward the right, as a sideways wheel reports them. Shift and the wheel scroll
// the code sideways too. Over the open panel only the strip scrolls; the open file list takes the wheel.
@(require_results)
changes_wheel :: proc(
	app: ^App, w: ^Window, x, y: f32, rows, columns: int, modifiers: input.Modifiers,
) -> bool {
	pane, shown := changes_under_pointer(app, w, x, y)
	if shown.content.kind != .Changes {return false}
	if pane == nil {return true}
	g := changes_geometry_of(app, w, pane, shown)
	view := &pane.model.view
	mono := ui.text_mono(&w.ui_text, app.family)
	delta := -rows * int(mono.line_height)
	switch {
	case pane.state.turn_list_open && render.rect_contains(g.turn_list, x, y):
		if ui.changes_scroll_turn_list(&pane.state, g, view, delta) {w.dirty = true}
	case pane.state.panel_open && render.rect_contains(g.panel, x, y):
		// Scrolling up shows older bars, which sit to the left.
		if render.rect_contains(g.strip, x, y) && ui.changes_scroll_strip(&pane.state, g, view, -rows) {
			w.dirty = true
		}
	case pane.comments.menu && render.rect_contains(g.selection_bar.menu, x, y):
		changes_label_menu_step(app, pane, -rows)
		w.dirty = true
	case changes_list_open(pane):
		_ = ui.dropdown_wheel(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), rows, w.scale,
		)
		w.dirty = true
	case:
		// Shift turns the wheel sideways, as a sideways wheel does: up goes left.
		sideways := .Shift in modifiers ? columns - rows : columns
		if sideways != 0 {
			if ui.changes_scroll_columns(&pane.state, g, view, sideways * CHANGES_WHEEL_COLUMNS) {w.dirty = true}
			break
		}
		// Over the note editor the wheel scrolls its text while it has more to show; at an end, or when the
		// text fits, the diff takes it.
		if box, visible := ui.changes_editor_box(g, view, &pane.state, &w.ui_text);
		   visible && render.rect_contains(box.rect, x, y) && ui.text_area_scroll(box, f32(delta)) {
			w.dirty = true
			break
		}
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
}

@(private = "file", require_results)
changes_cursor :: proc(hit: ui.Changes_Hit, line_mode: bool) -> platform.Cursor_Shape {
	if _, button := ui.changes_row_button_of(hit.part); button {return .Hand}
	#partial switch hit.part {
	case .Hooks, .Notice_Button, .File_Header, .Strip_Bar, .Step_Back, .Step_Forward, .Range_Label,
	     .Hunk_Select, .Comment_Edit, .Comment_Remove, .Editor_Untag, .Editor_Bold, .Editor_Code, .Editor_Block,
	     .Editor_Suggest, .Editor_Cancel, .Editor_Save, .Send, .Copy, .Discard, .Filter_Clear,
	     .Filter_Bar_Clear, .Sticky_Header, .Strip_Older, .Strip_Newer, .Summary, .Files_Button, .Tools_Button,
	     .Source_Chip, .Worktree_Chip, .Gutter, .Toolbar_Delete, .Toolbar_Comment, .Toolbar_Label, .Label_Row,
	     .Label_Edit, .Filter_At, .Filter_Save, .Filter_Manage:
		return .Hand
	case .Turn_List_Row, .Tools_Row:
		if hit.index >= 0 {return .Hand}
	case .Filter_Pick:
		return .Hand
	case .Filter_Field:
		if hit.index >= 0 {return .Text}
	case .Comment_Editor:
		return .Text
	case .Split_Divider:
		return .Resize_Horizontal
	case .Line:
		// The code text selects characters, unless a press picks whole lines.
		return line_mode ? .Arrow : .Text
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

// Where a press or a drag at `x` lands on the code of `hit`'s line, and which half of a side-by-side row that
// is; nothing for any other hit. The numbers' byte is the start of the line's text.
@(private = "file", require_results)
changes_text_at :: proc(
	app: ^App, w: ^Window, pane: ^Changes_Pane, g: ui.Changes_Geometry, hit: ui.Changes_Hit, x, y: f32,
) -> Changes_Text_Point {
	if hit.part != .Line && hit.part != .Gutter {return {}}
	mono := ui.text_mono(&w.ui_text, app.family)
	offset, cell, _ := ui.changes_text_point(g, &pane.model.view, &pane.state, &mono, hit.index, hit.line, x, y)
	return {offset, cell, ui.changes_cell_half(g, &pane.state, cell)}
}

// Follow the grabbed divider even when the pointer leaves the diff or crosses another pane.
changes_divider_held :: proc(
	app: ^App, w: ^Window, under: Pointer_Target, e: input.Mouse_Move_Event,
) -> Pointer_Held {
	grab, active := w.changes_divider.?
	if !active || pointer_modal(under) {return .Free}
	pane := changes_find(app, grab.pane)
	shown, visible := changes_pane_rect(w, grab.pane)
	if .Left not_in e.buttons || pane == nil || !visible || !pane.side_by_side {
		changes_cancel(app, w)
		return .Ended
	}
	g := changes_geometry_of(app, w, pane, shown)
	if ui.changes_divider_move(&pane.state, g, f32(e.x) - grab.offset) {
		w.changes_divider_click = {}
		w.dirty = true
	}
	pointer_set(app, w, .Resize_Horizontal)
	return .Taken
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
	if pane.state.h_bar.active {
		bar, visible := ui.changes_h_scrollbar(g, view, &pane.state)
		if visible && .Left in e.buttons {
			target := ui.scrollbar_drag(pane.state.h_bar, bar, x)
			_ = ui.changes_scroll_columns(&pane.state, g, view, target - pane.state.h_scroll)
		} else {
			pane.state.h_bar = {}
		}
		w.dirty = true
		return
	}
	if pane.state.overview_drag.active {
		if .Left in e.buttons {
			pane.state.diff_scroll = ui.changes_overview_drag(&pane.state, g, y)
			_ = ui.changes_scroll_diff(&pane.state, g, 0)
		} else {
			pane.state.overview_drag = {}
		}
		w.dirty = true
		pointer_set(app, w, .Arrow)
		return
	}
	// The open file list takes the pointer.
	if changes_list_open(pane) {
		if pane.state.hover != {} {pane.state.hover, w.dirty = {}, true}
		if ui.dropdown_hover(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), x, y, w.scale,
		) {w.dirty = true}
		shape := ui.dropdown_pointer(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), x, y, w.scale,
		)
		pointer_set(app, w, shape)
		return
	}
	if pane.filter_editor.dragging {
		if .Left in e.buttons {
			changes_filter_point(app, w, pane, g, x, false, false)
		} else {
			_ = ui.field_release(&pane.filter_editor)
		}
		pointer_set(app, w, .Text)
		return
	}
	// A held press in the note editor's text extends its selection, wherever the pointer is.
	if pane.comments.area.dragging {
		if .Left in e.buttons {
			if box, visible := ui.changes_editor_box(g, view, &pane.state, &w.ui_text); visible {
				_ = ui.text_area_pointer(box, x, y, false, false)
				w.dirty = true
			}
		} else {
			_ = ui.text_area_release(&pane.comments.area)
		}
		pointer_set(app, w, .Text)
		return
	}
	if .Left not_in e.buttons {pane.dragging = .None}
	if alt := .Alt in e.modifiers; pane.comments.alt != alt {pane.comments.alt, w.dirty = alt, true}
	// A text selection stays within the cell it started in, so its drag reads the pointer clamped to that
	// cell.
	c := &pane.comments
	reach := x
	if c.dragging && c.by_text && .Left in e.buttons && c.drag_cell.width > 0 {
		reach = clamp(x, c.drag_cell.x, c.drag_cell.x + c.drag_cell.width - 1)
		// A text drag past the cell's edge scrolls the code on, a step a frame until the pointer is back.
		pane.drag_point, pane.moving = {x, y}, true
		w.dirty = true
	}
	hit := ui.changes_hit(g, view, &pane.state, reach, y)
	shape := changes_cursor(hit, view.select_lines || view.alt)
	if hit.part == .Filter_Field && hit.index >= 0 {
		if box, shown := ui.changes_filter_box(g, view, &w.ui_text); shown {
			if token, _ := ui.filter_field_token_at(box, pane.filter_tokens[:], x); token >= 0 {shape = .Hand}
		}
	}
	if hit.part == .Filter_Pick && pane.filter_pick_row != hit.index {
		pane.filter_pick_row, w.dirty = hit.index, true
		changes_filter_view(pane)
	}
	if pane.dragging != .None {
		changes_drag_turns(app, pane, g, hit)
	} else if c.dragging && .Left in e.buttons {
		if changes_comments_drag(app, w, pane, hit, changes_text_at(app, w, pane, g, hit, reach, y)) {
			w.dirty = true
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
	last_click := w.changes_divider_click
	w.changes_divider_click = {}
	w.dirty = true
	g := changes_geometry_of(app, w, pane, shown)
	view, state := &pane.model.view, &pane.state
	in_panel := state.panel_open && render.rect_contains(g.panel, x, y)
	// The open file list takes the press, and a press outside it only closes it.
	if changes_list_open(pane) {
		choices, anchor := changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g)
		outcome := ui.dropdown_press(&pane.dropdown, choices, anchor, &w.ui_text, x, y, false, w.scale)
		if side := ui.dropdown_take_track(&pane.dropdown); side != .None {
			scroll_hold_begin(app, w, .Changes_Choices, shown.content, x, y, side)
		}
		switch outcome {
		case .Chosen:
			changes_list_choose(app, w, pane, ui.dropdown_highlighted(&pane.dropdown, choices))
			changes_list_close(w, pane)
		case .None:
			changes_list_close(w, pane)
		case .Changed, .Closed, .Font_Filter:
		}
		return
	}
	if state.turn_list_open {
		if bar, visible := ui.changes_turn_list_scrollbar(state, g, view);
		   visible && ui.scrollbar_contains(bar, x, y) {
			side := ui.scrollbar_side(bar, y)
			state.turn_list_scroll = ui.scrollbar_press(&state.turn_list_bar, bar, y)
			if !state.turn_list_bar.active {scroll_hold_begin(app, w, .Changes_Turn_List, shown.content, x, y, side)}
			return
		}
	}
	hit := ui.changes_hit(g, view, state, x, y)
	state.press = hit
	extend := .Shift in e.modifiers
	// A press anywhere but on the toolbar and its menu closes the menu.
	if !changes_selection_part(hit.part) {changes_labels_close(pane)}
	// While the filter popover is open, a press outside it, its button's own included, only closes it.
	if state.filter_open {
		#partial switch hit.part {
		case .Filter_Field:
			if hit.index >= 0 {changes_filter_point(app, w, pane, g, x, true, extend, e.time_ns)}
		case .Filter_Clear:
			changes_filter_clear(app, w, pane)
		case .Filter_Pick:
			changes_filter_pick_choose(app, w, pane, hit.index)
		case .Filter_At:
			changes_filter_list_toggle(app, w, pane)
		case .Filter_Save:
			changes_filter_save(app, w, pane)
		case .Filter_Manage:
			changes_filter_manage(app, w, pane)
		case:
			changes_filter_popover(app, w, pane, false)
		}
		return
	}
	// The ⋯ menu answers on its rows; a press outside it only closes it.
	if state.tools_open {
		if hit.part == .Tools_Row {
			if hit.index >= 0 {changes_tools_row(app, w, pane, hit.index)}
		} else if !render.rect_contains(g.tools_menu, x, y) {
			changes_tools_close(w, pane)
		}
		return
	}
	// A press outside the open turn list only closes it, as a press outside a dropdown does.
	if state.turn_list_open && hit.part != .Turn_List_Row && hit.part != .Range_Label {
		changes_turn_list_set(w, pane, g, false)
		return
	}
	// A press outside the open panel, its own summary included, only closes it.
	if state.panel_open && !in_panel && hit.part != .Turn_List_Row {
		changes_panel_close(w, pane)
		return
	}
	#partial switch hit.part {
	case .Summary:
		changes_panel_set(app, w, pane, true)
	case .Files_Button:
		changes_files_open(app, w, pane)
	case .Tools_Button:
		changes_tools_open(app, w, pane)
	case .Source_Chip:
		changes_source_pick(app, pane, hit.index)
	case .Worktree_Chip:
		changes_worktree_pick(app, pane, hit.index)
	case .Split_Divider:
		if click_run_count(last_click, pane.id, x, y, e.time_ns) == 2 {
			state.split = 0
			pointer_set(app, w, .Resize_Horizontal)
			return
		}
		w.changes_divider_click = Click_Run{pane.id, x, y, e.time_ns, 1, 0}
		divider := ui.changes_divider_rect(g, view, state)
		w.changes_divider = Changes_Divider_Drag{pane.id, x - divider.x}
		pointer_set(app, w, .Resize_Horizontal)
	case .H_Scroll:
		if bar, visible := ui.changes_h_scrollbar(g, view, state); visible {
			side := ui.scrollbar_side(bar, x)
			target := ui.scrollbar_press(&state.h_bar, bar, x)
			_ = ui.changes_scroll_columns(state, g, view, target - state.h_scroll)
			if !state.h_bar.active {scroll_hold_begin(app, w, .Changes_H_Scroll, shown.content, x, y, side)}
		}
	case .Overview:
		side: ui.Scroll_Side
		if bar, visible := ui.changes_overview_bar(state, g); visible {side = ui.scrollbar_side(bar, y)}
		state.diff_scroll = ui.changes_overview_press(state, g, y)
		_ = ui.changes_scroll_diff(state, g, 0)
		if !state.overview_drag.active {scroll_hold_begin(app, w, .Changes_Overview, shown.content, x, y, side)}
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
	case .Strip_Older:
		changes_strip_page(app, w, pane, shown, -1)
	case .Strip_Newer:
		changes_strip_page(app, w, pane, shown, 1)
	case .Range_Label:
		changes_turn_list_set(w, pane, g, !state.turn_list_open)
	case .Turn_List_Row:
		if hit.index >= 0 {
			changes_select(app, pane, g, hit.index, extend)
			pane.dragging = .Turn_List
		}
	case .File_Header:
		changes_model_fold(&pane.model, hit.index)
	case .File_Edit:
		changes_edit_file(app, w, pane, shown.node, hit.index)
	case .Sticky_Header:
		// The pinned header's file goes to the top, so what its press folds stays under the pointer: the
		// file's own header, which takes over the pinned one's hover and press.
		changes_model_fold(&pane.model, hit.index)
		changes_scroll_to_file(app, w, pane, hit.index)
		header := ui.changes_hit(changes_geometry_of(app, w, pane, shown), view, state, x, y)
		if header == (ui.Changes_Hit{.File_Header, hit.index, 0}) {
			state.hover, state.press, state.lit = header, header, header
		}
	case .Filter_Bar_Clear:
		changes_filter_clear(app, w, pane)
	case .Line, .Gutter, .Hunk_Select, .Comment_Card, .Comment_Edit, .Comment_Remove, .Comment_Editor,
	     .Editor_Untag, .Editor_Bold, .Editor_Code, .Editor_Block, .Editor_Suggest, .Editor_Cancel,
	     .Editor_Save, .Send, .Copy, .Discard, .Toolbar, .Toolbar_Delete, .Toolbar_Comment, .Toolbar_Label,
	     .Label_Menu, .Label_Row, .Label_Edit:
		_ = changes_comments_press(app, w, pane, hit, e, changes_text_at(app, w, pane, g, hit, x, y))
	case:
		if button, ok := ui.changes_row_button_of(hit.part); ok {changes_row_button_run(app, w, pane, button)}
	}
}

changes_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left {return false}
	cleared := false
	if grab, active := w.changes_divider.?; active {
		w.changes_divider = nil
		if pane := changes_find(app, grab.pane); pane != nil {
			pane.state.press, pane.state.hover = {}, {}
		}
		cleared = true
	}
	for shown in w.panes {
		if shown.content.kind != .Changes {continue}
		pane := changes_find(app, shown.content.id)
		if pane == nil {continue}
		if pane.state.turn_list_bar.active {pane.state.turn_list_bar, cleared = {}, true}
		if pane.state.overview_drag.active {pane.state.overview_drag, cleared = {}, true}
		if pane.state.h_bar.active {pane.state.h_bar, cleared = {}, true}
		if pane.state.press != {} {pane.state.press, cleared = {}, true}
		if pane.dragging != .None {pane.dragging, cleared = .None, true}
		if ui.field_release(&pane.filter_editor) {cleared = true}
		if pane.comments.dragging {cleared = true}
		changes_comments_release(app, w, pane)
	}
	if cleared {w.dirty = true}
	return cleared
}

// Ends whatever the pointer holds on an Agent changes pane: a press, a drag or the overview strip.
changes_cancel :: proc(app: ^App, w: ^Window) {
	w.changes_divider_click = {}
	_ = changes_release(app, w, {button = .Left})
}

// One page of a held track press on an Agent changes pane's file list, turn list or overview strip,
// toward (x, y). `shown` is false once the pane, or the list the press began on, is gone.
changes_scroll_hold_page :: proc(
	app: ^App,
	w: ^Window,
	hold: Scroll_Hold,
) -> (
	result: ui.Scroll_Page,
	shown: bool,
) {
	pane := changes_find(app, hold.content.id)
	rect, found := changes_pane_rect(w, hold.content.id)
	if pane == nil || !found {return}
	g := changes_geometry_of(app, w, pane, rect)
	x, y := hold.pointer.x, hold.pointer.y
	switch hold.bar {
	case .Changes_Choices:
		if !changes_list_open(pane) {return}
		result = ui.dropdown_page(
			&pane.dropdown, changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g), x, y, w.scale,
			hold.side,
		)
	case .Changes_Turn_List:
		if !pane.state.turn_list_open {return}
		result = ui.changes_turn_list_page(&pane.state, g, &pane.model.view, x, y, hold.side)
	case .Changes_Overview:
		result = ui.changes_overview_page(&pane.state, g, x, y, hold.side)
		if result == .Paged {_ = ui.changes_scroll_diff(&pane.state, g, 0)}
	case .Changes_H_Scroll:
		result = ui.changes_h_page(&pane.state, g, &pane.model.view, x, y, hold.side)
	case .None, .Pane, .Rail, .Palette_Results, .Palette_Choices:
		return
	case .Settings_Page, .Settings_Strip, .Settings_Choices:
		return
	}
	return result, true
}

// The control a tooltip describes: what a press would reach, as changes_press finds it, or a disabled
// button, whose tooltip still says what it does. `listed` while the file list is open, which then
// takes every point; while the filter popover, the ⋯ menu or the turn list is
// open, a point outside it only closes it, so it names nothing.
@(private = "file")
changes_tooltip_hit :: proc(
	app: ^App,
	w: ^Window,
	x, y: f32,
) -> (
	pane: ^Changes_Pane,
	hit: ui.Changes_Hit,
	g: ui.Changes_Geometry,
	listed: bool,
) {
	shown: layout.Pane_Rect
	pane, shown = changes_under_pointer(app, w, x, y)
	if pane == nil {return}
	g = changes_geometry_of(app, w, pane, shown)
	state := &pane.state
	in_panel := state.panel_open && render.rect_contains(g.panel, x, y)
	if changes_list_open(pane) {return pane, {}, g, true}
	if state.filter_open && !render.rect_contains(g.filter_popover, x, y) {return}
	if state.tools_open && !render.rect_contains(g.tools_menu, x, y) {return}
	if state.turn_list_open && !render.rect_contains(g.turn_list, x, y) &&
	   !render.rect_contains(g.range_label, x, y) {
		return
	}
	hit = ui.changes_hit(g, &pane.model.view, state, x, y)
	if hit.part != .None {return}
	switch {
	case in_panel && render.rect_contains(g.step_back, x, y):
		hit.part = .Step_Back
	case in_panel && render.rect_contains(g.step_forward, x, y):
		hit.part = .Step_Forward
	case render.rect_contains(g.files_button, x, y):
		hit.part = .Files_Button
	}
	if button, ok := ui.changes_row_button_at(g, x, y); ok {
		parts := ui.CHANGES_ROW_BUTTON_PARTS
		hit.part = parts[button]
	}
	return
}

// Whether the point is on the open file list's regular expression toggle.
@(private = "file", require_results)
changes_on_regex_toggle :: proc(w: ^Window, pane: ^Changes_Pane, g: ui.Changes_Geometry, x, y: f32) -> bool {
	if !pane.state.files_open {return false}
	choices, anchor := changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g)
	return render.rect_contains(ui.dropdown_regex_rect(&pane.dropdown, choices, anchor, w.scale), x, y)
}

// What the control under the point does; the turns name themselves.
changes_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	pane, hit, g, listed := changes_tooltip_hit(app, w, x, y)
	if pane == nil {return ""}
	if listed {
		if changes_on_regex_toggle(w, pane, g, x, y) {return "Use regular expression"}
		// A row whose folder is shortened names its full path.
		choices, anchor := changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g)
		source, cut := ui.dropdown_row_cut(&pane.dropdown, choices, anchor, &w.ui_text, x, y, w.scale)
		return cut ? changes_list_identity(pane, source) : ""
	}
	view := &pane.model.view
	if button, ok := ui.changes_row_button_of(hit.part); ok {
		return ui.changes_row_button_entry(view, button).tooltip
	}
	#partial switch hit.part {
	case .Summary:
		return "Source and turns"
	case .Files_Button:
		return "Files in this diff"
	case .File_Edit:
		return "Edit in Neovim"
	case .Tools_Button:
		return "Layout, fold and filter"
	case .Source_Chip:
		if hit.index >= 0 && hit.index < len(view.sources) {return view.sources[hit.index]}
	case .Worktree_Chip:
		if hit.index >= 0 && hit.index < len(view.worktree_labels) {return view.worktree_labels[hit.index]}
	case .Overview:
		return "Overview: click or drag to scroll"
	case .Hooks:
		return "Install hooks so turns begin before the first edit"
	case .Step_Back:
		return "Older turn"
	case .Step_Forward:
		return "Newer turn"
	case .Strip_Older, .Strip_Newer:
		older, newer := ui.changes_strip_hidden(g, &pane.state, view)
		count, side := older, "older"
		if hit.part == .Strip_Newer {count, side = newer, "newer"}
		return fmt.tprintf("%d %s turn%s", count, side, count == 1 ? "" : "s")
	case .Range_Label:
		return "Choose turns"
	case .Strip_Bar:
		return ui.changes_turn_tooltip(view, hit.index, context.temp_allocator)
	case .Turn_List_Row:
		if hit.index >= 0 {return ui.changes_turn_tooltip(view, hit.index, context.temp_allocator)}
	case .Filter_Clear, .Filter_Bar_Clear:
		return "Clear the filter"
	case .File_Header, .Sticky_Header:
		folded := hit.index >= 0 && hit.index < len(view.collapsed) && view.collapsed[hit.index]
		return folded ? "Expand file" : "Collapse file"
	case .Filter_At:
		return "Saved filters"
	case .Hunk_Select:
		return "Select this hunk"
	case .Toolbar_Delete:
		return "Ask the agent to delete this"
	case .Toolbar_Comment:
		return "Comment"
	case .Toolbar_Label:
		return "Quick label"
	case .Label_Row:
		label, _ := ui.changes_label_at(view.quick_labels, hit.index)
		return label.instruction
	case .Comment_Edit:
		return "Edit"
	case .Comment_Remove:
		return "Remove"
	case .Editor_Untag:
		return "Make it a plain comment"
	case .Editor_Bold:
		return "Bold"
	case .Editor_Code:
		return "Inline code"
	case .Editor_Block:
		return "Code block"
	case .Editor_Suggest:
		if view.span.old {return "A suggestion replaces lines of the new file"}
		return "Insert the selected lines as an editable replacement"
	case .Send:
		if !view.send.can_send {return view.send.reason}
		if view.send.target == "" {return "Send the notes and submit"}
		parts := []string{"Send the notes to ", view.send.target, " and submit"}
		return strings.concatenate(parts, context.temp_allocator)
	case .Copy:
		return "Copy the notes"
	case .Discard:
		return "Discard the notes"
	}
	return ""
}

// The keys the step buttons answer to, older then newer; changes_key reads them and so do the tooltips.
@(private = "file", rodata)
CHANGES_STEP_KEYS := [2]commands.Shortcut{{.Arrow_Left, {}}, {.Arrow_Right, {}}}

// The key that toggles the panel, which the row's summary and chevron button name.
@(private = "file", rodata)
CHANGES_PANEL_KEY := commands.Shortcut{.K, {.Control}}

// The fixed keys the step buttons and the file list's regular expression toggle answer to; the toggle's is
// the find bar's, which the list shares.
changes_shortcut :: proc(app: ^App, w: ^Window, x, y: f32) -> Tooltip_Shortcut {
	pane, hit, g, listed := changes_tooltip_hit(app, w, x, y)
	if pane == nil {return nil}
	if listed {
		if !changes_on_regex_toggle(w, pane, g, x, y) {return nil}
		return ui.FIND_KEYS[.Regex_Toggle]
	}
	#partial switch hit.part {
	case .Step_Back:
		return CHANGES_STEP_KEYS[0]
	case .Step_Forward:
		return CHANGES_STEP_KEYS[1]
	case .Summary:
		return CHANGES_PANEL_KEY
	case .Toolbar_Delete:
		return commands.Shortcut{.Delete, {}}
	case .Toolbar_Comment:
		return "type to start"
	case .Toolbar_Label:
		return "Alt+1–9"
	case .Editor_Bold:
		return commands.Shortcut{.B, {.Control}}
	}
	return nil
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
	changes_token_state_name :: proc(state: ui.Filter_Token_State) -> string {
		switch state {
		case .Known:
			return "known"
		case .Unknown:
			return "unknown"
		case .Invalid:
			return "invalid"
		}
		return ""
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
		notice_rect, hooks_rect: render.Rect
		step_back_rect, step_forward_rect, range_label_rect: render.Rect
		layout_button_rect, fold_button_rect, filter_button_rect: render.Rect
		wrap_button_rect, divider_rect: render.Rect
		filter_field_rect, filter_clear_rect, filter_bar_clear_rect: render.Rect
		regex_rect, sticky_rect, strip_older_rect, strip_newer_rect: render.Rect
		row_rect, summary_rect, panel_rect, files_button_rect, tools_button_rect: render.Rect
		overview_rect, overview_thumb_rect, turn_title_rect: render.Rect
		overview_state := ui.Scrollbar_State.Collapsed
		row_steps := 0
		range_title := ""
		title_buffer: [96]u8
		top_file, sticky_file := -1, -1
		strip_older, strip_newer, strip_bars := 0, 0, 0
		list_empty := ""
		label_buffer: [64]u8
		if pane != nil {
			view := &pane.model.view
			scope = strings.to_lower(changes_scope_name(pane.scope), context.temp_allocator)
			notice = strings.to_lower(reflect.enum_string(view.notice), context.temp_allocator)
			turn_count, first, last, files = len(view.turns), view.first, view.last, len(view.files)
			if shown, found := changes_pane_rect(w, pane.id); found {
				g := changes_geometry_of(app, w, pane, shown)
				row_rect, summary_rect, row_steps = g.row, g.summary, g.row_steps
				files_button_rect, tools_button_rect = g.files_button, g.tools_button
				layout_button_rect, fold_button_rect, filter_button_rect = g.layout_button, g.fold_button, g.filter_button
				wrap_button_rect = g.wrap_button
				divider_rect = ui.changes_divider_rect(g, view, &pane.state)
				filter_bar_clear_rect = g.filter_bar_clear
				overview_rect, overview_thumb_rect = g.overview, ui.changes_overview_thumb(&pane.state, g)
				overview_state = ui.changes_overview_state(&pane.state, g, w.pointer)
				if view.notice == .Recording_Off {notice_rect = g.notice_button}
				for i in 0 ..< min(len(view.files), 20) {
					edit := ui.changes_file_edit_button(g, view, &pane.state, i)
					state_rect(r, changes_report_key("file", i, "edit_rect"), edit)
				}
				// The panel's parts exist while it is open: the chips, the hooks button and the turn strip.
				if pane.state.panel_open {
					panel_rect, turn_title_rect = g.panel, g.turn_title
					if view.hooks_offer {hooks_rect = g.hooks}
					step_back_rect, step_forward_rect, range_label_rect = g.step_back, g.step_forward, g.range_label
					for chip, i in g.source_chips {
						state_rect(r, changes_report_key("source_chip", i, "rect"), chip)
						state_text(r, changes_report_key("source_chip", i, "label"), view.sources[i])
					}
					state_value(r, "changes.source_chip_current", view.source_current)
					for chip, i in g.worktree_chips {
						state_rect(r, changes_report_key("worktree_chip", i, "rect"), chip)
						state_text(r, changes_report_key("worktree_chip", i, "label"), view.worktree_labels[i])
					}
				}
				if pane.state.tools_open {
					for row, i in g.tools_rows {state_rect(r, changes_report_key("tools_row", i, "rect"), row)}
				}
				if pane.state.filter_open {
					filter_field_rect = g.filter_field
					if changes_filter_text(pane) != "" {filter_clear_rect = g.filter_clear}
					if box, shown := ui.changes_filter_box(g, view, &w.ui_text); shown {
						for _, i in pane.filter_tokens {
							rect := ui.filter_field_token_rect(box, pane.filter_tokens[:], i)
							state_rect(r, changes_report_key("filter_token", i, "rect"), rect)
							at, close := ui.filter_field_token_marks(box, pane.filter_tokens[:], i)
							state_rect(r, changes_report_key("filter_token", i, "at_rect"), at)
							state_rect(r, changes_report_key("filter_token", i, "close_rect"), close)
						}
					}
					for row, i in g.filter_picks {
						state_rect(r, changes_report_key("filter_pick", g.filter_pick_first + i, "rect"), row)
					}
					state_rect(r, "changes.filter_at_rect", g.filter_at)
					state_rect(r, "changes.filter_save_rect", g.filter_save)
					state_rect(r, "changes.filter_manage_rect", g.filter_manage)
				}
				if pane.state.files_open {
					choices, anchor := changes_dropdown_choices(pane), changes_dropdown_anchor(pane, g)
					regex_rect = ui.dropdown_regex_rect(&pane.dropdown, choices, anchor, w.scale)
				}
				top_file = ui.changes_top_file(&pane.state, view)
				sticky_file, sticky_rect = ui.changes_sticky_header(&pane.state, view, g)
				if ui.changes_scope_turns(pane.scope) {
					strip_older, strip_newer = ui.changes_strip_hidden(g, &pane.state, view)
					strip_bars = g.strip_bars
				}
				if pane.state.panel_open {
					if ui.changes_scope_turns(pane.scope) {
						strip_older_rect = ui.changes_strip_marker_rect(g, &pane.state, view, false)
						strip_newer_rect = ui.changes_strip_marker_rect(g, &pane.state, view, true)
					}
					for i in 0 ..< len(view.turns) {
						rect := ui.changes_strip_bar_rect(g, &pane.state, view, i)
						if rect.width <= 0 || rect.height <= 0 {continue}
						state_rect(r, changes_report_key("strip", i, "rect"), rect)
					}
				}
			}
			// State entries borrow their text until the report is written, after this returns.
			if ui.changes_scope_turns(pane.scope) {
				range_label = strings.clone(ui.changes_range_label(view, label_buffer[:]), context.temp_allocator)
			}
			range_title = strings.clone(ui.changes_range_title(view, title_buffer[:]), context.temp_allocator)
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
			if pane.state.files_open {
				choices := changes_dropdown_choices(pane)
				list_empty = ui.dropdown_empty_text(&pane.dropdown, choices)
				for match, i in pane.dropdown.matches {
					if i >= 20 {break}
					if match >= len(choices.choices) {continue}
					state_text(r, changes_report_key("file_list", i, "label"), choices.choices[match])
					faded := match < len(pane.model.faded) && pane.model.faded[match]
					state_value(r, changes_report_key("file_list", i, "faded"), faded)
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
		state_value(r, "changes.files_open", pane != nil && pane.state.files_open)
		state_value(r, "changes.panel_open", pane != nil && pane.state.panel_open)
		state_value(r, "changes.tools_open", pane != nil && pane.state.tools_open)
		state_value(r, "changes.row_steps", row_steps)
		state_value(r, "changes.side_by_side", pane != nil && pane.side_by_side)
		state_value(r, "changes.diff_scroll", pane != nil ? pane.state.diff_scroll : 0)
		state_value(r, "changes.top_file", top_file)
		state_value(r, "changes.any_expanded", pane != nil && pane.model.view.any_expanded)
		state_value(r, "changes.sticky_file", sticky_file)
		state_value(r, "changes.strip_bars", strip_bars)
		state_value(r, "changes.strip_older", strip_older)
		state_value(r, "changes.strip_newer", strip_newer)
		state_text(r, "changes.filter", pane != nil ? changes_filter_text(pane) : "")
		state_value(r, "changes.filter_open", pane != nil && pane.state.filter_open)
		state_value(r, "changes.filter_active", pane != nil && pane.model.view.filter_active)
		state_value(r, "changes.filter_invalid", pane != nil && pane.model.view.filter_invalid)
		state_text(r, "changes.filter_error", pane != nil ? pane.filter_error : "")
		state_value(r, "changes.filter_tokens", pane != nil ? len(pane.filter_tokens) : 0)
		state_value(r, "changes.filter_typing", pane != nil && pane.filter_typing)
		state_value(r, "changes.filter_pick_row", pane != nil ? pane.filter_pick_row : 0)
		state_value(r, "changes.filter_savable", pane != nil && pane.filter_savable)
		state_text(r, "changes.filter_notice", pane != nil ? pane.filter_notice : "")
		state_text(r, "changes.filter_on", pane != nil ? pane.filter_on_labels : "")
		state_text(r, "changes.saved_filters", app.settings.turns.saved_filters)
		if pane != nil {
			for token, i in pane.filter_tokens {
				state_text(r, changes_report_key("filter_token", i, "name"), token.name)
				state_text(r, changes_report_key("filter_token", i, "id"), token.id)
				state_value(r, changes_report_key("filter_token", i, "on"), !token.off)
				state_text(r, changes_report_key("filter_token", i, "state"), changes_token_state_name(token.state))
			}
			for pick, i in pane.filter_picks {
				state_text(r, changes_report_key("filter_pick", i, "name"), pick.label)
				state_value(r, changes_report_key("filter_pick", i, "hides"), pick.hides)
				state_text(r, changes_report_key("filter_pick", i, "id"), pick.id)
			}
		}
		state_value(r, "changes.hidden_files", pane != nil ? pane.model.view.hidden_count : 0)
		state_value(r, "changes.total_files", pane != nil ? pane.model.view.total_files : 0)
		state_value(r, "changes.shown_added", pane != nil ? pane.model.view.shown_added : 0)
		state_value(r, "changes.shown_removed", pane != nil ? pane.model.view.shown_removed : 0)
		state_value(r, "changes.total_added", pane != nil ? pane.model.view.total_added : 0)
		state_value(r, "changes.total_removed", pane != nil ? pane.model.view.total_removed : 0)
		state_value(r, "changes.minimum_contrast", pane != nil ? pane.model.view.minimum_contrast : 0)
		// What the tooltip says for the control under the pointer, and the key it names, whether or not it
		// is showing yet.
		tooltip := strings.clone(changes_tooltip(app, w, w.pointer.x, w.pointer.y), context.temp_allocator)
		key_buffer: [commands.SHORTCUT_TEXT_CAP]u8
		key := tooltip_shortcut(app, w, .Changes_Page, w.pointer.x, w.pointer.y, key_buffer[:])
		state_text(r, "changes.tooltip", tooltip)
		state_text(r, "changes.tooltip_key", strings.clone(key, context.temp_allocator))
		state_value(r, "changes.file_list_regex", pane != nil && pane.dropdown.regex)
		state_text(r, "changes.file_list_empty", list_empty)
		state_text(r, "changes.range_label", range_label)
		state_text(r, "changes.range_title", range_title)
		state_rect(r, "changes.row_rect", row_rect)
		state_rect(r, "changes.summary_rect", summary_rect)
		state_rect(r, "changes.panel_rect", panel_rect)
		state_rect(r, "changes.files_button_rect", files_button_rect)
		state_rect(r, "changes.tools_button_rect", tools_button_rect)
		state_rect(r, "changes.overview_rect", overview_rect)
		state_rect(r, "changes.overview_thumb_rect", overview_thumb_rect)
		look := "rest"
		if overview_state == .Hovered {look = "hover"} else if overview_state == .Active {look = "drag"}
		state_text(r, "changes.overview_state", look)
		state_rect(r, "changes.turn_title_rect", turn_title_rect)
		state_rect(r, "changes.notice_button_rect", notice_rect)
		state_rect(r, "changes.hooks_rect", hooks_rect)
		state_rect(r, "changes.step_back_rect", step_back_rect)
		state_rect(r, "changes.step_forward_rect", step_forward_rect)
		state_rect(r, "changes.range_label_rect", range_label_rect)
		state_rect(r, "changes.layout_button_rect", layout_button_rect)
		state_rect(r, "changes.wrap_button_rect", wrap_button_rect)
		state_rect(r, "changes.divider_rect", divider_rect)
		state_rect(r, "changes.filter_button_rect", filter_button_rect)
		state_rect(r, "changes.filter_field_rect", filter_field_rect)
		state_rect(r, "changes.filter_clear_rect", filter_clear_rect)
		state_rect(r, "changes.filter_bar_clear_rect", filter_bar_clear_rect)
		state_rect(r, "changes.file_list_regex_rect", regex_rect)
		state_rect(r, "changes.fold_button_rect", fold_button_rect)
		state_rect(r, "changes.sticky_rect", sticky_rect)
		state_rect(r, "changes.strip_older_rect", strip_older_rect)
		state_rect(r, "changes.strip_newer_rect", strip_newer_rect)
		changes_comments_state_report(r, app, w, pane)
	}
}

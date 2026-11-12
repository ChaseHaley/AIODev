package app_test

import app "../../src"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
pane_reports :: proc(
	workspace, pane: string,
	order: int,
	records: ..term.Program_Status,
) -> [dynamic]app.Status_Report {
	reports := make([dynamic]app.Status_Report, context.temp_allocator)
	copied := make([]term.Program_Status, len(records), context.temp_allocator)
	copy(copied, records)
	place := app.Status_Pane{workspace = workspace, workspace_order = order, crumb = "crumb", title = pane}
	app.status_tree_append(&reports, copied, 1, place)
	return reports
}

@(private = "file")
reports_of :: proc(workspace: string, records: ..term.Program_Status) -> [dynamic]app.Status_Report {
	return pane_reports(workspace, "pane", 0, ..records)
}

// What each row shows in tests: a report's id, or a label with its count.
@(private = "file")
row_texts :: proc(rows: []app.Status_Row) -> []string {
	texts := make([]string, len(rows), context.temp_allocator)
	for row, i in rows {
		texts[i] = row.report ? row.item.record.id : fmt.tprintf("[%s %d]", row.label, row.count)
	}
	return texts
}

@(private = "file")
expect_rows :: proc(t: ^testing.T, rows: []app.Status_Row, expected: []string, loc := #caller_location) {
	texts := row_texts(rows)
	testing.expect_value(t, len(texts), len(expected), loc)
	for text, i in expected {
		if i >= len(texts) {return}
		testing.expect_value(t, texts[i], text, loc)
	}
}

@(test)
activity_tree_keeps_children_with_parents_and_treats_orphans_as_roots :: proc(t: ^testing.T) {
	reports := reports_of(
		"W",
		{id = "a-b"},
		{id = "a/c/d"},
		{id = "a"},
		{id = "z/orphan"},
		{id = "a/b"},
	)
	expected := [?]struct {
		id:    string,
		depth: int,
	}{{"a", 0}, {"a/b", 1}, {"a/c/d", 1}, {"a-b", 0}, {"z/orphan", 0}}
	testing.expect_value(t, len(reports), len(expected))
	for e, i in expected {
		testing.expect_value(t, reports[i].item.record.id, e.id)
		testing.expect_value(t, reports[i].depth, e.depth)
	}
	rooted := reports_of("W", {id = "x"}, {id = ""}, {id = "x/y"})
	testing.expect_value(t, rooted[0].depth, 0)
	testing.expect_value(t, rooted[1].depth, 1)
	testing.expect_value(t, rooted[2].depth, 2)
}

@(test)
activity_sections_follow_urgency_and_keep_trees_whole :: proc(t: ^testing.T) {
	reports := reports_of(
		"W",
		{id = "idle", state = .Idle},
		{id = "seen", state = .Error, read = true},
		{id = "unseen", state = .Error},
		{id = "working", state = .Working},
		{id = "working/ask", state = .Blocked},
		{id = "working/ask/run", state = .Working},
		{id = "done", state = .Done},
		{id = "plain", state = .Working},
	)
	rows, _ := app.status_rows_project(.Status, reports[:], {32, 28}, 1)
	expect_rows(t, rows, {
		"[Needs you 2]", "unseen", "working", "working/ask", "working/ask/run",
		"[Working 1]", "plain",
		"[Finished 2]", "done", "seen",
		"[Idle 1]", "idle",
	})
	if len(rows) < 6 {return}
	testing.expect(t, rows[0].attention)
	testing.expect(t, !rows[5].attention)
	testing.expect_value(t, rows[1].height, 32)
	testing.expect_value(t, rows[3].height, 28)
	testing.expect_value(t, rows[0].height, 28)
	testing.expect_value(t, rows[0].y, 4)
	// Later sections stand 8 DIPs from the row above them.
	testing.expect_value(t, rows[5].y, rows[4].y + rows[4].height + 8)
}

// Ties within a section sort newest first by when the report giving the tree its section entered its
// state, and keep pane order when times match. Pane titles, which programs such as omp animate, play
// no part, nor do workspaces when grouping by status.
@(test)
activity_status_grouping_sorts_by_status_time_across_workspaces :: proc(t: ^testing.T) {
	base := time.now()
	at :: proc(base: time.Time, seconds: int) -> time.Time {
		return time.time_add(base, time.Duration(seconds) * time.Second)
	}
	reports := make([dynamic]app.Status_Report, context.temp_allocator)
	panes := [?]struct {
		workspace, pane, id: string,
		order, since:        int,
		state:               term.Program_Status_State,
	} {
		{"One", "⠋ alpha", "a", 0, 1, .Working},
		{"One", "zeta", "z", 0, 3, .Working},
		{"Two", "beta", "b1", 1, 2, .Working},
		{"Two", "beta", "b2", 1, 2, .Working},
		{"Two", "omega", "e", 1, 5, .Blocked},
	}
	for p in panes {
		record := term.Program_Status{id = p.id, state = p.state, since = at(base, p.since)}
		more := pane_reports(p.workspace, p.pane, p.order, record)
		append(&reports, ..more[:])
	}
	// A finished tree that needs you through an older child ranks by the child's time.
	more := pane_reports("One", "aardvark", 0,
		{id = "d", state = .Done, since = at(base, 9)},
		{id = "d/ask", state = .Blocked, since = at(base, 0)})
	append(&reports, ..more[:])
	rows, _ := app.status_rows_project(.Status, reports[:], {56, 56}, 1)
	expect_rows(t, rows, {"[Needs you 2]", "e", "d", "d/ask", "[Working 4]", "z", "b1", "b2", "a"})
}

@(test)
activity_workspace_grouping_nests_sections_under_each_workspace :: proc(t: ^testing.T) {
	reports := pane_reports("Two", "b", 1, {id = "late", state = .Working})
	more := pane_reports("One", "a", 0, {id = "done", state = .Done}, {id = "done/ask", state = .Blocked})
	append(&reports, ..more[:])
	more = pane_reports("One", "c", 0, {id = "run", state = .Working})
	append(&reports, ..more[:])
	rows, total := app.status_rows_project(.Workspace, reports[:], {56, 56}, 1.5)
	expect_rows(t, rows, {
		"[One 2]", "[Needs you 1]", "done", "done/ask", "[Working 1]", "run",
		"[Two 1]", "[Working 1]", "late",
	})
	if len(rows) != 9 {return}
	testing.expect(t, !rows[0].nested && rows[1].nested && rows[1].attention)
	testing.expect_value(t, rows[0].height, 28 * 1.5)
	// A nested label is shorter and sits right under the row above it.
	testing.expect_value(t, rows[1].height, 24 * 1.5)
	testing.expect_value(t, rows[1].y, rows[0].y + rows[0].height)
	testing.expect_value(t, rows[6].y, rows[5].y + rows[5].height + 8 * 1.5)
	testing.expect_value(t, total, rows[8].y + rows[8].height + 4 * 1.5)
}

@(test)
activity_groupings_project_nothing_without_reports :: proc(t: ^testing.T) {
	for group in settings.Status_Group {
		rows, total := app.status_rows_project(group, nil, {56, 56}, 1)
		testing.expect_value(t, len(rows), 0)
		testing.expect_value(t, total, 0)
	}
}

// WORK-406: rows take the chosen name, falling back when that term is empty; a subagent keeps its
// own title.
@(test)
activity_row_names_follow_the_setting_and_subagents_keep_their_titles :: proc(t: ^testing.T) {
	s: settings.Status_Settings
	item := app.Status_Item {
		record = {id = "a", app = "claude", title = "Long task"},
		pane = {title = "✳ Fix inbox", tab = "status", folder = "AIODev", program = "node"},
	}
	expected := [settings.Status_Row_Name]string {
		.Pane    = "✳ Fix inbox",
		.Program = "claude",
		.Tab     = "status",
		.Folder  = "AIODev",
	}
	for name in settings.Status_Row_Name {
		s.row_name = name
		testing.expect_value(t, app.status_report_name(&s, item, 0), expected[name])
		testing.expect_value(t, app.status_report_name(&s, item, 1), "Long task")
	}
	s.row_name = .Folder
	bare := item
	bare.pane.folder = ""
	testing.expect_value(t, app.status_report_name(&s, bare, 0), "Long task")
	bare.record.title, bare.record.app = "", ""
	testing.expect_value(t, app.status_report_name(&s, bare, 0), "✳ Fix inbox")
	testing.expect_value(t, app.status_report_name(&s, bare, 1), "✳ Fix inbox")
	s.row_name = .Program
	testing.expect_value(t, app.status_report_name(&s, bare, 0), "node")
}

@(test)
activity_row_terms_keep_their_order_and_skip_what_the_row_already_says :: proc(t: ^testing.T) {
	s := settings.Status_Settings {
		row_terms = {.Folder, .Workspace, .Message, .Tab, .Pane},
	}
	item := app.Status_Item {
		record = {state = .Working, progress = -1, message = "Editing"},
		pane = {workspace = "AIODev", title = "status", tab = "status", folder = ""},
	}
	testing.expect_value(t, app.status_report_terms(&s, item, "Session"), "Editing · status · status · AIODev")
	testing.expect_value(t, app.status_report_terms(&s, item, "status"), "Editing · AIODev")
	s.group_by = .Workspace
	testing.expect_value(t, app.status_report_terms(&s, item, "status"), "Editing")
	item.record.message = ""
	testing.expect_value(t, app.status_report_terms(&s, item, "status"), "Working")
	s.row_terms = {}
	testing.expect_value(t, app.status_report_terms(&s, item, "status"), "")
}

@(test)
activity_view_button_saves_one_preference_and_cancels_outside_or_on_capture_loss :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-view", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	saved := app.settings_save_value(s, "status.panel", "true", "enable panel")
	if !testing.expect(t, saved) {return}
	testing.expect_value(t, s.settings.status.panel_view, settings.Status_Panel_View.Comfy)
	r := app.status_panel_button_rect(s, w, .View)
	side := app.status_panel_button_rect(s, w, .Side)
	testing.expect(t, r.width > 0 && r.x + r.width <= side.x)
	x, y := r.x + r.width / 2, r.y + r.height / 2
	gesture_button(s, w, .Left, true, x, y)
	gesture_button(s, w, .Left, false, 0, 0)
	testing.expect_value(t, s.settings.status.panel_view, settings.Status_Panel_View.Comfy)
	gesture_button(s, w, .Left, true, x, y)
	app.handle_event(s, platform.Capture_Lost_Event{w.id})
	gesture_button(s, w, .Left, false, x, y)
	testing.expect_value(t, s.settings.status.panel_view, settings.Status_Panel_View.Comfy)
	for next in ([?]settings.Status_Panel_View{.Dense, .Comfy}) {
		gesture_button(s, w, .Left, true, x, y)
		gesture_button(s, w, .Left, false, x, y)
		testing.expect_value(t, s.settings.status.panel_view, next)
		text, err := os.read_entire_file(f.path, context.temp_allocator)
		testing.expect_value(t, err, nil)
		expected := next == .Dense ? "status.panel_view = dense" : "status.panel_view = comfy"
		testing.expect(t, strings.contains(string(text), expected))
	}
	// A Settings edit reaches the same preference the button reads.
	saved = app.settings_save_value(s, "status.panel_view", "dense", "set view")
	testing.expect(t, saved)
	testing.expect_value(t, s.settings.status.panel_view, settings.Status_Panel_View.Dense)
}

@(private = "file")
click_at :: proc(s: ^app.App, w: ^app.Window, x, y: f32) {
	gesture_button(s, w, .Left, true, x, y)
	gesture_button(s, w, .Left, false, x, y)
}

// The menu row with `label`, counting from the row after `after` when given.
@(private = "file")
menu_click :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, label: string, after := "") -> bool {
	menu := &w.activity_menu
	searching := after == ""
	for item, i in menu.items {
		if !searching {
			searching = item.label == after
			continue
		}
		if item.label != label {continue}
		r := ui.menu_row_rect(menu, i, f32(w.width), f32(w.height), w.scale)
		click_at(s, w, r.x + r.width / 2, r.y + r.height / 2)
		return true
	}
	testing.expectf(t, false, "no %q row in the Activity menu", label)
	return false
}

// WORK-406, WORK-412: Show and Group by sit left of the view button and open their menus, whose
// choices save the settings Settings shows. Show stays open while terms toggle and greys out the term
// that names the rows; Group by closes on a choice.
@(test)
activity_menus_save_row_names_terms_and_grouping :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-menus", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	if !testing.expect(t, app.settings_save_value(s, "status.panel", "true", "enable panel")) {return}
	show := app.status_panel_button_rect(s, w, .Show)
	group := app.status_panel_button_rect(s, w, .Group)
	view := app.status_panel_button_rect(s, w, .View)
	testing.expect(t, show.width > 0 && show.x + show.width <= group.x && group.x + group.width <= view.x)
	saved :: proc(t: ^testing.T, f: ^Palette_Fixture, line: string, loc := #caller_location) {
		text, err := os.read_entire_file(f.path, context.temp_allocator)
		testing.expect_value(t, err, nil, loc)
		testing.expectf(t, strings.contains(string(text), line), "settings lack %q", line, loc = loc)
	}
	click_at(s, w, show.x + show.width / 2, show.y + show.height / 2)
	if !testing.expect(t, app.activity_menu_shown(w, .Show)) {return}
	if !menu_click(t, s, w, "Tab") {return}
	testing.expect_value(t, s.settings.status.row_name, settings.Status_Row_Name.Tab)
	saved(t, &f, "status.row_name = tab")
	testing.expect(t, app.activity_menu_shown(w, .Show))
	if !menu_click(t, s, w, "Message", after = "Also show") {return}
	testing.expect_value(t, s.settings.status.row_terms, settings.Status_Row_Terms{.Workspace})
	saved(t, &f, "status.row_terms = workspace")
	// Tab names the rows, so it cannot also follow the name.
	if !menu_click(t, s, w, "Tab", after = "Also show") {return}
	testing.expect_value(t, s.settings.status.row_terms, settings.Status_Row_Terms{.Workspace})
	// The button that opened the menu closes it.
	click_at(s, w, show.x + show.width / 2, show.y + show.height / 2)
	testing.expect(t, !app.activity_menu_shown(w))
	click_at(s, w, group.x + group.width / 2, group.y + group.height / 2)
	if !testing.expect(t, app.activity_menu_shown(w, .Group)) {return}
	if !menu_click(t, s, w, "Workspace, then status") {return}
	testing.expect_value(t, s.settings.status.group_by, settings.Status_Group.Workspace)
	saved(t, &f, "status.group_by = workspace")
	testing.expect(t, !app.activity_menu_shown(w))
}

@(test)
activity_view_change_repaints_every_window :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-view-windows") {return}
	s := &f.state
	if !testing.expect(t, len(s.windows) > 1) {return}
	for window in s.windows {window.dirty = false}
	app.status_panel_view_toggle(s)
	testing.expect_value(t, s.settings.status.panel_view, settings.Status_Panel_View.Dense)
	for window in s.windows {testing.expect(t, window.dirty)}
	for window in s.windows {window.dirty = false}
	saved := app.settings_save_value(s, "status.panel_view", "comfy", "set view")
	testing.expect(t, saved)
	testing.expect_value(t, s.settings.status.panel_view, settings.Status_Panel_View.Comfy)
	for window in s.windows {testing.expect(t, window.dirty)}
}

@(test)
activity_view_setting_shows_its_user_facing_names :: proc(t: ^testing.T) {
	for entry in settings.SCHEMA {
		if entry.key != "status.panel_view" {continue}
		row := ui.schema_row(entry)
		testing.expect_value(t, row.kind, ui.Row_Kind.Choice)
		testing.expect_value(t, row.default_value, "comfy")
		testing.expect_value(t, row.choices[0], "comfy")
		testing.expect_value(t, row.choice_labels[0], "Comfy")
		testing.expect_value(t, row.choices[1], "dense")
		testing.expect_value(t, row.choice_labels[1], "Dense")
		return
	}
	testing.expect(t, false, "status.panel_view is missing from the schema")
}

@(test)
activity_rows_hit_and_explain_themselves_in_both_views :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-rows", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.panel = true
	s.settings.status.enabled = true
	s.settings.status.show_done = true
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	previous := entry.statuses
	defer {
		delete(entry.statuses)
		entry.statuses = previous
	}
	entry.statuses = make([]term.Program_Status, 2)
	entry.statuses[0] = {id = "a", app = "claude", title = "Long task",
		message = strings.repeat("long message ", 200, context.temp_allocator), state = .Done,
		progress = -1, updated_at = time.now()}
	entry.statuses[1] = {id = "a/b", app = "codex", title = "Child", state = .Working, progress = 40,
		updated_at = time.now()}
	for view in settings.Status_Panel_View {
		s.settings.status.panel_view = view
		app.window_relayout(s, w)
		rows, _ := app.status_panel_rows(s, w)
		list := app.status_panel_rect(s, w)
		found := 0
		for row in rows {
			if !row.report {continue}
			found += 1
			y := list.y + 32 * w.scale + row.y + row.height / 2
			x := list.x + 40 * w.scale
			index, rect := app.status_panel_hit(s, w, rows, x, y)
			if !testing.expect(t, index >= 0) {continue}
			testing.expect_value(t, rows[index].item.record.id, row.item.record.id)
			// The same point misses once the list scrolls a row away, and the row follows the scroll.
			w.status.panel_scroll = row.height
			scrolled, moved := app.status_panel_hit(s, w, rows, x, y - row.height)
			testing.expect_value(t, scrolled, index)
			testing.expect_value(t, moved.y, rect.y - row.height)
			w.status.panel_scroll = 0
			tip := app.status_panel_row_tooltip(s, w, x, y)
			testing.expect(t, strings.contains(tip, row.item.record.title))
			testing.expect(t, strings.contains(tip, row.item.pane.crumb))
			testing.expect(t, strings.contains(tip, row.item.record.app))
			testing.expect(t, strings.contains(tip, " for ") && strings.contains(tip, "read"))
			testing.expect_value(t, strings.count(tip, "\n"), row.item.record.message != "" ? 3 : 2)
			receipt := app.status_panel_receipt_rect(s, w, rect, row)
			rx, ry := receipt.x + receipt.width / 2, receipt.y + receipt.height / 2
			testing.expect(t, render.rect_contains(rect, rx, ry))
			// WORK-424: a working row out of view has nothing to mark; the fixture window is unfocused.
			mark := row.item.record.state == .Working && !w.focused ? "Working · " : "click to mark"
			testing.expect(t, strings.contains(app.status_panel_row_tooltip(s, w, rx, ry), mark))
			if row.item.record.state == .Done {
				close := app.status_panel_dismiss_rect(s, w, rect)
				cx, cy := close.x + close.width / 2, close.y + close.height / 2
				testing.expect(t, rect.y <= close.y && close.y + close.height <= rect.y + rect.height)
				testing.expect_value(t, app.status_panel_row_tooltip(s, w, cx, cy), "Dismiss")
			}
		}
		testing.expect_value(t, found, 2)
		if rows[0].report {continue}
		y := list.y + 32 * w.scale + rows[0].y + rows[0].height / 2
		index, _ := app.status_panel_hit(s, w, rows, list.x + 40 * w.scale, y)
		testing.expect_value(t, index, -1)
	}
}

@(private = "file")
inbox_press :: proc(s: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers = {}) {
	e := input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = true}
	app.handle_event(s, e)
	e.pressed = false
	app.handle_event(s, e)
}

// The open inbox keeps its list keys and passes every other key to the shortcuts and the terminal. It
// stays open for modifiers and shortcuts that open nothing, and closes for typing and other surfaces.
@(test)
activity_inbox_passes_keys_it_does_not_use :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-inbox-keys", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.enabled = true
	app.run_action(s, w, .Status_Inbox)
	if !testing.expect(t, app.status_inbox_shown(w)) {return}
	inbox_press(s, w, .Arrow_Down)
	inbox_press(s, w, .Control_Left, {.Control})
	points := s.font_points
	inbox_press(s, w, .Equal, {.Control})
	testing.expect(t, app.status_inbox_shown(w))
	testing.expect(t, s.font_points > points)
	// WORK-343: the inbox's own shortcut reaches it and closes it.
	inbox_press(s, w, .I, {.Control, .Shift})
	testing.expect(t, !app.status_inbox_shown(w))
	app.run_action(s, w, .Status_Inbox)
	typed := input.Key_Event{window = w.id, key = .A, pressed = true, text = "a"}
	app.handle_event(s, typed)
	testing.expect(t, !app.status_inbox_shown(w) && !app.key_suppressed(w, .A))
	typed.pressed, typed.text = false, ""
	app.handle_event(s, typed)
	app.run_action(s, w, .Status_Inbox)
	inbox_press(s, w, .F10, {.Shift})
	testing.expect(t, app.tab_menu_shown(w) && !app.status_inbox_shown(w))
}

// WORK-412: the inbox lists the panel's groups in the panel's order, and its selection passes over
// the labels between them.
@(test)
activity_inbox_groups_like_the_panel_and_skips_labels :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-inbox-groups", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.enabled = true
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	previous := entry.statuses
	defer {
		delete(entry.statuses)
		entry.statuses = previous
	}
	entry.statuses = make([]term.Program_Status, 2)
	entry.statuses[0] = {id = "a", state = .Working, progress = -1, updated_at = time.now()}
	entry.statuses[1] = {id = "b", state = .Blocked, progress = -1, updated_at = time.now()}
	app.run_action(s, w, .Status_Inbox)
	if !testing.expect(t, app.status_inbox_shown(w)) {return}
	rows, _ := app.status_rows_project(s.settings.status.group_by, app.status_reports(s, w), {48, 48}, w.scale)
	expect_rows(t, rows, {"[Needs you 1]", "b", "[Working 1]", "a"})
	selected :: proc(w: ^app.Window) -> int {
		inbox, _ := w.status.inbox.?
		return inbox.selected
	}
	inbox_press(s, w, .Arrow_Up)
	testing.expect_value(t, selected(w), 1)
	inbox_press(s, w, .Arrow_Down)
	testing.expect_value(t, selected(w), 3)
	inbox_press(s, w, .Arrow_Down)
	testing.expect_value(t, selected(w), 3)
	inbox_press(s, w, .Arrow_Up)
	testing.expect_value(t, selected(w), 1)
}

// U in the open inbox reads the selected row's pane, or marks it unread once read, and keeps the key.
@(test)
activity_inbox_u_reads_and_unreads_the_selected_pane :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-inbox-read", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.enabled = true
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	previous := entry.statuses
	defer {
		delete(entry.statuses)
		entry.statuses = previous
	}
	entry.statuses = make([]term.Program_Status, 1)
	entry.statuses[0] = {id = "a", app = "claude", state = .Done, progress = -1, updated_at = time.now()}
	app.run_action(s, w, .Status_Inbox)
	if !testing.expect(t, app.status_inbox_shown(w)) {return}
	entry.status_unread = true
	inbox_press(s, w, .U)
	testing.expect(t, app.status_inbox_shown(w))
	testing.expect(t, !entry.status_unread && entry.status_read_at != {})
	entry.statuses[0].read = true
	inbox_press(s, w, .U)
	testing.expect(t, entry.status_unread)
}

// WORK-424: a working program out of view always has output the user has not seen, so its row is
// unread whatever the pane's last read, and U leaves it be; in view it reads as before.
@(test)
activity_working_rows_stay_unread_out_of_view :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-working-unread", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.enabled = true
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	previous := entry.statuses
	defer {
		delete(entry.statuses)
		entry.statuses = previous
	}
	entry.statuses = make([]term.Program_Status, 2)
	entry.statuses[0] = {id = "a", state = .Working, progress = -1, read = true, updated_at = time.now()}
	entry.statuses[1] = {id = "b", state = .Done, progress = -1, read = true, updated_at = time.now()}
	read_of :: proc(s: ^app.App, w: ^app.Window, id: string) -> (read, found: bool) {
		for report in app.status_reports(s, w) {
			if report.item.record.id == id {return report.item.record.read, true}
		}
		return
	}
	w.focused = true
	working, found := read_of(s, w, "a")
	testing.expect(t, found && working)
	w.focused = false
	working, found = read_of(s, w, "a")
	testing.expect(t, found && !working)
	done, _ := read_of(s, w, "b")
	testing.expect(t, done)
	app.run_action(s, w, .Status_Inbox)
	if !testing.expect(t, app.status_inbox_shown(w)) {return}
	rows, _ := app.status_rows_project(s.settings.status.group_by, app.status_reports(s, w), {48, 48}, w.scale)
	for row, i in rows {
		if row.report && row.item.record.id == "a" {w.status.inbox = app.Status_Inbox{selected = i}}
	}
	inbox, _ := w.status.inbox.?
	if !testing.expect(t, rows[inbox.selected].item.record.id == "a") {return}
	read_at := entry.status_read_at
	inbox_press(s, w, .U)
	testing.expect(t, !entry.status_unread && entry.status_read_at == read_at)
}

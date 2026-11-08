package app_test

import app "../../src"
import "aio:input"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
reports_of :: proc(
	workspace: string,
	records: ..term.Program_Status,
) -> [dynamic]app.Status_Panel_Report {
	reports := make([dynamic]app.Status_Panel_Report, context.temp_allocator)
	copied := make([]term.Program_Status, len(records), context.temp_allocator)
	copy(copied, records)
	app.status_panel_tree_append(&reports, copied, 1, "crumb", workspace)
	return reports
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
activity_comfy_groups_by_workspace_with_fixed_row_heights :: proc(t: ^testing.T) {
	reports := reports_of("One", {id = "a", state = .Working}, {id = "a/b", state = .Blocked})
	more := reports_of("Two", {id = "c", state = .Done})
	append(&reports, ..more[:])
	rows, total := app.status_panel_project(.Comfy, reports[:], 1.5)
	testing.expect_value(t, len(rows), 5)
	testing.expect_value(t, rows[0].label, "One")
	testing.expect(t, rows[1].report && rows[2].report && !rows[3].report && rows[4].report)
	testing.expect_value(t, rows[2].depth, 1)
	testing.expect_value(t, rows[3].label, "Two")
	testing.expect_value(t, rows[0].height, 28 * 1.5)
	testing.expect_value(t, rows[1].height, 56 * 1.5)
	testing.expect_value(t, rows[0].y, 4 * 1.5)
	// Later groups stand 8 DIPs from the row above them.
	testing.expect_value(t, rows[3].y, rows[2].y + rows[2].height + 8 * 1.5)
	testing.expect_value(t, total, rows[4].y + rows[4].height + 4 * 1.5)
}

@(test)
activity_dense_sections_follow_urgency_and_keep_trees_whole :: proc(t: ^testing.T) {
	reports := reports_of(
		"W",
		{id = "idle", state = .Idle},
		{id = "seen", state = .Error_Seen},
		{id = "unseen", state = .Error},
		{id = "working", state = .Working},
		{id = "working/ask", state = .Blocked},
		{id = "working/ask/run", state = .Working},
		{id = "done", state = .Done},
		{id = "plain", state = .Working},
	)
	rows, _ := app.status_panel_project(.Dense, reports[:], 1)
	expected := [?]struct {
		text:  string,
		count: int,
	} {
		{"Needs you", 2},
		{"unseen", 0},
		{"working", 0},
		{"working/ask", 0},
		{"working/ask/run", 0},
		{"Working", 1},
		{"plain", 0},
		{"Finished", 2},
		{"done", 0},
		{"seen", 0},
		{"Idle", 1},
		{"idle", 0},
	}
	testing.expect_value(t, len(rows), len(expected))
	if len(rows) != len(expected) {return}
	for e, i in expected {
		row := rows[i]
		testing.expect_value(t, row.report ? row.item.record.id : row.label, e.text)
		testing.expect_value(t, row.count, e.count)
	}
	testing.expect(t, rows[0].attention)
	testing.expect(t, !rows[5].attention)
	testing.expect_value(t, rows[1].height, 32)
	testing.expect_value(t, rows[3].height, 28)
	testing.expect_value(t, rows[0].height, 28)
}

@(test)
activity_views_project_nothing_without_reports :: proc(t: ^testing.T) {
	for view in settings.Status_Panel_View {
		rows, total := app.status_panel_project(view, nil, 1)
		testing.expect_value(t, len(rows), 0)
		testing.expect_value(t, total, 0)
	}
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
	r := app.status_panel_view_rect(s, w)
	side := app.status_panel_side_rect(s, w)
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
			testing.expect(t, strings.contains(tip, row.item.crumb))
			testing.expect(t, strings.contains(tip, row.item.record.app))
			testing.expect_value(t, strings.count(tip, "\n"), 2)
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

package ui_test

import "core:fmt"
import "core:mem"
import "core:testing"
import "aio:commands"
import "aio:input"
import "aio:ui"

@(private = "file")
DAY :: 24 * 60 * 60

@(private = "file")
UP := input.Key_Event{key = .Arrow_Up, pressed = true}
@(private = "file")
DOWN := input.Key_Event{key = .Arrow_Down, pressed = true}

// Runs the best result for `query` in `mode`, as typing it and pressing Enter does.
@(private = "file")
submit :: proc(
	t: ^testing.T,
	p: ^ui.Palette,
	registry: ^commands.Registry,
	query: string,
	mode := ui.Palette_Mode.All,
	now: i64 = 0,
) {
	ui.palette_open_mode(p, registry, mode, now)
	ui.palette_text(p, registry, query)
	outcome, _ := ui.palette_key(p, registry, key({key = .Enter}))
	testing.expectf(t, outcome != .None && outcome != .Changed, "%q in %v ran nothing", query, mode)
}

@(private = "file")
press :: proc(p: ^ui.Palette, registry: ^commands.Registry, e: input.Key_Event) -> ui.Outcome {
	outcome, _ := ui.palette_key(p, registry, e)
	return outcome
}

@(private = "file")
titles :: proc(p: ^ui.Palette) -> []string {
	list := make([dynamic]string, context.temp_allocator)
	for result in p.results {append(&list, ui.palette_result_title(p, result))}
	return list[:]
}

@(test)
query_history_step_walks_like_a_prompt :: proc(t: ^testing.T) {
	h: ui.Query_History(int)
	defer ui.query_history_destroy(&h)
	_, ok := ui.query_history_step(&h, -1, "", true)
	testing.expect(t, !ok)
	ui.query_history_add(&h, "one", 1)
	ui.query_history_add(&h, "two", 2)
	ui.query_history_add(&h, "", 3)
	ui.query_history_add(&h, "one", 4)
	testing.expect_value(t, len(h.entries), 2)
	testing.expect_value(t, h.entries[0].query, "two")
	testing.expect_value(t, h.entries[1], ui.Query_Entry(int){"one", 4})
	next: int
	// From the draft only Up goes anywhere, and it skips an entry equal to the draft.
	_, ok = ui.query_history_step(&h, -1, "", false)
	testing.expect(t, !ok)
	next, ok = ui.query_history_step(&h, -1, "x", true)
	testing.expect(t, ok && next == 1)
	next, ok = ui.query_history_step(&h, -1, "one", true)
	testing.expect(t, ok && next == 0)
	// The oldest entry is an end, not a wrap; Down past the newest returns to the draft.
	_, ok = ui.query_history_step(&h, 0, "two", true)
	testing.expect(t, !ok)
	next, ok = ui.query_history_step(&h, 0, "two", false)
	testing.expect(t, ok && next == 1)
	next, ok = ui.query_history_step(&h, 1, "one", false)
	testing.expect(t, ok && next == -1)
	for i in 0 ..< ui.QUERY_HISTORY_LIMIT + 5 {ui.query_history_add(&h, fmt.tprintf("q%d", i), i)}
	testing.expect_value(t, len(h.entries), ui.QUERY_HISTORY_LIMIT)
	testing.expect_value(t, h.entries[0].query, "q5")
}

@(test)
palette_up_without_history_leaves_the_query_alone :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	press(&p, &registry, UP)
	testing.expect_value(t, ui.palette_query(&p), "")
	testing.expect_value(t, p.selected, 0)
	testing.expect(t, p.browse == nil)
	press(&p, &registry, DOWN)
	testing.expect_value(t, p.selected, 1)
}

@(test)
palette_up_and_down_walk_submitted_queries_with_their_modes :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	submit(t, &p, &registry, "quit")
	submit(t, &p, &registry, "rest", .Commands)
	submit(t, &p, &registry, "copy")
	// Closing without running a result records nothing.
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "abandoned")
	ui.palette_close(&p)
	testing.expect_value(t, len(p.history.entries), 3)

	ui.palette_open_mode(&p, &registry, .Commands)
	steps := [?]struct {
		key:     input.Key_Event,
		outcome: ui.Outcome,
		query:   string,
		mode:    ui.Palette_Mode,
	}{
		{UP, .Changed, "copy", .All},
		{UP, .Changed, "rest", .Commands},
		{UP, .Changed, "quit", .All},
		// The oldest entry is an end: Up stays there and the selection does not move either.
		{UP, .None, "quit", .All},
		{DOWN, .Changed, "rest", .Commands},
		{DOWN, .Changed, "copy", .All},
		// Past the newest entry the empty query and its mode come back.
		{DOWN, .Changed, "", .Commands},
	}
	for step, i in steps {
		testing.expectf(t, press(&p, &registry, step.key) == step.outcome, "step %d outcome", i)
		testing.expectf(t, ui.palette_query(&p) == step.query, "step %d: %q", i, ui.palette_query(&p))
		testing.expectf(t, p.mode == step.mode, "step %d: %v", i, p.mode)
		testing.expectf(t, p.selected == 0, "step %d selected %d", i, p.selected)
	}
	testing.expect(t, p.browse == nil)
	// No longer browsing, Down moves the selection.
	press(&p, &registry, DOWN)
	testing.expect_value(t, p.selected, 1)
	testing.expect_value(t, ui.palette_query(&p), "")

	// Running a recalled query makes it the newest entry again.
	ui.palette_open(&p, &registry)
	press(&p, &registry, UP)
	press(&p, &registry, UP)
	press(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, p.history.entries[len(p.history.entries) - 1].query, "rest")
	testing.expect_value(t, len(p.history.entries), 3)
}

@(test)
palette_up_moves_the_selection_until_the_first_row :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	submit(t, &p, &registry, "quit")
	ui.palette_open(&p, &registry)
	press(&p, &registry, DOWN)
	press(&p, &registry, DOWN)
	testing.expect_value(t, p.selected, 2)
	press(&p, &registry, UP)
	press(&p, &registry, UP)
	testing.expect_value(t, p.selected, 0)
	testing.expect_value(t, ui.palette_query(&p), "")
	press(&p, &registry, UP)
	testing.expect_value(t, ui.palette_query(&p), "quit")
	// Shift, Ctrl or Alt with the arrows leave history alone.
	ui.palette_open(&p, &registry)
	press(&p, &registry, key({key = .Arrow_Up, modifiers = {.Shift}}))
	testing.expect_value(t, ui.palette_query(&p), "")
}

@(test)
palette_editing_or_moving_after_recall_returns_the_arrows_to_the_list :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	submit(t, &p, &registry, "re")

	ui.palette_open(&p, &registry)
	press(&p, &registry, UP)
	testing.expect_value(t, ui.palette_query(&p), "re")
	ui.palette_text(&p, &registry, "s")
	testing.expect(t, p.browse == nil)
	testing.expect(t, len(p.results) >= 2)
	press(&p, &registry, DOWN)
	testing.expect_value(t, p.selected, 1)
	press(&p, &registry, UP)
	press(&p, &registry, UP)
	testing.expect_value(t, p.selected, 0)
	testing.expect_value(t, ui.palette_query(&p), "res")

	// Ctrl+N and Ctrl+P always move the selection, and moving it ends browsing.
	ui.palette_open(&p, &registry)
	press(&p, &registry, UP)
	press(&p, &registry, key({key = ui.LIST_NEXT_KEY, modifiers = {.Control}}))
	testing.expect_value(t, p.selected, 1)
	testing.expect(t, p.browse == nil)
	press(&p, &registry, UP)
	testing.expect_value(t, p.selected, 0)
	testing.expect_value(t, ui.palette_query(&p), "re")
}

// Browsing copies the draft; every way out of browsing frees it.
@(test)
palette_browsing_frees_its_draft_however_it_ends :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	submit(t, &p, &registry, "quit")
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	Way_Out :: enum {Past_Newest, Typing, Next_Key, Mode, Close, Enter}
	for way in Way_Out {
		ui.palette_open(&p, &registry)
		context.allocator = mem.tracking_allocator(&tracking)
		press(&p, &registry, UP)
		browse, browsing := p.browse.?
		if !testing.expectf(t, browsing, "%v did not browse", way) {continue}
		draft := rawptr(raw_data(browse.draft.query))
		switch way {
		case .Past_Newest:
			press(&p, &registry, DOWN)
		case .Typing:
			ui.palette_text(&p, &registry, "!")
		case .Next_Key:
			press(&p, &registry, key({key = ui.LIST_NEXT_KEY, modifiers = {.Control}}))
		case .Mode:
			press(&p, &registry, key({key = .Tab}))
		case .Close:
			ui.palette_close(&p)
		case .Enter:
			press(&p, &registry, key({key = .Enter}))
		}
		testing.expectf(t, p.browse == nil, "%v kept browsing", way)
		testing.expectf(t, draft not_in tracking.allocation_map, "%v kept the draft", way)
		context.allocator = tracking.backing
	}
}

@(test)
palette_empty_query_lists_frecent_results_first :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows := [?]ui.Palette_Setting{{key = "font.size", title = "Font Size", group = "Text"}}
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry, 10 * DAY)
	natural := [?]string{"Quit AIODev", "Restart Shell", "Reload Settings", "Copy", "Font Size"}
	testing.expect_value(t, len(titles(&p)), len(natural))
	for title, i in titles(&p) {testing.expectf(t, title == natural[i], "row %d: %s", i, title)}

	submit(t, &p, &registry, "copy", now = 10 * DAY)
	submit(t, &p, &registry, "reload", now = 11 * DAY)
	submit(t, &p, &registry, "reload", now = 11 * DAY)
	submit(t, &p, &registry, "font size", now = 11 * DAY)
	ui.palette_open(&p, &registry, 11 * DAY)
	// Two uses today, one today, one yesterday, then the rest in their usual order.
	expected := [?]string{"Reload Settings", "Font Size", "Copy", "Quit AIODev", "Restart Shell"}
	for title, i in titles(&p) {testing.expectf(t, title == expected[i], "row %d: %s", i, title)}
	testing.expect(t, p.results[0].frecency > p.results[1].frecency)
	testing.expect_value(t, p.results[3].frecency, 0.0)
	// The mode's own list follows the same order.
	ui.palette_open_mode(&p, &registry, .Commands, 11 * DAY)
	testing.expect_value(t, titles(&p)[0], "Reload Settings")
	testing.expect_value(t, titles(&p)[1], "Copy")
}

@(test)
palette_typed_query_keeps_match_quality_ahead_of_frecency :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	if !testing.expect_value(t, commands.register(&registry, {id = 5, name = "shell.pick", title = "Shell Picker"}),
		commands.Error.None) {return}
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "re")
	before := titles(&p)[0]
	// Equal match classes order by frecency: run the one that ranked second.
	other := before == "Restart Shell" ? "reload" : "restart"
	for _ in 0 ..< 3 {submit(t, &p, &registry, other)}
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "re")
	testing.expect(t, titles(&p)[0] != before)

	// A frecent substring match stays behind a prefix match nobody ran.
	for _ in 0 ..< 5 {submit(t, &p, &registry, "restart shell")}
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "shell")
	testing.expect_value(t, titles(&p)[0], "Shell Picker")
	testing.expect_value(t, titles(&p)[1], "Restart Shell")
}

@(test)
palette_frecency_follows_a_tab_by_id_through_a_rename :: proc(t: ^testing.T) {
	items := []ui.Palette_Item{{"alpha", "pwsh", "Workspace 1", 1}, {"beta", "pwsh", "Workspace 1", 2}}
	tabs := Mode_Source{items = items}
	p: ui.Palette
	registry := mode_palette(t, &p, nil, &tabs, nil)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &registry, .Tabs)
	press(&p, &registry, DOWN)
	outcome, _ := ui.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, outcome, ui.Outcome.Open_Tab)
	items[1].label = "gamma"
	ui.palette_open_mode(&p, &registry, .Tabs)
	testing.expect_value(t, titles(&p)[0], "gamma")
	testing.expect_value(t, p.results[0].id, u64(2))
}

// Changing a setting in place counts as a use, once per opening however many steps it takes; the order
// stays as it opened until the palette opens again.
@(test)
palette_inline_setting_changes_count_once_per_opening :: proc(t: ^testing.T) {
	v: Control_Values
	p: ui.Palette
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	alt_right := key({key = .Arrow_Right, modifiers = {.Alt}})
	select_setting(&p, "pane.gap")
	for _ in 0 ..< 5 {
		outcome, _ := ui.palette_key(&p, &registry, alt_right)
		testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	}
	testing.expect_value(t, p.usage.settings.entries["pane.gap"].count, 1)
	testing.expect(t, ui.palette_used_take(&p))
	testing.expect(t, !ui.palette_used_take(&p))
	testing.expect_value(t, ui.palette_frecency(&p, p.results[p.selected]), 0.0)
	// Ctrl+Enter flips a toggle, and opening a list counts even when nothing is chosen.
	select_setting(&p, "cursor.blink")
	ui.palette_key(&p, &registry, key({key = .Enter, modifiers = {.Control}}))
	select_setting(&p, "cursor.style")
	ui.palette_key(&p, &registry, key({key = .Enter, modifiers = {.Control}}))
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Choice)
	ui.palette_key(&p, &registry, key({key = .Escape}))
	testing.expect_value(t, p.usage.settings.entries["cursor.blink"].count, 1)
	testing.expect_value(t, p.usage.settings.entries["cursor.style"].count, 1)
	testing.expect(t, "status.ignore_apps" not_in p.usage.settings.entries)

	// Another opening counts again.
	ui.palette_open_mode(&p, &registry, .Settings)
	select_setting(&p, "pane.gap")
	ui.palette_key(&p, &registry, alt_right)
	ui.palette_key(&p, &registry, alt_right)
	testing.expect_value(t, p.usage.settings.entries["pane.gap"].count, 2)
	ui.palette_open_mode(&p, &registry, .Settings)
	testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "pane.gap")
	testing.expect_value(t, ui.palette_result_name(&p, p.results[1]), "cursor.blink")
	testing.expect_value(t, ui.palette_result_name(&p, p.results[2]), "cursor.style")
}

@(test)
palette_shortcut_editor_counts_its_command :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "copy")
	ui.palette_key(&p, &registry, key({key = .Enter, modifiers = {.Control}}))
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Shortcut)
	testing.expect_value(t, p.usage.commands.entries["edit.copy"].count, 1)
	testing.expect(t, ui.palette_used_take(&p))
	ui.palette_close(&p)
	ui.palette_open(&p, &registry)
	testing.expect_value(t, titles(&p)[0], "Copy")
}

// Any use of a row records the query that found it, as running one does, and once per opening for the
// same text.
@(test)
palette_inline_change_records_its_query_in_history :: proc(t: ^testing.T) {
	rows := [?]ui.Palette_Setting {
		{key = "appearance.theme", title = "Theme", group = "Appearance", control = .Choice,
			choices = {"dark", "light"}},
		{key = "pane.gap", title = "Pane gap", group = "Panes", control = .Slider, minimum = 0, maximum = 24,
			step = 1},
	}
	v: Control_Values
	control_set(&v, "appearance.theme", "dark")
	control_set(&v, "pane.gap", "5")
	registry := commands.create()
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_set_values(&p, {user = &v, value = control_value, choices = control_choices})
	alt_right := key({key = .Arrow_Right, modifiers = {.Alt}})

	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "theme")
	for _ in 0 ..< 3 {
		outcome, _ := ui.palette_key(&p, &registry, alt_right)
		testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	}
	testing.expect_value(t, len(p.history.entries), 1)
	outcome, _ := ui.palette_key(&p, &registry, key({key = .Escape}))
	testing.expect_value(t, outcome, ui.Outcome.Closed)
	ui.palette_open_mode(&p, &registry, .Commands)
	press(&p, &registry, UP)
	testing.expect_value(t, ui.palette_query(&p), "theme")
	testing.expect_value(t, p.mode, ui.Palette_Mode.All)

	// A second query records too; returning to the first in the same opening records nothing again.
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "theme")
	ui.palette_key(&p, &registry, alt_right)
	ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	ui.palette_text(&p, &registry, "gap")
	ui.palette_key(&p, &registry, alt_right)
	ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	ui.palette_text(&p, &registry, "theme")
	ui.palette_key(&p, &registry, alt_right)
	testing.expect_value(t, len(p.history.entries), 2)
	testing.expect_value(t, p.history.entries[1].query, "gap")
	// Opening a list counts as a use and records its query; an empty query records nothing.
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "them")
	ui.palette_key(&p, &registry, key({key = .Enter, modifiers = {.Control}}))
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Choice)
	testing.expect_value(t, p.history.entries[len(p.history.entries) - 1].query, "them")
	ui.palette_open(&p, &registry)
	ui.palette_key(&p, &registry, alt_right)
	testing.expect_value(t, len(p.history.entries), 3)
}

@(test)
palette_shortcut_editor_records_its_query_in_history :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "copy")
	ui.palette_key(&p, &registry, key({key = .Enter, modifiers = {.Control}}))
	ui.palette_close(&p)
	ui.palette_open(&p, &registry)
	press(&p, &registry, UP)
	testing.expect_value(t, ui.palette_query(&p), "copy")
}

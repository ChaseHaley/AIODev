package ui_test

import "core:strings"
import "core:testing"
import "aio:commands"
import "aio:font"
import "aio:platform"
import "aio:ui"

@(private)
Mode_Source :: struct {
	items: []ui.Palette_Item,
}

@(private)
mode_source_count :: proc(user: rawptr) -> int {
	source := cast(^Mode_Source)user
	return len(source.items)
}

@(private)
mode_source_at :: proc(user: rawptr, index: int) -> ui.Palette_Item {
	source := cast(^Mode_Source)user
	if index < 0 || index >= len(source.items) {return {}}
	return source.items[index]
}

@(private)
mode_palette :: proc(
	t: ^testing.T,
	p: ^ui.Palette,
	rows: []ui.Palette_Setting,
	tabs, workspaces: ^Mode_Source,
) -> commands.Registry {
	registry := commands.create()
	if !testing.expect_value(t, ui.palette_init(p, rows), nil) {
		commands.destroy(&registry)
		return registry
	}
	if tabs != nil {
		ui.palette_set_sources(
			p,
			{user = tabs, count = mode_source_count, item = mode_source_at},
			{},
		)
	}
	if workspaces != nil {
		ui.palette_set_sources(
			p,
			{user = tabs, count = mode_source_count, item = mode_source_at},
			{user = workspaces, count = mode_source_count, item = mode_source_at},
		)
	}
	return registry
}

@(private)
mode_names :: proc(p: ^ui.Palette) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for result in p.results {append(&names, ui.palette_result_name(p, result))}
	return names[:]
}

@(private)
mode_kinds :: proc(p: ^ui.Palette) -> []ui.Palette_Kind {
	kinds := make([dynamic]ui.Palette_Kind, context.temp_allocator)
	for result in p.results {append(&kinds, result.kind)}
	return kinds[:]
}

@(test)
palette_prefix_parses_only_the_four_leading_tokens :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:   string,
		mode:   ui.Palette_Mode,
		length: int,
	}{
		{"t:aio", .Tabs, 2},
		{"w:build", .Workspaces, 2},
		{"s:font", .Settings, 2},
		{"c:split", .Commands, 2},
		{"x:aio", .All, 0},
		{"T:aio", .All, 0},
		{"t", .All, 0},
		{"aio", .All, 0},
		{"", .All, 0},
	}
	for c in cases {
		mode, length := ui.palette_parse_prefix(c.text)
		testing.expect_value(t, mode, c.mode)
		testing.expect_value(t, length, c.length)
	}
}

@(test)
palette_typing_a_prefix_converts_to_a_mode_and_back :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)

	ui.palette_open(&p, &registry)
	testing.expect_value(t, ui.palette_text(&p, &registry, "t:aio"), ui.Outcome.Changed)
	testing.expect_value(t, p.mode, ui.Palette_Mode.Tabs)
	testing.expect_value(t, ui.palette_query(&p), "aio")
	testing.expect_value(t, ui.palette_mode_prefix(p.mode), "t:")
	// Moving the caret to zero and deleting there removes the chip and keeps the text.
	ui.palette_key(&p, &registry, key({key = .Arrow_Left, modifiers = {.Control}}))
	outcome, _ := ui.palette_key(&p, &registry, key({key = .Backspace}))
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, p.mode, ui.Palette_Mode.All)
	testing.expect_value(t, ui.palette_query(&p), "aio")
	testing.expect_value(t, ui.palette_mode_prefix(p.mode), "")

	// A prefix typed over the text replaces the chip.
	ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	ui.palette_text(&p, &registry, "w:build")
	testing.expect_value(t, p.mode, ui.Palette_Mode.Workspaces)
	testing.expect_value(t, ui.palette_query(&p), "build")

	// An unknown prefix stays literal text.
	ui.palette_set_mode(&p, &registry, .All)
	ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	ui.palette_text(&p, &registry, "x:aio")
	testing.expect_value(t, p.mode, ui.Palette_Mode.All)
	testing.expect_value(t, ui.palette_query(&p), "x:aio")
}

@(test)
palette_tab_cycles_all_five_modes :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	order := [?]ui.Palette_Mode {
		.Tabs,
		.Workspaces,
		.Settings,
		.Commands,
		.All,
	}
	for expected in order {
		outcome, _ := ui.palette_key(&p, &registry, key({key = .Tab}))
		testing.expect_value(t, outcome, ui.Outcome.Changed)
		testing.expect_value(t, p.mode, expected)
		testing.expect_value(t, ui.palette_mode_prefix(p.mode) != "", expected != .All)
	}
	ui.palette_text(&p, &registry, "pane")
	for expected in ([?]ui.Palette_Mode{.Commands, .Settings, .Workspaces, .Tabs, .All}) {
		p.selected, p.scroll = 3, 2
		outcome, _ := ui.palette_key(&p, &registry, key({key = .Tab, modifiers = {.Shift}}))
		testing.expect_value(t, outcome, ui.Outcome.Changed)
		testing.expect_value(t, p.mode, expected)
		testing.expect_value(t, ui.palette_query(&p), "pane")
		testing.expect_value(t, p.selected, 0)
		testing.expect_value(t, p.scroll, 0)
	}
}

@(test)
palette_mode_labels_fit_at_control_size :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, nil, 13)) {return}
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	for scale in ([?]f32{1, 1.5, 2}) {
		ui.text_set_size(&text, 13 * scale)
		for mode in ([?]ui.Palette_Mode{.All, .Tabs, .Workspaces, .Settings, .Commands}) {
			ui.palette_open_mode(&p, &registry, mode)
			l := ui.palette_layout(&p, 560 * scale, 700 * scale, scale)
			needed := ui.text_width(&text, ui.palette_mode_info(mode).word) +
				(2 * ui.CONTROL_INSET + ui.ICON_BUTTON + ui.SPACE_2) * scale
			testing.expect(t, l.modes[mode].width >= needed)
		}
	}
}

@(test)
palette_modes_filter_and_group_by_domain :: proc(t: ^testing.T) {
	tabs := Mode_Source{items = []ui.Palette_Item{{"aio", "pwsh", "Workspace 1", 1}, {"aio docs", "nvim", "Workspace 1", 2}}}
	workspaces := Mode_Source{items = []ui.Palette_Item{{"aio workspace", "pwsh", "", 10}}}
	rows := [?]ui.Palette_Setting{{key = "aio.key", title = "Use aio", group = "Panes"}}
	p: ui.Palette
	registry := mode_palette(t, &p, rows[:], &tabs, &workspaces)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	if !testing.expect_value(t, commands.register(&registry, {id = 3, name = "app.aio", title = "aio command"}),
		commands.Error.None) {return}

	expect := [?]struct {
		mode:  ui.Palette_Mode,
		kinds: []ui.Palette_Kind,
		names: []string,
	}{
		{.Tabs, []ui.Palette_Kind{.Tab, .Tab}, []string{"aio", "aio docs"}},
		{.Workspaces, []ui.Palette_Kind{.Workspace}, []string{"aio workspace"}},
		{.Settings, []ui.Palette_Kind{.Setting}, []string{"aio.key"}},
		{.Commands, []ui.Palette_Kind{.Command}, []string{"app.aio"}},
	}
	for c in expect {
		ui.palette_open_mode(&p, &registry, c.mode)
		ui.palette_text(&p, &registry, "aio")
		testing.expect_value(t, len(p.results), len(c.kinds))
		kinds := mode_kinds(&p)
		names := mode_names(&p)
		for kind, i in c.kinds {testing.expect_value(t, kinds[i], kind)}
		for name, i in c.names {testing.expect_value(t, names[i], name)}
	}

	ui.palette_open_mode(&p, &registry, .All)
	ui.palette_text(&p, &registry, "aio")
	// Tabs have the exact match; commands and workspaces share a prefix; the setting is a
	// substring. The fixed order breaks the command/workspace tie.
	testing.expect_value(t, len(p.results), 5)
	want := []ui.Palette_Kind{.Tab, .Tab, .Command, .Workspace, .Setting}
	kinds := mode_kinds(&p)
	for kind, i in want {testing.expect_value(t, kinds[i], kind)}
}

@(test)
palette_all_mode_without_a_query_keeps_commands_first :: proc(t: ^testing.T) {
	tabs := Mode_Source{items = []ui.Palette_Item{{"AIODev", "pwsh", "Workspace 1", 1}}}
	workspaces := Mode_Source{items = []ui.Palette_Item{{"Workspace 1", "pwsh", "", 10}}}
	rows := [?]ui.Palette_Setting{{key = "pane.gap", title = "Pane Gap", group = "Panes"}}
	p: ui.Palette
	registry := mode_palette(t, &p, rows[:], &tabs, &workspaces)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	if !testing.expect_value(t, commands.register(&registry, {id = 4, name = "app.quit", title = "Quit"}),
		commands.Error.None) {return}
	ui.palette_open_mode(&p, &registry, .All)
	testing.expect_value(t, len(p.results), 4)
	kinds := mode_kinds(&p)
	want := []ui.Palette_Kind{.Command, .Setting, .Tab, .Workspace}
	for kind, i in want {testing.expect_value(t, kinds[i], kind)}
}

@(test)
palette_duplicate_names_keep_tab_and_workspace_identity :: proc(t: ^testing.T) {
	tabs := Mode_Source{items = []ui.Palette_Item{{"AIODev", "pwsh", "Workspace 2", 7}}}
	workspaces := Mode_Source{items = []ui.Palette_Item{{"AIODev", "pwsh", "", 9}}}
	p: ui.Palette
	registry := mode_palette(t, &p, nil, &tabs, &workspaces)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &registry, .All)
	ui.palette_text(&p, &registry, "aiodev")
	if !testing.expect_value(t, len(p.results), 2) {return}
	testing.expect_value(t, p.results[0].kind, ui.Palette_Kind.Tab)
	testing.expect_value(t, p.results[1].kind, ui.Palette_Kind.Workspace)
	tab := ui.palette_target(&p, p.results[0])
	workspace := ui.palette_target(&p, p.results[1])
	testing.expect_value(t, tab.kind, ui.Palette_Kind.Tab)
	testing.expect_value(t, tab.id, u64(7))
	testing.expect_value(t, workspace.kind, ui.Palette_Kind.Workspace)
	testing.expect_value(t, workspace.id, u64(9))
	// The shared title is the only reason either row names its kind.
	testing.expect(t, ui.palette_title_collides(&p, 0))
	testing.expect(t, ui.palette_title_collides(&p, 1))
	testing.expect_value(t, ui.palette_result_context(&p, p.results[0]), "Workspace 2")
	testing.expect_value(t, ui.palette_result_context(&p, p.results[1]), "")
	ui.palette_text(&p, &registry, " ")
	testing.expect_value(t, len(p.results), 0)
}

@(test)
palette_ranking_is_exact_prefix_substring_then_natural_order :: proc(t: ^testing.T) {
	tabs := Mode_Source {
		items = []ui.Palette_Item {
			{"aio", "pwsh", "", 1},
			{"AIO", "pwsh", "", 2},
			{"aio docs", "pwsh", "", 3},
			{"my aio", "pwsh", "", 4},
			{"notes", "aio", "", 5},
		},
	}
	p: ui.Palette
	registry := mode_palette(t, &p, nil, &tabs, nil)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &registry, .Tabs)
	ui.palette_text(&p, &registry, "aio")
	names := mode_names(&p)
	if !testing.expect_value(t, len(names), 5) {return}
	// The two case-insensitive exact matches keep their natural order, then the prefix,
	// the substring, and finally the process-title match.
	testing.expect_value(t, names[0], "aio")
	testing.expect_value(t, names[1], "AIO")
	testing.expect_value(t, names[2], "aio docs")
	testing.expect_value(t, names[3], "my aio")
	testing.expect_value(t, names[4], "notes")
	testing.expect(t, !p.results[4].title_match)

	// Tab and workspace ranking is exact, prefix, or substring only; a fuzzy subsequence
	// of a long process title is not a match.
	ui.palette_text(&p, &registry, "nws")
	testing.expect_value(t, len(p.results), 0)
}

@(test)
palette_workspace_query_returns_every_owned_tab_in_all_and_tabs_modes :: proc(t: ^testing.T) {
	tabs := Mode_Source {
		items = []ui.Palette_Item {
			{"Editor", "nvim", "main", 1},
			{"Shell", "pwsh", "main", 2},
			{"Logs", "tail", "main", 3},
			{"Other", "pwsh", "work", 4},
		},
	}
	p: ui.Palette
	registry := mode_palette(t, &p, nil, &tabs, nil)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	for query in ([?]string{"main", "MAIN", "mai", "ain"}) {
		for mode in ([?]ui.Palette_Mode{.Tabs, .All}) {
			ui.palette_open_mode(&p, &registry, mode)
			ui.palette_text(&p, &registry, query)
			if !testing.expect_value(t, len(p.results), 3) {continue}
			for result, i in p.results {
				testing.expect_value(t, result.kind, ui.Palette_Kind.Tab)
				testing.expect_value(t, ui.palette_target(&p, result).id, u64(i + 1))
				testing.expect_value(t, ui.palette_result_context(&p, result), "main")
				testing.expect(t, !result.title_match)
				testing.expect_value(t, len(result.positions), 0)
			}
		}
	}
	// Workspace names use the same literal match classes as tab and process titles.
	ui.palette_open_mode(&p, &registry, .Tabs)
	ui.palette_text(&p, &registry, "mn")
	testing.expect_value(t, len(p.results), 0)
}

@(test)
palette_tab_title_and_process_matches_rank_before_workspace_matches :: proc(t: ^testing.T) {
	tabs := Mode_Source {
		items = []ui.Palette_Item {
			{"Editor", "nvim", "main", 1},
			{"Shell", "main", "work", 2},
			{"main", "pwsh", "work", 3},
			{"Logs", "tail", "main", 4},
		},
	}
	p: ui.Palette
	registry := mode_palette(t, &p, nil, &tabs, nil)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &registry, .Tabs)
	ui.palette_text(&p, &registry, "main")
	if !testing.expect_value(t, len(p.results), 4) {return}
	for id, i in ([?]u64{3, 2, 1, 4}) {
		testing.expect_value(t, ui.palette_target(&p, p.results[i]).id, id)
		testing.expect_value(t, p.results[i].title_match, i == 0)
	}
}

@(test)
palette_settings_match_label_before_key :: proc(t: ^testing.T) {
	rows := [?]ui.Palette_Setting {
		{key = "aio.key", title = "Unrelated", group = "Panes"},
		{key = "other.key", title = "AIO label", group = "Panes"},
	}
	p: ui.Palette
	registry := mode_palette(t, &p, rows[:], nil, nil)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &registry, .Settings)
	ui.palette_text(&p, &registry, "aio")
	if !testing.expect_value(t, len(p.results), 2) {return}
	testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "other.key")
	testing.expect(t, p.results[0].title_match)
	testing.expect_value(t, ui.palette_result_name(&p, p.results[1]), "aio.key")
	testing.expect(t, !p.results[1].title_match)
}

@(test)
palette_activation_targets_carry_identity_and_kind :: proc(t: ^testing.T) {
	tabs := Mode_Source{items = []ui.Palette_Item{{"AIODev", "pwsh", "", 7}}}
	workspaces := Mode_Source{items = []ui.Palette_Item{{"AIODev", "pwsh", "", 9}}}
	rows := [?]ui.Palette_Setting{{key = "pane.gap", title = "Pane Gap", group = "Panes"}}
	p: ui.Palette
	registry := mode_palette(t, &p, rows[:], &tabs, &workspaces)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	if !testing.expect_value(t, commands.register(&registry, {id = 5, name = "app.quit", title = "Quit"}),
		commands.Error.None) {return}

	ui.palette_open_mode(&p, &registry, .Commands)
	ui.palette_text(&p, &registry, "quit")
	target := ui.palette_target(&p, p.results[0])
	testing.expect_value(t, target.kind, ui.Palette_Kind.Command)
	testing.expect_value(t, target.command, commands.Command_Id(5))

	ui.palette_open_mode(&p, &registry, .Settings)
	ui.palette_text(&p, &registry, "gap")
	target = ui.palette_target(&p, p.results[0])
	testing.expect_value(t, target.kind, ui.Palette_Kind.Setting)
	testing.expect_value(t, target.setting, "pane.gap")

	ui.palette_open_mode(&p, &registry, .All)
	ui.palette_text(&p, &registry, "aiodev")
	target = ui.palette_target(&p, p.results[0])
	testing.expect_value(t, target.kind, ui.Palette_Kind.Tab)
	testing.expect_value(t, target.id, u64(7))
	target = ui.palette_target(&p, p.results[1])
	testing.expect_value(t, target.kind, ui.Palette_Kind.Workspace)
	testing.expect_value(t, target.id, u64(9))
}

@(test)
palette_scope_tabs_preserve_the_query_and_caret :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	for scale in ([?]f32{1, 1.5, 2}) {
		ui.palette_open(&p, &registry)
		ui.palette_text(&p, &registry, "pane")
		p.query.cursor, p.query.anchor = 2, 1
		for mode in ([?]ui.Palette_Mode{.Tabs, .Workspaces, .Settings, .Commands, .All}) {
			l := ui.palette_layout(&p, 560 * scale, 700 * scale, scale)
			r := l.modes[mode]
			x, y := r.x + r.width / 2, r.y + r.height / 2
			testing.expect(t, !ui.palette_input_contains(l, x, y))
			testing.expect_value(t, ui.palette_pointer(&p, l, x, y), platform.Cursor_Shape.Hand)
			before := p.mode
			ui.palette_mouse_move(&p, l, x, y)
			testing.expect_value(t, p.mode, before)
			p.drag = ui.Query_Drag{}
			outcome, id := ui.palette_mouse_press(&p, &registry, l, x, y)
			testing.expect_value(t, outcome, ui.Outcome.Changed)
			testing.expect_value(t, id, commands.Command_Id(0))
			testing.expect_value(t, p.mode, mode)
			testing.expect_value(t, ui.palette_query(&p), "pane")
			testing.expect_value(t, p.query.cursor, 2)
			testing.expect_value(t, p.query.anchor, 1)
			testing.expect(t, p.drag == nil && ui.presence_is_open(p.presence))
			testing.expect_value(t, p.selected, 0)
			testing.expect_value(t, p.scroll, 0)
		}
		l := ui.palette_layout(&p, 560 * scale, 700 * scale, scale)
		ui.palette_mouse_press(&p, &registry, l, l.footer.x + 20, l.footer.y + l.footer.height / 2)
		testing.expect_value(t, p.mode, ui.Palette_Mode.All)
	}
}

@(test)
palette_scope_tabs_cancel_an_unapplied_setting_edit :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	rows := [?]ui.Palette_Setting{{key = "font.family", title = "Font", control = .Text}}
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &registry, .Settings)
	ui.palette_text(&p, &registry, "font")
	ui.palette_key(&p, &registry, key({key = .Enter, modifiers = {.Control}}))
	ui.palette_text(&p, &registry, "Unapplied font")
	if !testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Text) {return}
	l := ui.palette_layout(&p, 1000, 800, 1)
	r := l.modes[.Commands]
	outcome, _ := ui.palette_mouse_press(&p, &registry, l, r.x + r.width / 2, r.y + r.height / 2)
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.None)
	testing.expect_value(t, ui.palette_query(&p), "font")
	testing.expect_value(t, p.mode, ui.Palette_Mode.Commands)
	testing.expect(t, ui.palette_chosen_take(&p) == nil)
}

@(test)
palette_opens_in_all_and_mode_bindings_do_not_persist :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, nil), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &registry, .Settings)
	testing.expect_value(t, p.mode, ui.Palette_Mode.Settings)
	ui.palette_close(&p)
	ui.palette_open(&p, &registry)
	testing.expect_value(t, p.mode, ui.Palette_Mode.All)
	testing.expect_value(t, ui.palette_query(&p), "")
	testing.expect(t, strings.has_prefix(
		ui.palette_mode_info(ui.Palette_Mode.All).placeholder,
		"Search",
	))
}

@(test)
palette_scope_and_query_never_overlap :: proc(t: ^testing.T) {
	p: ui.Palette
	registry := mode_palette(t, &p, nil, nil, nil)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	text: ui.Text
	for scale in ([?]f32{1, 1.5, 2}) {
		for mode in ([?]ui.Palette_Mode{.Tabs, .Workspaces, .Settings, .Commands}) {
			ui.palette_open_mode(&p, &registry, mode)
			for width in ([?]f32{240, 560, 1200}) {
				l := ui.palette_layout(&p, width * scale, 700 * scale, scale)
				box := ui.palette_query_box(&p, l, &text, scale)
				r := ui.field_box_text_rect(box)
				testing.expect(t, r.y >= l.mode_bar.y + l.mode_bar.height)
				testing.expect(t, r.x >= l.input.x + (ui.DIALOG_PADDING + ui.ICON_BUTTON + ui.SPACE_3) * scale)
				testing.expect(t, r.x + r.width <= l.input.x + l.input.width - 14 * scale)
			}
		}
	}
}

@(private)
hint_labels :: proc(p: ^ui.Palette) -> []string {
	hints: [6]ui.Palette_Key_Hint
	count := ui.palette_key_hints(p, &hints)
	labels := make([]string, count, context.temp_allocator)
	for hint, i in hints[:count] {labels[i] = hint.label}
	return labels
}

@(private)
expect_hints :: proc(t: ^testing.T, p: ^ui.Palette, want: []string, loc := #caller_location) {
	got := hint_labels(p)
	if !testing.expect_value(t, len(got), len(want), loc) {return}
	for label, i in want {testing.expect_value(t, got[i], label, loc)}
}

@(test)
palette_footer_states_only_the_selected_results_keys :: proc(t: ^testing.T) {
	tabs := Mode_Source{items = []ui.Palette_Item{{"gap notes", "pwsh", "Workspace 1", 1}}}
	workspaces := Mode_Source{items = []ui.Palette_Item{{"gap work", "pwsh", "", 10}}}
	rows := [?]ui.Palette_Setting {
		{key = "pane.gap", title = "Gap Size", group = "Panes", control = .Slider, minimum = 0, maximum = 24, step = 1},
		{key = "pane.gap_name", title = "Gap Name", group = "Panes", control = .Text},
		{key = "pane.gap_note", title = "Gap Note", group = "Panes"},
	}
	p: ui.Palette
	registry := mode_palette(t, &p, rows[:], &tabs, &workspaces)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)
	if !testing.expect_value(t, commands.register(&registry, {id = 3, name = "pane.gap_reset", title = "Gap Reset"}),
		commands.Error.None) {return}
	ui.palette_open_mode(&p, &registry, .Commands)
	ui.palette_text(&p, &registry, "gap")
	expect_hints(t, &p, {"Navigate", "Run command", "Edit shortcut", "Search by keys", "Close"})
	ui.palette_set_mode(&p, &registry, .Settings)
	expect_hints(t, &p, {"Navigate", "Go to setting", "Change", "Adjust", "Search by keys", "Close"})
	ui.palette_key(&p, &registry, key({key = .N, modifiers = {.Control}}))
	// Typed values have no step, so Alt+arrows are not offered.
	expect_hints(t, &p, {"Navigate", "Go to setting", "Change", "Search by keys", "Close"})
	ui.palette_key(&p, &registry, key({key = .N, modifiers = {.Control}}))
	expect_hints(t, &p, {"Navigate", "Go to setting", "Search by keys", "Close"})
	ui.palette_set_mode(&p, &registry, .Tabs)
	expect_hints(t, &p, {"Navigate", "Switch tab", "Search by keys", "Close"})
	ui.palette_set_mode(&p, &registry, .Workspaces)
	expect_hints(t, &p, {"Navigate", "Switch workspace", "Search by keys", "Close"})
	ui.palette_text(&p, &registry, "zzz")
	expect_hints(t, &p, {"Search by keys", "Close"})
	ui.palette_set_mode(&p, &registry, .Commands)
	ui.palette_key(&p, &registry, key({key = .K, modifiers = {.Alt}}))
	expect_hints(t, &p, {"Clear", "Search by text"})
	ui.palette_key(&p, &registry, key({key = .Escape}))
	expect_hints(t, &p, {"Search by keys", "Close"})
}

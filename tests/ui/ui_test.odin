package ui_test

import "core:testing"
import "core:time"
import "aio:commands"
import "aio:font"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"

registry_create :: proc(t: ^testing.T) -> commands.Registry {
	r := commands.create()
	items := [?]commands.Command{
		{id = 1, name = "app.quit", title = "Quit AIODev"},
		{id = 2, name = "terminal.restart_shell", title = "Restart Shell"},
		{id = 3, name = "settings.reload", title = "Reload Settings"},
		{id = 4, name = "edit.copy", title = "Copy", shortcuts = {{0 = {.C, {.Control, .Shift}}}, 1}},
	}
	for item in items {
		testing.expect_value(t, commands.register(&r, item), commands.Error.None)
	}
	return r
}

palette_settings := [?]ui.Palette_Setting{
	{"pane.gap", "Pane Gap", "Panes"},
	{"pane.show_headers", "Show Pane Headers", "Panes"},
	{"font.size", "Font Size", "Font"},
	{"terminal.copy_on_select", "Copy on Select", "Terminal"},
}

key :: proc(k: platform.Key_Event) -> platform.Key_Event {
	e := k
	e.pressed = true
	return e
}

@(test)
palette_filters_navigates_and_runs :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, nil), nil)
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	testing.expect(t, p.open)
	testing.expect_value(t, len(p.results), 4)
	outcome, _ := ui.palette_key(&p, &registry, key({key = .R, text = "r"}))
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	outcome, _ = ui.palette_key(&p, &registry, key({key = .S, text = "s"}))
	testing.expect_value(t, ui.palette_query(&p), "rs")
	testing.expect_value(t, len(p.results), 2)
	testing.expect_value(t, p.results[0].command.id, commands.Command_Id(2))
	outcome, _ = ui.palette_key(&p, &registry, key({key = .Arrow_Down}))
	testing.expect_value(t, p.selected, 1)
	outcome, _ = ui.palette_key(&p, &registry, key({key = .Arrow_Down}))
	testing.expect_value(t, p.selected, 1)
	outcome, _ = ui.palette_key(&p, &registry, key({key = .Backspace}))
	testing.expect_value(t, ui.palette_query(&p), "r")
	ui.palette_key(&p, &registry, key({key = .Home}))
	expected := p.results[0].command.id
	ran, id := ui.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, ran, ui.Outcome.Run)
	testing.expect_value(t, id, expected)
	testing.expect(t, !p.open)
}

@(test)
palette_text_editing_and_close :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, nil), nil)
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	testing.expect_value(t, ui.palette_text(&p, &registry, "re\x01load set"), ui.Outcome.Changed)
	testing.expect_value(t, ui.palette_query(&p), "reload set")
	ui.palette_key(&p, &registry, key({key = .Backspace, modifiers = {.Control}}))
	testing.expect_value(t, ui.palette_query(&p), "reload ")
	ignored, _ := ui.palette_key(&p, &registry, key({key = .V, modifiers = {.Control}, text = "\x16"}))
	testing.expect_value(t, ignored, ui.Outcome.None)
	testing.expect_value(t, ui.palette_text(&p, &registry, "zzzz"), ui.Outcome.Changed)
	testing.expect_value(t, len(p.results), 0)
	run, _ := ui.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, run, ui.Outcome.None)
	closed, _ := ui.palette_key(&p, &registry, key({key = .Escape}))
	testing.expect_value(t, closed, ui.Outcome.Closed)
	testing.expect(t, !p.open)
}

@(test)
palette_mouse_selects_and_dismisses :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, nil), nil)
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	l := ui.palette_layout(&p, 1000, 800, 1)
	second_row := l.list.y + l.row_height * 1.5
	testing.expect_value(t, ui.palette_mouse_move(&p, l, l.list.x + 10, second_row), ui.Outcome.Changed)
	testing.expect_value(t, p.selected, 1)
	expected := p.results[1].command.id
	outcome, id := ui.palette_mouse_press(&p, l, l.list.x + 10, second_row)
	testing.expect_value(t, outcome, ui.Outcome.Run)
	testing.expect_value(t, id, expected)
	ui.palette_open(&p, &registry)
	outside, _ := ui.palette_mouse_press(&p, l, 2, 2)
	testing.expect_value(t, outside, ui.Outcome.Closed)
}

@(test)
notices_replace_expire_and_report_deadlines :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	ui.notices_put(&n, 7, .Info, "first", 0)
	ui.notices_put(&n, 7, .Error, "replaced", 0)
	ui.notices_put(&n, 0, .Info, "transient", time.Millisecond)
	testing.expect_value(t, len(n.items), 2)
	testing.expect_value(t, n.items[0].text, "replaced")
	deadline, found := ui.notices_deadline(&n)
	testing.expect(t, found)
	testing.expect(t, !ui.notices_expire(&n, time.tick_add(deadline, -time.Millisecond)))
	testing.expect(t, ui.notices_expire(&n, time.tick_add(deadline, time.Millisecond)))
	testing.expect_value(t, len(n.items), 1)
	_, any := ui.notices_deadline(&n)
	testing.expect(t, !any)
	testing.expect(t, ui.notices_clear(&n, 7))
	testing.expect(t, !ui.notices_clear(&n, 7))
}

@(test)
text_measures_and_wraps :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) {
		return
	}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) {
		return
	}
	testing.expect(t, text.line_height > text.ascent && text.ascent > 0)
	word := ui.text_width(&text, "word")
	testing.expect(t, word > 0)
	testing.expect(t, ui.text_width(&text, "word word") > 2 * word)
	lines := make([dynamic]string)
	defer delete(lines)
	ui.wrap(&text, "word word word word", word * 2.5, &lines)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0], "word word")
	testing.expect_value(t, lines[1], "word word")
	ui.wrap(&text, "unbreakablelongword", word, &lines)
	testing.expect(t, len(lines) > 1)
}

@(test)
find_bar_edits_query_and_navigates :: proc(t: ^testing.T) {
	f: ui.Find_Bar
	ui.find_init(&f)
	defer ui.find_destroy(&f)
	Outcome :: ui.Find_Outcome
	ui.find_open(&f)
	testing.expect(t, f.open)
	testing.expect_value(t, ui.find_key(&f, key({key = .E, text = "e"})), Outcome.Changed)
	testing.expect_value(t, ui.find_text(&f, "rr or"), Outcome.Changed)
	testing.expect_value(t, ui.find_text(&f, "\x1b"), Outcome.None)
	testing.expect_value(t, ui.field_string(&f.query), "err or")
	control_a := key({key = .A, text = "\x01", modifiers = {.Control}})
	testing.expect_value(t, ui.find_key(&f, control_a), Outcome.Moved)
	testing.expect_value(t, ui.field_selected_text(&f.query), "err or")
	testing.expect_value(t, ui.find_key(&f, key({key = .End})), Outcome.Moved)
	testing.expect_value(t, ui.find_key(&f, key({key = .Backspace, modifiers = {.Control}})), Outcome.Changed)
	testing.expect_value(t, ui.field_string(&f.query), "err ")
	testing.expect_value(t, ui.find_key(&f, key({key = .Backspace})), Outcome.Changed)
	testing.expect_value(t, ui.field_string(&f.query), "err")
	testing.expect_value(t, ui.find_key(&f, key({key = .Enter, text = "\r"})), Outcome.Older)
	shift_enter := key({key = .Enter, text = "\r", modifiers = {.Shift}})
	testing.expect_value(t, ui.find_key(&f, shift_enter), Outcome.Newer)
	testing.expect_value(t, ui.find_key(&f, key({key = .Arrow_Up})), Outcome.Older)
	testing.expect_value(t, ui.find_key(&f, key({key = .Arrow_Down})), Outcome.Newer)
	testing.expect_value(t, ui.find_key(&f, {key = .Escape}), Outcome.None)
	testing.expect(t, f.open)
	testing.expect_value(t, ui.find_key(&f, key({key = .Escape})), Outcome.Closed)
	testing.expect(t, !f.open)
	testing.expect_value(t, len(f.query.bytes), 0)
	r := ui.find_layout(1000, 1.5)
	testing.expect_value(t, r, render.Rect{1000 - 18 - 570, 18, 570, 60})
	testing.expect(t, ui.find_contains(1000, 1.5, 413, 19))
	testing.expect(t, !ui.find_contains(1000, 1.5, 411, 19))
	testing.expect_value(t, ui.find_layout(100, 1).width, 76)
}

@(test)
tab_bar_visibility_and_controls_in_narrow_windows :: proc(t: ^testing.T) {
	single := ui.tab_bar_layout(1000, 1, 1, false)
	testing.expect_value(t, single.height, f32(0))
	testing.expect_value(t, ui.tab_bar_hit_test(single, 1, 1), -1)
	shown := ui.tab_bar_layout(1000, 1, 1, true)
	testing.expect_value(t, shown.height, f32(40))
	testing.expect_value(t, ui.tab_bar_hit_test(shown, 1, 1), 0)
	testing.expect_value(t, ui.tab_bar_hit_test(shown, 225, 1), 1)
	testing.expect_value(t, ui.tab_bar_layout(1000, 1, 0, true), ui.Tab_Bar{})
	testing.expect_value(t, ui.tab_bar_layout(500, 2, 3, true), ui.tab_bar_layout(500, 2, 3, false))
	bar := ui.tab_bar_layout(500, 2, 3, false)
	testing.expect_value(t, bar.height, f32(80))
	testing.expect_value(t, ui.tab_bar_hit_test(bar, 0, 0), 0)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.tab_width, 10), 1)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.tab_width*3, 10), 3)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, 500, 10), -1)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, 10, 80), -1)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, -1, 10), -1)
	narrow := ui.tab_bar_layout(20, 1, 10, true)
	testing.expect_value(t, ui.tab_bar_hit_test(narrow, 1, 1), 10)
}

@(test)
tab_close_targets_and_caption_buttons_are_distinct :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		bar := ui.tab_bar_layout(900*scale, scale, 3, true)
		for i in 0..<bar.count {
			r := ui.tab_close_rect(bar, i, scale)
			testing.expect_value(t, ui.tab_close_hit(bar, r.x+r.width/2, r.y+r.height/2, scale), i)
			testing.expect_value(t, ui.tab_close_hit(bar, f32(i)*bar.tab_width+10*scale, 20*scale, scale), -1)
		}
		testing.expect_value(t, ui.tab_close_hit(bar, 670*scale, 20*scale, scale), -1)
		for i in 0..<3 {
			testing.expect_value(t, ui.caption_hit(1200*scale, (1085+f32(i)*46)*scale, 20*scale, scale), i)
		}
		testing.expect_value(t, ui.caption_hit(1200*scale, 300*scale, 20*scale, scale), -1)
	}
}

@(test)
leader_status_line_stays_inside_the_focused_card :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		for size in ([?][2]f32{{400, 300}, {160, 90}, {12, 8}, {0, 0}}) {
			area := render.Rect{30*scale, 70*scale, size.x*scale, size.y*scale}
			r := ui.leader_status_layout(area, 240*scale, scale)
			testing.expect(t, r.x >= area.x && r.y >= area.y && r.width >= 0 && r.height >= 0)
			testing.expect(t, r.x+r.width <= area.x+area.width && r.y+r.height <= area.y+area.height)
		}
	}
}

@(test)
palette_matches_settings_groups_and_navigates_with_control_keys :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	testing.expect_value(t, commands.register(&registry, {id = 5, name = "pane.split_right", title = "Split Right"}),
		commands.Error.None)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, palette_settings[:]), nil)
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	testing.expect_value(t, len(p.results), 5)
	for r in p.results { testing.expect(t, r.command != nil) }
	ui.palette_text(&p, &registry, "panes")
	names := make([dynamic]string, context.temp_allocator)
	for r in p.results { append(&names, ui.palette_result_name(&p, r)) }
	testing.expect_value(t, len(names), 3)
	testing.expect_value(t, names[0], "pane.show_headers")
	testing.expect(t, p.results[0].positions != nil)
	testing.expect_value(t, names[1], "pane.split_right")
	testing.expect_value(t, names[2], "pane.gap")
	testing.expect(t, p.results[2].positions == nil)
	ui.palette_key(&p, &registry, key({key = .N, modifiers = {.Control}}))
	testing.expect_value(t, p.selected, 1)
	ui.palette_key(&p, &registry, key({key = .N, modifiers = {.Control}}))
	ui.palette_key(&p, &registry, key({key = .N, modifiers = {.Control}}))
	testing.expect_value(t, p.selected, 2)
	ui.palette_key(&p, &registry, key({key = .P, modifiers = {.Control}}))
	ui.palette_key(&p, &registry, key({key = .P, modifiers = {.Control}}))
	testing.expect_value(t, p.selected, 0)
	ui.palette_key(&p, &registry, key({key = .End}))
	testing.expect_value(t, ui.palette_query(&p), "panes")
	outcome, _ := ui.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, outcome, ui.Outcome.Open_Setting)
	testing.expect_value(t, p.chosen, "pane.gap")
	testing.expect(t, !p.open)

	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "font si")
	testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "font.size")
	selected, _ := ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}, text = "\x01"}))
	testing.expect_value(t, selected, ui.Outcome.Changed)
	testing.expect_value(t, ui.palette_selection(&p), "font si")
	ui.palette_key(&p, &registry, key({key = .Backspace}))
	testing.expect_value(t, ui.palette_query(&p), "")
	testing.expect_value(t, len(p.results), 5)
	ui.palette_paste(&p, &registry, "quit\nsecond line")
	testing.expect_value(t, ui.palette_query(&p), "quit")
	ui.palette_key(&p, &registry, key({key = .Arrow_Left, modifiers = {.Shift}}))
	ui.palette_key(&p, &registry, key({key = .Arrow_Left, modifiers = {.Shift}}))
	testing.expect_value(t, ui.palette_selection(&p), "it")
	testing.expect_value(t, ui.palette_cut(&p, &registry), ui.Outcome.Changed)
	testing.expect_value(t, ui.palette_query(&p), "qu")
	ui.palette_key(&p, &registry, key({key = .Arrow_Left, modifiers = {.Control}}))
	ui.palette_text(&p, &registry, "x")
	testing.expect_value(t, ui.palette_query(&p), "xqu")
}

@(test)
palette_fuzzy_matches_titles_and_groups_with_highlights :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, palette_settings[:]), nil)
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "term")
	names := make([dynamic]string, context.temp_allocator)
	for r in p.results { append(&names, ui.palette_result_name(&p, r)) }
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "terminal.restart_shell")
	testing.expect_value(t, names[1], "terminal.copy_on_select")
	for query in ([?]string{"settin", "setting", "settings"}) {
		ui.palette_open(&p, &registry)
		ui.palette_text(&p, &registry, query)
		testing.expectf(t, len(p.results) == 1, "%s matched %d", query, len(p.results))
		if len(p.results) == 1 {
			testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "settings.reload")
			testing.expectf(t, len(p.results[0].positions) == len(query), "%s lost its highlights", query)
		}
	}
}

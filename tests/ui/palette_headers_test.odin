package ui_test

import "core:strings"
import "core:testing"
import "aio:commands"
import "aio:settings"
import "aio:ui"

@(test)
palette_matches_real_setting_headers :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]ui.Palette_Setting
	for entry, i in settings.SCHEMA {
		rows[i] = {entry.key, entry.title, settings.group_title(entry.key)}
	}
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) { return }
	defer ui.palette_destroy(&p)
	for query in ([?]string{"terminal setting", "terminal settings", "TeRmInAl SeTtInG", "trm sttng"}) {
		ui.palette_open(&p, &registry)
		ui.palette_text(&p, &registry, query)
		testing.expectf(t, len(p.results) == 3, "%s matched %d instead of 3 Terminal settings", query,
			len(p.results))
		index := 0
		for row in rows {
			if row.group != "Terminal" { continue }
			if index < len(p.results) {
				r := p.results[index]
				testing.expect_value(t, ui.palette_result_name(&p, r), row.key)
				testing.expect(t, !r.title_match && len(r.positions) == 0)
			}
			index += 1
		}
	}
	for query in ([?]string{"pane setting", "panes settings", "font setting", "font settings"}) {
		ui.palette_open(&p, &registry)
		ui.palette_text(&p, &registry, query)
		group := strings.has_prefix(query, "pane") ? "Panes" : "Font"
		expected := 0
		for row in rows { if row.group == group { expected += 1 } }
		testing.expect_value(t, len(p.results), expected)
		for r in p.results {
			if testing.expect(t, r.command == nil) {
				testing.expect_value(t, rows[r.setting].group, group)
			}
		}
	}
	for query in ([?]string{"terminal setting contrast", "terminal settings contrast", "terminal contrast"}) {
		ui.palette_open(&p, &registry)
		ui.palette_text(&p, &registry, query)
		if !testing.expect_value(t, len(p.results), 1) { continue }
		r := p.results[0]
		testing.expect_value(t, ui.palette_result_name(&p, r), "terminal.minimum_contrast")
		testing.expect(t, !r.title_match)
		title := ui.palette_result_title(&p, r)
		if testing.expect(t, len(r.positions) >= len("contrast")) {
			for pos, i in r.positions[len(r.positions)-len("contrast"):] {
				testing.expect_value(t, pos, len("Minimum Text ")+i)
				testing.expect(t, pos >= 0 && pos < len(title))
			}
			for pos in r.positions[:len(r.positions)-len("contrast")] {
				testing.expect_value(t, title[pos], u8(' '))
			}
		}
	}
	for query in ([?]string{"terminal settings zzz", "zzzz setting"}) {
		ui.palette_open(&p, &registry)
		ui.palette_text(&p, &registry, query)
		testing.expect_value(t, len(p.results), 0)
	}
}

@(test)
palette_header_results_keep_title_priority_and_query_navigation :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	testing.expect_value(t, commands.register(&registry,
		{id = 5, name = "terminal.setting", title = "Terminal Setting"}), commands.Error.None)
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, palette_settings[:]), nil) { return }
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "terminal setting")
	if !testing.expect_value(t, len(p.results), 2) { return }
	testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "terminal.setting")
	testing.expect(t, p.results[0].title_match)
	for pos, i in p.results[0].positions { testing.expect_value(t, pos, i) }
	testing.expect_value(t, len(p.results[0].positions), len("terminal setting"))
	testing.expect_value(t, ui.palette_result_name(&p, p.results[1]), "terminal.copy_on_select")
	testing.expect(t, !p.results[1].title_match && len(p.results[1].positions) == 0)
	ui.palette_key(&p, &registry, key({key = .N, modifiers = {.Control}}))
	testing.expect_value(t, p.selected, 1)
	ui.palette_key(&p, &registry, key({key = .P, modifiers = {.Control}}))
	testing.expect_value(t, p.selected, 0)
	ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	testing.expect_value(t, ui.palette_selection(&p), "terminal setting")
	ui.palette_text(&p, &registry, "terminal settings copy")
	testing.expect_value(t, p.selected, 0)
	if !testing.expect_value(t, len(p.results), 1) { return }
	outcome, _ := ui.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, outcome, ui.Outcome.Open_Setting)
	testing.expect_value(t, p.chosen, "terminal.copy_on_select")
	testing.expect(t, !p.open)
}

@(test)
palette_header_title_positions_use_title_utf8_offsets :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	rows := [?]ui.Palette_Setting{{"test", "Café Size", "Thème"}}
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) { return }
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "thème settings café")
	if !testing.expect_value(t, len(p.results), 1) { return }
	positions := p.results[0].positions
	if !testing.expect_value(t, len(positions), 4) { return }
	for pos, i in positions { testing.expect_value(t, pos, i) }
	ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	ui.palette_text(&p, &registry, "thème setting size")
	if !testing.expect_value(t, len(p.results), 1) { return }
	positions = p.results[0].positions
	if !testing.expect(t, len(positions) >= 4) { return }
	for pos, i in positions[len(positions)-4:] { testing.expect_value(t, pos, len("Café ")+i) }
	for pos in positions[:len(positions)-4] { testing.expect_value(t, rows[0].title[pos], u8(' ')) }
}

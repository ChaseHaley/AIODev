package ui_test

import "core:testing"
import "base:runtime"
import "aio:commands"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:settings"
import "aio:ui"

@(test)
palette_header_flood_fits_measured_narrow_viewport :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]ui.Palette_Setting
	for entry, i in settings.SCHEMA {
		rows[i] = {entry.key, entry.title, settings.group_title(entry.key)}
	}
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) { return }
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "setting")
	testing.expect(t, len(p.results) > 8)
	l := ui.palette_layout(&p, 926, 928, 2)
	testing.expectf(t, l.panel.y+l.panel.height+2 <= 928, "panel bottom %g exceeds client height 928",
		l.panel.y+l.panel.height+2)
	testing.expectf(t, l.list.y+l.list.height <= 928, "last result bottom %g exceeds client height 928",
		l.list.y+l.list.height)
}

@(test)
palette_fit_renders_final_selection_inside_client :: proc(t: ^testing.T) {
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) { return }
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 32)) { return }
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]ui.Palette_Setting
	for entry, i in settings.SCHEMA { rows[i] = {entry.key, entry.title, settings.group_title(entry.key)} }
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) { return }
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "setting")
	for viewport in ([?][3]f32{{926, 928, 2}, {695, 696, 1.5}}) {
		w, h, scale := viewport[0], viewport[1], viewport[2]
		surface, surface_error := render.surface_create_offscreen(device, i32(w), i32(h))
		if !testing.expect_value(t, surface_error, render.Error.None) { return }
		defer render.surface_destroy(surface)
		ui.text_set_size(&text, 16*scale)
		ui.palette_layout(&p, w, h, scale)
		ui.palette_key(&p, &registry, key({key = .End}))
		testing.expect_value(t, p.selected, len(p.results)-1)
		for mode in settings.Theme_Mode {
			theme := ui.theme_from(settings.theme_resolve({.Studio, mode}))
			theme.selection = {1, 0, 0, 1}
			render.draw_list_reset(&list)
			testing.expect_value(t, ui.palette_draw(&p, &list, &text, theme, w, h, scale), glyphs.Result.Ok)
			selection: render.Rect
			count := 0
			for instance in list.rects {
				if instance.color != theme.selection { continue }
				selection = instance.rect
				count += 1
			}
			testing.expect_value(t, count, 1)
			inside := selection.y >= 0 && selection.y+selection.height <= h
			testing.expectf(t, inside, "rendered final selection %v exceeds client height %g", selection, h)
			testing.expect_value(t, render.frame_render(device, surface, &list, theme.window), render.Error.None)
			pixels, pixel_error := render.surface_read_pixels(device, surface, context.allocator)
			if !testing.expect_value(t, pixel_error, render.Error.None) { return }
			defer delete(pixels)
			if !inside { continue }
			x, y := int(selection.x+selection.width/2), int(selection.y+selection.height-2*scale)
			offset := (y*int(w)+x)*4
			for expected, channel in ([4]u8{0, 0, 255, 255}) {
				testing.expect_value(t, pixels[offset+channel], expected)
			}
		}
	}
}

@(private)
palette_fit_visible :: proc(t: ^testing.T, p: ^ui.Palette, l: ui.Palette_Layout, width, height: f32) {
	for r in ([?]render.Rect{l.panel, l.input, l.list}) {
		testing.expect(t, r.x >= 0 && r.y >= 0 && r.width >= 0 && r.height >= 0)
		testing.expectf(t, r.x+r.width <= width+0.001 && r.y+r.height <= height+0.001,
			"%v outside %gx%g", r, width, height)
	}
	testing.expect(t, p.scroll >= 0 && p.scroll <= max(0, len(p.results)-max(1, p.visible_rows)))
	if l.rows > 0 && len(p.results) > 0 {
		testing.expect(t, p.selected >= p.scroll && p.selected < p.scroll+l.rows)
		testing.expect(t, l.list.y+f32(p.selected-p.scroll+1)*l.row_height <= height+0.001)
	}
}

@(test)
palette_fit_tracks_navigation_query_resize_and_pointer :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]ui.Palette_Setting
	for entry, i in settings.SCHEMA { rows[i] = {entry.key, entry.title, settings.group_title(entry.key)} }
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) { return }
	defer ui.palette_destroy(&p)
	for scale in ([?]f32{0.5, 1, 1.5, 1.75, 2, 3}) {
		for width in ([?]f32{40, 160, 463, 1000}) {
			for height in ([?]f32{1, 40, 80, 122, 123, 160, 240, 464, 800}) {
				w, h := width*scale, height*scale
				ui.palette_open(&p, &registry)
				ui.palette_text(&p, &registry, "setting")
				l := ui.palette_layout(&p, w, h, scale)
				palette_fit_visible(t, &p, l, w, h)
				ui.palette_key(&p, &registry, key({key = .End}))
				testing.expect_value(t, p.selected, len(p.results)-1)
				palette_fit_visible(t, &p, l, w, h)
				if l.rows == 0 {
					outcome, _ := ui.palette_key(&p, &registry, key({key = .Enter}))
					testing.expect_value(t, outcome, ui.Outcome.None)
					testing.expect_value(t, ui.palette_scroll(&p, -1), ui.Outcome.None)
					continue
				}
				for _ in 0..<len(p.results) {
					ui.palette_key(&p, &registry, key({key = .Arrow_Up}))
					palette_fit_visible(t, &p, l, w, h)
				}
				ui.palette_key(&p, &registry, key({key = .Page_Down}))
				testing.expect_value(t, p.selected, p.visible_rows)
				palette_fit_visible(t, &p, l, w, h)
				ui.palette_key(&p, &registry, key({key = .Page_Up}))
				testing.expect_value(t, p.selected, 0)
				for _ in 0..<len(p.results) {
					ui.palette_key(&p, &registry, key({key = .N, modifiers = {.Control}}))
					palette_fit_visible(t, &p, l, w, h)
				}
				ui.palette_key(&p, &registry, key({key = .P, modifiers = {.Control}}))
				palette_fit_visible(t, &p, l, w, h)
				ui.palette_key(&p, &registry, key({key = .Home}))
				for _ in 0..<len(p.results) {
					ui.palette_key(&p, &registry, key({key = .Arrow_Down}))
					palette_fit_visible(t, &p, l, w, h)
				}
				for _ in 0..<len(p.results) {
					ui.palette_key(&p, &registry, key({key = .P, modifiers = {.Control}}))
					palette_fit_visible(t, &p, l, w, h)
				}
				ui.palette_scroll(&p, -10000)
				testing.expect_value(t, p.scroll, len(p.results)-p.visible_rows)
				palette_fit_visible(t, &p, l, w, h)
				x, y := l.list.x+l.list.width/2, l.list.y+l.list.height-l.row_height/2
				ui.palette_mouse_move(&p, l, x, y)
				testing.expect_value(t, p.selected, len(p.results)-1)
				palette_fit_visible(t, &p, l, w, h)
				expected := ui.palette_result_name(&p, p.results[p.selected])
				outcome, _ := ui.palette_mouse_press(&p, l, x, y)
				testing.expect_value(t, outcome, ui.Outcome.Open_Setting)
				testing.expect_value(t, p.chosen, expected)
				ui.palette_open(&p, &registry)
				ui.palette_text(&p, &registry, "setting")
				ui.palette_scroll(&p, -10000)
				ui.palette_scroll(&p, 10000)
				testing.expect_value(t, p.scroll, 0)
				palette_fit_visible(t, &p, l, w, h)
				testing.expect_value(t, ui.palette_mouse_move(&p, l, x, l.list.y+l.list.height), ui.Outcome.None)
			}
		}
	}
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "setting")
	normal := ui.palette_layout(&p, 1000, 800, 1)
	testing.expect_value(t, normal.rows, 8)
	testing.expect_value(t, normal.panel, render.Rect{220, 96, 560, 417})
	testing.expect_value(t, normal.list, render.Rect{228, 169, 544, 336})
	ui.palette_key(&p, &registry, key({key = .End}))
	ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	selected_text := ui.palette_selection(&p)
	cursor, anchor := p.query.cursor, p.query.anchor
	for viewport in ([?][3]f32{{926, 928, 2}, {463, 240, 1.5}, {1000, 800, 1}}) {
		l := ui.palette_layout(&p, viewport[0], viewport[1], viewport[2])
		palette_fit_visible(t, &p, l, viewport[0], viewport[1])
		testing.expect_value(t, ui.palette_selection(&p), selected_text)
		testing.expect_value(t, p.query.cursor, cursor)
		testing.expect_value(t, p.query.anchor, anchor)
	}
	ui.palette_text(&p, &registry, "terminal setting")
	testing.expect_value(t, len(p.results), 3)
	testing.expect_value(t, p.scroll, 0)
	testing.expect_value(t, p.selected, 0)
	l := ui.palette_layout(&p, 926, 928, 2)
	testing.expect_value(t, l.rows, 3)
	ui.palette_key(&p, &registry, key({key = .End}))
	outcome, _ := ui.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, outcome, ui.Outcome.Open_Setting)
	testing.expect_value(t, p.chosen, "terminal.minimum_contrast")
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "terminal settings contrast")
	l = ui.palette_layout(&p, 926, 928, 2)
	testing.expect_value(t, len(p.results), 1)
	testing.expect_value(t, l.rows, 1)
	testing.expect_value(t, ui.palette_scroll(&p, -10000), ui.Outcome.None)
	testing.expect_value(t, p.scroll, 0)
	ui.palette_key(&p, &registry, key({key = .End}))
	testing.expect_value(t, p.selected, 0)
	ui.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	ui.palette_text(&p, &registry, "zzzz setting")
	l = ui.palette_layout(&p, 926, 928, 2)
	testing.expect_value(t, l.rows, 1)
	testing.expect_value(t, p.scroll, 0)
	testing.expect_value(t, ui.palette_mouse_move(&p, l, l.list.x+1, l.list.y+1), ui.Outcome.None)
	outcome, _ = ui.palette_mouse_press(&p, l, l.list.x+1, l.list.y+1)
	testing.expect_value(t, outcome, ui.Outcome.None)
	outcome, _ = ui.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, outcome, ui.Outcome.None)
	p.query.dragging = true
	ui.palette_close(&p)
	testing.expect(t, !p.open && !p.query.dragging)
}

@(test)
palette_fit_draws_complete_selected_rows_with_reused_owned_storage :: proc(t: ^testing.T) {
	allocations := Notice_Allocations{backing = context.allocator}
	allocator := runtime.Allocator{notice_allocator, &allocations}
	fonts, font_error := font.system_create(allocator)
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) { return }
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device, allocator)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 16)) { return }
	list := render.draw_list_init(allocator)
	defer render.draw_list_destroy(&list)
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]ui.Palette_Setting
	for entry, i in settings.SCHEMA { rows[i] = {entry.key, entry.title, settings.group_title(entry.key)} }
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:], allocator), nil) { return }
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "setting")
	for viewport in ([?][3]f32{{926, 928, 2}, {695, 696, 1.5}, {1000, 800, 1}, {160, 100, 2}, {1, 1, 2}}) {
		w, h, scale := viewport[0], viewport[1], viewport[2]
		surface, surface_error := render.surface_create_offscreen(device, i32(w), i32(h))
		if !testing.expect_value(t, surface_error, render.Error.None) { return }
		defer render.surface_destroy(surface)
		ui.text_set_size(&text, 16*scale)
		l := ui.palette_layout(&p, w, h, scale)
		if l.input.width > 100*scale && l.input.height >= 64*scale {
			ui.palette_input_press(&p, l, &text, l.input.x+14*scale, scale, false)
			testing.expect_value(t, p.query.cursor, 0)
			ui.palette_input_drag(&p, l, &text, l.input.x+l.input.width-14*scale, scale)
			testing.expect_value(t, ui.palette_selection(&p), "setting")
			testing.expect(t, ui.palette_input_release(&p) && !p.query.dragging)
		}
		ui.palette_key(&p, &registry, key({key = .End}))
		for mode in settings.Theme_Mode {
			theme := ui.theme_from(settings.theme_resolve({.Studio, mode}))
			render.draw_list_reset(&list)
			testing.expect_value(t, ui.palette_draw(&p, &list, &text, theme, w, h, scale), glyphs.Result.Ok)
			selected_rows := 0
			for instance in list.rects {
				if instance.color != theme.selection { continue }
				selected_rows += 1
				testing.expect_value(t, instance.rect, render.Rect{l.list.x,
					l.list.y+f32(p.selected-p.scroll)*l.row_height, l.list.width, l.row_height})
				testing.expect(t, instance.rect.y+instance.rect.height <= h)
			}
			testing.expect_value(t, selected_rows, l.rows > 0 ? 1 : 0)
			for layer in list.layers {
				testing.expect(t, layer.clip.x >= 0 && layer.clip.y >= 0)
				testing.expect(t, layer.clip.x+layer.clip.width <= w && layer.clip.y+layer.clip.height <= h)
			}
			testing.expect_value(t, render.frame_render(device, surface, &list, theme.window), render.Error.None)
			calls := allocations.calls
			for _ in 0..<3 {
				render.draw_list_reset(&list)
				ui.palette_layout(&p, w, h, scale)
				ui.palette_scroll(&p, -1)
				testing.expect_value(t, ui.palette_draw(&p, &list, &text, theme, w, h, scale), glyphs.Result.Ok)
				testing.expect_value(t, allocations.calls, calls)
			}
		}
	}
}

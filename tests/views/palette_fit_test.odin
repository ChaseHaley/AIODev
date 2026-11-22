package views_test

import "core:testing"
import "base:runtime"
import "aio:commands"
import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:render"
import "aio:settings"
import "aio:views"
import fixtures "../fixtures"
import "cosmos:ui"
import "cosmos:testkit"

// Counts the allocations and resizes made through it, so a test can prove a draw reuses its storage.
@(private = "file")
Counted_Allocations :: struct {
	backing: runtime.Allocator,
	calls:   int,
}

@(private = "file")
counting_allocator :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	state := cast(^Counted_Allocations)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		state.calls += 1
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
palette_header_flood_fits_measured_narrow_viewport :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]views.Palette_Setting
	for entry, i in settings.SCHEMA {
		rows[i] = {key = entry.key, title = entry.title, group = settings.group_title(entry.key)}
	}
	p: views.Palette
	if !testing.expect_value(t, views.palette_init(&p, rows[:]), nil) { return }
	defer views.palette_destroy(&p)
	views.palette_open(&p, &registry)
	views.palette_text(&p, &registry, "setting")
	testing.expect(t, len(p.results) > 8)
	l := views.palette_layout(&p, 926, 928, 2)
	testing.expectf(t, l.panel.y+l.panel.height+2 <= 928, "panel bottom %g exceeds client height 928",
		l.panel.y+l.panel.height+2)
	testing.expectf(t, l.list.y+l.list.height <= 928, "last result bottom %g exceeds client height 928",
		l.list.y+l.list.height)
}

@(test)
palette_fit_keeps_rows_and_stable_query_top :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]views.Palette_Setting
	for entry, i in settings.SCHEMA { rows[i] = {key = entry.key, title = entry.title, group = settings.group_title(entry.key)} }
	p: views.Palette
	if !testing.expect_value(t, views.palette_init(&p, rows[:]), nil) { return }
	defer views.palette_destroy(&p)
	// A 46x18 client at 200% cannot hold eight rows below the caption claim, so it
	// trades rows for a panel that keeps its pointer events. All mode also spends
	// height on the key footer.
	for viewport in ([?][4]f32{
		{926, 928, 2, 6},
		{695, 696, 1.5, 6},
		{926, 837, 2, 5},
		{1000, 800, 1, 8},
	}) {
		w, h, scale := viewport[0], viewport[1], viewport[2]
		expected := int(viewport[3])
		views.palette_open(&p, &registry)
		views.palette_text(&p, &registry, "setting")
		l := views.palette_layout(&p, w, h, scale)
		testing.expectf(t, l.rows == expected, "expected %d rows at %gx%g scale %g, got %d",
			expected, w, h, scale, l.rows)
		testing.expect(t, l.panel.y >= min(h, ui.caption_claim_height(scale)))
		testing.expect(t, l.panel.y >= scale && l.panel.y+l.panel.height+scale <= h)
		top := l.panel.y
		for query in ([?]string{"terminal setting", "terminal settings contrast", "zzzz setting", "setting"}) {
			views.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
			views.palette_text(&p, &registry, query)
			l = views.palette_layout(&p, w, h, scale)
			testing.expect_value(t, l.panel.y, top)
		}
	}
}

@(test)
palette_fit_renders_final_selection_inside_client :: proc(t: ^testing.T) {
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
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
	rows: [len(settings.SCHEMA)]views.Palette_Setting
	for entry, i in settings.SCHEMA { rows[i] = {key = entry.key, title = entry.title, group = settings.group_title(entry.key)} }
	p: views.Palette
	if !testing.expect_value(t, views.palette_init(&p, rows[:]), nil) { return }
	defer views.palette_destroy(&p)
	views.palette_open(&p, &registry)
	views.palette_text(&p, &registry, "setting")
	for viewport in ([?][3]f32{{926, 928, 2}, {695, 696, 1.5}, {926, 837, 2}, {1000, 800, 1}}) {
		w, h, scale := viewport[0], viewport[1], viewport[2]
		surface, surface_error := render.surface_create_offscreen(device, i32(w), i32(h))
		if !testing.expect_value(t, surface_error, render.Error.None) { return }
		defer render.surface_destroy(surface)
		ui.text_set_size(&text, 16*scale)
		views.palette_fit(&p, w, h, scale)
		views.palette_key(&p, &registry, key({key = .End, modifiers = {.Control}}))
		testing.expect_value(t, p.selected, len(p.results)-1)
		for id in ([?]string{"studio-dark", "studio-light"}) {
			theme := views.theme_from(testkit.bundled_theme(id), fixtures.default_interface())
			theme.selection = {1, 0, 0, 1}
			for progress in ([?]f32{0.01, 0.25, 0.5, 0.75, 1}) {
				render.draw_list_reset(&list)
				testing.expect_value(t, views.palette_draw(&p, &list, &text, theme, w, h, scale,
					{opacity = 1, rise = 4*scale*(1-progress)}), render.Build_Status.Ok)
				for layer in list.layers {
					testing.expect(t, layer.clip.y >= 0 && layer.clip.y+layer.clip.height <= h)
				}
				for instance in list.rects {
					if instance.color != theme.border || instance.rect.width <= w/2 { continue }
					testing.expectf(t, instance.rect.y+instance.rect.height <= h,
						"animated border %v exceeds client height %g at progress %g", instance.rect, h, progress)
				}
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
}

@(private)
palette_fit_visible :: proc(t: ^testing.T, p: ^views.Palette, l: views.Palette_Layout, width, height: f32) {
	// Navigation keeps the selection on a fitted row, so measuring without fitting must show it.
	current := views.palette_layout(p, width, height, l.row_height / 40)
	for r in ([?]render.Rect{current.panel, current.mode_bar, current.input, current.list}) {
		testing.expect(t, r.x >= 0 && r.y >= 0 && r.width >= 0 && r.height >= 0)
		testing.expectf(t, r.x+r.width <= width+0.001 && r.y+r.height <= height+0.001,
			"%v outside %gx%g", r, width, height)
	}
	testing.expect(t, p.scroll >= 0 && p.scroll <= max(0, len(p.results)-1))
	if current.rows > 0 && len(p.results) > 0 {
		testing.expect(t, p.selected >= p.scroll && p.selected < p.scroll+current.rows)
		bottom := current.list.y + f32(p.selected-p.scroll+1) * current.row_height
		testing.expect(t, bottom <= height+0.001)
	}
}

@(test)
palette_fit_tracks_navigation_query_resize_and_pointer :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]views.Palette_Setting
	for entry, i in settings.SCHEMA { rows[i] = {key = entry.key, title = entry.title, group = settings.group_title(entry.key)} }
	p: views.Palette
	if !testing.expect_value(t, views.palette_init(&p, rows[:]), nil) { return }
	defer views.palette_destroy(&p)
	for scale in ([?]f32{0.5, 1, 1.5, 1.75, 2, 3}) {
		for width in ([?]f32{40, 160, 463, 1000}) {
			for height in ([?]f32{1, 40, 80, 122, 123, 160, 240, 464, 800}) {
				w, h := width*scale, height*scale
				views.palette_open(&p, &registry)
				views.palette_text(&p, &registry, "setting")
				views.palette_fit(&p, w, h, scale)
				l := views.palette_layout(&p, w, h, scale)
				palette_fit_visible(t, &p, l, w, h)
				views.palette_key(&p, &registry, key({key = .End, modifiers = {.Control}}))
				testing.expect_value(t, p.selected, len(p.results)-1)
				palette_fit_visible(t, &p, l, w, h)
				if l.rows == 0 {
					outcome, _ := views.palette_key(&p, &registry, key({key = .Enter}))
					testing.expect_value(t, outcome, views.Outcome.None)
					testing.expect_value(t, views.palette_scroll(&p, -1), views.Outcome.None)
					continue
				}
				for _ in 0..<len(p.results) {
					views.palette_key(&p, &registry, key({key = .Arrow_Up}))
					palette_fit_visible(t, &p, l, w, h)
				}
				views.palette_key(&p, &registry, key({key = .Page_Down}))
				testing.expect_value(t, p.selected, p.visible_rows)
				palette_fit_visible(t, &p, l, w, h)
				views.palette_key(&p, &registry, key({key = .Page_Up}))
				testing.expect_value(t, p.selected, 0)
				for _ in 0..<len(p.results) {
					views.palette_key(&p, &registry, key({key = .N, modifiers = {.Control}}))
					palette_fit_visible(t, &p, l, w, h)
				}
				views.palette_key(&p, &registry, key({key = .P, modifiers = {.Control}}))
				palette_fit_visible(t, &p, l, w, h)
				views.palette_key(&p, &registry, key({key = .Home, modifiers = {.Control}}))
				for _ in 0..<len(p.results) {
					views.palette_key(&p, &registry, key({key = .Arrow_Down}))
					palette_fit_visible(t, &p, l, w, h)
				}
				for _ in 0..<len(p.results) {
					views.palette_key(&p, &registry, key({key = .P, modifiers = {.Control}}))
					palette_fit_visible(t, &p, l, w, h)
				}
				views.palette_scroll(&p, -10000)
				testing.expect_value(t, p.scroll, len(p.results)-p.visible_rows)
				palette_fit_visible(t, &p, l, w, h)
				l = views.palette_layout(&p, w, h, scale)
				last := p.scroll + l.rows - 1
				x := l.list.x + l.list.width/2
				y := l.list.y + f32(last-p.scroll) * l.row_height + l.row_height/2
				views.palette_mouse_move(&p, l, x, y)
				testing.expect_value(t, p.selected, last)
				palette_fit_visible(t, &p, l, w, h)
				expected := views.palette_result_name(&p, p.results[p.selected])
				outcome, _ := views.palette_mouse_press(&p, &registry, l, x, y)
				testing.expect_value(t, outcome, views.Outcome.Open_Setting)
				testing.expect_value(t, chosen_setting(&p), expected)
				views.palette_open(&p, &registry)
				views.palette_text(&p, &registry, "setting")
				views.palette_scroll(&p, -10000)
				views.palette_scroll(&p, 10000)
				testing.expect_value(t, p.scroll, 0)
				palette_fit_visible(t, &p, l, w, h)
				testing.expect_value(t, views.palette_mouse_move(&p, l, x, l.list.y+l.list.height), views.Outcome.None)
			}
		}
	}
	views.palette_open(&p, &registry)
	views.palette_text(&p, &registry, "setting")
	normal := views.palette_layout(&p, 1000, 800, 1)
	testing.expect_value(t, normal.rows, 8)
	// Eight flat rows sit between the query band and the key footer.
	testing.expect_value(t, normal.panel, render.Rect{220, 96, 560, 477})
	// The scrollbar takes the list's right padding and 3 DIPs more, inside the panel border.
	testing.expect_value(t, normal.list, render.Rect{228, 213, 541, 320})
	views.palette_key(&p, &registry, key({key = .End, modifiers = {.Control}}))
	views.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	selected_text := views.palette_selection(&p)
	cursor, anchor := p.query.cursor, p.query.anchor
	for viewport in ([?][3]f32{
		{1000, 400, 1}, {1000, 800, 1}, {1000, 800, 2}, {926, 928, 2},
		{463, 240, 1.5}, {463, 240, 0.5}, {40, 1, 1}, {1000, 800, 1},
	}) {
		views.palette_fit(&p, viewport[0], viewport[1], viewport[2])
		l := views.palette_layout(&p, viewport[0], viewport[1], viewport[2])
		testing.expect_value(t, p.selected, len(p.results)-1)
		palette_fit_visible(t, &p, l, viewport[0], viewport[1])
		testing.expect_value(t, views.palette_selection(&p), selected_text)
		testing.expect_value(t, p.query.cursor, cursor)
		testing.expect_value(t, p.query.anchor, anchor)
	}
	terminal := 0
	for row in rows { if row.group == "Terminal" { terminal += 1 } }
	views.palette_text(&p, &registry, "terminal setting")
	testing.expect_value(t, len(p.results), terminal)
	testing.expect_value(t, p.scroll, 0)
	testing.expect_value(t, p.selected, 0)
	views.palette_fit(&p, 926, 928, 2)
	l := views.palette_layout(&p, 926, 928, 2)
	testing.expect_value(t, l.rows, min(terminal, p.visible_rows))
	views.palette_key(&p, &registry, key({key = .End, modifiers = {.Control}}))
	outcome, _ := views.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, outcome, views.Outcome.Open_Setting)
	testing.expect_value(t, chosen_setting(&p), "terminal.minimum_contrast")
	views.palette_open(&p, &registry)
	views.palette_text(&p, &registry, "terminal settings contrast")
	views.palette_fit(&p, 926, 928, 2)
	l = views.palette_layout(&p, 926, 928, 2)
	testing.expect_value(t, len(p.results), 1)
	testing.expect_value(t, l.rows, 1)
	testing.expect_value(t, views.palette_scroll(&p, -10000), views.Outcome.None)
	testing.expect_value(t, p.scroll, 0)
	views.palette_key(&p, &registry, key({key = .End, modifiers = {.Control}}))
	testing.expect_value(t, p.selected, 0)
	views.palette_key(&p, &registry, key({key = .A, modifiers = {.Control}}))
	views.palette_text(&p, &registry, "zzzz setting")
	views.palette_fit(&p, 926, 928, 2)
	l = views.palette_layout(&p, 926, 928, 2)
	testing.expect_value(t, l.rows, 1)
	testing.expect_value(t, p.scroll, 0)
	testing.expect_value(t, views.palette_mouse_move(&p, l, l.list.x+1, l.list.y+1), views.Outcome.None)
	outcome, _ = views.palette_mouse_press(&p, &registry, l, l.list.x+1, l.list.y+1)
	testing.expect_value(t, outcome, views.Outcome.None)
	outcome, _ = views.palette_key(&p, &registry, key({key = .Enter}))
	testing.expect_value(t, outcome, views.Outcome.None)
	p.drag = views.Query_Drag{}
	views.palette_close(&p)
	testing.expect(t, !ui.presence_is_open(p.presence) && p.drag == nil)
}

@(test)
palette_fit_draws_complete_selected_rows_with_reused_owned_storage :: proc(t: ^testing.T) {
	allocations := Counted_Allocations{backing = context.allocator}
	allocator := runtime.Allocator{counting_allocator, &allocations}
	fonts, font_error := font.system_create(allocator)
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
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
	rows: [len(settings.SCHEMA)]views.Palette_Setting
	for entry, i in settings.SCHEMA { rows[i] = {key = entry.key, title = entry.title, group = settings.group_title(entry.key)} }
	p: views.Palette
	if !testing.expect_value(t, views.palette_init(&p, rows[:], allocator), nil) { return }
	defer views.palette_destroy(&p)
	views.palette_open(&p, &registry)
	views.palette_text(&p, &registry, "setting")
	for viewport in ([?][3]f32{{926, 928, 2}, {695, 696, 1.5}, {1000, 800, 1}, {160, 100, 2}, {1, 1, 2}}) {
		w, h, scale := viewport[0], viewport[1], viewport[2]
		surface, surface_error := render.surface_create_offscreen(device, i32(w), i32(h))
		if !testing.expect_value(t, surface_error, render.Error.None) { return }
		defer render.surface_destroy(surface)
		ui.text_set_size(&text, 16*scale)
		views.palette_fit(&p, w, h, scale)
		l := views.palette_layout(&p, w, h, scale)
		if l.input.width > 100*scale && l.input.height >= 64*scale {
			frame := ui.field_box_text_rect(views.palette_query_box(&p, l, &text, scale))
			views.palette_input_press(&p, l, &text, frame.x, l.input.y + 40*scale, scale, false)
			testing.expect_value(t, p.query.cursor, 0)
			views.palette_input_drag(&p, l, &text, frame.x+frame.width, scale)
			testing.expect_value(t, views.palette_selection(&p), "setting")
			_, selecting := p.drag.(views.Query_Drag)
			testing.expect(t, selecting)
			testing.expect_value(t, views.palette_pointer_release(&p), views.Outcome.None)
			testing.expect(t, p.drag == nil)
		}
		views.palette_key(&p, &registry, key({key = .End, modifiers = {.Control}}))
		l = views.palette_layout(&p, w, h, scale)
		selected_y := l.list.y + f32(p.selected-p.scroll) * l.row_height
		for id in ([?]string{"studio-dark", "studio-light"}) {
			theme := views.theme_from(testkit.bundled_theme(id), fixtures.default_interface())
			render.draw_list_reset(&list)
			testing.expect_value(t, views.palette_draw(&p, &list, &text, theme, w, h, scale), render.Build_Status.Ok)
			selected_rows := 0
			for instance in list.rects {
				if instance.color != theme.selection { continue }
				selected_rows += 1
				testing.expect_value(t, instance.rect, render.Rect{l.list.x,
					selected_y, l.list.width, l.row_height})
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
				views.palette_fit(&p, w, h, scale)
				views.palette_scroll(&p, -1)
				testing.expect_value(t, views.palette_draw(&p, &list, &text, theme, w, h, scale), render.Build_Status.Ok)
				testing.expect_value(t, allocations.calls, calls)
			}
		}
	}
}

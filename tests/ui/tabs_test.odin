package ui_test

import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:ui"
import fixtures "../fixtures"

@(test)
tab_bar_caps_widths_and_places_tabs_actions_and_empty_space :: proc(t: ^testing.T) {
	bar := ui.tab_bar_layout(0, 500, 1, 3)
	testing.expect_value(t, bar.count, 3)
	testing.expect_value(t, bar.height, ui.TITLE_BAR_HEIGHT)
	testing.expect(t, bar.tab_width > 0 && bar.tab_width <= 220)
	// The main package's window_tab_hit tests the points against these slots.
	new_tab := ui.tab_new_rect(bar)
	testing.expect_value(t, new_tab.x, bar.end)
	testing.expect_value(t, bar.end, bar.x + f32(bar.count)*bar.tab_width)
	testing.expect_value(t, new_tab.width, bar.button_width)

	close := ui.tab_close_rect(bar, bar.x+bar.tab_width, 1)
	testing.expect_value(t, close.width, f32(24))
	// A resting tab's close button sits inside its own slot.
	testing.expect(t, close.x >= bar.x+bar.tab_width && close.x+close.width <= bar.x+2*bar.tab_width)
	testing.expect(t, close.y >= 0 && close.y+close.height <= bar.height)
	// A tab sliding toward another slot carries its close button with it.
	moved := ui.tab_close_rect(bar, bar.x+1.5*bar.tab_width, 1)
	testing.expect_value(t, moved.x - close.x, bar.tab_width / 2)

	drop := ui.tab_drop_region(bar, 900, 1)
	testing.expect(t, ui.tab_drop_hit(bar, 900, 1, drop.x+2, 20))
	testing.expect(t, !ui.tab_drop_hit(bar, 900, 1, 2, 20))
}

@(test)
tab_bar_with_no_tabs_has_no_tab_slots :: proc(t: ^testing.T) {
	bar := ui.tab_bar_layout(0, 500, 1, 0)
	testing.expect_value(t, bar.count, 0)
	testing.expect_value(t, bar.tab_width, f32(0))
	testing.expect_value(t, ui.tab_close_rect(bar, 0, 1), render.Rect{})
	// Tabs a drag offers take their share of the width without counting as tabs.
	offered := ui.tab_bar_layout(10, 500, 1, 2, 1)
	testing.expect_value(t, offered.count, 2)
	testing.expect_value(t, offered.x, f32(10))
	testing.expect_value(t, offered.tab_width, ui.tab_bar_layout(10, 500, 1, 3).tab_width)
}

// The program icon stays at the left and status sits just before Close; a tab too narrow for both
// keeps the status.
@(test)
tab_draw_keeps_the_program_icon_left_and_status_before_close :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	resolved, ok := fixtures.shipped_theme_file(fixtures.SHIPPED_THEMES[0])
	if !testing.expect(t, ok) {return}
	theme := ui.theme_from(resolved, fixtures.default_interface())
	done := ui.Status_Mark{glyph = .Done, progress = -1}
	for scale in ([?]f32{1, 1.5, 2}) {
		ui.text_set_size(&text, 14 * scale)
		for width, i in ([?]f32{200, 80}) {
			bar := ui.tab_bar_layout(0, width * 2 * scale + 32 * scale, scale, 2)
			render.draw_list_reset(&list)
			testing.expect_value(t, ui.tab_draw(&list, &text, theme, bar, bar.tab_width,
				{title = "Title", badge = {atlas = {0, 0, 14 * scale, 14 * scale}}, status = done,
				 status_slot = true},
				0, 0, scale), render.Build_Status.Ok)
			left := bar.x + bar.tab_width
			close := ui.tab_close_rect(bar, bar.tab_width, scale)
			icon_found, status_found := false, false
			for g in list.glyphs {
				if g.flags & render.GLYPH_COLOR == 0 {continue}
				icon_found = true
				testing.expect(t, g.rect.x >= left + 8 * scale && g.rect.x + g.rect.width <= left + 28 * scale)
			}
			for r in list.rects {
				if r.color != ui.status_color(theme, .Done) || r.rect.width != ui.ICON_INDICATOR * scale {continue}
				status_found = true
				testing.expect(t, r.rect.x >= left + bar.tab_width - 46 * scale && r.rect.x + r.rect.width <= close.x + 4 * scale)
			}
			testing.expect_value(t, icon_found, i == 0)
			testing.expect(t, status_found)
			// Without a status to show, a narrow tab keeps its icon.
			render.draw_list_reset(&list)
			testing.expect_value(t, ui.tab_draw(&list, &text, theme, bar, bar.tab_width,
				{title = "Title", badge = {atlas = {0, 0, 14 * scale, 14 * scale}}, status_slot = true},
				0, 0, scale), render.Build_Status.Ok)
			icon_found = false
			for g in list.glyphs {icon_found ||= g.flags & render.GLYPH_COLOR != 0}
			testing.expect(t, icon_found)
		}
	}
}

// A tab with several panes stacks its focused pane's mark over the one behind; the mark behind
// stays clear of a gap around the front one, and the title starts where a one-pane tab's does.
@(test)
tab_draw_stacks_the_focused_mark_over_the_one_behind :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	resolved, ok := fixtures.shipped_theme_file(fixtures.SHIPPED_THEMES[0])
	if !testing.expect(t, ok) {return}
	theme := ui.theme_from(resolved, fixtures.default_interface())
	for scale in ([?]f32{1, 1.5, 2}) {
		ui.text_set_size(&text, 14 * scale)
		mark := ui.TAB_STACK_MARK * scale
		front_atlas := render.Rect{0, 0, mark, mark}
		back_atlas := render.Rect{64, 0, mark, mark}
		bar := ui.tab_bar_layout(0, 400 * scale, scale, 2)
		render.draw_list_reset(&list)
		testing.expect_value(t, ui.tab_draw(&list, &text, theme, bar, 0,
			{title = "Title", badge = {atlas = front_atlas}, behind = {atlas = back_atlas}, selected = true},
			0, 0, scale), render.Build_Status.Ok)
		front: render.Rect
		backs, title_x := 0, f32(-1)
		for g in list.glyphs {
			if g.flags & render.GLYPH_COLOR == 0 {
				if title_x < 0 {title_x = g.rect.x}
				continue
			}
			if g.atlas == front_atlas {front = g.rect}
		}
		if !testing.expect(t, front.width > 0) {continue}
		testing.expect_value(t, front.width, mark)
		cut := render.Rect {
			front.x - ui.TAB_STACK_GAP * scale + 0.01,
			front.y - ui.TAB_STACK_GAP * scale + 0.01,
			front.width + 2 * ui.TAB_STACK_GAP * scale - 0.02,
			front.height + 2 * ui.TAB_STACK_GAP * scale - 0.02,
		}
		for layer in list.layers {
			for g in list.glyphs[layer.glyph_start:][:layer.glyph_count] {
				if g.atlas != back_atlas {continue}
				backs += 1
				// The back mark draws only where its clip leaves the cut-out alone.
				visible := layer.clip
				x := max(visible.x, g.rect.x, cut.x)
				y := max(visible.y, g.rect.y, cut.y)
				right := min(visible.x + visible.width, g.rect.x + g.rect.width, cut.x + cut.width)
				bottom := min(visible.y + visible.height, g.rect.y + g.rect.height, cut.y + cut.height)
				testing.expectf(t, right <= x || bottom <= y, "scale %v: back mark shows in the cut-out", scale)
				testing.expect(t, g.rect.x < front.x && g.rect.y < front.y)
			}
		}
		testing.expect(t, backs > 0)
		// The title starts where a one-pane tab's does.
		render.draw_list_reset(&list)
		testing.expect_value(t, ui.tab_draw(&list, &text, theme, bar, 0,
			{title = "Title", badge = {atlas = front_atlas}, selected = true}, 0, 0, scale),
			render.Build_Status.Ok)
		single_x := f32(-1)
		for g in list.glyphs {
			if g.flags & render.GLYPH_COLOR == 0 {single_x = g.rect.x; break}
		}
		testing.expect_value(t, single_x, title_x)
		left := bar.x + ui.CONTROL_INSET * scale
		testing.expect(t, title_x >= left + (ui.TAB_BADGE_COLUMN + ui.SPACE_2) * scale - 1)
	}
}

// WORK-483: while a tab's label turns, its marks swivel about their column (the old face squeezing to edge
// on, then the new face opening out, the stack's two marks trading sides when focus moves to the one behind)
// and its titles slide across their box the way focus moved.
@(test)
tab_turn_swivels_the_marks_and_slides_the_title :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	resolved, ok := fixtures.shipped_theme_file(fixtures.SHIPPED_THEMES[0])
	if !testing.expect(t, ok) {return}
	theme := ui.theme_from(resolved, fixtures.default_interface())
	everything := render.Rect{0, 0, 2000, 2000}
	for scale in ([?]f32{1, 2}) {
		ui.text_set_size(&text, 14 * scale)
		mark := ui.TAB_STACK_MARK * scale
		a, b := render.Rect{0, 0, mark, mark}, render.Rect{64, 0, mark, mark}
		tile := render.Rect{0, 4 * scale, 200 * scale, 32 * scale}
		// Focus moved from B, with A behind it, to A, with B behind it.
		tab := ui.Tab_Tile{title = "New", badge = {atlas = a}, behind = {atlas = b}}
		turn := ui.Tab_Turn{turning = true, title = "Old", badge = {atlas = b}, behind = {atlas = a}, toward = {1, 0}}

		render.draw_list_reset(&list)
		_ = render.push_layer(&list, everything)
		testing.expect_value(t, ui.tab_badge_draw(&list, &text, theme, tile, tab, scale), render.Build_Status.Ok)
		resting := turn_mark(list, a)
		Case :: struct {
			progress:     f32,
			front, back:  render.Rect,
		}
		for c in ([?]Case{{0.25, b, a}, {0.75, a, b}}) {
			turned := tab
			turned.turn = turn
			turned.turn.progress = c.progress
			render.draw_list_reset(&list)
			_ = render.push_layer(&list, everything)
			testing.expect_value(t, ui.tab_badge_draw(&list, &text, theme, tile, turned, scale), render.Build_Status.Ok)
			front, back := turn_mark(list, c.front), turn_mark(list, c.back)
			width := ui.tab_turn_width(c.progress)
			testing.expectf(t, width > 0.7 && width < 0.71, "progress %v: width %v", c.progress, width)
			testing.expectf(t, abs(front.rect.width - mark * width) < 0.01, "scale %v progress %v: front %v wide",
				scale, c.progress, front.rect.width)
			testing.expectf(t, front.rect.x > back.rect.x, "progress %v: the front mark sits right of the back",
				c.progress)
			testing.expectf(t, front.color.a < resting.color.a, "progress %v: a turned mark is shaded", c.progress)
			testing.expect_value(t, list.layers[len(list.layers) - 1].clip, everything)
		}
		edge_on := tab
		edge_on.turn = turn
		edge_on.turn.progress = 0.5
		render.draw_list_reset(&list)
		_ = render.push_layer(&list, everything)
		testing.expect_value(t, ui.tab_badge_draw(&list, &text, theme, tile, edge_on, scale), render.Build_Status.Ok)
		testing.expect(t, turn_mark(list, b).rect.width < 0.01, "halfway through, the marks are edge on")

		box := render.Rect{40 * scale, 4 * scale, 120 * scale, 32 * scale}
		ink := theme.tab_text
		old_rest, new_rest: [8]render.Glyph_Instance
		old_count := turn_title(&list, &text, {title = "Old"}, box, ink, scale, everything, old_rest[:])
		new_count := turn_title(&list, &text, {title = "New"}, box, ink, scale, everything, new_rest[:])
		if !testing.expect(t, old_count > 0 && new_count > 0) {continue}
		for toward in ([?][2]f32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			sliding := tab
			sliding.turn = turn
			sliding.turn.progress = 0.25
			sliding.turn.toward = toward
			drawn: [16]render.Glyph_Instance
			count := turn_title(&list, &text, sliding, box, ink, scale, everything, drawn[:])
			if !testing.expect_value(t, count, old_count + new_count) {continue}
			// Sideways the titles cross the longer title and its fade band; up or down, the title's line.
			longer := max(ui.text_width(&text, "Old"), ui.text_width(&text, "New"))
			size := [2]f32 {
				min(box.width, longer + ui.TAB_TURN_FADE * scale),
				text.line_height + 2 * ui.TAB_TURN_LINE_PAD * scale,
			}
			leaving, entering := ui.tab_turn_offsets(sliding.turn, size)
			testing.expect_value(t, leaving, -toward * 0.25 * size)
			testing.expect_value(t, entering, toward * 0.75 * size)
			old := drawn[0]
			new := drawn[old_count]
			moved_old := [2]f32{old.rect.x - old_rest[0].rect.x, old.rect.y - old_rest[0].rect.y}
			moved_new := [2]f32{new.rect.x - new_rest[0].rect.x, new.rect.y - new_rest[0].rect.y}
			testing.expectf(t, abs(moved_old.x - leaving.x) < 0.01 && abs(moved_old.y - leaving.y) < 0.01,
				"toward %v: old title moved %v", toward, moved_old)
			testing.expectf(t, abs(moved_new.x - entering.x) < 0.01 && abs(moved_new.y - entering.y) < 0.01,
				"toward %v: new title moved %v", toward, moved_new)
			// The old title leaves away from the side focus moved to; the new one comes from that side.
			testing.expect(t, moved_old.x * toward.x + moved_old.y * toward.y < 0)
			testing.expect(t, moved_new.x * toward.x + moved_new.y * toward.y > 0)
			if toward.x != 0 {
				testing.expect(t, old.flags & render.GLYPH_FADE != 0 && new.flags & render.GLYPH_FADE != 0)
				// Each glyph fades toward the end of the box it is nearer.
				near_left := old.rect.x + old.rect.width / 2 < box.x + box.width / 2 ? old : new
				testing.expect_value(t, near_left.fade_end, box.x)
				testing.expect(t, near_left.fade_start > box.x)
			} else {
				testing.expect(t, old.color.a < old_rest[0].color.a && new.color.a < new_rest[0].color.a)
			}
		}
		// A turn between the same titles draws the title once, in place.
		same := tab
		same.turn = turn
		same.turn.title = "New"
		same.turn.progress = 0.25
		drawn: [8]render.Glyph_Instance
		testing.expect_value(t, turn_title(&list, &text, same, box, ink, scale, everything, drawn[:]), new_count)
		testing.expect_value(t, drawn[0].rect, new_rest[0].rect)
	}
}

// The colour glyph drawing the mark at `atlas`.
@(private = "file")
turn_mark :: proc(list: render.Draw_List, atlas: render.Rect) -> render.Glyph_Instance {
	for g in list.glyphs {if g.atlas == atlas {return g}}
	return {}
}

// Draws tile `t`'s title into `box` on a fresh list and copies its glyphs to `out`; the glyph count.
@(private = "file")
turn_title :: proc(
	list: ^render.Draw_List,
	text: ^ui.Text,
	t: ui.Tab_Tile,
	box: render.Rect,
	ink: render.Color,
	scale: f32,
	clip: render.Rect,
	out: []render.Glyph_Instance,
) -> int {
	render.draw_list_reset(list)
	_ = render.push_layer(list, clip)
	if ui.tab_title_draw(list, text, t, box, ink, scale) != .Ok {return 0}
	return copy(out, list.glyphs[:])
}

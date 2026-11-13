package ui_test

import "core:math"
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

// WORK-483: while a tab's label turns, its marks ride a sphere spinning along the move. The front mark swings
// out away from the side focus moved to, the way the old title leaves, and goes to the back, smaller and
// dimmer on the far side, while the mark behind comes round from the side focus moved to, to the front; at the
// end they have traded places. A mark new to the stack rides in from the hidden back, fading in, as the old
// front goes out.
@(test)
tab_turn_spins_the_marks_on_a_sphere :: proc(t: ^testing.T) {
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
	centre :: proc(r: render.Rect) -> [2]f32 {return {r.x + r.width / 2, r.y + r.height / 2}}
	for scale in ([?]f32{1, 2}) {
		size := ui.TAB_STACK_MARK * scale
		a, b, c := render.Rect{0, 0, size, size}, render.Rect{64, 0, size, size}, render.Rect{128, 0, size, size}
		tile := render.Rect{0, 4 * scale, 200 * scale, 32 * scale}
		front, back := ui.tab_mark_places(tile, true, scale)
		for toward in ([?][2]f32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			// Focus moved from B, with A behind it, to A, with B behind it.
			tab := ui.Tab_Tile{title = "New", badge = {atlas = a}, behind = {atlas = b}}
			tab.turn = {turning = true, title = "Old", badge = {atlas = b}, behind = {atlas = a}, toward = toward}
			for progress in ([?]f32{0, 0.25, 0.5, 0.75, 1}) {
				tab.turn.progress = progress
				marks, count := ui.tab_spin_marks(tile, tab, scale)
				if !testing.expect_value(t, count, 2) {continue}
				going, coming := marks[0], marks[1]
				if going.badge.atlas != b {going, coming = coming, going}
				angle := f32(math.PI) * progress
				travel := (1 - math.cos(angle)) / 2
				swing := ui.TAB_SPIN_RADIUS * scale * math.sin(angle)
				// Each swings out along the move from the straight way between its places: the old front away
				// from the side focus moved to, the old back from that side.
				went := centre(going.rect) - (centre(front) + (centre(back) - centre(front)) * travel)
				came := centre(coming.rect) - (centre(back) + (centre(front) - centre(back)) * travel)
				testing.expectf(t, abs(went.x + toward.x * swing) < 0.01 && abs(went.y + toward.y * swing) < 0.01,
					"scale %v toward %v at %v: the front mark swung %v", scale, toward, progress, went)
				testing.expectf(t, abs(came.x - toward.x * swing) < 0.01 && abs(came.y - toward.y * swing) < 0.01,
					"scale %v toward %v at %v: the back mark swung %v", scale, toward, progress, came)
				switch progress {
				case 0:
					testing.expectf(t, near(going.rect, front) && near(coming.rect, back), "at rest before")
				case 1:
					testing.expectf(t, near(going.rect, back) && near(coming.rect, front), "traded places")
				case 0.25:
					// The old front is still nearer: drawn last, larger and brighter.
					testing.expect_value(t, marks[1].badge.atlas, b)
					testing.expect(t, going.rect.width > coming.rect.width && coming.rect.width < size)
					testing.expect(t, going.opacity > coming.opacity && coming.opacity < 1)
				case 0.5:
					testing.expect(t, abs(going.rect.width - coming.rect.width) < 0.01 && going.rect.width < size)
					testing.expect(t, abs(going.opacity - coming.opacity) < 0.01 && going.opacity < 1)
				case 0.75:
					testing.expect_value(t, marks[1].badge.atlas, a)
					testing.expect(t, coming.rect.width > going.rect.width && going.rect.width < size)
					testing.expect(t, coming.opacity > going.opacity)
				}
			}

			// Drawn a quarter of the way, the old front's glyph draws last, where the sphere put it, inside the
			// badge column.
			tab.turn.progress = 0.25
			marks, _ := ui.tab_spin_marks(tile, tab, scale)
			render.draw_list_reset(&list)
			_ = render.push_layer(&list, everything)
			testing.expect_value(t, ui.tab_badge_draw(&list, &text, theme, tile, tab, scale), render.Build_Status.Ok)
			last := -1
			for g, i in list.glyphs {if g.atlas == b {last = i}}
			if testing.expect(t, last == len(list.glyphs) - 1) {
				drawn := list.glyphs[last].rect
				testing.expect(t, abs(centre(drawn).x - centre(marks[1].rect).x) < 0.01)
				testing.expect(t, abs(centre(drawn).y - centre(marks[1].rect).y) < 0.01)
			}
			column_right := tile.x + (ui.CONTROL_INSET + ui.TAB_BADGE_COLUMN + ui.TAB_SPIN_MARGIN) * scale
			for layer in list.layers[1:len(list.layers) - 1] {
				testing.expect(t, layer.clip.x + layer.clip.width <= column_right + 0.01)
			}
			testing.expect_value(t, list.layers[len(list.layers) - 1].clip, everything)

			// Focus moved from B, with A behind it, to C, new to the stack, with A still behind it.
			fresh := ui.Tab_Tile{title = "New", badge = {atlas = c}, behind = {atlas = a}}
			fresh.turn = {turning = true, title = "Old", badge = {atlas = b}, behind = {atlas = a}, toward = toward}
			Seen :: struct {
				incoming, outgoing, staying: ui.Tab_Spin_Mark,
			}
			seen: [2]Seen
			for progress, i in ([?]f32{0.25, 0.75}) {
				fresh.turn.progress = progress
				spun, count := ui.tab_spin_marks(tile, fresh, scale)
				if !testing.expect_value(t, count, 3) {break}
				for mark in spun[:count] {
					if mark.badge.atlas == c {seen[i].incoming = mark}
					if mark.badge.atlas == b {seen[i].outgoing = mark}
					if mark.badge.atlas == a {seen[i].staying = mark}
				}
				testing.expect(t, near(seen[i].staying.rect, back))
				testing.expect_value(t, seen[i].staying.opacity, 1)
			}
			testing.expect(t, seen[0].incoming.opacity < seen[0].outgoing.opacity)
			testing.expect(t, seen[1].incoming.opacity > seen[1].outgoing.opacity)
			came := centre(seen[1].incoming.rect) - centre(seen[0].incoming.rect)
			testing.expect(t, came.x * (centre(front) - centre(back)).x >= 0, "the new mark comes forward")
		}
	}
}

// WORK-483: titles slide across their box the way focus moved and fade only as a title fades at rest, toward
// the box's right end; nothing fades at the left, and a title sliding up or down keeps its colour.
@(test)
tab_turn_slides_the_title_fading_only_at_the_right :: proc(t: ^testing.T) {
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
		box := render.Rect{40 * scale, 4 * scale, 120 * scale, 32 * scale}
		right := box.x + box.width
		ink := theme.tab_text
		tab := ui.Tab_Tile{title = "New"}
		tab.turn = {turning = true, title = "Old"}
		old_rest, new_rest: [8]render.Glyph_Instance
		old_count := turn_title(&list, &text, {title = "Old"}, box, ink, scale, everything, old_rest[:])
		new_count := turn_title(&list, &text, {title = "New"}, box, ink, scale, everything, new_rest[:])
		if !testing.expect(t, old_count > 0 && new_count > 0) {continue}
		line := text.line_height + 2 * ui.TAB_TURN_LINE_PAD * scale
		for toward in ([?][2]f32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			for progress in ([?]f32{0.25, 0.5, 0.75}) {
				sliding := tab
				sliding.turn.progress = progress
				sliding.turn.toward = toward
				drawn: [16]render.Glyph_Instance
				count := turn_title(&list, &text, sliding, box, ink, scale, everything, drawn[:])
				if !testing.expect(t, count >= old_count + new_count) {continue}
				leaving, entering := ui.tab_turn_offsets(sliding.turn, {box.width, line})
				testing.expect_value(t, leaving, -toward * progress * [2]f32{box.width, line})
				testing.expect_value(t, entering, toward * (1 - progress) * [2]f32{box.width, line})
				old, new := drawn[0], drawn[count - new_count]
				moved_old := [2]f32{old.rect.x - old_rest[0].rect.x, old.rect.y - old_rest[0].rect.y}
				moved_new := [2]f32{new.rect.x - new_rest[0].rect.x, new.rect.y - new_rest[0].rect.y}
				testing.expectf(t, abs(moved_old.x - leaving.x) < 0.01 && abs(moved_old.y - leaving.y) < 0.01,
					"toward %v at %v: old title moved %v", toward, progress, moved_old)
				testing.expectf(t, abs(moved_new.x - entering.x) < 0.01 && abs(moved_new.y - entering.y) < 0.01,
					"toward %v at %v: new title moved %v", toward, progress, moved_new)
				// Every glyph fades only over the box's last fifth or less, toward its right end.
				for g in drawn[:count] {
					testing.expect(t, g.flags & render.GLYPH_FADE != 0)
					testing.expect_value(t, g.fade_end, right)
					testing.expectf(t, g.fade_start >= box.x + box.width * 0.8 - 0.01 && g.fade_start <= right,
						"toward %v at %v: a fade starts at %v", toward, progress, g.fade_start)
					testing.expect_value(t, g.color.a, old_rest[0].color.a)
				}
			}
		}
		// A turn between the same titles draws the title once, in place.
		same := tab
		same.turn.title = "New"
		same.turn.progress = 0.25
		drawn: [8]render.Glyph_Instance
		testing.expect_value(t, turn_title(&list, &text, same, box, ink, scale, everything, drawn[:]), new_count)
		testing.expect_value(t, drawn[0].rect, new_rest[0].rect)
	}
}

// Whether two rectangles match to a hundredth of a pixel.
@(private = "file")
near :: proc(a, b: render.Rect) -> bool {
	return abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 && abs(a.width - b.width) < 0.01 &&
		abs(a.height - b.height) < 0.01
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

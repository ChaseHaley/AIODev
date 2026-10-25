package ui_test

import "core:testing"
import "aio:commands"
import "aio:settings"
import "aio:ui"

// The chrome claims caption presses before surfaces hit-tested after it, so the
// claim height is the boundary both the hit test and the placement read.
@(test)
caption_claim_and_hit_test_share_one_boundary :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2, 3}) {
		width := 1000 * scale
		claim := ui.caption_claim_height(scale)
		testing.expect_value(t, claim, ui.TAB_HEIGHT * scale)
		testing.expect_value(t, ui.caption_hit(width, width - 10 * scale, claim, scale), -1)
		testing.expect_value(t, ui.caption_hit(width, width - 10 * scale, claim - 1, scale), 2)
		for i in 0 ..< 3 {
			x := width - 138 * scale + (f32(i) * 46 + 20) * scale
			testing.expect_value(t, ui.caption_hit(width, x, claim - 1, scale), i)
		}
	}
}

@(test)
find_starts_below_the_caption_claim_at_each_width_and_scale :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2, 3}) {
		for width in ([?]f32{240, 300, 380, 460, 1000, 1600}) {
			l := ui.find_layout(width * scale, scale, 50 * scale)
			testing.expectf(t, l.panel.y > ui.caption_claim_height(scale),
				"find panel %v starts in the caption claim at %gx%g", l.panel, width, scale)
		}
	}
}

// A client with room for eight rows keeps them; one without gives up a row rather
// than start the query inside the caption band.
@(test)
palette_starts_below_the_caption_claim_and_fits_its_area :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]ui.Palette_Setting
	for entry, i in settings.SCHEMA { rows[i] = {entry.key, entry.title, settings.group_title(entry.key)} }
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) { return }
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "setting")
	for viewport in ([?][3]f32{
		{926, 928, 2},
		{926, 837, 2},
		{695, 696, 1.5},
		{1000, 800, 1},
		{1000, 400, 1},
		{463, 240, 1.5},
		{463, 240, 0.5},
		{160, 100, 2},
	}) {
		w, h, scale := viewport[0], viewport[1], viewport[2]
		l := ui.palette_layout(&p, w, h, scale)
		testing.expectf(t, l.panel.y >= min(h, ui.caption_claim_height(scale)),
			"palette panel %v starts in the caption claim at %gx%g scale %g", l.panel, w, h, scale)
		testing.expectf(t, l.panel.y+l.panel.height <= h, "palette panel %v exceeds %gx%g",
			l.panel, w, h)
		testing.expect(t, l.input.y >= l.panel.y && l.list.y >= l.panel.y)
		testing.expect(t, l.input.y+l.input.height <= l.panel.y+l.panel.height)
	}
	l := ui.palette_layout(&p, 926, 928, 2)
	// The section headers and footer fit inside the caption claim, so the panel starts at
	// the claim and keeps six of the eight result rows.
	testing.expect_value(t, l.panel.y, f32(80))
	testing.expect_value(t, l.rows, 6)
	l = ui.palette_layout(&p, 926, 837, 2)
	testing.expect_value(t, l.panel.y, f32(80))
	testing.expect_value(t, l.rows, 5)
	// The panel used to start at y 1.5 here, over the caption controls.
	l = ui.palette_layout(&p, 463, 240, 1.5)
	testing.expect_value(t, l.panel.y, f32(60))
	testing.expect(t, l.panel.height > 0)
	testing.expect(t, l.panel.x >= 0 && l.panel.x+l.panel.width <= 463)
}

// The confirm dialog is placed after the chrome but never fits the window while it
// starts inside the claim, so its placement needs no clamp.
@(test)
confirm_clears_the_caption_claim_whenever_it_fits_the_window :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2, 3}) {
		for height in ([?]f32{100, 150, 180, 190, 200, 240, 400, 700}) {
			for extended in ([?]bool{false, true}) {
				l := ui.confirm_layout(1000 * scale, height * scale, scale, extended)
				if l.panel.y+l.panel.height > height * scale { continue }
				testing.expectf(t, l.panel.y >= ui.caption_claim_height(scale),
					"confirm panel %v fits %gx%g but starts in the caption claim", l.panel,
					height, scale)
			}
		}
	}
}

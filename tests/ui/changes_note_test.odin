package ui_test

import "cosmos:font"
import "cosmos:glyphs"
import "aio:markdown"
import "cosmos:render"
import "aio:turns"
import "aio:ui"
import "core:math"
import "core:testing"

@(private = "file")
Note_Fixture :: struct {
	fonts:      ^font.System,
	text, mono: ui.Text,
	lines:      [6]turns.Diff_Line,
	hunks:      [1]turns.Hunk,
	files:      [1]turns.Diff_File,
	notes:      [3]ui.Changes_Comment_View,
	area:       ui.Text_Area,
	buffer:     markdown.Edit_Buffer,
	cache:      glyphs.Cache,
	device:     ^render.Device,
}

// One file with one hunk of six lines.
@(private = "file")
note_make :: proc(t: ^testing.T, f: ^Note_Fixture, view: ^ui.Changes_View) -> bool {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return false}
	f.device = device
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	glyphs.init(&f.cache, f.fonts, device)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &f.cache, 13)) {return false}
	f.mono = ui.text_mono(&f.text, f.text.family)
	f.lines = {
		{kind = .Context, old_line = 1, new_line = 1, text = "alpha beta gamma"},
		{kind = .Removed, old_line = 2, text = "gone"},
		{kind = .Added, new_line = 2, text = "delta epsilon zeta"},
		{kind = .Context, old_line = 3, new_line = 3, text = "tail"},
		{kind = .Context, old_line = 4, new_line = 4, text = "more"},
		{kind = .Context, old_line = 5, new_line = 5, text = "last"},
	}
	f.hunks = {{old_start = 1, old_count = 5, new_start = 1, new_count = 5, lines = f.lines[:]}}
	f.files = {{old_path = "a.odin", new_path = "a.odin", status = .Modified, hunks = f.hunks[:]}}
	view^ = {
		scope            = .Uncommitted,
		first            = -1,
		last             = -1,
		files            = f.files[:],
		editing          = -1,
		editor           = &f.area,
		buffer           = &f.buffer,
		revision         = 1,
		minimum_contrast = 4.5,
	}
	return true
}

@(private = "file")
note_destroy :: proc(f: ^Note_Fixture) {
	markdown.edit_buffer_destroy(&f.buffer)
	ui.text_area_destroy(&f.area)
	glyphs.destroy(&f.cache)
	font.system_destroy(f.fonts)
	render.device_destroy(f.device)
}

@(private = "file")
note_theme :: proc() -> ui.Theme {
	theme: ui.Theme
	theme.text, theme.muted, theme.faint = {0, 0, 0, 1}, {0.3, 0.3, 0.3, 1}, {0.5, 0.5, 0.5, 1}
	theme.surface, theme.pane = {1, 1, 1, 1}, {0.97, 0.97, 0.97, 1}
	theme.border = {0.2, 0.4, 0.6, 1}
	theme.hover = {0.8, 0.8, 0.8, 1}
	theme.code_background = {0.1, 0.3, 0.2, 1}
	theme.accent, theme.accent_text = {0.5, 0, 1, 1}, {1, 1, 1, 1}
	theme.error = {0.8, 0, 0, 1}
	return theme
}

@(private = "file")
note_near :: proc(a, b: f32) -> bool {return abs(a - b) < 0.01}

@(private = "file")
note_colour_near :: proc(a, b: render.Color) -> bool {
	return note_near(a.r, b.r) && note_near(a.g, b.g) && note_near(a.b, b.b) && note_near(a.a, b.a)
}

// Lays the pane out `width` wide and draws it.
@(private = "file")
note_draw :: proc(
	t: ^testing.T,
	f: ^Note_Fixture,
	list: ^render.Draw_List,
	theme: ^ui.Theme,
	view: ^ui.Changes_View,
	state: ^ui.Changes_State,
	width: f32 = 900,
) -> (
	g: ui.Changes_Geometry,
	ok: bool,
) {
	g = ui.changes_geometry({0, 0, width, 600}, 1, view, &f.text, state)
	ui.changes_layout(state, view, &f.text, &f.mono, g.diff.width, 1)
	render.draw_list_reset(list)
	if !testing.expect_value(t, render.push_layer(list, g.area), render.Error.None) {return}
	status, _ := ui.changes_draw(list, &f.text, &f.mono, theme, g, view, state, 1, {-1, -1}, 0)
	return g, testing.expect_value(t, status, render.Build_Status.Ok)
}

@(private = "file")
note_rects :: proc(list: ^render.Draw_List, color: render.Color) -> [dynamic]render.Rect {
	found: [dynamic]render.Rect
	for r in list.rects {
		if note_colour_near(r.color, color) {append(&found, r.rect)}
	}
	return found
}

// Whether a rect of `rect`'s place is drawn in `color`.
@(private = "file")
note_has_rect :: proc(list: ^render.Draw_List, rect: render.Rect, color: render.Color) -> bool {
	for r in list.rects {
		if r.rect == rect && note_colour_near(r.color, color) {return true}
	}
	return false
}

@(test)
a_note_card_is_as_tall_as_its_body_needs_at_the_width_it_is_painted :: proc(t: ^testing.T) {
	f: Note_Fixture
	view: ui.Changes_View
	if !note_make(t, &f, &view) {return}
	defer note_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme := note_theme()
	text := "First **bold** and `code`.\n```odin\nfoo()\nbar()\n```\nLast words."

	// A plain comment has no first line: its text leaves room at the right for Edit and Remove, and the card is
	// the padding, the body laid out at that width, and the padding.
	f.notes[0] = {file = 0, first = 3, last = 3, text = text}
	view.comments = f.notes[:1]
	g, ok := note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	card, shown := ui.changes_card_rect(g, &view, &state, 0)
	if !testing.expect(t, shown) {return}
	layout := ui.note_body_layout(&f.text, &f.mono, text, nil, card.width - 16 - 48, 1)
	testing.expect_value(t, state.rows.cards[0], int(math.round(16 + layout.height)))
	testing.expect_value(t, card.height, f32(state.rows.cards[0]))
	testing.expect(t, note_has_rect(&list, card, theme.surface), "the card is painted at its measured height")
	// The code block's frame is painted inside the card, within its padding.
	found := false
	frames := note_rects(&list, theme.code_background)
	defer delete(frames)
	for frame in frames {
		if frame.y < card.y || frame.y > card.y + card.height {continue}
		found = true
		testing.expect(t, frame.x >= card.x + 8 - 0.01 && frame.x + frame.width <= card.x + card.width - 8 + 0.01)
		testing.expect(t, frame.y + frame.height <= card.y + card.height - 8 + 0.01)
	}
	testing.expect(t, found, "the note's code block has a frame")

	// With a tag the first line holds it and the body takes the card's whole inner width below it.
	f.notes[0].kind, f.notes[0].label_name, f.notes[0].label_colour = .Label, "Clarify", "blue"
	g, ok = note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	card, _ = ui.changes_card_rect(g, &view, &state, 0)
	layout = ui.note_body_layout(&f.text, &f.mono, text, nil, card.width - 16, 1)
	testing.expect_value(t, state.rows.cards[0], int(math.round(8 + 18 + 4 + layout.height + 8)))
	testing.expect(t, note_has_rect(&list, card, theme.surface))
}

@(test)
a_card_has_a_first_line_only_for_a_tag_or_an_excerpt :: proc(t: ^testing.T) {
	f: Note_Fixture
	view: ui.Changes_View
	if !note_make(t, &f, &view) {return}
	defer note_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text, &state)

	f.notes[0] = {file = 0, first = 0, last = 0, text = "Hi"}
	f.notes[1] = {file = 0, first = 2, last = 2, text = "Hi", partial = true, first_offset = 2, last_offset = 8}
	f.notes[2] = {file = 0, first = 3, last = 3, kind = .Delete}
	view.comments = f.notes[:]
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	plain, excerpt, tag := state.rows.cards[0], state.rows.cards[1], state.rows.cards[2]
	// The first line is 18 high with a gap of 4 below it when there is text.
	testing.expect_value(t, excerpt, plain + 18 + 4)
	// A deletion with no text is the first line alone, in the padding.
	testing.expect_value(t, tag, 8 + 18 + 8)
	// Out of the way of the buttons, a card is never shorter than they are.
	f.notes[0].text = ""
	f.notes[0].kind = .Comment
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	testing.expect(t, state.rows.cards[0] >= 22 + 2 * 3)
}

@(test)
edit_and_remove_show_on_hover_and_always_in_a_narrow_pane :: proc(t: ^testing.T) {
	f: Note_Fixture
	view: ui.Changes_View
	if !note_make(t, &f, &view) {return}
	defer note_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme := note_theme()
	f.notes[0] = {file = 0, first = 0, last = 0, text = "Why?"}
	view.comments = f.notes[:1]

	backing :: proc(g: ui.Changes_Geometry, view: ^ui.Changes_View, state: ^ui.Changes_State) -> render.Rect {
		card, _ := ui.changes_card_rect(g, view, state, 0)
		edit, remove := ui.changes_note_actions(card, 1)
		return {edit.x, edit.y, remove.x + remove.width - edit.x, edit.height}
	}
	g, ok := note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	testing.expect(t, !note_has_rect(&list, backing(g, &view, &state), theme.surface), "hidden until pointed at")
	for hover in ([?]ui.Changes_Hit{{.Comment_Card, 0, 0}, {.Comment_Edit, 0, 0}, {.Comment_Remove, 0, 0}}) {
		state.hover = hover
		g, ok = note_draw(t, &f, &list, &theme, &view, &state)
		if !ok {return}
		testing.expect(t, note_has_rect(&list, backing(g, &view, &state), theme.surface), "shown on hover")
	}
	state.hover = {}
	g, ok = note_draw(t, &f, &list, &theme, &view, &state, 300)
	if !ok {return}
	testing.expect(t, note_has_rect(&list, backing(g, &view, &state), theme.surface), "shown when narrow")
}

@(test)
a_card_points_at_its_lines_with_a_notch_unless_they_are_not_in_the_diff :: proc(t: ^testing.T) {
	f: Note_Fixture
	view: ui.Changes_View
	if !note_make(t, &f, &view) {return}
	defer note_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme := note_theme()
	f.notes[0] = {file = 0, first = 0, last = 0, text = "Why?"}
	view.comments = f.notes[:1]

	segments := proc(list: ^render.Draw_List, color: render.Color) -> (count: int) {
		for r in list.rects {
			if r.fill == render.RECT_FILL_SEGMENT && note_colour_near(r.color, color) {count += 1}
		}
		return
	}
	g, ok := note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	card, _ := ui.changes_card_rect(g, &view, &state, 0)
	testing.expect_value(t, segments(&list, theme.border), 2)
	// Its point is above the card's top edge, over the lines' code column.
	apex := f32(1e9)
	for r in list.rects {
		if r.fill == render.RECT_FILL_SEGMENT && note_colour_near(r.color, theme.border) {apex = min(apex, r.rect.y)}
	}
	testing.expect(t, apex < card.y && apex >= card.y - 6 - 1)
	f.notes[0].detached = true
	g, ok = note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	testing.expect_value(t, segments(&list, theme.border), 0)
}

@(test)
a_tags_words_are_lifted_to_the_minimum_contrast_against_its_tint :: proc(t: ^testing.T) {
	f: Note_Fixture
	view: ui.Changes_View
	if !note_make(t, &f, &view) {return}
	defer note_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme := note_theme()
	f.notes[0] = {file = 0, first = 0, last = 0, kind = .Label, label_name = "Verify", label_colour = "#ff8800"}
	view.comments = f.notes[:1]
	g, ok := note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	card, _ := ui.changes_card_rect(g, &view, &state, 0)

	// The tag's tint is 14 % of the colour on the card, and its words are the colour lifted against that.
	raw := ui.quick_label_color(theme, "#ff8800")
	tint := render.Color {
		raw.r * 0.14 + theme.surface.r * 0.86,
		raw.g * 0.14 + theme.surface.g * 0.86,
		raw.b * 0.14 + theme.surface.b * 0.86,
		1,
	}
	want := ui.quick_label_ink(theme, "#ff8800", tint, 4.5)
	testing.expect(t, !note_colour_near(want, raw), "the colour alone is too faint on its tint")
	words := 0
	for glyph in list.glyphs {
		inside := glyph.rect.y >= card.y && glyph.rect.y <= card.y + card.height
		if inside && note_colour_near(glyph.color, want) {words += 1}
	}
	testing.expect(t, words >= len("Verify"), "the tag's words are inked with the lifted colour")
}

@(test)
the_editor_card_draws_a_save_that_waits_for_words :: proc(t: ^testing.T) {
	f: Note_Fixture
	view: ui.Changes_View
	if !note_make(t, &f, &view) {return}
	defer note_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme := note_theme()
	view.selection = {file = 0, first = 2, last = 2, active = true}
	view.editing = 0

	// A new plain comment with no words: Save is the primary button at its disabled opacity.
	faint := theme.accent
	faint.a *= 0.45
	g, ok := note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	parts, shown := ui.changes_editor_of(g, &view, &state)
	if !testing.expect(t, shown) {return}
	testing.expect(t, note_has_rect(&list, parts.save, faint))
	testing.expect(t, !ui.changes_editor_can_save(&view))
	// The text area is the field's frame, and the card is in the focus ring over its fill.
	testing.expect(t, note_has_rect(&list, parts.area, theme.border))
	testing.expect(t, note_has_rect(&list, parts.card, theme.surface))

	// With words it is saveable and drawn in full; a label or a deletion needs none.
	testing.expect(t, markdown.edit_buffer_reset(&f.buffer, "Looks off."))
	g, ok = note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	parts, _ = ui.changes_editor_of(g, &view, &state)
	testing.expect(t, ui.changes_editor_can_save(&view))
	testing.expect(t, !note_has_rect(&list, parts.save, faint))
	testing.expect(t, markdown.edit_buffer_reset(&f.buffer, "  \n "))
	testing.expect(t, !ui.changes_editor_can_save(&view), "spaces are not words")
	view.draft = .Delete
	testing.expect(t, ui.changes_editor_can_save(&view))
	view.draft = .Label
	testing.expect(t, ui.changes_editor_can_save(&view))

	// Suggest change is the tool that a selection of only removed lines turns off.
	view.draft = .Comment
	view.span = {first = 2, last = 2, old = true}
	g, ok = note_draw(t, &f, &list, &theme, &view, &state)
	if !ok {return}
	testing.expect_value(t, ui.changes_editor_placeholder(.Comment), "Leave a comment")
	testing.expect_value(t, ui.changes_editor_placeholder(.Label), "Add to the label (optional)")
	testing.expect_value(t, ui.changes_editor_placeholder(.Delete), "Why delete it? (optional)")
}

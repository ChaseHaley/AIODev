package ui_test

import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:input"
import "aio:platform"
import "cosmos:render"
import "aio:ui"
import "core:testing"

@(private = "file")
FILES :: [?]string{"live.py", "long.txt", "notes.txt", "src/Live.py"}

@(private = "file")
ANCHOR :: ui.Dropdown_Anchor {
	field  = {10, 10, 300, 24},
	row    = {10, 10, 300, 24},
	bounds = {0, 0, 800, 600},
}

@(private = "file")
shown :: proc(d: ^ui.Dropdown, c: ui.Dropdown_Choices) -> (labels: [4]string, count: int) {
	count = ui.dropdown_count(d, c)
	for i in 0 ..< min(count, len(labels)) {
		labels[i] = c.choices[d.matches[i]]
	}
	return
}

@(private = "file")
retype :: proc(d: ^ui.Dropdown, c: ui.Dropdown_Choices, query: string) {
	ui.dropdown_open(d, c)
	ui.dropdown_text(d, c, query)
}

@(test)
dropdown_regex_toggle_switches_the_search_to_regular_expressions :: proc(t: ^testing.T) {
	files := FILES
	c := ui.Dropdown_Choices {
		choices      = files[:],
		searchable   = true,
		regex_toggle = true,
	}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)

	// Off, the pattern is plain text that no path contains.
	retype(&d, c, `^l.*\.py$`)
	testing.expect_value(t, ui.dropdown_count(&d, c), 0)
	testing.expect_value(t, ui.dropdown_empty_text(&d, c), "No fonts found")

	// On, it matches from the start of the path; the toggle stays on across opens.
	d.regex = true
	retype(&d, c, `^l.*\.py$`)
	labels, count := shown(&d, c)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, labels[0], "live.py")
	testing.expect_value(t, ui.dropdown_empty_text(&d, c), "")
	retype(&d, c, "live")
	labels, count = shown(&d, c)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, labels[1], "src/Live.py")

	// An invalid pattern matches nothing and says so, ahead of the list's own empty text.
	retype(&d, c, "[")
	testing.expect_value(t, ui.dropdown_count(&d, c), 0)
	testing.expect_value(t, ui.dropdown_empty_text(&d, c), "Invalid regular expression")
	files_list := c
	files_list.empty_text = "No matching files"
	testing.expect_value(t, ui.dropdown_empty_text(&d, files_list), "Invalid regular expression")
	retype(&d, files_list, "zzz")
	testing.expect_value(t, ui.dropdown_empty_text(&d, files_list), "No matching files")

	// A list without the toggle keeps plain matching whatever the Dropdown remembers.
	plain := c
	plain.regex_toggle = false
	retype(&d, plain, "[")
	testing.expect_value(t, ui.dropdown_empty_text(&d, plain), "No fonts found")
	plain.empty_text = "No matching files"
	testing.expect_value(t, ui.dropdown_empty_text(&d, plain), "No matching files")
	retype(&d, plain, ".txt")
	testing.expect_value(t, ui.dropdown_count(&d, plain), 2)
}

@(test)
dropdown_regex_toggle_answers_alt_r_and_presses :: proc(t: ^testing.T) {
	files := FILES
	c := ui.Dropdown_Choices {
		choices      = files[:],
		searchable   = true,
		regex_toggle = true,
	}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)
	retype(&d, c, `t$`)
	testing.expect_value(t, ui.dropdown_count(&d, c), 0)

	alt_r := input.Key_Event {
		key       = .R,
		modifiers = {.Alt},
		pressed   = true,
	}
	outcome, taken := ui.dropdown_key(&d, c, ANCHOR, alt_r, 1)
	testing.expect_value(t, outcome, ui.Dropdown_Outcome.Changed)
	testing.expect(t, taken)
	testing.expect(t, d.regex)
	testing.expect_value(t, ui.dropdown_count(&d, c), 2)
	// Ctrl+Alt is AltGr on Windows, which types characters rather than toggling.
	alt_gr := alt_r
	alt_gr.modifiers = {.Control, .Alt}
	_, _ = ui.dropdown_key(&d, c, ANCHOR, alt_gr, 1)
	testing.expect(t, d.regex)

	// The toggle sits inside the search field at its right; a press flips it back and leaves the query.
	r := ui.dropdown_regex_rect(&d, c, ANCHOR, 1)
	popup := ui.dropdown_rect(&d, c, ANCHOR, 1)
	testing.expect(t, r.width > 0 && r.x + r.width <= popup.x + popup.width && r.y >= popup.y)
	x, y := r.x + r.width / 2, r.y + r.height / 2
	// Entering and leaving the toggle report a change, so its hover draws at once.
	testing.expect(t, ui.dropdown_hover(&d, c, ANCHOR, x, y, 1))
	testing.expect(t, d.regex_hover)
	testing.expect(t, !ui.dropdown_hover(&d, c, ANCHOR, x + 1, y, 1))
	testing.expect(t, ui.dropdown_hover(&d, c, ANCHOR, r.x - 20, y, 1))
	testing.expect(t, !d.regex_hover)
	testing.expect_value(t, ui.dropdown_pointer(&d, c, ANCHOR, x, y, 1), platform.Cursor_Shape.Hand)
	testing.expect_value(t, ui.dropdown_pointer(&d, c, ANCHOR, r.x - 20, y, 1), platform.Cursor_Shape.Text)
	pressed := ui.dropdown_press(&d, c, ANCHOR, nil, x, y, false, 1)
	testing.expect_value(t, pressed, ui.Dropdown_Outcome.Changed)
	testing.expect(t, !d.regex)
	testing.expect_value(t, ui.field_string(&d.search), "t$")
	testing.expect_value(t, ui.dropdown_count(&d, c), 0)

	// Lists without the toggle have no rect for it and leave Alt+R alone.
	plain := c
	plain.regex_toggle = false
	testing.expect_value(t, ui.dropdown_regex_rect(&d, plain, ANCHOR, 1), render.Rect{})
	_, _ = ui.dropdown_key(&d, plain, ANCHOR, alt_r, 1)
	testing.expect(t, !d.regex)
}

@(test)
dropdown_faded_choices_draw_faded_and_stay_pickable :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 13)) {return}

	files := FILES
	faded := [len(FILES)]bool{false, true, false, false}
	c := ui.Dropdown_Choices {
		choices    = files[:],
		searchable = true,
		faded      = faded[:],
	}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)
	ui.dropdown_open(&d, c)

	theme: ui.Theme
	theme.text = {1, 1, 1, 1}
	theme.muted = {0.5, 0.5, 0.5, 1}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	testing.expect_value(
		t, ui.dropdown_draw(&d, c, ANCHOR, &list, &text, theme, {-1, -1}, 1), render.Build_Status.Ok,
	)
	dim, bright := 0, 0
	for glyph in list.glyphs {
		if glyph.color == (render.Color{0.5, 0.5, 0.5, 0.45}) {dim += 1}
		if glyph.color == theme.text {bright += 1}
	}
	testing.expect_value(t, dim, len("long.txt"))
	testing.expect(t, bright >= len("live.py") + len("notes.txt"))

	// The faded choice still takes the hover and a press picks it.
	popup := ui.dropdown_rect(&d, c, ANCHOR, 1)
	header := ui.dropdown_header(c, 1)
	y := popup.y + header + 4 + 1.5 * 32
	x := popup.x + 40
	ui.dropdown_hover(&d, c, ANCHOR, x, y, 1)
	testing.expect_value(t, ui.dropdown_highlighted(&d, c), 1)
	testing.expect_value(t, ui.dropdown_press(&d, c, ANCHOR, nil, x, y, false, 1), ui.Dropdown_Outcome.Chosen)
	testing.expect_value(t, ui.dropdown_highlighted(&d, c), 1)
}

@(test)
dropdown_search_text_is_matched_in_place_of_decorated_labels :: proc(t: ^testing.T) {
	files := FILES
	labels := [len(FILES)]string {
		"A live.py  +4 −0", "M long.txt  +1 −1", "M notes.txt  +2 −0", "D src/Live.py",
	}
	c := ui.Dropdown_Choices {
		choices      = files[:],
		labels       = labels[:],
		searchable   = true,
		regex_toggle = true,
	}
	d: ui.Dropdown
	ui.dropdown_init(&d)
	defer ui.dropdown_destroy(&d)
	d.regex = true

	// The labels' status marks and counts keep an anchored pattern from matching them.
	retype(&d, c, `^l.*\.py$`)
	testing.expect_value(t, ui.dropdown_count(&d, c), 0)

	// Searching the paths instead finds the file, for regular expressions and plain text alike.
	c.search_text = files[:]
	retype(&d, c, `^l.*\.py$`)
	found, count := shown(&d, c)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, found[0], "live.py")
	d.regex = false
	retype(&d, c, "+")
	testing.expect_value(t, ui.dropdown_count(&d, c), 0)
	c.search_text = nil
	retype(&d, c, "+")
	testing.expect_value(t, ui.dropdown_count(&d, c), 3)
}

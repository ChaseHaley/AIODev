package app_test

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:commands"
import "aio:layout"
import "cosmos:render"
import "aio:term"
import "aio:views"
import "cosmos:ui"

// A pane in a float keeps its split, view and close controls; floating and linking belong to tiled panes.
// Edit and Open in Default App belong to a pane showing a file.
@(test)
pane_headers_in_a_float_drop_float_and_linked_window :: proc(t: ^testing.T) {
	w := new(app.Window)
	defer free(w)
	w.scale = 1
	for kind in ([?]layout.Content_Kind{.Terminal, .Markdown}) {
		tiled := layout.Pane_Rect{content = {kind, 1}, rect = {0, 0, 640, 200}}
		floating := tiled
		floating.floating = true
		in_tile, in_float := app.pane_header_layout(w, tiled), app.pane_header_layout(w, floating)
		for button in app.Pane_Header_Button {
			owned := true
			#partial switch button {
			case .Edit, .Default_App: owned = kind == .Markdown
			case .Commands: owned = kind == .Terminal
			}
			testing.expectf(t, (in_tile.buttons[button].width > 0) == owned, "a tiled %v header and %v", kind, button)
			kept := owned && button != .Dock && button != .Linked_Window
			testing.expectf(t, (in_float.buttons[button].width > 0) == kept, "a floating %v header and %v", kind,
				button)
		}
	}
}

// A header button's picture is the window as pressing the button leaves it: every pane where it ends up,
// and the chosen one where the button's pane, or the pane a split adds, lands. The pane is not focused yet,
// as pressing its header focuses it first.
@(test)
pane_header_previews_show_what_the_buttons_do :: proc(t: ^testing.T) {
	Case :: struct {
		button: app.Pane_Header_Button,
		action: app.Action,
	}
	cases := [?]Case {
		{.Split_Right, .Split_Right},
		{.Split_Down, .Split_Down},
		{.Zoom, .Zoom_Pane},
		{.Fill_Window, .Fill_Window_Pane},
		{.Dock, .Float_Pane},
		{.Linked_Window, .Linked_Window},
	}
	for c in cases {
		f: Palette_Fixture
		defer palette_fixture_destroy(t, &f)
		if !palette_fixture_create(t, &f, fmt.tprintf("header-preview-%v", c.button), second_window = false) {
			return
		}
		s, w := &f.state, f.state.windows[0]
		s.animations = false
		app.pane_split(s, w, .Right)
		if !testing.expect_value(t, len(w.panes), 2) {return}
		pane, other := w.panes[0], w.panes[1]
		card := app.pane_header_card(s, w, pane, c.button)
		preview, pictured := card.preview.?
		if !testing.expectf(t, pictured && card.description != "", "%v shows a picture", c.button) {continue}
		app.pane_focus(s, w, pane.node)
		app.run_action(s, w, c.action)
		if !testing.expectf(t, len(preview.panes) == len(w.panes), "%v: %d panes pictured, %d shown",
			c.button, len(preview.panes), len(w.panes)) {continue}
		for shown, i in w.panes {
			r := shown.rect
			testing.expectf(t, preview.panes[i] == render.Rect{r.x, r.y, r.width, r.height},
				"%v: pane %d pictured at %v, shown at %v", c.button, i, preview.panes[i], r)
		}
		switch c.button {
		case .Split_Right, .Split_Down:
			added := w.panes[preview.pane].content
			fresh := added != pane.content && added != other.content
			testing.expectf(t, fresh, "%v picks the new pane", c.button)
		case .Linked_Window:
			testing.expect_value(t, preview.pane, -1)
			testing.expect_value(t, preview.away, [2]f32{pane.rect.width, pane.rect.height})
		case .Links, .Commands, .Edit, .Default_App, .Zoom, .Fill_Window, .Dock, .Close:
			testing.expectf(t, w.panes[preview.pane].content == pane.content, "%v picks its pane", c.button)
		}
	}
}

// A button the window would refuse draws disabled, takes no press and says why in its tooltip card; it comes
// back once the refusal no longer holds.
@(test)
refused_header_buttons_are_disabled_and_say_why :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "header-refused", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.animations = false
	if !testing.expect_value(t, len(w.panes), 1) {return}
	pane := w.panes[0]
	testing.expect_value(t, app.pane_header_refused(w, pane, .Dock), app.Pane_Header_Refusal.Last_Tiled)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Linked_Window), app.Pane_Header_Refusal.Keeps_One)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Split_Right), app.Pane_Header_Refusal.None)
	card := app.pane_header_card(s, w, pane, .Dock)
	testing.expect_value(t, card.description, app.PANE_HEADER_REFUSAL_TEXT[.Last_Tiled])
	testing.expect(t, card.preview == nil, "a refused button pictures nothing")
	notices := len(s.notices.items)
	gesture_click_header(s, w, .Dock, app.pane_header_layout(w, pane))
	gesture_click_header(s, w, .Linked_Window, app.pane_header_layout(w, pane))
	testing.expect_value(t, len(w.panes), 1)
	testing.expect(t, !w.panes[0].floating, "the disabled Float button floats nothing")
	testing.expect_value(t, len(s.windows), 1)
	testing.expect_value(t, len(s.notices.items), notices)

	// Too small to split: both split buttons are refused until the minimum allows them again.
	s.settings.pane.minimum_columns = 10_000
	app.window_relayout(s, w)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Split_Right), app.Pane_Header_Refusal.Minimum)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Split_Down), app.Pane_Header_Refusal.Minimum)
	gesture_click_header(s, w, .Split_Right, app.pane_header_layout(w, pane))
	testing.expect_value(t, len(w.panes), 1)
	s.settings.pane.minimum_columns = 0
	app.window_relayout(s, w)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Split_Right), app.Pane_Header_Refusal.None)
	gesture_click_header(s, w, .Split_Right, app.pane_header_layout(w, pane))
	if !testing.expect_value(t, len(w.panes), 2) {return}
	// With a second tiled pane the first can float, and linking it leaves the other here.
	testing.expect_value(t, app.pane_header_refused(w, w.panes[0], .Dock), app.Pane_Header_Refusal.None)
	testing.expect_value(t, app.pane_header_refused(w, w.panes[0], .Linked_Window), app.Pane_Header_Refusal.None)
}

// The Settings pane's header shows the Settings icon the tab strip, rail and float capsules show,
// rather than a keycap.
@(test)
settings_pane_header_shows_the_settings_icon :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "settings-header", second_window = false) {return}
	s := &f.state
	w := app.editor_open(s, s.windows[0])
	if !testing.expect(t, w != nil) {return}
	app.window_render(s, w)
	pane: layout.Pane_Rect
	found := false
	for candidate in w.panes {
		if candidate.content.kind == .Settings {pane, found = candidate, true}
	}
	if !testing.expect(t, found, "the settings pane is laid out") {return}
	badge := app.pane_header_layout(w, pane).badge
	area := render.Rect{0, 0, f32(w.width), f32(w.height)}
	render.draw_list_reset(&w.list)
	testing.expect_value(t, render.push_layer(&w.list, area), render.Error.None)
	testing.expect_value(t, app.pane_header_draw(s, w, pane, nil), render.Build_Status.Ok)
	for rect in w.list.rects {
		testing.expect(t, rect.rect != badge || rect.color != s.theme.selection, "no keycap behind the badge")
	}
	icon := render.draw_list_init()
	defer render.draw_list_destroy(&icon)
	testing.expect_value(t, render.push_layer(&icon, area), render.Error.None)
	ink := app.pane_shows_focus(w, pane) ? s.theme.text : s.theme.muted
	ui.icon_draw(&icon, .Settings, badge, ink, ui.ICON_BUTTON, w.scale)
	if !testing.expect(t, len(icon.rects) > 0) {return}
	drawn := false
	for start in 0 ..= len(w.list.rects) - len(icon.rects) {
		if slice.equal(w.list.rects[start:start + len(icon.rects)], icon.rects[:]) {drawn = true}
	}
	testing.expect(t, drawn, "the Settings icon is drawn in the badge")
}

// A header button's tooltip shows the shortcut of the command the button runs, as Settings binds it now: a
// refused button keeps its shortcut beside the reason, and a button whose command is unbound shows none.
@(test)
pane_header_tooltips_show_their_commands_shortcuts :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "header-shortcuts", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	if !testing.expect_value(t, len(w.panes), 1) {return}
	header_shortcut :: proc(s: ^app.App, w: ^app.Window, button: app.Pane_Header_Button) -> string {
		r := app.pane_header_layout(w, w.panes[0]).buttons[button]
		buffer: [commands.SHORTCUT_TEXT_CAP]u8
		shortcut := app.tooltip_shortcut(s, w, .Pane_Header, r.x + r.width / 2, r.y + r.height / 2, buffer[:])
		return strings.clone(shortcut, context.temp_allocator)
	}
	testing.expect_value(t, app.pane_header_refused(w, w.panes[0], .Dock), app.Pane_Header_Refusal.Last_Tiled)
	testing.expect_value(t, header_shortcut(s, w, .Split_Right), "Ctrl+Shift+O")
	testing.expect_value(t, header_shortcut(s, w, .Split_Down), "Ctrl+Shift+E")
	testing.expect_value(t, header_shortcut(s, w, .Fill_Window), "Ctrl+Shift+Enter")
	testing.expect_value(t, header_shortcut(s, w, .Dock), "Ctrl+Alt+Enter")
	testing.expect_value(t, header_shortcut(s, w, .Links), "")
	testing.expect_value(t, header_shortcut(s, w, .Close), "")

	existing, read_error := os.read_entire_file(f.path, context.temp_allocator)
	if !testing.expect_value(t, read_error, nil) {return}
	keys := "\nkeys.pane.split_right = Ctrl+Alt+F9\nkeys.pane.close = Ctrl+Alt+F4\n"
	rebound := strings.concatenate({string(existing), keys}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(f.path, transmute([]u8)rebound), nil) {return}
	app.reload_settings(s, false)
	testing.expect_value(t, header_shortcut(s, w, .Split_Right), "Ctrl+Alt+F9")
	testing.expect_value(t, header_shortcut(s, w, .Close), "Ctrl+Alt+F4")
	testing.expect_value(t, header_shortcut(s, w, .Split_Down), "Ctrl+Shift+E")
}

// The status pill `pane`'s header draws for a working program, found by its tint.
@(private = "file")
header_status_pill :: proc(s: ^app.App, w: ^app.Window, pane: layout.Pane_Rect) -> (render.Rect, bool) {
	statuses := [1]term.Program_Status{{app = "cargo", state = .Working, progress = 40, updated_at = time.now()}}
	entry := app.Session_Entry{id = 9_999, statuses = statuses[:]}
	render.draw_list_reset(&w.list)
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return {}, false}
	if app.pane_header_draw(s, w, pane, &entry) != .Ok {return {}, false}
	tint := views.status_color(s.theme, .Working)
	tint.a *= 0.16
	for rect in w.list.rects {if rect.color == tint {return rect.rect, true}}
	return {}, false
}

// An unfocused, unhovered pane's header hides its buttons and shows its program status at its right end;
// focus or the pointer brings the buttons back and the status beside them. It slides between the two
// with animations on and jumps with them off, and a status the header did not draw appears in place.
@(test)
pane_header_status_sits_at_the_right_end_while_buttons_hide :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "header-status", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.animations = false
	gesture_click_header(s, w, .Split_Right, app.pane_header_layout(w, w.panes[0]))
	if !testing.expect_value(t, len(w.panes), 2) {return}
	w.focused = true
	w.header_pane = nil
	focused, other := w.panes[0], w.panes[1]
	if !app.pane_shows_focus(w, focused) {focused, other = other, focused}
	if !testing.expect(t, app.pane_shows_focus(w, focused)) {return}
	view, focused_view: ^app.Pane_View
	for &candidate in w.pane_views {
		if candidate.content == other.content {view = &candidate}
		if candidate.content == focused.content {focused_view = &candidate}
	}
	if !testing.expect(t, view != nil && focused_view != nil) {return}
	now := time.tick_now()
	_ = app.pane_header_controls_animate(s, w, render.frame_time_at(now))
	testing.expect_value(t, view.header_status.value, f32(1))
	testing.expect_value(t, focused_view.header_status.value, f32(0))

	scale := w.scale
	right_end := other.rect.x + other.rect.width - ui.SPACE_1 * scale
	l := app.pane_header_layout(w, other)
	beside_end := l.title.x + l.title.width
	pill, found := header_status_pill(s, w, other)
	if !testing.expect(t, found, "the unfocused header draws its status") {return}
	testing.expect_value(t, pill.x + pill.width, right_end)
	testing.expect(t, view.header_status_drawn)

	// Hovering the pane shows its buttons and puts the status back beside them.
	w.header_pane = other.content
	_ = app.pane_header_controls_animate(s, w, render.frame_time_at(now))
	testing.expect_value(t, view.header_status.value, f32(0))
	pill, found = header_status_pill(s, w, other)
	testing.expect(t, found)
	testing.expect_value(t, pill.x + pill.width, beside_end)

	// With animations on it slides, and lands at the right end.
	s.animations = true
	w.header_pane = nil
	frame := render.frame_time_at(now)
	testing.expect(t, app.pane_header_controls_animate(s, w, frame))
	testing.expect(t, app.pane_header_controls_animating(w))
	frame.display = time.tick_add(now, 40 * time.Millisecond)
	_ = app.pane_header_controls_animate(s, w, frame)
	testing.expect(t, view.header_status.value > 0 && view.header_status.value < 1)
	pill, found = header_status_pill(s, w, other)
	testing.expect(t, found)
	testing.expect(t, pill.x + pill.width > beside_end && pill.x + pill.width < right_end)
	frame.display = time.tick_add(now, 200 * time.Millisecond)
	_ = app.pane_header_controls_animate(s, w, frame)
	testing.expect_value(t, view.header_status.value, f32(1))
	testing.expect(t, !app.pane_header_controls_animating(w))

	// A header that drew no status lets its place follow the buttons at once.
	view.header_status_drawn = false
	w.header_pane = other.content
	_ = app.pane_header_controls_animate(s, w, frame)
	testing.expect_value(t, view.header_status.value, f32(0))
}

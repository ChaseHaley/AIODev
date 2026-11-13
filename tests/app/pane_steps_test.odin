package app_test

import "core:testing"
import app "../../src"
import "aio:input"
import "aio:layout"
import "aio:platform"

// Keyboard pane moves and Arrange mode (WORK-477): each command lands where the header drag would.

@(private = "file")
Steps_Fixture :: struct {
	palette: Palette_Fixture,
	w:       ^app.Window,
	// The sessions of the window's first pane and of the pane split right of it, which is focused.
	a, b:    u32,
}

@(private = "file", require_results)
steps_fixture_create :: proc(t: ^testing.T, f: ^Steps_Fixture, name: string) -> bool {
	if !palette_fixture_create(t, &f.palette, name, second_window = false) {return false}
	s := &f.palette.state
	f.w = s.windows[0]
	f.a = steps_focused(s, f.w)
	app.pane_split(s, f.w, .Right)
	f.b = steps_focused(s, f.w)
	app.handle_event(s, platform.Focus_Event{f.w.id, true})
	return testing.expect(t, f.a != 0 && f.b != 0 && f.a != f.b)
}

@(private = "file")
steps_focused :: proc(s: ^app.App, w: ^app.Window) -> u32 {
	entry := app.focused_session(s, w)
	return entry != nil ? entry.id : 0
}

@(private = "file")
steps_rect :: proc(w: ^app.Window, session: u32) -> layout.Rect {
	for pane in w.panes {if pane.content.id == session {return pane.rect}}
	return {}
}

@(private = "file")
steps_shown :: proc(w: ^app.Window, session: u32) -> bool {
	for pane in w.panes {if pane.content.id == session {return true}}
	return false
}

@(private = "file")
steps_press :: proc(s: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers = {}) {
	app.handle_event(s, input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = true})
	app.handle_event(s, input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = false})
}

@(private = "file")
steps_last_notice :: proc(s: ^app.App) -> string {
	if len(s.notices.items) == 0 {return ""}
	return s.notices.items[len(s.notices.items) - 1].text
}

// A beside B: Move Left takes B past A and Move Right back, focus staying on B; Move Left from the left edge
// where B already runs along it changes nothing.
@(test)
move_passes_the_neighbour_in_its_row :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-pass") {return}
	s, w := &f.palette.state, f.w
	app.run_action(s, w, .Move_Left)
	testing.expect(t, steps_rect(w, f.b).x < steps_rect(w, f.a).x)
	testing.expect_value(t, steps_focused(s, w), f.b)
	before := steps_rect(w, f.b)
	app.run_action(s, w, .Move_Left)
	testing.expect_value(t, steps_rect(w, f.b), before)
	app.run_action(s, w, .Move_Right)
	testing.expect(t, steps_rect(w, f.b).x > steps_rect(w, f.a).x)
	testing.expect_value(t, steps_focused(s, w), f.b)
}

// A over C beside B: Move Left takes B into the left column beside its neighbour, facing it, and a second
// Move Left passes that neighbour to the window's left edge.
@(test)
move_joins_a_neighbour_in_another_branch :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-join") {return}
	s, w := &f.palette.state, f.w
	app.run_action(s, w, .Focus_Left)
	app.pane_split(s, w, .Down)
	c := steps_focused(s, w)
	app.run_action(s, w, .Focus_Right)
	if !testing.expect_value(t, steps_focused(s, w), f.b) {return}
	full := steps_rect(w, f.b)
	app.run_action(s, w, .Move_Left)
	joined := steps_rect(w, f.b)
	testing.expect(t, joined.height < full.height)
	neighbour := f.a
	if joined.y != steps_rect(w, f.a).y {neighbour = c}
	testing.expect_value(t, joined.y, steps_rect(w, neighbour).y)
	testing.expect(t, joined.x > steps_rect(w, neighbour).x)
	app.run_action(s, w, .Move_Left)
	passed := steps_rect(w, f.b)
	testing.expect(t, passed.x < steps_rect(w, neighbour).x)
	testing.expect_value(t, passed.height, joined.height)
	testing.expect_value(t, steps_focused(s, w), f.b)
}

// With nothing to its left, Move Left docks C along the whole left edge; Dock Down puts B along the bottom.
@(test)
move_docks_at_the_edge_with_nothing_beyond :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-dock") {return}
	s, w := &f.palette.state, f.w
	full := steps_rect(w, f.b)
	app.run_action(s, w, .Focus_Left)
	app.pane_split(s, w, .Down)
	c := steps_focused(s, w)
	app.run_action(s, w, .Move_Left)
	docked := steps_rect(w, c)
	testing.expect_value(t, docked.height, full.height)
	testing.expect(t, docked.x < steps_rect(w, f.a).x)
	app.run_action(s, w, .Focus_Right)
	app.run_action(s, w, .Focus_Right)
	if !testing.expect_value(t, steps_focused(s, w), f.b) {return}
	app.run_action(s, w, .Dock_Down)
	bottom := steps_rect(w, f.b)
	testing.expect(t, bottom.y > steps_rect(w, c).y)
	testing.expect(t, bottom.width > full.width)
}

// Swap Right trades A and B with focus following A; Rotate Split stacks them, and again sets them side by
// side.
@(test)
swap_and_rotate_rearrange_the_pair :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-swap") {return}
	s, w := &f.palette.state, f.w
	app.run_action(s, w, .Focus_Left)
	app.run_action(s, w, .Swap_Right)
	testing.expect(t, steps_rect(w, f.a).x > steps_rect(w, f.b).x)
	testing.expect_value(t, steps_focused(s, w), f.a)
	app.run_action(s, w, .Rotate_Split)
	a, b := steps_rect(w, f.a), steps_rect(w, f.b)
	testing.expect_value(t, a.width, b.width)
	testing.expect(t, a.y > b.y)
	app.run_action(s, w, .Rotate_Split)
	testing.expect(t, steps_rect(w, f.a).x > steps_rect(w, f.b).x)
}

// Move to tab 2 puts B beside tab 2's pane and shows that tab; tab 1 keeps A. Its own tab and a tab that does
// not exist move nothing. Move to New Tab gives B a tab of its own, and on a tab's only pane moves the tab to
// the end.
@(test)
move_to_tabs_lands_as_a_drop_on_the_tab :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-tabs") {return}
	s, w := &f.palette.state, f.w
	if _, created := app.tab_create(s, w.workspace); !testing.expect(t, created) {return}
	app.tab_select(s, w, 0)
	app.run_action(s, w, .Move_Pane_Tab_1)
	app.run_action(s, w, .Move_Pane_Tab_9)
	testing.expect_value(t, w.workspace.selected, 0)
	testing.expect(t, steps_shown(w, f.b))
	app.run_action(s, w, .Move_Pane_Tab_2)
	testing.expect_value(t, w.workspace.selected, 1)
	testing.expect_value(t, len(w.panes), 2)
	testing.expect_value(t, steps_focused(s, w), f.b)
	testing.expect_value(t, layout.pane_count(&w.workspace.tabs[0].tree), 1)
	app.run_action(s, w, .Move_Pane_New_Tab)
	testing.expect_value(t, len(w.workspace.tabs), 3)
	testing.expect_value(t, w.workspace.selected, 2)
	testing.expect_value(t, len(w.panes), 1)
	testing.expect_value(t, steps_focused(s, w), f.b)
	app.tab_select(s, w, 0)
	app.run_action(s, w, .Move_Pane_New_Tab)
	testing.expect_value(t, len(w.workspace.tabs), 3)
	testing.expect_value(t, w.workspace.selected, 2)
	testing.expect_value(t, steps_focused(s, w), f.a)
}

// Move to New Window takes B into a window of its own, which names its workspace; the workspace's last pane
// cannot leave. The keyboard workspace picker offers the same New window row a drag does.
@(test)
move_to_new_window_from_the_command_and_the_picker :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-window") {return}
	s, w := &f.palette.state, f.w
	app.pane_split(s, w, .Right)
	third := steps_focused(s, w)
	app.run_action(s, w, .Move_Pane_New_Window)
	if !testing.expect_value(t, len(s.windows), 2) {return}
	torn := s.windows[1]
	testing.expect_value(t, steps_focused(s, torn), third)
	testing.expect_value(t, app.overlay_kind(s, torn), app.Overlay_Kind.Chip_Name)
	testing.expect(t, !steps_shown(w, third))

	app.run_action(s, w, .Move_Pane_Workspace)
	if !testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.Workspace_Picker) {return}
	last := app.workspace_picker_count(w) - 1
	_, offered := app.workspace_picker_target_at(w, last).(app.Picker_New_Window)
	if !testing.expect(t, offered) {return}
	w.workspace_picker.selected = last
	app.workspace_picker_choose(s, w)
	testing.expect_value(t, len(s.windows), 3)
	testing.expect_value(t, len(w.panes), 1)

	app.run_action(s, s.windows[2], .Move_Pane_New_Window)
	testing.expect_value(t, len(s.windows), 3)
	testing.expect_value(t, steps_last_notice(s), "This pane cannot move to a new window.")
}

// A host showing A beside C, with B moved to a linked window on the host's right.
@(private = "file")
Linked_Fixture :: struct {
	using steps: Steps_Fixture,
	linked:      ^app.Window,
	c:           u32,
}

@(private = "file", require_results)
linked_fixture_create :: proc(t: ^testing.T, f: ^Linked_Fixture, name: string, split_host: bool) -> bool {
	if !steps_fixture_create(t, &f.steps, name) {return false}
	s := &f.palette.state
	app.pane_link_toggle(s, f.w)
	if !testing.expect_value(t, len(s.windows), 2) {return false}
	f.linked = s.windows[1]
	app.pane_links_sync(s)
	if !testing.expect(t, f.linked.phase == .Shown) {return false}
	hx, hy, host_error := platform.window_to_screen(&s.platform, f.w.id, 0, 0)
	if !testing.expect_value(t, host_error, platform.Error.None) {return false}
	moved := platform.window_set_position(&s.platform, f.linked.id, hx + i32(f.w.width) + 40, hy)
	if !testing.expect_value(t, moved, platform.Error.None) {return false}
	if split_host {
		app.pane_split(s, f.w, .Right)
		f.c = steps_focused(s, f.w)
	}
	return true
}

// Move Right from the host's rightmost pane crosses into the linked window beside B, facing it; from the
// host's only shown pane the same move is refused as the drag refuses it, keeping the pane.
@(test)
move_crosses_into_a_linked_window_as_a_drop_there :: proc(t: ^testing.T) {
	f: Linked_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !linked_fixture_create(t, &f, "steps-linked", true) {return}
	s := &f.palette.state
	app.run_action(s, f.w, .Move_Right)
	app.pane_links_sync(s)
	testing.expect_value(t, len(f.linked.panes), 2)
	testing.expect(t, steps_rect(f.linked, f.c).x < steps_rect(f.linked, f.b).x)
	testing.expect_value(t, steps_focused(s, f.linked), f.c)
	testing.expect_value(t, len(f.w.panes), 1)

	refused :: "Could not move the pane. The source was preserved."
	testing.expect(t, steps_last_notice(s) != refused)
	app.run_action(s, f.w, .Move_Right)
	app.pane_links_sync(s)
	testing.expect_value(t, len(f.w.panes), 1)
	testing.expect_value(t, steps_focused(s, f.w), f.a)
	testing.expect_value(t, steps_last_notice(s), refused)
}

// A wide window shows the key card in three columns and at about 700 px in fewer, inside the panes. At 360 px
// the panes beside the Activity panel are narrower than one column, so the card takes one column and stays
// inside the window.
@(test)
arrange_card_flows_into_fewer_columns_in_a_narrow_window :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-card") {return}
	s, w := &f.palette.state, f.w
	app.run_action(s, w, .Arrange_Panes)
	columns := 4
	for width in ([?]i32{1600, 700, 360}) {
		app.handle_event(s, platform.Resize_Event{window = w.id, width = width, height = w.height})
		card := app.arrange_card(s, w)
		r := card.rect
		testing.expectf(t, card.columns < columns, "%v px: %v columns after %v", width, card.columns, columns)
		bounds := app.window_content_area(s, w)
		if width == 360 {bounds = {0, bounds.y, f32(w.width), bounds.height}}
		testing.expectf(t, r.x >= bounds.x && r.x + r.width <= bounds.x + bounds.width,
			"%v px: card %v outside %v", width, r, bounds)
		testing.expectf(t, r.y >= bounds.y && r.y + r.height <= bounds.y + bounds.height,
			"%v px: card %v outside %v", width, r, bounds)
		switch width {
		case 1600: testing.expect_value(t, card.columns, 3)
		case 360: testing.expect_value(t, card.columns, 1)
		}
		columns = card.columns
	}
	testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.Arrange)
}

// Arrange Panes takes the keys: arrows move, Shift swaps, Ctrl resizes, R rotates and = balances, while
// typing reaches nothing. Esc and Enter leave, keeping every change.
@(test)
arrange_mode_keys_arrange_and_esc_or_enter_keep_the_result :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-arrange") {return}
	s, w := &f.palette.state, f.w
	app.run_action(s, w, .Arrange_Panes)
	if !testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.Arrange) {return}
	steps_press(s, w, .Arrow_Left)
	testing.expect(t, steps_rect(w, f.b).x < steps_rect(w, f.a).x)
	steps_press(s, w, .L)
	testing.expect(t, steps_rect(w, f.b).x > steps_rect(w, f.a).x)
	steps_press(s, w, .Arrow_Left, {.Shift})
	testing.expect(t, steps_rect(w, f.b).x < steps_rect(w, f.a).x)
	testing.expect_value(t, steps_focused(s, w), f.b)
	before := steps_rect(w, f.b).width
	steps_press(s, w, .Arrow_Right, {.Control})
	testing.expect(t, steps_rect(w, f.b).width != before)
	steps_press(s, w, .Equal)
	testing.expect_value(t, steps_rect(w, f.b).width, steps_rect(w, f.a).width)
	steps_press(s, w, .R)
	testing.expect(t, steps_rect(w, f.b).y < steps_rect(w, f.a).y)

	steps_press(s, w, .X)
	app.handle_event(s, input.Text_Event{window = w.id, text = "x"})
	testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.Arrange)
	testing.expect_value(t, len(s.windows), 1)

	stacked := steps_rect(w, f.b)
	steps_press(s, w, .Escape)
	testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.None)
	testing.expect_value(t, steps_rect(w, f.b), stacked)
	steps_press(s, w, .Arrow_Left)
	testing.expect_value(t, steps_rect(w, f.b), stacked)

	app.run_action(s, w, .Arrange_Panes)
	steps_press(s, w, .K, {.Alt, .Shift})
	testing.expect_value(t, steps_rect(w, f.b), stacked)
	steps_press(s, w, .Enter)
	testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.None)
}

// A press leaves the mode and still reaches the pane it landed on; opening the palette and the window losing
// focus leave it too.
@(test)
arrange_mode_leaves_on_a_click_the_palette_or_lost_focus :: proc(t: ^testing.T) {
	f: Steps_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !steps_fixture_create(t, &f, "steps-arrange-leave") {return}
	s, w := &f.palette.state, f.w
	app.run_action(s, w, .Arrange_Panes)
	a := steps_rect(w, f.a)
	x, y := i32(a.x + a.width / 2), i32(a.y + a.height / 2)
	app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true, x = x, y = y})
	app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = false, x = x, y = y})
	testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.None)
	testing.expect_value(t, steps_focused(s, w), f.a)

	app.run_action(s, w, .Arrange_Panes)
	steps_press(s, w, .P, {.Control, .Shift})
	testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.Palette)
	app.window_overlays_cancel(s, w)

	app.run_action(s, w, .Arrange_Panes)
	testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.Arrange)
	app.handle_event(s, platform.Focus_Event{w.id, false})
	testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.None)
}

// The mode stays on the pane it arranges: through a move to another tab or a new tab, into a linked window
// and, with Alt, onto the pane focus picks in the host. N ends it in the new window's name field.
@(test)
arrange_mode_follows_its_pane_across_tabs_and_windows :: proc(t: ^testing.T) {
	f: Linked_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !linked_fixture_create(t, &f, "steps-arrange-follow", true) {return}
	s, w := &f.palette.state, f.w
	app.run_action(s, w, .Arrange_Panes)
	steps_press(s, w, .Arrow_Right)
	app.pane_links_sync(s)
	testing.expect(t, app.arrange_active(f.linked))
	testing.expect(t, !app.arrange_active(w))
	testing.expect_value(t, steps_focused(s, f.linked), f.c)

	steps_press(s, f.linked, .Arrow_Left, {.Alt})
	app.pane_links_sync(s)
	testing.expect(t, app.arrange_active(w))
	testing.expect(t, !app.arrange_active(f.linked))
	testing.expect_value(t, steps_focused(s, w), f.a)

	steps_press(s, w, .Escape)
	if _, created := app.tab_create(s, w.workspace); !testing.expect(t, created) {return}
	app.tab_select(s, w, 0)
	app.pane_split(s, w, .Right)
	moved := steps_focused(s, w)
	app.run_action(s, w, .Arrange_Panes)
	steps_press(s, w, .Digit_2)
	testing.expect_value(t, w.workspace.selected, 1)
	testing.expect_value(t, steps_focused(s, w), moved)
	testing.expect(t, app.arrange_active(w))
	steps_press(s, w, .T)
	testing.expect_value(t, w.workspace.selected, 2)
	testing.expect_value(t, steps_focused(s, w), moved)
	testing.expect(t, app.arrange_active(w))

	windows := len(s.windows)
	steps_press(s, w, .N)
	testing.expect(t, !app.arrange_active(w))
	if !testing.expect_value(t, len(s.windows), windows + 1) {return}
	testing.expect_value(t, app.overlay_kind(s, s.windows[windows]), app.Overlay_Kind.Chip_Name)
}

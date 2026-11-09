package layout_test

import "aio:layout"
import "core:testing"

// The last choice wins; turning off the current mode clears the whole view.
@(private = "file")
expected_view :: proc(view: layout.Pane_View, event: layout.Pane_View_Event) -> layout.Pane_View {
	fill, zoomed := layout.pane_view_parts(view)
	switch event {
	case .Toggle_Zoom:
		return layout.pane_view_of(.None, fill != .None || !zoomed)
	case .Toggle_Fill:
		if fill == .Content {return .Split}
		return layout.pane_view_of(.Content, zoomed)
	case .Toggle_Screen:
		if fill == .Screen {return .Split}
		return layout.pane_view_of(.Screen, zoomed)
	case .Panes_Changed, .Tab_Changed:
		return .Split
	}
	return .Split
}

@(test)
pane_view_chained_modes_return_to_split_when_toggled_off :: proc(t: ^testing.T) {
	for first in ([?]layout.Pane_View_Event{.Toggle_Zoom, .Toggle_Fill, .Toggle_Screen}) {
		for last in ([?]layout.Pane_View_Event{.Toggle_Fill, .Toggle_Screen}) {
			if first == last {continue}
			view := layout.PANE_VIEW_TRANSITIONS[.Split][first]
			view = layout.PANE_VIEW_TRANSITIONS[view][last]
			view = layout.PANE_VIEW_TRANSITIONS[view][last]
			testing.expect_value(t, view, layout.Pane_View.Split)
		}
	}
}

@(test)
pane_view_every_transition_follows_the_rules :: proc(t: ^testing.T) {
	for row, view in layout.PANE_VIEW_TRANSITIONS {
		for next, event in row {
			testing.expectf(t, next == expected_view(view, event), "%v on %v went to %v", view, event, next)
		}
	}
}

@(test)
pane_view_parts_round_trip_and_every_state_is_reachable :: proc(t: ^testing.T) {
	reached: bit_set[layout.Pane_View] = {.Split}
	for {
		before := reached
		for view in reached {
			for next in layout.PANE_VIEW_TRANSITIONS[view] {reached += {next}}
		}
		if reached == before {break}
	}
	testing.expect_value(t, reached, ~bit_set[layout.Pane_View]{})
	for view in layout.Pane_View {
		fill, zoomed := layout.pane_view_parts(view)
		testing.expect_value(t, layout.pane_view_of(fill, zoomed), view)
	}
}

@(test)
pane_view_changes_that_reveal_panes_are_recorded :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	testing.expect(t, !l.panes_changed)

	reveals :: proc(t: ^testing.T, l: ^layout.Layout, loc := #caller_location) {
		testing.expect(t, l.panes_changed, loc = loc)
		testing.expect(t, !l.zoomed, loc = loc)
		l.panes_changed, l.zoomed = false, true
	}
	l.zoomed = true
	right, err := layout.split_direction(&l, l.focus, .Right, 0.5, terminal(2))
	testing.expect_value(t, err, nil)
	reveals(t, &l)
	below, beside_error := layout.insert_beside(&l, right, .Vertical, false, 0.5, terminal(3))
	testing.expect_value(t, beside_error, nil)
	reveals(t, &l)
	moved, move_ok := layout.move_pane(&l, below, 0, .Left)
	testing.expect(t, move_ok)
	reveals(t, &l)
	_, dock_ok := layout.dock_pane(&l, moved, .Down)
	testing.expect(t, dock_ok)
	reveals(t, &l)

	testing.expect(t, layout.remove(&l, l.focus))
	reveals(t, &l)
}

@(test)
pane_view_changes_inside_a_single_pane_view_are_not_recorded :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split_direction(&l, l.focus, .Right, 0.5, terminal(2))
	testing.expect_value(t, err, nil)
	third, third_error := layout.split_direction(&l, right, .Down, 0.5, terminal(3))
	testing.expect_value(t, third_error, nil)
	l.panes_changed, l.zoomed = false, true
	testing.expect(t, layout.swap(&l, l.focus, right))
	layout.balance(&l)
	testing.expect(t, layout.remove(&l, third))
	testing.expect(t, !l.panes_changed)
	testing.expect(t, l.zoomed)
}

@(test)
pane_view_transfer_records_the_destination_and_a_focused_source :: proc(t: ^testing.T) {
	source, destination: layout.Layout
	testing.expect_value(t, layout.init(&source, terminal(1)), nil)
	defer layout.destroy(&source)
	testing.expect_value(t, layout.init(&destination, terminal(2)), nil)
	defer layout.destroy(&destination)
	right, err := layout.split_direction(&source, source.focus, .Right, 0.5, terminal(3))
	testing.expect_value(t, err, nil)
	source.panes_changed = false
	_, moved := layout.transfer_pane(&source, &destination, right, destination.root, .Right, false)
	testing.expect(t, moved)
	testing.expect(t, destination.panes_changed)
	testing.expect(t, !source.panes_changed)
}

@(test)
pane_view_compute_focused_places_only_the_focused_pane :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split_direction(&l, l.focus, .Right, 0.5, terminal(2))
	testing.expect_value(t, err, nil)
	l.focus = right
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.compute_focused(&l, {0, 30, 400, 200}, &rects)
	testing.expect_value(t, len(rects), 1)
	testing.expect_value(t, rects[0].node, right)
	testing.expect_value(t, rects[0].rect, layout.Rect{0, 30, 400, 200})
}

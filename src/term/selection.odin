package term

import "aio:ghostty"
import "core:log"
import "core:strings"
import "core:sync"

@(private)
REPEAT_CLICK_INTERVAL_NS :: u64(500_000_000)
@(private)
REPEAT_CLICK_DISTANCE :: f64(4)

@(private, require_results)
configure_press_event :: proc(s: ^Session) -> Error {
	interval, distance := REPEAT_CLICK_INTERVAL_NS, REPEAT_CLICK_DISTANCE
	ok :=
		ghostty.selection_gesture_event_set(s.press_event, .Repeat_Interval_Ns, &interval) ==
		.Success
	ok &&=
		ghostty.selection_gesture_event_set(s.press_event, .Repeat_Distance, &distance) == .Success
	return ok ? .None : .Terminal_Failed
}

@(private)
viewport_ref :: proc(s: ^Session, x, y: f32) -> (ghostty.Grid_Ref, bool) {
	column, row := cell_at(s.geometry, x, y)
	point := ghostty.Point {
		tag = .Viewport,
		value = {coordinate = {x = u16(column), y = u32(row)}},
	}
	ref := ghostty.sized(ghostty.Grid_Ref)
	found := ghostty.terminal_grid_ref(s.terminal, point, &ref) == .Success
	return ref, found
}

// Feeds one gesture event to libghostty and installs the selection it produces. The caller holds the mutex.
@(private)
apply_gesture :: proc(s: ^Session, event: ghostty.Selection_Gesture_Event, x, y: f32) {
	ref, found := viewport_ref(s, x, y)
	position := ghostty.Surface_Position{f64(x), f64(y)}
	ok := ghostty.selection_gesture_event_set(event, .Ref, found ? &ref : nil) == .Success
	if event != s.release_event {
		ok &&= ghostty.selection_gesture_event_set(event, .Position, &position) == .Success
	}
	if !ok {
		log.error("term: configuring a selection gesture failed")
		return
	}
	run_gesture(s, event)
}

// Applies a configured gesture event and installs the selection it produces. The caller holds the mutex.
@(private)
run_gesture :: proc(s: ^Session, event: ghostty.Selection_Gesture_Event) {
	selection := ghostty.sized(ghostty.Selection)
	result := ghostty.selection_gesture_event(s.gesture, s.terminal, event, &selection)
	#partial switch result {
	case .Success:
		result = ghostty.terminal_set(s.terminal, .Selection, &selection)
	case .No_Value:
		// Releases and autoscroll ticks never take away the selection the gesture made.
		keep := event == s.release_event || event == s.autoscroll_event
		result = keep ? .Success : ghostty.terminal_set(s.terminal, .Selection, nil)
	case:
	}
	if result != .Success {
		log.errorf("term: applying a selection gesture failed: %v", result)
	}
}

selection_press :: proc(s: ^Session, x, y: f32, time_ns: i64) {
	time := u64(time_ns)
	sync.mutex_lock(&s.mutex)
	if ghostty.selection_gesture_event_set(s.press_event, .Time_Ns, &time) == .Success {
		apply_gesture(s, s.press_event, x, y)
	}
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
}

@(private)
gesture_geometry :: proc(g: Geometry) -> ghostty.Selection_Gesture_Geometry {
	return {
		columns = u32(g.columns),
		cell_width = g.cell_width,
		padding_left = g.padding_left,
		screen_height = g.surface_height,
	}
}

selection_drag :: proc(s: ^Session, x, y: f32) {
	geometry := gesture_geometry(s.geometry)
	sync.mutex_lock(&s.mutex)
	if ghostty.selection_gesture_event_set(s.drag_event, .Geometry, &geometry) == .Success {
		apply_gesture(s, s.drag_event, x, y)
	}
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
}

Autoscroll :: enum {
	None,
	Up,
	Down,
}

// The direction the current selection drag asks history to scroll, set once the pointer passes the top or
// bottom edge of the surface.
selection_autoscroll :: proc(s: ^Session) -> Autoscroll {
	value: ghostty.Selection_Gesture_Autoscroll
	sync.mutex_lock(&s.mutex)
	result := ghostty.selection_gesture_get(s.gesture, s.terminal, .Autoscroll, &value)
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		return .None
	}
	switch value {
	case .None:
		return .None
	case .Up:
		return .Up
	case .Down:
		return .Down
	}
	return .None
}

// Scrolls history one row in the drag's autoscroll direction and extends the selection to
// the pointer's column.
selection_autoscroll_tick :: proc(s: ^Session, x, y: f32) {
	direction := selection_autoscroll(s)
	if direction == .None {
		return
	}
	g := s.geometry
	geometry := gesture_geometry(g)
	column := cell_column(g, x)
	coordinate := ghostty.Point_Coordinate{u16(column), direction == .Up ? 0 : u32(g.rows) - 1}
	position := ghostty.Surface_Position{f64(x), f64(y)}
	event := s.autoscroll_event
	sync.mutex_lock(&s.mutex)
	ok := ghostty.selection_gesture_event_set(event, .Viewport, &coordinate) == .Success
	ok &&= ghostty.selection_gesture_event_set(event, .Geometry, &geometry) == .Success
	ok &&= ghostty.selection_gesture_event_set(event, .Position, &position) == .Success
	if ok {
		run_gesture(s, event)
	} else {
		log.error("term: configuring a selection autoscroll failed")
	}
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
}

selection_release :: proc(s: ^Session, x, y: f32) {
	sync.mutex_lock(&s.mutex)
	apply_gesture(s, s.release_event, x, y)
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
}

has_selection :: proc(s: ^Session) -> bool {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	selection := ghostty.sized(ghostty.Selection)
	return ghostty.terminal_get(s.terminal, .Selection, &selection) == .Success
}

select_all :: proc(s: ^Session) {
	sync.mutex_lock(&s.mutex)
	selection := ghostty.sized(ghostty.Selection)
	result := ghostty.terminal_select_all(s.terminal, &selection)
	if result == .Success {
		result = ghostty.terminal_set(s.terminal, .Selection, &selection)
	}
	sync.mutex_unlock(&s.mutex)
	if result != .Success && result != .No_Value {
		log.errorf("term: select all failed: %v", result)
	}
	mark_changed(s)
}

clear_selection :: proc(s: ^Session) {
	sync.mutex_lock(&s.mutex)
	ghostty.selection_gesture_reset(s.gesture, s.terminal)
	result := ghostty.terminal_set(s.terminal, .Selection, nil)
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: clearing the selection failed: %v", result)
	}
	mark_changed(s)
}

// Returns the selected text with soft-wrapped lines joined, or false when nothing is selected.
selection_text :: proc(s: ^Session, allocator := context.allocator) -> (string, bool) {
	options := ghostty.sized(ghostty.Terminal_Selection_Format_Options)
	options.emit = .Plain
	options.unwrap = true
	options.trim = true
	text: [^]u8
	length: uint
	sync.mutex_lock(&s.mutex)
	result := ghostty.terminal_selection_format_alloc(s.terminal, nil, options, &text, &length)
	sync.mutex_unlock(&s.mutex)
	if result == .No_Value {
		return "", false
	}
	if result != .Success {
		log.errorf("term: formatting the selection failed: %v", result)
		return "", false
	}
	defer ghostty.free(nil, text, length)
	return strings.clone(string(text[:length]), allocator), true
}

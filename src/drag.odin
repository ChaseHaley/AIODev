package main

import "aio:input"
import "aio:layout"
import "aio:ui"
import "core:math"
import "core:time"

// One pane or tab drag per window; nil is Idle. A Left press on a pane header or a marked tab arms it, the
// threshold makes it Active, and from then on one destination at a time would take the drop. The release
// drops there; Escape, a lost capture or a release the drag does not own cancels it and puts everything back.
// The procs in this file are the only writers of Window.drag, of an active drag's destination and of its
// tear-off preview. arrange.odin, tab_windows.odin and pane_workspace_drag.odin work out the destinations and
// carry out the drops.
Drag :: union {
	Drag_Pressed,
	Drag_Active,
}

// Below the threshold: a release here is still a click.
Drag_Pressed :: struct {
	origin: [2]f32,
	grab:   Drag_Grab,
}

Drag_Grab :: union #no_nil {
	Pane_Grab,
	Tab_Grab,
}

// A pane header press: the tab the window shows, which for a linked window is its private copy, and the
// pane's node there.
Pane_Grab :: struct {
	source: ^Tab,
	node:   layout.Node_Id,
}

// A press on a marked tab, which carries every marked tab.
Tab_Grab :: struct {
	grabbed:  ^Tab,
	// Where the pointer holds the tab: pixels from its left edge on the strip, a fraction of its row on the
	// rail.
	offset:   [2]f32,
	// A press that changed the marks keeps them when it ends without a drag.
	modified: bool,
}

Drag_Active :: struct {
	carry:       Drag_Carry,
	// The latest pointer position, in the source window's coordinates.
	pointer:     [2]f32,
	destination: Drag_Destination,
	preview:     Tear_Off_Preview,
	thumbnail:   Drag_Thumbnail,
}

Drag_Carry :: union #no_nil {
	Pane_Carry,
	Tab_Carry,
}

Pane_Carry :: struct {
	using grab: Pane_Grab,
	visit:      Drag_Visit,
	// The drop outline as x, y, width and height, and its fade in.
	ghost:      [4]ui.Motion,
	reveal:     ui.Motion,
}

// The window a pane drag is over, 0 outside every window, and the tab it showed on arrival, which leaving the
// window shows again. Resting on another of its tabs arms a switch to that tab.
Drag_Visit :: struct {
	window:         input.Window_Id,
	original:       ^Tab,
	original_index: int,
	hover:          Maybe(Drag_Hover),
}

// The tab under the pointer and when it is shown.
Drag_Hover :: struct {
	tab: ^Tab,
	at:  time.Tick,
}

@(private)
DRAG_HOVER_DELAY :: 350 * time.Millisecond

Tab_Carry :: struct {
	using grab: Tab_Grab,
	// The tabs in their order at the threshold, which a cancel restores.
	order:      [dynamic]^Tab,
	// The grabbed tab's place among the marked tabs.
	rank:       int,
}

// Where a drop would land now. Nil lands nowhere and puts the content back.
Drag_Destination :: union {
	Drop_Pane,
	Drop_Swap,
	Drop_Dock_Root,
	Drop_New_Tab,
	Drop_Reorder,
	Drop_Other_Window,
	Drop_Workspace_Dropdown,
	Drop_Tear_Off,
}

// Whether a pane lands where the outline shows, from the trial layout that placed the outline.
Drop_Fit :: enum u8 {
	Fits,
	Refused,
	// It would leave a pane below the minimum pane size, which the drop reports.
	Too_Small,
}

// A pane beside `target`, a pane of `tab`, which `window` shows.
Drop_Pane :: struct {
	window:    input.Window_Id,
	tab:       ^Tab,
	target:    layout.Node_Id,
	direction: layout.Direction,
	fit:       Drop_Fit,
}

// A pane trading places with `target` in its own tab while Shift is held.
Drop_Swap :: struct {
	window: input.Window_Id,
	target: layout.Node_Id,
	fit:    Drop_Fit,
}

// A pane along one edge of the whole of `tab`, from the band at the edge of the content area. `target` is the
// pane focused there, which a linked destination resolves to its slot.
Drop_Dock_Root :: struct {
	window:    input.Window_Id,
	tab:       ^Tab,
	target:    layout.Node_Id,
	direction: layout.Direction,
	fit:       Drop_Fit,
}

// A pane in a new tab of `window`. `tab` is the tab shown there: the pane's own, when it is that tab's only
// pane, only moves the tab to the end.
Drop_New_Tab :: struct {
	window: input.Window_Id,
	tab:    ^Tab,
	fit:    Drop_Fit,
}

// Tabs in the order their own strip or rail shows as they move.
Drop_Reorder :: struct {}

// Tabs joining another window's workspace at `slot`, where that window opens a gap for them.
Drop_Other_Window :: struct {
	window: input.Window_Id,
	slot:   int,
}

// A drag holding `window`'s workspace dropdown open. `row` is the row under `pointer`, in that window's
// coordinates, or -1; the dropdown keeps its own side, so one closed under the drag no longer takes the drop.
Drop_Workspace_Dropdown :: struct {
	window:  input.Window_Id,
	pointer: [2]f32,
	row:     int,
}

// A window of its own at the pointer, which the drag's preview window becomes.
Drop_Tear_Off :: struct {}

// The hidden window a tear-off drop commits. Nil is Pending: none until the drag first offers a tear-off.
// Ready lasts until the drop commits it or the drag discards it; Failed lasts for the rest of the drag.
Tear_Off_Preview :: union {
	Preview_Ready,
	Preview_Failed,
}

Preview_Ready :: struct {
	window: input.Window_Id,
}

Preview_Failed :: struct {}

// Any drag, pressed or active.
drag_held :: proc(w: ^Window) -> bool {
	return w.drag != nil
}

// The active drag, or nil.
drag_active :: proc(w: ^Window) -> ^Drag_Active {
	a, active := &w.drag.(Drag_Active)
	return active ? a : nil
}

// The pane a held pane drag carries.
pane_drag_grab :: proc(w: ^Window) -> (Pane_Grab, bool) {
	switch d in w.drag {
	case Drag_Pressed:
		grab, pane := d.grab.(Pane_Grab)
		return grab, pane
	case Drag_Active:
		carry, pane := d.carry.(Pane_Carry)
		return carry.grab, pane
	}
	return {}, false
}

pane_drag_active :: proc(w: ^Window) -> bool {
	a := drag_active(w)
	if a == nil {return false}
	_, pane := a.carry.(Pane_Carry)
	return pane
}

tab_drag_held :: proc(w: ^Window) -> bool {
	switch d in w.drag {
	case Drag_Pressed:
		_, tab := d.grab.(Tab_Grab)
		return tab
	case Drag_Active:
		_, tab := d.carry.(Tab_Carry)
		return tab
	}
	return false
}

// Tabs following the pointer: the marked tabs draw above the others and keep the place it gives them.
tab_drag_active :: proc(w: ^Window) -> bool {
	a := drag_active(w)
	if a == nil {return false}
	_, tab := a.carry.(Tab_Carry)
	return tab
}

drag_destination :: proc(w: ^Window) -> Drag_Destination {
	a := drag_active(w)
	return a == nil ? nil : a.destination
}

// An active drag holding a workspace dropdown open, which takes every key and the release.
drag_holds_dropdown :: proc(w: ^Window) -> bool {
	_, held := drag_destination(w).(Drop_Workspace_Dropdown)
	return held
}

// The window a drop at the destination would land in, or 0; a tear-off lands in the preview.
drag_destination_window :: proc(destination: Drag_Destination) -> input.Window_Id {
	switch d in destination {
	case Drop_Pane:
		return d.window
	case Drop_Swap:
		return d.window
	case Drop_Dock_Root:
		return d.window
	case Drop_New_Tab:
		return d.window
	case Drop_Other_Window:
		return d.window
	case Drop_Workspace_Dropdown:
		return d.window
	case Drop_Reorder, Drop_Tear_Off:
	}
	return 0
}

// When a resting pane drag next switches the tab under it.
drag_hover_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	a := drag_active(w)
	if a == nil {return {}, false}
	carry, pane := a.carry.(Pane_Carry)
	if !pane {return {}, false}
	hover, armed := carry.visit.hover.?
	return hover.at, armed
}

// Whether w's drag reaches window `id`: by visiting it, dropping there or preparing it.
drag_involves :: proc(w: ^Window, id: input.Window_Id) -> bool {
	a := drag_active(w)
	if a == nil {return false}
	if drag_destination_window(a.destination) == id {return true}
	if ready, ok := a.preview.(Preview_Ready); ok && ready.window == id {return true}
	carry, pane := a.carry.(Pane_Carry)
	return pane && carry.visit.window == id
}

// Idle → Pressed.
drag_press :: proc(w: ^Window, x, y: f32, grab: Drag_Grab) {
	w.drag = Drag_Pressed{{x, y}, grab}
}

// The pressed drag's grab, once the pointer has left the threshold around the press.
@(require_results)
drag_threshold_passed :: proc(w: ^Window, x, y: f32) -> (Drag_Grab, bool) {
	pressed, ok := w.drag.(Drag_Pressed)
	if !ok {return {}, false}
	if math.hypot(x - pressed.origin.x, y - pressed.origin.y) < DRAG_THRESHOLD * w.scale {return {}, false}
	return pressed.grab, true
}

// Pressed → Active, with no destination yet.
drag_activate :: proc(w: ^Window, carry: Drag_Carry, x, y: f32) -> ^Drag_Active {
	w.drag = Drag_Active{carry = carry, pointer = {x, y}}
	return &w.drag.(Drag_Active)
}

// Any phase → Idle, returning the drag so the release or cancel can finish it. Content moved by a drop may
// end this window's gestures, which must then find nothing to put back.
drag_end :: proc(w: ^Window) -> Drag {
	d := w.drag
	w.drag = nil
	if d != nil {w.dirty = true}
	return d
}

// The only change of an active drag's destination. What the old one held in another window lets go, and the
// window offered tabs opens its gap.
drag_retarget :: proc(app: ^App, w: ^Window, a: ^Drag_Active, next: Drag_Destination) {
	previous := a.destination
	if held, was := previous.(Drop_Workspace_Dropdown); was {
		if now, still := next.(Drop_Workspace_Dropdown); !still || now.window != held.window {
			workspace_picker_drag_leave(app, held)
		}
	}
	if offer, was := previous.(Drop_Other_Window); was {
		if now, still := next.(Drop_Other_Window); !still || now.window != offer.window {
			tab_incoming_set(app, offer.window, {})
		}
	}
	if offer, is := next.(Drop_Other_Window); is {
		count := tabs_marked_count(w.workspace)
		tab_incoming_set(app, offer.window, {source = w.id, count = count, slot = offer.slot})
	}
	_, was_tear_off := previous.(Drop_Tear_Off)
	_, tear_off := next.(Drop_Tear_Off)
	if !tear_off {drag_thumbnail_sync(app, w, &a.thumbnail, {}, false, 0, 0)}
	if was_tear_off != tear_off {w.dirty = true}
	a.destination = next
}

// Releases everything an ended drag holds outside its content: the other windows it reached, then its own
// resources.
drag_let_go :: proc(app: ^App, w: ^Window, a: ^Drag_Active) {
	drag_retarget(app, w, a, nil)
	drag_free(app, a)
}

// An ended drag's thumbnail, uncommitted preview and saved tab order. A drop that moved content calls this
// alone: its destination let go as the content arrived, and the source window may be gone.
drag_free :: proc(app: ^App, a: ^Drag_Active) {
	drag_thumbnail_destroy(&a.thumbnail)
	tear_off_preview_discard(app, a)
	if carry, tab := &a.carry.(Tab_Carry); tab {
		delete(carry.order)
		carry.order = nil
	}
}

// The memory a window's drag owns, as the window is freed.
drag_destroy :: proc(w: ^Window) {
	if a, active := &w.drag.(Drag_Active); active {
		if carry, tab := &a.carry.(Tab_Carry); tab {delete(carry.order)}
	}
	w.drag = nil
}

when AIO_CONTROL {
	// What the verify harness reports of a window's drag, in the terms its journeys check.
	Drag_Report :: struct {
		pane, tab:                      bool,
		shown, root, new_tab, tear_off: bool,
		// A pane drag's visited window; the window a tab drag offers its tabs to.
		window:                         input.Window_Id,
		preview:                        input.Window_Id,
		thumbnail:                      Drag_Thumbnail,
		ghost:                          [4]f32,
	}

	drag_report :: proc(w: ^Window) -> (report: Drag_Report) {
		if pressed, ok := w.drag.(Drag_Pressed); ok {
			if _, pane := pressed.grab.(Pane_Grab); pane {report.window = w.id}
			return
		}
		a := drag_active(w)
		if a == nil {return}
		_, report.tear_off = a.destination.(Drop_Tear_Off)
		if ready, ok := a.preview.(Preview_Ready); ok {report.preview = ready.window}
		report.thumbnail = a.thumbnail
		switch carry in a.carry {
		case Pane_Carry:
			report.pane = true
			report.shown = pane_drag_ghost_shown(a)
			_, report.root = a.destination.(Drop_Dock_Root)
			_, report.new_tab = a.destination.(Drop_New_Tab)
			report.window = carry.visit.window
			for m, i in carry.ghost {report.ghost[i] = m.target}
		case Tab_Carry:
			report.tab = true
			if offer, offered := a.destination.(Drop_Other_Window); offered {report.window = offer.window}
		}
		return
	}
}

// Pending → Ready, or → Failed when the window cannot be prepared, which `report` tells the user. Ready
// and Failed stay as they are.
tear_off_preview_ensure :: proc(app: ^App, a: ^Drag_Active, report: bool) -> ^Window {
	switch p in a.preview {
	case Preview_Ready:
		return window_find(app, p.window)
	case Preview_Failed:
		return nil
	}
	preview: ^Window
	message: string
	switch c in a.carry {
	case Pane_Carry:
		preview = pane_window_preview_create(app, c.source, c.node)
		message = "Could not prepare a new window. The pane was preserved."
	case Tab_Carry:
		preview = tab_window_preview_create(app, c.grabbed)
		message = "Could not prepare a new window. The tab was preserved."
	}
	if preview == nil {
		a.preview = Preview_Failed{}
		if report {notify(app, .Error, message)}
		return nil
	}
	a.preview = Preview_Ready{preview.id}
	return preview
}

// Ready → Pending, closing the preview. A failure stays latched.
tear_off_preview_discard :: proc(app: ^App, a: ^Drag_Active) {
	ready, ok := a.preview.(Preview_Ready)
	if !ok {return}
	a.preview = nil
	pane_window_preview_discard(app, ready.window)
}

// Ready → committed: the preview moves to the pointer and takes the carried content, then names its new
// workspace. The content moves only once the window is on screen, so on failure nothing has moved and the
// preview is still the drag's to discard.
@(require_results)
tear_off_commit :: proc(app: ^App, w: ^Window, a: ^Drag_Active) -> bool {
	ready, ok := a.preview.(Preview_Ready)
	if !ok {return false}
	preview := window_find(app, ready.window)
	if preview == nil || !window_place_at_pointer(app, preview, w, a.pointer) {return false}
	moved := false
	switch c in a.carry {
	case Pane_Carry:
		moved = pane_to_window(app, w, c.source, c.node, preview.id)
	case Tab_Carry:
		moved = tabs_to_window(app, w, preview)
	}
	if !moved {return false}
	a.preview = nil
	workspace_name_begin(app, preview)
	return true
}

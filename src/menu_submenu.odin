package main

import "cosmos:host"
import "cosmos:input"
import "cosmos:ui"
import "core:time"

// A ui.Submenu shown in a window (D-088): these keep the window's redraw and open the submenu through its
// owner.

// Builds row `row`'s submenu into the submenu and shows it, or closes it for a row without one. Each
// owner's open.
Submenu_Open :: proc(app: ^App, w: ^Window, row: int, select_first: bool)

submenu_close :: proc(w: ^Window, sub: ^ui.Submenu) {
	if ui.submenu_close(sub) {w.dirty = true}
}

// Hangs the rows just built beside row `row` of `parent`, `width` DIPs wide, with the first selected for
// the keyboard.
submenu_place :: proc(
	w: ^Window,
	sub: ^ui.Submenu,
	parent: ^ui.Menu,
	row: int,
	width: f32,
	select_first: bool,
) {
	ui.submenu_place(sub, parent, row, width, select_first, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

// Shows the submenu of the row the pointer, at `point`, rests on once ui.SUBMENU_DELAY has passed. True
// when it did.
@(private = "file")
submenu_settle :: proc(
	app: ^App,
	w: ^Window,
	sub: ^ui.Submenu,
	parent: ^ui.Menu,
	open: Submenu_Open,
	point: [2]f32,
	now: time.Tick,
) -> bool {
	width, height := f32(w.width), f32(w.height)
	row, due := ui.submenu_due(sub, parent, point, now, width, height, w.scale)
	if !due {return false}
	open(app, w, row, false)
	ui.submenu_aim(sub, parent, point, now, width, height, w.scale)
	return true
}

// A row the pointer has rested on long enough shows its submenu. True when an aim at the submenu stopped
// short of it, which closed it: the owner gives the row under the pointer its turn.
submenu_tick :: proc(
	app: ^App,
	w: ^Window,
	sub: ^ui.Submenu,
	parent: ^ui.Menu,
	open: Submenu_Open,
	now: time.Tick,
) -> bool {
	if submenu_settle(app, w, sub, parent, open, w.pointer, now) {return false}
	if !ui.submenu_tick(sub, now) {return false}
	w.dirty = true
	return true
}

submenu_key :: proc(w: ^Window, sub: ^ui.Submenu, logical: input.Key_Event) -> ui.Submenu_Key {
	result := ui.submenu_key(sub, logical)
	if result == .Taken {w.dirty = true}
	return result
}

// The pointer at x, y over the submenu or `parent`, the menu it hangs from (ui.submenu_hover). True when
// the submenu keeps the pointer.
submenu_hover :: proc(
	app: ^App,
	w: ^Window,
	sub: ^ui.Submenu,
	parent: ^ui.Menu,
	open: Submenu_Open,
	x, y: f32,
) -> bool {
	now := host.clock_now(&app.clock)
	keeps, redraw := ui.submenu_hover(sub, parent, {x, y}, now, f32(w.width), f32(w.height), w.scale)
	if redraw {w.dirty = true}
	if !keeps {_ = submenu_settle(app, w, sub, parent, open, {x, y}, now)}
	return keeps
}

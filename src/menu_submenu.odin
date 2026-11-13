package main

import "aio:input"
import "aio:render"
import "aio:ui"
import "core:time"

// How long the pointer rests on a row before its submenu shows, Radix UI's open delay, so a sweep down the
// menu does not flash each submenu it crosses. The keyboard opens one at once.
SUBMENU_DELAY :: 100 * time.Millisecond

// A menu of a row's own, shown beside the row of the menu it hangs from (D-088). The owner keeps which menu
// that is and builds the rows; this keeps which row it hangs from, the open delay and menu aim.
Menu_Submenu :: struct {
	using menu:    ui.Menu,
	// The parent row it hangs from while it shows.
	row:           Maybe(int),
	// Keeps it while the pointer heads from its row to it (menu aim).
	reveal:        ui.Hover_Reveal,
	// A row the pointer rests on whose submenu shows SUBMENU_DELAY after `pending_since`.
	pending_row:   Maybe(int),
	pending_since: time.Tick,
}

// Builds row `row`'s submenu into the submenu and shows it, or closes it for a row without one. Each
// owner's open.
Submenu_Open :: proc(app: ^App, w: ^Window, row: int, select_first: bool)

submenu_shown :: proc(sub: ^Menu_Submenu) -> bool {
	_, shown := sub.row.?
	return shown
}

submenu_reset :: proc(sub: ^Menu_Submenu) {
	sub.row, sub.pending_row = nil, nil
	ui.hover_reveal_close(&sub.reveal)
}

submenu_close :: proc(w: ^Window, sub: ^Menu_Submenu) {
	if sub.row != nil {w.dirty = true}
	submenu_reset(sub)
}

// Hangs the rows just built beside row `row` of `parent`, `width` DIPs wide, with the first selected for
// the keyboard.
submenu_place :: proc(
	w: ^Window,
	sub: ^Menu_Submenu,
	parent: ^ui.Menu,
	row: int,
	width: f32,
	select_first: bool,
) {
	sub.width = width
	anchor := ui.menu_submenu_anchor(parent, row, width, f32(w.width), f32(w.height), w.scale)
	ui.menu_anchor(&sub.menu, anchor.x, anchor.y)
	ui.menu_select(&sub.menu, select_first ? 0 : -1)
	sub.row, w.dirty = row, true
}

// Shows the submenu of the row the pointer, at `point`, rests on once SUBMENU_DELAY has passed. True when it
// did.
submenu_settle :: proc(
	app: ^App,
	w: ^Window,
	sub: ^Menu_Submenu,
	parent: ^ui.Menu,
	open: Submenu_Open,
	point: [2]f32,
	now: time.Tick,
) -> bool {
	row, pending := sub.pending_row.?
	if !pending || time.tick_diff(time.tick_add(sub.pending_since, SUBMENU_DELAY), now) < 0 {return false}
	sub.pending_row = nil
	width, height := f32(w.width), f32(w.height)
	if ui.menu_hit(parent, point.x, point.y, width, height, w.scale) != row {return false}
	open(app, w, row, false)
	trigger := ui.menu_row_rect(parent, row, width, height, w.scale)
	surface, _ := ui.menu_layout(&sub.menu, width, height, w.scale)
	slack := ui.HOVER_AIM_SLACK * w.scale
	ui.hover_reveal_move(&sub.reveal, point, true, false, false, trigger, surface, slack, now)
	return true
}

// A row the pointer has rested on long enough shows its submenu. True when an aim at the submenu stopped
// short of it, which closed it: the owner gives the row under the pointer its turn.
submenu_tick :: proc(
	app: ^App,
	w: ^Window,
	sub: ^Menu_Submenu,
	parent: ^ui.Menu,
	open: Submenu_Open,
	now: time.Tick,
) -> bool {
	if submenu_settle(app, w, sub, parent, open, w.pointer, now) {return false}
	if !ui.hover_reveal_tick(&sub.reveal, now) {return false}
	submenu_close(w, sub)
	return true
}

submenu_deadline :: proc(sub: ^Menu_Submenu) -> (time.Tick, bool) {
	if _, pending := sub.pending_row.?; pending {return time.tick_add(sub.pending_since, SUBMENU_DELAY), true}
	return ui.hover_reveal_deadline(sub.reveal)
}

// What the submenu did with a key.
Submenu_Key :: enum u8 {
	// The key is the parent's.
	Pass,
	Taken,
	// The selected row was chosen.
	Chosen,
}

// The submenu's keys while it shows with a row selected: it moves and chooses, and Left or Escape closes
// it. A submenu the pointer opened has no selection yet, so the keys stay with the highlighted row of the
// menu it hangs from, as in Radix UI, except that Left still closes it.
submenu_key :: proc(w: ^Window, sub: ^Menu_Submenu, logical: input.Key_Event) -> Submenu_Key {
	if !submenu_shown(sub) {return .Pass}
	if ui.menu_selected(&sub.menu) < 0 {
		if logical.key != .Arrow_Left {return .Pass}
		submenu_close(w, sub)
		return .Taken
	}
	switch ui.menu_key(&sub.menu, logical) {
	case .None, .Submenu:
		if logical.key == .Arrow_Left {submenu_close(w, sub)}
	case .Changed:
	case .Chosen:
		return .Chosen
	case .Closed:
		submenu_close(w, sub)
	}
	w.dirty = true
	return .Taken
}

// The pointer at x, y over the submenu or `parent`, the menu it hangs from. On the submenu it selects there.
// While the pointer heads from a row to its submenu (ui.Hover_Reveal) everything stays as it is; otherwise
// the parent row under the pointer shows its submenu after the delay or, having none, closes it. True when
// the submenu keeps the pointer.
submenu_hover :: proc(
	app: ^App,
	w: ^Window,
	sub: ^Menu_Submenu,
	parent: ^ui.Menu,
	open: Submenu_Open,
	x, y: f32,
) -> bool {
	width, height := f32(w.width), f32(w.height)
	slack, now := ui.HOVER_AIM_SLACK * w.scale, clock_now(&app.clock)
	hit := ui.menu_hit(parent, x, y, width, height, w.scale)
	if row, shown := sub.row.?; shown {
		trigger := ui.menu_row_rect(parent, row, width, height, w.scale)
		surface, _ := ui.menu_layout(&sub.menu, width, height, w.scale)
		on_trigger, on_surface := render.rect_contains(trigger, x, y), render.rect_contains(surface, x, y)
		// Another row of the menu wants the hover unless the pointer is heading for the submenu.
		on_other := !on_trigger && !on_surface && hit >= 0 && hit != row
		ui.hover_reveal_move(&sub.reveal, {x, y}, on_trigger, on_surface, on_other, trigger, surface, slack, now)
		if on_surface {
			place := ui.menu_hit(&sub.menu, x, y, width, height, w.scale)
			if place >= 0 && place != ui.menu_selected(&sub.menu) {
				ui.menu_select(&sub.menu, place)
				w.dirty = true
			}
			return true
		}
		if sub.reveal.open && !on_trigger {return true}
	}
	if hit < 0 {
		sub.pending_row = nil
		return false
	}
	if !parent.items[hit].submenu {
		submenu_close(w, sub)
		return false
	}
	if current, showing := sub.row.?; showing && current == hit {
		trigger := ui.menu_row_rect(parent, hit, width, height, w.scale)
		surface, _ := ui.menu_layout(&sub.menu, width, height, w.scale)
		ui.hover_reveal_move(&sub.reveal, {x, y}, true, false, false, trigger, surface, slack, now)
		return false
	}
	if sub.row != nil {submenu_close(w, sub)}
	if pending, waiting := sub.pending_row.?; !waiting || pending != hit {
		sub.pending_row, sub.pending_since = hit, now
	}
	_ = submenu_settle(app, w, sub, parent, open, {x, y}, now)
	return false
}

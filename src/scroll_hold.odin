package main

import "aio:layout"
import "aio:views"
import "core:time"
import "cosmos:ui"
import "cosmos:host"

// A Left press held on a scrollbar's track (ui.Scroll_Hold). Every surface that draws the shared scrollbar
// begins a hold from its press, so there is one rule for all of them. The hold is a window timer: it wakes
// the loop only while a track press is down, and a tick allocates nothing.

// The shared scrollbar a held track press pages.
Scroll_Hold_Bar :: enum u8 {
	None,
	// The overlay bar of a terminal or Markdown pane, named by the hold's content.
	Pane,
	// The tab rail's bar.
	Rail,
	// The palette's results and its open choice list.
	Palette_Results,
	Palette_Choices,
	// The settings page's bar, its theme filmstrip's and its open choice list.
	Settings_Page,
	Settings_Strip,
	Settings_Choices,
	// An Agent changes pane's file list, turn list and overview strip, named by the hold's content.
	Changes_Choices,
	Changes_Turn_List,
	Changes_Overview,
	// The Agent changes diff's bottom scrollbar, along its columns.
	Changes_H_Scroll,
}

Scroll_Hold :: struct {
	using hold: ui.Scroll_Hold(Scroll_Hold_Bar),
	content:    layout.Content,
}

// Holds the track press at (x, y) that has just paged once on `bar`.
scroll_hold_begin :: proc(
	app: ^App,
	w: ^Window,
	bar: Scroll_Hold_Bar,
	content: layout.Content,
	x, y: f32,
	side: ui.Scroll_Side,
) {
	ui.scroll_hold_begin(&w.scroll_hold.hold, bar, {x, y}, side, host.clock_now(&app.clock))
	w.scroll_hold.content = content
}

// The pointer moved: the next page aims at it.
scroll_hold_move :: proc(w: ^Window, x, y: f32) {
	ui.scroll_hold_move(&w.scroll_hold.hold, {x, y})
}

scroll_hold_end :: proc(w: ^Window) {
	w.scroll_hold = {}
}

scroll_hold_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	return ui.scroll_hold_deadline(w.scroll_hold.hold)
}

// Pages once the repeat is due.
scroll_hold_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	if !ui.scroll_hold_due(&w.scroll_hold.hold, now) {return}
	result, shown := scroll_hold_page(app, w, w.scroll_hold)
	if !shown {
		scroll_hold_end(w)
	} else if result == .Paged {
		w.dirty = true
	}
}

// One page of the held bar toward the pointer. `shown` is false once the surface that owns the bar is
// gone, which ends the hold.
@(private = "file")
scroll_hold_page :: proc(app: ^App, w: ^Window, hold: Scroll_Hold) -> (result: ui.Scroll_Page, shown: bool) {
	x, y := hold.pointer.x, hold.pointer.y
	switch hold.bar {
	case .None:
	case .Pane:
		return pane_scrollbar_page(app, w, hold.content, x, y, hold.side)
	case .Rail:
		return rail_scrollbar_page(app, w, x, y, hold.side), !w.tabs_horizontal
	case .Palette_Results, .Palette_Choices:
		if !palette_active(app, w) {return}
		track := views.Palette_Track.Results if hold.bar == .Palette_Results else .Choices
		l := views.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
		return views.palette_page(&app.palette, l, track, x, y, hold.side), true
	case .Settings_Page, .Settings_Strip, .Settings_Choices:
		if !settings_active(w) {return}
		track := views.Editor_Track.Page
		if hold.bar == .Settings_Strip {track = .Strip} else if hold.bar == .Settings_Choices {track = .Choices}
		return views.editor_page(&w.editor, settings_layout(w), track, x, y, hold.side), true
	case .Changes_Choices, .Changes_Turn_List, .Changes_Overview, .Changes_H_Scroll:
		return changes_scroll_hold_page(app, w, hold)
	}
	return
}

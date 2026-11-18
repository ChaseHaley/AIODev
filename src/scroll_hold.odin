package main

import "aio:layout"
import "aio:ui"
import "core:time"

// A Left press held on a scrollbar's track, as Windows repeats it: the press pages once at once toward the
// pointer (each surface's own press does that), and while the button stays down the window pages again
// after ui.SCROLLBAR_REPEAT_DELAY and then every ui.SCROLLBAR_REPEAT_INTERVAL, toward wherever the pointer
// is then, until the thumb reaches it. Leaving the track pauses the paging and coming back resumes it;
// the release ends it. Every surface that draws the shared scrollbar begins a hold from its press, so
// there is one rule for all of them. The hold is a window timer: it wakes the loop only while a track
// press is down, and a tick allocates nothing.

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
}

Scroll_Hold :: struct {
	bar:     Scroll_Hold_Bar,
	content: layout.Content,
	// The pointer as the last move left it; each repeat pages toward it.
	pointer: [2]f32,
	// When the next page is due.
	due:     time.Tick,
}

// Holds the track press at (x, y) that has just paged once on `bar`.
scroll_hold_begin :: proc(app: ^App, w: ^Window, bar: Scroll_Hold_Bar, content: layout.Content, x, y: f32) {
	w.scroll_hold = {
		bar     = bar,
		content = content,
		pointer = {x, y},
		due     = time.tick_add(clock_now(&app.clock), ui.SCROLLBAR_REPEAT_DELAY),
	}
}

// The pointer moved: the next page aims at it.
scroll_hold_move :: proc(w: ^Window, x, y: f32) {
	if w.scroll_hold.bar != .None {w.scroll_hold.pointer = {x, y}}
}

scroll_hold_end :: proc(w: ^Window) {
	w.scroll_hold = {}
}

scroll_hold_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	return w.scroll_hold.due, w.scroll_hold.bar != .None
}

// Pages once the repeat is due. The next page is a repeat interval after this one, not after the due
// time, so a stalled loop pages once on waking rather than catching up.
scroll_hold_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	hold := &w.scroll_hold
	if hold.bar == .None || time.tick_diff(hold.due, now) < 0 {return}
	hold.due = time.tick_add(now, ui.SCROLLBAR_REPEAT_INTERVAL)
	result, shown := scroll_hold_page(app, w, hold^)
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
		return pane_scrollbar_page(app, w, hold.content, x, y)
	case .Rail:
		return rail_scrollbar_page(app, w, x, y), !w.tabs_horizontal
	case .Palette_Results, .Palette_Choices:
		if !palette_active(app, w) {return}
		track := ui.Palette_Track.Results if hold.bar == .Palette_Results else .Choices
		l := ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
		return ui.palette_page(&app.palette, l, track, x, y), true
	case .Settings_Page, .Settings_Strip, .Settings_Choices:
		if !settings_active(w) {return}
		track := ui.Editor_Track.Page
		if hold.bar == .Settings_Strip {track = .Strip} else if hold.bar == .Settings_Choices {track = .Choices}
		return ui.editor_page(&w.editor, settings_layout(w), track, x, y), true
	case .Changes_Choices, .Changes_Turn_List, .Changes_Overview:
		return changes_scroll_hold_page(app, w, hold)
	}
	return
}

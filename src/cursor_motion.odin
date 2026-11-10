package main

import "aio:caret"
import "aio:layout"
import "aio:render"
import "aio:term_view"
import "aio:ui"
import "core:time"

// Presets and tuning reach every terminal through the same style, including cached split panes, and
// every text field's caret through the window's ui.Carets. Windows' motion preference overrides the
// preset without changing the user's saved choice.
cursor_effects :: proc(app: ^App) -> caret.Effects {
	c := app.settings.cursor
	preset := caret.Preset.Off
	if app.animations {
		switch c.animation {
		case .Off:    preset = .Off
		case .Smooth: preset = .Smooth
		case .Smear:  preset = .Smear
		case .Trail:  preset = .Trail
		}
	}
	return {
		preset = preset,
		duration = time.Duration(c.animation_duration) * time.Millisecond,
		strength = f32(c.animation_strength) / 100,
		movement = c.animation_movement,
	}
}

// Tracking owns the last cursor the completed window frame showed. Pending suppresses the new
// pane before its capture is known; Flying draws the window overlay. Final draws a landed or
// degenerate transition, and Restoring rebuilds the ordinary cursor exactly once.
Cursor_Crossing_Phase :: enum u8 {Empty, Tracking, Pending, Flying, Final, Restoring}

@(private = "file")
CURSOR_CROSSING_OVERLAY_PHASES :: bit_set[Cursor_Crossing_Phase]{.Pending, .Flying, .Final}
@(private = "file")
CURSOR_CROSSING_LIVE_PHASES :: bit_set[Cursor_Crossing_Phase]{.Pending, .Flying, .Final, .Restoring}

Cursor_Crossing :: struct {
	phase: Cursor_Crossing_Phase,
	tree: ^layout.Layout,
	source, destination: layout.Content,
	drawn, goal: term_view.Cursor_Paint,
	drawn_at: time.Tick,
	effects: caret.Effects,
	transition: term_view.Cursor_Transition,
}

cursor_paint_translate :: proc(paint: term_view.Cursor_Paint, offset: [2]f32) -> term_view.Cursor_Paint {
	result := paint
	result.head.x += offset.x
	result.head.y += offset.y
	result.tail.x += offset.x
	result.tail.y += offset.y
	result.target.x += offset.x
	result.target.y += offset.y
	return result
}

@(private = "file")
cursor_crossing_enabled :: proc(app: ^App, w: ^Window) -> bool {
	return app.settings.cursor.animation_across_panes && app.animations &&
	       app.settings.cursor.animation != .Off && window_drawable(w) &&
	       caret.effects_active(cursor_effects(app))
}

@(private = "file")
cursor_crossing_pane_visible :: proc(w: ^Window, content: layout.Content) -> bool {
	for pane in w.panes {
		if pane.content != content {continue}
		f := pane_frame(w, pane)
		return f.shown.width >= 1 && f.shown.height >= 1 && pane_view(w, content) != nil
	}
	return false
}

@(private = "file")
cursor_crossing_focus :: proc(app: ^App, w: ^Window) -> (layout.Content, bool) {
	for pane in w.panes {
		if pane.content.kind == .Terminal && pane_has_keyboard(app, w, pane) &&
		   cursor_crossing_pane_visible(w, pane.content) &&
		   workspace_session_for_content(app, pane.content) != nil {
			return pane.content, true
		}
	}
	return {}, false
}

cursor_crossing_suppresses :: proc(w: ^Window, content: layout.Content) -> bool {
	c := &w.cursor_crossing
	return c.destination == content &&
	       c.phase in CURSOR_CROSSING_OVERLAY_PHASES
}

// OS focus loss calls this immediately, so losing and regaining focus between frames cannot replay
// a cursor belonging to an earlier focus bracket.
cursor_crossing_forget :: proc(w: ^Window) {
	if w.cursor_crossing.phase == .Empty {return}
	for &view in w.views {
		if view.style.cursor_suppressed {view.valid = false}
	}
	w.cursor_crossing = {}
}

@(private)
cursor_crossing_prepare :: proc(app: ^App, w: ^Window) {
	c := &w.cursor_crossing
	if !cursor_crossing_enabled(app, w) {cursor_crossing_forget(w); return}
	focus, focused := cursor_crossing_focus(app, w)
	if !focused {
		cursor_crossing_forget(w)
		return
	}
	if c.phase == .Empty {return}
	if c.tree != window_tree(w) ||
	   !cursor_crossing_pane_visible(w, c.destination) ||
	   (c.phase != .Tracking && !cursor_crossing_pane_visible(w, c.source)) {
		cursor_crossing_forget(w)
		return
	}
	if focus == c.destination {return}
	// A rapid switch starts at the overlay's last drawn pose, never at its logical target or an
	// unpainted sample. Tracking already contains the last local animation pose.
	if c.phase == .Flying || c.phase == .Final {
		c.drawn = term_view.cursor_transition_paint(&c.transition)
	}
	c.source = c.destination
	c.destination = focus
	c.phase = .Pending
}

@(private = "file")
cursor_crossing_goal :: proc(paint: term_view.Cursor_Paint) -> term_view.Cursor_Paint {
	result := paint
	result.head, result.tail = result.target, result.target
	return result
}

@(private)
cursor_crossing_draw :: proc(app: ^App, w: ^Window) {
	c := &w.cursor_crossing
	if c.phase not_in CURSOR_CROSSING_OVERLAY_PHASES {return}
	view := pane_view(w, c.destination)
	if view == nil {cursor_crossing_forget(w); return}
	paint, shown := view.cursor.?
	if !shown {cursor_crossing_forget(w); return}
	goal := cursor_crossing_goal(paint)
	effects := cursor_effects(app)
	if c.phase == .Pending || c.goal != goal || c.effects != effects {
		departing := c.phase == .Pending
		if c.phase != .Pending {c.drawn = term_view.cursor_transition_paint(&c.transition)}
		c.goal = goal
		c.effects = effects
		term_view.cursor_transition_start(&c.transition, c.drawn, goal, effects)
		// Focus changes first show the departure pose. Output retargets consume the time since
		// the last completed frame, so a moving destination cannot pin the head at its source.
		first := w.frame
		first.period = departing ? 0 : clamp(time.tick_diff(c.drawn_at, first.display), 0, effects.duration)
		_ = term_view.cursor_transition_animate(&c.transition, first, true)
		c.phase = term_view.cursor_transition_active(&c.transition) ? .Flying : .Final
	}
	clip := render.Rect{0, 0, f32(w.width), f32(w.height)}
	term_view.cursor_transition_draw(&c.transition, &w.list, clip)
	// Replay text in the same bottom-to-top order as the cards. Each pane clears the head's
	// intersection under its original rounded mask before replaying its own cached glyphs.
	raised: Maybe(layout.Pane_Rect)
	for pane in w.panes {
		if pane.floating {continue}
		if pane_motion_raised(w, pane) {raised = pane; continue}
		cursor_crossing_pane(app, w, pane)
	}
	if pane, ok := raised.?; ok {cursor_crossing_pane(app, w, pane)}
	for pane in w.panes {
		if pane.floating {cursor_crossing_pane(app, w, pane)}
	}
	if c.phase == .Flying && !w.frame.resuming {w.frame_moved = true}
}

@(private = "file")
cursor_crossing_pane :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	source: ^render.Draw_List
	if pane.content.kind == .Terminal {
		if view := pane_view(w, pane.content); view != nil {source = &view.cache}
	}
	f := pane_frame(w, pane)
	if f.shown.width < 1 || f.shown.height < 1 {return}
	term_view.cursor_transition_pane(
		&w.cursor_crossing.transition, &w.list, source, f.offset,
		{f.shown.x, f.shown.y, f.shown.width, f.shown.height}, window_pane_radius(app, w),
	)
}

// Only a successfully completed frame may become the source of the next crossing.
cursor_crossing_commit :: proc(app: ^App, w: ^Window) {
	c := &w.cursor_crossing
	if c.phase == .Flying || c.phase == .Final {
		term_view.cursor_transition_commit(&c.transition)
		c.drawn_at = w.frame.display
	}
	if c.phase == .Final {
		// This frame learned that the flight landed after its pane was already suppressed.
		// Keep the static overlay visible, then replace the suppressed cache next frame.
		c.drawn = term_view.cursor_transition_paint(&c.transition)
		c.phase = .Restoring
		if view := pane_view(w, c.destination); view != nil {view.valid = false}
		return
	}
	if c.phase == .Pending || c.phase == .Flying {return}
	if !cursor_crossing_enabled(app, w) {cursor_crossing_forget(w); return}
	focus, focused := cursor_crossing_focus(app, w)
	if !focused {cursor_crossing_forget(w); return}
	view := pane_view(w, focus)
	if view == nil {cursor_crossing_forget(w); return}
	paint, shown := view.cursor.?
	if !shown {cursor_crossing_forget(w); return}
	c^ = {
		phase = .Tracking, tree = window_tree(w), destination = focus,
		drawn = paint, drawn_at = w.frame.display,
	}
}

// Only a shown pane with the keyboard keeps cursor motion alive. Clearing the view on loss of
// focus also prevents output accumulated while hidden from flying across the pane when it returns.
cursor_motion_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := false
	before := w.cursor_crossing.phase
	cursor_crossing_prepare(app, w)
	c := &w.cursor_crossing
	if before in CURSOR_CROSSING_LIVE_PHASES &&
	   c.phase == .Empty {changed = true}
	switch c.phase {
	case .Flying:
		if term_view.cursor_transition_animate(&c.transition, frame, true) {changed = true}
		if !term_view.cursor_transition_active(&c.transition) {
			c.phase = .Final
			changed = true
		}
	case .Final, .Restoring:
		changed = true
	case .Empty, .Tracking, .Pending:
	}
	enabled := app.animations && app.settings.cursor.animation != .Off &&
	           window_drawable(w)
	for &view in w.views {
		if view.content.kind != .Terminal {continue}
		focused := false
		if enabled {
			for pane in w.panes {
				if pane.content == view.content {
					focused = pane_has_keyboard(app, w, pane) &&
					          !cursor_crossing_suppresses(w, pane.content)
					break
				}
			}
		}
		moved := false
		if focused {
			moved = term_view.cursor_animate(&view.view, frame, true)
		} else {
			moved = term_view.cursor_animating(&view.view)
			term_view.cursor_reset(&view.view)
		}
		if moved {view.valid = false; changed = true}
	}
	return changed
}

cursor_motion_animating :: proc(w: ^Window) -> bool {
	if !window_drawable(w) {return false}
	if w.cursor_crossing.phase in CURSOR_CROSSING_LIVE_PHASES {
		return true
	}
	for &view in w.views {
		if view.content.kind == .Terminal && term_view.cursor_animating(&view.view) {return true}
	}
	return false
}

package main

import "cosmos:caret"
import "aio:layout"
import "cosmos:render"
import "aio:term_view"
import "core:math"
import "core:time"
import "cosmos:ui"
@(require) import "aio:views"

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

// How a text field's, editor's and Markdown view's caret looks: the cursor.style shape, as thick a
// stroke as one pixel at the window's scale, and cursor.blink. DECSCUSR changes only its terminal.
cursor_caret_style :: proc(app: ^App, w: ^Window) -> ui.Caret_Style {
	shape := caret.Shape.Bar
	switch app.settings.cursor.style {
	case .Block:     shape = .Block
	case .Bar:       shape = .Bar
	case .Underline: shape = .Underline
	}
	return {shape = shape, stroke = max(1, math.round(w.scale)), blinks = app.settings.cursor.blink}
}

// The owner of the caret while a terminal pane holds the keyboard. Field carets name themselves by
// address (ui.caret_owner_of), which never has the top bit.
terminal_caret_owner :: proc(content: layout.Content) -> ui.Caret_Owner {
	return ui.Caret_Owner(u64(1) << 63 | u64(content.kind) << 32 | u64(content.id))
}

// The pane a terminal owner names; false for every other surface.
@(private = "file")
caret_owner_terminal :: proc(owner: ui.Caret_Owner) -> (layout.Content, bool) {
	if u64(owner) >> 63 == 0 {return {}, false}
	return {kind = layout.Content_Kind(u64(owner) >> 32 & 0xff), id = u32(owner)}, true
}

// Tracking owns the last cursor the completed window frame showed. Pending is the frame a new
// surface took the keyboard: its own caret waits while the window overlay flies the head to it.
// Flying draws that overlay. Final draws a landed or degenerate transition, and Restoring lets the
// surface draw its ordinary caret exactly once more before it is tracked again.
Cursor_Crossing_Phase :: enum u8 {Empty, Tracking, Pending, Flying, Final, Restoring}

@(private = "file")
CURSOR_CROSSING_OVERLAY_PHASES :: bit_set[Cursor_Crossing_Phase]{.Pending, .Flying, .Final}
@(private = "file")
CURSOR_CROSSING_LIVE_PHASES :: bit_set[Cursor_Crossing_Phase]{.Pending, .Flying, .Final, .Restoring}

// The window's one caret in flight between surfaces: terminal panes, palette, find bar, fields and
// editors. `destination` is the surface that has it, or is about to; `source` the one it left.
Cursor_Crossing :: struct {
	phase: Cursor_Crossing_Phase,
	tree: ^layout.Layout,
	source, destination: ui.Caret_Owner,
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

// A terminal owner is only there while its pane shows; any other surface draws or is gone with its
// own claim.
@(private = "file")
cursor_crossing_owner_visible :: proc(w: ^Window, owner: ui.Caret_Owner) -> bool {
	content, terminal := caret_owner_terminal(owner)
	return !terminal || cursor_crossing_pane_visible(w, content)
}

cursor_crossing_suppresses :: proc(w: ^Window, content: layout.Content) -> bool {
	c := &w.cursor_crossing
	return c.destination == terminal_caret_owner(content) &&
	       c.phase in CURSOR_CROSSING_OVERLAY_PHASES
}

// OS focus loss calls this immediately, so losing and regaining focus between frames cannot replay
// a cursor belonging to an earlier focus bracket.
cursor_crossing_forget :: proc(w: ^Window) {
	w.carets.tracked, w.carets.flying = 0, 0
	if w.cursor_crossing.phase == .Empty {return}
	for &view in w.pane_views {
		if view.style.cursor_suppressed {view.valid = false}
	}
	w.cursor_crossing = {}
}

// Tells the surfaces about to draw where the caret is, and whether a flight is carrying it.
@(private)
cursor_crossing_prepare :: proc(app: ^App, w: ^Window) {
	c := &w.cursor_crossing
	w.carets.flights = false
	if !cursor_crossing_enabled(app, w) {cursor_crossing_forget(w); return}
	w.carets.flights = true
	if c.phase == .Empty {
		w.carets.tracked, w.carets.flying = 0, 0
		return
	}
	if c.tree != window_tree(w) ||
	   !cursor_crossing_owner_visible(w, c.destination) ||
	   (c.phase != .Tracking && !cursor_crossing_owner_visible(w, c.source)) {
		cursor_crossing_forget(w)
		return
	}
	w.carets.tracked = c.destination
	w.carets.flying = c.phase in CURSOR_CROSSING_OVERLAY_PHASES ? c.destination : 0
}

@(private = "file")
cursor_crossing_goal :: proc(paint: term_view.Cursor_Paint) -> term_view.Cursor_Paint {
	result := paint
	result.head, result.tail = result.target, result.target
	return result
}

// Called once every surface, the palette and the overlays have drawn, so the head flies above them.
// A surface that took the keyboard left drawing its caret to this flight (the claim is `held`).
@(private)
cursor_crossing_draw :: proc(app: ^App, w: ^Window) {
	c := &w.cursor_crossing
	claim := w.carets.claim
	if !w.carets.flights {return}
	if !claim.present {
		if c.phase != .Empty {cursor_crossing_forget(w)}
		return
	}
	if !claim.held {return}
	if claim.owner != c.destination || c.phase not_in CURSOR_CROSSING_OVERLAY_PHASES {
		// The caret goes somewhere new. A rapid switch starts at the overlay's last drawn pose, never
		// at its logical target or an unpainted sample; Tracking already holds the last local pose.
		if c.phase == .Flying || c.phase == .Final {
			c.drawn = term_view.cursor_transition_paint(&c.transition)
		}
		c.source, c.destination = c.destination, claim.owner
		c.phase = .Pending
		cursor_blink_reset(w, clock_now(&app.clock))
	}
	goal := cursor_crossing_goal(claim.paint)
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
	// Between two terminals a block head draws the text it covers in the cursor text colour. Replay
	// text in the same bottom-to-top order as the cards. Each pane clears the head's intersection
	// under its original rounded mask before replaying its own cached glyphs. Other surfaces have no
	// glyphs to replay, so a block head covers their text on its way.
	_, from := caret_owner_terminal(c.source)
	_, to := caret_owner_terminal(c.destination)
	if from && to {
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
		// This frame learned that the flight landed after its surface was already suppressed.
		// Keep the static overlay visible, then let the surface draw its own caret next frame; a
		// terminal's cached list still holds the suppressed cursor, so it is rebuilt. The caret starts
		// its blink visible.
		c.drawn = term_view.cursor_transition_paint(&c.transition)
		c.phase = .Restoring
		if content, terminal := caret_owner_terminal(c.destination); terminal {
			if view := pane_view(w, content); view != nil {view.valid = false}
		}
		cursor_blink_reset(w, clock_now(&app.clock))
		return
	}
	if c.phase == .Pending || c.phase == .Flying {return}
	if !cursor_crossing_enabled(app, w) {cursor_crossing_forget(w); return}
	claim := w.carets.claim
	if !claim.present {cursor_crossing_forget(w); return}
	c^ = {
		phase = .Tracking, tree = window_tree(w), destination = claim.owner,
		drawn = claim.paint, drawn_at = w.frame.display,
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
	for &view in w.pane_views {
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
	for pane in w.panes {
		if pane.content.kind != .Neovim {continue}
		np := neovim_find(app, pane.content.id)
		if np == nil {continue}
		if enabled && pane_has_keyboard(app, w, pane) && !cursor_crossing_suppresses(w, pane.content) {
			changed ||= term_view.neovim_cursor_animate(&np.view, frame, true)
		} else {
			changed ||= term_view.neovim_cursor_animating(&np.view)
			term_view.neovim_cursor_reset(&np.view)
		}
	}
	return changed
}

cursor_motion_animating :: proc(w: ^Window) -> bool {
	if !window_drawable(w) {return false}
	if w.cursor_crossing.phase in CURSOR_CROSSING_LIVE_PHASES {
		return true
	}
	for &view in w.pane_views {
		if view.content.kind == .Terminal && term_view.cursor_animating(&view.view) {return true}
	}
	return false
}

// A Neovim pane's cursor still moving, which keeps the window drawing as a terminal's cursor does.
neovim_cursors_animating :: proc(app: ^App, w: ^Window) -> bool {
	if !window_drawable(w) {return false}
	for pane in w.panes {
		if pane.content.kind != .Neovim {continue}
		if np := neovim_find(app, pane.content.id); np != nil && term_view.neovim_cursor_animating(&np.view) {
			return true
		}
	}
	return false
}

when AIO_CONTROL {
	// Who holds the window's one caret, where, how it looks and whether a flight carries it. While a
	// flight runs the rect and colour are the overlay head's, as last drawn.
	caret_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		claim, c := w.carets.claim, &w.cursor_crossing
		flying := c.phase in CURSOR_CROSSING_OVERLAY_PHASES
		owner := "none"
		if claim.present {owner = caret_owner_name(app, w, claim.owner)}
		paint := claim.paint
		head, color := paint.head, paint.color
		if flying {
			head = c.transition.motion.head
			color = caret.mix_colors(
				c.transition.color_from, c.transition.paint.color, caret.smooth(c.transition.motion.progress),
			)
		}
		state_value(r, "caret.present", claim.present)
		state_text(r, "caret.owner", owner)
		state_text(r, "caret.phase", flying ? "flying" : "rest")
		state_value(r, "caret.held", claim.held)
		state_value(r, "caret.flights", w.carets.flights)
		state_rect(r, "caret.rect", head)
		state_rect(r, "caret.target", paint.target)
		state_word(r, "caret.shape", paint.shape)
		state_valuef(
			r, "caret.color", "#%02x%02x%02x",
			u8(math.round(color.r * 255)), u8(math.round(color.g * 255)), u8(math.round(color.b * 255)),
		)
		blink := "steady"
		if on, blinking := w.cursor_blink.(Cursor_Blink_On); blinking {blink = on.visible ? "shown" : "hidden"}
		state_text(r, "caret.blink", blink)
	}

	@(private = "file")
	caret_owner_name :: proc(app: ^App, w: ^Window, owner: ui.Caret_Owner) -> string {
		if content, terminal := caret_owner_terminal(owner); terminal {
			return state_key("pane:%d", content.id)
		}
		switch {
		case owner == ui.caret_owner_of(&app.palette.query.caret):
			return "palette.query"
		case owner == ui.caret_owner_of(&w.find.query.caret):
			return "find"
		}
		if pane := markdown_focused(app, w); pane != nil && owner == ui.caret_owner_of(&pane.view.caret) {
			return "markdown"
		}
		return "field"
	}
}

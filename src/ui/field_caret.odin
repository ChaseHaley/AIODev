package ui

import "cosmos:caret"
import "cosmos:render"

// Who holds a window's text cursor: a terminal pane, or the caret of a field, text area or Markdown
// view, named by where its Field_Caret lives. Zero is nobody.
Caret_Owner :: distinct u64

caret_owner_of :: proc(carrier: ^Field_Caret) -> Caret_Owner {
	return Caret_Owner(uintptr(carrier))
}

// How every text cursor looks, whichever surface draws it: cursor.style and the pixel size of a stroke.
// Colours come from the theme.
Caret_Style :: struct {
	shape:  caret.Shape,
	stroke: f32,
	// cursor.blink: whether a focused caret blinks with the window's phase.
	blinks: bool,
}

// The one live caret a frame drew, which the window tracks from frame to frame. A claim is made even
// when the surface left drawing to a flight (`held`) or its caret is in a hidden blink phase.
Caret_Claim :: struct {
	present, held: bool,
	owner:         Caret_Owner,
	paint:         caret.Paint,
	blinks:        bool,
}

// What every text field caret a window draws in one frame shares: the Cursor Animation settings and
// the moment the frame will be on screen. The window owns it and its Text carries it, so any field
// drawn with the window's text animates without its owner tracking anything.
Carets :: struct {
	effects: caret.Effects,
	frame:   Frame_Time,
	// Counts the window's frames, so a field can tell that it drew its caret in the frame before.
	build:   u64,
	// A caret drew partway through a move, so the window must draw again.
	moving:  bool,
	style:   Caret_Style,
	// The window's blink phase is in its shown part; a caret that moved restarts the phase, so it shows.
	shown, restart: bool,
	// Whether the keyboard may take the caret from one surface to another with a flight, the owner the
	// last good frame left it with, and the owner a flight is carrying it to, whose own caret waits.
	flights:         bool,
	tracked, flying: Caret_Owner,
	// What this frame's surface that holds the keyboard drew. The window reads it once the frame is built.
	claim: Caret_Claim,
}

// Starts a frame of the window that owns `c`; every attempt to build that frame shares it.
carets_begin :: proc(c: ^Carets, effects: caret.Effects, frame: Frame_Time) {
	c.effects, c.frame, c.moving, c.restart, c.claim = effects, frame, false, false, {}
	c.build += 1
}

// Whether a caret drawn by `owner` now waits for a flight: one is already carrying the caret to it,
// or the caret was elsewhere after the last good frame.
caret_holds :: proc(c: ^Carets, owner: Caret_Owner) -> bool {
	return c != nil && c.flights && owner != 0 && (owner == c.flying || (c.tracked != 0 && c.tracked != owner))
}

// The surface that holds the keyboard reports where its caret is. The last claim of a frame wins, as
// the topmost surface draws last. True when the surface must not draw its own caret: a flight brings it.
caret_claim :: proc(c: ^Carets, owner: Caret_Owner, paint: caret.Paint, blinks: bool) -> (held: bool) {
	held = caret_holds(c, owner)
	c.claim = {present = true, held = held, owner = owner, paint = paint, blinks = blinks}
	return held
}

// Whether a caret in its phase of the window's blink shows. A caret that moves, and one still moving,
// shows whatever the phase.
caret_shown :: proc(c: ^Carets, moving: bool) -> bool {
	return c == nil || c.shown || c.restart || moving || !c.style.blinks
}

// One field's caret motion. A caret moves only while its field keeps drawing it in consecutive frames
// of the same window at the same place; otherwise it appears where it is.
Field_Caret :: struct {
	motion: caret.Motion,
	origin: [2]f32,
	carets: ^Carets,
	build:  u64,
}

// Where the caret draws this frame, on its way to `cell` (the cell the cursor occupies) from where the
// previous frame drew it, and whether the surface draws it at all: not while a flight carries it.
@(private)
field_caret_pose :: proc(
	c: ^Field_Caret, carets: ^Carets, origin: [2]f32, cell: render.Rect, theme: Theme,
) -> (head: render.Rect, drawn: bool) {
	m := &c.motion
	// A caret that kept its place in the window and went to another cell moved, animated or not.
	if carets != nil && c.carets == carets && (c.build == carets.build || c.build + 1 == carets.build) &&
	   c.origin == origin && m.target != cell {
		carets.restart = true
	}
	if carets == nil || c.carets != carets || (c.build != carets.build && c.build + 1 != carets.build) ||
	   c.origin != origin || m.effects != carets.effects || m.target.height != cell.height ||
	   !caret.effects_active(carets.effects) || carets.frame.display == {} {
		c^ = {
			motion = {target = cell, head = cell, tail = cell, drawn_head = cell, drawn_tail = cell},
			origin = origin,
			carets = carets,
		}
		if carets != nil {c.motion.effects, c.build = carets.effects, carets.build}
		head = cell
	} else {
		c.build = carets.build
		if cell != m.target {caret.motion_retarget(m, cell)}
		if m.active {
			t := caret.motion_progress(m, carets.frame)
			if t >= 1 {m.active = false}
			caret.motion_place(m, t)
			if m.active {carets.moving = true}
		}
		caret.motion_drawn(m)
		head = m.head
	}
	if carets == nil {return head, true}
	paint := caret.Paint {
		head = head, tail = m.tail, target = cell, shape = carets.style.shape, stroke = carets.style.stroke,
		color = theme.caret, text_color = theme.caret_text,
	}
	if caret_claim(carets, caret_owner_of(c), paint, carets.style.blinks) {
		// A flight draws the caret; the field starts afresh where it lands.
		c.motion = {target = cell, head = cell, tail = cell, drawn_head = cell, drawn_tail = cell}
		c.motion.effects = carets.effects
		return cell, false
	}
	return head, true
}

// The smear or trail behind a moving caret, drawn under the field's text.
@(private)
field_caret_body :: proc(c: ^Field_Caret, list: ^render.Draw_List, theme: Theme) {
	m := &c.motion
	if !m.active || c.carets == nil {return}
	style := c.carets.style
	paint := caret.Paint {
		head = m.head, tail = m.tail, shape = style.shape, stroke = style.stroke, color = theme.caret,
	}
	caret.paint_body_draw(list, paint, caret.motion_corners(m), m.effects, m.progress)
}

// Draws a caret's head in the cursor's shape. A block covers the text under it, so it draws inside a
// clip scope over the head, which the caller closes after drawing that text again in `theme.caret_text`;
// the other shapes need no more and return `block` false.
@(private)
field_caret_head :: proc(
	list: ^render.Draw_List, c: ^Field_Caret, theme: Theme, head: render.Rect,
) -> (scope: Clip_Scope, block: bool) {
	style := Caret_Style{shape = .Bar, stroke = 1}
	if c.carets != nil {style = c.carets.style}
	if style.shape != .Block {
		caret.shape_draw(list, style.shape, style.stroke, head, theme.caret)
		return {}, false
	}
	opened: bool
	scope, opened = clip_scope_open(list, head)
	if !opened {return scope, false}
	caret.shape_draw(list, .Block, style.stroke, head, theme.caret)
	return scope, true
}

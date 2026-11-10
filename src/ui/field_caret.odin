package ui

import "aio:caret"
import "aio:render"

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
}

// Starts a frame of the window that owns `c`; every attempt to build that frame shares it.
carets_begin :: proc(c: ^Carets, effects: caret.Effects, frame: Frame_Time) {
	c.effects, c.frame, c.moving = effects, frame, false
	c.build += 1
}

// One field's caret motion. A caret moves only while its field keeps drawing it in consecutive frames
// of the same window at the same place; otherwise it appears where it is.
Field_Caret :: struct {
	motion: caret.Motion,
	origin: [2]f32,
	carets: ^Carets,
	build:  u64,
}

// Where the caret draws this frame, on its way to `target` from where the previous frame drew it.
@(private)
field_caret_pose :: proc(
	c: ^Field_Caret, carets: ^Carets, origin: [2]f32, target: render.Rect,
) -> render.Rect {
	m := &c.motion
	if carets == nil || c.carets != carets || (c.build != carets.build && c.build + 1 != carets.build) ||
	   c.origin != origin || m.effects != carets.effects || m.target.height != target.height ||
	   !caret.effects_active(carets.effects) || carets.frame.display == {} {
		c^ = {
			motion = {target = target, head = target, tail = target, drawn_head = target, drawn_tail = target},
			origin = origin,
			carets = carets,
		}
		if carets != nil {c.motion.effects, c.build = carets.effects, carets.build}
		return target
	}
	c.build = carets.build
	if target != m.target {caret.motion_retarget(m, target)}
	if m.active {
		t := caret.motion_progress(m, carets.frame)
		if t >= 1 {m.active = false}
		caret.motion_place(m, t)
		if m.active {carets.moving = true}
	}
	m.drawn_head, m.drawn_tail = m.head, m.tail
	return m.head
}

// The smear or trail behind a moving caret, drawn under the field's text.
@(private)
field_caret_body :: proc(c: ^Field_Caret, list: ^render.Draw_List, color: render.Color) {
	m := &c.motion
	if !m.active {return}
	caret.body_draw(list, m.tail, m.head, m.effects, color, m.progress)
}

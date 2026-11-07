package ui

import "aio:render"
import "core:strings"
import "core:time"

@(private)
NOTICE_WIDTH :: 520
@(private)
NOTICE_MARGIN :: 16
@(private)
NOTICE_PADDING :: 12
@(private)
NOTICE_MAX_LINES :: 4
@(private)
NOTICE_PRESENCE :: Presence_Spec {
	open  = 160 * time.Millisecond,
	close = 120 * time.Millisecond,
}

Notice_Kind :: enum u8 {
	Info,
	Error,
	Warning,
	Success,
}

@(private)
Notice_Look :: struct {
	label:  string,
	symbol: Icon,
}

@(private, rodata)
NOTICE_LOOKS := [Notice_Kind]Notice_Look {
	.Info    = {"Info", .Info},
	.Error   = {"Error", .Error},
	.Warning = {"Warning", .Warning},
	.Success = {"Success", .Success},
}

notice_style :: proc(
	kind: Notice_Kind,
	theme: Theme,
) -> (
	label: string,
	symbol: Icon,
	color: render.Color,
) {
	look := NOTICE_LOOKS[kind]
	switch kind {
	case .Info: color = theme.info
	case .Warning: color = theme.warning
	case .Error: color = theme.error
	case .Success: color = theme.success
	}
	return look.label, look.symbol, color
}

Notice_Entering :: struct {
	presence: Presence,
	// A sticky notice has no deadline. Timed notices count from arrival, not from the end of entry.
	expires: Maybe(time.Tick),
}
Notice_Shown :: struct {expires: time.Tick}
Notice_Sticky :: struct {}
Notice_Fading :: struct {presence: Presence}

Notice_State :: union #no_nil {
	Notice_Sticky,
	Notice_Entering,
	Notice_Shown,
	Notice_Fading,
}

Notice :: struct {
	id:    u64,
	key:   u32,
	kind:  Notice_Kind,
	text:  string,
	state: Notice_State,
}

Notices :: struct {
	next_id: u64,
	// The live notices in the order they arrived, then the fading ones in the order they began to
	// fade, so a notice leaves from the bottom of the stack. notice_fade keeps that order.
	items:   [dynamic]Notice,
	// The close button under the pointer and the one a press armed, in the window that holds the
	// notices. A fade drops either when it names the fading notice.
	hover:   u64,
	armed:   Armed(u64),
	// Scratch storage for the lines notice_layout wraps; only the layout's returned slice is read.
	lines:   [dynamic]string,
}

notices_init :: proc(n: ^Notices, allocator := context.allocator) {
	n.items = make([dynamic]Notice, allocator)
	n.lines = make([dynamic]string, allocator)
}

notices_destroy :: proc(n: ^Notices) {
	for item in n.items {
		delete(item.text, n.items.allocator)
	}
	delete(n.items)
	delete(n.lines)
	n^ = {}
}

notice_fading :: proc(item: Notice) -> bool {
	_, fading := item.state.(Notice_Fading)
	return fading
}

notice_expiry :: proc(item: Notice) -> Maybe(time.Tick) {
	switch state in item.state {
	case Notice_Entering: return state.expires
	case Notice_Shown: return state.expires
	case Notice_Sticky, Notice_Fading:
	}
	return nil
}

@(private)
notice_fade_of :: proc(item: Notice, rise: f32) -> Fade {
	switch state in item.state {
	case Notice_Entering: return presence_fade(state.presence, rise)
	case Notice_Fading: return presence_fade(state.presence, rise)
	case Notice_Shown, Notice_Sticky:
	}
	return FADE_NONE
}

// The live notices, which lead the list.
notices_live :: proc(n: ^Notices) -> []Notice {
	for item, i in n.items {
		if notice_fading(item) {return n.items[:i]}
	}
	return n.items[:]
}

// Shows a notice. A nonzero key replaces the notice already shown under it; a zero duration is sticky.
// `enabled` and `now` are the caller's animation policy and clock, as for every notice transition.
notices_put :: proc(
	n: ^Notices,
	key: u32,
	kind: Notice_Kind,
	text: string,
	duration: time.Duration,
	enabled: bool,
	now: time.Tick,
) {
	// The new notice's storage is in place before a keyed notice it replaces starts to fade, so a
	// notice that cannot be stored leaves the current one showing.
	owned, err := strings.clone(text, n.items.allocator)
	if err != nil {
		return
	}
	if reserve(&n.items, len(n.items) + 1) != nil {
		delete(owned, n.items.allocator)
		return
	}
	if key != 0 {
		notices_clear(n, key, enabled, now)
	}
	n.next_id += 1
	notice := Notice {
		id   = n.next_id,
		key  = key,
		kind = kind,
		text = owned,
	}
	entering: Notice_Entering
	presence_open(&entering.presence, NOTICE_PRESENCE)
	if duration != 0 {entering.expires = time.tick_add(now, duration)}
	notice.state = entering
	_, _ = notice_advance(&notice, enabled, now)
	inject_at(&n.items, len(notices_live(n)), notice)
}

notices_clear :: proc(n: ^Notices, key: u32, enabled: bool, now: time.Tick) -> bool {
	for i := len(notices_live(n)) - 1; i >= 0; i -= 1 {
		if n.items[i].key == key {
			notice_fade(n, i, enabled, now)
			return true
		}
	}
	return false
}

notices_dismiss :: proc(n: ^Notices, id: u64, enabled: bool, now: time.Tick) -> bool {
	for item, i in notices_live(n) {
		if item.id == id {notice_fade(n, i, enabled, now); return true}
	}
	return false
}

// Reports whether the hovered close button changed, so the caller redraws only then.
notices_hover :: proc(n: ^Notices, id: u64) -> bool {
	if n.hover == id {return false}
	n.hover = id
	return true
}

notices_press :: proc(n: ^Notices, id: u64) {
	armed_press(&n.armed, id)
}

// Dismisses the notice whose close button both the press and this release landed on.
notices_release :: proc(n: ^Notices, id: u64, enabled: bool, now: time.Tick) -> (dismissed: bool) {
	fired, ok := armed_release(&n.armed, id)
	return ok && fired != 0 && notices_dismiss(n, fired, enabled, now)
}

notices_pointer_cancel :: proc(n: ^Notices) {
	n.hover = 0
	armed_cancel(&n.armed)
}

Notice_Hit :: struct {
	id: u64,
	close, contains: bool,
}

// `lines` are every wrapped line of the text; the first `shown` fit the notice.
@(private)
Notice_Layout :: struct {
	box, close:                    render.Rect,
	content_width, heading_height: f32,
	lines:                         []string,
	shown:                         int,
}

// Wraps the item's text into `scratch`; the returned layout's lines stay valid until the next wrap.
@(private)
notice_layout :: proc(
	item: Notice, text: ^Text, width, bottom, scale: f32, scratch: ^[dynamic]string,
) -> Notice_Layout {
	padding := NOTICE_PADDING * scale
	max_width := min(NOTICE_WIDTH * scale, max(0, width - 2 * NOTICE_MARGIN * scale))
	leading := (4 + ICON_BUTTON + SPACE_2) * scale
	trailing := (HEIGHT_COMPACT + SPACE_2) * scale
	content_width := max(scale, max_width - 2 * padding - leading - trailing)
	wrap(text, item.text, content_width, scratch)
	lines := scratch[:]
	shown := min(len(lines), NOTICE_MAX_LINES)
	strong := text_styled(text, .Strong)
	measured_width := text_width(&strong, NOTICE_LOOKS[item.kind].label)
	for line in lines[:shown] {measured_width = max(measured_width, text_width(text, line))}
	content_width = min(content_width, measured_width)
	box_width := min(max_width, content_width + 2 * padding + leading + trailing)
	heading_height := max(strong.line_height, HEIGHT_COMPACT * scale)
	box_height := heading_height + SPACE_1 * scale + f32(shown) * text.line_height + 2 * padding
	box := render.Rect{width - NOTICE_MARGIN * scale - box_width, bottom - box_height, box_width, box_height}
	size := HEIGHT_COMPACT * scale
	close := render.Rect{box.x + box.width - padding - size, box.y + padding, size, size}
	return {box, close, content_width, heading_height, lines, shown}
}

notices_hit :: proc(
	n: ^Notices, text: ^Text, width, height, scale, x, y: f32,
) -> Notice_Hit {
	if text.fonts == nil || width <= 2 * NOTICE_MARGIN * scale {return {}}
	bottom := height - NOTICE_MARGIN * scale
	for i := len(n.items) - 1; i >= 0; i -= 1 {
		item := n.items[i]
		l := notice_layout(item, text, width, bottom, scale, &n.lines)
		rise := notice_fade_of(item, RISE_NOTICE * scale).rise
		box, close := l.box, l.close
		box.y += rise
		close.y += rise
		if render.rect_contains(box, x, y) {
			return {item.id, !notice_fading(item) && render.rect_contains(close, x, y), true}
		}
		bottom = l.box.y - SPACE_2 * scale
		if bottom < NOTICE_MARGIN * scale {break}
	}
	return {}
}

// Fades expired notices and reports whether any began to fade.
notices_expire :: proc(n: ^Notices, enabled: bool, now: time.Tick) -> bool {
	faded := false
	for i := len(notices_live(n)) - 1; i >= 0; i -= 1 {
		if expires, timed := notice_expiry(n.items[i]).?; timed && time.tick_diff(expires, now) >= 0 {
			notice_fade(n, i, enabled, now)
			faded = true
		}
	}
	return faded
}

notices_deadline :: proc(n: ^Notices) -> (time.Tick, bool) {
	deadline: time.Tick
	found := false
	for item in notices_live(n) {
		if expires, timed := notice_expiry(item).?; timed && (!found || time.tick_diff(expires, deadline) > 0) {
			deadline, found = expires, true
		}
	}
	return deadline, found
}

notices_draw :: proc(
	n: ^Notices,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	if len(n.items) == 0 || render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	margin, padding := NOTICE_MARGIN * scale, NOTICE_PADDING * scale
	max_width := min(NOTICE_WIDTH * scale, max(0, width - 2 * margin))
	if max_width <= 0 {return .Ok}
	bottom := height - margin
	hover, pressed := n.hover, armed_target(n.armed)
	for i := len(n.items) - 1; i >= 0; i -= 1 {
		item := n.items[i]
		mark := fade_mark(list)
		l := notice_layout(item, text, width, bottom, scale, &n.lines)
		box, content_width, shown := l.box, l.content_width, l.shown
		label, symbol, accent := notice_style(item.kind, theme)
		strong := text_styled(text, .Strong)
		frame := popover_panel(box, scale)
		if panel_draw(list, frame, theme) != .None {return .Ok}
		bar := render.Rect{box.x, box.y, 4 * scale, box.height}
		draw_rect(list, {rect = bar, color = accent, radius = pill_radius(bar)})
		icon := ICON_BUTTON * scale
		icon_y := box.y + padding + (l.heading_height - icon) / 2
		badge := render.Rect{bar.x + bar.width + padding, icon_y, icon, icon}
		icon_draw(list, symbol, badge, accent, ICON_BUTTON, scale)
		if icon_button_draw(
			list, theme, l.close, .Close, f32(int(hover == item.id)), f32(int(pressed == item.id)),
			scale, pointer, radius = RADIUS_CONTROL,
		) != .None {return .Ok}
		x := badge.x + icon + SPACE_2 * scale
		if result := draw_text(
			&strong,
			list,
			label,
			x,
			box.y + padding + (l.heading_height - strong.line_height) / 2 + strong.ascent,
			accent,
			content_width,
		); result != .Ok {return result}
		for line, index in l.lines[:shown] {
			top := box.y + padding + l.heading_height + SPACE_1 * scale
			baseline := top + f32(index) * text.line_height + text.ascent
			line_limit := index == shown - 1 && len(l.lines) > shown ? content_width : 0
			if result := draw_text(text, list, line, x, baseline, theme.text, line_limit);
			   result != .Ok {
				return result
			}
		}
		fade_draw(list, mark, notice_fade_of(item, RISE_NOTICE * scale))
		bottom = box.y - SPACE_2 * scale
		if bottom < margin {
			break
		}
	}
	return .Ok
}

// The one way a notice leaves. It moves behind the live notices and the pointer lets go of it, so
// a fading notice never shows a hovered or pressed close button; without animations the close
// settles at once and the notice is gone.
@(private)
notice_fade :: proc(n: ^Notices, index: int, enabled: bool, now: time.Tick) {
	item := n.items[index]
	if n.hover == item.id {n.hover = 0}
	if armed_is(n.armed, item.id) {armed_cancel(&n.armed)}
	entering, is_entering := item.state.(Notice_Entering)
	p := is_entering ? entering.presence : presence_shown(NOTICE_PRESENCE)
	presence_close(&p)
	item.state = Notice_Fading{p}
	_, settled := notice_advance(&item, enabled, now)
	copy(n.items[index:], n.items[index + 1:])
	if settled {
		delete(item.text, n.items.allocator)
		resize(&n.items, len(n.items) - 1)
	} else {
		n.items[len(n.items) - 1] = item
	}
}

notices_animating :: proc(n: ^Notices) -> bool {
	for item in n.items {
		switch state in item.state {
		case Notice_Entering, Notice_Fading: return true
		case Notice_Shown, Notice_Sticky:
		}
	}
	return false
}

// Advances every notice's motion. Disabled animations snap each to the end of its motion: an
// entering one is shown and a fading one is gone.
notices_animate :: proc(n: ^Notices, enabled: bool, now: time.Tick) -> bool {
	changed := false
	for i := len(n.items) - 1; i >= 0; i -= 1 {
		item_changed, settled := notice_advance(&n.items[i], enabled, now)
		changed = item_changed || changed
		if settled {
			delete(n.items[i].text, n.items.allocator)
			ordered_remove(&n.items, i)
		}
	}
	return changed
}

// Arrival, the end of entry and the end of a fade are the only lifetime transitions. Motion exists
// only during entry and fade, and only entry and timed display can carry a deadline.
@(private)
notice_advance :: proc(item: ^Notice, enabled: bool, now: time.Tick) -> (changed, settled: bool) {
	switch &state in item.state {
	case Notice_Entering:
		changed, _ = presence_advance(&state.presence, enabled, now)
		if !presence_active(state.presence) {
			expires := state.expires
			if deadline, timed := expires.?; timed {item.state = Notice_Shown{deadline}}
			else {item.state = Notice_Sticky{}}
		}
	case Notice_Fading:
		changed, settled = presence_advance(&state.presence, enabled, now)
	case Notice_Shown, Notice_Sticky:
	}
	return
}

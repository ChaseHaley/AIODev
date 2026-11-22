package ui

import "cosmos:render"
import "aio:settings"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

// Every card is this wide, so its text wraps the same whether the deck is open or closed.
@(private)
NOTICE_WIDTH :: 440
// Notices keep this far from the window's edges, as does Arrange mode's key card.
NOTICE_MARGIN :: 16
@(private)
NOTICE_PADDING :: 12
@(private)
NOTICE_MAX_LINES :: 4
// A notice fades and rises in, and fades out; Arrange mode's key card shows and leaves the same way.
NOTICE_PRESENCE :: Presence_Spec {
	open  = 160 * time.Millisecond,
	close = 120 * time.Millisecond,
}
// The tinted circle at a card's left that holds its severity symbol.
@(private)
NOTICE_CHIP :: 28
// Every card keeps room for the count of notices behind the front card, shown or not, so no text
// rewraps when the deck opens or a card comes to the front.
@(private)
NOTICE_BADGE :: 32
// The countdown line along a card's bottom edge.
@(private)
NOTICE_LINE :: 3
// A closed deck shows this much of each of the first NOTICE_PEEKS cards behind the front one, and each
// of them is narrower by NOTICE_PEEK_NARROW of the card's width per step.
@(private)
NOTICE_STEP :: 7
@(private)
NOTICE_PEEKS :: 2
@(private)
NOTICE_PEEK_NARROW :: f32(0.04)
// How strongly a card's severity colour tints its surface, its chip and its border.
@(private)
NOTICE_TINT_SURFACE :: f32(0.09)
@(private)
NOTICE_TINT_CHIP :: f32(0.18)
@(private)
NOTICE_TINT_BORDER :: f32(0.32)
// The deck opening or closing, and a card moving to another place in it.
@(private)
NOTICE_DECK_MOTION :: 180 * time.Millisecond
// A notice without a deadline sweeps a segment of its line along the bottom edge and spins its symbol.
@(private)
NOTICE_SWEEP :: 1200 * time.Millisecond
@(private)
NOTICE_SWEEP_SHARE :: f32(0.3)
@(private)
NOTICE_SWEEP_CURVE :: settings.Motion_Curve{p = {0.4, 0, 0.6, 1}}

Notice_Kind :: enum u8 {
	Info,
	Error,
	Warning,
	Success,
}

@(private, rodata)
NOTICE_SYMBOLS := [Notice_Kind]Icon {
	.Info    = .Info,
	.Error   = .Error,
	.Warning = .Warning,
	.Success = .Success,
}

// A notice's severity shows only as its symbol and colour; the colour also tints its card.
notice_style :: proc(kind: Notice_Kind, theme: Theme) -> (symbol: Icon, color: render.Color) {
	switch kind {
	case .Info: color = theme.info
	case .Warning: color = theme.warning
	case .Error: color = theme.error
	case .Success: color = theme.success
	}
	return NOTICE_SYMBOLS[kind], color
}

// The surface and border of a card in its severity colour `color`.
notice_surface :: proc(color: render.Color, theme: Theme) -> (fill, border: render.Color) {
	fill = theme.surface + (color - theme.surface) * NOTICE_TINT_SURFACE
	fill.a = theme.surface.a
	border = color
	border.a *= NOTICE_TINT_BORDER
	return
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

// Where a card draws and how much of it shows: `panel` the card itself, `content` what it holds, and
// `left` the share of its countdown still to run. A fading notice keeps the last one it was given, so
// it fades where it was while the deck closes the room it took.
Notice_Card :: struct {
	box:                  render.Rect,
	panel, content, left: f32,
}

// `action`, static text, labels a button that acts on the notice, such as Undo; empty for none.
// `action_key` names its keyboard chord beside it, also static.
Notice :: struct {
	id:                 u64,
	key:                u32,
	kind:               Notice_Kind,
	text:               string,
	action, action_key: string,
	state:              Notice_State,
	// The countdown's full length; zero for a sticky notice.
	duration:           time.Duration,
	// Places from the front of the deck, eased: the newest live notice is 0.
	depth:              Motion,
	// How far the card's bottom edge sits above the deck's bottom when open, in pixels, eased so the
	// cards above a leaving one slide down into its room. `slotted` is false until a placement measures
	// it while the deck is opening or open, which then starts it at its place.
	slot:               Motion,
	slotted:            bool,
	card:               Notice_Card,
}

// A notice's button: its close button, or its action button when `action`.
Notice_Button :: struct {
	id:     u64,
	action: bool,
}

// The notices show as a deck at the bottom right. Closed, only the newest is readable and the next
// cards step up behind it; with the pointer over the deck it opens to show every card, and every
// countdown stands still until the pointer leaves.
Notices :: struct {
	next_id:   u64,
	// The live notices in the order they arrived, then the fading ones in the order they began to
	// fade. notice_fade keeps that order.
	items:     [dynamic]Notice,
	// The button under the pointer and the one a press armed, in the window that holds the notices.
	// A fade drops either when it names the fading notice.
	hover:     Notice_Button,
	armed:     Armed(Notice_Button),
	// The pointer is over the deck, which pauses every countdown at `paused_at`.
	over:      bool,
	paused_at: time.Tick,
	// 0 closed, 1 open.
	open:      Motion,
	// The animation policy last given to any notice transition, which placement eases the slots by.
	animate:   bool,
	// When the front card's countdown line next loses a pixel; zero until a draw asks for one.
	line_next: time.Tick,
	// The last draw showed a notice without a deadline spinning and sweeping, which asks for frames as
	// the working status spinner does. It is not motion, so housekeeping does not wait for it.
	spinning:  bool,
	// Scratch storage for the lines notice_layout wraps; only the layout's returned slice is read.
	lines:     [dynamic]string,
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

// The instant the countdowns read: `now`, or the moment the pointer came over the deck.
notices_clock :: proc(n: ^Notices, now: time.Tick) -> time.Tick {
	return n.over ? n.paused_at : now
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

// Shows a notice. A nonzero key replaces the notice already shown under it, unless `stack`: then the
// key only names the notice's source and every different notice from it stays, while one that repeats
// a shown notice word for word replaces it, since it says nothing new. A zero duration is sticky.
// `enabled` is the caller's animation policy, as for every notice transition; `now` dates the expiry.
// A notice arriving while the deck is paused waits with the rest and runs its full time afterwards.
// A nonempty `action` adds a button whose release notices_release reports with the notice's key.
notices_put :: proc(
	n: ^Notices,
	key: u32,
	kind: Notice_Kind,
	text: string,
	duration: time.Duration,
	enabled: bool,
	now: time.Tick,
	action := "",
	action_key := "",
	stack := false,
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
	if key != 0 && !stack {
		notices_clear(n, key, enabled)
	} else if stack {
		for item, i in notices_live(n) {
			if item.key == key && item.kind == kind && item.text == text {notice_fade(n, i, enabled); break}
		}
	}
	n.next_id += 1
	notice := Notice {
		id         = n.next_id,
		key        = key,
		kind       = kind,
		text       = owned,
		action     = action,
		action_key = action_key,
		duration   = duration,
	}
	entering: Notice_Entering
	presence_open(&entering.presence, NOTICE_PRESENCE)
	if duration != 0 {entering.expires = time.tick_add(notices_clock(n, now), duration)}
	notice.state = entering
	// Without animations the notice shows at once, and a disabled motion never reads the frame;
	// otherwise its entry starts with the next frame.
	if !enabled {_, _ = notice_advance(&notice, false, {})}
	inject_at(&n.items, len(notices_live(n)), notice)
	n.animate = enabled
	notices_restack(n, enabled)
}

notices_clear :: proc(n: ^Notices, key: u32, enabled: bool) -> bool {
	for i := len(notices_live(n)) - 1; i >= 0; i -= 1 {
		if n.items[i].key == key {
			notice_fade(n, i, enabled)
			return true
		}
	}
	return false
}

notices_dismiss :: proc(n: ^Notices, id: u64, enabled: bool) -> bool {
	for item, i in notices_live(n) {
		if item.id == id {notice_fade(n, i, enabled); return true}
	}
	return false
}

// Whether a notice under `key` is still shown, so its action can still be taken.
notices_showing :: proc(n: ^Notices, key: u32) -> bool {
	for item in notices_live(n) {if item.key == key {return true}}
	return false
}

// Reports whether the hovered button changed, so the caller redraws only then.
notices_hover :: proc(n: ^Notices, button: Notice_Button) -> bool {
	if n.hover == button {return false}
	n.hover = button
	return true
}

// The pointer came over the deck or left it. Over it, the deck opens and every countdown stops;
// leaving closes the deck, and each notice resumes the time it had left. Reports whether either
// happened, so the caller redraws only then.
notices_pointer_over :: proc(n: ^Notices, over: bool, now: time.Tick, enabled: bool) -> bool {
	if over == n.over || (over && len(notices_live(n)) == 0) {return false}
	n.over, n.animate = over, enabled
	if over {
		n.paused_at = now
		n.line_next = {}
	} else {
		held := time.tick_diff(n.paused_at, now)
		for &item in notices_live(n) {
			switch &state in item.state {
			case Notice_Entering:
				if expires, timed := state.expires.?; timed {state.expires = time.tick_add(expires, held)}
			case Notice_Shown:
				state.expires = time.tick_add(state.expires, held)
			case Notice_Sticky, Notice_Fading:
			}
		}
	}
	motion_target(&n.open, over ? 1 : 0, NOTICE_DECK_MOTION, .Decelerate, enabled)
	return true
}

notices_press :: proc(n: ^Notices, button: Notice_Button) {
	armed_press(&n.armed, button)
}

// Fires the button both the press and this release landed on. Either button dismisses its notice;
// an action also returns the notice's key for the owner to act on.
notices_release :: proc(n: ^Notices, button: Notice_Button, enabled: bool) -> (dismissed: bool, acted: u32) {
	fired, ok := armed_release(&n.armed, button)
	if !ok || fired.id == 0 {return}
	if fired.action {
		for item in notices_live(n) {if item.id == fired.id {acted = item.key}}
	}
	return notices_dismiss(n, fired.id, enabled), acted
}

// The pointer left the notices' window or they moved to another: no hover, no press, and the deck
// closes and runs again.
notices_pointer_cancel :: proc(n: ^Notices, now: time.Tick, enabled: bool) {
	n.hover = {}
	armed_cancel(&n.armed)
	_ = notices_pointer_over(n, false, now, enabled)
}

// The notice under a point, and which of its buttons, if any. `contains` covers the whole deck,
// the gaps between open cards included, so moving between cards never closes it.
Notice_Hit :: struct {
	id:                       u64,
	close, action, contains: bool,
}

// The button a hit lands on, or none.
notice_hit_button :: proc(hit: Notice_Hit) -> Notice_Button {
	if !hit.close && !hit.action {return {}}
	return {hit.id, hit.action}
}

// `lines` are every wrapped line of the text; the first `shown` fit the card. The text wraps at the
// full card width whatever `box` is, so a card narrowed behind the front one keeps its lines.
@(private)
Notice_Layout :: struct {
	chip, close, badge, action:            render.Rect,
	text_x, text_top, content_width, height: f32,
	lines:                                   []string,
	shown:                                   int,
}

// Lays out the item's card at `box`, wrapping its text into `scratch`; the returned layout's lines
// stay valid until the next wrap. `height` is the card's own height, whatever `box.height` is.
@(private)
notice_layout :: proc(
	item: Notice, text: ^Text, box: render.Rect, card_width, scale: f32, scratch: ^[dynamic]string,
) -> Notice_Layout {
	padding := NOTICE_PADDING * scale
	chip := NOTICE_CHIP * scale
	control := HEIGHT_COMPACT * scale
	gap := SPACE_2 * scale
	badge := NOTICE_BADGE * scale
	leading := padding + chip + SPACE_3 * scale
	trailing := gap + control + gap + badge + gap
	action_width: f32
	if item.action != "" {
		strong := text_styled(text, .Strong)
		action_width = text_width(&strong, item.action) + 2 * CONTROL_INSET * scale
		trailing += action_width + gap
		if item.action_key != "" {
			small := text_styled(text, .Detail)
			trailing += text_width(&small, item.action_key) + gap
		}
	}
	content_width := max(scale, card_width - leading - trailing)
	wrap(text, item.text, content_width, scratch)
	lines := scratch[:]
	shown := min(len(lines), NOTICE_MAX_LINES)
	// The first line sits level with the chip; more run down from it.
	inset := (chip - text.line_height) / 2
	top := box.y + padding
	right := box.x + box.width - gap
	close := render.Rect{right - control, top + (chip - control) / 2, control, control}
	slot := render.Rect{close.x - gap - badge, close.y, badge, control}
	action: render.Rect
	if action_width > 0 {action = {slot.x - gap - action_width, close.y, action_width, control}}
	return {
		chip = {box.x + padding, top, chip, chip},
		close = close,
		badge = slot,
		action = action,
		text_x = box.x + leading,
		text_top = top + inset,
		content_width = content_width,
		height = 2 * padding + max(chip, inset + f32(shown) * text.line_height),
		lines = lines,
		shown = shown,
	}
}

// The width of every card in a `width` wide window; zero when none fits.
@(private)
notice_card_width :: proc(width, scale: f32) -> f32 {
	return max(0, min(NOTICE_WIDTH * scale, width - 2 * NOTICE_MARGIN * scale))
}

// Places every live card for a `width` by `height` window. Closed, the front card sits at the bottom
// right and the next NOTICE_PEEKS cards step up behind it at its height; open, every card has its own
// height, newest at the bottom. The open motion blends the two, and each card's eased depth and slot
// move it between places. Returns the column the visible cards cover.
@(private)
notices_place :: proc(n: ^Notices, text: ^Text, width, height, scale: f32) -> (column: render.Rect) {
	live := notices_live(n)
	card_width := notice_card_width(width, scale)
	if len(live) == 0 || text.fonts == nil || card_width <= 0 {return}
	margin := NOTICE_MARGIN * scale
	right, bottom := width - margin, height - margin
	t := n.open.value
	// Shut and settled, nothing shows an open place, so the cards behind the front are not measured
	// and their slots start afresh the next time the deck opens.
	opening := t > 0 || n.open.target > 0
	measure := render.Rect{width = card_width}
	front := notice_layout(live[len(live) - 1], text, measure, card_width, scale, &n.lines).height
	open_bottom, top := f32(0), bottom
	for i := len(live) - 1; i >= 0; i -= 1 {
		item := &live[i]
		depth := max(item.depth.value, 0)
		own := front
		if i < len(live) - 1 && (opening || depth < 1) {
			own = notice_layout(item^, text, measure, card_width, scale, &n.lines).height
		}
		if !opening {
			item.slotted = false
		} else if !item.slotted {
			item.slot, item.slotted = {value = open_bottom, target = open_bottom}, true
		} else {
			motion_target(&item.slot, open_bottom, NOTICE_DECK_MOTION, .Decelerate, n.animate)
		}
		step := min(depth, NOTICE_PEEKS)
		// A card stepping back from the front shrinks to the front card's height as it goes.
		closed_height := math.lerp(own, front, min(depth, 1))
		closed_top := bottom - step * NOTICE_STEP * scale - closed_height
		card_top := math.lerp(closed_top, bottom - item.slot.value - own, t)
		card := card_width * (1 - math.lerp(step * NOTICE_PEEK_NARROW, 0, t))
		item.card.box = {
			right - card_width + (card_width - card) / 2, card_top, card, math.lerp(closed_height, own, t),
		}
		item.card.panel = math.lerp(clamp(NOTICE_PEEKS + 1 - depth, 0, 1), 1, t)
		item.card.content = math.lerp(clamp(1 - depth, 0, 1), 1, t)
		open_bottom += own + SPACE_2 * scale
		if item.card.panel > 0 {top = min(top, card_top)}
	}
	return {right - card_width, top, card_width, bottom - top}
}

notices_hit :: proc(
	n: ^Notices, text: ^Text, width, height, scale, x, y: f32,
) -> Notice_Hit {
	column := notices_place(n, text, width, height, scale)
	card_width := notice_card_width(width, scale)
	if text.fonts == nil || card_width <= 0 {return {}}
	live := notices_live(n)
	// Topmost first: fading cards that were in front, the deck from its front card, then the rest.
	for item in n.items[len(live):] {
		if item.card.content >= 1 && notice_card_contains(item, x, y, scale) {
			return {id = item.id, contains = true}
		}
	}
	for i := len(live) - 1; i >= 0; i -= 1 {
		item := live[i]
		if !notice_card_contains(item, x, y, scale) {continue}
		hit := Notice_Hit{id = item.id, contains = true}
		// A card that is mostly hidden behind the front one takes no button press.
		if item.card.content >= 0.5 {
			l := notice_layout(item, text, item.card.box, card_width, scale, &n.lines)
			hit.close = render.rect_contains(l.close, x, y)
			hit.action = render.rect_contains(l.action, x, y)
		}
		return hit
	}
	for item in n.items[len(live):] {
		if notice_card_contains(item, x, y, scale) {return {id = item.id, contains = true}}
	}
	if column.width > 0 && render.rect_contains(column, x, y) {return {contains = true}}
	return {}
}

@(private)
notice_card_contains :: proc(item: Notice, x, y, scale: f32) -> bool {
	if item.card.panel <= 0 {return false}
	box := item.card.box
	box.y += notice_fade_of(item, RISE_NOTICE * scale).rise
	return render.rect_contains(box, x, y)
}

// Where notice `id` draws its action button, or nothing when it has none or is not shown.
notices_action_rect :: proc(n: ^Notices, text: ^Text, width, height, scale: f32, id: u64) -> render.Rect {
	_ = notices_place(n, text, width, height, scale)
	card_width := notice_card_width(width, scale)
	if text.fonts == nil || card_width <= 0 {return {}}
	for item in notices_live(n) {
		if item.id != id || item.card.content <= 0 {continue}
		action := notice_layout(item, text, item.card.box, card_width, scale, &n.lines).action
		if action.width > 0 {action.y += notice_fade_of(item, RISE_NOTICE * scale).rise}
		return action
	}
	return {}
}

// Fades expired notices and reports whether any began to fade. Nothing expires while paused.
notices_expire :: proc(n: ^Notices, enabled: bool, now: time.Tick) -> bool {
	if n.over {return false}
	faded := false
	for i := len(notices_live(n)) - 1; i >= 0; i -= 1 {
		if expires, timed := notice_expiry(n.items[i]).?; timed && time.tick_diff(expires, now) >= 0 {
			notice_fade(n, i, enabled)
			faded = true
		}
	}
	return faded
}

// Whether the front card's countdown line is due to shrink by a pixel; true once per draw that asked.
notices_line_due :: proc(n: ^Notices, now: time.Tick) -> bool {
	if n.line_next == {} || time.tick_diff(n.line_next, now) < 0 {return false}
	n.line_next = {}
	return true
}

// The next expiry or countdown line step; none while paused.
notices_deadline :: proc(n: ^Notices) -> (time.Tick, bool) {
	deadline, found := n.line_next, n.line_next != {}
	if n.over {return deadline, found}
	for item in notices_live(n) {
		if expires, timed := notice_expiry(item).?; timed && (!found || time.tick_diff(expires, deadline) > 0) {
			deadline, found = expires, true
		}
	}
	return deadline, found
}

// Draws the deck for a `width` by `height` window at `now`, the instant its countdowns read and the
// sweep of a notice without a deadline is drawn for. `spin` is the caller's animation policy: without
// it, that notice's spinner and line hold still.
notices_draw :: proc(
	n: ^Notices,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
	now: time.Tick,
	spin: bool,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	n.line_next, n.spinning = {}, false
	if len(n.items) == 0 {return .Ok}
	_ = notices_place(n, text, width, height, scale)
	card_width := notice_card_width(width, scale)
	if text.fonts == nil || card_width <= 0 {return .Ok}
	live := notices_live(n)
	clock := notices_clock(n, now)
	for &item in live {item.card.left = notice_time_left(item, clock)}
	bounds := render.Rect{0, 0, width, height}
	deck := Notice_Draw{n, list, text, theme, bounds, card_width, scale, now, spin, pointer, len(live)}
	// Back to front: fading cards that had stepped back, the deck from its deepest card, then fading
	// cards that were in front.
	for item in n.items[len(live):] {
		if item.card.content >= 1 {continue}
		if result := notice_card_draw(&deck, item, false); result != .Ok {return result}
	}
	for item, i in live {
		front := i == len(live) - 1
		if result := notice_card_draw(&deck, item, front); result != .Ok {return result}
		if front && !n.over && item.duration > 0 {notice_line_schedule(n, item, now)}
	}
	for item in n.items[len(live):] {
		if item.card.content < 1 {continue}
		if result := notice_card_draw(&deck, item, false); result != .Ok {return result}
	}
	return .Ok
}

@(private)
Notice_Draw :: struct {
	n:          ^Notices,
	list:       ^render.Draw_List,
	text:       ^Text,
	theme:      Theme,
	bounds:     render.Rect,
	card_width: f32,
	scale:      f32,
	now:        time.Tick,
	spin:       bool,
	pointer:    [2]f32,
	count:      int,
}

// The share of a timed notice's countdown still to run at `clock`; 1 for a sticky one.
@(private)
notice_time_left :: proc(item: Notice, clock: time.Tick) -> f32 {
	expires, timed := notice_expiry(item).?
	if !timed || item.duration <= 0 {return 1}
	return clamp(f32(time.tick_diff(clock, expires)) / f32(item.duration), 0, 1)
}

// Asks to draw again when the front card's line next loses a whole pixel, rather than every frame.
@(private)
notice_line_schedule :: proc(n: ^Notices, item: Notice, now: time.Tick) {
	full := item.card.box.width
	pixels := full * item.card.left
	next := math.ceil(pixels) - 1
	if full <= 0 || next < 0 {return}
	wait := time.Duration(f64(pixels - next) / f64(full) * f64(item.duration))
	n.line_next = time.tick_add(now, max(wait, time.Millisecond))
}

@(private)
notice_card_draw :: proc(d: ^Notice_Draw, item: Notice, front: bool) -> render.Build_Status {
	card := item.card
	if card.panel <= 0 || card.box.width <= 0 {return .Ok}
	list, scale := d.list, d.scale
	box := card.box
	symbol, color := notice_style(item.kind, d.theme)
	mark := render.draw_mark(list)
	if render.push_layer(list, d.bounds) != .None {return .Ok}
	// The popover frame, drawn in the card's tinted colours.
	tinted := d.theme
	tinted.surface, tinted.border = notice_surface(color, d.theme)
	if panel_draw(list, popover_panel(box, scale), tinted) != .None {return .Ok}
	// Content is clipped to the rounded card, so the countdown line follows its bottom corners.
	if render.push_layer(list, box, RADIUS_OVERLAY * scale) != .None {return .Ok}
	if card.content > 0 {
		content := render.draw_mark(list)
		if result := notice_content_draw(d, item, color, symbol, front); result != .Ok {return result}
		fade_draw(list, content, {opacity = card.content})
	}
	fade := notice_fade_of(item, RISE_NOTICE * scale)
	fade.opacity *= card.panel
	fade_draw(list, mark, fade)
	return .Ok
}

@(private)
notice_content_draw :: proc(
	d: ^Notice_Draw, item: Notice, color: render.Color, symbol: Icon, front: bool,
) -> render.Build_Status {
	n, list, text, theme, scale := d.n, d.list, d.text, d.theme, d.scale
	box := item.card.box
	l := notice_layout(item, text, box, d.card_width, scale, &n.lines)
	chip_fill := color
	chip_fill.a *= NOTICE_TINT_CHIP
	draw_rect(list, {rect = l.chip, color = chip_fill, radius = pill_radius(l.chip)})
	icon := ICON_BUTTON * scale
	mark := render.Rect{l.chip.x + (l.chip.width - icon) / 2, l.chip.y + (l.chip.height - icon) / 2, icon, icon}
	if item.duration == 0 {
		n.spinning ||= d.spin
		status_spinner_draw(list, mark, color, d.spin ? notice_phase(d.now, STATUS_SPIN_PERIOD) : STATUS_SPIN_STILL)
	} else {
		icon_draw(list, symbol, mark, color, ICON_BUTTON, scale)
	}
	for line, index in l.lines[:l.shown] {
		baseline := l.text_top + f32(index) * text.line_height + text.ascent
		limit := index == l.shown - 1 && len(l.lines) > l.shown ? l.content_width : 0
		if result := draw_text(text, list, line, l.text_x, baseline, theme.text, limit); result != .Ok {
			return result
		}
	}
	if l.action.width > 0 {
		button := Notice_Button{item.id, true}
		hover, press := f32(int(n.hover == button)), f32(int(armed_target(n.armed) == button))
		if result := filled_button_draw(
			list, text, theme, l.action, item.action, color, theme.surface, hover, press, false, scale, d.pointer,
		); result != .Ok {return result}
		if item.action_key != "" {
			small := text_styled(text, .Detail)
			key_x := l.action.x - SPACE_2 * scale - text_width(&small, item.action_key)
			baseline := l.action.y + (l.action.height - small.line_height) / 2 + small.ascent
			if result := draw_text(&small, list, item.action_key, key_x, baseline, theme.faint); result != .Ok {
				return result
			}
		}
	}
	if front && d.count > 1 {
		if result := notice_badge_draw(d, l.badge, d.count - 1, 1 - n.open.value); result != .Ok {return result}
	}
	closing := Notice_Button{item.id, false}
	close_hover, close_press := f32(int(n.hover == closing)), f32(int(armed_target(n.armed) == closing))
	if icon_button_draw(list, theme, l.close, .Close, close_hover, close_press, scale, d.pointer,
	                    radius = RADIUS_CONTROL) != .None {return .Ok}
	notice_line_draw(list, item, box, color, d.spin ? notice_phase(d.now, NOTICE_SWEEP) : 0.5, scale)
	return .Ok
}

// "+N" for the notices behind the front card, which shows only while the deck is closed.
@(private)
notice_badge_draw :: proc(
	d: ^Notice_Draw, slot: render.Rect, behind: int, opacity: f32,
) -> render.Build_Status {
	if opacity <= 0 {return .Ok}
	small := text_styled(d.text, .Detail)
	pill_height := min(slot.height, small.line_height + SPACE_1 * d.scale)
	pill := render.Rect{slot.x, slot.y + (slot.height - pill_height) / 2, slot.width, pill_height}
	fill := d.theme.pressed
	fill.a *= opacity
	draw_rect(d.list, {rect = pill, color = fill, radius = pill_radius(pill)})
	buffer: [24]u8
	buffer[0] = '+'
	digits := strconv.write_int(buffer[1:], i64(behind), 10)
	label := string(buffer[:1 + len(digits)])
	ink := d.theme.muted
	ink.a *= opacity
	x := pill.x + (pill.width - text_width(&small, label)) / 2
	baseline := pill.y + (pill.height - small.line_height) / 2 + small.ascent
	return draw_text(&small, d.list, label, x, baseline, ink, pill.width)
}

// The countdown along the card's bottom edge, shrinking toward the left; a sweeping segment when the
// notice has no deadline, at `phase` of its sweep.
@(private)
notice_line_draw :: proc(
	list: ^render.Draw_List, item: Notice, box: render.Rect, color: render.Color, phase, scale: f32,
) {
	thickness := NOTICE_LINE * scale
	y := box.y + box.height - thickness
	if item.duration == 0 {
		segment := box.width * NOTICE_SWEEP_SHARE
		eased := settings.motion_curve_ease(NOTICE_SWEEP_CURVE, phase)
		start := box.x - segment + (box.width + segment) * eased
		left, right := max(start, box.x), min(start + segment, box.x + box.width)
		if right > left {draw_rect(list, {rect = {left, y, right - left, thickness}, color = color})}
		return
	}
	if item.card.left <= 0 {return}
	draw_rect(list, {rect = {box.x, y, box.width * item.card.left, thickness}, color = color})
}

// Where `now` falls in a repeating `period`, from 0 up to 1.
@(private)
notice_phase :: proc(now: time.Tick, period: time.Duration) -> f32 {
	return f32(time.tick_diff({}, now) % period) / f32(period)
}

// The one way a notice leaves. It moves behind the live notices and the pointer lets go of it, so
// a fading notice never shows a hovered or pressed close button; without animations the close
// settles at once and the notice is gone. It keeps its last card and takes no room, so the cards
// behind it move up into its place. The last live notice leaving closes the deck and ends any pause.
@(private)
notice_fade :: proc(n: ^Notices, index: int, enabled: bool) {
	item := n.items[index]
	n.animate = enabled
	if n.hover.id == item.id {n.hover = {}}
	if armed_target(n.armed).id == item.id {armed_cancel(&n.armed)}
	entering, is_entering := item.state.(Notice_Entering)
	p := is_entering ? entering.presence : presence_shown(NOTICE_PRESENCE)
	presence_close(&p)
	item.state = Notice_Fading{p}
	// A disabled close, or one with nothing left to fade, settles without reading the frame; any
	// other fade starts with the next frame.
	settled := false
	if !enabled || p.phase == .Release_Due {_, settled = notice_advance(&item, enabled, {})}
	copy(n.items[index:], n.items[index + 1:])
	if settled {
		delete(item.text, n.items.allocator)
		resize(&n.items, len(n.items) - 1)
	} else {
		n.items[len(n.items) - 1] = item
	}
	if len(notices_live(n)) == 0 {
		n.over, n.open, n.line_next = false, {}, {}
	}
	notices_restack(n, enabled)
}

// Eases every live notice toward its place from the front of the deck.
@(private)
notices_restack :: proc(n: ^Notices, enabled: bool) {
	live := notices_live(n)
	for &item, i in live {
		motion_target(&item.depth, f32(len(live) - 1 - i), NOTICE_DECK_MOTION, .Decelerate, enabled)
	}
}

notices_animating :: proc(n: ^Notices) -> bool {
	if motion_active(n.open) {return true}
	for item in n.items {
		switch state in item.state {
		case Notice_Entering, Notice_Fading: return true
		case Notice_Shown, Notice_Sticky:
		}
		if motion_active(item.depth) || motion_active(item.slot) {return true}
	}
	return false
}

// Advances every notice's motion and the deck's. Disabled animations snap each to the end of its
// motion: an entering notice is shown, a fading one is gone and the deck lands open or closed.
notices_animate :: proc(n: ^Notices, enabled: bool, frame: Frame_Time) -> bool {
	n.animate = enabled
	changed := notice_motion_advance(&n.open, enabled, frame)
	for i := len(n.items) - 1; i >= 0; i -= 1 {
		changed = notice_motion_advance(&n.items[i].depth, enabled, frame) || changed
		changed = notice_motion_advance(&n.items[i].slot, enabled, frame) || changed
		item_changed, settled := notice_advance(&n.items[i], enabled, frame)
		changed = item_changed || changed
		if settled {
			delete(n.items[i].text, n.items.allocator)
			ordered_remove(&n.items, i)
		}
	}
	return changed
}

@(private)
notice_motion_advance :: proc(m: ^Motion, enabled: bool, frame: Frame_Time) -> bool {
	if enabled {return motion_update(m, frame)}
	if !motion_active(m^) {return false}
	m.value = m.target
	return true
}

// Arrival, the end of entry and the end of a fade are the only lifetime transitions. Motion exists
// only during entry and fade, and only entry and timed display can carry a deadline.
@(private)
notice_advance :: proc(item: ^Notice, enabled: bool, frame: Frame_Time) -> (changed, settled: bool) {
	switch &state in item.state {
	case Notice_Entering:
		changed, _ = presence_advance(&state.presence, enabled, frame)
		if !presence_active(state.presence) {
			expires := state.expires
			if deadline, timed := expires.?; timed {item.state = Notice_Shown{deadline}}
			else {item.state = Notice_Sticky{}}
		}
	case Notice_Fading:
		changed, settled = presence_advance(&state.presence, enabled, frame)
	case Notice_Shown, Notice_Sticky:
	}
	return
}

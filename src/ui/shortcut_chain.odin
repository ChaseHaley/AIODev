package ui

import "aio:commands"
import "aio:input"
import "aio:render"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"

// A command a conflict check reads: its settings key, title and shortcuts. A surface lists the
// commands it edits for one check; the list borrows their strings and slices.
Shortcut_Command :: struct {
	key, title: string,
	shortcuts:  []commands.Shortcut,
}

// Whether `shortcuts` bind `chord`, by the rule the settings check refuses duplicates with.
shortcuts_hold :: proc(shortcuts: []commands.Shortcut, chord: commands.Shortcut) -> bool {
	for shortcut in shortcuts {if commands.shortcut_equal(shortcut, chord) {return true}}
	return false
}

// The commands a clash ties together, edited as one draft until no chord in it is held twice. The
// first member is the command whose shortcut was applied; each command a later apply takes a chord
// from is appended. Clashes are counted against the drafts, so a swap resolves itself. Everything is
// owned; `members` is empty while no chain is open.
Shortcut_Chain :: struct {
	// Every command a chord can belong to, as the surface listed them when the chain opened. A
	// member's shortcuts are its draft's.
	entries:   [dynamic]Chain_Entry,
	members:   [dynamic]Chain_Member,
	selected:  int,
	// The member whose chip `capture` records into `draft`, or -1.
	recording: int,
	capture:   Shortcut_Capture,
	draft:     Text_Field,
	// The member the last apply appended, for the surface to bring into view, or -1.
	appended:  int,
	// What the chain shows, rebuilt after every change: each member's chips in member order, the
	// chords held more than once, and the line above the rows.
	chips:     [dynamic]Chain_Chip,
	contested: [dynamic]commands.Shortcut,
	summary:   strings.Builder,
	// The part under the pointer, which draws its hover.
	hover:     Chain_Hit,
}

Chain_Entry :: struct {
	key, title: string,
	shortcuts:  []commands.Shortcut,
}

// `saved` and `draft` are shortcut text in canonical labels; `first` and `count` are its chips.
Chain_Member :: struct {
	entry:        int,
	saved, draft: string,
	first, count: int,
}

// One shortcut a chain row shows. `label` borrows a draft or a static placeholder until the next
// change; `index` is the alternative it is, or the one a recording replaces.
Chain_Chip :: struct {
	label:                         string,
	index:                         int,
	contested, pending, recording: bool,
}

// What a key or press did to the chain. Resolved: no chord is held twice any more, so the owner
// saves every change at once. Cancelled: the owner drops the chain and every change in it.
Chain_Outcome :: enum u8 {
	None,
	Changed,
	Resolved,
	Cancelled,
}

Chain_Part :: enum u8 {
	None,
	Row,
	Chip,
	Remove,
	Add,
	// The surface's Cancel · Esc button.
	Cancel,
}

// A part of a member's row: `chip` is the alternative for Chip and Remove.
Chain_Hit :: struct {
	member, chip: int,
	part:         Chain_Part,
}

// A changed member's settings key and draft, borrowed from the chain.
Shortcut_Change :: struct {
	key, value: string,
}

CHAIN_CANCEL_LABEL :: "Cancel · Esc"
@(private)
CHAIN_REMOVE_SIZE :: f32(16)
@(private)
CHAIN_DASH :: f32(3)
@(private)
CHAIN_DASH_GAP :: f32(2)

shortcut_chain_active :: proc(chain: ^Shortcut_Chain) -> bool {return len(chain.members) > 0}

shortcut_chain_recording :: proc(chain: ^Shortcut_Chain) -> bool {
	return shortcut_chain_active(chain) && chain.recording >= 0
}

// The settings key of member `member`.
shortcut_chain_member_key :: proc(chain: ^Shortcut_Chain, member: int) -> string {
	return chain.entries[chain.members[member].entry].key
}

shortcut_chain_member_title :: proc(chain: ^Shortcut_Chain, member: int) -> string {
	return chain.entries[chain.members[member].entry].title
}

// The line above the rows, such as "Ctrl+Shift+P is used twice. Change one to save."
shortcut_chain_context :: proc(chain: ^Shortcut_Chain) -> string {
	return strings.to_string(chain.summary)
}

// "Used by" and the other commands holding the chord being recorded, or empty.
shortcut_chain_used_by :: proc(chain: ^Shortcut_Chain) -> string {
	if chain.recording < 0 {return ""}
	return shortcut_capture_used_by(&chain.capture)
}

shortcut_chain_destroy :: proc(chain: ^Shortcut_Chain) {
	for entry in chain.entries {
		delete(entry.key)
		delete(entry.title)
		delete(entry.shortcuts)
	}
	delete(chain.entries)
	for member in chain.members {
		delete(member.saved)
		delete(member.draft)
	}
	delete(chain.members)
	delete(chain.draft.bytes)
	delete(chain.chips)
	delete(chain.contested)
	strings.builder_destroy(&chain.summary)
	chain^ = {}
}

// Opens a chain on the command with settings key `edited` in `book` and applies `draft` to it as
// Enter applied it, with the chord `capture` recorded. The capture's leader and key-position choice
// carry over to recordings in the chain. On failure the caller destroys the partial chain.
@(require_results)
shortcut_chain_open :: proc(
	chain: ^Shortcut_Chain,
	book: []Shortcut_Command,
	edited, draft: string,
	capture: ^Shortcut_Capture,
) -> runtime.Allocator_Error {
	shortcut_chain_destroy(chain)
	reserve(&chain.entries, len(book)) or_return
	first := -1
	for command, i in book {
		append(&chain.entries, Chain_Entry{})
		entry := &chain.entries[i]
		entry.key = strings.clone(command.key) or_return
		entry.title = strings.clone(command.title) or_return
		entry.shortcuts = slice.clone(command.shortcuts) or_return
		if command.key == edited {first = i}
	}
	if first < 0 {return nil}
	chain.summary = strings.builder_make() or_return
	chain.capture.leader, chain.capture.physical = capture.leader, capture.physical
	chain.recording, chain.appended = -1, -1
	chain_member_add(chain, first) or_return
	return chain_apply(chain, 0, draft, capture.chord)
}

// The changes a resolved chain saves: every member whose draft differs from its saved shortcuts.
shortcut_chain_changes :: proc(chain: ^Shortcut_Chain) -> []Shortcut_Change {
	changes := make([dynamic]Shortcut_Change, 0, len(chain.members), context.temp_allocator)
	for member in chain.members {
		if member.draft == member.saved {continue}
		append(&changes, Shortcut_Change{chain.entries[member.entry].key, member.draft})
	}
	return changes[:]
}

@(private, require_results)
chain_member_add :: proc(chain: ^Shortcut_Chain, entry: int) -> runtime.Allocator_Error {
	shortcuts := chain.entries[entry].shortcuts
	saved := commands.shortcut_set_text({shortcuts, len(shortcuts)})
	draft, clone_error := strings.clone(saved)
	if clone_error != nil {
		delete(saved)
		return clone_error
	}
	if _, err := append(&chain.members, Chain_Member{entry = entry, saved = saved, draft = draft}); err != nil {
		delete(saved)
		delete(draft)
		return err
	}
	return nil
}

@(private)
chain_member_of :: proc(chain: ^Shortcut_Chain, entry: int) -> int {
	for member, i in chain.members {if member.entry == entry {return i}}
	return -1
}

// How many commands hold `chord`, counting each member by its draft.
@(private)
chain_holders :: proc(chain: ^Shortcut_Chain, chord: commands.Shortcut) -> int {
	count := 0
	for entry in chain.entries {if shortcuts_hold(entry.shortcuts, chord) {count += 1}}
	return count
}

@(private)
chain_parse :: proc(text: string) -> []commands.Shortcut {
	storage := make([]commands.Shortcut, len(text) + 1, context.temp_allocator)
	count, err := commands.parse_shortcuts(text, storage)
	return err == .None ? storage[:count] : nil
}

// Makes `text` member `member`'s draft. A chord another command outside the chain holds brings that
// command in; a chord a member holds only marks the clash.
@(private, require_results)
chain_apply :: proc(
	chain: ^Shortcut_Chain,
	member: int,
	text: string,
	chord: Maybe(commands.Shortcut),
) -> runtime.Allocator_Error {
	parsed := chain_parse(text)
	shortcuts := slice.clone(parsed) or_return
	draft := commands.shortcut_set_text({shortcuts, len(shortcuts)})
	entry := &chain.entries[chain.members[member].entry]
	delete(entry.shortcuts)
	entry.shortcuts = shortcuts
	delete(chain.members[member].draft)
	chain.members[member].draft = draft
	chain.appended = -1
	if chord, recorded := chord.?; recorded {
		for other, i in chain.entries {
			if chain_member_of(chain, i) >= 0 || !shortcuts_hold(other.shortcuts, chord) {continue}
			chain_member_add(chain, i) or_return
			chain.appended = len(chain.members) - 1
		}
	}
	chain_refresh(chain)
	return nil
}

// Records alternative `index` of member `member` again; an index past its shortcuts adds one.
shortcut_chain_record :: proc(chain: ^Shortcut_Chain, member, index: int) {
	chain_stop(chain)
	if field_set(&chain.draft, chain.members[member].draft) != nil {return}
	chain.recording, chain.selected = member, member
	shortcut_capture_start(&chain.capture, index)
	chain_refresh(chain)
}

@(private)
chain_stop :: proc(chain: ^Shortcut_Chain) {
	if chain.recording < 0 {return}
	chain.recording = -1
	chain.capture.state = .Idle
	chain.capture.chord, chain.capture.used_by_len = nil, 0
	chain_refresh(chain)
}

// Applies what the capture recorded to its member.
@(private)
chain_commit :: proc(chain: ^Shortcut_Chain) -> Chain_Outcome {
	member := chain.recording
	text := strings.clone(field_string(&chain.draft), context.temp_allocator)
	chord := chain.capture.chord
	chain_stop(chain)
	chain.selected = member
	if err := chain_apply(chain, member, text, chord); err != nil {
		log.errorf("conflict chain: could not apply a shortcut: %v", err)
		return .Changed
	}
	return len(chain.contested) == 0 ? .Resolved : .Changed
}

// Removes alternative `index` from member `member`'s draft.
@(private)
chain_remove :: proc(chain: ^Shortcut_Chain, member, index: int) -> Chain_Outcome {
	chain_stop(chain)
	chain.selected = member
	parts := commands.shortcut_alternatives(chain.members[member].draft, context.temp_allocator)
	if index < 0 || index >= len(parts) {return .Changed}
	kept := make([dynamic]string, 0, len(parts), context.temp_allocator)
	for part, i in parts {if i != index {append(&kept, part)}}
	text := commands.shortcut_alternatives_text(kept[:], context.temp_allocator)
	if err := chain_apply(chain, member, text, nil); err != nil {
		log.errorf("conflict chain: could not remove a shortcut: %v", err)
		return .Changed
	}
	return len(chain.contested) == 0 ? .Resolved : .Changed
}

// The first contested alternative of member `member`, or -1.
@(private)
chain_contested_chip :: proc(chain: ^Shortcut_Chain, member: int) -> int {
	m := chain.members[member]
	for chip in chain.chips[m.first:][:m.count] {if chip.contested {return chip.index}}
	return -1
}

// Recounts the clashes and rebuilds the line above the rows, the chips and the "Used by" line.
@(private)
chain_refresh :: proc(chain: ^Shortcut_Chain) {
	clear(&chain.contested)
	for member in chain.members {
		for chord in chain.entries[member.entry].shortcuts {
			if chain_holders(chain, chord) > 1 && !shortcuts_hold(chain.contested[:], chord) {
				append(&chain.contested, chord)
			}
		}
	}
	strings.builder_reset(&chain.summary)
	if len(chain.contested) > 1 {
		fmt.sbprintf(&chain.summary, "%d shortcuts clash. Change one of each to save.", len(chain.contested))
	} else if len(chain.contested) == 1 {
		buffer: [commands.SHORTCUT_TEXT_CAP]u8
		label := commands.shortcut_text(chain.contested[0], buffer[:])
		if holders := chain_holders(chain, chain.contested[0]); holders == 2 {
			fmt.sbprintf(&chain.summary, "%s is used twice. Change one to save.", label)
		} else {
			fmt.sbprintf(&chain.summary, "%s is used %d times. Keep one to save.", label, holders)
		}
	}
	if chain.recording >= 0 {
		book := make([]Shortcut_Command, len(chain.entries), context.temp_allocator)
		for entry, i in chain.entries {book[i] = {entry.key, entry.title, entry.shortcuts}}
		shortcut_capture_check(&chain.capture, book, shortcut_chain_member_key(chain, chain.recording))
	}
	clear(&chain.chips)
	for &member, i in chain.members {
		member.first = len(chain.chips)
		saved := chain_parse(member.saved)
		if i != chain.recording {
			chain_text_chips(chain, member.draft, saved)
		} else if _, recorded := chain.capture.chord.?; recorded {
			chain_text_chips(chain, field_string(&chain.draft), saved)
			chain_mark_recording(chain, member.first, member.draft, "")
		} else {
			chain_text_chips(chain, member.draft, saved)
			placeholder := chain.capture.state == .Leader_Pending ? "Leader+…" : "Press keys…"
			chain_mark_recording(chain, member.first, member.draft, placeholder)
		}
		member.count = len(chain.chips) - member.first
	}
}

@(private)
chain_text_chips :: proc(chain: ^Shortcut_Chain, text: string, saved: []commands.Shortcut) {
	cursor := commands.shortcut_alternatives_begin(text)
	index := 0
	for label, ok := commands.shortcut_alternatives_next(&cursor); ok;
	    label, ok = commands.shortcut_alternatives_next(&cursor) {
		if label == "" {continue}
		chip := Chain_Chip{label = label, index = index}
		if chord, parsed := commands.parse_shortcut(label); parsed {
			chip.contested = shortcuts_hold(chain.contested[:], chord)
			chip.pending = !shortcuts_hold(saved, chord)
		}
		append(&chain.chips, chip)
		index += 1
	}
}

// Marks the chip a recording writes: the alternative it replaces, or a new one after the others. A
// recorded chord is contested when another command holds it; without one the chip shows
// `placeholder`.
@(private)
chain_mark_recording :: proc(chain: ^Shortcut_Chain, first: int, base, placeholder: string) {
	count := len(commands.shortcut_alternatives(base, context.temp_allocator))
	slot := min(chain.capture.replace, count)
	if placeholder != "" {
		chip := Chain_Chip{label = placeholder, index = slot, recording = true}
		if first + slot < len(chain.chips) {chain.chips[first + slot] = chip} else {append(&chain.chips, chip)}
		return
	}
	if first + slot >= len(chain.chips) {return}
	chip := &chain.chips[first + slot]
	chip.recording = true
	chip.contested = chain.capture.used_by_len > 0
}

// Takes the raw key event: a recording needs the physical key, and the rows use the layout's key.
// Recording, Escape cancels only the recording and Enter applies it; otherwise the arrows choose a
// row, Enter records its contested chip again (or adds one), Delete removes that chip and Escape
// drops the chain.
shortcut_chain_key :: proc(chain: ^Shortcut_Chain, raw: input.Key_Event) -> Chain_Outcome {
	if !raw.pressed || !shortcut_chain_active(chain) {return .None}
	plain := raw.modifiers & {.Control, .Shift, .Alt, .Super} == {}
	if chain.recording >= 0 {
		// The chain has no Key positions switch for Tab to move to.
		if plain && raw.key == .Tab {return .None}
		base := chain.members[chain.recording].draft
		switch shortcut_capture_key(&chain.capture, &chain.draft, base, .Alternatives, raw, 0) {
		case .None:
			return .None
		case .Changed, .Hinted, .Positions:
			chain_refresh(chain)
			return .Changed
		case .Cancel:
			chain_stop(chain)
			return .Changed
		case .Save:
			return chain_commit(chain)
		}
		return .None
	}
	e := raw
	e.key = commands.logical_key(raw.key, raw.unshifted)
	if step := list_step(e); step != 0 {
		chain.selected = clamp(chain.selected + step, 0, len(chain.members) - 1)
		return .Changed
	}
	if !plain {return .None}
	#partial switch e.key {
	case .Escape:
		return .Cancelled
	case .Enter, .Numpad_Enter:
		index := chain_contested_chip(chain, chain.selected)
		if index < 0 {index = chain.members[chain.selected].count}
		shortcut_chain_record(chain, chain.selected, index)
		return .Changed
	case .Delete, .Backspace:
		index := chain_contested_chip(chain, chain.selected)
		if index < 0 {return .None}
		return chain_remove(chain, chain.selected, index)
	}
	return .None
}

// A press on a part of a member's row: a chip records again, its remove mark removes it and the add
// chip records a new alternative. Anywhere else selects the row and ends a recording on another one.
shortcut_chain_press :: proc(chain: ^Shortcut_Chain, hit: Chain_Hit) -> Chain_Outcome {
	switch hit.part {
	case .None:
		return .None
	case .Row:
		if chain.recording >= 0 && chain.recording != hit.member {chain_stop(chain)}
		chain.selected = hit.member
	case .Chip:
		shortcut_chain_record(chain, hit.member, hit.chip)
	case .Add:
		shortcut_chain_record(chain, hit.member, chain.members[hit.member].count)
	case .Remove:
		return chain_remove(chain, hit.member, hit.chip)
	case .Cancel:
		return .Cancelled
	}
	return .Changed
}

// Notes the part under the pointer; reports whether it changed, so the owner redraws only then.
shortcut_chain_hover :: proc(chain: ^Shortcut_Chain, hit: Chain_Hit) -> bool {
	if chain.hover == hit {return false}
	chain.hover = hit
	return true
}

// A recording chip has no controls; every other chip has a remove mark, and the row ends with Add.
@(private)
chain_controls :: proc(chain: ^Shortcut_Chain, member: int) -> bool {return member != chain.recording}

@(private)
chain_chip_width :: proc(chip: Chain_Chip, controls: bool, small: ^Text, scale: f32) -> f32 {
	trailing := controls ? SPACE_1 + CHAIN_REMOVE_SIZE + SPACE_1 : CONTROL_INSET
	return (CONTROL_INSET + trailing) * scale + text_width(small, chip.label)
}

// Where member `member`'s chips start when they end at `right`.
@(private)
chain_chips_left :: proc(chain: ^Shortcut_Chain, member: int, right: f32, small: ^Text, scale: f32) -> f32 {
	m := chain.members[member]
	controls := chain_controls(chain, member)
	width: f32
	for chip in chain.chips[m.first:][:m.count] {
		width += chain_chip_width(chip, controls, small, scale) + SPACE_2 * scale
	}
	if controls {width += HEIGHT_COMPACT * scale} else if m.count > 0 {width -= SPACE_2 * scale}
	return right - width
}

@(private)
chain_remove_rect :: proc(chip: render.Rect, scale: f32) -> render.Rect {
	size := CHAIN_REMOVE_SIZE * scale
	return {chip.x + chip.width - SPACE_1 * scale - size, chip.y + (chip.height - size) / 2, size, size}
}

// A chip as laid out: its rectangle and its remove mark, empty while the member records.
Chain_Chip_Rects :: struct {
	chip:         Chain_Chip,
	rect, remove: render.Rect,
}

// Member `member`'s chips laid out to end at `right`, for verification reports; temporary.
shortcut_chain_chip_rects :: proc(
	chain: ^Shortcut_Chain,
	member: int,
	row: render.Rect,
	right: f32,
	text: ^Text,
	scale: f32,
) -> []Chain_Chip_Rects {
	small := text_styled(text, .Detail)
	m := chain.members[member]
	controls := chain_controls(chain, member)
	height := HEIGHT_COMPACT * scale
	top := row.y + (row.height - height) / 2
	pen := chain_chips_left(chain, member, right, &small, scale)
	out := make([]Chain_Chip_Rects, m.count, context.temp_allocator)
	for chip, i in chain.chips[m.first:][:m.count] {
		r := render.Rect{pen, top, chain_chip_width(chip, controls, &small, scale), height}
		out[i] = {chip, r, controls ? chain_remove_rect(r, scale) : {}}
		pen += r.width + SPACE_2 * scale
	}
	return out
}

// The part of member `member`'s row under x, y, with its chips ending at `right`.
shortcut_chain_hit :: proc(
	chain: ^Shortcut_Chain,
	member: int,
	row: render.Rect,
	right: f32,
	text: ^Text,
	scale: f32,
	x, y: f32,
) -> Chain_Hit {
	if !render.rect_contains(row, x, y) {return {}}
	hit := Chain_Hit{member = member, part = .Row}
	if !chain_controls(chain, member) || text == nil {return hit}
	small := text_styled(text, .Detail)
	m := chain.members[member]
	height := HEIGHT_COMPACT * scale
	top := row.y + (row.height - height) / 2
	pen := chain_chips_left(chain, member, right, &small, scale)
	for chip in chain.chips[m.first:][:m.count] {
		r := render.Rect{pen, top, chain_chip_width(chip, true, &small, scale), height}
		if render.rect_contains(r, x, y) {
			hit.chip = chip.index
			hit.part = render.rect_contains(chain_remove_rect(r, scale), x, y) ? .Remove : .Chip
			return hit
		}
		pen += r.width + SPACE_2 * scale
	}
	if render.rect_contains({pen, top, height, height}, x, y) {hit.part = .Add}
	return hit
}

// Draws member `member`'s chips ending at `right` and returns where they start, so the row's title
// stops before them. A contested chord is red; a chord not saved yet has a dashed outline.
shortcut_chain_chips_draw :: proc(
	chain: ^Shortcut_Chain,
	member: int,
	row: render.Rect,
	right: f32,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> (
	left: f32,
	status: render.Build_Status,
) {
	small := text_styled(text, .Detail)
	m := chain.members[member]
	controls := chain_controls(chain, member)
	height := HEIGHT_COMPACT * scale
	top := row.y + (row.height - height) / 2
	radius := RADIUS_CONTROL * scale
	left = chain_chips_left(chain, member, right, &small, scale)
	pen := left
	hover := chain.hover
	for chip in chain.chips[m.first:][:m.count] {
		r := render.Rect{pen, top, chain_chip_width(chip, controls, &small, scale), height}
		pen += r.width + SPACE_2 * scale
		hovered := hover.member == member && hover.chip == chip.index && hover.part == .Chip
		ink := chip.contested ? theme.error : (chip.pending || chip.recording || hovered ? theme.text : theme.muted)
		edge := chip.contested ? theme.error : (chip.pending || chip.recording ? theme.accent : theme.border)
		if hovered && !chip.contested && !chip.pending {edge = theme.muted}
		switch {
		case chip.recording:
			draw_rect(list, {rect = r, color = edge, radius = radius, stroke = 2 * scale})
		case chip.pending:
			dashed_outline_draw(list, r, edge, radius, scale)
		case:
			draw_rect(list, {rect = r, color = edge, radius = radius, stroke = scale})
		}
		baseline := r.y + (r.height - small.line_height) / 2 + small.ascent
		if result := draw_text(&small, list, chip.label, r.x + CONTROL_INSET * scale, baseline, ink);
		   result != .Ok {return left, result}
		if !controls {continue}
		remove := chain_remove_rect(r, scale)
		over := hover.member == member && hover.chip == chip.index && hover.part == .Remove
		if over {draw_rect(list, {rect = remove, color = theme.hover, radius = radius})}
		icon_draw(list, .Close, remove, over ? theme.error : theme.faint, ICON_INDICATOR, scale)
	}
	if !controls {return left, .Ok}
	add := render.Rect{pen, top, height, height}
	over := hover.member == member && hover.part == .Add
	draw_rect(list, {rect = add, color = over ? theme.muted : theme.border, radius = radius, stroke = scale})
	icon_draw(list, .Add, add, over ? theme.text : theme.muted, ICON_INDICATOR, scale)
	return left, .Ok
}

// The muted red of the "Used by" line under a recording field or chip.
used_by_color :: proc(theme: Theme) -> render.Color {return theme.error * 0.7 + theme.muted * 0.3}

// Draws the "Used by" line right-aligned to `right`, its top at `top`.
used_by_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	line: string,
	right, top: f32,
) -> render.Build_Status {
	if line == "" {return .Ok}
	small := text_styled(text, .Detail)
	x := right - text_width(&small, line)
	return draw_text(&small, list, line, x, top + small.ascent, used_by_color(theme))
}

// The Cancel · Esc button, right-aligned to `right` and centred on `cy`.
chain_cancel_rect :: proc(text: ^Text, right, cy, scale: f32) -> render.Rect {
	small := text_styled(text, .Detail)
	width := text_width(&small, CHAIN_CANCEL_LABEL) + 2 * CONTROL_INSET * scale
	height := HEIGHT_COMPACT * scale
	return {right - width, cy - height / 2, width, height}
}

// A ghost button: no fill at rest, the hover fill and full-strength text under the pointer.
chain_cancel_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	r: render.Rect,
	hovered: bool,
	scale: f32,
) -> render.Build_Status {
	small := text_styled(text, .Detail)
	if hovered {draw_rect(list, {rect = r, color = theme.hover, radius = RADIUS_CONTROL * scale})}
	baseline := r.y + (r.height - small.line_height) / 2 + small.ascent
	return draw_text(&small, list, CHAIN_CANCEL_LABEL, r.x + CONTROL_INSET * scale, baseline,
	                 hovered ? theme.text : theme.muted)
}

// A one-pixel outline of short dashes along `r`'s straight edges, with solid rounded corners.
@(private)
dashed_outline_draw :: proc(
	list: ^render.Draw_List,
	r: render.Rect,
	color: render.Color,
	radius, scale: f32,
) {
	width := scale
	half := width / 2
	dash, step := CHAIN_DASH * scale, (CHAIN_DASH + CHAIN_DASH_GAP) * scale
	edges := [4][2][2]f32 {
		{{r.x + radius, r.y + half}, {r.x + r.width - radius, r.y + half}},
		{{r.x + radius, r.y + r.height - half}, {r.x + r.width - radius, r.y + r.height - half}},
		{{r.x + half, r.y + radius}, {r.x + half, r.y + r.height - radius}},
		{{r.x + r.width - half, r.y + radius}, {r.x + r.width - half, r.y + r.height - radius}},
	}
	for edge in edges {
		length := max(abs(edge[1].x - edge[0].x), abs(edge[1].y - edge[0].y))
		direction := (edge[1] - edge[0]) / max(length, 1)
		for at := f32(0); at < length; at += step {
			// Round caps add half the width at each end of a dash.
			start := edge[0] + direction * (at + half)
			end := edge[0] + direction * (min(at + dash, length) - half)
			_ = render.push_segment(list, start, end, width, color)
		}
	}
	corners := [4][3]f32 {
		{r.x + radius, r.y + radius, math.PI},
		{r.x + r.width - radius, r.y + radius, 1.5 * math.PI},
		{r.x + r.width - radius, r.y + r.height - radius, 0},
		{r.x + radius, r.y + r.height - radius, 0.5 * math.PI},
	}
	for corner in corners {
		_ = render.push_arc(list, {corner.x, corner.y}, radius - half, corner.z, 0.5 * math.PI, width, color)
	}
}

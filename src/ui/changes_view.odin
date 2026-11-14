package ui

import "aio:render"
import tr "aio:turns"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// The Agent changes pane: a toolbar with the scope, a list of recorded turns, and one diff stream. The
// pane keeps the model and the scroll state; this file lays the view out, draws it and answers where a
// point lands. Heights of the diff stream are cached in whole pixels, so scrolling and hit testing
// agree with what is drawn.

Changes_Scope :: enum u8 {
	Agent,
	Repository,
	Uncommitted,
	Staged,
	Unstaged,
}

CHANGES_SCOPE_LABELS :: [Changes_Scope]string {
	.Agent       = "This agent's turns",
	.Repository  = "All turns in this repository",
	.Uncommitted = "Uncommitted changes",
	.Staged      = "Staged changes",
	.Unstaged    = "Unstaged changes",
}

// Whether the scope reads recorded turns rather than asking git.
changes_scope_turns :: proc(s: Changes_Scope) -> bool {return s == .Agent || s == .Repository}

// Why the diff area shows a message instead of a diff.
Changes_Notice :: enum u8 {
	None,
	Loading,
	Recording_Off,
	Not_Repository,
	Git_Missing,
	Failed,
	No_Turns,
	No_Changes,
}

// One row of the turn list. `between` is what changed while no agent worked.
Changes_Turn :: struct {
	title, detail:         string,
	files, added, removed: int,
	between:               bool,
}

Changes_View :: struct {
	scope:       Changes_Scope,
	notice:      Changes_Notice,
	// Extra notice text, such as the git error.
	detail:      string,
	// The label in the toolbar.
	repository:  string,
	// Newest first; empty in git scopes.
	turns:       []Changes_Turn,
	// The selected inclusive row range of `turns`, -1 when none.
	first, last: int,
	// The diff for the selection or git scope.
	files:       []tr.Diff_File,
	// Parallel to `files`.
	marked:      []bool,
	collapsed:   []bool,
	// Untracked files left out of an Uncommitted diff.
	omitted:     int,
	// Show the "Install turn hooks" toolbar button.
	hooks_offer: bool,
	// Bumps whenever the content changes, so the cached row layout refreshes.
	revision:    u64,
}

Changes_Part :: enum u8 {
	None,
	Scope,
	Hooks,
	Notice_Button,
	Turn,
	File_Header,
	Diff,
	Turn_List,
}

// What a point is over. `index` is the turn row for Turn and the file for File_Header and Diff (-1 below
// the last file).
Changes_Hit :: struct {
	part:  Changes_Part,
	index: int,
}

// The cached layout of the diff stream, in whole pixels. Each file is its header, its body unless
// collapsed, and a gap. A hunk is its header row and one row per line; a binary file or one without
// hunks has a single note row.
Changes_Rows :: struct {
	valid:                                  bool,
	revision, collapsed_key:                u64,
	notice:                                 Changes_Notice,
	files, omitted:                         int,
	scale, line_height:                     f32,
	header, hunk, line, note, gap, footer:  int,
	// The top of each file, then the end of the last one.
	tops:                                   [dynamic]int,
	total:                                  int,
}

// Per pane. The pane owns it and frees it with changes_state_destroy.
Changes_State :: struct {
	turn_scroll, diff_scroll: int,
	hover, press:             Changes_Hit,
	// The control whose hover and press `motion` plays: it keeps fading after the pointer leaves.
	lit:                      Changes_Hit,
	// The scope's list is open, so its field stays outlined.
	scope_open:               bool,
	motion:                   Control_Motion,
	rows:                     Changes_Rows,
	turn_bar, diff_bar:       Scroll_Drag,
}

changes_state_destroy :: proc(state: ^Changes_State) {
	delete(state.rows.tops)
	state.rows = {}
}

// Where everything goes, in window pixels. `diff` holds the diff stream or the notice and is the area
// the pane scrollbar belongs to; `turns` is empty without a turn list.
Changes_Geometry :: struct {
	area, toolbar, scope, hooks, repository, turns, diff, notice, notice_button: render.Rect,
	scale, turn_row:                                                             f32,
	// The turn list sits above the diff rather than beside it.
	narrow:                                                                      bool,
}

@(private = "file")
CHANGES_TURN_LIST_WIDTH :: f32(264)
@(private = "file")
CHANGES_TURN_ROW_HEIGHT :: f32(40)
@(private = "file")
CHANGES_NARROW_BODY :: f32(560)
@(private = "file")
CHANGES_NARROW_SHARE :: f32(0.3)
@(private = "file")
CHANGES_SCOPE_WIDTH :: f32(216)
@(private = "file")
CHANGES_NOTICE_WIDTH :: f32(360)
@(private = "file")
CHANGES_TAB_COLUMNS :: 4
@(private = "file")
CHANGES_HOOKS_LABEL :: "Install turn hooks"
@(private = "file")
CHANGES_RECORD_LABEL :: "Record agent turns"
@(private = "file")
CHANGES_MARKED_LABEL :: "Also changed outside these turns"
@(private = "file")
CHANGES_STATUS_WIDTH :: f32(16)
@(private = "file")
CHANGES_BADGE_MINIMUM_PATH :: f32(96)

// The text of a notice: its title and an optional body.
changes_notice_text :: proc(view: ^Changes_View) -> (title, body: string) {
	switch view.notice {
	case .None:
	case .Loading:
		title = "Loading changes…"
	case .Recording_Off:
		title = "Turn recording is off"
		body = "Record agent turns to see what each turn changed. Copies stay on this computer and are " +
			"deleted after the retention period."
	case .Not_Repository:
		title, body = "Not a git repository", "Agent changes works in git repositories."
	case .Git_Missing:
		title, body = "Git was not found", "Install Git or add it to PATH."
	case .Failed:
		title, body = "Could not read changes", clip_bytes(view.detail, CHANGES_CLIP_BYTES)
	case .No_Turns:
		title = "No turns yet"
		body = "Turns appear here when an agent in this repository starts working."
	case .No_Changes:
		title = "No changes"
		body = changes_scope_turns(view.scope) ? "The selected turns changed no files." : "Nothing to show."
	}
	return
}

@(private = "file")
wrap_count :: proc(t: ^Text, s: string, width: f32) -> int {
	lines := Wrap_Lines {
		text      = t,
		s         = s,
		width     = max(1, width),
		last_space = -1,
	}
	count := 0
	for {
		_, _, ok := wrap_next(&lines)
		if !ok {break}
		count += 1
	}
	return count
}

changes_geometry :: proc(
	area: render.Rect, scale: f32, view: ^Changes_View, text: ^Text,
) -> Changes_Geometry {
	s := scale
	g := Changes_Geometry {
		area     = area,
		scale    = s,
		turn_row = math.round(CHANGES_TURN_ROW_HEIGHT * s),
	}
	g.toolbar = {area.x, area.y, area.width, min(HEIGHT_TOOLBAR * s, area.height)}
	pad, gap := SPACE_2 * s, SPACE_2 * s
	control := min(HEIGHT_COMPACT * s, g.toolbar.height)
	top := g.toolbar.y + (g.toolbar.height - control) / 2
	room := max(0, area.width - 2 * pad)
	body_text := text_styled(text, .Body)
	hooks_width: f32
	if view.hooks_offer {
		hooks_width = min(text_width(&body_text, CHANGES_HOOKS_LABEL) + 2 * SPACE_3 * s, room / 2)
	}
	scope_room := room - hooks_width - (hooks_width > 0 ? gap : 0)
	g.scope = {area.x + pad, top, min(CHANGES_SCOPE_WIDTH * s, max(0, scope_room)), control}
	if hooks_width > 0 {g.hooks = {area.x + area.width - pad - hooks_width, top, hooks_width, control}}
	left := g.scope.x + g.scope.width + gap
	right := hooks_width > 0 ? g.hooks.x - gap : area.x + area.width - pad
	g.repository = {left, g.toolbar.y, max(0, right - left), g.toolbar.height}

	bottom := max(0, area.height - g.toolbar.height)
	body := render.Rect{area.x, g.toolbar.y + g.toolbar.height, area.width, bottom}
	g.diff = body
	if changes_scope_turns(view.scope) && len(view.turns) > 0 {
		if body.width >= CHANGES_NARROW_BODY * s {
			width := min(math.round(CHANGES_TURN_LIST_WIDTH * s), body.width)
			g.turns = {body.x, body.y, width, body.height}
			g.diff = {body.x + width, body.y, body.width - width, body.height}
		} else {
			g.narrow = true
			height := math.round(body.height * CHANGES_NARROW_SHARE)
			g.turns = {body.x, body.y, body.width, height}
			g.diff = {body.x, body.y + height, body.width, body.height - height}
		}
	}
	if view.notice != .None {changes_notice_place(&g, view, text, &body_text)}
	return g
}

@(private = "file")
changes_notice_place :: proc(g: ^Changes_Geometry, view: ^Changes_View, text, body_text: ^Text) {
	s := g.scale
	_, body := changes_notice_text(view)
	strong := text_styled(text, .Strong)
	width := math.round(min(CHANGES_NOTICE_WIDTH * s, max(0, g.diff.width - 2 * SPACE_4 * s)))
	lines := body != "" ? wrap_count(body_text, body, width) : 0
	height := strong.line_height
	if lines > 0 {height += SPACE_1 * s + f32(lines) * body_text.line_height}
	button := view.notice == .Recording_Off
	if button {height += SPACE_4 * s + HEIGHT_STANDARD * s}
	x := math.round(g.diff.x + (g.diff.width - width) / 2)
	y := math.round(g.diff.y + max(0, (g.diff.height - height) / 2))
	g.notice = {x, y, width, height}
	if button {
		label := text_width(&strong, CHANGES_RECORD_LABEL) + 2 * SPACE_6 * s
		w := min(math.round(label), width)
		g.notice_button = {
			math.round(x + (width - w) / 2),
			y + height - HEIGHT_STANDARD * s,
			w,
			HEIGHT_STANDARD * s,
		}
	}
}

@(private = "file")
collapsed_key :: proc(view: ^Changes_View) -> u64 {
	hash := u64(14695981039346656037)
	for c in view.collapsed {hash = (hash ~ (c ? 2 : 1)) * 1099511628211}
	return hash
}

@(private = "file")
changes_collapsed :: proc(view: ^Changes_View, i: int) -> bool {
	return i < len(view.collapsed) && view.collapsed[i]
}

@(private = "file")
changes_marked :: proc(view: ^Changes_View, i: int) -> bool {
	return i < len(view.marked) && view.marked[i]
}

@(private = "file")
file_body_height :: proc(rows: ^Changes_Rows, f: ^tr.Diff_File) -> int {
	if f.binary || len(f.hunks) == 0 {return rows.note}
	h := 0
	for &hunk in f.hunks {h += rows.hunk + len(hunk.lines) * rows.line}
	return h
}

// Refreshes the cached rows when the content, the line height or the scale changed. Collapsing is the
// pane's own state, so it is part of the key too.
changes_layout :: proc(state: ^Changes_State, view: ^Changes_View, mono: ^Text, scale: f32) {
	rows := &state.rows
	key := collapsed_key(view)
	if rows.valid && rows.revision == view.revision && rows.collapsed_key == key &&
	   rows.notice == view.notice && rows.files == len(view.files) && rows.omitted == view.omitted &&
	   rows.line_height == mono.line_height && rows.scale == scale {return}
	rows.valid, rows.revision, rows.collapsed_key, rows.notice = true, view.revision, key, view.notice
	rows.files, rows.omitted = len(view.files), view.omitted
	rows.scale, rows.line_height = scale, mono.line_height
	rows.header = int(math.round(HEIGHT_STANDARD * scale))
	rows.line = max(1, int(mono.line_height) + int(math.round(2 * scale)))
	rows.hunk = rows.line + int(math.round(SPACE_1 * scale))
	rows.note = int(math.round(HEIGHT_COMPACT * scale))
	rows.gap = int(math.round(SPACE_2 * scale))
	rows.footer = int(math.round(HEIGHT_STANDARD * scale))
	clear(&rows.tops)
	y := 0
	if view.notice == .None {
		for i in 0 ..< len(view.files) {
			append(&rows.tops, y)
			y += rows.header
			if !changes_collapsed(view, i) {y += file_body_height(rows, &view.files[i])}
			y += rows.gap
		}
	}
	append(&rows.tops, y)
	rows.total = y
	if view.notice == .None && view.omitted > 0 {rows.total += rows.footer}
}

// The file that contains row `y` of the stream: its index, the file count past the last one, or -1 for
// a negative `y` and for no files.
@(private = "file")
changes_file_at :: proc(rows: ^Changes_Rows, y: int) -> int {
	files := len(rows.tops) - 1
	if files <= 0 || y < 0 {return -1}
	if y >= rows.tops[files] {return files}
	low, high := 0, files - 1
	for low < high {
		mid := (low + high + 1) / 2
		if rows.tops[mid] <= y {low = mid} else {high = mid - 1}
	}
	return low
}

changes_diff_extent :: proc(state: ^Changes_State, g: Changes_Geometry) -> Scroll_Extent {
	visible := int(g.diff.height)
	return {
		total = state.rows.total,
		visible = visible,
		offset = clamp(state.diff_scroll, 0, max(0, state.rows.total - visible)),
	}
}

// The turn list's own scrollbar, laid out in `state`'s look; `visible` is false when the rows fit.
changes_turn_scrollbar :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, bar_state := Scrollbar_State.Collapsed,
) -> (bar: Scrollbar, visible: bool) {
	extent := Scroll_Extent {
		total   = len(view.turns) * int(g.turn_row),
		visible = int(g.turns.height),
		offset  = state.turn_scroll,
	}
	return scrollbar_layout(g.turns, extent, bar_state, g.scale)
}

// Scroll by `delta` pixels, positive toward the end; true when the position changed.
changes_scroll_turns :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, delta: int,
) -> bool {
	limit := max(0, len(view.turns) * int(g.turn_row) - int(g.turns.height))
	before := state.turn_scroll
	state.turn_scroll = clamp(before + delta, 0, limit)
	return state.turn_scroll != before
}

changes_scroll_diff :: proc(state: ^Changes_State, g: Changes_Geometry, delta: int) -> bool {
	limit := max(0, state.rows.total - int(g.diff.height))
	before := state.diff_scroll
	state.diff_scroll = clamp(before + delta, 0, limit)
	return state.diff_scroll != before
}

// The on-screen rect of turn row `index` given the scroll, cut to the turn list; empty when it is outside.
changes_turn_rect :: proc(g: Changes_Geometry, state: ^Changes_State, index: int) -> render.Rect {
	if index < 0 || g.turn_row <= 0 {return {}}
	y := g.turns.y + f32(index) * g.turn_row - f32(state.turn_scroll)
	top, bottom := max(y, g.turns.y), min(y + g.turn_row, g.turns.y + g.turns.height)
	if bottom <= top {return {}}
	return {g.turns.x, top, g.turns.width, bottom - top}
}

// Scrolls the turn list just far enough to show row `index` whole; true when it moved.
changes_turn_reveal :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, index: int,
) -> bool {
	if index < 0 || index >= len(view.turns) || g.turn_row <= 0 {return false}
	row, visible := int(g.turn_row), int(g.turns.height)
	top := index * row
	target := state.turn_scroll
	if top < target {
		target = top
	} else if top + row > target + visible {
		target = top + row - visible
	}
	target = clamp(target, 0, max(0, len(view.turns) * row - visible))
	moved := target != state.turn_scroll
	state.turn_scroll = target
	return moved
}

// What lies at the point. Needs the rows of the latest changes_layout.
changes_hit :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, x, y: f32,
) -> Changes_Hit {
	if render.rect_contains(g.scope, x, y) {return {.Scope, 0}}
	if render.rect_contains(g.hooks, x, y) {return {.Hooks, 0}}
	if render.rect_contains(g.notice_button, x, y) {return {.Notice_Button, 0}}
	if render.rect_contains(g.turns, x, y) && g.turn_row > 0 {
		row := int((y - g.turns.y + f32(state.turn_scroll)) / g.turn_row)
		if row >= 0 && row < len(view.turns) {return {.Turn, row}}
		return {.Turn_List, 0}
	}
	if view.notice == .None && render.rect_contains(g.diff, x, y) {
		rows := &state.rows
		at := int(y - g.diff.y) + state.diff_scroll
		file := changes_file_at(rows, at)
		if file < 0 || file >= len(rows.tops) - 1 {return {.Diff, -1}}
		if at < rows.tops[file] + rows.header {return {.File_Header, file}}
		return {.Diff, file}
	}
	return {}
}

@(private = "file")
changes_animated :: proc(hit: Changes_Hit) -> bool {
	#partial switch hit.part {
	case .Scope, .Hooks, .Notice_Button, .File_Header:
		return true
	}
	return false
}

// Plays the hover and press of the control under the pointer; true while it moves. The motion belongs
// to one control at a time and restarts when the pointer moves to another.
changes_animate :: proc(state: ^Changes_State, enabled: bool, frame: Frame_Time) -> bool {
	switched := false
	if changes_animated(state.hover) && state.hover != state.lit {
		state.lit, switched = state.hover, true
		state.motion = {}
	}
	over := changes_animated(state.lit) && state.hover == state.lit
	pressed := over && state.press == state.lit
	return control_update(&state.motion, over, pressed, enabled, frame) || switched
}

@(private = "file")
changes_lit :: proc(state: ^Changes_State, hit: Changes_Hit) -> (hover, press: f32) {
	if state.lit != hit {return 0, 0}
	return state.motion.hover.value, state.motion.press.value
}

@(private = "file")
baseline_in :: proc(y, height: f32, t: ^Text) -> f32 {return y + (height - t.line_height) / 2 + t.ascent}

// "+N −M" in the added and removed colours, ending at `right`. Returns where it starts, which is
// `right` when there is nothing to show.
@(private = "file")
stats_draw :: proc(
	list: ^render.Draw_List,
	t: ^Text,
	theme: Theme,
	right, baseline: f32,
	added, removed: int,
	scale: f32,
) -> (
	left: f32,
	status: render.Build_Status,
) {
	if added == 0 && removed == 0 {return right, .Ok}
	plus_buf, minus_buf: [24]u8
	plus := fmt.bprintf(plus_buf[:], "+%d", added)
	minus := fmt.bprintf(minus_buf[:], "−%d", removed)
	minus_x := right - text_width(t, minus)
	plus_x := minus_x - SPACE_1 * scale - text_width(t, plus)
	if status = draw_text(t, list, plus, plus_x, baseline, theme.success); status != .Ok {return}
	status = draw_text(t, list, minus, minus_x, baseline, theme.error)
	return plus_x, status
}

@(private = "file")
tab_expand :: proc(buf: []u8, s: string) -> string {
	if strings.index_byte(s, '\t') < 0 {return s}
	n := 0
	for r in s {
		if r == '\t' {
			if n + CHANGES_TAB_COLUMNS > len(buf) {break}
			for _ in 0 ..< CHANGES_TAB_COLUMNS {
				buf[n] = ' '
				n += 1
			}
			continue
		}
		encoded, size := utf8.encode_rune(r)
		if n + size > len(buf) {break}
		copy(buf[n:], encoded[:size])
		n += size
	}
	return string(buf[:n])
}

@(private = "file")
CHANGES_CLIP_BYTES :: 512

// The start of `s` of at most `limit` bytes, cut on a rune boundary. Long titles and paths only ever show
// their start, so drawing never measures the rest.
clip_bytes :: proc(s: string, limit: int) -> string {
	if len(s) <= limit {return s}
	end := limit
	for end > 0 && (s[end] & 0xC0) == 0x80 {end -= 1}
	return s[:end]
}

// The leading runes of `s` that can reach `width` in a monospace font whose glyphs advance `advance`, plus
// two, so the fade still sees the overflow. A minified line is therefore never walked whole.
mono_prefix :: proc(s: string, width, advance: f32) -> string {
	if advance <= 0 {return clip_bytes(s, CHANGES_CLIP_BYTES)}
	limit := int(max(0, width) / advance) + 2
	count := 0
	for _, offset in s {
		if count == limit {return s[:offset]}
		count += 1
	}
	return s
}

// The text of a file header: the path, or old and new for a rename or copy.
@(private = "file")
file_label :: proc(buf: []u8, f: ^tr.Diff_File) -> string {
	if (f.status == .Renamed || f.status == .Copied) && f.old_path != f.new_path && f.old_path != "" {
		return fmt.bprintf(buf, "%s → %s", f.old_path, f.new_path)
	}
	if f.status == .Deleted || f.new_path == "" {return clip_bytes(f.old_path, len(buf))}
	return clip_bytes(f.new_path, len(buf))
}

@(private = "file")
status_mark :: proc(status: tr.File_Status, theme: Theme) -> (mark: string, color: render.Color) {
	switch status {
	case .Modified:
		return "M", theme.warning
	case .Added:
		return "A", theme.success
	case .Deleted:
		return "D", theme.error
	case .Renamed:
		return "R", theme.info
	case .Copied:
		return "C", theme.info
	}
	return "M", theme.warning
}

@(private = "file")
Diff_Paint :: struct {
	list:                 ^render.Draw_List,
	mono, small, strong, body: ^Text,
	theme:                Theme,
	scale:                f32,
	// The file card's horizontal extent; rows fill it.
	card_x, card_width:   f32,
	// The visible part of the diff area, to skip rows outside it.
	top, bottom:          f32,
	digit:                f32,
	// Where the line numbers, the sign and the text start in the current file.
	old_x, new_x, sign_x, text_x, column: f32,
}

@(private = "file")
digit_count :: proc(n: int) -> int {
	count := 1
	for v := n; v >= 10; v /= 10 {count += 1}
	return count
}

@(private = "file")
paint_gutter :: proc(p: ^Diff_Paint, f: ^tr.Diff_File) {
	biggest := 0
	if len(f.hunks) > 0 {
		last := f.hunks[len(f.hunks) - 1]
		biggest = int(max(last.old_start + last.old_count, last.new_start + last.new_count))
	}
	s := p.scale
	p.column = f32(digit_count(biggest)) * p.digit
	p.old_x = p.card_x + SPACE_2 * s
	p.new_x = p.old_x + p.column + SPACE_2 * s
	p.sign_x = p.new_x + p.column + SPACE_2 * s
	p.text_x = p.sign_x + p.digit + SPACE_1 * s
}

@(private = "file")
number_draw :: proc(p: ^Diff_Paint, n: i32, x, baseline: f32) -> render.Build_Status {
	if n <= 0 {return .Ok}
	buf: [16]u8
	label := strconv.write_int(buf[:], i64(n), 10)
	return draw_text(p.mono, p.list, label, x + p.column - f32(len(label)) * p.digit, baseline, p.theme.faint)
}

@(private = "file")
paint_line :: proc(p: ^Diff_Paint, line: ^tr.Diff_Line, y, height: f32) -> render.Build_Status {
	t := p.theme
	baseline := baseline_in(y, height, p.mono)
	row := render.Rect{p.card_x, y, p.card_width, height}
	switch line.kind {
	case .Added:
		draw_rect(p.list, {rect = row, color = t.diff_added})
	case .Removed:
		draw_rect(p.list, {rect = row, color = t.diff_removed})
	case .Context, .No_Newline:
	}
	if line.kind == .No_Newline {
		return draw_fading_text(
			p.mono, p.list, "No newline at end of file", p.text_x, baseline, t.faint,
			p.card_x + p.card_width - p.text_x,
		)
	}
	if line.kind != .Added {
		if r := number_draw(p, line.old_line, p.old_x, baseline); r != .Ok {return r}
	}
	if line.kind != .Removed {
		if r := number_draw(p, line.new_line, p.new_x, baseline); r != .Ok {return r}
	}
	ink := t.muted
	switch line.kind {
	case .Added:
		ink = t.success
		if r := draw_text(p.mono, p.list, "+", p.sign_x, baseline, ink); r != .Ok {return r}
		ink = t.text
	case .Removed:
		ink = t.error
		if r := draw_text(p.mono, p.list, "-", p.sign_x, baseline, ink); r != .Ok {return r}
		ink = t.text
	case .Context, .No_Newline:
	}
	buf: [1024]u8
	width := p.card_x + p.card_width - p.text_x
	text := tab_expand(buf[:], mono_prefix(line.text, width, p.digit))
	return draw_fading_text(p.mono, p.list, text, p.text_x, baseline, ink, width)
}

@(private = "file")
paint_hunk :: proc(p: ^Diff_Paint, rows: ^Changes_Rows, h: ^tr.Hunk, y: f32) -> render.Build_Status {
	t := p.theme
	header := render.Rect{p.card_x, y, p.card_width, f32(rows.hunk)}
	draw_rect(p.list, {rect = header, color = t.code_background})
	buf: [64]u8
	label := fmt.bprintf(buf[:], "@@ -%d,%d +%d,%d @@", h.old_start, h.old_count, h.new_start, h.new_count)
	baseline := baseline_in(y, f32(rows.hunk), p.mono)
	room := p.card_width - 2 * SPACE_2 * p.scale
	x := p.card_x + SPACE_2 * p.scale
	if r := draw_fading_text(p.mono, p.list, label, x, baseline, t.muted, room); r != .Ok {return r}
	if h.section != "" {
		after := text_width(p.mono, label) + SPACE_2 * p.scale
		section := mono_prefix(h.section, room - after, p.digit)
		if r := draw_fading_text(p.mono, p.list, section, x + after, baseline, t.faint, room - after);
		   r != .Ok {return r}
	}
	top := y + f32(rows.hunk)
	height := f32(rows.line)
	count := len(h.lines)
	first := max(0, int(math.floor((p.top - top) / height)))
	last := min(count - 1, int(math.floor((p.bottom - top) / height)))
	for i in first ..= last {
		if r := paint_line(p, &h.lines[i], top + f32(i) * height, height); r != .Ok {return r}
	}
	return .Ok
}

@(private = "file")
paint_file :: proc(
	p: ^Diff_Paint,
	rows: ^Changes_Rows,
	view: ^Changes_View,
	state: ^Changes_State,
	i: int,
	y: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	t, s := p.theme, p.scale
	f := &view.files[i]
	head := render.Rect{p.card_x, y, p.card_width, f32(rows.header)}
	collapsed := changes_collapsed(view, i)
	hover, press := changes_lit(state, {.File_Header, i})
	draw_rect(p.list, {rect = head, color = t.surface, radius = RADIUS_CONTROL * s})
	face, ink, err := button_draw(
		p.list,
		t,
		{rect = head, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat},
		s,
		pointer,
	)
	if err != .None {return .Ok}
	x := face.x + CONTROL_INSET * s
	icon := render.Rect{x, face.y, ICON_INDICATOR * s, face.height}
	icon_draw(p.list, collapsed ? .Chevron_Right : .Chevron_Down, icon, ink, ICON_INDICATOR, s)
	x += ICON_INDICATOR * s + SPACE_1 * s
	mark, color := status_mark(f.status, t)
	slot := CHANGES_STATUS_WIDTH * s
	letter := x + (slot - text_width(p.strong, mark)) / 2
	if r := draw_text(p.strong, p.list, mark, letter, baseline_in(face.y, face.height, p.strong), color);
	   r != .Ok {return r}
	x += slot + SPACE_1 * s

	small_baseline := baseline_in(face.y, face.height, p.small)
	right := face.x + face.width - CONTROL_INSET * s
	if !f.binary {
		left, r := stats_draw(p.list, p.small, t, right, small_baseline, f.added, f.removed, s)
		if r != .Ok {return r}
		right = left - SPACE_2 * s
	}
	if changes_marked(view, i) {
		badge := text_width(p.small, CHANGES_MARKED_LABEL)
		if right - badge - x >= CHANGES_BADGE_MINIMUM_PATH * s {
			if r := draw_text(p.small, p.list, CHANGES_MARKED_LABEL, right - badge, small_baseline, t.warning);
			   r != .Ok {return r}
			right -= badge + SPACE_2 * s
		} else {
			size := ICON_INDICATOR * s
			icon_draw(p.list, .Warning, {right - size, face.y, size, face.height}, t.warning, ICON_INDICATOR, s)
			right -= size + SPACE_2 * s
		}
	}
	label_buf: [512]u8
	body := p.body
	if r := draw_fading_text(
		body, p.list, file_label(label_buf[:], f), x, baseline_in(face.y, face.height, body), t.text,
		right - x,
	); r != .Ok {return r}
	if collapsed {return .Ok}

	top := y + f32(rows.header)
	if f.binary || len(f.hunks) == 0 {
		note := f.binary ? "Binary file" : "No content changes"
		return draw_text(
			p.small, p.list, note, p.card_x + CONTROL_INSET * s, baseline_in(top, f32(rows.note), p.small),
			t.muted,
		)
	}
	paint_gutter(p, f)
	for &hunk in f.hunks {
		height := f32(rows.hunk + len(hunk.lines) * rows.line)
		if top + height > p.top {
			if top >= p.bottom {break}
			if r := paint_hunk(p, rows, &hunk, top); r != .Ok {return r}
		}
		top += height
	}
	return .Ok
}

@(private = "file")
diff_draw :: proc(
	list: ^render.Draw_List,
	text, mono: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	rows := &state.rows
	if !rows.valid || len(rows.tops) != len(view.files) + 1 || g.diff.width <= 0 {return .Ok}
	scope, opened := clip_scope_open(list, g.diff)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	s := g.scale
	small := text_styled(text, .Detail)
	strong := text_styled(text, .Strong)
	pad := SPACE_2 * s
	p := Diff_Paint {
		list       = list,
		mono       = mono,
		small      = &small,
		strong     = &strong,
		body       = text,
		theme      = theme,
		scale      = s,
		card_x     = g.diff.x + pad,
		card_width = max(0, g.diff.width - 2 * pad),
		top        = g.diff.y,
		bottom     = g.diff.y + g.diff.height,
		digit      = text_width(mono, "0"),
	}
	scroll := state.diff_scroll
	origin := g.diff.y - f32(scroll)
	files := len(view.files)
	first := max(0, changes_file_at(rows, scroll))
	for i := first; i < files && f32(rows.tops[i]) + origin < p.bottom; i += 1 {
		if r := paint_file(&p, rows, view, state, i, origin + f32(rows.tops[i]), pointer); r != .Ok {return r}
	}
	if view.omitted > 0 {
		y := origin + f32(rows.tops[files])
		if y < p.bottom && y + f32(rows.footer) > p.top {
			buf: [64]u8
			noun := view.omitted == 1 ? "file" : "files"
			label := fmt.bprintf(buf[:], "%d untracked %s not shown", view.omitted, noun)
			return draw_text(
				&small, list, label, p.card_x + CONTROL_INSET * s, baseline_in(y, f32(rows.footer), &small),
				theme.muted,
			)
		}
	}
	return .Ok
}

@(private = "file")
turns_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	if g.turns.width <= 0 || g.turns.height <= 0 || g.turn_row <= 0 {return .Ok}
	scope, opened := clip_scope_open(list, g.turns)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	s := g.scale
	body := text_styled(text, .Body)
	small := text_styled(text, .Detail)
	scroll := f32(state.turn_scroll)
	origin := g.turns.y - scroll
	count := len(view.turns)
	if view.first >= 0 && view.last >= view.first && view.first < count {
		last := min(view.last, count - 1)
		rect := render.Rect {
			g.turns.x,
			origin + f32(view.first) * g.turn_row,
			g.turns.width,
			f32(last - view.first + 1) * g.turn_row,
		}
		inner := render.Rect{rect.x, rect.y + s, rect.width, max(0, rect.height - 2 * s)}
		draw_rect(list, {rect = inner, color = theme.selection, radius = RADIUS_CONTROL * s})
		mark := navigation_row_mark_rect(rect, s)
		draw_rect(list, {rect = mark, color = theme.tab_indicator, radius = pill_radius(mark)})
	}
	first := max(0, int(scroll / g.turn_row))
	last := min(count - 1, int((scroll + g.turns.height) / g.turn_row))
	for i := first; i <= last; i += 1 {
		turn := &view.turns[i]
		row := render.Rect{g.turns.x, origin + f32(i) * g.turn_row, g.turns.width, g.turn_row}
		selected := i >= view.first && i <= view.last
		hit := Changes_Hit{.Turn, i}
		hovered, pressed := state.hover == hit, state.press == hit && state.hover == hit
		if !selected && (hovered || pressed) {
			nav := Navigation_Row {
				hovered = hovered,
				pressed = pressed,
			}
			if navigation_row_surface_draw(list, theme, row, nav, s, pointer) != .None {return .Ok}
		}
		if r := turn_row_draw(list, &body, &small, theme, row, turn, s); r != .Ok {return r}
	}
	return .Ok
}

@(private = "file")
turn_row_draw :: proc(
	list: ^render.Draw_List,
	body, small: ^Text,
	theme: Theme,
	row: render.Rect,
	turn: ^Changes_Turn,
	scale: f32,
) -> render.Build_Status {
	s := scale
	x := row.x + SPACE_3 * s
	right := row.x + row.width - SPACE_3 * s
	top := row.y + (row.height - body.line_height - small.line_height) / 2
	title_baseline := top + body.ascent
	detail_baseline := top + body.line_height + small.ascent
	stats_baseline := top + (body.line_height - small.line_height) / 2 + small.ascent
	left, status := stats_draw(list, small, theme, right, stats_baseline, turn.added, turn.removed, scale)
	if status != .Ok {return status}
	title := clip_bytes(turn.title, CHANGES_CLIP_BYTES)
	if title == "" {title = turn.between ? "Changes between turns" : "Agent turn"}
	if r := draw_fading_text(
		body, list, title, x, title_baseline, turn.between ? theme.muted : theme.text,
		left - SPACE_2 * s - x,
	); r != .Ok {return r}
	detail := clip_bytes(turn.detail, CHANGES_CLIP_BYTES)
	count_buf: [32]u8
	files := ""
	if turn.files > 0 {
		files = fmt.bprintf(count_buf[:], "%d %s", turn.files, turn.files == 1 ? "file" : "files")
	}
	files_x := right - text_width(small, files)
	if files != "" {
		if r := draw_text(small, list, files, files_x, detail_baseline, theme.faint); r != .Ok {return r}
		files_x -= SPACE_2 * s
	} else {
		files_x = right
	}
	return draw_fading_text(small, list, detail, x, detail_baseline, theme.muted, files_x - x)
}

@(private = "file")
toolbar_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	s := g.scale
	rule := render.Rect{g.toolbar.x, g.toolbar.y + g.toolbar.height - s, g.toolbar.width, s}
	draw_rect(list, {rect = rule, color = theme.border})
	@(static, rodata)
	labels := CHANGES_SCOPE_LABELS
	if g.scope.width > 0 {
		if r := dropdown_field_draw(list, text, theme, g.scope, labels[view.scope], state.scope_open, s); r != .Ok {
			return r
		}
		hover, press := changes_lit(state, {.Scope, 0})
		b := Button{rect = g.scope, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat_Unfilled}
		if _, _, err := button_draw(list, theme, b, s, pointer); err != .None {return .Ok}
	}
	small := text_styled(text, .Detail)
	if view.repository != "" && g.repository.width > 0 {
		if r := draw_fading_text(
			&small, list, clip_bytes(view.repository, CHANGES_CLIP_BYTES), g.repository.x,
			baseline_in(g.repository.y, g.repository.height, &small),
			theme.muted, g.repository.width,
		); r != .Ok {return r}
	}
	if g.hooks.width > 0 {
		radius := RADIUS_CONTROL * s
		draw_rect(list, {rect = g.hooks, color = theme.surface, radius = radius})
		draw_rect(list, {rect = g.hooks, color = theme.border, radius = radius, stroke = s})
		hover, press := changes_lit(state, {.Hooks, 0})
		b := Button{rect = g.hooks, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat_Unfilled}
		face, _, err := button_draw(list, theme, b, s, pointer)
		if err != .None {return .Ok}
		body := text_styled(text, .Body)
		inset := CONTROL_INSET * s
		width := min(text_width(&body, CHANGES_HOOKS_LABEL), max(0, face.width - 2 * inset))
		return draw_text(
			&body, list, CHANGES_HOOKS_LABEL, face.x + (face.width - width) / 2,
			baseline_in(face.y, face.height, &body), theme.text, max(1, face.width - 2 * inset),
		)
	}
	return .Ok
}

@(private = "file")
notice_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	if g.notice.width <= 0 {return .Ok}
	title, body := changes_notice_text(view)
	strong := text_styled(text, .Strong)
	plain := text_styled(text, .Body)
	n := g.notice
	y := n.y
	tw := min(text_width(&strong, title), n.width)
	if r := draw_fading_text(
		&strong, list, title, n.x + (n.width - tw) / 2, y + strong.ascent, theme.text, n.width,
	); r != .Ok {return r}
	y += strong.line_height
	if body != "" {
		y += SPACE_1 * g.scale
		lines := Wrap_Lines {
			text       = &plain,
			s          = body,
			width      = max(1, n.width),
			last_space = -1,
		}
		for {
			start, end, ok := wrap_next(&lines)
			if !ok {break}
			line := body[start:end]
			lw := min(text_width(&plain, line), n.width)
			if r := draw_text(&plain, list, line, n.x + (n.width - lw) / 2, y + plain.ascent, theme.muted, n.width);
			   r != .Ok {return r}
			y += plain.line_height
		}
	}
	if view.notice == .Recording_Off {
		hover, press := changes_lit(state, {.Notice_Button, 0})
		return primary_button_draw(
			list, text, theme, g.notice_button, CHANGES_RECORD_LABEL, hover, press, false, g.scale, pointer,
		)
	}
	return .Ok
}

changes_draw :: proc(
	list: ^render.Draw_List,
	text, mono: ^Text,
	theme: ^Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	scale: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	s := scale
	t := theme^
	turn_total := len(view.turns) * int(g.turn_row)
	state.turn_scroll = clamp(state.turn_scroll, 0, max(0, turn_total - int(g.turns.height)))
	state.diff_scroll = clamp(state.diff_scroll, 0, max(0, state.rows.total - int(g.diff.height)))
	if r := toolbar_draw(list, text, t, g, view, state, pointer); r != .Ok {return r}
	if g.turns.width > 0 {
		if r := turns_draw(list, text, t, g, view, state, pointer); r != .Ok {return r}
		edge := render.Rect{g.turns.x + g.turns.width - s, g.turns.y, s, g.turns.height}
		if g.narrow {edge = {g.turns.x, g.turns.y + g.turns.height - s, g.turns.width, s}}
		draw_rect(list, {rect = edge, color = t.border})
		held := state.turn_bar
		if track, shown := changes_turn_scrollbar(state, g, view); shown {
			over := render.rect_contains(track.track, pointer.x, pointer.y)
			bar_state := scrollbar_state(over, held)
			if bar, drawn := changes_turn_scrollbar(state, g, view, bar_state); drawn {
				scrollbar_draw(list, t, bar, bar_state)
			}
		}
	}
	if view.notice != .None {return notice_draw(list, text, t, g, view, state, pointer)}
	return diff_draw(list, text, mono, t, g, view, state, pointer)
}

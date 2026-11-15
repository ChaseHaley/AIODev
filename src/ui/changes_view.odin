package ui

import "aio:render"
import tr "aio:turns"
import "core:math"

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
	// The folder name of the worktree a git scope shows, and whether it was chosen by following the agent.
	worktree:    string,
	following:   bool,
	// Newest first; empty in git scopes.
	turns:       []Changes_Turn,
	// The selected inclusive row range of `turns`, -1 when none.
	first, last: int,
	// The diff for the selection or git scope.
	files:       []tr.Diff_File,
	// Parallel to `files`.
	marked:      []bool,
	// Parallel to `files`: a selected change may belong to another agent.
	ambiguous:   []bool,
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
	Worktree,
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
	// The worktree list is open.
	worktree_open:            bool,
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
	area, toolbar, scope, worktree, hooks, repository, turns, diff, notice, notice_button: render.Rect,
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
CHANGES_WORKTREE_WIDTH :: f32(180)
@(private = "file")
CHANGES_NOTICE_WIDTH :: f32(360)
@(private)
CHANGES_HOOKS_LABEL :: "Install turn hooks"
@(private = "file")
CHANGES_RECORD_LABEL :: "Record agent turns"
@(private = "file")
CHANGES_MARKED_LABEL :: "Also changed outside these turns"
@(private = "file")
CHANGES_AMBIGUOUS_LABEL :: "May include another agent's changes"
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
	if !changes_scope_turns(view.scope) {
		g.worktree = {left, top, min(CHANGES_WORKTREE_WIDTH * s, max(0, right - left)), control}
		if g.worktree.width > 0 {left += g.worktree.width + gap}
	}
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

@(private)
changes_collapsed :: proc(view: ^Changes_View, i: int) -> bool {
	return i < len(view.collapsed) && view.collapsed[i]
}

@(private = "file")
changes_marked :: proc(view: ^Changes_View, i: int) -> bool {
	return i < len(view.marked) && view.marked[i]
}

@(private = "file")
changes_ambiguous :: proc(view: ^Changes_View, i: int) -> bool {
	return i < len(view.ambiguous) && view.ambiguous[i]
}

Changes_Badge :: enum u8 {
	Marked,
	Ambiguous,
}

// How a file header shows a badge: its text, its icon when the path would get too little room, or not at all.
Changes_Badge_Form :: enum u8 {
	Hidden,
	Text,
	Icon,
}

CHANGES_BADGE_LABELS :: [Changes_Badge]string {
	.Marked    = CHANGES_MARKED_LABEL,
	.Ambiguous = CHANGES_AMBIGUOUS_LABEL,
}

// The form of each badge of file `i`, given `room`, the width from the start of the path to the right edge
// of the badges. The marked badge is placed first (rightmost); each falls back to its icon on its own.
changes_badge_forms :: proc(
	view: ^Changes_View, i: int, small: ^Text, room, scale: f32,
) -> (forms: [Changes_Badge]Changes_Badge_Form) {
	labels := CHANGES_BADGE_LABELS
	left := room
	for badge in Changes_Badge {
		present := badge == .Marked ? changes_marked(view, i) : changes_ambiguous(view, i)
		if !present {continue}
		width := text_width(small, labels[badge])
		if left - width >= CHANGES_BADGE_MINIMUM_PATH * scale {
			forms[badge] = .Text
			left -= width + SPACE_2 * scale
		} else {
			forms[badge] = .Icon
			left -= ICON_INDICATOR * scale + SPACE_2 * scale
		}
	}
	return
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

changes_diff_extent :: proc(state: ^Changes_State, g: Changes_Geometry) -> Scroll_Extent {
	visible := int(g.diff.height)
	return {
		total = state.rows.total,
		visible = visible,
		offset = clamp(state.diff_scroll, 0, max(0, state.rows.total - visible)),
	}
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

// What lies at the point. Needs the rows of the latest changes_layout.
changes_hit :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, x, y: f32,
) -> Changes_Hit {
	if render.rect_contains(g.scope, x, y) {return {.Scope, 0}}
	if render.rect_contains(g.worktree, x, y) {return {.Worktree, 0}}
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
	case .Scope, .Worktree, .Hooks, .Notice_Button, .File_Header:
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

@(private)
changes_lit :: proc(state: ^Changes_State, hit: Changes_Hit) -> (hover, press: f32) {
	if state.lit != hit {return 0, 0}
	return state.motion.hover.value, state.motion.press.value
}

@(private)
baseline_in :: proc(y, height: f32, t: ^Text) -> f32 {return y + (height - t.line_height) / 2 + t.ascent}

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

package ui

import "aio:render"
import "aio:syntax"
import tr "aio:turns"
import "core:math"

// The Agent changes pane: a toolbar with the source and, for turns, a strip of turn bars, then one diff
// stream across the pane. The pane keeps the model and the scroll state; this file lays the view out,
// draws it and answers where a point lands. Heights of the diff stream are cached in whole pixels, so
// scrolling and hit testing agree with what is drawn.

Changes_Scope :: enum u8 {
	Agent,
	Repository,
	Uncommitted,
	Staged,
	Unstaged,
}

CHANGES_SCOPE_LABELS :: [Changes_Scope]string {
	.Agent       = "This agent's turns",
	.Repository  = "All agents",
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

// One turn. `between` is what changed while no agent worked; `live` is a turn still open; `agent` is
// the index of the turn's agent among the repository's agents in the All agents scope, else -1.
Changes_Turn :: struct {
	title, detail:         string,
	files, added, removed: int,
	between, live:         bool,
	agent:                 int,
}

// Flat line indices within one file: the file's diff lines in hunk order, as syntax.File_Lines and
// comments count them.
Changes_Selection :: struct {
	file, first, last: int,
	active:            bool,
}

// A comment as the diff shows it. `detached`: its lines are not in this diff.
Changes_Comment_View :: struct {
	file, first, last: int,
	text:              string,
	detached:          bool,
}

// The send bar: how many comments, which agent they go to, and why Send is off when it is.
Changes_Send_View :: struct {
	count:    int,
	target:   string,
	can_send: bool,
	reason:   string,
}

Changes_View :: struct {
	scope:       Changes_Scope,
	notice:      Changes_Notice,
	// Extra notice text, such as the git error.
	detail:       string,
	// The source field's label: the agent's name, All agents or the git scope.
	source_label: string,
	// The label in the toolbar.
	repository:   string,
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
	// Parallel to `files`: each file's spans per flat diff line, or an empty entry when not highlighted.
	highlights:  []syntax.File_Lines,
	selection:   Changes_Selection,
	comments:    []Changes_Comment_View,
	// -1 when no comment is being written; an index into `comments` edits that one; len(comments) writes a
	// new one below the selection.
	editing:     int,
	editor:      ^Text_Field,
	send:        Changes_Send_View,
	// Show the "Install turn hooks" toolbar button.
	hooks_offer: bool,
	// Old and new side by side rather than one unified stream; the pane's own choice.
	side_by_side: bool,
	// The diff filter: active when its text is non-empty and valid; invalid shows `filter_error` and hides
	// nothing. `files` holds only the files it shows: `hidden_count` of `total_files` are left out.
	filter_active, filter_invalid: bool,
	filter_error: string,
	hidden_count, total_files: int,
	filter_editor: ^Text_Field,
	// Bumps whenever the content changes, so the cached row layout refreshes.
	revision:    u64,
}

Changes_Part :: enum u8 {
	None,
	Scope,
	Worktree,
	Hooks,
	Notice_Button,
	File_Header,
	Diff,
	Strip_Bar,
	Step_Back,
	Step_Forward,
	Range_Label,
	Turn_List_Row,
	Line,
	Hunk_Comment,
	Comment_Button,
	Comment_Card,
	Comment_Delete,
	Comment_Editor,
	Send,
	Copy,
	Discard,
	Files_Button,
	Layout_Button,
	Filter_Button,
	Filter_Field,
	Filter_Clear,
	Filter_Bar_Clear,
}

// What a point is over. `index` is the bar or list row for the strip parts, the file for File_Header,
// Diff, Line and Hunk_Comment (-1 below the last file), and the comment for the comment parts; `line`
// is the flat line in file `index`.
Changes_Hit :: struct {
	part:  Changes_Part,
	index: int,
	line:  int,
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
	// The diff width and Body line height the comment cards were wrapped at.
	width, body_line:                       f32,
	comments_key:                           u64,
	header, hunk, line, note, gap, footer:  int,
	// The top of each file, then the end of the last one.
	tops:                                   [dynamic]int,
	// The height of each comment card, measured by changes_cards_measure.
	cards:                                  [dynamic]int,
	// The "Not in this diff" group at the end of the stream.
	detached:                               int,
	// Each file's rows of diff lines, in either layout.
	pairs:                                  Changes_Pairs,
	total:                                  int,
}

// Per pane. The pane owns it and frees it with changes_state_destroy.
Changes_State :: struct {
	diff_scroll:              int,
	// Strip bars hidden at the left, and the turn list's scroll in pixels.
	strip_offset:             int,
	// The strip's bar room, turn count and selection at the last draw: when any changes, the draw
	// reveals the selection again, so a resize or a pane drawn after a tab switch keeps it in view.
	strip_seen_bars:          int,
	strip_seen_turns:         int,
	strip_seen_first:         int,
	turn_list_scroll:         int,
	turn_list_open:           bool,
	hover, press:             Changes_Hit,
	// The control whose hover and press `motion` plays: it keeps fading after the pointer leaves.
	lit:                      Changes_Hit,
	// The scope's list is open, so its field stays outlined.
	scope_open:               bool,
	// The worktree list is open.
	worktree_open:            bool,
	// The file list is open, so its button stays outlined.
	files_open:               bool,
	// The filter popover is open, so its button stays outlined.
	filter_open:              bool,
	motion:                   Control_Motion,
	rows:                     Changes_Rows,
	turn_list_bar, diff_bar:  Scroll_Drag,
}

changes_state_destroy :: proc(state: ^Changes_State) {
	delete(state.rows.tops)
	delete(state.rows.cards)
	changes_pairs_destroy(&state.rows.pairs)
	state.rows = {}
}

// Where everything goes, in window pixels. `diff` holds the diff stream or the notice and is the area
// the pane scrollbar belongs to. The strip, its step buttons and the range label are empty in git scopes.
Changes_Geometry :: struct {
	area, toolbar, scope, worktree, hooks, repository, diff, notice, notice_button: render.Rect,
	strip, step_back, step_forward, range_label:                                   render.Rect,
	// Where the turn list goes under the range label while state.turn_list_open; empty without turns.
	turn_list:                                                                     render.Rect,
	// The comments' send bar under the diff; empty without comments.
	send_bar:                                                                      render.Rect,
	// The filter, layout and file list buttons at the toolbar's right end, in every scope.
	filter_button, layout_button, files_button:                                    render.Rect,
	// The filter popover under its button, with its field and the field's clear button; where it goes
	// whenever there is a filter button, and shown only while state.filter_open.
	filter_popover, filter_field, filter_clear:                                   render.Rect,
	// The row under the toolbar while the filter hides files, and its Clear button.
	filter_bar, filter_bar_clear:                                                 render.Rect,
	scale, turn_row:                                                               f32,
	// How many bars the strip has room for.
	strip_bars:                                                                    int,
}

@(private = "file")
CHANGES_TURN_ROW_HEIGHT :: f32(40)
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
	end := area.x + area.width - pad
	// The filter, layout and file list buttons hold the right end, all three or none; everything else
	// fits before them.
	buttons := 3 * control + 2 * SPACE_1 * s
	if room >= buttons {
		g.files_button = {end - control, top, control, control}
		g.layout_button = {g.files_button.x - SPACE_1 * s - control, top, control, control}
		g.filter_button = {g.layout_button.x - SPACE_1 * s - control, top, control, control}
		end = g.filter_button.x - gap
		room = max(0, room - buttons - gap)
	}
	body_text := text_styled(text, .Body)
	hooks_width: f32
	if view.hooks_offer {
		hooks_width = min(text_width(&body_text, CHANGES_HOOKS_LABEL) + 2 * SPACE_3 * s, room / 2)
	}
	scope_room := room - hooks_width - (hooks_width > 0 ? gap : 0)
	g.scope = {area.x + pad, top, min(CHANGES_SCOPE_WIDTH * s, max(0, scope_room)), control}
	if hooks_width > 0 {g.hooks = {end - hooks_width, top, hooks_width, control}}
	left := g.scope.x + g.scope.width + gap
	right := hooks_width > 0 ? g.hooks.x - gap : end
	if changes_scope_turns(view.scope) {
		left = strip_place(&g, view, &body_text, left, right, top, control)
	} else {
		g.worktree = {left, top, min(CHANGES_WORKTREE_WIDTH * s, max(0, right - left)), control}
		if g.worktree.width > 0 {left += g.worktree.width + gap}
	}
	g.repository = {left, g.toolbar.y, max(0, right - left), g.toolbar.height}

	body := render.Rect{area.x, g.toolbar.y + g.toolbar.height, area.width, 0}
	if view.filter_active && view.hidden_count > 0 {
		filter_bar_place(&g, text, body.y)
		body.y += g.filter_bar.height
	}
	body.height = max(0, area.y + area.height - body.y)
	if g.filter_button.width > 0 {filter_popover_place(&g, view, text)}
	send := min(changes_send_bar_height(view, s), body.height)
	g.diff = {body.x, body.y, body.width, body.height - send}
	if send > 0 {g.send_bar = {body.x, body.y + body.height - send, body.width, send}}
	if changes_scope_turns(view.scope) {turn_list_place(&g, view)}
	if view.notice != .None {changes_notice_place(&g, view, text, &body_text)}
	return g
}

// Centres the notice in the diff area. With comments it sits at the top instead, and the diff area
// shrinks to below it: the stream then holds only the comments, so they can still be read, edited and
// deleted while no diff shows.
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
	if len(view.comments) > 0 {
		y = math.round(g.diff.y + SPACE_6 * s)
		below := math.round(y + height + SPACE_4 * s)
		g.diff = {g.diff.x, below, g.diff.width, max(0, g.diff.y + g.diff.height - below)}
	}
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

// Refreshes the cached rows when the content, the line height, the width or the scale changed.
// Collapsing and comments are the pane's own state, so they are part of the key too. `text` wraps the
// comment cards at `width`, the diff area's width.
changes_layout :: proc(state: ^Changes_State, view: ^Changes_View, text, mono: ^Text, width, scale: f32) {
	rows := &state.rows
	key := collapsed_key(view)
	comments := changes_comments_key(view)
	if rows.valid && rows.revision == view.revision && rows.collapsed_key == key &&
	   rows.notice == view.notice && rows.files == len(view.files) && rows.omitted == view.omitted &&
	   rows.line_height == mono.line_height && rows.scale == scale && rows.width == width &&
	   rows.body_line == text.line_height && rows.comments_key == comments &&
	   rows.pairs.side_by_side == view.side_by_side {return}
	rows.valid, rows.revision, rows.collapsed_key, rows.notice = true, view.revision, key, view.notice
	rows.files, rows.omitted = len(view.files), view.omitted
	rows.scale, rows.line_height = scale, mono.line_height
	rows.width, rows.body_line, rows.comments_key = width, text.line_height, comments
	rows.header = int(math.round(HEIGHT_STANDARD * scale))
	rows.line = max(1, int(mono.line_height) + int(math.round(2 * scale)))
	rows.hunk = rows.line + int(math.round(SPACE_1 * scale))
	rows.note = int(math.round(HEIGHT_COMPACT * scale))
	rows.gap = int(math.round(SPACE_2 * scale))
	rows.footer = int(math.round(HEIGHT_STANDARD * scale))
	changes_pairs_build(&rows.pairs, view)
	changes_cards_measure(rows, view, text)
	clear(&rows.tops)
	y := 0
	if view.notice == .None {
		for i in 0 ..< len(view.files) {
			append(&rows.tops, y)
			y += rows.header
			if !changes_collapsed(view, i) {y += file_body_height(rows, view, i)}
			y += rows.gap
		}
	}
	append(&rows.tops, y)
	rows.total = y
	if view.notice == .None && view.omitted > 0 {rows.total += rows.footer}
	rows.detached = changes_detached_height(rows, view)
	rows.total += rows.detached
}

changes_diff_extent :: proc(state: ^Changes_State, g: Changes_Geometry) -> Scroll_Extent {
	visible := int(g.diff.height)
	return {
		total = state.rows.total,
		visible = visible,
		offset = clamp(state.diff_scroll, 0, max(0, state.rows.total - visible)),
	}
}

changes_scroll_diff :: proc(state: ^Changes_State, g: Changes_Geometry, delta: int) -> bool {
	limit := max(0, state.rows.total - int(g.diff.height))
	before := state.diff_scroll
	state.diff_scroll = clamp(before + delta, 0, limit)
	return state.diff_scroll != before
}

// What lies at the point: the open filter popover and turn list first, then the toolbar and the filter
// bar, then the diff area and the send bar. Needs the rows of the latest changes_layout.
changes_hit :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, x, y: f32,
) -> Changes_Hit {
	if state.filter_open && render.rect_contains(g.filter_popover, x, y) {
		if render.rect_contains(g.filter_clear, x, y) {return {.Filter_Clear, 0, 0}}
		if render.rect_contains(g.filter_field, x, y) {return {.Filter_Field, 0, 0}}
		return {.Filter_Field, -1, 0}
	}
	if state.turn_list_open && render.rect_contains(g.turn_list, x, y) {
		return {.Turn_List_Row, turn_list_row_at(g, state, view, y), 0}
	}
	if render.rect_contains(g.scope, x, y) {return {.Scope, 0, 0}}
	if render.rect_contains(g.worktree, x, y) {return {.Worktree, 0, 0}}
	if render.rect_contains(g.hooks, x, y) {return {.Hooks, 0, 0}}
	if render.rect_contains(g.filter_button, x, y) {return {.Filter_Button, 0, 0}}
	if render.rect_contains(g.layout_button, x, y) {return {.Layout_Button, 0, 0}}
	if render.rect_contains(g.files_button, x, y) {
		return changes_files_listed(view) ? {.Files_Button, 0, 0} : {}
	}
	back, forward := changes_step_enabled(view)
	if render.rect_contains(g.step_back, x, y) {return back ? {.Step_Back, 0, 0} : {}}
	if render.rect_contains(g.step_forward, x, y) {return forward ? {.Step_Forward, 0, 0} : {}}
	if render.rect_contains(g.strip, x, y) {
		if bar := strip_bar_at(g, state, view, x); bar >= 0 {return {.Strip_Bar, bar, 0}}
		return {}
	}
	if render.rect_contains(g.range_label, x, y) {return {.Range_Label, 0, 0}}
	if render.rect_contains(g.filter_bar_clear, x, y) {return {.Filter_Bar_Clear, 0, 0}}
	if render.rect_contains(g.notice_button, x, y) {return {.Notice_Button, 0, 0}}
	return changes_diff_hit(g, view, state, x, y)
}

@(private = "file")
changes_animated :: proc(hit: Changes_Hit) -> bool {
	#partial switch hit.part {
	case .Scope, .Worktree, .Hooks, .Notice_Button, .File_Header, .Step_Back, .Step_Forward, .Range_Label,
	     .Hunk_Comment, .Comment_Button, .Comment_Delete, .Send, .Copy, .Discard, .Files_Button,
	     .Layout_Button, .Filter_Button, .Filter_Clear, .Filter_Bar_Clear:
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
		hover, press := changes_lit(state, {.Notice_Button, 0, 0})
		return primary_button_draw(
			list, text, theme, g.notice_button, CHANGES_RECORD_LABEL, hover, press, false, g.scale, pointer,
		)
	}
	return .Ok
}

// Draws the pane. `spin_phase` places the working spinner of a live turn; `spinning` reports that one
// was drawn, so the caller keeps frames coming while it turns.
changes_draw :: proc(
	list: ^render.Draw_List,
	text, mono: ^Text,
	theme: ^Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	scale: f32,
	pointer: [2]f32,
	spin_phase: f32,
) -> (
	status: render.Build_Status,
	spinning: bool,
) {
	t := theme^
	strip_follow(state, g, view)
	state.turn_list_scroll = clamp(state.turn_list_scroll, 0, turn_list_limit(g, view))
	state.diff_scroll = clamp(state.diff_scroll, 0, max(0, state.rows.total - int(g.diff.height)))
	status, spinning = toolbar_draw(list, text, t, g, view, state, pointer, spin_phase)
	if status != .Ok {return}
	if status = filter_bar_draw(list, text, t, g, view, state, pointer); status != .Ok {return}
	if view.notice != .None {
		if status = notice_draw(list, text, t, g, view, state, pointer); status != .Ok {return}
	}
	if status = diff_draw(list, text, mono, t, g, view, state, pointer); status != .Ok {return}
	if status = changes_send_bar_draw(list, text, t, g, view, state, pointer); status != .Ok {return}
	listed: bool
	status, listed = turn_list_draw(list, text, t, g, view, state, pointer, spin_phase)
	if status != .Ok {return}
	status = filter_popover_draw(list, text, t, g, view, state, pointer)
	return status, spinning || listed
}

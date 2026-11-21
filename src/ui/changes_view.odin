package ui

import "aio:font"
import "aio:markdown"
import "aio:render"
import "aio:syntax"
import tr "aio:turns"
import "core:math"
import "core:mem/virtual"

// The Agent changes pane: a header row at the top (a summary of what the pane shows on the left; the layout,
// fold, filter and select lines buttons and a chevron button on the right), a panel under the summary for
// the source, the worktree, the turn strip and the file list, then one diff stream across the pane with an
// overview strip at its right edge. The pane keeps the model and the scroll state; this file lays the
// view out, draws it and answers where a point lands. Heights of the diff stream are cached in whole pixels,
// so scrolling and hit testing agree with what is drawn.

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

// What a note asks of the agent: a comment, a quick label's request, or the deletion of its lines.
Changes_Note_Kind :: enum u8 {
	Comment,
	Label,
	Delete,
}

// Which cell of a side-by-side row something is in. A context line is drawn in both, and a selection or a
// note made in one marks only that one; `Both` is the whole row of the unified layout, and a selection or a
// note that was not made in either cell, such as a hunk's.
Changes_Half :: enum u8 {
	Both,
	Left,
	Right,
}

// Flat line indices within one file: the file's diff lines in hunk order, as syntax.File_Lines and
// comments count them. A `partial` selection is of text rather than whole lines: it starts at byte
// `first_offset` of the first line's text and ends at `last_offset` of the last line's. `half` is the cell
// side by side it was made in.
Changes_Selection :: struct {
	file, first, last:         int,
	active:                    bool,
	partial:                   bool,
	first_offset, last_offset: int,
	half:                      Changes_Half,
}

// A note as the diff shows it. `detached`: its lines are not in this diff. The offsets and `half` are a
// selection's, as above. A label note names its label and gives its colour, a preset name or #rrggbb.
Changes_Comment_View :: struct {
	file, first, last:         int,
	text:                      string,
	detached:                  bool,
	kind:                      Changes_Note_Kind,
	partial:                   bool,
	first_offset, last_offset: int,
	half:                      Changes_Half,
	label_name, label_colour:  string,
}

// The send bar: how many notes, which agent they go to, and why Send is off when it is.
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
	// The label of the source: the agent's name, All agents or the git scope.
	source_label: string,
	// The name of the repository a turn scope shows; the harness reports it.
	repository:   string,
	// The folder name of the worktree a git scope shows, and whether it was chosen by following the agent.
	worktree:    string,
	following:   bool,
	// The source chips: one label per agent, then All agents and the git scopes, borrowed from the pane.
	// `source_current` is the lit one (-1 for none); `source_agent` the pane's own agent among the
	// repository's agents, which tints the summary's dot (-1 when unknown).
	sources:      []string,
	source_current, source_agent: int,
	// The worktree chips of a git scope: "Follow the agent", then one per worktree, borrowed from the pane;
	// `worktree_current` is the lit one.
	worktree_labels: []string,
	worktree_current: int,
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
	// -1 when no note is being written; an index into `comments` edits that one; len(comments) writes a
	// new one below the selection. The editor is a text area over `buffer`, and `draft` is the kind the
	// note will have when saved: a label or deletion tag the editor's × removes makes it a comment.
	editing:     int,
	editor:      ^Text_Area,
	buffer:      ^markdown.Edit_Buffer,
	draft:       Changes_Note_Kind,
	// The line numbers and side of the note being written or edited, which the editor's header names.
	span:        Changes_Span,
	send:        Changes_Send_View,
	// The Select lines toggle is on, and Alt is down: either makes a press pick whole lines, and the rows
	// under the pointer show it.
	select_lines, alt: bool,
	// A selection drag is in progress, which hides the selection toolbar until it ends.
	selecting:   bool,
	// The label menu under the toolbar is open, and the row the keys are on. `quick_labels` is the
	// turns.quick_labels setting's value; the menu reads its labels from it as it draws and hit tests.
	label_menu:  bool,
	label_row:   int,
	quick_labels: string,
	// The least WCAG contrast code text and signs keep against the row they sit on; 1 or less keeps the
	// theme's colours.
	minimum_contrast: f32,
	// Long lines wrap to the pane's width instead of scrolling sideways (turns.diff_long_lines).
	wrap: bool,
	// Show the "Install turn hooks" button in the panel.
	hooks_offer: bool,
	// Old and new side by side rather than one unified stream; the pane's own choice.
	side_by_side: bool,
	// The diff filter: active when its text is non-empty and valid; invalid shows `filter_error` and hides
	// nothing. `files` holds only the files it shows: `hidden_count` of `total_files` are left out.
	filter_active, filter_invalid: bool,
	filter_error: string,
	hidden_count, total_files: int,
	// Lines added and removed in the files shown, and in every file of the result.
	shown_added, shown_removed, total_added, total_removed: int,
	filter_editor: ^Text_Field,
	// The saved filters the filter text holds as tokens, in order, as the field draws them; `filter_unknown`
	// is the label of the first that names no saved filter, "" when there is none.
	filter_tokens: []Filter_Token,
	filter_unknown: string,
	// The saved filters list is open: what it offers, and the row the keys are on. `filter_savable` is
	// whether the text holds terms to save, `filter_notice` why saving was refused, and `filter_on_labels`
	// what the bar names as filtering ("@one + @two"), "" while no token is on.
	filter_pick_open: bool,
	filter_picks: []Filter_Pick,
	filter_pick_row: int,
	filter_savable: bool,
	filter_notice: string,
	filter_on_labels: string,
	// Some shown file is expanded, so the fold button collapses every file rather than expanding them.
	any_expanded: bool,
	// Bumps whenever the content changes, so the cached row layout refreshes.
	revision:    u64,
}

Changes_Part :: enum u8 {
	None,
	Hooks,
	Notice_Button,
	File_Header,
	// A file header's Edit in Neovim button.
	File_Edit,
	Diff,
	Strip_Bar,
	Step_Back,
	Step_Forward,
	Range_Label,
	Turn_List_Row,
	Line,
	// A press that picks a line from its number or sign; one on the code text starts a text selection.
	Gutter,
	Hunk_Select,
	// The note editor's tools and buttons.
	Editor_Untag,
	Editor_Bold,
	Editor_Code,
	Editor_Block,
	Editor_Suggest,
	Editor_Cancel,
	Editor_Save,
	// A note card, and the Edit and Remove buttons on it; and the text area of the editor card.
	Comment_Card,
	Comment_Edit,
	Comment_Remove,
	Comment_Editor,
	Send,
	Copy,
	Discard,
	Layout_Button,
	Filter_Button,
	Filter_Field,
	Filter_Clear,
	// The field's @ button, a row of the saved filters list, and the buttons that save the text as a filter and
	// open Settings on the saved filters.
	Filter_At,
	Filter_Pick,
	Filter_Save,
	Filter_Manage,
	Filter_Bar_Clear,
	Fold_Button,
	Select_Lines_Button,
	Wrap_Button,
	Split_Divider,
	Sticky_Header,
	Strip_Older,
	Strip_Newer,
	// The row's summary, which opens the panel, and the files button, which opens the file list.
	Summary,
	Files_Button,
	// The one ⋯ button that holds the layout, fold and filter buttons when the row is short of room, and the
	// rows of its menu.
	Tools_Button,
	Tools_Row,
	// The selection toolbar's buttons and its padding, and the label menu's rows and padding (index -1).
	Toolbar,
	Toolbar_Delete,
	Toolbar_Comment,
	Toolbar_Label,
	Label_Menu,
	Label_Row,
	Label_Edit,
	// A chip of the panel's Source and Worktree sections.
	Source_Chip,
	Worktree_Chip,
	// The overview strip at the right edge of the diff.
	Overview,
	// The scrollbar along the diff's bottom edge, which scrolls the code sideways.
	H_Scroll,
}

// What a point is over. `index` is the bar or list row for the strip parts; the file for File_Header,
// Sticky_Header, Diff, Line, Gutter and Hunk_Select (-1 below the last file); the comment for the comment
// parts; the chip for Source_Chip and Worktree_Chip; the row for Tools_Row (-1 on the menu's padding); the
// label for Label_Row (-1 on Label_Menu's padding); -1 for Filter_Field on the filter popover's padding;
// else 0, as for the row's buttons (Fold_Button, Filter_Button, Layout_Button, ...). `line` is the flat
// line in file `index`.
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
	// The diff width and Body line height the comment cards were wrapped at, and the width of the editor's
	// tag, which the × after it sits at the end of.
	width, body_line, tag_width:            f32,
	// The body font the cards were wrapped in: its size and family move word widths whatever the line height.
	body_size:                              f32,
	body_family:                            font.Family,
	comments_key:                           u64,
	// How many times the rows were laid out, for tests that show a drag step or a keystroke does not.
	built:                                  int,
	header, hunk, line, note, gap, footer:  int,
	// How far a digit of the diff's text advances, so a hit test can tell the gutter from the code.
	digit:                                  f32,
	// The top of each file, then the end of the last one.
	tops:                                   [dynamic]int,
	// The height of each comment card, measured by changes_cards_measure.
	cards:                                  [dynamic]int,
	// What each saved note's card was laid out as when it was measured, by card number (the editor's and
	// absent cards' are empty). Its text layout, excerpt and syntax colours live in `notes_arena`, which
	// is emptied whenever the cards are measured again and freed with changes_state_destroy.
	notes:                                  [dynamic]Note_Plan,
	notes_arena:                            virtual.Arena,
	// What the overview strip draws: runs of added and removed lines and the comment cards, by their place in
	// the stream, rebuilt with the rows.
	ticks:                                  [dynamic]Changes_Tick,
	// The "Not in this diff" group at the end of the stream.
	detached:                               int,
	// Each file's rows of diff lines, in either layout.
	pairs:                                  Changes_Pairs,
	// The widest line of every file, for the sideways scroll.
	widths:                                 Changes_Widths,
	// Left cell's width in pixels. Zero in unified view.
	split_left:                             f32,
	// Whether long lines wrap (the view's `wrap` as of the last layout), and where they break.
	wrapped:                                bool,
	wrap:                                   Changes_Wrap,
	total:                                  int,
}

// Per pane. The pane owns it and frees it with changes_state_destroy.
Changes_State :: struct {
	// How many text columns the code is scrolled sideways; each file holds it at its own limit.
	h_scroll:                 int,
	h_bar:                    Scroll_Drag,
	diff_scroll:              int,
	// Fraction of the available code width given to the left cell; zero means centered.
	split:                    f32,
	// Strip bars hidden at the left, and the turn list's scroll in pixels.
	strip_offset:             int,
	// The strip's room, turn count and selection at the last draw: when any changes, the draw reveals the
	// selection again, so a resize or a pane drawn after a tab switch keeps it in view. The room, not the
	// bar count, because the bars change with the offset as markers come and go.
	strip_seen_room:          f32,
	strip_seen_turns:         int,
	strip_seen_first:         int,
	turn_list_scroll:         int,
	turn_list_open:           bool,
	hover, press:             Changes_Hit,
	// The control whose hover and press `motion` plays: it keeps fading after the pointer leaves.
	lit:                      Changes_Hit,
	// The panel is open, so the summary's panel stays shown.
	panel_open:               bool,
	// The file list is open, so the files button stays lit.
	files_open:               bool,
	// The ⋯ menu is open, so its button stays lit.
	tools_open:               bool,
	// The filter popover is open, so its button stays outlined.
	filter_open:              bool,
	motion:                   Control_Motion,
	rows:                     Changes_Rows,
	// Code text colours raised to `minimum_contrast` per row background, kept while the theme and ratio hold.
	inks:                     Changes_Inks,
	turn_list_bar:            Scroll_Drag,
	// The overview strip's thumb, held: where the pointer grabbed it.
	overview_drag:            Scroll_Drag,
}

changes_state_destroy :: proc(state: ^Changes_State) {
	delete(state.rows.tops)
	delete(state.rows.cards)
	delete(state.rows.ticks)
	delete(state.rows.widths.code)
	delete(state.rows.widths.head)
	wrap_free(&state.rows.wrap)
	delete(state.rows.notes)
	virtual.arena_destroy(&state.rows.notes_arena)
	changes_pairs_destroy(&state.rows.pairs)
	state.rows = {}
}

// Where everything goes, in window pixels. `diff` holds the diff stream or the notice, left of the overview
// strip. The summary and the buttons sit in the row; the panel, with its chips, hooks button and turn strip,
// is laid out whether or not it is open, and the strip, its step buttons and the range label are empty in
// git scopes. The chip slices live in temporary memory, valid until the frame's temporary memory is freed.
Changes_Geometry :: struct {
	area, row, hooks, diff, notice, notice_button: render.Rect,
	// The header row: its summary (one hit part), the view buttons and the files button at the right end.
	// The view buttons are empty while `row_steps` is 1 or more, when `tools_button` stands for them.
	summary:                                        render.Rect,
	using view_buttons:                             Row_Button_Rects,
	tools_button, files_button:                     render.Rect,
	// How far the row's collapse ladder went, 0 to 5: 1 the buttons became one, 2 the files button lost its
	// word, 3 the totals went, 4 the agent name, 5 the range got short.
	row_steps:                                     int,
	// The ⋯ menu under the tools button and its rows; empty without that button.
	tools_menu:                                     render.Rect,
	tools_rows:                                     [CHANGES_TOOLS_ROWS]render.Rect,
	// The panel under the summary, its section captions, the chips of its Source and Worktree sections, and the
	// line under the strip that names the selected turns.
	panel:                                          render.Rect,
	source_caption, worktree_caption, turns_caption, turn_title: render.Rect,
	source_chips, worktree_chips:                   []render.Rect,
	strip, step_back, step_forward, range_label:    render.Rect,
	// The strip's "+N" markers for older (left) and newer (right) turns it can't show at the offset the
	// layout was given; empty for a side that hides none.
	strip_older, strip_newer:                       render.Rect,
	// Where the turn list goes under the range label while state.turn_list_open; empty without turns.
	turn_list:                                      render.Rect,
	// The comments' send bar under the diff; empty without comments.
	send_bar:                                       render.Rect,
	// The selection toolbar and the label menu under it; empty while no toolbar shows. Placed by
	// changes_selection_place, which needs the laid out rows.
	selection_bar:                                  Changes_Selection_Bar,
	// The filter popover under the filter button, or under ⋯ while the buttons are collapsed, with its field
	// and the field's clear button; where it goes whenever there is such a button, and shown only while
	// state.filter_open.
	filter_popover, filter_field, filter_clear:     render.Rect,
	// The field's @ button; the list of saved filters under the field while it is open (its header, rows and
	// empty message) and the rows themselves, in temporary memory, with the index the first one stands for;
	// and the Save and Manage buttons at the popover's foot.
	filter_at:                                      render.Rect,
	filter_list:                                    render.Rect,
	filter_picks:                                   []render.Rect,
	filter_pick_first:                              int,
	filter_save, filter_manage:                     render.Rect,
	// The row under the header row while the filter hides files, and its Clear button.
	filter_bar, filter_bar_clear:                   render.Rect,
	// The overview strip at the diff's right edge; empty under a notice.
	overview:                                       render.Rect,
	scale, turn_row:                                f32,
	// The strip's room before any marker takes some: it changes only with the pane and the panel.
	strip_room:                                     f32,
	// How many bars the strip has room for.
	strip_bars:                                     int,
}

@(private = "file")
CHANGES_TURN_ROW_HEIGHT :: f32(40)
@(private)
CHANGES_ROW_HEIGHT :: HEIGHT_STANDARD
@(private)
CHANGES_OVERVIEW_WIDTH :: f32(12)
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
		body = "Turns appear here when an agent in this repository changes files."
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

// Lays the pane out. `state` gives the strip's offset, which decides which of its "+N" markers take room;
// without it the strip is laid out scrolled to the oldest turn. The panel and the strip in it are laid out
// whether or not the panel is open, so the keys that step through turns never depend on it.
changes_geometry :: proc(
	area: render.Rect, scale: f32, view: ^Changes_View, text: ^Text, state: ^Changes_State = nil,
) -> Changes_Geometry {
	s := scale
	g := Changes_Geometry {
		area     = area,
		scale    = s,
		turn_row = math.round(CHANGES_TURN_ROW_HEIGHT * s),
	}
	g.row = {area.x, area.y, area.width, min(math.round(CHANGES_ROW_HEIGHT * s), area.height)}
	lane := math.round(CHANGES_OVERVIEW_WIDTH * s)
	if view.notice != .None || area.width < 8 * lane {lane = 0}
	body_text := text_styled(text, .Body)
	row_place(&g, view, text)
	panel_place(&g, view, text, &body_text, state)

	body := render.Rect{area.x, g.row.y + g.row.height, area.width, 0}
	if view.filter_active && view.hidden_count > 0 {
		filter_bar_place(&g, text, body.y)
		body.y += g.filter_bar.height
	}
	body.height = max(0, area.y + area.height - body.y)
	if g.filter_button.width > 0 || g.tools_button.width > 0 {filter_popover_place(&g, view, text)}
	send := min(changes_send_bar_height(view, s), body.height)
	g.diff = {body.x, body.y, body.width, body.height - send}
	if send > 0 {g.send_bar = {body.x, body.y + body.height - send, body.width, send}}
	if lane > 0 && g.diff.height > 0 {
		g.overview = {g.diff.x + g.diff.width - lane, g.diff.y, lane, g.diff.height}
		g.diff.width -= lane
	}
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
	changes_widths_build(&rows.widths, view, mono)
	key := collapsed_key(view)
	comments := changes_comments_key(view)
	digit := text_width(mono, "0")
	split_left := f32(0)
	if view.side_by_side {
		band := max(0, width - 2 * SPACE_2 * scale)
		split_left = split_position(band, scale, state.split)
	}
	same := rows.valid && rows.revision == view.revision && rows.collapsed_key == key &&
	   rows.notice == view.notice && rows.files == len(view.files) && rows.omitted == view.omitted &&
	   rows.line_height == mono.line_height && rows.digit == digit && rows.scale == scale &&
	   rows.width == width && rows.body_line == text.line_height && rows.comments_key == comments &&
	   rows.body_size == text.size_px && rows.body_family == text.family &&
	   rows.pairs.side_by_side == view.side_by_side && rows.wrapped == view.wrap &&
	   !editor_stale(rows, view, text)
	if same && (!view.wrap || rows.split_left == split_left) {
		rows.split_left = split_left
		return
	}
	// A change of width, scale, font or mode that rewraps the rows keeps the row at the top of the diff there.
	anchor: Changes_Anchor
	if (rows.wrapped || view.wrap) && rows.valid && rows.revision == view.revision &&
	   rows.collapsed_key == key && rows.notice == view.notice && rows.files == len(view.files) &&
	   view.notice == .None && (rows.width != width || rows.scale != scale || rows.digit != digit ||
	   rows.line_height != mono.line_height || rows.wrapped != view.wrap ||
	   rows.pairs.side_by_side != view.side_by_side || rows.split_left != split_left) {
		anchor = changes_anchor_find(rows, view, state.diff_scroll)
	}
	rows.built += 1
	rows.valid, rows.revision, rows.collapsed_key, rows.notice = true, view.revision, key, view.notice
	rows.files, rows.omitted = len(view.files), view.omitted
	rows.scale, rows.line_height, rows.digit = scale, mono.line_height, digit
	rows.width, rows.body_line, rows.comments_key = width, text.line_height, comments
	rows.body_size, rows.body_family = text.size_px, text.family
	rows.header = int(math.round(HEIGHT_STANDARD * scale))
	rows.line = max(1, int(mono.line_height) + int(math.round(2 * scale)))
	rows.hunk = rows.line + int(math.round(SPACE_1 * scale))
	rows.note = int(math.round(HEIGHT_COMPACT * scale))
	rows.gap = int(math.round(SPACE_2 * scale))
	rows.footer = int(math.round(HEIGHT_STANDARD * scale))
	changes_pairs_build(&rows.pairs, view)
	rows.wrapped = view.wrap
	rows.split_left = split_left
	changes_wrap_build(rows, view, mono, max(0, width - 2 * SPACE_2 * scale))
	if !same {changes_cards_measure(rows, view, text, mono)}
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
	changes_ticks_build(rows, view)
	if anchor.ok {
		if at, placed := changes_anchor_place(rows, view, anchor); placed {
			state.diff_scroll = clamp(at, 0, rows.total)
		}
	}
}

changes_scroll_diff :: proc(state: ^Changes_State, g: Changes_Geometry, delta: int) -> bool {
	limit := max(0, state.rows.total - int(g.diff.height))
	before := state.diff_scroll
	state.diff_scroll = clamp(before + delta, 0, limit)
	return state.diff_scroll != before
}

// What lies at the point: the open filter popover, ⋯ menu and turn list first, then the open panel, the
// row and the filter bar, then the overview strip, the diff area and the send bar. Needs the rows of the
// latest changes_layout.
changes_hit :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, x, y: f32,
) -> Changes_Hit {
	if state.filter_open && render.rect_contains(g.filter_popover, x, y) {
		if render.rect_contains(g.filter_clear, x, y) {return {.Filter_Clear, 0, 0}}
		if render.rect_contains(g.filter_at, x, y) {return {.Filter_At, 0, 0}}
		if render.rect_contains(g.filter_field, x, y) {return {.Filter_Field, 0, 0}}
		if render.rect_contains(g.filter_save, x, y) {return {.Filter_Save, 0, 0}}
		if render.rect_contains(g.filter_manage, x, y) {return {.Filter_Manage, 0, 0}}
		for row, i in g.filter_picks {
			if render.rect_contains(row, x, y) {return {.Filter_Pick, g.filter_pick_first + i, 0}}
		}
		return {.Filter_Field, -1, 0}
	}
	if state.tools_open && render.rect_contains(g.tools_menu, x, y) {
		for row, i in g.tools_rows {
			if render.rect_contains(row, x, y) {
				return changes_row_button_entry(view, Row_Button(i)).enabled ? {.Tools_Row, i, 0} : {}
			}
		}
		return {.Tools_Row, -1, 0}
	}
	if state.turn_list_open && render.rect_contains(g.turn_list, x, y) {
		return {.Turn_List_Row, turn_list_row_at(g, state, view, y), 0}
	}
	if state.panel_open && render.rect_contains(g.panel, x, y) {return panel_hit(g, view, state, x, y)}
	if render.rect_contains(g.summary, x, y) {return {.Summary, 0, 0}}
	if button, ok := changes_row_button_at(g, x, y); ok {
		parts := CHANGES_ROW_BUTTON_PARTS
		return changes_row_button_entry(view, button).enabled ? {parts[button], 0, 0} : {}
	}
	if render.rect_contains(g.tools_button, x, y) {return {.Tools_Button, 0, 0}}
	if render.rect_contains(g.files_button, x, y) {
		return changes_files_listed(view) ? {.Files_Button, 0, 0} : {}
	}
	if render.rect_contains(g.filter_bar_clear, x, y) {return {.Filter_Bar_Clear, 0, 0}}
	if render.rect_contains(g.notice_button, x, y) {return {.Notice_Button, 0, 0}}
	if render.rect_contains(g.overview, x, y) {return {.Overview, 0, 0}}
	return changes_diff_hit(g, view, state, x, y)
}

@(private = "file")
changes_animated :: proc(hit: Changes_Hit) -> bool {
	if _, button := changes_row_button_of(hit.part); button {return true}
	#partial switch hit.part {
	case .Hooks, .Notice_Button, .File_Header, .File_Edit, .Step_Back, .Step_Forward, .Range_Label, .Hunk_Select,
	     .Comment_Edit, .Comment_Remove, .Editor_Untag, .Editor_Bold, .Editor_Code, .Editor_Block,
	     .Editor_Suggest, .Editor_Cancel, .Editor_Save, .Send, .Copy, .Discard, .Filter_Clear,
	     .Filter_Bar_Clear, .Sticky_Header, .Strip_Older, .Strip_Newer, .Summary, .Files_Button, .Tools_Button,
	     .Source_Chip, .Worktree_Chip, .Toolbar_Delete, .Toolbar_Comment, .Toolbar_Label, .Label_Row,
	     .Label_Edit, .Filter_At, .Filter_Save, .Filter_Manage:
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
	// Revealing the selection moves the strip, which can add or drop a marker's slot and so change how
	// many bars fit: lay the pane out again and keep the selection in view until the strip holds still.
	// Scrolling the strip moves nothing here, so a paged or wheeled strip stays where it was put.
	g := g
	if strip_follow(state, g, view) {
		for _ in 0 ..< 3 {
			g = changes_geometry(g.area, g.scale, view, text, state)
			if !changes_strip_reveal(state, g, view) {break}
		}
	}
	state.turn_list_scroll = clamp(state.turn_list_scroll, 0, turn_list_limit(g, view))
	state.diff_scroll = clamp(state.diff_scroll, 0, max(0, state.rows.total - int(g.diff.height)))
	_ = changes_scroll_columns(state, g, view, 0)
	g.selection_bar = changes_selection_place(g, view, state, text, mono)
	rule := render.Rect{g.row.x, g.row.y + g.row.height - scale, g.row.width, scale}
	draw_rect(list, {rect = rule, color = t.border})
	if status = filter_bar_draw(list, text, t, g, view, state, pointer); status != .Ok {return}
	if view.notice != .None {
		if status = notice_draw(list, text, t, g, view, state, pointer); status != .Ok {return}
	}
	if status = diff_draw(list, text, mono, t, g, view, state, pointer); status != .Ok {return}
	if status = changes_send_bar_draw(list, text, t, g, view, state, pointer); status != .Ok {return}
	overview_draw(list, t, g, view, state, pointer)
	status, spinning = row_draw(list, text, t, g, view, state, pointer, spin_phase)
	if status != .Ok {return}
	if status = tools_menu_draw(list, text, t, g, view, state, pointer); status != .Ok {return}
	panel_spun: bool
	status, panel_spun = changes_panel_draw(list, text, t, g, view, state, pointer, spin_phase)
	if status != .Ok {return}
	listed: bool
	status, listed = turn_list_draw(list, text, t, g, view, state, pointer, spin_phase)
	if status != .Ok {return}
	status = filter_popover_draw(list, text, t, g, view, state, pointer)
	return status, spinning || panel_spun || listed
}

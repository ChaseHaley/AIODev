package main

import "aio:agent"
import "aio:commands"
import "aio:input"
import "aio:markdown"
import "aio:procinfo"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:turns"
import "aio:ui"
import "core:fmt"
import "core:strings"
import "core:time"

// Review comments on an Agent changes pane's diff lines: written in the diff, then pasted into the
// agent's pane or copied. A comment keeps its file's path, a side and that side's line numbers, so the
// next diff finds its lines again or lists it as no longer in the diff. Flat line indices count a
// file's diff lines in hunk order, as ui.Changes_Selection does.

Comment_Side :: enum u8 {
	New,
	Old,
}

Changes_Comment :: struct {
	// The path as the diff shows it: new_path, or old_path for a deleted file.
	worktree, path:                             string,
	// New when any commented line is Context or Added, else Old.
	side:                                       Comment_Side,
	// Line numbers on `side`.
	first, last:                                i32,
	// The commented diff lines with their signs (" ", "+", "-"), joined by '\n'.
	quote:                                      string,
	text:                                       string,
	// What the note asks. A label note keeps the quick label it was made with, copied so that renaming or
	// removing the label later leaves the note as it was: its name, its colour (a preset name or #rrggbb)
	// and the instruction sent with it.
	kind:                                       ui.Changes_Note_Kind,
	label_name, label_colour, label_instruction: string,
	// A note on part of its lines starts at byte `first_offset` of its first line's text and ends at
	// `last_offset` of its last line's. Whole lines are not partial, and neither is a range that spans its
	// lines' trimmed text. These index `quote`, the text as it was when the note was made, so a refreshed
	// diff never rewrites them; the view clamps a copy to the lines as they are now.
	partial:                                    bool,
	first_offset, last_offset:                  int,
	// How many diff lines it covers (a "no newline" marker is not one), so a refresh that changes the
	// lines in between is noticed.
	lines:                                      int,
	// What the view shows of a partial note: its offsets clamped to the lines as they are now, found when
	// the note is made and after each refresh, not on every layout.
	fit_partial:                                bool,
	fit_first, fit_last:                        int,
	// The cell side by side it was made in.
	half:                                       ui.Changes_Half,
	// Where it shows in the current view; file = -1 when its lines are not in this diff.
	file, first_line, last_line:                int,
}

Changes_Comments :: struct {
	items:     [dynamic]Changes_Comment,
	selection: ui.Changes_Selection,
	// The flat line a selection extends from.
	anchor:    int,
	dragging:  bool,
	// The cell side by side the selection's press was in, which the selection and a note made on it carry.
	anchor_half: ui.Changes_Half,
	// What the press that started a drag picks: characters, from byte `anchor_offset` of flat line `anchor`
	// of file `drag_file`, within the cell `drag_cell` side by side; else whole lines.
	by_text:       bool,
	anchor_offset: int,
	drag_file:     int,
	drag_cell:     render.Rect,
	// The Select lines toggle, and Alt being down: either makes a press pick whole lines.
	select_lines, alt: bool,
	// The label menu under the toolbar is open, and the row its keys are on.
	menu:          bool,
	menu_row:      int,
	// The note editor: its text, the area that wraps and draws it, and the kind the note will be saved as,
	// which the tag's × turns into a plain comment.
	buffer:    markdown.Edit_Buffer,
	area:      ui.Text_Area,
	draft:     ui.Changes_Note_Kind,
	// -1 none; an index into `items` edits that note; len(items) writes a new one at the selection.
	editing:   int,
	// The selection by path, side and line numbers, so a refreshed diff finds it again; file = -1 when
	// it holds nothing. Its quote and text are unused.
	held:      Changes_Comment,
	// What the view's comments and send target point at. Owned here rather than in temporary memory
	// because hit tests between frames read the view too.
	views:     [dynamic]ui.Changes_Comment_View,
	target:    strings.Builder,
	// The view's last send check. Every hover lays the view out, and without process polling the check
	// reads the process tree, so the view repeats it only after CHANGES_SEND_CHECK; Send checks afresh.
	checked:   time.Tick,
	can_send:  bool,
	reason:    string,
}

// Where a press on the code text landed: the byte of the line's text, the cell it is drawn in, which a text
// selection side by side stays within, and which half of a side-by-side row that is.
Changes_Text_Point :: struct {
	offset: int,
	cell:   render.Rect,
	half:   ui.Changes_Half,
}

@(private = "file")
CHANGES_SEND_CHECK :: 500 * time.Millisecond

// How many characters of a partial selection the message quotes after its line range.
@(private = "file")
CHANGES_EXCERPT_RUNES :: 100

@(private = "file")
changes_comment_release :: proc(item: ^Changes_Comment) {
	delete(item.worktree)
	delete(item.path)
	delete(item.quote)
	delete(item.text)
	delete(item.label_name)
	delete(item.label_colour)
	delete(item.label_instruction)
	item^ = {}
}

changes_comments_destroy :: proc(c: ^Changes_Comments) {
	for &item in c.items {changes_comment_release(&item)}
	delete(c.items)
	changes_comment_release(&c.held)
	markdown.edit_buffer_destroy(&c.buffer)
	ui.text_area_destroy(&c.area)
	delete(c.views)
	strings.builder_destroy(&c.target)
	c^ = {}
	c.editing = -1
}

// The worktree the shown diff's paths are relative to.
@(private = "file", require_results)
changes_comments_worktree :: proc(pane: ^Changes_Pane) -> string {
	#partial switch r in pane.model.content {
	case Result_Query:
		return r.worktree
	case Result_Plain:
		return r.worktree
	}
	return ""
}

@(private = "file", require_results)
changes_comment_path :: proc(file: turns.Diff_File) -> string {
	return file.status == .Deleted ? file.old_path : file.new_path
}

@(private = "file", require_results)
changes_side_line :: proc(line: turns.Diff_Line, side: Comment_Side) -> i32 {
	return side == .New ? line.new_line : line.old_line
}

@(private = "file", require_results)
changes_line_count :: proc(file: turns.Diff_File) -> (count: int) {
	for hunk in file.hunks {count += len(hunk.lines)}
	return
}

// A note on flat lines `first..last` of `file` as it stands there: its offsets held inside those lines'
// text and in order, and not partial when they span the trimmed text of the lines, which is the whole of
// them, or when the range no longer covers `lines` diff lines (so the offsets cannot be told apart
// between its ends). Offsets of a note that is not partial are zero. `lines` = 0 checks nothing.
@(private = "file", require_results)
changes_range_fit :: proc(
	file: turns.Diff_File,
	first, last: int,
	partial: bool,
	first_offset, last_offset: int,
	lines := 0,
) -> (
	fit: bool,
	low, high: int,
) {
	if !partial {return false, 0, 0}
	if lines > 0 && changes_span_lines(file, first, last) != lines {return false, 0, 0}
	first_text, found_first := ui.changes_line_text(file, first)
	last_text, found_last := ui.changes_line_text(file, last)
	if !found_first || !found_last {return false, 0, 0}
	low, high = clamp(first_offset, 0, len(first_text)), clamp(last_offset, 0, len(last_text))
	if first == last && high < low {low, high = high, low}
	indent := len(first_text) - len(strings.trim_left_space(first_text))
	if low <= indent && high >= len(strings.trim_right_space(last_text)) {return false, 0, 0}
	return true, low, high
}

// How many diff lines flat lines `first..last` of `file` are, not counting "no newline" markers.
@(private = "file", require_results)
changes_span_lines :: proc(file: turns.Diff_File, first, last: int) -> (count: int) {
	flat := 0
	for hunk in file.hunks {
		if flat > last {break}
		for line in hunk.lines {
			if flat >= first && flat <= last && line.kind != .No_Newline {count += 1}
			flat += 1
		}
	}
	return
}

@(private = "file", require_results)
changes_clone :: proc(s: string, failed: ^bool) -> string {
	cloned, err := strings.clone(s)
	if err != nil {failed^ = true}
	return cloned
}

// The text of flat line `flat` of `file` when it belongs to a selection or note made in `half`.
@(private = "file", require_results)
changes_half_text :: proc(
	file: turns.Diff_File,
	flat: int,
	half: ui.Changes_Half,
) -> (
	text: string,
	ok: bool,
) {
	line := ui.changes_line_at(file, flat) or_return
	return line.text, ui.changes_half_has(half, line.kind)
}

// Works out what the view shows of `item`'s partial range in `files`, once per diff.
@(private = "file")
changes_item_fit :: proc(files: []turns.Diff_File, item: ^Changes_Comment) {
	item.fit_partial, item.fit_first, item.fit_last = false, 0, 0
	if item.file < 0 || item.file >= len(files) {return}
	item.fit_partial, item.fit_first, item.fit_last = changes_range_fit(
		files[item.file], item.first_line, item.last_line, item.partial, item.first_offset, item.last_offset,
		item.lines,
	)
}

// The side and its line numbers that flat lines `first..last` of `file` cover, counting only the lines that
// belong to `half`; found = false when none of them is a line of either side.
@(private = "file", require_results)
changes_range_of :: proc(
	file: turns.Diff_File,
	first, last: int,
	half := ui.Changes_Half.Both,
) -> (
	side: Comment_Side,
	low, high: i32,
	found: bool,
) {
	new_low, new_high, old_low, old_high: i32
	flat := 0
	for hunk in file.hunks {
		if flat > last {break}
		if flat + len(hunk.lines) <= first {
			flat += len(hunk.lines)
			continue
		}
		for line in hunk.lines {
			at := flat
			flat += 1
			if at < first || at > last || !ui.changes_half_has(half, line.kind) {continue}
			#partial switch line.kind {
			case .Context:
				// A cell holds one side: the left's lines are numbered by the old file.
				if half == .Left {
					if old_low == 0 {old_low = line.old_line}
					old_high = line.old_line
				} else {
					if new_low == 0 {new_low = line.new_line}
					new_high = line.new_line
				}
			case .Added:
				if new_low == 0 {new_low = line.new_line}
				new_high = line.new_line
			case .Removed:
				if old_low == 0 {old_low = line.old_line}
				old_high = line.old_line
			}
		}
	}
	if half == .Left && old_low > 0 {return .Old, old_low, old_high, true}
	if new_low > 0 {return .New, new_low, new_high, true}
	if old_low > 0 {return .Old, old_low, old_high, true}
	return .New, 0, 0, false
}

// Flat lines `first..last` of `file` that belong to `half`, with their signs, joined by '\n', in temporary
// memory.
@(private = "file", require_results)
changes_quote :: proc(file: turns.Diff_File, first, last: int, half := ui.Changes_Half.Both) -> string {
	b := strings.builder_make(context.temp_allocator)
	flat := 0
	for hunk in file.hunks {
		for line in hunk.lines {
			at := flat
			flat += 1
			if at < first || at > last || !ui.changes_half_has(half, line.kind) {continue}
			sign: string
			switch line.kind {
			case .Context:
				sign = " "
			case .Added:
				sign = "+"
			case .Removed:
				sign = "-"
			case .No_Newline:
				continue
			}
			if strings.builder_len(b) > 0 {strings.write_byte(&b, '\n')}
			strings.write_string(&b, sign)
			strings.write_string(&b, line.text)
		}
	}
	return strings.to_string(b)
}

// Where `item`'s lines are in `files`: the file with its path whose lines on its side include its first
// and last numbers. file = -1 when they are not there.
@(private = "file", require_results)
changes_anchor_find :: proc(
	files: []turns.Diff_File,
	worktree: string,
	item: Changes_Comment,
) -> (
	file, first, last: int,
) {
	if item.worktree != worktree {return -1, 0, 0}
	for candidate, index in files {
		if changes_comment_path(candidate) != item.path {continue}
		first, last = -1, -1
		flat := 0
		for hunk in candidate.hunks {
			for line in hunk.lines {
				at := flat
				flat += 1
				number := changes_side_line(line, item.side)
				if number == 0 {continue}
				if first < 0 && number == item.first {first = at}
				if number == item.last {last = at}
			}
		}
		if first >= 0 && last >= first {return index, first, last}
		break
	}
	return -1, 0, 0
}

// The lines the editor's note is on, as its header names them: those of the note being edited, or of the
// selection a new note goes on.
@(private = "file", require_results)
changes_editor_span :: proc(pane: ^Changes_Pane) -> ui.Changes_Span {
	c := &pane.comments
	files := pane.model.view.files
	if c.editing < 0 {return {}}
	if c.editing < len(c.items) {
		item := c.items[c.editing]
		return {int(item.first), int(item.last), item.side == .Old}
	}
	s := c.selection
	if !s.active || s.file < 0 || s.file >= len(files) {return {}}
	side, low, high, found := changes_range_of(files[s.file], s.first, s.last, s.half)
	if !found {return {}}
	return {int(low), int(high), side == .Old}
}

// Points the view at the comments, the selection and the editor. Every change calls it, so a hit test
// before the next frame sees what that frame draws.
@(private = "file")
changes_comments_sync :: proc(pane: ^Changes_Pane) {
	c := &pane.comments
	view := &pane.model.view
	clear(&c.views)
	if reserve(&c.views, len(c.items)) == nil {
		for item in c.items {
			detached := item.file < 0
			partial, first_offset, last_offset := item.fit_partial, item.fit_first, item.fit_last
			append(
				&c.views,
				ui.Changes_Comment_View {
					file = item.file,
					first = item.first_line,
					last = item.last_line,
					text = item.text,
					detached = detached,
					kind = item.kind,
					partial = partial,
					first_offset = first_offset,
					last_offset = last_offset,
					half = item.half,
					label_name = item.label_name,
					label_colour = item.label_colour,
				},
			)
		}
	}
	view.comments = c.views[:]
	view.selection = c.selection
	view.editing = c.editing <= len(view.comments) ? c.editing : -1
	view.editor, view.buffer, view.draft = &c.area, &c.buffer, c.draft
	view.span = changes_editor_span(pane)
	view.select_lines, view.alt, view.selecting = c.select_lines, c.alt, c.dragging
	if !c.selection.active {c.menu = false}
	view.label_menu, view.label_row = c.menu, c.menu_row
	if len(c.items) == 0 {
		view.send = {}
	} else {
		view.send.count = len(c.items)
	}
}

// Remembers where the selection is by path, side and line numbers.
@(private = "file")
changes_selection_hold :: proc(pane: ^Changes_Pane) {
	c := &pane.comments
	files := pane.model.view.files
	held := &c.held
	held.file = -1
	s := c.selection
	if !s.active || s.file < 0 || s.file >= len(files) {return}
	file := files[s.file]
	side, low, high, found := changes_range_of(file, s.first, s.last, s.half)
	if !found {return}
	path, worktree := changes_comment_path(file), changes_comments_worktree(pane)
	if held.path != path {
		cloned, err := strings.clone(path)
		if err != nil {return}
		delete(held.path)
		held.path = cloned
	}
	if held.worktree != worktree {
		cloned, err := strings.clone(worktree)
		if err != nil {return}
		delete(held.worktree)
		held.worktree = cloned
	}
	held.side, held.first, held.last = side, low, high
	held.file, held.first_line, held.last_line = s.file, s.first, s.last
	held.partial, held.first_offset, held.last_offset = changes_range_fit(
		file, s.first, s.last, s.partial, s.first_offset, s.last_offset,
	)
	held.half = s.half
	held.lines = changes_span_lines(file, s.first, s.last)
}

@(private = "file")
changes_select_line :: proc(pane: ^Changes_Pane, file, line: int, extend: bool) {
	c := &pane.comments
	files := pane.model.view.files
	if file < 0 || file >= len(files) || line < 0 || line >= changes_line_count(files[file]) {return}
	if !extend {c.anchor = line}
	c.selection = {
		file   = file,
		first  = min(c.anchor, line),
		last   = max(c.anchor, line),
		active = true,
		half   = c.anchor_half,
	}
	changes_selection_hold(pane)
}

// Selects the hunk of `file` whose first flat line is `first`.
@(private = "file", require_results)
changes_select_hunk :: proc(pane: ^Changes_Pane, file, first: int) -> bool {
	c := &pane.comments
	files := pane.model.view.files
	if file < 0 || file >= len(files) {return false}
	flat := 0
	for hunk in files[file].hunks {
		if flat == first && len(hunk.lines) > 0 {
			c.anchor, c.anchor_half = first, .Both
			c.selection = {
				file   = file,
				first  = first,
				last   = first + len(hunk.lines) - 1,
				active = true,
			}
			changes_selection_hold(pane)
			return true
		}
		flat += len(hunk.lines)
	}
	return false
}

// Opens the editor on note `index`, or on a new comment at the selection when it is len(items), with the
// caret at the end of its text. A note keeps its tag until the editor's × takes it off.
@(private = "file")
changes_editor_open :: proc(pane: ^Changes_Pane, index: int) {
	c := &pane.comments
	if index < 0 || index > len(c.items) {return}
	if index == len(c.items) && !c.selection.active {return}
	text := index < len(c.items) ? c.items[index].text : ""
	if !markdown.edit_buffer_reset(&c.buffer, text) {return}
	c.buffer.caret, c.buffer.anchor = len(c.buffer.text), len(c.buffer.text)
	ui.text_area_reset(&c.area)
	c.draft = index < len(c.items) ? c.items[index].kind : .Comment
	c.editing = index
}

// What a new note carries besides its lines. A label's name, colour and instruction are copied from the
// quick label it was made with.
Changes_Note :: struct {
	kind:                                       ui.Changes_Note_Kind,
	text:                                       string,
	label_name, label_colour, label_instruction: string,
}

// Adds a note of any kind on the selection; the selection ends. A label or a deletion needs no editor, so
// this is how those are made.
@(require_results)
changes_comment_add :: proc(pane: ^Changes_Pane, note: Changes_Note) -> bool {
	c := &pane.comments
	files := pane.model.view.files
	s := c.selection
	if !s.active || s.file < 0 || s.file >= len(files) {return false}
	file := files[s.file]
	side, low, high, found := changes_range_of(file, s.first, s.last, s.half)
	if !found {return false}
	item := Changes_Comment {
		side       = side,
		first      = low,
		last       = high,
		kind       = note.kind,
		file       = s.file,
		first_line = s.first,
		last_line  = s.last,
		half       = s.half,
	}
	item.partial, item.first_offset, item.last_offset = changes_range_fit(
		file, s.first, s.last, s.partial, s.first_offset, s.last_offset,
	)
	item.lines = changes_span_lines(file, s.first, s.last)
	changes_item_fit(files, &item)
	failed := false
	item.worktree = changes_clone(changes_comments_worktree(pane), &failed)
	item.path = changes_clone(changes_comment_path(file), &failed)
	item.quote = changes_clone(changes_quote(file, s.first, s.last, s.half), &failed)
	item.text = changes_clone(note.text, &failed)
	item.label_name = changes_clone(note.label_name, &failed)
	item.label_colour = changes_clone(note.label_colour, &failed)
	item.label_instruction = changes_clone(note.label_instruction, &failed)
	if failed {
		changes_comment_release(&item)
		return false
	}
	if _, err := append(&c.items, item); err != nil {
		changes_comment_release(&item)
		return false
	}
	c.selection, c.dragging = {}, false
	c.held.file = -1
	return true
}

// Puts `text` in a note and, when the editor's × took its tag off, makes it a plain comment that forgets its
// label.
@(private = "file")
changes_note_rewrite :: proc(app: ^App, item: ^Changes_Comment, text: string, kind: ui.Changes_Note_Kind) {
	cloned, err := strings.clone(text)
	if err != nil {
		notify(app, .Error, "Could not save the note.")
		return
	}
	delete(item.text)
	item.text = cloned
	if kind == item.kind {return}
	delete(item.label_name)
	delete(item.label_colour)
	delete(item.label_instruction)
	item.label_name, item.label_colour, item.label_instruction = "", "", ""
	item.kind = kind
}

// Ends editing; with `save`, the text and the kind replace the note's or become a new comment. An empty
// plain comment saves nothing, so it never empties an existing note.
@(private)
changes_editor_close :: proc(app: ^App, pane: ^Changes_Pane, save: bool) {
	c := &pane.comments
	if c.editing < 0 {return}
	editing, draft := c.editing, c.draft
	c.editing = -1
	_ = ui.text_area_release(&c.area)
	text := strings.trim_space(markdown.edit_string(&c.buffer))
	if !save || (text == "" && draft == .Comment) {return}
	if editing < len(c.items) {
		changes_note_rewrite(app, &c.items[editing], text, draft)
		return
	}
	if !changes_comment_add(pane, {text = text}) {notify(app, .Error, "Could not save the note.")}
}

@(private = "file")
changes_comment_delete :: proc(pane: ^Changes_Pane, index: int) {
	c := &pane.comments
	if index < 0 || index >= len(c.items) {return}
	changes_comment_release(&c.items[index])
	ordered_remove(&c.items, index)
	if c.editing == index {
		c.editing = -1
		_ = ui.text_area_release(&c.area)
	} else if c.editing > index {
		c.editing -= 1
	}
}

@(private = "file")
changes_comments_clear :: proc(pane: ^Changes_Pane) {
	c := &pane.comments
	for &item in c.items {changes_comment_release(&item)}
	clear(&c.items)
	c.editing = -1
	_ = ui.text_area_release(&c.area)
}

@(private = "file", require_results)
changes_comment_noun :: proc(count: int) -> string {
	return count == 1 ? "note" : "notes"
}

// "<harness> · <pane title>", as the source chips name the agent.
@(private = "file", require_results)
changes_target_label :: proc(pane: ^Changes_Pane, entry: ^Session_Entry) -> string {
	b := &pane.comments.target
	strings.builder_reset(b)
	strings.write_string(b, pane.agent.harness)
	title := entry != nil ? session_display_title(entry) : ""
	if title != "" {
		if strings.builder_len(b^) > 0 {strings.write_string(b, " · ")}
		strings.write_string(b, title)
	}
	if strings.builder_len(b^) == 0 {strings.write_string(b, "the agent")}
	return strings.to_string(b^)
}

@(private = "file")
changes_comments_send :: proc(app: ^App, pane: ^Changes_Pane) {
	c := &pane.comments
	count := len(c.items)
	if count == 0 {return}
	entry, can_send, reason := changes_send_check(app, pane, fresh = true)
	if !can_send {
		notify(app, .Error, reason)
		return
	}
	message := changes_comments_message(c.items[:], context.temp_allocator)
	if term.paste(entry.session, message) != .Sent {
		notify(app, .Error, "Could not send the comments: the agent's pane isn't accepting input.")
		return
	}
	// The text is in the agent's input now, so the comments go whether or not Enter reaches it.
	notice := fmt.tprintf(
		"Sent %d %s to %s.", count, changes_comment_noun(count), changes_target_label(pane, entry),
	)
	if outcome := pane_send(entry, "", true); outcome.status != .Ok {
		notify(app, .Warning, "Sent the comments, but could not press Enter in the agent's pane.")
	} else {
		notify(app, .Info, notice)
	}
	changes_comments_clear(pane)
}

@(private = "file")
changes_comments_copy :: proc(app: ^App, pane: ^Changes_Pane) {
	items := pane.comments.items[:]
	if len(items) == 0 {return}
	if clipboard_write(app, changes_comments_message(items, context.temp_allocator)) {
		notify(app, .Info, fmt.tprintf("Copied %d %s.", len(items), changes_comment_noun(len(items))))
	}
}

// Places the editor's caret where the pointer pressed, or extends its selection there with Shift.
@(private = "file")
changes_editor_point :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, x, y: f32, extend: bool) {
	shown, found := changes_pane_rect(w, pane.id)
	if !found {return}
	g := changes_geometry_of(app, w, pane, shown)
	box, visible := ui.changes_editor_box(g, &pane.model.view, &pane.state, &w.ui_text)
	if !visible {return}
	_ = ui.text_area_pointer(box, x, y, true, extend)
}

// Starts picking whole lines at flat line `line` of `file`, pressed in `half` of a side-by-side row; Shift
// extends the selection of the same file, which keeps the half it began in.
@(private = "file")
changes_press_lines :: proc(pane: ^Changes_Pane, file, line: int, extend: bool, half: ui.Changes_Half) {
	c := &pane.comments
	same_file := c.selection.active && c.selection.file == file
	if !(extend && same_file) {c.anchor_half = half}
	changes_select_line(pane, file, line, extend && same_file)
	c.by_text, c.dragging = false, c.selection.active
}

// Selects the text between the anchor and byte `offset` of flat line `line` of `file`; no text is no
// selection.
@(private = "file")
changes_text_extend :: proc(pane: ^Changes_Pane, file, line, offset: int) {
	c := &pane.comments
	files := pane.model.view.files
	if file < 0 || file >= len(files) || line < 0 || line >= changes_line_count(files[file]) {return}
	first, first_offset, last, last_offset := c.anchor, c.anchor_offset, line, offset
	if last < first || (last == first && last_offset < first_offset) {
		first, first_offset, last, last_offset = last, last_offset, first, first_offset
	}
	if first == last && first_offset == last_offset {
		c.selection, c.held.file = {}, -1
		return
	}
	c.selection = {
		file         = file,
		first        = first,
		last         = last,
		active       = true,
		partial      = true,
		first_offset = first_offset,
		last_offset  = last_offset,
		half         = c.anchor_half,
	}
	changes_selection_hold(pane)
}

// Starts a character selection at byte `at.offset` of flat line `line` of `file`; Shift extends the text
// selection of the same file from its anchor. A press that no drag follows selects nothing.
@(private = "file")
changes_press_text :: proc(pane: ^Changes_Pane, file, line: int, at: Changes_Text_Point, extend: bool) {
	c := &pane.comments
	extending := extend && c.selection.active && c.selection.partial && c.selection.file == file &&
		c.selection.half == at.half
	if !extending {
		c.anchor, c.anchor_offset, c.anchor_half = line, at.offset, at.half
		c.selection, c.held.file = {}, -1
	}
	c.by_text, c.dragging = true, true
	c.drag_file, c.drag_cell = file, at.cell
	if extending {changes_text_extend(pane, file, line, at.offset)}
}

@(private = "file", require_results)
changes_blank :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\r' || b == '\n' || b == '\v' || b == '\f'
}

// Ends a text drag: whitespace goes from both ends of the range, so selecting "a word " means the word,
// and a range of nothing but whitespace is no selection.
@(private = "file")
changes_text_settle :: proc(pane: ^Changes_Pane) {
	c := &pane.comments
	s := c.selection
	files := pane.model.view.files
	if !s.active || s.file < 0 || s.file >= len(files) {return}
	file := files[s.file]
	first, first_offset, last, last_offset := -1, 0, -1, 0
	for line in s.first ..= s.last {
		text, found := changes_half_text(file, line, s.half)
		if !found {continue}
		low := line == s.first ? clamp(s.first_offset, 0, len(text)) : 0
		high := line == s.last ? clamp(s.last_offset, 0, len(text)) : len(text)
		for low < high && changes_blank(text[low]) {low += 1}
		if low < high {
			first, first_offset = line, low
			break
		}
	}
	for line := s.last; line >= first && first >= 0; line -= 1 {
		text, found := changes_half_text(file, line, s.half)
		if !found {continue}
		low := line == first ? first_offset : 0
		high := line == s.last ? clamp(s.last_offset, 0, len(text)) : len(text)
		for high > low && changes_blank(text[high - 1]) {high -= 1}
		if high > low {
			last, last_offset = line, high
			break
		}
	}
	if first < 0 || last < 0 {
		c.selection, c.held.file = {}, -1
		return
	}
	c.selection.first, c.selection.first_offset = first, first_offset
	c.selection.last, c.selection.last_offset = last, last_offset
	changes_selection_hold(pane)
}

// Opens the editor on a new comment at the selection, starting with `text` already typed.
@(private = "file")
changes_comment_start :: proc(pane: ^Changes_Pane, text: string) {
	c := &pane.comments
	changes_editor_open(pane, len(c.items))
	if c.editing == len(c.items) && text != "" {_ = text_edit_type(&c.buffer, text)}
}

// The file and flat lines the editor's note is on; false when they are not in the diff.
@(private = "file", require_results)
changes_editor_lines :: proc(pane: ^Changes_Pane) -> (file: turns.Diff_File, first, last: int, found: bool) {
	c := &pane.comments
	files := pane.model.view.files
	at := -1
	if c.editing >= 0 && c.editing < len(c.items) {
		item := c.items[c.editing]
		at, first, last = item.file, item.first_line, item.last_line
	} else if c.editing == len(c.items) && c.selection.active {
		at, first, last = c.selection.file, c.selection.first, c.selection.last
	}
	if at < 0 || at >= len(files) {return}
	return files[at], first, last, true
}

// The new-side lines of flat lines `first` through `last` of `file` joined by line breaks, which a suggestion
// replaces, in temporary memory.
@(private = "file", require_results)
changes_new_side :: proc(file: turns.Diff_File, first, last: int) -> string {
	return strings.join(ui.changes_new_side(file, first, last), "\n", context.temp_allocator)
}

// The word that opens a code block of `file`'s lines: its extension, which names its language.
@(private = "file", require_results)
changes_fence_language :: proc(file: turns.Diff_File) -> string {
	path := changes_comment_path(file)
	name := path[strings.last_index_any(path, "/\\") + 1:]
	dot := strings.last_index_byte(name, '.')
	return dot > 0 ? name[dot + 1:] : ""
}

// Applies one of the editor's tools to its text: bold or inline code around the selection, a code block, or
// the selected lines as an editable replacement.
@(private = "file")
changes_editor_tool :: proc(pane: ^Changes_Pane, part: ui.Changes_Part) {
	c := &pane.comments
	file, first, last, found := changes_editor_lines(pane)
	#partial switch part {
	case .Editor_Bold:
		_ = ui.text_area_wrap_selection(&c.buffer, "**", "**", "bold")
	case .Editor_Code:
		_ = ui.text_area_wrap_selection(&c.buffer, "`", "`", "code")
	case .Editor_Block:
		from, to := markdown.edit_selection(&c.buffer)
		lang := found ? changes_fence_language(file) : ""
		_ = ui.text_area_insert_block(&c.buffer, lang, string(c.buffer.text[from:to]))
	case .Editor_Suggest:
		if found && !changes_editor_span(pane).old {
			_ = ui.text_area_insert_block(&c.buffer, "suggestion", changes_new_side(file, first, last))
		}
	}
}

// Adds a label or a deletion on the selection at once, with no editor: the selection ends and the toolbar
// closes with it.
@(private = "file")
changes_note_add :: proc(app: ^App, pane: ^Changes_Pane, note: Changes_Note) {
	if !changes_comment_add(pane, note) {
		notify(app, .Error, "Could not save the note.")
		return
	}
	pane.comments.menu = false
}

// Adds the label at `index` of the quick labels setting on the selection; a label that is not there adds
// nothing.
@(private = "file")
changes_label_apply :: proc(app: ^App, pane: ^Changes_Pane, index: int) {
	label, found := ui.changes_label_at(app.settings.turns.quick_labels, index)
	if !found {return}
	changes_note_add(
		app,
		pane,
		{
			kind = .Label,
			label_name = label.name,
			label_colour = label.colour,
			label_instruction = label.instruction,
		},
	)
}

// Opens the label menu, which closes the pane's other popovers, or closes it.
@(private = "file")
changes_label_menu_set :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, open: bool) {
	c := &pane.comments
	if c.menu == open {return}
	if open {changes_popovers_close(app, w, pane, .Labels)}
	c.menu, c.menu_row = open, 0
}

// Closes the label menu; a press elsewhere than on the toolbar and the menu does it.
@(private)
changes_labels_close :: proc(pane: ^Changes_Pane) {
	pane.comments.menu = false
}

// Moves the label menu's key row by `step` labels, stopping at the first and the last.
@(private)
changes_label_menu_step :: proc(app: ^App, pane: ^Changes_Pane, step: int) {
	count := ui.changes_label_count(app.settings.turns.quick_labels)
	pane.comments.menu_row = clamp(pane.comments.menu_row + step, 0, max(0, count - 1))
}

// Whether a press on `part` is on the selection toolbar or its label menu, which a press elsewhere closes
// the menu around.
@(private)
changes_selection_part :: proc(part: ui.Changes_Part) -> bool {
	#partial switch part {
	case .Toolbar, .Toolbar_Delete, .Toolbar_Comment, .Toolbar_Label, .Label_Menu, .Label_Row, .Label_Edit:
		return true
	}
	return false
}

// Opens Settings on the quick labels, ending the selection the toolbar was over.
@(private = "file")
changes_labels_edit :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	c := &pane.comments
	c.selection, c.dragging, c.menu = {}, false, false
	c.held.file = -1
	settings_reveal(app, w, {key = settings.QUICK_LABELS_KEY, search = .Clear, focus = .Control})
}

// Whether the pane shows the selection's toolbar: a selection no drag is making, not scrolled out of view.
// A pane that is not on screen counts as shown, as there is nothing to scroll.
@(private = "file", require_results)
changes_toolbar_shown :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) -> bool {
	c := &pane.comments
	if !c.selection.active || c.dragging || c.editing >= 0 {return false}
	shown, found := changes_pane_rect(w, pane.id)
	if !found {return true}
	return changes_geometry_of(app, w, pane, shown).selection_bar.bar.width > 0
}

// Scrolls the diff so the editor card shows: its bottom in view, and its top too when the card fits.
@(private = "file")
changes_editor_reveal :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	shown, found := changes_pane_rect(w, pane.id)
	if !found {return}
	g := changes_geometry_of(app, w, pane, shown)
	card, visible := ui.changes_card_rect(g, &pane.model.view, &pane.state, pane.comments.editing)
	if !visible {return}
	over := card.y + card.height + ui.SPACE_3 * w.scale - (g.diff.y + g.diff.height)
	if over > 0 {_ = ui.changes_scroll_diff(&pane.state, g, int(min(over, card.y - g.diff.y)))}
}

// Saves the note being written, unless it is an empty plain comment, which has nothing to save.
@(private = "file")
changes_editor_save :: proc(app: ^App, pane: ^Changes_Pane) {
	if ui.changes_editor_can_save(&pane.model.view) {changes_editor_close(app, pane, true)}
}

// Takes presses on diff lines, the selection toolbar and its menu, the note cards and the editor, and the
// send bar. `at` says where a press on the code text or the numbers landed.
changes_comments_press :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Changes_Pane,
	hit: ui.Changes_Hit,
	e: input.Mouse_Button_Event,
	at := Changes_Text_Point{},
) -> bool {
	c := &pane.comments
	extend := .Shift in e.modifiers
	c.alt = .Alt in e.modifiers
	editing := c.editing
	#partial switch hit.part {
	case .Line:
		// Pressing away from the editor keeps what it holds.
		changes_editor_close(app, pane, true)
		if c.alt || c.select_lines {
			changes_press_lines(pane, hit.index, hit.line, extend, at.half)
		} else {
			changes_press_text(pane, hit.index, hit.line, at, extend)
		}
	case .Gutter:
		changes_editor_close(app, pane, true)
		changes_press_lines(pane, hit.index, hit.line, extend, at.half)
	case .Hunk_Select:
		changes_editor_close(app, pane, true)
		_ = changes_select_hunk(pane, hit.index, hit.line)
	case .Toolbar_Delete:
		changes_note_add(app, pane, {kind = .Delete})
	case .Toolbar_Comment:
		c.menu = false
		changes_comment_start(pane, "")
	case .Toolbar_Label:
		changes_label_menu_set(app, w, pane, !c.menu)
	case .Label_Row:
		changes_label_apply(app, pane, hit.index)
	case .Label_Edit:
		changes_labels_edit(app, w, pane)
	case .Toolbar, .Label_Menu:
	case .Comment_Card:
		if hit.index != c.editing {changes_editor_close(app, pane, true)}
	case .Comment_Edit:
		changes_editor_close(app, pane, true)
		changes_editor_open(pane, hit.index)
	case .Comment_Remove:
		changes_comment_delete(pane, hit.index)
	case .Comment_Editor:
		changes_editor_point(app, w, pane, f32(e.x), f32(e.y), extend)
	case .Editor_Untag:
		c.draft = .Comment
	case .Editor_Bold, .Editor_Code, .Editor_Block, .Editor_Suggest:
		changes_editor_tool(pane, hit.part)
	case .Editor_Cancel:
		changes_editor_close(app, pane, false)
	case .Editor_Save:
		changes_editor_save(app, pane)
	case .Send:
		changes_comments_send(app, pane)
	case .Copy:
		changes_comments_copy(app, pane)
	case .Discard:
		changes_comments_clear(pane)
	case:
		return false
	}
	changes_comments_sync(pane)
	if c.editing >= 0 && c.editing != editing {changes_editor_reveal(app, w, pane)}
	w.dirty = true
	return true
}

// Extends the selection a press started while the pointer moves over lines of its file: by lines or, for a
// text selection, to the byte `at` gives on the line under the pointer, the line's start over its numbers.
changes_comments_drag :: proc(
	app: ^App, w: ^Window, pane: ^Changes_Pane, hit: ui.Changes_Hit, at := Changes_Text_Point{},
) -> bool {
	c := &pane.comments
	if !c.dragging || (hit.part != .Line && hit.part != .Gutter) {return false}
	before := c.selection
	if c.by_text {
		if hit.index != c.drag_file {return false}
		changes_text_extend(pane, hit.index, hit.line, hit.part == .Gutter ? 0 : at.offset)
	} else {
		if !c.selection.active || hit.index != c.selection.file {return false}
		first, last := min(c.anchor, hit.line), max(c.anchor, hit.line)
		c.selection.first, c.selection.last = first, last
		changes_selection_hold(pane)
	}
	if c.selection == before {return false}
	changes_comments_sync(pane)
	w.dirty = true
	return true
}

changes_comments_release :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	c := &pane.comments
	dragged := c.dragging
	c.dragging = false
	if dragged && c.by_text {changes_text_settle(pane)}
	changes_comments_sync(pane)
	if ui.text_area_release(&c.area) || dragged {w.dirty = true}
}

// The digit a key types, 0 to 9; -1 for any other key.
@(private = "file", require_results)
changes_key_digit :: proc(key: input.Key) -> int {
	if key >= .Digit_0 && key <= .Digit_9 {return int(key) - int(input.Key.Digit_0)}
	if key >= .Numpad_0 && key <= .Numpad_9 {return int(key) - int(input.Key.Numpad_0)}
	return -1
}

// The keys of the selection toolbar, while it shows: Alt and a digit apply that label (Alt+0 the tenth), and
// with the menu open so do arrows with Enter and the plain digits; Delete or Backspace add a deletion;
// Enter opens the comment editor empty, and a typed character opens it with that character; Escape closes
// the menu, then the selection. Anything else is not the toolbar's.
@(private = "file", require_results)
changes_selection_key :: proc(
	app: ^App, w: ^Window, pane: ^Changes_Pane, e, logical: input.Key_Event, modifiers: input.Modifiers,
) -> bool {
	c := &pane.comments
	if !changes_toolbar_shown(app, w, pane) {return false}
	key := logical.key
	enter := key == .Enter || key == .Numpad_Enter
	if digit := changes_key_digit(key); digit >= 0 && (modifiers == {.Alt} || (c.menu && modifiers == {})) {
		changes_label_apply(app, pane, digit == 0 ? 9 : digit - 1)
		return true
	}
	if modifiers == {} {
		switch {
		case key == .Escape:
			if c.menu {
				c.menu = false
			} else {
				c.selection, c.dragging = {}, false
				c.held.file = -1
			}
			return true
		case c.menu && (key == .Arrow_Down || key == .Arrow_Up):
			if count := ui.changes_label_count(app.settings.turns.quick_labels); count > 0 {
				c.menu_row = (c.menu_row + (key == .Arrow_Down ? 1 : count - 1)) % count
			}
			return true
		case c.menu && enter:
			changes_label_apply(app, pane, c.menu_row)
			return true
		case key == .Delete || key == .Backspace:
			changes_note_add(app, pane, {kind = .Delete})
			return true
		case enter:
			c.menu = false
			changes_comment_start(pane, "")
			return true
		}
	}
	// Typing starts a comment with what was typed (AltGr types too); a control character is not typing.
	if text_key_types(modifiers) && e.text != "" && e.text[0] >= ' ' && e.text[0] != 0x7f {
		c.menu = false
		changes_comment_start(pane, e.text)
		return true
	}
	return false
}

// Applies a key to the open editor's text, moving down and up a line through the text area, which knows its
// lines. False for the chords the editor has no use for, which go on to the shortcuts.
@(private = "file", require_results)
changes_editor_edit :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, key: Content_Key) -> bool {
	result := text_edit_key(app, &pane.comments.buffer, key)
	switch result.kind {
	case .Ignored:
		return key.logical.modifiers & {.Control, .Alt, .Super} == {}
	case .Handled, .Moved, .Edited:
	case .Vertical:
		shown, found := changes_pane_rect(w, pane.id)
		if !found {break}
		g := changes_geometry_of(app, w, pane, shown)
		if box, visible := ui.changes_editor_box(g, &pane.model.view, &pane.state, &w.ui_text); visible {
			ui.text_area_vertical(box, result.lines, result.pages, result.extend)
		}
	}
	return true
}

// The editor's keys while a note is being written: Escape cancels, Ctrl+Enter saves, Ctrl+B bolds, and the
// rest edit the text (Enter breaks the line); else the toolbar's keys over a selection. Chords the editor has
// no use for go on to the shortcuts.
changes_comments_key :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, e: input.Key_Event) -> bool {
	if !e.pressed {return false}
	c := &pane.comments
	logical := e
	logical.key = commands.logical_key(e.key, e.unshifted)
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	enter := logical.key == .Enter || logical.key == .Numpad_Enter
	editing := c.editing
	switch {
	case c.editing < 0:
		if !changes_selection_key(app, w, pane, e, logical, modifiers) {return false}
	case logical.key == .Escape && modifiers == {}:
		changes_editor_close(app, pane, false)
	case enter && modifiers == {.Control}:
		changes_editor_save(app, pane)
	case logical.key == .B && modifiers == {.Control}:
		_ = ui.text_area_wrap_selection(&c.buffer, "**", "**", "bold")
	case:
		if !changes_editor_edit(app, w, pane, {logical = logical, clipboard = clipboard_chord(logical)}) {
			return false
		}
	}
	key_suppress(w, e)
	changes_comments_sync(pane)
	if c.editing >= 0 && c.editing != editing {changes_editor_reveal(app, w, pane)}
	w.dirty = true
	return true
}

// Typed or pasted text goes to the open editor.
changes_comments_text :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, text: string) -> bool {
	c := &pane.comments
	if c.editing < 0 {return false}
	if text_edit_type(&c.buffer, text) == .Edited {w.dirty = true}
	return true
}

// Fills the view's selection, comments, editor and send bar before a frame.
changes_comments_view :: proc(app: ^App, pane: ^Changes_Pane) {
	changes_comments_sync(pane)
	c := &pane.comments
	view := &pane.model.view
	view.quick_labels = app.settings.turns.quick_labels
	view.send = {
		count = len(c.items),
	}
	if view.send.count == 0 {return}
	now := clock_now(&app.clock)
	if c.checked == {} || time.tick_diff(c.checked, now) >= CHANGES_SEND_CHECK {
		_, c.can_send, c.reason = changes_send_target(app, pane)
		c.checked = now
	}
	entry: ^Session_Entry
	if pane.agent.pane_key != "" {entry = turn_entry_find(app, pane.agent.pane_key)}
	view.send.can_send, view.send.reason = c.can_send, c.reason
	view.send.target = changes_target_label(pane, entry)
}

// After a new diff: each comment and the selection find their lines again by path, side and line
// numbers. A comment whose lines are gone is detached; a selection whose lines are gone ends, and so
// does a new comment being written on it.
changes_comments_reanchor :: proc(pane: ^Changes_Pane) {
	c := &pane.comments
	files := pane.model.view.files
	worktree := changes_comments_worktree(pane)
	for &item in c.items {
		item.file, item.first_line, item.last_line = changes_anchor_find(files, worktree, item)
		changes_item_fit(files, &item)
	}
	if c.selection.active {
		file, first, last := -1, 0, 0
		if c.held.file >= 0 {file, first, last = changes_anchor_find(files, worktree, c.held)}
		if file < 0 {
			c.selection, c.dragging = {}, false
			c.held.file = -1
			if c.editing == len(c.items) {
				c.editing = -1
				_ = ui.text_area_release(&c.area)
			}
		} else {
			c.anchor = c.anchor == c.selection.first ? first : last
			partial, first_offset, last_offset := changes_range_fit(
				files[file], first, last, c.held.partial, c.held.first_offset, c.held.last_offset,
				c.held.lines,
			)
			c.selection = {
				file         = file,
				first        = first,
				last         = last,
				active       = true,
				partial      = partial,
				first_offset = first_offset,
				last_offset  = last_offset,
				half         = c.held.half,
			}
			c.held.file, c.held.first_line, c.held.last_line = file, first, last
		}
	}
	changes_comments_sync(pane)
}

// How many backticks fence `s` so nothing inside it can close the fence: one more than its longest run, and
// at least three.
@(private = "file", require_results)
changes_fence :: proc(s: string) -> int {
	run, longest := 0, 0
	for at in 0 ..< len(s) {
		run = s[at] == '`' ? run + 1 : 0
		longest = max(longest, run)
	}
	return max(3, longest + 1)
}

@(private = "file")
changes_fence_write :: proc(b: ^strings.Builder, count: int) {
	for _ in 0 ..< count {strings.write_byte(b, '`')}
}

// The text a partial note covers, from the quote it kept: its lines without their signs, from the start
// offset in the first to the end offset in the last, as the note card shows it. In temporary memory.
@(private = "file", require_results)
changes_note_excerpt :: proc(item: Changes_Comment) -> string {
	lines := strings.split(item.quote, "\n", context.temp_allocator)
	for &line in lines {line = len(line) > 0 ? line[1:] : ""}
	return ui.changes_excerpt(lines, item.first_offset, item.last_offset, CHANGES_EXCERPT_RUNES)
}

// A note's own text as the message gives it: fenced blocks keep a fence long enough for what they hold, and
// a suggestion block becomes "Suggested replacement for <span>:" and the fenced replacement. Trimmed. In
// temporary memory. The blocks are those the note card draws.
@(private = "file", require_results)
changes_note_text :: proc(text, span: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	scan := ui.Note_Scan {
		rest = text,
	}
	for block in ui.note_block_next(&scan) {
		if block.kind == .Paragraph {
			strings.write_string(&out, block.text)
			continue
		}
		fence := changes_fence(block.text)
		if block.kind == .Suggestion {
			strings.write_string(&out, "Suggested replacement for ")
			strings.write_string(&out, span)
			strings.write_string(&out, ":\n")
			changes_fence_write(&out, fence)
		} else {
			changes_fence_write(&out, fence)
			strings.write_string(&out, block.lang)
		}
		strings.write_byte(&out, '\n')
		strings.write_string(&out, block.text)
		strings.write_byte(&out, '\n')
		changes_fence_write(&out, fence)
	}
	return strings.trim_space(strings.to_string(out))
}

// What a note says under its quote. A comment is its text. A label is its name and a period, then its
// instruction, then the text on a line of its own. A deletion says what to delete, then the text.
@(private = "file")
changes_note_body :: proc(b: ^strings.Builder, item: Changes_Comment) {
	one := item.first == item.last
	span := one ? fmt.tprintf("line %d", item.first) : fmt.tprintf("lines %d-%d", item.first, item.last)
	text := changes_note_text(item.text, span)
	switch item.kind {
	case .Comment:
		strings.write_string(b, text)
	case .Delete:
		switch {
		case item.partial:
			strings.write_string(b, "Delete the selected text.")
		case one:
			strings.write_string(b, "Delete this line.")
		case:
			strings.write_string(b, "Delete these lines.")
		}
		if text != "" {
			strings.write_byte(b, ' ')
			strings.write_string(b, text)
		}
	case .Label:
		strings.write_string(b, item.label_name)
		strings.write_byte(b, '.')
		if item.label_instruction != "" {
			strings.write_byte(b, ' ')
			strings.write_string(b, item.label_instruction)
		}
		if text != "" {
			strings.write_byte(b, '\n')
			strings.write_string(b, text)
		}
	}
}

// The message Send pastes and Copy copies: a heading, then each note numbered with its path and lines (and
// for a partial selection the text it covers), its quote fenced, and what it says.
@(require_results)
changes_comments_message :: proc(items: []Changes_Comment, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "Review comments on your changes:")
	for item, i in items {
		strings.write_string(&b, "\n\n")
		strings.write_int(&b, i + 1)
		strings.write_string(&b, ". ")
		strings.write_string(&b, item.path)
		if item.first == item.last {
			strings.write_string(&b, ", line ")
			strings.write_int(&b, int(item.first))
		} else {
			strings.write_string(&b, ", lines ")
			strings.write_int(&b, int(item.first))
			strings.write_byte(&b, '-')
			strings.write_int(&b, int(item.last))
		}
		if item.side == .Old {strings.write_string(&b, " before the change")}
		if item.partial {
			strings.write_string(&b, ", at \"")
			strings.write_string(&b, changes_note_excerpt(item))
			strings.write_byte(&b, '"')
		}
		strings.write_string(&b, ":\n")
		fence := changes_fence(item.quote)
		changes_fence_write(&b, fence)
		strings.write_byte(&b, '\n')
		strings.write_string(&b, item.quote)
		strings.write_byte(&b, '\n')
		changes_fence_write(&b, fence)
		strings.write_byte(&b, '\n')
		changes_note_body(&b, item)
	}
	return strings.to_string(b)
}

// The record turns.main_status follows: the one with an empty id, else the most recently updated
// top-level record.
@(private = "file", require_results)
changes_main_record :: proc(statuses: []term.Program_Status) -> (record: term.Program_Status, found: bool) {
	for status in statuses {
		if status.id == "" {return status, true}
	}
	latest: i64
	for status in statuses {
		if strings.index_byte(status.id, '/') >= 0 {continue}
		updated := time.to_unix_nanoseconds(status.updated_at)
		if found && updated <= latest {continue}
		record, latest, found = status, updated, true
	}
	return
}

@(private = "file")
CHANGES_NOT_RUNNING :: "The agent isn't running in its pane."

// What Send makes of the pane's foreground program, so comments never reach a shell or answer a
// prompt. `found` is false when only the pane's shell runs; `name` is the program's executable stem, or
// the script a launcher runs; `harness` is the agent its arguments start; `reporters` are the apps the
// pane's status records name; `record` is its main record; `agent_harness` is the harness the pane's
// agent ran under, "" when unknown. An open record counts only when the program is the app that reports
// it, never a nested shell or bridge that a record outlived.
@(require_results)
changes_send_verdict :: proc(
	found: bool,
	name: string,
	harness: agent.Harness,
	reporters: []string,
	record: term.Program_Status,
	has_record: bool,
	agent_harness: string,
) -> (
	can_send: bool,
	reason: string,
) {
	if !found {return false, CHANGES_NOT_RUNNING}
	names := agent.HARNESS_NAMES
	// Another agent started in the pane is not the one the comments are about.
	running := harness != .None ? harness : agent.harness_named(name)
	if agent_harness != "" && running != .None && !strings.equal_fold(names[running], agent_harness) {
		return false, CHANGES_NOT_RUNNING
	}
	open := has_record && !record.ended
	reporting := false
	if open {
		for reporter in reporters {
			if strings.equal_fold(reporter, name) {reporting = true; break}
		}
	}
	if !reporting && harness == .None {return false, CHANGES_NOT_RUNNING}
	// Enter would answer the agent's permission or question prompt.
	if open && record.state == .Blocked {return false, "The agent is waiting for an answer."}
	return true, ""
}

// The pane's foreground program that is not its shell: polling's adopted choice unless `fresh` or
// nothing polls, else the one found in the process tree read now, as polling finds it.
@(private = "file", require_results)
changes_foreground :: proc(
	app: ^App,
	entry: ^Session_Entry,
	fresh: bool,
) -> (
	name: string,
	launch: agent.Launch,
	found: bool,
) {
	if !fresh && program_polling(app) {
		adopted := program_adopted(entry)
		if adopted == nil || adopted.id != program_polled(entry) {return}
		return adopted.name, adopted.launch, true
	}
	processes := session_processes(app)
	root := term.process_id(entry.session)
	index := procinfo.process_program(
		processes, root, program_reporters(entry), 0, program_at_root(app, processes, root),
	)
	if index < 0 {return}
	program := processes[index]
	name = procinfo.executable_stem(program.executable)
	arguments, read := procinfo.process_arguments(program.id, root, context.temp_allocator)
	if read {
		launch = program_launch(app, arguments, name, context.temp_allocator)
		if procinfo.is_launcher(name) {
			if script := procinfo.process_script(arguments); program_known(app, script) {name = script}
		}
	}
	return name, launch, true
}

// Where Send pastes: the pane's agent, while it still runs in its pane and that pane takes bracketed
// paste, so the comments never reach a shell prompt as commands. This is the drawn state's check; the
// Send action reads the process tree afresh.
@(require_results)
changes_send_target :: proc(
	app: ^App,
	pane: ^Changes_Pane,
) -> (
	entry: ^Session_Entry,
	can_send: bool,
	reason: string,
) {
	return changes_send_check(app, pane, fresh = false)
}

@(private = "file", require_results)
changes_send_check :: proc(
	app: ^App,
	pane: ^Changes_Pane,
	fresh: bool,
) -> (
	entry: ^Session_Entry,
	can_send: bool,
	reason: string,
) {
	if pane.agent.pane_key != "" {entry = turn_entry_find(app, pane.agent.pane_key)}
	if entry == nil {return nil, false, "The agent's pane is closed."}
	if entry.status != .Running {return entry, false, CHANGES_NOT_RUNNING}
	name, launch, found := changes_foreground(app, entry, fresh)
	record, has_record := changes_main_record(entry.statuses)
	can_send, reason = changes_send_verdict(
		found, name, launch.harness, program_reporters(entry), record, has_record, pane.agent.harness,
	)
	if !can_send {return entry, false, reason}
	if !term.bracketed_paste(entry.session) {return entry, false, "The agent isn't accepting pasted text."}
	return entry, true, ""
}

when AIO_CONTROL {
	// The text the selection covers, lines joined by line breaks, in temporary memory: the selected bytes of
	// a text selection, the whole lines of a selection of lines.
	@(private = "file")
	changes_selection_text :: proc(pane: ^Changes_Pane) -> string {
		s := pane.comments.selection
		files := pane.model.view.files
		if !s.active || s.file < 0 || s.file >= len(files) {return ""}
		b := strings.builder_make(context.temp_allocator)
		written := false
		for line in s.first ..= s.last {
			text, found := changes_half_text(files[s.file], line, s.half)
			if !found {continue}
			low, high := 0, len(text)
			if s.partial {
				if line == s.first {low = clamp(s.first_offset, 0, len(text))}
				if line == s.last {high = clamp(s.last_offset, low, len(text))}
			}
			if written {strings.write_byte(&b, '\n')}
			written = true
			strings.write_string(&b, text[low:high])
		}
		return strings.to_string(b)
	}

	// The comment keys of the focused Agent changes pane, which may be nil; changes_state_report calls it.
	changes_comments_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window, pane: ^Changes_Pane) {
		selection, mode, selected, reason := "", "", "", ""
		count, editing := 0, -1
		can_send, select_lines, label_menu := false, false, false
		advance: f32
		send_rect, copy_rect, discard_rect, select_lines_rect: render.Rect
		editor: ui.Changes_Editor
		bar: ui.Changes_Selection_Bar
		if pane != nil {
			changes_comments_view(app, pane)
			c := &pane.comments
			view := &pane.model.view
			s := c.selection
			if s.active {
				selection = fmt.tprintf("%d:%d-%d", s.file, s.first, s.last)
				mode = s.partial ? "text" : "lines"
				selected = changes_selection_text(pane)
			}
			select_lines, label_menu = c.select_lines, c.menu
			count, editing = len(c.items), c.editing
			// Fresh, like Send, so the harness sees an agent exit at once.
			if count > 0 {_, can_send, reason = changes_send_check(app, pane, fresh = true)}
			for item, i in c.items {
				state_text(r, fmt.tprintf("changes.comment.%d.path", i), item.path)
				state_value(r, fmt.tprintf("changes.comment.%d.first", i), item.first)
				state_value(r, fmt.tprintf("changes.comment.%d.last", i), item.last)
				state_text(r, fmt.tprintf("changes.comment.%d.text", i), item.text)
				state_value(r, fmt.tprintf("changes.comment.%d.detached", i), item.file < 0)
				state_text(r, fmt.tprintf("changes.comment.%d.kind", i), fmt.tprint(item.kind))
				state_text(r, fmt.tprintf("changes.comment.%d.label", i), item.label_name)
				state_value(r, fmt.tprintf("changes.comment.%d.partial", i), item.partial)
				state_value(r, fmt.tprintf("changes.comment.%d.first_byte", i), item.first_offset)
				state_value(r, fmt.tprintf("changes.comment.%d.last_byte", i), item.last_offset)
			}
			if shown, found := changes_pane_rect(w, pane.id); found {
				g := changes_geometry_of(app, w, pane, shown)
				mono := ui.text_mono(&w.ui_text, app.family)
				advance = ui.text_width(&mono, "0")
				send_rect, copy_rect, discard_rect = ui.changes_send_rects(g, view)
				editor, _ = ui.changes_editor_of(g, view, &pane.state)
				for i in 0 ..< len(c.items) {
					card, shown := ui.changes_card_rect(g, view, &pane.state, i)
					if !shown || i == c.editing {continue}
					edit, remove := ui.changes_note_actions(card, w.scale)
					state_rect(r, fmt.tprintf("changes.comment.%d.rect", i), card)
					state_rect(r, fmt.tprintf("changes.comment.%d.edit_rect", i), edit)
					state_rect(r, fmt.tprintf("changes.comment.%d.remove_rect", i), remove)
				}
				select_lines_rect = g.select_lines_button
				bar = g.selection_bar
				for file, n in view.files[:min(3, len(view.files))] {
					for m in 0 ..< changes_line_count(file) {
						rect := ui.changes_line_rect(g, view, &pane.state, n, m)
						if rect.width <= 0 || rect.height <= 0 {continue}
						state_rect(r, fmt.tprintf("changes.line.%d.%d.rect", n, m), rect)
						_, column, _ := ui.changes_line_code(g, view, &pane.state, &mono, n, m)
						state_value(r, fmt.tprintf("changes.line.%d.%d.text_x", n, m), column.text_x)
					}
				}
				for k in 0 ..< bar.shown {
					index := bar.first + k
					label, _ := ui.changes_label_at(view.quick_labels, index)
					state_rect(r, fmt.tprintf("changes.label_menu.%d.rect", index), ui.changes_label_row_rect(bar, k))
					state_text(r, fmt.tprintf("changes.label_menu.%d.label", index), label.name)
				}
			}
		}
		state_text(r, "changes.selection", selection)
		state_text(r, "changes.selection_mode", mode)
		state_text(r, "changes.selection_text", selected)
		state_value(r, "changes.select_lines", select_lines)
		state_rect(r, "changes.select_lines_rect", select_lines_rect)
		state_value(r, "changes.mono_advance", advance)
		state_value(r, "changes.toolbar_open", bar.bar.width > 0)
		state_rect(r, "changes.toolbar_rect", bar.bar)
		state_rect(r, "changes.toolbar.delete_rect", bar.delete)
		state_rect(r, "changes.toolbar.comment_rect", bar.comment)
		state_rect(r, "changes.toolbar.label_rect", bar.label)
		state_value(r, "changes.label_menu_open", label_menu)
		state_rect(r, "changes.label_menu_rect", bar.menu)
		state_rect(r, "changes.label_menu_edit_rect", bar.edit)
		state_value(r, "changes.comments", count)
		state_value(r, "changes.editing", editing)
		state_value(r, "changes.send.can_send", can_send)
		state_text(r, "changes.send.reason", reason)
		state_rect(r, "changes.send_rect", send_rect)
		state_rect(r, "changes.copy_rect", copy_rect)
		state_rect(r, "changes.discard_rect", discard_rect)
		state_text(r, "changes.editor_text", pane != nil ? markdown.edit_string(&pane.comments.buffer) : "")
		state_text(r, "changes.editor_kind", pane != nil && editing >= 0 ? fmt.tprint(pane.comments.draft) : "")
		state_rect(r, "changes.editor_rect", editor.card)
		state_rect(r, "changes.editor.area_rect", editor.area)
		state_rect(r, "changes.editor.bold_rect", editor.bold)
		state_rect(r, "changes.editor.code_rect", editor.code)
		state_rect(r, "changes.editor.block_rect", editor.block)
		state_rect(r, "changes.editor.suggest_rect", editor.suggest)
		state_rect(r, "changes.editor.untag_rect", editor.untag)
		state_rect(r, "changes.editor.cancel_rect", editor.cancel)
		state_rect(r, "changes.editor.save_rect", editor.save)
	}
}

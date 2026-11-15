package main

import "aio:agent"
import "aio:commands"
import "aio:input"
import "aio:procinfo"
import "aio:render"
import "aio:term"
import "aio:turns"
import "aio:ui"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

// Only the harness report draws on render.
_ :: render

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
	worktree, path:              string,
	// New when any commented line is Context or Added, else Old.
	side:                        Comment_Side,
	// Line numbers on `side`.
	first, last:                 i32,
	// The commented diff lines with their signs (" ", "+", "-"), joined by '\n'.
	quote:                       string,
	text:                        string,
	// Where it shows in the current view; file = -1 when its lines are not in this diff.
	file, first_line, last_line: int,
}

Changes_Comments :: struct {
	items:     [dynamic]Changes_Comment,
	selection: ui.Changes_Selection,
	// The flat line a selection extends from.
	anchor:    int,
	dragging:  bool,
	editor:    ui.Text_Field,
	// -1 none; an index into `items` edits that comment; len(items) writes a new one at the selection.
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

@(private = "file")
CHANGES_SEND_CHECK :: 500 * time.Millisecond

@(private = "file")
changes_comment_release :: proc(item: ^Changes_Comment) {
	delete(item.worktree)
	delete(item.path)
	delete(item.quote)
	delete(item.text)
	item^ = {}
}

changes_comments_destroy :: proc(c: ^Changes_Comments) {
	for &item in c.items {changes_comment_release(&item)}
	delete(c.items)
	changes_comment_release(&c.held)
	delete(c.editor.bytes)
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

// The side and its line numbers that flat lines `first..last` of `file` cover; found = false when none
// of them is a line of either side.
@(private = "file", require_results)
changes_range_of :: proc(
	file: turns.Diff_File,
	first, last: int,
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
			if at < first || at > last {continue}
			#partial switch line.kind {
			case .Context, .Added:
				if new_low == 0 {new_low = line.new_line}
				new_high = line.new_line
			case .Removed:
				if old_low == 0 {old_low = line.old_line}
				old_high = line.old_line
			}
		}
	}
	if new_low > 0 {return .New, new_low, new_high, true}
	if old_low > 0 {return .Old, old_low, old_high, true}
	return .New, 0, 0, false
}

// Flat lines `first..last` of `file` with their signs, joined by '\n', in temporary memory.
@(private = "file", require_results)
changes_quote :: proc(file: turns.Diff_File, first, last: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	flat := 0
	for hunk in file.hunks {
		for line in hunk.lines {
			at := flat
			flat += 1
			if at < first || at > last {continue}
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
			append(
				&c.views,
				ui.Changes_Comment_View {
					file = item.file,
					first = item.first_line,
					last = item.last_line,
					text = item.text,
					detached = detached,
				},
			)
		}
	}
	view.comments = c.views[:]
	view.selection = c.selection
	view.editing = c.editing <= len(view.comments) ? c.editing : -1
	view.editor = &c.editor
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
	side, low, high, found := changes_range_of(file, s.first, s.last)
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
			c.anchor = first
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

// Opens the editor on comment `index`, or on a new comment at the selection when it is len(items).
@(private = "file")
changes_editor_open :: proc(pane: ^Changes_Pane, index: int) {
	c := &pane.comments
	if index < 0 || index > len(c.items) {return}
	if index == len(c.items) && !c.selection.active {return}
	text := index < len(c.items) ? c.items[index].text : ""
	if ui.field_set(&c.editor, text) != nil {return}
	c.editing = index
}

// A comment on the selection with `text`; the selection ends.
@(private = "file", require_results)
changes_comment_add :: proc(pane: ^Changes_Pane, text: string) -> bool {
	c := &pane.comments
	files := pane.model.view.files
	s := c.selection
	if !s.active || s.file < 0 || s.file >= len(files) {return false}
	file := files[s.file]
	side, low, high, found := changes_range_of(file, s.first, s.last)
	if !found {return false}
	item := Changes_Comment {
		side       = side,
		first      = low,
		last       = high,
		file       = s.file,
		first_line = s.first,
		last_line  = s.last,
	}
	worktree_error, path_error, quote_error, text_error: mem.Allocator_Error
	item.worktree, worktree_error = strings.clone(changes_comments_worktree(pane))
	item.path, path_error = strings.clone(changes_comment_path(file))
	item.quote, quote_error = strings.clone(changes_quote(file, s.first, s.last))
	item.text, text_error = strings.clone(text)
	if worktree_error != nil || path_error != nil || quote_error != nil || text_error != nil {
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

// Ends editing; with `save`, the text replaces the comment's or becomes a new one. Empty text saves
// nothing.
@(private = "file")
changes_editor_close :: proc(app: ^App, pane: ^Changes_Pane, save: bool) {
	c := &pane.comments
	if c.editing < 0 {return}
	editing := c.editing
	c.editing = -1
	_ = ui.field_release(&c.editor)
	text := strings.trim_space(ui.field_string(&c.editor))
	if !save || text == "" {return}
	if editing < len(c.items) {
		cloned, err := strings.clone(text)
		if err != nil {
			notify(app, .Error, "Could not save the comment.")
			return
		}
		delete(c.items[editing].text)
		c.items[editing].text = cloned
		return
	}
	if !changes_comment_add(pane, text) {notify(app, .Error, "Could not save the comment.")}
}

@(private = "file")
changes_comment_delete :: proc(pane: ^Changes_Pane, index: int) {
	c := &pane.comments
	if index < 0 || index >= len(c.items) {return}
	changes_comment_release(&c.items[index])
	ordered_remove(&c.items, index)
	if c.editing == index {
		c.editing = -1
		_ = ui.field_release(&c.editor)
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
	_ = ui.field_release(&c.editor)
}

@(private = "file", require_results)
changes_comment_noun :: proc(count: int) -> string {
	return count == 1 ? "comment" : "comments"
}

// "<harness> · <pane title>", as the source dropdown names the agent.
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

// Places the editor's caret where the pointer pressed.
@(private = "file")
changes_editor_point :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, x: f32, extend: bool) {
	shown, found := changes_pane_rect(w, pane.id)
	if !found {return}
	g := changes_geometry_of(app, w, pane, shown)
	box, visible := ui.changes_editor_box(g, &pane.model.view, &pane.state, &w.ui_text)
	if !visible {return}
	_ = ui.field_pointer(&pane.comments.editor, ui.field_box_offset(box, x), true, extend)
}

// Takes presses on diff lines, comment controls and the send bar.
changes_comments_press :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Changes_Pane,
	hit: ui.Changes_Hit,
	e: input.Mouse_Button_Event,
) -> bool {
	c := &pane.comments
	extend := .Shift in e.modifiers
	#partial switch hit.part {
	case .Line:
		// Pressing away from the editor keeps what it holds.
		changes_editor_close(app, pane, true)
		same_file := c.selection.active && c.selection.file == hit.index
		changes_select_line(pane, hit.index, hit.line, extend && same_file)
		c.dragging = c.selection.active
	case .Hunk_Comment:
		changes_editor_close(app, pane, true)
		if changes_select_hunk(pane, hit.index, hit.line) {changes_editor_open(pane, len(c.items))}
	case .Comment_Button:
		changes_editor_close(app, pane, true)
		changes_editor_open(pane, len(c.items))
	case .Comment_Card:
		if hit.index != c.editing {
			changes_editor_close(app, pane, true)
			changes_editor_open(pane, hit.index)
		}
	case .Comment_Delete:
		changes_comment_delete(pane, hit.index)
	case .Comment_Editor:
		changes_editor_point(app, w, pane, f32(e.x), extend)
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
	w.dirty = true
	return true
}

// Extends the line selection a press started while the pointer moves over lines of its file.
changes_comments_drag :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, hit: ui.Changes_Hit) -> bool {
	c := &pane.comments
	if !c.dragging || !c.selection.active || hit.part != .Line || hit.index != c.selection.file {return false}
	first, last := min(c.anchor, hit.line), max(c.anchor, hit.line)
	if first == c.selection.first && last == c.selection.last {return false}
	c.selection.first, c.selection.last = first, last
	changes_selection_hold(pane)
	changes_comments_sync(pane)
	w.dirty = true
	return true
}

changes_comments_release :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	c := &pane.comments
	dragged := c.dragging
	c.dragging = false
	if ui.field_release(&c.editor) || dragged {w.dirty = true}
}

// The editor's keys while a comment is being written; else Enter opens it on the selection and Escape
// ends the selection. Chords the editor has no use for go on to the shortcuts.
changes_comments_key :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, e: input.Key_Event) -> bool {
	if !e.pressed {return false}
	c := &pane.comments
	logical := e
	logical.key = commands.logical_key(e.key, e.unshifted)
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	enter := logical.key == .Enter || logical.key == .Numpad_Enter
	if c.editing < 0 {
		if !c.selection.active || modifiers != {} {return false}
		switch {
		case logical.key == .Escape:
			c.selection, c.dragging = {}, false
			c.held.file = -1
		case enter:
			changes_editor_open(pane, len(c.items))
		case:
			return false
		}
	} else if logical.key == .Escape && modifiers == {} {
		changes_editor_close(app, pane, false)
	} else if enter && modifiers == {} {
		changes_editor_close(app, pane, true)
	} else {
		edit := field_edit_key(app, &c.editor, logical)
		chord := clipboard_chord(logical) != .None
		if edit.change == .None && !chord && modifiers - {.Shift} != {} && e.text == "" {return false}
	}
	key_suppress(w, e)
	changes_comments_sync(pane)
	w.dirty = true
	return true
}

// Typed or pasted text goes to the open editor.
changes_comments_text :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, text: string) -> bool {
	c := &pane.comments
	if c.editing < 0 {return false}
	if ui.field_text(&c.editor, text) != .None {w.dirty = true}
	return true
}

// Fills the view's selection, comments, editor and send bar before a frame.
changes_comments_view :: proc(app: ^App, pane: ^Changes_Pane) {
	changes_comments_sync(pane)
	c := &pane.comments
	view := &pane.model.view
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
	}
	if c.selection.active {
		file, first, last := -1, 0, 0
		if c.held.file >= 0 {file, first, last = changes_anchor_find(files, worktree, c.held)}
		if file < 0 {
			c.selection, c.dragging = {}, false
			c.held.file = -1
			if c.editing == len(c.items) {
				c.editing = -1
				_ = ui.field_release(&c.editor)
			}
		} else {
			c.anchor = c.anchor == c.selection.first ? first : last
			c.selection = {
				file   = file,
				first  = first,
				last   = last,
				active = true,
			}
			c.held.file, c.held.first_line, c.held.last_line = file, first, last
		}
	}
	changes_comments_sync(pane)
}

// The message Send pastes and Copy copies: a heading, then each comment numbered with its path and
// lines, its quote fenced, and its text.
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
		strings.write_string(&b, ":\n")
		// A fence longer than any backtick run in the quote, so the quote cannot close it.
		run, longest := 0, 0
		for at in 0 ..< len(item.quote) {
			run = item.quote[at] == '`' ? run + 1 : 0
			longest = max(longest, run)
		}
		fence := max(3, longest + 1)
		for _ in 0 ..< fence {strings.write_byte(&b, '`')}
		strings.write_byte(&b, '\n')
		strings.write_string(&b, item.quote)
		strings.write_byte(&b, '\n')
		for _ in 0 ..< fence {strings.write_byte(&b, '`')}
		strings.write_byte(&b, '\n')
		strings.write_string(&b, item.text)
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
	// The comment keys of the focused Agent changes pane, which may be nil; changes_state_report calls it.
	changes_comments_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window, pane: ^Changes_Pane) {
		selection, reason := "", ""
		count, editing := 0, -1
		can_send := false
		send_rect, copy_rect, discard_rect, button_rect: render.Rect
		if pane != nil {
			changes_comments_view(app, pane)
			c := &pane.comments
			view := &pane.model.view
			s := c.selection
			if s.active {selection = fmt.tprintf("%d:%d-%d", s.file, s.first, s.last)}
			count, editing = len(c.items), c.editing
			// Fresh, like Send, so the harness sees an agent exit at once.
			if count > 0 {_, can_send, reason = changes_send_check(app, pane, fresh = true)}
			for item, i in c.items {
				state_text(r, fmt.tprintf("changes.comment.%d.path", i), item.path)
				state_value(r, fmt.tprintf("changes.comment.%d.first", i), item.first)
				state_value(r, fmt.tprintf("changes.comment.%d.last", i), item.last)
				state_text(r, fmt.tprintf("changes.comment.%d.text", i), item.text)
				state_value(r, fmt.tprintf("changes.comment.%d.detached", i), item.file < 0)
			}
			if shown, found := changes_pane_rect(w, pane.id); found {
				g := changes_geometry_of(app, w, pane, shown)
				send_rect, copy_rect, discard_rect = ui.changes_send_rects(g, view)
				button_rect = ui.changes_comment_button_rect(g, view, &pane.state)
				for file, n in view.files[:min(3, len(view.files))] {
					for m in 0 ..< changes_line_count(file) {
						rect := ui.changes_line_rect(g, view, &pane.state, n, m)
						if rect.width <= 0 || rect.height <= 0 {continue}
						state_rect(r, fmt.tprintf("changes.line.%d.%d.rect", n, m), rect)
					}
				}
			}
		}
		state_text(r, "changes.selection", selection)
		state_value(r, "changes.comments", count)
		state_value(r, "changes.editing", editing)
		state_value(r, "changes.send.can_send", can_send)
		state_text(r, "changes.send.reason", reason)
		state_rect(r, "changes.send_rect", send_rect)
		state_rect(r, "changes.copy_rect", copy_rect)
		state_rect(r, "changes.discard_rect", discard_rect)
		state_rect(r, "changes.comment_button_rect", button_rect)
	}
}

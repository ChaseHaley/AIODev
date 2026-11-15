package main

import "aio:turns"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// What an Agent changes pane shows: the turn worker reads git and the recorded segments off the main
// thread, and this file turns its results into the pane's ui.Changes_View. The model owns the current
// result; the view borrows the diff from it, and owns the arrays that sit beside it.

@(private = "file")
WORKTREE_FOLLOW_LABEL :: "Follow the agent"

// Whether the turn hooks are installed in the harness settings that exist.
Changes_Hooks :: enum u8 {
	Unknown,
	Present,
	Missing,
}

// The three events the turn hooks install, as they follow `turn-hook <harness>` in the command.
@(private = "file")
HOOK_EVENTS :: [?]string{"prompt", "stop", "edit"}

// Whether a harness settings directory that exists lacks any of the turn hooks. A directory that does
// not exist is a harness the user does not run, so it offers nothing.
@(require_results)
changes_hooks_missing :: proc(claude_directory, codex_directory: string) -> bool {
	claude := hooks_file_missing(claude_directory, "settings.json", "claude")
	return claude || hooks_file_missing(codex_directory, "hooks.json", "codex")
}

@(private = "file")
hooks_file_missing :: proc(directory, file, harness: string) -> bool {
	if directory == "" || !os.is_dir(directory) {return false}
	path, err := filepath.join({directory, file}, context.temp_allocator)
	if err != nil {return false}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return true}
	for event in HOOK_EVENTS {
		if !strings.contains(string(data), fmt.tprintf("turn-hook %s %s", harness, event)) {return true}
	}
	return false
}

// Sets the toolbar button from the recording setting and the app's cached hook check, which reads the
// settings files only when it is unknown.
@(private = "file")
changes_hooks_sync :: proc(app: ^App, model: ^Changes_Model) {
	if !model.recording {
		model.view.hooks_offer = false
		return
	}
	if app.turn_hooks == .Unknown {
		missing := changes_hooks_missing(
			harness_directory("CLAUDE_CONFIG_DIR", ".claude"),
			harness_directory("CODEX_HOME", ".codex"),
		)
		app.turn_hooks = missing ? .Missing : .Present
	}
	model.view.hooks_offer = app.turn_hooks == .Missing
}

// The turn hooks were installed or changed on disk: the next look re-reads them, and every pane takes it.
changes_hooks_refresh :: proc(app: ^App) {
	app.turn_hooks = .Unknown
	for pane in app.changes_panes {changes_hooks_sync(app, &pane.model)}
	mark_all_dirty(app)
}

// The notice and its detail for a finished read. Turn scopes with no rows say why: recording is off,
// or no turn has been recorded yet.
@(require_results)
changes_notice_of :: proc(
	err: turns.Error,
	turn_scope, recording: bool,
	rows, files: int,
) -> (
	ui.Changes_Notice,
	string,
) {
	switch err {
	case .None:
	case .Git_Missing:
		return .Git_Missing, ""
	case .Not_Repository:
		return .Not_Repository, ""
	case .Out_Of_Memory:
		return .Failed, "Out of memory."
	case .Failed:
		return .Failed, "Git could not read the changes. The log has the details."
	}
	if turn_scope && rows == 0 {return recording ? .No_Turns : .Recording_Off, ""}
	if files == 0 {return .No_Changes, ""}
	return .None, ""
}

// Where the ids `wanted` sit in `ids`, as the first and last index; -1, -1 when none does.
@(require_results)
changes_ids_range :: proc(ids, wanted: []u64) -> (first, last: int) {
	first, last = -1, -1
	for id in wanted {
		i := changes_index_of(ids, id)
		if i < 0 {continue}
		first = first < 0 ? i : min(first, i)
		last = max(last, i)
	}
	return
}

@(private = "file", require_results)
changes_index_of :: proc(ids: []u64, id: u64) -> int {
	for candidate, i in ids {if candidate == id {return i}}
	return -1
}

@(private = "file", require_results)
changes_row_id :: proc(model: ^Changes_Model, index: int) -> (u64, bool) {
	if index < 0 || index >= len(model.row_ids) {return 0, false}
	return model.row_ids[index], true
}

// A title's first line, trimmed; empty lets the view name the turn.
@(private = "file", require_results)
changes_title_line :: proc(title: string) -> string {
	line := title
	if end := strings.index_any(line, "\r\n"); end >= 0 {line = line[:end]}
	return strings.trim_space(line)
}

// How long ago a Unix-millisecond time was, as the Activity rows say it, to the minute.
@(require_results)
changes_age_text :: proc(at_ms: i64, now: time.Time) -> string {
	at := time.unix(at_ms / 1000, (at_ms % 1000) * 1_000_000)
	if time.diff(at, now) < time.Minute {return "just now"}
	return fmt.tprintf("%s ago", status_age(at, now))
}

@(private = "file", require_results)
changes_minute :: proc(now: time.Time) -> i64 {
	return time.to_unix_seconds(now) / 60
}

// The name the toolbar shows: the last folder of the pane's directory.
@(private = "file", require_results)
changes_folder_name :: proc(directory: string) -> string {
	trimmed := strings.trim_right(directory, "/\\")
	if trimmed == "" {return ""}
	return filepath.base(trimmed)
}

@(private = "file", require_results)
changes_clone_text :: proc(text: string) -> string {
	if text == "" {return ""}
	cloned, err := strings.clone(text)
	return err == nil ? cloned : ""
}

@(private = "file")
changes_text_set :: proc(slot: ^string, text: string) {
	delete(slot^)
	slot^ = changes_clone_text(text)
}

@(private = "file")
changes_notice_set :: proc(model: ^Changes_Model, notice: ui.Changes_Notice, detail := "") {
	model.view.notice = notice
	changes_text_set(&model.view.detail, detail)
}

// Frees what the view owns beside the result: the row arrays and the per-file flags.
@(private = "file")
changes_view_release :: proc(model: ^Changes_Model) {
	view := &model.view
	delete(view.turns)
	delete(model.row_ids)
	for detail in model.details {delete(detail)}
	delete(model.details)
	delete(view.marked)
	delete(view.ambiguous)
	delete(view.collapsed)
	view.turns, model.row_ids, model.details, view.marked, view.ambiguous, view.collapsed =
		nil, nil, nil, nil, nil, nil
	view.files = nil
}

@(private = "file", require_results)
changes_view_alloc :: proc(model: ^Changes_Model, rows, files: int) -> bool {
	view := &model.view
	turn_rows, turn_error := make([]ui.Changes_Turn, rows)
	ids, ids_error := make([]u64, rows)
	details, details_error := make([]string, rows)
	marked, marked_error := make([]bool, files)
	ambiguous, ambiguous_error := make([]bool, files)
	collapsed, collapsed_error := make([]bool, files)
	if turn_error != nil || ids_error != nil || details_error != nil || marked_error != nil ||
	   ambiguous_error != nil || collapsed_error != nil {
		delete(turn_rows)
		delete(ids)
		delete(details)
		delete(marked)
		delete(ambiguous)
		delete(collapsed)
		return false
	}
	view.turns, model.row_ids, model.details, view.marked, view.ambiguous, view.collapsed =
		turn_rows, ids, details, marked, ambiguous, collapsed
	return true
}

// The diff's files with their marks and folds; folds come back by path.
@(private = "file")
changes_files_fill :: proc(model: ^Changes_Model, files: []turns.Diff_File, marked, ambiguous: []bool) {
	view := &model.view
	view.files = files
	for file, i in files {
		view.marked[i] = i < len(marked) && marked[i]
		view.ambiguous[i] = i < len(ambiguous) && ambiguous[i]
		_, folded := model.folded[file.new_path]
		view.collapsed[i] = folded
	}
}

// Folds or unfolds a file and remembers it by path, so the next result keeps it.
changes_model_fold :: proc(model: ^Changes_Model, index: int) {
	view := &model.view
	if index < 0 || index >= len(view.collapsed) || index >= len(view.files) {return}
	view.collapsed[index] = !view.collapsed[index]
	view.revision += 1
	path := view.files[index].new_path
	if view.collapsed[index] {
		if path in model.folded {return}
		if key, err := strings.clone(path); err == nil {model.folded[key] = {}}
	} else if key, _ := delete_key(&model.folded, path); key != "" {
		delete(key)
	}
}

// Replaces the view's turns and diff with a turn query's. Nothing here takes the result: the view
// borrows its diff and titles until the next fill, and whoever owns the result keeps it alive.
changes_fill_query :: proc(pane: ^Changes_Pane, q: ^Result_Query, now: time.Time, recording: bool) {
	model, view := &pane.model, &pane.model.view
	anchor_id, anchored := changes_row_id(model, pane.anchor)
	cursor_id, cursored := changes_row_id(model, pane.cursor)
	changes_view_release(model)
	changes_text_set(&model.repository_key, q.repository)
	label := q.error == .None ? changes_folder_name(q.worktree) : ""
	changes_text_set(&view.repository, label)
	changes_text_set(&view.worktree, "")
	view.following = false
	view.first, view.last, view.omitted = -1, -1, 0
	pane.anchor, pane.cursor = -1, -1
	model.loaded, model.shown = true, pane.scope
	view.revision += 1
	if !changes_view_alloc(model, len(q.rows), len(q.diff.files)) {
		changes_notice_set(model, .Failed, "Out of memory.")
		return
	}
	model.aged = changes_minute(now)
	for row, i in q.rows {
		model.row_ids[i] = row.id
		model.details[i] = changes_clone_text(changes_age_text(row.ended > 0 ? row.ended : row.started, now))
		view.turns[i] = {
			title   = changes_title_line(row.title),
			detail  = model.details[i],
			files   = row.files,
			added   = row.added,
			removed = row.removed,
			between = row.kind == .Between,
		}
	}
	changes_files_fill(model, q.diff.files, q.marked, q.ambiguous)
	view.first, view.last = changes_ids_range(model.row_ids, q.selected)
	// An end of the selection the result no longer holds is forgotten, so the keys start over.
	if anchored {pane.anchor = changes_index_of(model.row_ids, anchor_id)}
	if cursored {pane.cursor = changes_index_of(model.row_ids, cursor_id)}
	if pane.anchor < view.first || pane.anchor > view.last {pane.anchor = -1}
	if pane.cursor < view.first || pane.cursor > view.last {pane.cursor = -1}
	notice, detail := changes_notice_of(q.error, true, recording, len(q.rows), len(q.diff.files))
	changes_notice_set(model, notice, detail)
}

// Replaces the view's diff with a git scope's; git scopes list no turns.
changes_fill_plain :: proc(pane: ^Changes_Pane, r: ^Result_Plain) {
	model, view := &pane.model, &pane.model.view
	changes_view_release(model)
	label := r.error == .None ? changes_folder_name(r.worktree) : ""
	changes_text_set(&view.repository, label)
	changes_text_set(&view.worktree, label)
	view.following = r.error == .None && r.following
	changes_worktrees_set(model, r.worktrees)
	view.first, view.last, view.omitted = -1, -1, r.omitted
	pane.anchor, pane.cursor = -1, -1
	model.loaded, model.shown = true, pane.scope
	view.revision += 1
	if !changes_view_alloc(model, 0, len(r.diff.files)) {
		view.omitted = 0
		changes_notice_set(model, .Failed, "Out of memory.")
		return
	}
	changes_files_fill(model, r.diff.files, nil, nil)
	notice, detail := changes_notice_of(r.error, false, false, 0, len(r.diff.files))
	changes_notice_set(model, notice, detail)
}

@(private = "file")
changes_worktrees_release :: proc(model: ^Changes_Model) {
	for label in model.worktree_labels {delete(label)}
	delete(model.worktree_labels)
	for path in model.worktree_paths {delete(path)}
	delete(model.worktree_paths)
	model.worktree_labels, model.worktree_paths = nil, nil
}

// The choices the worktree dropdown lists: "Follow the agent", then each worktree by its folder name,
// with the parent folder added where two share a name. Kept in the model because the dropdown borrows them.
@(private = "file")
changes_worktrees_set :: proc(model: ^Changes_Model, paths: []string) {
	changes_worktrees_release(model)
	if len(paths) == 0 {return}
	labels, labels_error := make([]string, len(paths) + 1)
	kept, kept_error := make([]string, len(paths))
	if labels_error != nil || kept_error != nil {
		delete(labels)
		delete(kept)
		return
	}
	labels[0] = changes_clone_text(WORKTREE_FOLLOW_LABEL)
	for path, i in paths {
		kept[i] = changes_clone_text(path)
		name := changes_folder_name(path)
		shared := false
		for other, j in paths {
			if j != i && changes_folder_name(other) == name {shared = true}
		}
		if shared {
			trimmed := strings.trim_right(path, "/\\")
			parent := changes_folder_name(trimmed[:len(trimmed) - len(name)])
			labels[i + 1] = changes_clone_text(fmt.tprintf("%s \u00b7 %s", name, parent))
		} else {
			labels[i + 1] = changes_clone_text(name)
		}
	}
	model.worktree_labels, model.worktree_paths = labels, kept
}

// The label of the picked worktree in the dropdown's choices; the follow label for no pick or one the
// result no longer lists.
@(require_results)
changes_worktree_value :: proc(pane: ^Changes_Pane) -> string {
	model := &pane.model
	if len(model.worktree_labels) == 0 {return ""}
	if pane.worktree_pick != "" {
		for path, i in model.worktree_paths {
			if path == pane.worktree_pick {return model.worktree_labels[i + 1]}
		}
	}
	return model.worktree_labels[0]
}

// Picks a dropdown choice: 0 follows the agent, the others a worktree. Asks again when it changed.
changes_worktree_pick :: proc(app: ^App, pane: ^Changes_Pane, choice: int) {
	model := &pane.model
	pick := ""
	if choice > 0 && choice <= len(model.worktree_paths) {pick = model.worktree_paths[choice - 1]}
	if pick == pane.worktree_pick {return}
	cloned := changes_clone_text(pick)
	delete(pane.worktree_pick)
	pane.worktree_pick = cloned
	changes_model_changed(app, pane)
}

// Drops the content the pane shows, so the next result starts from an empty view.
@(private = "file")
changes_model_clear :: proc(pane: ^Changes_Pane) {
	model, view := &pane.model, &pane.model.view
	changes_view_release(model)
	if model.content != nil {turn_result_destroy(&model.content)}
	model.content = nil
	view.first, view.last, view.omitted = -1, -1, 0
	pane.anchor, pane.cursor = -1, -1
	model.loaded = false
	model.aged = 0
}

// Frees everything the model owns; the pane's own fields are the caller's.
changes_model_destroy :: proc(pane: ^Changes_Pane) {
	model := &pane.model
	changes_model_clear(pane)
	changes_worktrees_release(model)
	delete(model.watched)
	delete(model.repository_key)
	delete(model.view.worktree)
	delete(model.view.detail)
	delete(model.view.repository)
	for key in model.folded {delete(key)}
	delete(model.folded)
	model^ = {}
}

// Stops the pane's git watch on the worker, if it has one.
changes_model_unwatch :: proc(app: ^App, pane: ^Changes_Pane) {
	if !pane.model.watching {return}
	turn_worker_view_unwatch(app, pane.id)
	pane.model.watching = false
	changes_text_set(&pane.model.watched, "")
}

@(private = "file", require_results)
changes_plain_mode :: proc(scope: ui.Changes_Scope) -> turns.Plain_Mode {
	#partial switch scope {
	case .Staged:
		return .Staged
	case .Unstaged:
		return .Unstaged
	}
	return .Uncommitted
}

// The scope or the selection changed, or the content the pane shows may have: asks the worker for
// what the pane should show now. The answer arrives in changes_model_result.
changes_model_changed :: proc(app: ^App, pane: ^Changes_Pane) {
	model, view := &pane.model, &pane.model.view
	view.scope = pane.scope
	if model.recording != app.settings.turns.record {app.turn_hooks = .Unknown}
	model.recording = app.settings.turns.record
	changes_hooks_sync(app, model)
	if model.loaded && model.shown != pane.scope {changes_model_clear(pane)}
	model.request += 1
	if ui.changes_scope_turns(pane.scope) {
		changes_model_unwatch(app, pane)
		if !model.recording && len(model.row_ids) == 0 {
			changes_model_clear(pane)
			changes_notice_set(model, .Recording_Off)
			view.revision += 1
			mark_all_dirty(app)
			return
		}
		session: turns.Session
		if pane.scope == .Agent {session = turn_recorder_session(app, pane.source)}
		// The newest turn alone is asked for by asking for none, so a turn that ends meanwhile is followed.
		selected: []u64
		first, last := view.first, view.last
		if first >= 0 && last >= first && last < len(model.row_ids) && !(first == 0 && last == 0) {
			selected = model.row_ids[first:last + 1]
		}
		if !model.loaded {changes_notice_set(model, .Loading)}
		turn_worker_query(app, pane.id, model.request, pane.directory, pane.scope, session, selected)
	} else {
		if !model.loaded {changes_notice_set(model, .Loading)}
		if !model.watching {
			turn_worker_view_watch(app, pane.id, pane.directory)
			changes_text_set(&model.watched, pane.directory)
			model.watching = true
		}
		turn_worker_plain(
			app, pane.id, model.request, pane.directory, changes_plain_mode(pane.scope),
			turn_recorder_session(app, pane.source), pane.worktree_pick,
		)
	}
	view.revision += 1
	mark_all_dirty(app)
}

// Takes a finished read from the worker. A result for a pane that is gone, or for a request the pane has
// asked again since, is dropped. The pane keeps the result it shows until the next replaces it.
changes_model_result :: proc(app: ^App, result: Turn_Result) {
	result := result
	pane_id: u32
	request: u64
	switch r in result {
	case Result_Dirty:
		if pane := changes_find(app, r.pane); pane != nil && !ui.changes_scope_turns(pane.scope) {
			changes_model_changed(app, pane)
		}
		return
	case Result_Query:
		pane_id, request = r.pane, r.request
	case Result_Plain:
		pane_id, request = r.pane, r.request
	case nil, Result_Saved, Result_Deleted, Result_Failure:
		return
	}
	pane := changes_find(app, pane_id)
	if pane == nil || request != pane.model.request {
		turn_result_destroy(&result)
		return
	}
	model := &pane.model
	if model.content != nil {turn_result_destroy(&model.content)}
	model.content = result
	switch &r in model.content {
	case Result_Query:
		changes_fill_query(pane, &r, clock_wall(&app.clock), model.recording)
	case Result_Plain:
		changes_fill_plain(pane, &r)
		// The view watch follows the worktree the result shows.
		if model.watching && r.error == .None && r.worktree != "" && r.worktree != model.watched {
			turn_worker_view_watch(app, pane.id, r.worktree)
			changes_text_set(&model.watched, r.worktree)
		}
	case nil, Result_Dirty, Result_Saved, Result_Deleted, Result_Failure:
	}
	mark_all_dirty(app)
}

// Every turn-scope pane whose repository is in `repositories`, or whose repository is not known yet,
// reads again; a selection on the newest turn follows the new one.
changes_turns_saved :: proc(app: ^App, repositories: []string) {
	for pane in app.changes_panes {
		if !ui.changes_scope_turns(pane.scope) {
			// A pane following the agent may have a new worktree to show; its result carries no repository.
			if pane.worktree_pick == "" {changes_model_changed(app, pane)}
			continue
		}
		key := pane.model.repository_key
		if key != "" && !slice.contains(repositories, key) {continue}
		changes_model_changed(app, pane)
	}
}

// Recording was turned on or off, or recorded turns were deleted.
changes_recording_changed :: proc(app: ^App) {
	app.turn_hooks = .Unknown
	for pane in app.changes_panes {
		changes_model_changed(app, pane)
	}
}

// What a pane keeps up on each poll: the setting it last saw and the ages in its rows.
// True when the view changed and the windows need a frame.
@(require_results)
changes_model_poll :: proc(app: ^App, pane: ^Changes_Pane) -> bool {
	model, view := &pane.model, &pane.model.view
	if model.recording != app.settings.turns.record {
		changes_model_changed(app, pane)
		return false
	}
	changed := false
	wall := clock_wall(&app.clock)
	minute := changes_minute(wall)
	if minute != model.aged && len(model.details) > 0 {
		#partial switch &content in model.content {
		case Result_Query:
			if len(content.rows) == len(model.details) {
				for row, i in content.rows {
					delete(model.details[i])
					model.details[i] = changes_clone_text(
						changes_age_text(row.ended > 0 ? row.ended : row.started, wall),
					)
					view.turns[i].detail = model.details[i]
				}
				changed = true
			}
		}
		model.aged = minute
	}
	return changed
}

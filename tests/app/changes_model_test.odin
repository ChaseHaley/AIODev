package app_test

import "aio:turns"
import "aio:ui"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"

@(private = "file")
NOW_SECONDS :: 1_000_000
@(private = "file")
NOW_MS :: NOW_SECONDS * 1000

@(private = "file")
now_time :: proc() -> time.Time {
	return time.unix(NOW_SECONDS, 0)
}

// A pane in a state that never starts the turn worker: a turn scope with recording off.
@(private = "file")
pane_start :: proc(state: ^app.App, scope: ui.Changes_Scope) -> ^app.Changes_Pane {
	return app.changes_pane_create(state, "", "C:/work/odin", scope)
}

@(private = "file")
file_of :: proc(path: string) -> turns.Diff_File {
	return {old_path = path, new_path = path, added = 1}
}

@(test)
notice_follows_the_error_then_the_rows_then_the_files :: proc(t: ^testing.T) {
	notice, detail := app.changes_notice_of(.Git_Missing, true, true, 0, 0)
	testing.expect_value(t, notice, ui.Changes_Notice.Git_Missing)
	testing.expect_value(t, detail, "")
	notice, _ = app.changes_notice_of(.Not_Repository, false, false, 0, 0)
	testing.expect_value(t, notice, ui.Changes_Notice.Not_Repository)
	notice, detail = app.changes_notice_of(.Failed, true, true, 3, 2)
	testing.expect_value(t, notice, ui.Changes_Notice.Failed)
	testing.expect(t, detail != "", "a failure says something")
	notice, detail = app.changes_notice_of(.Out_Of_Memory, false, false, 0, 0)
	testing.expect_value(t, notice, ui.Changes_Notice.Failed)
	testing.expect(t, detail != "")

	notice, _ = app.changes_notice_of(.None, true, true, 0, 0)
	testing.expect_value(t, notice, ui.Changes_Notice.No_Turns)
	notice, _ = app.changes_notice_of(.None, true, false, 0, 0)
	testing.expect_value(t, notice, ui.Changes_Notice.Recording_Off)
	notice, _ = app.changes_notice_of(.None, true, false, 2, 0)
	testing.expect_value(t, notice, ui.Changes_Notice.No_Changes)
	notice, _ = app.changes_notice_of(.None, false, false, 0, 0)
	testing.expect_value(t, notice, ui.Changes_Notice.No_Changes)
	notice, detail = app.changes_notice_of(.None, true, true, 2, 1)
	testing.expect_value(t, notice, ui.Changes_Notice.None)
	testing.expect_value(t, detail, "")
}

@(test)
ids_range_finds_the_rows_a_selection_covers :: proc(t: ^testing.T) {
	ids := []u64{9, 7, 5, 3}
	first, last := app.changes_ids_range(ids, {5, 9})
	testing.expect_value(t, first, 0)
	testing.expect_value(t, last, 2)
	first, last = app.changes_ids_range(ids, {3})
	testing.expect_value(t, first, 3)
	testing.expect_value(t, last, 3)
	first, last = app.changes_ids_range(ids, {4, 8})
	testing.expect_value(t, first, -1)
	testing.expect_value(t, last, -1)
	first, last = app.changes_ids_range(ids, nil)
	testing.expect_value(t, first, -1)
	testing.expect_value(t, last, -1)
}

@(test)
ages_are_short_and_to_the_minute :: proc(t: ^testing.T) {
	testing.expect_value(t, app.changes_age_text(NOW_MS - 20_000, now_time()), "just now")
	testing.expect_value(t, app.changes_age_text(NOW_MS - 5 * 60_000, now_time()), "5m ago")
	testing.expect_value(t, app.changes_age_text(NOW_MS - 3 * 3_600_000, now_time()), "3h ago")
	testing.expect_value(t, app.changes_age_text(NOW_MS - 2 * 86_400_000, now_time()), "2d ago")
}

@(test)
a_turn_scope_without_recording_or_rows_shows_the_recording_notice_and_asks_nothing :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	pane := pane_start(&state, .Agent)
	if !testing.expect(t, pane != nil) {return}
	testing.expect_value(t, pane.model.view.notice, ui.Changes_Notice.Recording_Off)
	testing.expect_value(t, pane.model.view.scope, ui.Changes_Scope.Agent)
	testing.expect_value(t, pane.model.loaded, false)
	testing.expect_value(t, pane.model.watching, false)
	testing.expect_value(t, pane.model.request, u64(1))
	app.changes_model_changed(&state, pane)
	testing.expect_value(t, pane.model.request, u64(2))
	testing.expect_value(t, pane.model.view.notice, ui.Changes_Notice.Recording_Off)
}

@(test)
an_empty_query_says_why_there_is_nothing :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	pane := pane_start(&state, .Repository)
	if !testing.expect(t, pane != nil) {return}
	empty := app.Result_Query {
		pane = pane.id,
		repository = "0123456789abcdef",
		worktree   = "C:/work/odin",
	}
	app.changes_fill_query(pane, &empty, now_time(), true)
	testing.expect_value(t, pane.model.view.notice, ui.Changes_Notice.No_Turns)
	testing.expect_value(t, pane.model.repository_key, "0123456789abcdef")
	testing.expect_value(t, pane.model.view.repository, "odin")
	testing.expect_value(t, pane.model.loaded, true)
	app.changes_fill_query(pane, &empty, now_time(), false)
	testing.expect_value(t, pane.model.view.notice, ui.Changes_Notice.Recording_Off)

	Case :: struct {
		err:    turns.Error,
		notice: ui.Changes_Notice,
	}
	cases := []Case{{.Not_Repository, .Not_Repository}, {.Git_Missing, .Git_Missing}, {.Failed, .Failed}}
	for c in cases {
		failed := app.Result_Query {
			pane  = pane.id,
			error = c.err,
		}
		app.changes_fill_query(pane, &failed, now_time(), true)
		testing.expect_value(t, pane.model.view.notice, c.notice)
		testing.expect_value(t, len(pane.model.view.turns), 0)
		testing.expect_value(t, pane.model.view.repository, "")
		has_detail := pane.model.view.detail != ""
		testing.expect_value(t, has_detail, c.err == .Failed)
	}
}

@(test)
rows_become_turns_with_titles_ages_and_the_selection :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	pane := pane_start(&state, .Repository)
	if !testing.expect(t, pane != nil) {return}
	rows := []app.Turn_Row {
		{
			id = 7,
			kind = .Turn,
			started = NOW_MS - 400_000,
			ended = NOW_MS - 5 * 60_000,
			title = "Fix the parser\nand then more",
			files = 2,
			added = 10,
			removed = 3,
		},
		{id = 5, kind = .Between, ended = NOW_MS - 3 * 3_600_000, files = 1, added = 4},
		{id = 3, kind = .Turn, started = NOW_MS - 20_000},
	}
	files := []turns.Diff_File{file_of("a.txt"), file_of("b.txt")}
	q := app.Result_Query {
		pane       = pane.id,
		repository = "k",
		rows       = rows,
		selected   = {7, 5},
		diff       = {files = files},
		marked     = {false, true},
	}
	app.changes_fill_query(pane, &q, now_time(), true)
	view := &pane.model.view
	if !testing.expect_value(t, len(view.turns), 3) {return}
	testing.expect_value(t, view.turns[0].title, "Fix the parser")
	testing.expect_value(t, view.turns[0].detail, "5m ago")
	testing.expect_value(t, view.turns[0].files, 2)
	testing.expect_value(t, view.turns[0].added, 10)
	testing.expect_value(t, view.turns[0].removed, 3)
	testing.expect_value(t, view.turns[0].between, false)
	testing.expect_value(t, view.turns[1].between, true)
	testing.expect_value(t, view.turns[1].title, "")
	testing.expect_value(t, view.turns[1].detail, "3h ago")
	testing.expect_value(t, view.turns[2].detail, "just now")
	testing.expect_value(t, view.first, 0)
	testing.expect_value(t, view.last, 1)
	testing.expect_value(t, len(view.files), 2)
	testing.expect_value(t, len(view.marked), 2)
	testing.expect_value(t, view.marked[0], false)
	testing.expect_value(t, view.marked[1], true)
	testing.expect_value(t, view.notice, ui.Changes_Notice.None)
	testing.expect_value(t, pane.model.row_ids[0], u64(7))
	testing.expect_value(t, pane.model.row_ids[2], u64(3))
}

@(test)
a_refresh_keeps_the_selection_by_id :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	pane := pane_start(&state, .Repository)
	if !testing.expect(t, pane != nil) {return}
	files := []turns.Diff_File{file_of("a.txt")}
	three := []app.Turn_Row{{id = 3, ended = NOW_MS}, {id = 2, ended = NOW_MS}, {id = 1, ended = NOW_MS}}
	first := app.Result_Query {
		pane     = pane.id,
		rows     = three,
		selected = {2},
		diff     = {files = files},
	}
	app.changes_fill_query(pane, &first, now_time(), true)
	view := &pane.model.view
	testing.expect_value(t, view.first, 1)
	testing.expect_value(t, view.last, 1)
	pane.anchor, pane.cursor = 1, 1

	four := []app.Turn_Row {
		{id = 4, ended = NOW_MS},
		{id = 3, ended = NOW_MS},
		{id = 2, ended = NOW_MS},
		{id = 1, ended = NOW_MS},
	}
	second := app.Result_Query {
		pane     = pane.id,
		rows     = four,
		selected = {2},
		diff     = {files = files},
	}
	app.changes_fill_query(pane, &second, now_time(), true)
	testing.expect_value(t, view.first, 2)
	testing.expect_value(t, view.last, 2)
	testing.expect_value(t, pane.anchor, 2)
	testing.expect_value(t, pane.cursor, 2)

	// The newest turn is now what the selection covers; the old ends no longer lie inside it.
	five := []app.Turn_Row {
		{id = 5, ended = NOW_MS},
		{id = 4, ended = NOW_MS},
		{id = 3, ended = NOW_MS},
		{id = 2, ended = NOW_MS},
		{id = 1, ended = NOW_MS},
	}
	third := app.Result_Query {
		pane     = pane.id,
		rows     = five,
		selected = {5},
		diff     = {files = files},
	}
	app.changes_fill_query(pane, &third, now_time(), true)
	testing.expect_value(t, view.first, 0)
	testing.expect_value(t, view.last, 0)
	testing.expect_value(t, pane.anchor, -1)
	testing.expect_value(t, pane.cursor, -1)

	// A selection the result lacks selects nothing.
	gone := app.Result_Query {
		pane     = pane.id,
		rows     = five,
		selected = {99},
		diff     = {files = files},
	}
	app.changes_fill_query(pane, &gone, now_time(), true)
	testing.expect_value(t, view.first, -1)
	testing.expect_value(t, view.last, -1)
}

@(test)
folds_come_back_by_path :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	pane := pane_start(&state, .Repository)
	if pane == nil {return}
	view := &pane.model.view
	// Opened in a turn scope so no worker is involved; the scope changes under the reads below.
	pane.scope = .Uncommitted
	files := []turns.Diff_File{file_of("a.txt"), file_of("b.txt")}
	plain := app.Result_Plain {
		pane = pane.id,
		diff = {files = files},
	}
	app.changes_fill_plain(pane, &plain)
	if !testing.expect_value(t, len(view.collapsed), 2) {return}
	testing.expect_value(t, view.notice, ui.Changes_Notice.None)
	app.changes_model_fold(&pane.model, 1)
	testing.expect_value(t, view.collapsed[0], false)
	testing.expect_value(t, view.collapsed[1], true)

	reordered := []turns.Diff_File{file_of("b.txt"), file_of("c.txt"), file_of("a.txt")}
	again := app.Result_Plain {
		pane = pane.id,
		diff = {files = reordered},
	}
	app.changes_fill_plain(pane, &again)
	if !testing.expect_value(t, len(view.collapsed), 3) {return}
	testing.expect_value(t, view.collapsed[0], true)
	testing.expect_value(t, view.collapsed[1], false)
	testing.expect_value(t, view.collapsed[2], false)

	// A turn query restores them too, and unfolding is remembered.
	q := app.Result_Query {
		pane = pane.id,
		diff = {files = files},
	}
	app.changes_fill_query(pane, &q, now_time(), true)
	testing.expect_value(t, view.collapsed[0], false)
	testing.expect_value(t, view.collapsed[1], true)
	app.changes_model_fold(&pane.model, 1)
	app.changes_fill_query(pane, &q, now_time(), true)
	testing.expect_value(t, view.collapsed[1], false)
	app.changes_model_fold(&pane.model, 7)
}

@(test)
a_git_scope_result_lists_no_turns_and_counts_what_was_left_out :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	pane := pane_start(&state, .Repository)
	if pane == nil {return}
	pane.scope = .Staged
	view := &pane.model.view
	files := []turns.Diff_File{file_of("a.txt")}
	plain := app.Result_Plain {
		pane    = pane.id,
		diff    = {files = files},
		omitted  = 51,
		worktree = "C:/work/odin",
	}
	app.changes_fill_plain(pane, &plain)
	testing.expect_value(t, len(view.turns), 0)
	testing.expect_value(t, view.first, -1)
	testing.expect_value(t, view.omitted, 51)
	testing.expect_value(t, view.repository, "odin")
	testing.expect_value(t, view.notice, ui.Changes_Notice.None)

	nothing := app.Result_Plain {
		pane = pane.id,
	}
	app.changes_fill_plain(pane, &nothing)
	testing.expect_value(t, view.notice, ui.Changes_Notice.No_Changes)
	testing.expect_value(t, view.omitted, 0)

	broken := app.Result_Plain {
		pane  = pane.id,
		error = .Not_Repository,
	}
	app.changes_fill_plain(pane, &broken)
	testing.expect_value(t, view.notice, ui.Changes_Notice.Not_Repository)
	testing.expect_value(t, view.repository, "")
}

@(test)
a_git_scope_result_names_its_worktree_and_lists_every_worktree :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	pane := pane_start(&state, .Repository)
	if pane == nil {return}
	pane.scope = .Unstaged
	view := &pane.model.view
	paths := []string{"C:/work/odin", "C:/other/odin", "C:/work/odin-wt-a"}
	plain := app.Result_Plain {
		pane      = pane.id,
		diff      = {files = []turns.Diff_File{file_of("a.txt")}},
		worktree  = "C:/work/odin-wt-a",
		worktrees = paths,
		following = true,
	}
	app.changes_fill_plain(pane, &plain)
	testing.expect_value(t, view.worktree, "odin-wt-a")
	testing.expect_value(t, view.following, true)
	if !testing.expect_value(t, len(pane.model.worktree_labels), 4) {return}
	testing.expect_value(t, pane.model.worktree_labels[0], "Follow the agent")
	testing.expect_value(t, pane.model.worktree_labels[1], "odin \u00b7 work")
	testing.expect_value(t, pane.model.worktree_labels[2], "odin \u00b7 other")
	testing.expect_value(t, pane.model.worktree_labels[3], "odin-wt-a")
	testing.expect_value(t, pane.model.worktree_paths[1], "C:/other/odin")
	testing.expect_value(t, len(view.ambiguous), 1)

	plain.following = false
	app.changes_fill_plain(pane, &plain)
	testing.expect_value(t, view.following, false)
}

@(test)
a_turn_query_result_marks_ambiguous_files :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	pane := pane_start(&state, .Repository)
	if pane == nil {return}
	files := []turns.Diff_File{file_of("a.txt"), file_of("b.txt")}
	q := app.Result_Query {
		pane      = pane.id,
		diff      = {files = files},
		marked    = []bool{true, false},
		ambiguous = []bool{true, true},
	}
	app.changes_fill_query(pane, &q, now_time(), true)
	view := &pane.model.view
	if !testing.expect_value(t, len(view.ambiguous), 2) {return}
	testing.expect_value(t, view.ambiguous[0], true)
	testing.expect_value(t, view.ambiguous[1], true)
	testing.expect_value(t, view.marked[0], true)
	testing.expect_value(t, view.marked[1], false)
	testing.expect_value(t, view.following, false)
	testing.expect_value(t, view.worktree, "")
}

@(test)
turn_hooks_are_offered_only_where_a_harness_is_missing_them :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "aio-hooks-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	claude := strings.concatenate({directory, "/claude"}, context.temp_allocator)
	codex := strings.concatenate({directory, "/codex"}, context.temp_allocator)
	missing := strings.concatenate({directory, "/absent"}, context.temp_allocator)

	testing.expect(t, !app.changes_hooks_missing("", ""), "no harness, no offer")
	testing.expect(t, !app.changes_hooks_missing(missing, missing), "folders that do not exist offer nothing")
	if !testing.expect_value(t, os.make_directory(claude), nil) {return}
	testing.expect(t, app.changes_hooks_missing(claude, missing), "a folder without the file lacks the hooks")
	settings := strings.concatenate({claude, "/settings.json"}, context.temp_allocator)
	body := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"C:/aio.exe\" agent-session claude"}]}]}}`
	testing.expect_value(t, os.write_entire_file(settings, body), nil)
	testing.expect(t, app.changes_hooks_missing(claude, missing), "session hooks are not turn hooks")
	body = `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"C:/aio.exe\" turn-hook claude stop"}]}]}}`
	testing.expect_value(t, os.write_entire_file(settings, body), nil)
	testing.expect(t, app.changes_hooks_missing(claude, missing), "one of three events is not installed")
	body =
		`{"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"\"C:/aio.exe\" turn-hook claude prompt"}]}],` +
		`"Stop":[{"hooks":[{"command":"\"C:/aio.exe\" turn-hook claude stop"}]}],` +
		`"PreToolUse":[{"hooks":[{"command":"\"C:/aio.exe\" turn-hook claude edit"}]}]}}`
	testing.expect_value(t, os.write_entire_file(settings, body), nil)
	testing.expect(t, !app.changes_hooks_missing(claude, missing))

	if !testing.expect_value(t, os.make_directory(codex), nil) {return}
	testing.expect(t, app.changes_hooks_missing(claude, codex), "the other harness still lacks them")
	hooks := strings.concatenate({codex, "/hooks.json"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(hooks, body), nil)
	testing.expect(t, app.changes_hooks_missing(claude, codex), "each harness needs its own commands")
	codex_body := `{"hooks":{"a":[{"hooks":[{"command":"& \"C:/aio.exe\" turn-hook codex prompt"}]}],` +
		`"b":[{"hooks":[{"command":"& \"C:/aio.exe\" turn-hook codex stop"}]}],` +
		`"c":[{"hooks":[{"command":"& \"C:/aio.exe\" turn-hook codex edit"}]}]}}`
	testing.expect_value(t, os.write_entire_file(hooks, codex_body), nil)
	testing.expect(t, !app.changes_hooks_missing(claude, codex))
}

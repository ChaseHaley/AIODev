package app_test

import "aio:platform"
import "aio:term"
import "aio:turns"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"

@(private = "file")
TIMEOUT :: 10 * time.Second

@(private = "file")
Fixture :: struct {
	state:     app.App,
	directory: string,
}

@(private = "file")
fixture_start :: proc(
	t: ^testing.T,
	f: ^Fixture,
	name: string,
	record: bool,
	settings_extra := "",
) -> bool {
	directory, err := os.make_directory_temp("", "aio-turns-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return false}
	f.directory = directory
	recorded := record ? "cursor.blink = false\nturns.record = true\n" : "cursor.blink = false\n"
	extra := strings.concatenate({recorded, settings_extra}, context.temp_allocator)
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(settings_path, idle_shell_settings(t, extra)), nil) {
		return false
	}
	f.state = {options = {data_dir = f.directory, inactive = true}}
	f.state.app_id = fmt.aprintf("AIODev.Test.Turns.%s.%d", name, os.get_pid())
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private = "file")
fixture_stop :: proc(t: ^testing.T, f: ^Fixture) {
	app.app_destroy(&f.state)
	testing.expect_value(t, os.remove_all(f.directory), nil)
	delete(f.directory)
}

// Ticks the app until the path is gone or the timeout passes. Callers keep paths on the heap: a tick
// frees temporary memory.
@(private = "file")
tick_until_missing :: proc(state: ^app.App, path: string) -> bool {
	for start := time.tick_now(); time.tick_since(start) < TIMEOUT; {
		app.tick(state)
		if !os.exists(path) {return true}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(private = "file")
tick_until_asking :: proc(state: ^app.App, w: ^app.Window) -> bool {
	for start := time.tick_now(); time.tick_since(start) < TIMEOUT; {
		app.tick(state)
		if app.confirmation_asking(w, app.Turns_Delete) != nil {return true}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(test)
recording_writes_its_marker_and_removes_it_when_turned_off :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, "Marker", true) {return}
	marker := fmt.aprintf("%s/%s", f.state.paths.turns, turns.RECORDING_MARKER)
	defer delete(marker)
	testing.expect(t, f.state.turn_recorder.recording)
	if !testing.expect(t, os.exists(marker), "recording leaves its marker") {return}
	data, read_error := os.read_entire_file(marker, context.allocator)
	defer delete(data)
	testing.expect_value(t, read_error, nil)
	pid, decoded := turns.marker_decode(data)
	testing.expect(t, decoded)
	testing.expect_value(t, int(pid), os.get_pid())

	testing.expect(t, app.settings_save_value(&f.state, "turns.record", "false", "Could not save."))
	testing.expect(t, !f.state.turn_recorder.recording)
	testing.expect(t, !os.exists(marker), "turning recording off removes the marker")
	// Nothing was recorded, so nothing is offered for deletion.
	for _ in 0 ..< 5 {app.tick(&f.state)}
	testing.expect(t, app.confirmation_asking(f.state.windows[0], app.Turns_Delete) == nil)

	testing.expect(t, app.settings_save_value(&f.state, "turns.record", "true", "Could not save."))
	testing.expect(t, f.state.turn_recorder.recording)
	testing.expect(t, os.exists(marker), "turning recording on writes it again")
}

@(test)
turning_recording_off_offers_to_delete_the_copies :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, "Delete", true) {return}
	w := f.state.windows[0]
	segments := fmt.aprintf("%s/0123456789abcdef/%s", f.state.paths.turns, turns.SEGMENTS_NAME)
	defer delete(segments)
	if !testing.expect_value(t, os.make_directory_all(segments), nil) {return}
	segment := fmt.aprintf("%s/0000000000000001.json", segments)
	defer delete(segment)
	if !testing.expect_value(t, os.write_entire_file(segment, "{}"), nil) {return}

	// The file edit and reload an editor user makes, which is not the save path.
	settings_path := fmt.aprintf("%s/settings.ini", f.directory)
	defer delete(settings_path)
	off := idle_shell_settings(t, "cursor.blink = false\nturns.record = false\n")
	if !testing.expect_value(t, os.write_entire_file(settings_path, off), nil) {return}
	app.reload_settings(&f.state, false)
	testing.expect(t, !f.state.turn_recorder.recording)
	if !testing.expect(t, tick_until_asking(&f.state, w), "a recorded copy prompts the question") {return}
	asking := app.confirmation_current(w)
	testing.expect(t, asking != nil)
	text := app.turns_delete_text()
	testing.expect_value(t, text.title, "Delete recorded turns?")
	testing.expect_value(t, text.label, "Delete")
	testing.expect_value(t, text.cancel, "Keep")

	app.confirmation_finish(&f.state, w, true)
	turns_directory := strings.clone(f.state.paths.turns)
	defer delete(turns_directory)
	testing.expect(t, tick_until_missing(&f.state, turns_directory), "accepting deletes every copy")
}

@(test)
keeping_the_copies_leaves_them_in_place :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, "Keep", true) {return}
	w := f.state.windows[0]
	segments := fmt.aprintf("%s/0123456789abcdef/%s", f.state.paths.turns, turns.SEGMENTS_NAME)
	defer delete(segments)
	if !testing.expect_value(t, os.make_directory_all(segments), nil) {return}
	segment := fmt.aprintf("%s/0000000000000001.json", segments)
	defer delete(segment)
	if !testing.expect_value(t, os.write_entire_file(segment, "{}"), nil) {return}

	testing.expect(t, app.settings_save_value(&f.state, "turns.record", "false", "Could not save."))
	if !testing.expect(t, tick_until_asking(&f.state, w)) {return}
	app.confirmation_finish(&f.state, w, false)
	for _ in 0 ..< 10 {
		app.tick(&f.state)
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, os.exists(segment), "keeping leaves the copies")
}

@(test)
a_hook_event_for_an_unknown_pane_is_deleted :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, "Inbox", true) {return}
	event := turns.Hook_Event {
		pane_key = "0123456789abcdef0123456789abcdef",
		harness  = "claude",
		session  = "81b3816b-4fce-4b04-b3bf-9f40b8d2172e",
		cwd      = "C:/work/repo",
		prompt   = "fix the tests",
		kind     = .Prompt,
		written  = 1,
	}
	text, encoded := turns.hook_event_encode(event)
	defer delete(text)
	if !testing.expect(t, encoded) {return}
	path := fmt.aprintf(
		"%s/%s/%s-00000000000000000001.json",
		f.state.paths.turns, turns.INBOX_DIRECTORY, event.pane_key,
	)
	defer delete(path)
	if !testing.expect_value(t, os.write_entire_file(path, text), nil) {return}
	testing.expect(t, tick_until_missing(&f.state, path), "the app answers a hook by deleting its file")
	testing.expect_value(t, f.state.turn_recorder.handled, 1)
}

// How long after reporting done the fake agent reports working again.
@(private = "file")
Strip_Gap :: enum u8 {
	// Both reports arrive within one status refresh.
	Coalesced,
	// The next refresh, with no frame between.
	Next_Refresh,
	Ms_50,
	Ms_300,
}

// Replaces the pane's status snapshot with one main record, as status_refresh does.
@(private = "file")
strip_report :: proc(
	state: ^app.App,
	entry: ^app.Session_Entry,
	shown: ^[]term.Program_Status,
	report: term.Program_Status_State,
	title: string,
) {
	next := make([]term.Program_Status, 1)
	now := time.now()
	next[0] = {
		state      = report,
		title      = title,
		updated_at = now,
		since      = now,
	}
	app.turn_recorder_status(state, entry, shown^, next)
	delete(shown^)
	shown^ = next
}

@(private = "file")
strip_ticks :: proc(state: ^app.App, duration: time.Duration) {
	for start := time.tick_now(); time.tick_since(start) < duration; {
		app.tick(state)
		time.sleep(5 * time.Millisecond)
	}
}

// A fake agent runs turns back to back, each writing one new file, as a queued prompt makes it: the next
// turn starts within the same status refresh as the last one finished, the next refresh, 50 ms or 300 ms
// later. Every turn is saved alone with its own file.
@(test)
back_to_back_turns_are_each_saved_with_their_own_file :: proc(t: ^testing.T) {
	output, git_error := turns.git_run({"--version"}, {})
	if git_error != .None {return}
	turns.git_output_destroy(&output)
	work, work_error := os.make_directory_temp("", "aio-strip-*", context.allocator)
	if !testing.expect_value(t, work_error, nil) {return}
	defer delete(work)
	defer _ = turns.store_delete_all(work)
	bytes := transmute([]u8)work
	for &b in bytes {
		if b == '\\' {b = '/'}
	}
	identity := [?]string{"-c", "user.name=T", "-c", "user.email=t@example.com"}
	setup := [?][]string{{"init", "-q"}, {"commit", "-q", "--allow-empty", "-m", "base"}}
	for args in setup {
		full := slice.concatenate([][]string{identity[:], args}, context.temp_allocator)
		run, run_error := turns.git_run(full, {cwd = work}, context.temp_allocator)
		if !testing.expect(t, run_error == .None && run.code == 0, "git setup") {return}
	}

	f: Fixture
	defer fixture_stop(t, &f)
	shell := fmt.tprintf("shell.directory = \"%s\"\n", work)
	if !fixture_start(t, &f, "Strip", true, shell) {return}
	state := &f.state
	entry := app.focused_session(state, state.windows[0])
	if !testing.expect(t, entry != nil && entry.key != "", "the pane has a session") {return}
	shown: []term.Program_Status
	defer delete(shown)
	count :: 8
	// A tick frees temporary memory, and the snapshot keeps borrowing its title.
	titles: [count]string
	defer for title in titles {delete(title)}
	// The agent starts idle, which has the worker follow its repository before the first turn.
	strip_report(state, entry, &shown, .Idle, "")
	rec := &state.turn_recorder
	for start := time.tick_now(); time.tick_since(start) < TIMEOUT; {
		strip_ticks(state, 20 * time.Millisecond)
		if rec.worker != nil && app.turn_worker_pending(rec.worker) == 0 {break}
	}
	for i in 0 ..< count {
		titles[i] = fmt.aprintf("strip %d", i)
		strip_report(state, entry, &shown, .Working, titles[i])
		// The agent writes a moment after it reports working, well inside the last turn's settle.
		strip_ticks(state, 20 * time.Millisecond)
		path := fmt.tprintf("%s/strip-%02d.txt", work, i)
		if !testing.expect_value(t, os.write_entire_file(path, titles[i]), nil) {return}
		strip_ticks(state, 80 * time.Millisecond)
		// A coalesced done leaves the record working, though it entered that state anew.
		gap := Strip_Gap(i % len(Strip_Gap))
		if gap != .Coalesced || i == count - 1 {strip_report(state, entry, &shown, .Done, titles[i])}
		#partial switch gap {
		case .Ms_50:
			strip_ticks(state, 50 * time.Millisecond)
		case .Ms_300:
			strip_ticks(state, 300 * time.Millisecond)
		}
	}
	// Each turn costs the worker a dozen git runs, so it may well fall behind the agent; that must not
	// move a file into another turn.
	for start := time.tick_now(); time.tick_since(start) < 6 * TIMEOUT; {
		strip_ticks(state, 20 * time.Millisecond)
		if len(rec.ends) == 0 && app.turn_worker_pending(rec.worker) == 0 && rec.saved >= count {break}
	}
	strip_ticks(state, 100 * time.Millisecond)
	testing.expect_value(t, rec.saved, count)

	// Each saved segment is a turn with one file, and no file is in two of them.
	seen := make(map[string]bool, count, context.temp_allocator)
	stores, list_error := os.read_all_directory_by_path(state.paths.turns, context.temp_allocator)
	if !testing.expect_value(t, list_error, nil) {return}
	for store in stores {
		if store.type != .Directory {continue}
		segments := fmt.tprintf("%s/%s", store.fullpath, turns.SEGMENTS_NAME)
		files, _ := os.read_all_directory_by_path(segments, context.temp_allocator)
		for file in files {
			data, read_error := os.read_entire_file(file.fullpath, context.temp_allocator)
			if !testing.expect_value(t, read_error, nil) {continue}
			segment, decoded := turns.segment_decode(data, context.temp_allocator)
			if !testing.expectf(t, decoded, "%s does not decode", file.name) {continue}
			testing.expect_value(t, segment.kind, turns.Segment_Kind.Turn)
			for change in segment.changes {
				testing.expectf(t, !seen[change.path], "%s is in two turns", change.path)
				seen[change.path] = true
			}
			testing.expectf(t, len(segment.changes) == 1, "%q has %v", segment.title, segment.changes)
		}
	}
	testing.expect_value(t, len(seen), count)
}

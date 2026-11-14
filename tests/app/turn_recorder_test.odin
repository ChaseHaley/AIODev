package app_test

import "aio:platform"
import "aio:turns"
import "core:fmt"
import "core:os"
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
fixture_start :: proc(t: ^testing.T, f: ^Fixture, name: string, record: bool) -> bool {
	directory, err := os.make_directory_temp("", "aio-turns-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return false}
	f.directory = directory
	extra := record ? "cursor.blink = false\nturns.record = true\n" : "cursor.blink = false\n"
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

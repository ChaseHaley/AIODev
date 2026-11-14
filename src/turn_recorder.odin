package main

import "aio:agent"
import platform_api "aio:platform"
import "aio:procinfo"
import "aio:term"
import "aio:turns"
import "aio:ui"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// What the main thread knows of agent turns: where each pane's turn begins and ends, from OSC program
// status and from the hook inbox, and the recording switch. The turn worker does every git command;
// this file only decides when to tell it. See turn_worker.odin.

// An End waits this long so the last file write of the turn reaches the watchers before it drains them.
@(private)
TURN_SETTLE :: 150 * time.Millisecond
@(private)
TURN_MAINTAIN :: 6 * time.Hour
// While a question waits for a window that can show it.
@(private)
TURN_ASK_POLL :: 250 * time.Millisecond
@(private)
TURN_RETENTION_DEFAULT :: 14

// The question asked after recording is turned off while copies exist.
Turns_Delete :: struct {}

// One pane's turn. Strings are owned; session.pane_key borrows key.
@(private)
Turn_Pane :: struct {
	key:          string,
	turn:         turns.Pane_Turn,
	session:      turns.Session,
	// A hook named the session, which then outranks what the pane's process says.
	hooked:       bool,
	// The worker was asked to watch the pane's repository.
	warmed:       bool,
	// The prompt of the turn a hook announced.
	title:        string,
	// The status record's title when the turn began.
	status_title: string,
}

// A turn that ended and waits TURN_SETTLE before the worker saves it. Self-contained, so the pane may
// close or begin a new turn meanwhile.
@(private)
Turn_End :: struct {
	key:       string,
	session:   turns.Session,
	started:   i64,
	ended:     i64,
	end_state: turns.End_State,
	title:     string,
	sources:   bit_set[turns.Signal_Source],
	due:       time.Tick,
}

Turn_Recorder :: struct {
	worker:       ^Turn_Worker,
	panes:        [dynamic]Turn_Pane,
	ends:         [dynamic]Turn_End,
	inbox:        ^turns.Watch,
	// Set by the inbox watch's thread (atomic), cleared when the main thread lists the inbox.
	inbox_woken:  bool,
	// Inbox files a posted job will delete, so later drains skip them. Keys are owned.
	taken:        map[string]struct{},
	maintain_due: time.Tick,
	// The setting turns_apply_settings last saw, and whether it has run at all.
	wanted:       bool,
	configured:   bool,
	// Recording is running: marker written, panes followed.
	recording:    bool,
	// Recording was turned off, so the question about the copies is due.
	ask_delete:   bool,
	// For the harness: segments saved this run, inbox files handled, the last failure's word.
	saved:        int,
	handled:      int,
	last_error:   string,
}

@(private, require_results)
turn_now :: proc(app: ^App) -> i64 {
	return turn_unix_ms(clock_wall(&app.clock))
}

@(private, require_results)
turn_unix_ms :: proc(t: time.Time) -> i64 {
	return time.to_unix_nanoseconds(t) / i64(time.Millisecond)
}

// Replaces an owned string; keeps the old one when copying fails.
@(private)
turn_text_set :: proc(dst: ^string, value: string) {
	if dst^ == value {return}
	copied, err := strings.clone(value)
	if err != nil {
		log.errorf("copying turn text failed: %v", err)
		return
	}
	delete(dst^)
	dst^ = copied
}

@(private, require_results)
turn_pane_find :: proc(rec: ^Turn_Recorder, key: string) -> ^Turn_Pane {
	for &pane in rec.panes {
		if pane.key == key {return &pane}
	}
	return nil
}

@(private, require_results)
turn_pane_ensure :: proc(rec: ^Turn_Recorder, key: string) -> ^Turn_Pane {
	if found := turn_pane_find(rec, key); found != nil {return found}
	copied, err := strings.clone(key)
	if err != nil {
		log.errorf("copying a pane key failed: %v", err)
		return nil
	}
	if _, append_error := append(&rec.panes, Turn_Pane{key = copied}); append_error != nil {
		log.errorf("tracking a pane's turns failed: %v", append_error)
		delete(copied)
		return nil
	}
	pane := &rec.panes[len(rec.panes) - 1]
	pane.session.pane_key = pane.key
	return pane
}

@(private)
turn_pane_destroy :: proc(pane: ^Turn_Pane) {
	delete(pane.key)
	delete(pane.session.harness)
	delete(pane.session.session)
	delete(pane.title)
	delete(pane.status_title)
}

@(private)
turn_end_destroy :: proc(end: ^Turn_End) {
	delete(end.key)
	delete(end.session.harness)
	delete(end.session.session)
	delete(end.title)
}

@(private)
turn_panes_reset :: proc(rec: ^Turn_Recorder) {
	for &pane in rec.panes {turn_pane_destroy(&pane)}
	clear(&rec.panes)
	for &end in rec.ends {turn_end_destroy(&end)}
	clear(&rec.ends)
	for path in rec.taken {delete(path)}
	clear(&rec.taken)
}

@(private, require_results)
turn_entry_find :: proc(app: ^App, key: string) -> ^Session_Entry {
	for &entry in app.sessions {
		if entry.key == key {return &entry}
	}
	return nil
}

// Starts the worker on first use. nil when the instance has no turns directory or the thread failed.
@(private, require_results)
turn_worker_ensure :: proc(app: ^App) -> ^Turn_Worker {
	rec := &app.turn_recorder
	if rec.worker != nil {return rec.worker}
	if app.paths.turns == "" {
		log.error("the turn worker needs a turns directory")
		return nil
	}
	rec.worker = turn_worker_create(app.paths.turns, process_worker_platform(app))
	if rec.worker == nil {log.error("starting the turn worker failed")}
	return rec.worker
}

@(private, require_results)
turn_post :: proc(app: ^App, job: Turn_Job) -> bool {
	worker := turn_worker_ensure(app)
	if worker == nil {return false}
	if !turn_worker_post(worker, job) {
		log.error("queueing a turn job failed")
		return false
	}
	return true
}

turn_worker_query :: proc(
	app: ^App,
	pane: u32,
	request: u64,
	directory: string,
	scope: ui.Changes_Scope,
	session: turns.Session,
	selected: []u64,
) {
	job := Job_Query {
		pane      = pane,
		request   = request,
		directory = directory,
		agent     = scope == .Agent,
		session   = session,
		selected  = selected,
	}
	_ = turn_post(app, job)
}

turn_worker_plain :: proc(app: ^App, pane: u32, request: u64, directory: string, mode: turns.Plain_Mode) {
	_ = turn_post(app, Job_Plain{pane = pane, request = request, directory = directory, mode = mode})
}

turn_worker_view_watch :: proc(app: ^App, pane: u32, directory: string) {
	_ = turn_post(app, Job_View_Watch{pane = pane, directory = directory})
}

// Never starts the worker: a pane that was never watched has nothing to stop, and panes are destroyed
// after the recorder at exit.
turn_worker_view_unwatch :: proc(app: ^App, pane: u32) {
	worker := app.turn_recorder.worker
	if worker == nil {return}
	_ = turn_worker_post(worker, Job_View_Unwatch{pane = pane})
}

// The session the recorder last knew for a pane key; strings stay valid until the recorder next
// changes, so callers use them at once.
@(require_results)
turn_recorder_session :: proc(app: ^App, pane_key: string) -> turns.Session {
	if pane := turn_pane_find(&app.turn_recorder, pane_key); pane != nil {return pane.session}
	return {pane_key = pane_key}
}

// Main status

@(private, require_results)
turn_state :: proc(state: term.Program_Status_State) -> turns.Status_State {
	switch state {
	case .Idle:
		return .Idle
	case .Working:
		return .Working
	case .Done:
		return .Done
	case .Blocked:
		return .Blocked
	case .Error:
		return .Error
	}
	return .Idle
}

@(private, require_results)
turn_records :: proc(statuses: []term.Program_Status) -> []turns.Record_Status {
	records := make([]turns.Record_Status, len(statuses), context.temp_allocator)
	for status, i in statuses {
		records[i] = {status.id, turn_state(status.state), turn_unix_ms(status.updated_at)}
	}
	return records
}

// The title of the record turns.main_status follows, which only reports its state: the one with an
// empty id, else the most recently updated top-level record.
@(private, require_results)
turn_main_title :: proc(statuses: []term.Program_Status) -> string {
	best := -1
	for status, i in statuses {
		if status.id == "" {best = i; break}
	}
	if best < 0 {
		latest: i64
		for status, i in statuses {
			if strings.index_byte(status.id, '/') >= 0 {continue}
			updated := turn_unix_ms(status.updated_at)
			if best >= 0 && updated <= latest {continue}
			best, latest = i, updated
		}
	}
	if best < 0 {return ""}
	status := statuses[best]
	return status.title != "" ? status.title : status.message
}

// Called by status_refresh with the snapshot being replaced and its replacement.
turn_recorder_status :: proc(app: ^App, entry: ^Session_Entry, previous, next: []term.Program_Status) {
	rec := &app.turn_recorder
	if !rec.recording || entry.key == "" {return}
	before, had_before := turns.main_status(turn_records(previous))
	after, has_after := turns.main_status(turn_records(next))
	signal, found := turns.status_signal(before, had_before, after, has_after)
	if !found && !has_after {return}
	pane := turn_pane_ensure(rec, entry.key)
	if pane == nil {return}
	if has_after {turn_warm(app, pane, entry)}
	if !found {return}
	title := turn_main_title(next)
	if title == "" {title = turn_main_title(previous)}
	_ = turn_signal(app, pane, entry, signal, title, "", "")
}

// Has the worker find the pane's repository and baseline it, so the turn's Begin drains quickly and
// an edit made right after the agent reports working is not missed.
@(private)
turn_warm :: proc(app: ^App, pane: ^Turn_Pane, entry: ^Session_Entry) {
	if pane.warmed {return}
	pane.warmed = true
	directory := turn_directory(app, entry, session_processes(app))
	if directory == "" {return}
	_ = turn_post(app, Job_Watch_Root{directory = directory})
}

// Where the pane's agent works: its program's own directory, which a shell's `cd` leaves behind (a
// shell process keeps the folder it started in unless the shell reports its directory). The program is
// chosen from `processes` read now, not from polling, which may not have seen it yet.
@(private, require_results)
turn_directory :: proc(app: ^App, entry: ^Session_Entry, processes: []procinfo.Process_Info) -> string {
	program: u32
	if processes != nil {
		root := term.process_id(entry.session)
		index := procinfo.process_program(
			processes, root, program_reporters(entry), program_polled(entry),
			program_at_root(app, processes, root),
		)
		if index >= 0 {program = processes[index].id}
	}
	directory, _ := pane_directory_of(entry, program)
	return directory
}

// A session closed; a turn open in its pane ends as Ended.
turn_recorder_closed :: proc(app: ^App, entry: ^Session_Entry) {
	rec := &app.turn_recorder
	if !rec.recording || entry.key == "" {return}
	pane := turn_pane_find(rec, entry.key)
	if pane == nil {return}
	_ = turn_signal(app, pane, entry, .Ended, "", "", "")
	for &candidate, i in rec.panes {
		if &candidate != pane {continue}
		turn_pane_destroy(pane)
		ordered_remove(&rec.panes, i)
		break
	}
}

// Feeds one signal to the pane's state machine and acts on the boundary it reports. `ack` is the inbox
// file a Begin deletes once the worker has a baseline; `fallback` is a directory when the pane has none.
@(private)
turn_signal :: proc(
	app: ^App,
	pane: ^Turn_Pane,
	entry: ^Session_Entry,
	signal: turns.Pane_Signal,
	status_title, ack, fallback: string,
) -> turns.Boundary {
	boundary := turns.pane_turn_signal(&pane.turn, signal, turn_now(app))
	switch boundary {
	case .Begin:
		turn_begin(app, pane, entry, status_title, ack, fallback)
	case .End:
		turn_end(app, pane, status_title)
	case .None:
	}
	return boundary
}

@(private)
turn_begin :: proc(app: ^App, pane: ^Turn_Pane, entry: ^Session_Entry, status_title, ack, fallback: string) {
	// A turn that just ended must reach the worker before the next one begins in the same pane.
	turn_end_flush(app, pane.key)
	turn_text_set(&pane.status_title, status_title)
	// Polling may not have seen a program that just started, and without it the pane's program is only
	// found by looking at the processes; the report that began the turn came from one of them.
	processes := session_processes(app)
	if !pane.hooked {
		running := pane_agent(app, entry, processes)
		names := agent.HARNESS_NAMES
		turn_text_set(&pane.session.harness, names[running.launch.harness])
		session, _ := agent_session(app, entry, running)
		turn_text_set(&pane.session.session, session)
	}
	directory := turn_directory(app, entry, processes)
	if directory == "" {directory = fallback}
	job := Job_Begin {
		pane_key  = pane.key,
		session   = pane.session,
		directory = directory,
		started   = pane.turn.started,
		ack       = ack,
	}
	if !turn_post(app, job) {
		if ack != "" {turn_inbox_remove(ack)}
	} else if ack != "" {
		turn_inbox_claim(&app.turn_recorder, ack)
	}
}

@(private)
turn_end :: proc(app: ^App, pane: ^Turn_Pane, status_title: string) {
	rec := &app.turn_recorder
	title := pane.title
	if title == "" {title = status_title}
	if title == "" {title = pane.status_title}
	end := Turn_End {
		started   = pane.turn.started,
		ended     = turn_now(app),
		end_state = pane.turn.end_state,
		sources   = pane.turn.sources,
		due       = time.tick_add(clock_now(&app.clock), TURN_SETTLE),
	}
	key, key_error := strings.clone(pane.key)
	harness, harness_error := strings.clone(pane.session.harness)
	session, session_error := strings.clone(pane.session.session)
	copied_title, title_error := strings.clone(title)
	end.key, end.title = key, copied_title
	end.session = {key, harness, session}
	turn_text_set(&pane.title, "")
	turn_text_set(&pane.status_title, "")
	if key_error != nil || harness_error != nil || session_error != nil || title_error != nil {
		log.error("copying a finished turn failed")
		turn_end_destroy(&end)
		return
	}
	if _, append_error := append(&rec.ends, end); append_error != nil {
		log.errorf("queueing a finished turn failed: %v", append_error)
		turn_end_destroy(&end)
	}
}

@(private)
turn_end_post :: proc(app: ^App, end: ^Turn_End) {
	_ = turn_post(
		app,
		Job_End {
			pane_key = end.key,
			session = end.session,
			started = end.started,
			ended = end.ended,
			end_state = end.end_state,
			title = end.title,
			sources = end.sources,
		},
	)
}

// Posts and forgets a pane's waiting End at once.
@(private)
turn_end_flush :: proc(app: ^App, key: string) {
	rec := &app.turn_recorder
	for i := len(rec.ends) - 1; i >= 0; i -= 1 {
		if rec.ends[i].key != key {continue}
		turn_end_post(app, &rec.ends[i])
		turn_end_destroy(&rec.ends[i])
		ordered_remove(&rec.ends, i)
	}
}

// Hook inbox

@(private)
turn_inbox_wake :: proc "contextless" (data: rawptr) {
	app := (^App)(data)
	sync.atomic_store(&app.turn_recorder.inbox_woken, true)
	context = runtime.default_context()
	_ = platform_api.wake(&app.platform)
}

@(private)
turn_inbox_remove :: proc(path: string) {
	if err := os.remove(path); err != nil && err != .Not_Exist {
		log.errorf("removing the hook event %q failed: %v", path, err)
	}
}

@(private, require_results)
turn_inbox_path :: proc(app: ^App) -> string {
	return fmt.tprintf("%s/%s", app.paths.turns, turns.INBOX_DIRECTORY)
}

// Handles every event file waiting. The watch is emptied first, so a file written meanwhile wakes again.
@(private)
turn_inbox_drain :: proc(app: ^App) {
	rec := &app.turn_recorder
	if rec.inbox == nil {return}
	changed := make([dynamic]string, context.temp_allocator)
	_ = turns.watch_take(rec.inbox, &changed, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(turn_inbox_path(app), context.temp_allocator)
	if err != nil {
		if err != .Not_Exist {log.errorf("listing the hook inbox failed: %v", err)}
		return
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	listed := make(map[string]struct{}, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".json") {continue}
		listed[entry.fullpath] = {}
		if entry.fullpath in rec.taken {continue}
		turn_inbox_handle(app, entry.fullpath, entry.size)
	}
	// A file the worker deleted is no longer claimed.
	gone := make([dynamic]string, context.temp_allocator)
	for path in rec.taken {
		if path not_in listed {_, _ = append(&gone, path)}
	}
	for path in gone {
		delete_key(&rec.taken, path)
		delete(path)
	}
}

// A file a posted job will delete: later drains must not handle it again while it is still listed.
@(private)
turn_inbox_claim :: proc(rec: ^Turn_Recorder, path: string) {
	copied, err := strings.clone(path)
	if err != nil {return}
	rec.taken[copied] = {}
}

// Every outcome but a Begin that keeps the file for the worker deletes it, since the hook waits for that.
@(private)
turn_inbox_handle :: proc(app: ^App, path: string, size: i64) {
	rec := &app.turn_recorder
	rec.handled += 1
	if size > turns.HOOK_EVENT_LIMIT {
		turn_inbox_remove(path)
		return
	}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		turn_inbox_remove(path)
		return
	}
	event, decoded := turns.hook_event_decode(data, context.temp_allocator)
	if !decoded {
		turn_inbox_remove(path)
		return
	}
	entry := turn_entry_find(app, event.pane_key)
	if entry == nil {
		turn_inbox_remove(path)
		return
	}
	pane := turn_pane_ensure(rec, event.pane_key)
	if pane == nil {
		turn_inbox_remove(path)
		return
	}
	if event.session != "" {
		turn_text_set(&pane.session.harness, event.harness)
		turn_text_set(&pane.session.session, event.session)
		pane.hooked = true
	}
	switch event.kind {
	case .Prompt:
		if pane.title == "" {turn_text_set(&pane.title, event.prompt)}
		boundary := turn_signal(app, pane, entry, .Prompt, "", path, event.cwd)
		if boundary != .Begin {
			// The worker may still hold a queued Begin of this turn; acking through it keeps the order.
			job := Job_Edit{pane_key = pane.key, ack = path}
			if turn_post(app, job) {turn_inbox_claim(rec, path)} else {turn_inbox_remove(path)}
		}
	case .Edit:
		job := Job_Edit{pane_key = pane.key, paths = event.paths, ack = path}
		if len(event.paths) > 0 && turn_post(app, job) {
			turn_inbox_claim(rec, path)
		} else {
			turn_inbox_remove(path)
		}
	case .Stop:
		turn_inbox_remove(path)
		_ = turn_signal(app, pane, entry, .Stop, "", "", "")
	}
}

// Recording

// The marker tells hooks the app records and which process to look for; the inbox is where they write.
@(private, require_results)
turn_marker_write :: proc(app: ^App) -> bool {
	directory := app.paths.turns
	if err := os.make_directory_all(turn_inbox_path(app)); err != nil {
		log.errorf("creating the hook inbox failed: %v", err)
		return false
	}
	marker := fmt.tprintf("%s/%s", directory, turns.RECORDING_MARKER)
	pending := fmt.tprintf("%s.tmp", marker)
	text := turns.marker_encode(u32(os.get_pid()), context.temp_allocator)
	if err := os.write_entire_file(pending, text); err != nil {
		log.errorf("writing the recording marker failed: %v", err)
		return false
	}
	_ = os.remove(marker)
	if err := os.rename(pending, marker); err != nil {
		log.errorf("publishing the recording marker failed: %v", err)
		_ = os.remove(pending)
		return false
	}
	return true
}

@(private)
turn_marker_remove :: proc(app: ^App) {
	if app.paths.turns == "" {return}
	marker := fmt.tprintf("%s/%s", app.paths.turns, turns.RECORDING_MARKER)
	if err := os.remove(marker); err != nil && err != .Not_Exist {
		log.errorf("removing the recording marker failed: %v", err)
	}
}

// Hooks only write while the marker exists, so a failed watch withdraws it: nobody would answer them.
@(private)
turn_inbox_start :: proc(app: ^App) {
	rec := &app.turn_recorder
	turns.watch_stop(rec.inbox)
	rec.inbox = nil
	if !turn_marker_write(app) {return}
	wake := turns.Watch_Wake{app, turn_inbox_wake}
	watch, started := turns.watch_start(turn_inbox_path(app), false, wake, runtime.heap_allocator())
	if !started {
		log.error("watching the hook inbox failed")
		turn_marker_remove(app)
		return
	}
	rec.inbox = watch
	turn_inbox_drain(app)
}

@(private)
turn_maintain_post :: proc(app: ^App) {
	rec := &app.turn_recorder
	days := app.settings.turns.retention_days
	if days <= 0 {days = TURN_RETENTION_DEFAULT}
	_ = turn_post(app, Job_Maintain{days = days, now = turn_now(app)})
	rec.maintain_due = time.tick_add(clock_now(&app.clock), TURN_MAINTAIN)
}

@(private)
turn_recording_start :: proc(app: ^App) {
	rec := &app.turn_recorder
	if app.paths.turns == "" {
		log.error("turn recording needs a turns directory")
		return
	}
	rec.recording = true
	rec.ask_delete = false
	turn_inbox_start(app)
	turn_maintain_post(app)
	for &entry in app.sessions {
		if entry.key == "" || len(entry.statuses) == 0 {continue}
		if pane := turn_pane_ensure(rec, entry.key); pane != nil {turn_warm(app, pane, &entry)}
	}
}

@(private)
turn_recording_stop :: proc(app: ^App) {
	rec := &app.turn_recorder
	rec.recording = false
	if rec.worker != nil {_ = turn_worker_post(rec.worker, Job_Stop{})}
	turn_marker_remove(app)
	turns.watch_stop(rec.inbox)
	rec.inbox = nil
	turn_panes_reset(rec)
	rec.ask_delete = true
}

// Follows turns.record: called when a settings revision applies, and once from app_init.
turns_apply_settings :: proc(app: ^App) {
	rec := &app.turn_recorder
	want := app.settings.turns.record
	first := !rec.configured
	rec.configured = true
	changed := want != rec.wanted
	rec.wanted = want
	switch {
	case changed && want:
		turn_recording_start(app)
	case changed:
		turn_recording_stop(app)
	case first:
		// A marker left by a run that crashed would have hooks waiting for an app that does not read them.
		turn_marker_remove(app)
	}
	if changed {changes_recording_changed(app)}
}

// Whether any store under the turns directory holds a segment file.
@(private, require_results)
turns_has_segments :: proc(app: ^App) -> bool {
	stores, err := os.read_all_directory_by_path(app.paths.turns, context.temp_allocator)
	if err != nil {return false}
	for store in stores {
		if store.type != .Directory || store.name == turns.INBOX_DIRECTORY {continue}
		segments := fmt.tprintf("%s/%s", store.fullpath, turns.SEGMENTS_NAME)
		files, files_error := os.read_all_directory_by_path(segments, context.temp_allocator)
		if files_error != nil {continue}
		for file in files {
			if file.type != .Directory && strings.has_suffix(file.name, turns.SEGMENT_EXTENSION) {return true}
		}
	}
	return false
}

// Asks once a window can show the question and nothing else is being asked there.
@(private)
turns_ask_delete :: proc(app: ^App) {
	rec := &app.turn_recorder
	if rec.recording {rec.ask_delete = false; return}
	w := window_focused_or_recent(app)
	if w == nil || confirmation_shown(w) != nil {return}
	rec.ask_delete = false
	if turns_has_segments(app) {confirmation_ask(app, w, Turns_Delete{}, extended = true, focus = .Cancel)}
}

turns_delete_text :: proc() -> Confirmation_Text {
	return {
		title = "Delete recorded turns?",
		body = "Recording is off. Keep the copies until they expire, or delete them now.",
		label = "Delete",
		cancel = "Keep",
	}
}

@(private)
turns_delete_finish :: proc(app: ^App, accepted: bool) {
	if !accepted {return}
	if !turn_post(app, Job_Delete_All{}) {notify(app, .Error, "Could not delete the recorded turns.")}
}

// Results and timers

@(private)
turn_results :: proc(app: ^App) {
	rec := &app.turn_recorder
	if rec.worker == nil {return}
	results := make([dynamic]Turn_Result, context.temp_allocator)
	turn_worker_take(rec.worker, &results)
	for &result in results {
		switch &value in result {
		case Result_Saved:
			rec.saved += value.segments
			changes_turns_saved(app, value.repositories)
			turn_result_destroy(&result)
		case Result_Query, Result_Plain:
			// The model owns both from here.
			changes_model_result(app, result)
		case Result_Dirty:
			changes_model_result(app, result)
			turn_result_destroy(&result)
		case Result_Deleted:
			if value.error == .None {
				notify(app, .Info, "Recorded turns deleted.")
			} else {
				notify(app, .Error, "Could not delete the recorded turns.")
			}
			// Deleting removed the marker and inbox with the rest.
			if rec.recording {turn_inbox_start(app)}
			changes_recording_changed(app)
			turn_result_destroy(&result)
		case Result_Failure:
			log.errorf("turn recording: %s: %v", value.what, value.error)
			turn_text_set(&rec.last_error, value.what)
			turn_result_destroy(&result)
		}
	}
}

// Advances everything the recorder waits for; cheap when nothing is.
turns_tick :: proc(app: ^App) {
	rec := &app.turn_recorder
	turn_results(app)
	if sync.atomic_exchange(&rec.inbox_woken, false) {turn_inbox_drain(app)}
	if rec.ask_delete {turns_ask_delete(app)}
	now := clock_now(&app.clock)
	for i := len(rec.ends) - 1; i >= 0; i -= 1 {
		if time.tick_diff(now, rec.ends[i].due) > 0 {continue}
		turn_end_post(app, &rec.ends[i])
		turn_end_destroy(&rec.ends[i])
		ordered_remove(&rec.ends, i)
	}
	if rec.recording && time.tick_diff(now, rec.maintain_due) <= 0 {turn_maintain_post(app)}
}

@(require_results)
turns_deadline :: proc(app: ^App) -> (next: time.Tick, pending: bool) {
	rec := &app.turn_recorder
	now := clock_now(&app.clock)
	if sync.atomic_load(&rec.inbox_woken) {return now, true}
	for end in rec.ends {next, pending = earliest(next, pending, end.due)}
	if rec.recording {next, pending = earliest(next, pending, rec.maintain_due)}
	if rec.ask_delete {next, pending = earliest(next, pending, time.tick_add(now, TURN_ASK_POLL))}
	return
}

// Stops recording's effects, joins the worker and frees everything. Accepts the zero value.
turn_recorder_destroy :: proc(app: ^App) {
	rec := &app.turn_recorder
	if rec.recording {turn_marker_remove(app)}
	turns.watch_stop(rec.inbox)
	// Turns that just ended are saved before the worker goes; it runs queued jobs on destroy.
	if rec.worker != nil {
		for &end in rec.ends {turn_end_post(app, &end)}
	}
	turn_worker_destroy(rec.worker)
	turn_panes_reset(rec)
	delete(rec.panes)
	delete(rec.ends)
	delete(rec.taken)
	delete(rec.last_error)
	rec^ = {}
}

when AIO_CONTROL {
	turns_state_report :: proc(r: ^State_Report, app: ^App) {
		rec := &app.turn_recorder
		open := 0
		for pane in rec.panes {
			if pane.turn.open {open += 1}
		}
		pending := rec.worker != nil ? turn_worker_pending(rec.worker) : 0
		state_value(r, "turns.recording", rec.recording)
		state_value(r, "turns.open", open)
		state_value(r, "turns.saved", rec.saved)
		state_value(r, "turns.pending", pending)
		state_value(r, "turns.inbox", rec.handled)
		state_text(r, "turns.last_error", rec.last_error)
		asking := false
		for w in app.windows {
			if confirmation_asking(w, Turns_Delete) != nil {asking = true}
		}
		// confirm.open reports only the close question, so this one has its own key.
		state_value(r, "turns.delete_open", asking)
	}
}

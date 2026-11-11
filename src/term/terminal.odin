package term

import "aio:ghostty"
import "aio:pty"
import "base:runtime"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Color :: [3]u8

Colors :: struct {
	foreground, background, cursor: Color,
	palette:                        [16]Color,
}

// color_from_ghostty converts libghostty's RGB struct to the opaque colour value every caller
// shares.
color_from_ghostty :: proc(rgb: ghostty.Color_Rgb) -> Color {
	return {rgb.r, rgb.g, rgb.b}
}

// ghostty_from_color is the inverse of color_from_ghostty.
ghostty_from_color :: proc(c: Color) -> ghostty.Color_Rgb {
	return {c.r, c.g, c.b}
}

Geometry :: struct {
	columns, rows:                 u16,
	cell_width, cell_height:       u32,
	surface_width, surface_height: u32,
	padding_left, padding_top:     u32,
}

process_id :: proc(s: ^Session) -> u32 {return pty.process_id(&s.pty)}
process_image :: proc(s: ^Session, allocator := context.allocator) -> string {
	return pty.process_image(&s.pty, allocator)
}

Config :: struct {
	command_line, working_directory: string,
	title:                           string,
	refresh_environment:             bool,
	// Up to MAX_HOST_ENVIRONMENT variables the host adds for this session, and a directory added
	// to the end of its PATH.
	environment:                     []pty.Env_Var,
	path_append:                     string,
	geometry:                        Geometry,
	options:                         Options,
	colors:                          Colors,
	// Text written to the screen before the shell starts, which then draws below it.
	preface:                         string,
	// Stamps program status reports. create keeps it for the session's life, so restart ignores it;
	// the zero value reads the system clock.
	wall_clock:                      Wall_Clock,
}

// A time-of-day source the reader thread can call.
Wall_Clock :: struct {
	procedure: proc(user: rawptr) -> time.Time,
	user:      rawptr,
}

// Everything about a session a running app can change. create, restart and configure all install
// the whole set, so no caller has to follow creation with a separate configure. The zero value is
// libghostty's own default: a steady block cursor, no retained scrollback and no status reports.
Options :: struct {
	scrollback_lines:                     int,
	cursor:                               Cursor_Style,
	cursor_blink, program_status_enabled: bool,
}

// Host variables a session accepts on top of the three terminal ones, on the stack of spawn. The
// app supplies at most five (pane id, instance name, aio path, terminal session key and agent record
// path); the rest is headroom for a new one.
MAX_HOST_ENVIRONMENT :: 6

Wake :: struct {
	procedure: proc(user: rawptr),
	user:      rawptr,
}

Status_Kind :: enum {
	Running,
	Exited,
	Failed,
}

Status :: struct {
	kind:      Status_Kind,
	exit_code: u32,
	message:   string,
}

// The session's child-process lifecycle; nil means no process: none spawned yet, a headless replay,
// or one stop_process has released. Only the process_* transitions write Session.process, under
// Session.mutex, so the main, reader and waiter threads always agree on one phase.
@(private)
Process :: union {
	Process_Running,
	Process_Exited,
	Process_Failed,
	Process_Stopping,
}

@(private)
Process_Running :: struct {}

// The process ended by itself. The waiter has closed the console, so the reader is draining the
// final output to EOF.
@(private)
Process_Exited :: struct {
	code: u32,
}

// Starting the process failed. The message belongs to the session allocator and may be empty.
@(private)
Process_Failed :: struct {
	message: string,
}

// stop_process is taking the process down. A process that had already exited drains its final
// output; one still running has its pending reads cancelled so closing a pane is fast (WORK-306).
@(private)
Process_Stopping :: struct {
	drain: bool,
}

Error :: enum {
	None,
	Out_Of_Memory,
	Terminal_Failed,
}

// Record_Start_Error reports why a capture could not begin.
Record_Start_Error :: enum {
	None,
	Already_Recording,
	File_Failed,
	Out_Of_Memory,
}

// Record_Stop reports how a capture ended. Faulted means a disk error ended it early, so the file
// holds only the bytes written before the error.
Record_Stop :: enum {
	Not_Recording,
	Stopped,
	Faulted,
}

@(private)
WRITE_QUEUE_LIMIT :: 4 * 1024 * 1024
@(private)
RENDER_HOLD_LIMIT :: time.Second
@(private)
READ_CHUNK :: 64 * 1024

Session :: struct {
	allocator:                                                runtime.Allocator,
	callback_context:                                         runtime.Context,
	wake:                                                     Wake,
	wall_clock:                                               Wall_Clock,
	// Guards the libghostty objects below, the process phase and the render hold.
	mutex:                                                    sync.Mutex,
	terminal:                                                 ghostty.Terminal,
	key_encoder:                                              ghostty.Key_Encoder,
	key_event:                                                ghostty.Key_Event,
	mouse_encoder:                                            ghostty.Mouse_Encoder,
	mouse_event:                                              ghostty.Mouse_Event,
	gesture:                                                  ghostty.Selection_Gesture,
	press_event, drag_event, release_event, autoscroll_event: ghostty.Selection_Gesture_Event,
	search:                                                   ghostty.Search,
	search_matches:                                           [dynamic]ghostty.Selection,
	// Written only by the transitions in search.odin and pattern_search.odin.
	search_state:                                             Search_State,
	pattern:                                                  Pattern_Search,
	process:                                                  Process,
	// When synchronized output began holding frames; nil while frames are live. capture judges
	// expiry, so a program that never releases the hold cannot freeze the pane.
	render_hold:                                              Maybe(time.Tick),
	geometry:                                                 Geometry,
	pty:                                                      pty.Pty,
	reader, writer, waiter:                                   ^thread.Thread,
	queue:                                                    Write_Queue,
	scanner:                                                  Mode_Scanner,
	win32_input:                                              bool,
	generation:                                               u64,
	title_changed, bell:                                      bool,
	status_changed:                                           bool,
	program_status_changed:                                   bool,
	program_statuses:                                         [PROGRAM_STATUS_LIMIT]Stored_Status,
	program_status_count:                                     int,
	program_status_enabled:                                   bool,
	read_buffer:                                              [READ_CHUNK]u8,
	// The mutex guards the capture: the reader thread appends, the main thread starts and stops.
	recording:                                                Recording,
}

@(private)
Write_Queue :: struct {
	mutex:   sync.Mutex,
	ready:   sync.Cond,
	pending: [dynamic]u8,
	state:   Write_Queue_State,
}

// Closed is the owner stopping the writer. Failed is a writer that lost the console's input: input
// is dropped until stop_process reopens the queue for the next process.
@(private)
Write_Queue_State :: enum u8 {
	Open,
	Closed,
	Failed,
}

@(private)
Queue_Push :: enum u8 {
	Queued,
	Unavailable,
	Full,
}

// Recording is one session's capture. `path` and `bytes` outlive it so a stop can still report what
// was written after a disk error ended the capture early.
@(private)
Recording :: struct {
	state: Recording_State,
	path:  string,
	bytes: u64,
}

// nil when not recording.
@(private)
Recording_State :: union {
	Recording_Active,
	Recording_Faulted,
}

@(private)
Recording_Active :: struct {
	file: ^os.File,
}

@(private)
Recording_Faulted :: struct {}

@(require_results)
create :: proc(config: Config, wake: Wake, allocator := context.allocator) -> (^Session, Error) {
	s := session_new(config.geometry, allocator)
	if s == nil {
		return nil, .Out_Of_Memory
	}
	s.wake, s.wall_clock = wake, config.wall_clock
	ok := false
	defer if !ok {
		destroy(s)
	}
	if err := ghostty_create(s, config.geometry, config.options); err != .None {
		return nil, err
	}
	// Applied here rather than in ghostty_create so a headless replay can keep libghostty's default
	// palette: a capture stores bytes, not the theme that drew them.
	set_colors(s, config.colors)
	if config.preface != "" {
		ghostty.terminal_vt_write(s.terminal, raw_data(config.preface), uint(len(config.preface)))
	}
	spawn(s, config)
	ok = true
	return s, .None
}

// The state both constructors share before libghostty exists. destroy is valid on the result, so
// each constructor cleans up a later failure the same way.
@(private)
session_new :: proc(geometry: Geometry, allocator: runtime.Allocator) -> ^Session {
	s, allocation_error := new(Session, allocator)
	if allocation_error != nil {
		return nil
	}
	s.allocator = allocator
	s.callback_context = context
	s.geometry = geometry
	s.queue.pending.allocator = allocator
	s.search_matches.allocator = allocator
	pattern_init(&s.pattern, s)
	return s
}

destroy :: proc(s: ^Session) {
	stop_process(s)
	record_close(&s.recording)
	delete(s.recording.path, s.allocator)
	ghostty.selection_gesture_event_free(s.press_event)
	ghostty.selection_gesture_event_free(s.drag_event)
	ghostty.selection_gesture_event_free(s.release_event)
	ghostty.selection_gesture_event_free(s.autoscroll_event)
	ghostty.search_free(s.search)
	if s.gesture != nil {
		ghostty.selection_gesture_free(s.gesture, s.terminal)
	}
	ghostty.mouse_event_free(s.mouse_event)
	ghostty.mouse_encoder_free(s.mouse_encoder)
	ghostty.key_event_free(s.key_event)
	ghostty.key_encoder_free(s.key_encoder)
	ghostty.terminal_free(s.terminal)
	clear_program_status(s, .All)
	delete(s.queue.pending)
	delete(s.search_matches)
	pattern_destroy(&s.pattern, s)
	free(s, s.allocator)
}

restart :: proc(s: ^Session, config: Config) {
	stop_process(s)
	sync.mutex_lock(&s.mutex)
	ghostty.terminal_reset(s.terminal)
	clear_program_status(s, .All)
	s.render_hold = nil
	_ = options_install(s, config.options)
	sync.mutex_unlock(&s.mutex)
	resize(s, config.geometry)
	spawn(s, config)
	mark_changed(s)
}

@(private, require_results)
ghostty_create :: proc(s: ^Session, g: Geometry, session_options: Options) -> Error {
	if ghostty.terminal_new(nil, &s.terminal, g.columns, g.rows) != .Success {
		return .Terminal_Failed
	}
	write_pty: ghostty.Terminal_Write_Pty_Fn = on_write_pty
	bell: ghostty.Terminal_Bell_Fn = on_bell
	title_changed: ghostty.Terminal_Title_Changed_Fn = on_title_changed
	render_hold: ghostty.Terminal_Render_Hold_Fn = on_render_hold
	semantic_prompt: ghostty.Terminal_Semantic_Prompt_Fn = on_semantic_prompt
	size: ghostty.Terminal_Size_Fn = on_size
	image_limit := IMAGE_STORAGE_LIMIT
	unlimited := max(uint)
	png_decoder_install()
	options := [?]struct {
		option: ghostty.Terminal_Option,
		value:  rawptr,
	} {
		{.Userdata, s},
		{.Write_Pty, rawptr(write_pty)},
		{.Bell, rawptr(bell)},
		{.Title_Changed, rawptr(title_changed)},
		{.Pwd_Changed, rawptr(title_changed)},
		{.Reset, rawptr(title_changed)},
		{.Render_Hold, rawptr(render_hold)},
		{.Semantic_Prompt, rawptr(semantic_prompt)},
		// Unlimited: the engine's default byte cap, about one page, would prune before the line limit.
		{.Scrollback_Max_Bytes, &unlimited},
		{.Size, rawptr(size)},
		{.Kitty_Image_Storage_Limit, &image_limit},
	}
	for item in options {
		if ghostty.terminal_set(s.terminal, item.option, item.value) != .Success {
			log.errorf("term: setting %v failed", item.option)
			return .Terminal_Failed
		}
	}
	if !options_install(s, session_options) {
		return .Terminal_Failed
	}
	if !apply_mode_defaults(s.terminal) {
		return .Terminal_Failed
	}
	if ghostty.terminal_resize(s.terminal, g.columns, g.rows, g.cell_width, g.cell_height) !=
	   .Success {
		return .Terminal_Failed
	}
	results := [?]ghostty.Result {
		ghostty.key_encoder_new(nil, &s.key_encoder),
		ghostty.key_event_new(nil, &s.key_event),
		ghostty.mouse_encoder_new(nil, &s.mouse_encoder),
		ghostty.mouse_event_new(nil, &s.mouse_event),
		ghostty.selection_gesture_new(nil, &s.gesture),
		ghostty.selection_gesture_event_new(nil, &s.press_event, .Press),
		ghostty.selection_gesture_event_new(nil, &s.drag_event, .Drag),
		ghostty.selection_gesture_event_new(nil, &s.release_event, .Release),
		ghostty.selection_gesture_event_new(nil, &s.autoscroll_event, .Autoscroll_Tick),
		ghostty.search_new(nil, &s.search, s.terminal),
	}
	for result in results {
		if result == .Out_Of_Memory {
			return .Out_Of_Memory
		}
		if result != .Success {
			return .Terminal_Failed
		}
	}
	return configure_press_event(s)
}

// Sets the modes every session starts with, and returns to after a reset.
// Grapheme clustering (mode 2027) is on so emoji sequences and combining marks occupy one
// cluster with libghostty's widths (D-042). Programs can still turn it off.
@(require_results)
apply_mode_defaults :: proc(terminal: ghostty.Terminal) -> bool {
	grapheme := ghostty.Terminal_Mode_Config {
		mode  = ghostty.MODE_GRAPHEME_CLUSTER,
		value = true,
	}
	if ghostty.terminal_set(terminal, .Mode_Default, &grapheme) != .Success {
		log.error("term: enabling grapheme clustering failed")
		return false
	}
	return true
}

@(private)
spawn :: proc(s: ^Session, config: Config) {
	environment: [3 + MAX_HOST_ENVIRONMENT]pty.Env_Var = {
		0 = {"TERM", "xterm-256color"},
		1 = {"COLORTERM", "truecolor"},
		2 = {"TERM_PROGRAM", "AIODev"},
	}
	assert(len(config.environment) <= MAX_HOST_ENVIRONMENT)
	count := 3 + copy(environment[3:], config.environment)
	options := pty.Spawn_Options {
		command_line        = config.command_line,
		working_directory   = config.working_directory,
		title               = config.title,
		environment         = environment[:count],
		path_append         = config.path_append,
		cols                = config.geometry.columns,
		rows                = config.geometry.rows,
		refresh_environment = config.refresh_environment,
		inherit_cursor      = config.preface != "",
	}
	process, err := pty.spawn(options, s.allocator)
	if err.kind != .None {
		message, message_error := pty.error_message(err, options, s.allocator)
		if message_error != .None {
			log.errorf("term: describing spawn failure %v failed: %v", err, message_error)
		}
		process_apply(s, Process_Failed{message})
		return
	}
	s.pty = process
	process_apply(s, Process_Running{})
	s.reader = thread.create_and_start_with_poly_data(s, reader_main, s.callback_context)
	s.waiter = thread.create_and_start_with_poly_data(s, waiter_main, s.callback_context)
	s.writer = thread.create_and_start_with_poly_data(s, writer_main, s.callback_context)
	if s.reader == nil || s.waiter == nil || s.writer == nil {
		log.error("term: creating session threads failed")
		stop_process(s)
		process_apply(s, Process_Failed{})
	}
}

// Takes the process down and releases its threads and console; a session with no process only
// forgets a failure.
@(private)
stop_process :: proc(s: ^Session) {
	stopping, live := process_stop(s)
	if !live {
		return
	}
	if err := pty.terminate(&s.pty); err != .None {
		log.errorf("term: terminating the process tree failed: %v", err)
	}
	join_thread(&s.waiter)
	// The waiter normally closes the console; closing again is harmless and covers a missing waiter.
	pty.close_console(&s.pty)
	if !stopping.drain {
		if err := pty.cancel_reads(s.reader); err != .None {
			log.errorf("term: cancelling process output failed: %v", err)
		}
	}
	join_thread(&s.reader)
	queue_close(&s.queue)
	join_thread(&s.writer)
	pty.destroy(&s.pty)
	queue_reset(&s.queue)
	s.scanner = {}
	sync.atomic_store(&s.win32_input, false)
	process_apply(s, nil)
}

// The only writer of Session.process; the caller holds the session mutex. Leaving Failed frees its
// message, and entering a phase the app shows flags a status change.
@(private)
process_enter :: proc(s: ^Session, next: Process) {
	if failed, ok := s.process.(Process_Failed); ok {
		delete(failed.message, s.allocator)
	}
	s.process = next
	switch _ in next {
	case Process_Running, Process_Exited, Process_Failed:
		sync.atomic_store(&s.status_changed, true)
	case Process_Stopping:
	}
}

@(private)
process_apply :: proc(s: ^Session, next: Process) {
	sync.mutex_lock(&s.mutex)
	process_enter(s, next)
	sync.mutex_unlock(&s.mutex)
}

// The waiter saw the process end. A stop already under way keeps the decision it took.
@(private)
process_exited :: proc(s: ^Session, code: u32) {
	sync.mutex_lock(&s.mutex)
	if _, running := s.process.(Process_Running); running {
		process_enter(s, Process_Exited{code})
	}
	sync.mutex_unlock(&s.mutex)
}

// Begins stop_process, deciding from the phase whether the reader drains or is cancelled. The
// decision and the phase change are one step, so an exit the waiter reports afterwards cannot make
// the stop wait for output it already chose to abandon. `live` is false when there is no process.
@(private)
process_stop :: proc(s: ^Session) -> (stopping: Process_Stopping, live: bool) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	switch _ in s.process {
	case Process_Running:
		stopping, live = {drain = false}, true
	case Process_Exited:
		stopping, live = {drain = true}, true
	case Process_Failed:
		process_enter(s, nil)
		return
	case Process_Stopping, nil:
		return
	}
	process_enter(s, stopping)
	return
}

@(private)
join_thread :: proc(t: ^^thread.Thread) {
	if t^ != nil {
		thread.join(t^)
		thread.destroy(t^)
		t^ = nil
	}
}

@(private)
notify :: proc(s: ^Session) {
	if s.wake.procedure != nil {
		s.wake.procedure(s.wake.user)
	}
}

@(private)
mark_changed :: proc(s: ^Session) {
	sync.atomic_add(&s.generation, 1)
}

@(private)
reader_main :: proc(s: ^Session) {
	defer {
		sync.mutex_lock(&s.mutex)
		clear_program_status(s, .Transient)
		sync.mutex_unlock(&s.mutex)
		notify(s)
	}
	for {
		n, err := pty.read(&s.pty, s.read_buffer[:])
		if err != .None {
			if err != .Closed {
				log.errorf("term: reading process output failed: %v", err)
			}
			return
		}
		chunk := s.read_buffer[:n]
		if enabled, changed := scan_win32_input_mode(&s.scanner, chunk); changed {
			sync.atomic_store(&s.win32_input, enabled)
		}
		sync.mutex_lock(&s.mutex)
		ghostty.terminal_vt_write(s.terminal, raw_data(chunk), uint(n))
		record_chunk(s, chunk)
		sync.mutex_unlock(&s.mutex)
		mark_changed(s)
		notify(s)
	}
}

@(private)
waiter_main :: proc(s: ^Session) {
	code, err := pty.wait_exit(&s.pty)
	if err != .None {
		log.errorf("term: waiting for process exit failed: %v", err)
	}
	process_exited(s, code)
	// Closing the console after exit lets the reader drain the remaining output and reach EOF.
	pty.close_console(&s.pty)
	mark_changed(s)
	notify(s)
}

@(private)
writer_main :: proc(s: ^Session) {
	sending := make([dynamic]u8, s.allocator)
	defer delete(sending)
	for queue_take(&s.queue, &sending) {
		if err := pty.write(&s.pty, sending[:]); err != .None {
			queue_fail(&s.queue, err)
			return
		}
		clear(&sending)
	}
}

// Every caller states what a refused write means. Typed text and pastes report it (send_input),
// since the user is owed a result; focus, mouse and wheel reports are best effort and drop it, as
// a writer failure is logged once and a closed queue belongs to a session being stopped; terminal
// replies warn only when the queue is full.
@(private, require_results)
queue_push :: proc(q: ^Write_Queue, data: []u8) -> Queue_Push {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	if q.state != .Open {
		return .Unavailable
	}
	if len(q.pending) + len(data) > WRITE_QUEUE_LIMIT {
		return .Full
	}
	if _, err := append(&q.pending, ..data); err != nil {
		return .Full
	}
	sync.cond_signal(&q.ready)
	return .Queued
}

@(private)
queue_take :: proc(q: ^Write_Queue, out: ^[dynamic]u8) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	for len(q.pending) == 0 && q.state == .Open {
		sync.cond_wait(&q.ready, &q.mutex)
	}
	if q.state != .Open {
		return false
	}
	q.pending, out^ = out^, q.pending
	return true
}

@(private)
queue_close :: proc(q: ^Write_Queue) {
	sync.mutex_lock(&q.mutex)
	q.state = .Closed
	sync.cond_broadcast(&q.ready)
	sync.mutex_unlock(&q.mutex)
}

// The writer lost the console's input. This is the one log line: later input is dropped quietly
// until stop_process reopens the queue.
@(private)
queue_fail :: proc(q: ^Write_Queue, err: pty.Error) {
	sync.mutex_lock(&q.mutex)
	failed := q.state == .Open
	if failed {
		q.state = .Failed
	}
	sync.cond_broadcast(&q.ready)
	sync.mutex_unlock(&q.mutex)
	if !failed {
		return
	}
	if err == .Closed {
		log.info("term: the console closed its input; later input is dropped")
	} else {
		log.errorf("term: writing process input failed: %v; later input is dropped", err)
	}
}

@(private)
queue_reset :: proc(q: ^Write_Queue) {
	sync.mutex_lock(&q.mutex)
	clear(&q.pending)
	q.state = .Open
	sync.mutex_unlock(&q.mutex)
}

// A closed or failed queue drops replies quietly: stopping expects it, and a failure logged once.
@(private)
on_write_pty :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr, data: [^]u8, len: uint) {
	s := (^Session)(userdata)
	context = s.callback_context
	if queue_push(&s.queue, data[:len]) == .Full {
		log.warn("term: dropped a terminal reply because the input queue has no room")
	}
}

@(private)
on_bell :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr) {
	sync.atomic_store(&(^Session)(userdata).bell, true)
}

@(private)
on_title_changed :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr) {
	sync.atomic_store(&(^Session)(userdata).title_changed, true)
}

@(private)
on_render_hold :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr, held: bool) {
	s := (^Session)(userdata)
	if held {
		s.render_hold = time.tick_now()
	} else {
		s.render_hold = nil
	}
}

// What capture did to the caller's render state. Only Updated read the terminal: its generation is
// the one current under the lock the read held, so a cache keyed by it never claims later output.
// Held leaves the previous screen in place while synchronized output holds frames; the hold ends
// by itself at `until`, so the caller draws again then even if the program stays silent. Failed
// also leaves the previous screen and has already been logged.
Capture_Result :: union {
	Capture_Updated,
	Capture_Held,
	Capture_Failed,
}

Capture_Updated :: struct {
	generation: u64,
}

Capture_Held :: struct {
	until: time.Tick,
}

Capture_Failed :: struct {}

// Updates `state` from the terminal and, given `highlights`, replaces it with the visible search
// matches. Given `images`, it also reads the visible image placements.
capture :: proc(
	s: ^Session,
	state: ghostty.Render_State,
	highlights: ^[dynamic]Highlight = nil,
	images: ^Image_Capture = nil,
) -> Capture_Result {
	sync.mutex_lock(&s.mutex)
	if since, held := s.render_hold.?; held && time.tick_since(since) < RENDER_HOLD_LIMIT {
		sync.mutex_unlock(&s.mutex)
		return Capture_Held{time.tick_add(since, RENDER_HOLD_LIMIT)}
	}
	generation := sync.atomic_load(&s.generation)
	result := ghostty.render_state_begin_update(state, s.terminal)
	if result == .Success && highlights != nil {
		collect_highlights(s, highlights)
	}
	if result == .Success && images != nil {
		collect_images(s, images)
	}
	sync.mutex_unlock(&s.mutex)
	if result == .Success {
		result = ghostty.render_state_end_update(state)
	}
	if result != .Success {
		log.errorf("term: render state update failed: %v", result)
		return Capture_Failed{}
	}
	return Capture_Updated{generation}
}

// Moves the pane's grid on the surface when its size is unchanged, as dragging a floating pane does, so
// the program sees no resize. False leaves a changed grid to resize.
@(require_results)
reposition :: proc(s: ^Session, geometry: Geometry) -> bool {
	sync.mutex_lock(&s.mutex)
	g := s.geometry
	same :=
		g.columns == geometry.columns && g.rows == geometry.rows &&
		g.cell_width == geometry.cell_width && g.cell_height == geometry.cell_height
	if same {s.geometry = geometry}
	sync.mutex_unlock(&s.mutex)
	if same {mark_changed(s)}
	return same
}

resize :: proc(s: ^Session, geometry: Geometry) {
	sync.mutex_lock(&s.mutex)
	s.geometry = geometry
	result := ghostty.terminal_resize(
		s.terminal,
		geometry.columns,
		geometry.rows,
		geometry.cell_width,
		geometry.cell_height,
	)
	_, failed := s.process.(Process_Failed)
	live := s.process != nil && !failed
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: resize to %vx%v failed: %v", geometry.columns, geometry.rows, result)
	}
	if live {
		if err := pty.resize(&s.pty, geometry.columns, geometry.rows);
		   err != .None && err != .Closed {
			log.errorf("term: console resize failed: %v", err)
		}
	}
	mark_changed(s)
}

set_colors :: proc(s: ^Session, colors: Colors) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	foreground := ghostty_from_color(colors.foreground)
	background := ghostty_from_color(colors.background)
	cursor := ghostty_from_color(colors.cursor)
	palette: [256]ghostty.Color_Rgb
	ok := ghostty.terminal_set(s.terminal, .Color_Foreground, &foreground) == .Success
	ok &&= ghostty.terminal_set(s.terminal, .Color_Background, &background) == .Success
	ok &&= ghostty.terminal_set(s.terminal, .Color_Cursor, &cursor) == .Success
	ok &&= ghostty.terminal_set(s.terminal, .Color_Palette, nil) == .Success
	ok &&= ghostty.terminal_get(s.terminal, .Color_Palette_Default, &palette) == .Success
	for color, i in colors.palette {
		palette[i] = ghostty_from_color(color)
	}
	ok &&= ghostty.terminal_set(s.terminal, .Color_Palette, &palette) == .Success
	if !ok {
		log.error("term: applying colors failed")
	}
	mark_changed(s)
}

// What the app shows of the process. A session without one, such as a headless replay, reads as
// Running because it has no exit to report; Stopping exists only inside stop_process.
status :: proc(s: ^Session) -> Status {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	#partial switch p in s.process {
	case Process_Exited:
		return {kind = .Exited, exit_code = p.code}
	case Process_Failed:
		return {kind = .Failed, message = p.message}
	}
	return {kind = .Running}
}

take_status_change :: proc(s: ^Session) -> bool {
	return sync.atomic_exchange(&s.status_changed, false)
}

title :: proc(s: ^Session, allocator := context.allocator) -> string {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	value: ghostty.String
	if ghostty.terminal_get(s.terminal, .Title, &value) != .Success || value.len == 0 {
		return ""
	}
	return strings.clone(string(value.ptr[:value.len]), allocator)
}

// The shell's last reported directory (OSC 7 or ConEmu's OSC 9;9). ConEmu documents 9;9 with the path
// in double quotes, and shell integrations send it that way, so one surrounding pair is dropped.
working_directory :: proc(s: ^Session, allocator := context.allocator) -> string {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	value: ghostty.String
	if ghostty.terminal_get(s.terminal, .Pwd, &value) != .Success || value.len == 0 {return ""}
	text := string(value.ptr[:value.len])
	if len(text) >= 2 && text[0] == '"' && text[len(text) - 1] == '"' {text = text[1:len(text) - 1]}
	return strings.clone(text, allocator)
}

take_title_change :: proc(s: ^Session) -> bool {
	return sync.atomic_exchange(&s.title_changed, false)
}

take_bell :: proc(s: ^Session) -> bool {
	return sync.atomic_exchange(&s.bell, false)
}

generation :: proc(s: ^Session) -> u64 {
	return sync.atomic_load(&s.generation)
}

scroll_viewport :: proc(s: ^Session, rows: int) {
	sync.mutex_lock(&s.mutex)
	result := ghostty.terminal_scroll_viewport(s.terminal, {tag = .Delta, value = {delta = rows}})
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: scrolling the viewport failed: %v", result)
	}
	mark_changed(s)
}

scroll_to_bottom :: proc(s: ^Session) {
	sync.mutex_lock(&s.mutex)
	result := ghostty.terminal_scroll_viewport(s.terminal, {tag = .Bottom})
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: scrolling to the bottom failed: %v", result)
	}
	mark_changed(s)
}

Scrollbar :: struct {
	total, offset, len: u64,
}

@(require_results)
scrollbar :: proc(s: ^Session) -> (Scrollbar, bool) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	value: ghostty.Terminal_Scrollbar
	result := ghostty.terminal_get(s.terminal, .Scrollbar, &value)
	if result != .Success {
		log.errorf("term: reading scrollbar failed: %v", result)
		return {}, false
	}
	return {value.total, value.offset, value.len}, true
}

clear_scrollback :: proc(s: ^Session) {
	ERASE_SCROLLBACK :: "\x1b[3J"
	sync.mutex_lock(&s.mutex)
	ghostty.terminal_vt_write(
		s.terminal,
		raw_data(string(ERASE_SCROLLBACK)),
		len(ERASE_SCROLLBACK),
	)
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
}

@(private)
mode_enabled :: proc(s: ^Session, mode: ghostty.Mode) -> bool {
	config := ghostty.Terminal_Mode_Config {
		mode = mode,
	}
	return ghostty.terminal_get(s.terminal, .Mode, &config) == .Success && config.value
}

Cursor_Style :: enum u8 {
	Block,
	Bar,
	Underline,
}

// Applies settings that a running session can change to a live session.
configure :: proc(s: ^Session, options: Options) {
	sync.mutex_lock(&s.mutex)
	_ = options_install(s, options)
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
}

// The one writer of the options: retained scrollback, the default cursor and program-status
// reports. Disabling reports stops listening: reports are dropped, the support query goes
// unanswered so programs see the protocol as unsupported, and every stored record is removed. The
// caller holds the session mutex; each failure is logged and the rest still applied.
@(private, require_results)
options_install :: proc(s: ^Session, options: Options) -> bool {
	style: ghostty.Cursor_Style
	switch options.cursor {
	case .Block:
		style = .Block
	case .Bar:
		style = .Bar
	case .Underline:
		style = .Underline
	}
	lines := uint(options.scrollback_lines)
	blinking := options.cursor_blink
	reporter: ghostty.Terminal_Program_Status_Fn = on_program_status
	settings := [?]struct {
		option: ghostty.Terminal_Option,
		value:  rawptr,
	} {
		{.Scrollback_Max_Lines, &lines},
		{.Default_Cursor_Style, &style},
		{.Default_Cursor_Blink, &blinking},
	}
	ok := true
	for item in settings {
		if ghostty.terminal_set(s.terminal, item.option, item.value) != .Success {
			log.errorf("term: setting %v failed", item.option)
			ok = false
		}
	}
	enabled := options.program_status_enabled
	if s.program_status_enabled == enabled {return ok}
	value := enabled ? rawptr(reporter) : nil
	if ghostty.terminal_set(s.terminal, .Program_Status, value) != .Success {
		log.error("term: switching program status reports failed")
		return false
	}
	s.program_status_enabled = enabled
	if !enabled {clear_program_status(s, .All)}
	return ok
}

geometry :: proc(s: ^Session) -> Geometry {
	return s.geometry
}

// record_start begins capturing this session's raw PTY output at `path`. The header is written
// immediately so a replay knows the geometry even when the process produces no output at all.
@(require_results)
record_start :: proc(s: ^Session, path: string) -> Record_Start_Error {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	if s.recording.state != nil {
		return .Already_Recording
	}
	owned, clone_error := strings.clone(path, s.allocator)
	if clone_error != nil {
		return .Out_Of_Memory
	}
	file, open_error := os.create(owned)
	if open_error != nil {
		log.errorf("term: creating the capture %s failed: %v", owned, open_error)
		delete(owned, s.allocator)
		return .File_Failed
	}
	header := capture_header(s.geometry.columns, s.geometry.rows)
	if _, ok := record_write(file, header[:]); !ok {
		log.errorf("term: writing the capture header to %s failed", owned)
		record_close_file(file)
		delete(owned, s.allocator)
		return .File_Failed
	}
	delete(s.recording.path, s.allocator)
	s.recording = {state = Recording_Active{file}, path = owned}
	return .None
}

// record_stop ends the capture and reports how it ended and what it wrote. The path borrows session
// memory that stays valid until the session is destroyed or another capture starts.
@(require_results)
record_stop :: proc(s: ^Session) -> (path: string, bytes: u64, result: Record_Stop) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	switch _ in s.recording.state {
	case Recording_Active:
		result = .Stopped
	case Recording_Faulted:
		result = .Faulted
	case:
		return "", 0, .Not_Recording
	}
	record_close(&s.recording)
	return s.recording.path, s.recording.bytes, result
}

// record_chunk appends one PTY chunk while the session records. A failed write faults the capture
// instead of retrying every chunk: the app must keep running, and one log line is enough evidence.
@(private)
record_chunk :: proc(s: ^Session, data: []u8) {
	active, recording := s.recording.state.(Recording_Active)
	if !recording {
		return
	}
	n, written := record_write(active.file, data)
	s.recording.bytes += u64(n)
	if written {
		return
	}
	log.errorf("term: appending to the capture %s failed; recording stopped", s.recording.path)
	record_close_file(active.file)
	s.recording.state = Recording_Faulted{}
}

// record_close ends any capture but keeps the path and byte count for the stop report.
@(private)
record_close :: proc(r: ^Recording) {
	if active, ok := r.state.(Recording_Active); ok {
		record_close_file(active.file)
	}
	r.state = nil
}

// record_write writes every byte of `data`; a short write or a closed file cannot be resumed.
@(private, require_results)
record_write :: proc(file: ^os.File, data: []u8) -> (written: int, ok: bool) {
	for written < len(data) {
		n, err := os.write(file, data[written:])
		if err != nil || n <= 0 {
			return written, false
		}
		written += n
	}
	return written, true
}

@(private)
record_close_file :: proc(file: ^os.File) {
	if file == nil {
		return
	}
	if err := os.close(file); err != nil {
		log.errorf("term: closing a capture failed: %v", err)
	}
}

// Test-only window onto the libghostty handle. `odin test` defines ODIN_TEST, so debug, release,
// check and verify builds do not contain this proc at all. It holds the session mutex so a test can
// inspect or configure the terminal while its reader thread is still feeding it.
when ODIN_TEST {
	@(require_results)
	with_terminal :: proc(
		s: ^Session,
		inspect: proc(terminal: ghostty.Terminal, user: rawptr) -> bool,
		user: rawptr,
	) -> bool {
		sync.mutex_lock(&s.mutex)
		defer sync.mutex_unlock(&s.mutex)
		return inspect(s.terminal, user)
	}
}

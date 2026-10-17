package term

import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "aio:ghostty"
import "aio:pty"

Color :: [3]u8

Colors :: struct {
	foreground, background, cursor: Color,
	palette: [16]Color,
}

Geometry :: struct {
	columns, rows: u16,
	cell_width, cell_height: u32,
	surface_width, surface_height: u32,
	padding_left, padding_top: u32,
}

Config :: struct {
	command_line, working_directory: string,
	geometry: Geometry,
	scrollback_lines: int,
	colors: Colors,
}

Wake :: struct {
	procedure: proc(user: rawptr),
	user: rawptr,
}

Status_Kind :: enum {
	Running,
	Exited,
	Failed,
}

Status :: struct {
	kind: Status_Kind,
	exit_code: u32,
	message: string,
}

Error :: enum {
	None,
	Out_Of_Memory,
	Terminal_Failed,
}

@(private) WRITE_QUEUE_LIMIT :: 4 * 1024 * 1024
@(private) RENDER_HOLD_LIMIT :: time.Second
@(private) READ_CHUNK :: 64 * 1024

Session :: struct {
	allocator: runtime.Allocator,
	callback_context: runtime.Context,
	wake: Wake,
	// Guards the libghostty objects below and the status fields.
	mutex: sync.Mutex,
	terminal: ghostty.Terminal,
	key_encoder: ghostty.Key_Encoder,
	key_event: ghostty.Key_Event,
	mouse_encoder: ghostty.Mouse_Encoder,
	mouse_event: ghostty.Mouse_Event,
	gesture: ghostty.Selection_Gesture,
	press_event, drag_event, release_event: ghostty.Selection_Gesture_Event,
	status: Status_Kind,
	exit_code: u32,
	failure: string,
	held: bool,
	held_since: time.Tick,
	geometry: Geometry,
	spawned: bool,
	pty: pty.Pty,
	reader, writer, waiter: ^thread.Thread,
	queue: Write_Queue,
	scanner: Mode_Scanner,
	win32_input: bool,
	generation: u64,
	title_changed, bell: bool,
	program_status_changed: bool,
	program_statuses: [PROGRAM_STATUS_LIMIT]Stored_Status,
	program_status_count: int,
	read_buffer: [READ_CHUNK]u8,
}

@(private)
Write_Queue :: struct {
	mutex: sync.Mutex,
	ready: sync.Cond,
	pending: [dynamic]u8,
	closed: bool,
}

@(require_results)
create :: proc(config: Config, wake: Wake, allocator := context.allocator) -> (^Session, Error) {
	s, allocation_error := new(Session, allocator)
	if allocation_error != nil {
		return nil, .Out_Of_Memory
	}
	s.allocator = allocator
	s.callback_context = context
	s.wake = wake
	s.geometry = config.geometry
	s.queue.pending.allocator = allocator
	ok := false
	defer if !ok {
		destroy(s)
	}
	if err := ghostty_create(s, config); err != .None {
		return nil, err
	}
	spawn(s, config)
	ok = true
	return s, .None
}

destroy :: proc(s: ^Session) {
	if s.spawned {
		stop_process(s)
	}
	ghostty.selection_gesture_event_free(s.press_event)
	ghostty.selection_gesture_event_free(s.drag_event)
	ghostty.selection_gesture_event_free(s.release_event)
	if s.gesture != nil {
		ghostty.selection_gesture_free(s.gesture, s.terminal)
	}
	ghostty.mouse_event_free(s.mouse_event)
	ghostty.mouse_encoder_free(s.mouse_encoder)
	ghostty.key_event_free(s.key_event)
	ghostty.key_encoder_free(s.key_encoder)
	ghostty.terminal_free(s.terminal)
	clear_program_status(s, false)
	delete(s.failure, s.allocator)
	delete(s.queue.pending)
	free(s, s.allocator)
}

restart :: proc(s: ^Session, config: Config) {
	if s.spawned {
		stop_process(s)
	}
	sync.mutex_lock(&s.mutex)
	ghostty.terminal_reset(s.terminal)
	clear_program_status(s, false)
	delete(s.failure, s.allocator)
	s.failure = ""
	s.held = false
	sync.mutex_unlock(&s.mutex)
	resize(s, config.geometry)
	spawn(s, config)
	mark_changed(s)
}

@(private, require_results)
ghostty_create :: proc(s: ^Session, config: Config) -> Error {
	g := config.geometry
	if ghostty.terminal_new(nil, &s.terminal, g.columns, g.rows) != .Success {
		return .Terminal_Failed
	}
	write_pty: ghostty.Terminal_Write_Pty_Fn = on_write_pty
	bell: ghostty.Terminal_Bell_Fn = on_bell
	title_changed: ghostty.Terminal_Title_Changed_Fn = on_title_changed
	render_hold: ghostty.Terminal_Render_Hold_Fn = on_render_hold
	program_status: ghostty.Terminal_Program_Status_Fn = on_program_status
	semantic_prompt: ghostty.Terminal_Semantic_Prompt_Fn = on_semantic_prompt
	scrollback := uint(config.scrollback_lines)
	options := [?]struct {
		option: ghostty.Terminal_Option,
		value: rawptr,
	}{
		{.Userdata, s},
		{.Write_Pty, rawptr(write_pty)},
		{.Bell, rawptr(bell)},
		{.Title_Changed, rawptr(title_changed)},
		{.Render_Hold, rawptr(render_hold)},
		{.Program_Status, rawptr(program_status)},
		{.Semantic_Prompt, rawptr(semantic_prompt)},
		{.Scrollback_Max_Lines, &scrollback},
	}
	for item in options {
		if ghostty.terminal_set(s.terminal, item.option, item.value) != .Success {
			log.errorf("term: setting %v failed", item.option)
			return .Terminal_Failed
		}
	}
	if ghostty.terminal_resize(s.terminal, g.columns, g.rows, g.cell_width, g.cell_height) != .Success {
		return .Terminal_Failed
	}
	set_colors(s, config.colors)
	results := [?]ghostty.Result{
		ghostty.key_encoder_new(nil, &s.key_encoder),
		ghostty.key_event_new(nil, &s.key_event),
		ghostty.mouse_encoder_new(nil, &s.mouse_encoder),
		ghostty.mouse_event_new(nil, &s.mouse_event),
		ghostty.selection_gesture_new(nil, &s.gesture),
		ghostty.selection_gesture_event_new(nil, &s.press_event, .Press),
		ghostty.selection_gesture_event_new(nil, &s.drag_event, .Drag),
		ghostty.selection_gesture_event_new(nil, &s.release_event, .Release),
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

@(private)
spawn :: proc(s: ^Session, config: Config) {
	environment := [?]pty.Env_Var{
		{"TERM", "xterm-256color"},
		{"COLORTERM", "truecolor"},
		{"TERM_PROGRAM", "AIODev"},
	}
	options := pty.Spawn_Options{
		command_line = config.command_line,
		working_directory = config.working_directory,
		environment = environment[:],
		cols = config.geometry.columns,
		rows = config.geometry.rows,
	}
	process, err := pty.spawn(options, s.allocator)
	if err.kind != .None {
		message, message_error := pty.error_message(err, options, s.allocator)
		if message_error != .None {
			log.errorf("term: describing spawn failure %v failed: %v", err, message_error)
		}
		sync.mutex_lock(&s.mutex)
		s.status, s.failure = .Failed, message
		sync.mutex_unlock(&s.mutex)
		return
	}
	s.pty, s.spawned = process, true
	sync.mutex_lock(&s.mutex)
	s.status, s.exit_code = .Running, 0
	sync.mutex_unlock(&s.mutex)
	s.reader = thread.create_and_start_with_poly_data(s, reader_main, s.callback_context)
	s.waiter = thread.create_and_start_with_poly_data(s, waiter_main, s.callback_context)
	s.writer = thread.create_and_start_with_poly_data(s, writer_main, s.callback_context)
	if s.reader == nil || s.waiter == nil || s.writer == nil {
		log.error("term: creating session threads failed")
		stop_process(s)
		sync.mutex_lock(&s.mutex)
		s.status = .Failed
		sync.mutex_unlock(&s.mutex)
	}
}

@(private)
stop_process :: proc(s: ^Session) {
	if err := pty.terminate(&s.pty); err != .None {
		log.errorf("term: terminating the process tree failed: %v", err)
	}
	join_thread(&s.waiter)
	// The waiter normally closes the console; closing again is harmless and covers a missing waiter.
	pty.close_console(&s.pty)
	join_thread(&s.reader)
	queue_close(&s.queue)
	join_thread(&s.writer)
	pty.destroy(&s.pty)
	queue_reset(&s.queue)
	s.scanner = {}
	sync.atomic_store(&s.win32_input, false)
	s.spawned = false
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
		clear_program_status(s, true)
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
	sync.mutex_lock(&s.mutex)
	s.status, s.exit_code = .Exited, code
	sync.mutex_unlock(&s.mutex)
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
			if err != .Closed {
				log.errorf("term: writing process input failed: %v", err)
			}
			queue_close(&s.queue)
			return
		}
		clear(&sending)
	}
}

@(private)
queue_push :: proc(q: ^Write_Queue, data: []u8) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	if q.closed || len(q.pending) + len(data) > WRITE_QUEUE_LIMIT {
		return false
	}
	if _, err := append(&q.pending, ..data); err != nil {
		return false
	}
	sync.cond_signal(&q.ready)
	return true
}

@(private)
queue_take :: proc(q: ^Write_Queue, out: ^[dynamic]u8) -> bool {
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	for len(q.pending) == 0 && !q.closed {
		sync.cond_wait(&q.ready, &q.mutex)
	}
	if q.closed {
		return false
	}
	q.pending, out^ = out^, q.pending
	return true
}

@(private)
queue_close :: proc(q: ^Write_Queue) {
	sync.mutex_lock(&q.mutex)
	q.closed = true
	sync.cond_broadcast(&q.ready)
	sync.mutex_unlock(&q.mutex)
}

@(private)
queue_reset :: proc(q: ^Write_Queue) {
	sync.mutex_lock(&q.mutex)
	clear(&q.pending)
	q.closed = false
	sync.mutex_unlock(&q.mutex)
}

@(private)
on_write_pty :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr, data: [^]u8, len: uint) {
	s := (^Session)(userdata)
	context = s.callback_context
	if !queue_push(&s.queue, data[:len]) {
		log.warn("term: dropped a terminal reply because the input queue is unavailable")
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
	s.held = held
	if held {
		s.held_since = time.tick_now()
	}
}

capture :: proc(s: ^Session, state: ghostty.Render_State) -> bool {
	sync.mutex_lock(&s.mutex)
	if s.held && time.tick_since(s.held_since) < RENDER_HOLD_LIMIT {
		sync.mutex_unlock(&s.mutex)
		return false
	}
	result := ghostty.render_state_begin_update(state, s.terminal)
	sync.mutex_unlock(&s.mutex)
	if result == .Success {
		result = ghostty.render_state_end_update(state)
	}
	if result != .Success {
		log.errorf("term: render state update failed: %v", result)
		return false
	}
	return true
}

resize :: proc(s: ^Session, geometry: Geometry) {
	s.geometry = geometry
	sync.mutex_lock(&s.mutex)
	result := ghostty.terminal_resize(
		s.terminal, geometry.columns, geometry.rows, geometry.cell_width, geometry.cell_height,
	)
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: resize to %vx%v failed: %v", geometry.columns, geometry.rows, result)
	}
	if s.spawned {
		if err := pty.resize(&s.pty, geometry.columns, geometry.rows); err != .None && err != .Closed {
			log.errorf("term: console resize failed: %v", err)
		}
	}
	mark_changed(s)
}

set_colors :: proc(s: ^Session, colors: Colors) {
	rgb :: proc(c: Color) -> ghostty.Color_Rgb {
		return {c.r, c.g, c.b}
	}
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	foreground, background, cursor := rgb(colors.foreground), rgb(colors.background), rgb(colors.cursor)
	palette: [256]ghostty.Color_Rgb
	ok := ghostty.terminal_set(s.terminal, .Color_Foreground, &foreground) == .Success
	ok &&= ghostty.terminal_set(s.terminal, .Color_Background, &background) == .Success
	ok &&= ghostty.terminal_set(s.terminal, .Color_Cursor, &cursor) == .Success
	ok &&= ghostty.terminal_set(s.terminal, .Color_Palette, nil) == .Success
	ok &&= ghostty.terminal_get(s.terminal, .Color_Palette_Default, &palette) == .Success
	for color, i in colors.palette {
		palette[i] = rgb(color)
	}
	ok &&= ghostty.terminal_set(s.terminal, .Color_Palette, &palette) == .Success
	if !ok {
		log.error("term: applying colors failed")
	}
	mark_changed(s)
}

status :: proc(s: ^Session) -> Status {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	return {s.status, s.exit_code, s.failure}
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
	ghostty.terminal_scroll_viewport(s.terminal, {tag = .Delta, value = {delta = rows}})
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
}

scroll_to_bottom :: proc(s: ^Session) {
	sync.mutex_lock(&s.mutex)
	ghostty.terminal_scroll_viewport(s.terminal, {tag = .Bottom})
	sync.mutex_unlock(&s.mutex)
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
	ghostty.terminal_vt_write(s.terminal, raw_data(string(ERASE_SCROLLBACK)), len(ERASE_SCROLLBACK))
	sync.mutex_unlock(&s.mutex)
	mark_changed(s)
}

@(private)
mode_enabled :: proc(s: ^Session, mode: ghostty.Mode) -> bool {
	config := ghostty.Terminal_Mode_Config{mode = mode}
	return ghostty.terminal_get(s.terminal, .Mode, &config) == .Success && config.value
}

Cursor_Style :: enum u8 {
	Block,
	Bar,
	Underline,
}

// Applies settings that a running session can change: retained scrollback and the default cursor.
configure :: proc(s: ^Session, scrollback_lines: int, cursor: Cursor_Style, blink: bool) {
	style: ghostty.Terminal_Cursor_Style
	switch cursor {
	case .Block: style = .Block
	case .Bar: style = .Bar
	case .Underline: style = .Underline
	}
	lines := uint(scrollback_lines)
	blinking := blink
	sync.mutex_lock(&s.mutex)
	ok := ghostty.terminal_set(s.terminal, .Scrollback_Max_Lines, &lines) == .Success
	ok &&= ghostty.terminal_set(s.terminal, .Default_Cursor_Style, &style) == .Success
	ok &&= ghostty.terminal_set(s.terminal, .Default_Cursor_Blink, &blinking) == .Success
	sync.mutex_unlock(&s.mutex)
	if !ok {
		log.error("term: applying session configuration failed")
	}
	mark_changed(s)
}

geometry :: proc(s: ^Session) -> Geometry {
	return s.geometry
}

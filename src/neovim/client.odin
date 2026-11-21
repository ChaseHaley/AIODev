// A Neovim UI client: spawns `nvim --embed`, speaks msgpack-RPC over its stdin and stdout, and keeps
// a double-buffered picture of grid 1 built from `redraw` events. The caller serializes all calls.
package neovim

import "aio:spawn"
import "base:runtime"
import "core:log"

Error :: enum u8 {
	None,
	Not_Found,
	Start_Failed,
	Closed,
	Out_Of_Memory,
	Protocol,
}

Color :: u32

Attribute :: enum u8 {
	Bold,
	Italic,
	Reverse,
	Strikethrough,
	Underline,
	Undercurl,
	Underdouble,
	Underdotted,
	Underdashed,
}

Highlight :: struct {
	foreground, background, special: Maybe(Color),
	attributes: bit_set[Attribute; u16],
	blend: u8,
}

// glyph: a single Unicode codepoint when below GLYPH_CLUSTER; GLYPH_CLUSTER | i names cluster i
// (several codepoints, read with `cluster`); 0 is the right half of a double-width character
// (Neovim sends "" there).
GLYPH_CLUSTER :: u32(1) << 31

Cell :: struct {
	glyph: u32,
	highlight: u32,
}

Cursor_Shape :: enum u8 {
	Block,
	Horizontal,
	Vertical,
}

Mode :: struct {
	shape: Cursor_Shape,
	percentage: u8,
	blink_wait, blink_on, blink_off: u32,
	highlight: u32,
}

// A consistent picture of grid 1 as of the last `flush`.
Screen :: struct {
	columns, rows: int,
	cells: []Cell,
	cursor_row, cursor_column: int,
	mode: Mode,
	cursor_style_enabled: bool,
	busy: bool,
	default_foreground, default_background, default_special: Color,
	highlights: []Highlight,
	generation: u64,
}

Start :: struct {
	argv: []string,
	cwd: string,
	env: []string,
	columns, rows: int,
}

Poll :: struct {
	flushed: bool,
	title_changed: bool,
	directory_changed: bool,
	buffer_changed: bool,
	bell: bool,
	exited: bool,
}

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
	Wheel,
	Move,
}

Mouse_Action :: enum u8 {
	None,
	Press,
	Drag,
	Release,
	Up,
	Down,
	Left,
	Right,
}

Modifier :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Super,
}

@(private)
REQUEST_SLOTS :: 8

// A message may not outgrow this while waiting for its last bytes.
@(private)
MAX_MESSAGE :: 1 << 26

// Neovim sends set_title only while 'title' is on, so the current buffer name is reported by an
// autocmd on this channel instead; special buffers (help, terminals, pickers) are not files, and keep
// the name before them. nvim_get_api_info is not callable from Lua, so the channel is found by the
// client name nvim_set_client_info registered just before.
@(private)
BUFFER_WATCH :: `local channel
for _, chan in ipairs(vim.api.nvim_list_chans()) do
	if chan.client and chan.client.name == 'aiodev' then channel = chan.id end
end
if not channel then return end
local function report()
	if vim.bo.buftype ~= '' then return end
	vim.rpcnotify(channel, 'aiodev_buffer', vim.api.nvim_buf_get_name(0))
end
local group = vim.api.nvim_create_augroup('aiodev_buffer', {clear = true})
vim.api.nvim_create_autocmd({'BufEnter', 'BufFilePost', 'BufWritePost'}, {group = group, callback = report})
report()`

@(private)
Request :: struct {
	id: u32,
	// Always a literal: the table never owns it.
	method: string,
}

Client :: struct {
	screen: Screen,
	title: string,
	directory: string,
	// The full name of the current buffer, "" when unnamed; owned.
	buffer: string,
	mouse: bool,
	exit_code: int,
	allocator: runtime.Allocator,
	process: ^spawn.Process,
	// The size most recently requested from Neovim, so an unchanged resize sends nothing.
	columns, rows: int,
	// The encoded bytes of the most recent outgoing message; tests decode it.
	sent: Msgpack_Writer,
	pending: [dynamic]u8,
	next_id: u32,
	requests: [REQUEST_SLOTS]Request,
	clusters: [dynamic]string,
	cluster_index: map[string]u32,
	back: Back,
	// Redraw handlers set these; receive resets them and returns them.
	events: Poll,
	fault: Error,
}

// Zero values are valid, so a Client may be fed by receive without start. The first call fixes
// the allocator and the default colours.
@(private)
prepare :: proc(c: ^Client) {
	if c.allocator.procedure != nil {return}
	c.allocator = context.allocator
	c.back.default_foreground, c.screen.default_foreground = 0xFFFFFF, 0xFFFFFF
	c.back.default_special, c.screen.default_special = 0xFF0000, 0xFF0000
}

@(require_results)
start :: proc(c: ^Client, options: Start, wake: spawn.Wake, allocator := context.allocator) -> Error {
	c^ = {}
	context.allocator = allocator
	prepare(c)
	c.columns, c.rows = max(options.columns, 1), max(options.rows, 1)
	process, error := spawn.start(options.argv, {
		cwd = options.cwd,
		env = options.env,
		keep_stdin = true,
		keep_crlf = true,
		discard_stderr = true,
	}, wake, allocator)
	if error != .None {
		#partial switch error {
		case .Not_Found: return .Not_Found
		case .Out_Of_Memory: return .Out_Of_Memory
		case: return .Start_Failed
		}
	}
	c.process = process
	failure := request_begin(c, "nvim_set_client_info", 5)
	if failure == .None {
		msgpack_write_str(&c.sent, "aiodev")
		msgpack_write_map(&c.sent, 0)
		msgpack_write_str(&c.sent, "ui")
		msgpack_write_map(&c.sent, 0)
		msgpack_write_map(&c.sent, 0)
		failure = transmit(c)
	}
	if failure == .None {
		failure = request_begin(c, "nvim_ui_attach", 3)
	}
	if failure == .None {
		msgpack_write_int(&c.sent, i64(c.columns))
		msgpack_write_int(&c.sent, i64(c.rows))
		msgpack_write_map(&c.sent, 2)
		msgpack_write_str(&c.sent, "rgb")
		msgpack_write_bool(&c.sent, true)
		msgpack_write_str(&c.sent, "ext_linegrid")
		msgpack_write_bool(&c.sent, true)
		failure = transmit(c)
	}
	if failure == .None {
		notification_begin(c, "nvim_exec_lua", 2)
		msgpack_write_str(&c.sent, BUFFER_WATCH)
		msgpack_write_array(&c.sent, 0)
		failure = transmit(c)
	}
	if failure != .None {
		destroy(c)
		return failure
	}
	return .None
}

// Accepts a zero or partially started Client; the process is killed.
destroy :: proc(c: ^Client) {
	spawn.destroy(c.process)
	delete(c.sent.bytes)
	delete(c.pending)
	delete(c.title, c.allocator)
	delete(c.directory, c.allocator)
	delete(c.buffer, c.allocator)
	delete(c.screen.cells, c.allocator)
	delete(c.screen.highlights, c.allocator)
	for text in c.clusters {delete(text, c.allocator)}
	delete(c.clusters)
	delete(c.cluster_index)
	delete(c.back.cells)
	delete(c.back.modes)
	delete(c.back.highlights)
	c^ = {}
}

@(require_results)
poll :: proc(c: ^Client) -> Poll {
	if c.process == nil {return {}}
	output := spawn.poll(c.process)
	events: Poll
	if len(output.stdout) > 0 {events, _ = receive(c, output.stdout)}
	if output.exited {
		events.exited = true
		c.exit_code = output.code
	}
	return events
}

// Appends bytes and handles every message they complete. A message cut off at the end of bytes
// waits for the next call. An error from the stream itself (Protocol) discards what was pending;
// a failure to answer Neovim because there is no process is not an error here.
@(require_results)
receive :: proc(c: ^Client, bytes: []u8) -> (events: Poll, error: Error) {
	prepare(c)
	context.allocator = c.allocator
	c.events, c.fault = {}, .None
	if _, append_error := append(&c.pending, ..bytes); append_error != nil {
		log.errorf("neovim: buffering %d bytes failed: %v", len(bytes), append_error)
		return {}, .Out_Of_Memory
	}
	reader := Msgpack_Reader{data = c.pending[:]}
	for c.fault == .None {
		begin := reader.offset
		skipped := msgpack_skip(&reader)
		if skipped == .Short {break}
		if skipped == .Malformed {
			log.errorf("neovim: malformed msgpack at stream offset %d, dropping %d bytes", begin, len(c.pending))
			clear(&c.pending)
			return c.events, .Protocol
		}
		message_handle(c, c.pending[begin:reader.offset])
	}
	consumed := reader.offset
	remaining := len(c.pending) - consumed
	if c.fault == .None && remaining > MAX_MESSAGE {
		log.errorf("neovim: a message over %d bytes is still incomplete", MAX_MESSAGE)
		clear(&c.pending)
		return c.events, .Protocol
	}
	remove_range(&c.pending, 0, consumed)
	return c.events, c.fault
}

// UTF-8 of a cluster glyph, or "" for any other glyph.
cluster :: proc(c: ^Client, glyph: u32) -> string {
	if glyph & GLYPH_CLUSTER == 0 {return ""}
	index := int(glyph & ~GLYPH_CLUSTER)
	if index >= len(c.clusters) {return ""}
	return c.clusters[index]
}

@(private)
message_handle :: proc(c: ^Client, data: []u8) {
	r := Msgpack_Reader{data = data}
	header, header_error := msgpack_read(&r)
	if header_error != .None || header.kind != .Array || header.count < 3 {
		log.warn("neovim: ignoring a message that is not an RPC array")
		return
	}
	kind, kind_error := msgpack_read(&r)
	if kind_error != .None || kind.kind != .Integer {
		log.warn("neovim: ignoring an RPC message without a type")
		return
	}
	switch kind.integer {
	case 0: request_handle(c, &r, header.count)
	case 1: response_handle(c, &r, header.count)
	case 2: notification_handle(c, &r)
	case: log.warnf("neovim: ignoring an RPC message of type %d", kind.integer)
	}
}

// Neovim blocks until a request is answered, and AIODev serves none.
@(private)
request_handle :: proc(c: ^Client, r: ^Msgpack_Reader, count: int) {
	if count != 4 {return}
	id, id_error := msgpack_read(r)
	method, method_error := msgpack_read(r)
	if id_error != .None || id.kind != .Integer || method_error != .None {return}
	suffix :: " is not supported by AIODev"
	name := method.kind == .String ? method.bytes : transmute([]u8)string("request")
	w := &c.sent
	clear(&w.bytes)
	w.failed = false
	msgpack_write_array(w, 4)
	msgpack_write_uint(w, 1)
	msgpack_write_int(w, id.integer)
	msgpack_write_str_header(w, len(name) + len(suffix))
	msgpack_write_raw(w, name)
	msgpack_write_raw(w, transmute([]u8)string(suffix))
	msgpack_write_nil(w)
	if transmit(c) == .Out_Of_Memory {c.fault = .Out_Of_Memory}
}

@(private)
response_handle :: proc(c: ^Client, r: ^Msgpack_Reader, count: int) {
	if count != 4 {return}
	id, id_error := msgpack_read(r)
	failure, failure_error := msgpack_read(r)
	if id_error != .None || id.kind != .Integer || failure_error != .None {return}
	method := "request"
	slot := &c.requests[u32(id.integer) % REQUEST_SLOTS]
	if slot.id == u32(id.integer) && slot.method != "" {
		method = slot.method
		slot^ = {}
	}
	if failure.kind == .Nil {return}
	text := "unknown error"
	if failure.kind == .Array && failure.count == 2 && msgpack_skip(r) == .None {
		if message, ok := msgpack_read(r); ok == .None && message.kind == .String {
			text = string(message.bytes)
		}
	}
	log.errorf("neovim: %s failed: %s", method, text)
}

@(private)
notification_handle :: proc(c: ^Client, r: ^Msgpack_Reader) {
	method, method_error := msgpack_read(r)
	if method_error != .None || method.kind != .String {return}
	switch string(method.bytes) {
	case "redraw":
		redraw_handle(c, r)
	case "aiodev_buffer":
		params, params_error := msgpack_read(r)
		if params_error != .None || params.kind != .Array || params.count != 1 {return}
		name, name_error := msgpack_read(r)
		if name_error != .None || name.kind != .String || string(name.bytes) == c.buffer {return}
		string_replace(c, &c.buffer, name.bytes)
		c.events.buffer_changed = c.fault == .None
	case "nvim_error_event":
		params, params_error := msgpack_read(r)
		if params_error != .None || params.kind != .Array || params.count != 2 {return}
		if msgpack_skip(r) != .None {return}
		if message, ok := msgpack_read(r); ok == .None && message.kind == .String {
			log.errorf("neovim: error event: %s", string(message.bytes))
		}
	}
}

@(private)
notification_begin :: proc(c: ^Client, method: string, params: int) {
	w := &c.sent
	clear(&w.bytes)
	w.failed = false
	msgpack_write_array(w, 3)
	msgpack_write_uint(w, 2)
	msgpack_write_str(w, method)
	msgpack_write_array(w, params)
}

// Starts a request; the caller appends its params and calls transmit.
@(private)
request_begin :: proc(c: ^Client, method: string, params: int) -> Error {
	w := &c.sent
	clear(&w.bytes)
	w.failed = false
	c.next_id += 1
	if c.next_id == 0 {c.next_id = 1}
	c.requests[c.next_id % REQUEST_SLOTS] = {c.next_id, method}
	msgpack_write_array(w, 4)
	msgpack_write_uint(w, 0)
	msgpack_write_uint(w, u64(c.next_id))
	msgpack_write_str(w, method)
	msgpack_write_array(w, params)
	return w.failed ? .Out_Of_Memory : .None
}

@(private, require_results)
transmit :: proc(c: ^Client) -> Error {
	if c.sent.failed {return .Out_Of_Memory}
	if c.process == nil {return .Closed}
	if spawn.write(c.process, c.sent.bytes[:]) != .None {return .Closed}
	return .None
}

@(require_results)
input :: proc(c: ^Client, keys: string) -> Error {
	prepare(c)
	context.allocator = c.allocator
	notification_begin(c, "nvim_input", 1)
	msgpack_write_str(&c.sent, keys)
	return transmit(c)
}

@(require_results)
input_mouse :: proc(
	c: ^Client,
	button: Mouse_Button,
	action: Mouse_Action,
	modifiers: bit_set[Modifier; u8],
	row, column: int,
) -> Error {
	prepare(c)
	context.allocator = c.allocator
	buttons := [Mouse_Button]string{
		.Left = "left", .Right = "right", .Middle = "middle", .Wheel = "wheel", .Move = "move",
	}
	actions := [Mouse_Action]string{
		.None = "", .Press = "press", .Drag = "drag", .Release = "release",
		.Up = "up", .Down = "down", .Left = "left", .Right = "right",
	}
	letters: [4]u8
	count := 0
	if .Shift in modifiers {letters[count] = 'S'; count += 1}
	if .Ctrl in modifiers {letters[count] = 'C'; count += 1}
	if .Alt in modifiers {letters[count] = 'A'; count += 1}
	if .Super in modifiers {letters[count] = 'D'; count += 1}
	notification_begin(c, "nvim_input_mouse", 6)
	msgpack_write_str(&c.sent, buttons[button])
	msgpack_write_str(&c.sent, actions[action])
	msgpack_write_str(&c.sent, string(letters[:count]))
	msgpack_write_int(&c.sent, 0)
	msgpack_write_int(&c.sent, i64(row))
	msgpack_write_int(&c.sent, i64(column))
	return transmit(c)
}

@(require_results)
resize :: proc(c: ^Client, columns, rows: int) -> Error {
	prepare(c)
	context.allocator = c.allocator
	wanted_columns, wanted_rows := max(columns, 1), max(rows, 1)
	if wanted_columns == c.columns && wanted_rows == c.rows {return .None}
	notification_begin(c, "nvim_ui_try_resize", 2)
	msgpack_write_int(&c.sent, i64(wanted_columns))
	msgpack_write_int(&c.sent, i64(wanted_rows))
	result := transmit(c)
	if result == .None {c.columns, c.rows = wanted_columns, wanted_rows}
	return result
}

@(require_results)
set_focus :: proc(c: ^Client, focused: bool) -> Error {
	prepare(c)
	context.allocator = c.allocator
	notification_begin(c, "nvim_ui_set_focus", 1)
	msgpack_write_bool(&c.sent, focused)
	return transmit(c)
}

// Pasted text goes through Neovim's own paste handling; crlf turns Windows line ends into newlines.
@(require_results)
paste :: proc(c: ^Client, text: string) -> Error {
	prepare(c)
	context.allocator = c.allocator
	notification_begin(c, "nvim_paste", 3)
	msgpack_write_str(&c.sent, text)
	msgpack_write_bool(&c.sent, true)
	msgpack_write_int(&c.sent, -1)
	return transmit(c)
}

// A request, so Neovim's refusal (an unreadable path, say) is logged with this method's name.
@(require_results)
edit :: proc(c: ^Client, path: string, line: int) -> Error {
	prepare(c)
	context.allocator = c.allocator
	code :: `local path, line = ...
vim.cmd('drop ' .. vim.fn.fnameescape(path))
if line > 0 then
	vim.api.nvim_win_set_cursor(0, {math.min(line, vim.api.nvim_buf_line_count(0)), 0})
end`
	if request_begin(c, "nvim_exec_lua", 2) != .None {return .Out_Of_Memory}
	msgpack_write_str(&c.sent, code)
	msgpack_write_array(&c.sent, 2)
	msgpack_write_str(&c.sent, path)
	msgpack_write_int(&c.sent, i64(line))
	return transmit(c)
}

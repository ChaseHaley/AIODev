package term

import "aio:ghostty"
import "core:log"
import "core:sync"

// A capture is the seven magic bytes, a little-endian u16 columns, a little-endian u16 rows, then
// the raw PTY payload. The header carries geometry only: columns and rows size the replay terminal
// before the first byte, while the palette stays out because a capture records bytes, not a theme.
CAPTURE_MAGIC :: "AIOVT1\n"
CAPTURE_HEADER_SIZE :: len(CAPTURE_MAGIC) + 4

// capture_header encodes the geometry a replay needs. Recording and replay share this writer and
// capture_geometry so the on-disk layout cannot drift between them.
capture_header :: proc(columns, rows: u16) -> [CAPTURE_HEADER_SIZE]u8 {
	header: [CAPTURE_HEADER_SIZE]u8
	copy(header[:], CAPTURE_MAGIC)
	header[7], header[8] = u8(columns), u8(columns >> 8)
	header[9], header[10] = u8(rows), u8(rows >> 8)
	return header
}

// capture_geometry validates a capture header. A short file, a foreign file, or a degenerate grid
// is not a capture, so callers refuse to replay it.
@(require_results)
capture_geometry :: proc(header: []u8) -> (columns, rows: u16, ok: bool) {
	if len(header) < CAPTURE_HEADER_SIZE {
		return 0, 0, false
	}
	if string(header[:len(CAPTURE_MAGIC)]) != CAPTURE_MAGIC {
		return 0, 0, false
	}
	columns = u16(header[7]) | u16(header[8]) << 8
	rows = u16(header[9]) | u16(header[10]) << 8
	return columns, rows, columns > 0 && rows > 0
}

// create_headless builds the same libghostty terminal as create() with no process behind it, so
// recorded bytes can be replayed offscreen. It starts no reader, waiter, or writer thread, and
// `spawned` stays false, so destroy performs no process cleanup.
@(require_results)
create_headless :: proc(
	geometry: Geometry,
	scrollback_lines: int,
	allocator := context.allocator,
) -> (^Session, Error) {
	s, allocation_error := new(Session, allocator)
	if allocation_error != nil {
		return nil, .Out_Of_Memory
	}
	s.allocator = allocator
	s.callback_context = context
	s.geometry = geometry
	s.queue.pending.allocator = allocator
	s.search_matches.allocator = allocator
	ok := false
	defer if !ok {
		destroy(s)
	}
	config := Config {
		geometry         = geometry,
		scrollback_lines = scrollback_lines,
	}
	if err := ghostty_create(s, config); err != .None {
		return nil, err
	}
	sync.mutex_lock(&s.mutex)
	s.status = .Running
	sync.mutex_unlock(&s.mutex)
	ok = true
	return s, .None
}

// replay_write feeds captured bytes through the parser under the session mutex. A headless session
// has no reader thread, but the terminal object itself is not thread-safe and the mutex is what
// guards it everywhere else.
replay_write :: proc(s: ^Session, data: []u8) {
	if len(data) == 0 {
		return
	}
	sync.mutex_lock(&s.mutex)
	ghostty.terminal_vt_write(s.terminal, raw_data(data), uint(len(data)))
	sync.mutex_unlock(&s.mutex)
}

// replay_snapshot reads the replayed terminal through the render-state path the app uses, so screen
// and cell output come from the production readers instead of a second formatter.
@(require_results)
replay_snapshot :: proc(s: ^Session, allocator := context.allocator) -> (Snapshot, Error) {
	state: ghostty.Render_State
	if ghostty.render_state_new(nil, &state) != .Success {
		log.error("term: creating a render state for replay failed")
		return {}, .Terminal_Failed
	}
	defer ghostty.render_state_free(state)
	sync.mutex_lock(&s.mutex)
	result := ghostty.render_state_update(state, s.terminal)
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: updating the replayed render state failed: %v", result)
		return {}, result == .Out_Of_Memory ? .Out_Of_Memory : .Terminal_Failed
	}
	return snapshot(state, allocator)
}

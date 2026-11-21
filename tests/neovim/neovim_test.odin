package neovim_test

import "aio:neovim"
import "aio:spawn"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// ---- msgpack -------------------------------------------------------------------------------------

Writer :: neovim.Msgpack_Writer

read_one :: proc(t: ^testing.T, bytes: []u8) -> (value: neovim.Msgpack_Value, consumed: int) {
	r := neovim.Msgpack_Reader{data = bytes}
	error: neovim.Msgpack_Error
	value, error = neovim.msgpack_read(&r)
	testing.expect_value(t, error, neovim.Msgpack_Error.None)
	return value, r.offset
}

@(test)
msgpack_integers_use_the_smallest_encoding :: proc(t: ^testing.T) {
	Case :: struct {
		value: i64,
		encoded: []u8,
	}
	cases := [?]Case{
		{0, {0x00}},
		{127, {0x7f}},
		{128, {0xcc, 0x80}},
		{255, {0xcc, 0xff}},
		{256, {0xcd, 0x01, 0x00}},
		{65535, {0xcd, 0xff, 0xff}},
		{65536, {0xce, 0x00, 0x01, 0x00, 0x00}},
		{4294967295, {0xce, 0xff, 0xff, 0xff, 0xff}},
		{4294967296, {0xcf, 0, 0, 0, 1, 0, 0, 0, 0}},
		{max(i64), {0xcf, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}},
		{-1, {0xff}},
		{-32, {0xe0}},
		{-33, {0xd0, 0xdf}},
		{-128, {0xd0, 0x80}},
		{-129, {0xd1, 0xff, 0x7f}},
		{-32768, {0xd1, 0x80, 0x00}},
		{-32769, {0xd2, 0xff, 0xff, 0x7f, 0xff}},
		{-2147483648, {0xd2, 0x80, 0x00, 0x00, 0x00}},
		{-2147483649, {0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff}},
		{min(i64), {0xd3, 0x80, 0, 0, 0, 0, 0, 0, 0}},
	}
	for item in cases {
		w: Writer
		neovim.msgpack_write_int(&w, item.value)
		testing.expect(t, slice.equal(w.bytes[:], item.encoded), fmt.tprintf("encoding %d: %x", item.value, w.bytes[:]))
		value, consumed := read_one(t, w.bytes[:])
		testing.expect_value(t, value.kind, neovim.Msgpack_Kind.Integer)
		testing.expect_value(t, value.integer, item.value)
		testing.expect_value(t, consumed, len(item.encoded))
		delete(w.bytes)
	}
}

@(test)
msgpack_unsigned_beyond_i64 :: proc(t: ^testing.T) {
	w: Writer
	defer delete(w.bytes)
	neovim.msgpack_write_uint(&w, max(u64))
	testing.expect_value(t, len(w.bytes), 9)
	value, _ := read_one(t, w.bytes[:])
	testing.expect_value(t, value.kind, neovim.Msgpack_Kind.Unsigned)
	testing.expect_value(t, u64(value.integer), max(u64))
	clear(&w.bytes)
	neovim.msgpack_write_uint(&w, u64(max(i64)))
	value, _ = read_one(t, w.bytes[:])
	testing.expect_value(t, value.kind, neovim.Msgpack_Kind.Integer)
	testing.expect_value(t, value.integer, max(i64))
}

@(test)
msgpack_reads_every_integer_width :: proc(t: ^testing.T) {
	Case :: struct {
		bytes: []u8,
		value: i64,
	}
	cases := [?]Case{
		{{0xcc, 0x01}, 1},
		{{0xcd, 0x00, 0x01}, 1},
		{{0xce, 0, 0, 0, 1}, 1},
		{{0xcf, 0, 0, 0, 0, 0, 0, 0, 1}, 1},
		{{0xd0, 0x01}, 1},
		{{0xd1, 0x00, 0x01}, 1},
		{{0xd2, 0, 0, 0, 1}, 1},
		{{0xd3, 0, 0, 0, 0, 0, 0, 0, 1}, 1},
		{{0xd0, 0xff}, -1},
		{{0xd1, 0xff, 0xff}, -1},
		{{0xd2, 0xff, 0xff, 0xff, 0xff}, -1},
		{{0xd3, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, -1},
		{{0xcc, 0xff}, 255},
		{{0xce, 0xff, 0xff, 0xff, 0xff}, 4294967295},
	}
	for item in cases {
		value, consumed := read_one(t, item.bytes)
		testing.expect_value(t, value.kind, neovim.Msgpack_Kind.Integer)
		testing.expect_value(t, value.integer, item.value)
		testing.expect_value(t, consumed, len(item.bytes))
	}
}

@(test)
msgpack_nil_bool_and_floats :: proc(t: ^testing.T) {
	w: Writer
	defer delete(w.bytes)
	neovim.msgpack_write_nil(&w)
	neovim.msgpack_write_bool(&w, true)
	neovim.msgpack_write_bool(&w, false)
	neovim.msgpack_write_f32(&w, 1.5)
	neovim.msgpack_write_f64(&w, -2.25)
	r := neovim.Msgpack_Reader{data = w.bytes[:]}
	value, error := neovim.msgpack_read(&r)
	testing.expect(t, error == .None && value.kind == .Nil)
	value, error = neovim.msgpack_read(&r)
	testing.expect(t, error == .None && value.kind == .Boolean && value.boolean)
	value, error = neovim.msgpack_read(&r)
	testing.expect(t, error == .None && value.kind == .Boolean && !value.boolean)
	value, error = neovim.msgpack_read(&r)
	testing.expect(t, error == .None && value.kind == .Float && value.real == 1.5)
	value, error = neovim.msgpack_read(&r)
	testing.expect(t, error == .None && value.kind == .Float && value.real == -2.25)
	testing.expect_value(t, r.offset, len(w.bytes))
	testing.expect_value(t, w.bytes[0], u8(0xc0))
	testing.expect_value(t, w.bytes[1], u8(0xc3))
	testing.expect_value(t, w.bytes[2], u8(0xc2))
	testing.expect(t, slice.equal(w.bytes[3:8], []u8{0xca, 0x3f, 0xc0, 0x00, 0x00}))
}

@(test)
msgpack_string_and_binary_lengths :: proc(t: ^testing.T) {
	// Header size by payload length: str 1,1,2,2,3,3,5 and bin 2,2,2,3,3,5 at the boundaries.
	str_lengths := [?]int{0, 31, 32, 255, 256, 65535, 65536}
	str_headers := [?]int{1, 1, 2, 2, 3, 3, 5}
	bin_lengths := [?]int{0, 255, 256, 65535, 65536}
	bin_headers := [?]int{2, 2, 3, 3, 5}
	for length, index in str_lengths {
		payload := make([]u8, length)
		defer delete(payload)
		for &b, i in payload {b = u8('a' + i % 26)}
		w: Writer
		neovim.msgpack_write_str(&w, string(payload))
		testing.expect_value(t, len(w.bytes) - length, str_headers[index])
		value, consumed := read_one(t, w.bytes[:])
		testing.expect_value(t, value.kind, neovim.Msgpack_Kind.String)
		testing.expect(t, slice.equal(value.bytes, payload))
		testing.expect_value(t, consumed, len(w.bytes))
		delete(w.bytes)
	}
	for length, index in bin_lengths {
		payload := make([]u8, length)
		defer delete(payload)
		for &b, i in payload {b = u8(i)}
		w: Writer
		neovim.msgpack_write_bin(&w, payload)
		testing.expect_value(t, len(w.bytes) - length, bin_headers[index])
		value, consumed := read_one(t, w.bytes[:])
		testing.expect_value(t, value.kind, neovim.Msgpack_Kind.Binary)
		testing.expect(t, slice.equal(value.bytes, payload))
		testing.expect_value(t, consumed, len(w.bytes))
		delete(w.bytes)
	}
}

@(test)
msgpack_container_headers :: proc(t: ^testing.T) {
	counts := [?]int{0, 15, 16, 65535, 65536}
	headers := [?]int{1, 1, 3, 3, 5}
	for count, index in counts {
		w: Writer
		neovim.msgpack_write_array(&w, count)
		testing.expect_value(t, len(w.bytes), headers[index])
		value, _ := read_one(t, w.bytes[:])
		testing.expect_value(t, value.kind, neovim.Msgpack_Kind.Array)
		testing.expect_value(t, value.count, count)
		clear(&w.bytes)
		neovim.msgpack_write_map(&w, count)
		testing.expect_value(t, len(w.bytes), headers[index])
		value, _ = read_one(t, w.bytes[:])
		testing.expect_value(t, value.kind, neovim.Msgpack_Kind.Map)
		testing.expect_value(t, value.count, count)
		delete(w.bytes)
	}
	// array32 and map32 encodings that a minimal writer would not choose still decode.
	value, _ := read_one(t, {0xdd, 0, 0, 0, 2})
	testing.expect(t, value.kind == .Array && value.count == 2)
	value, _ = read_one(t, {0xdf, 0, 0, 0, 3})
	testing.expect(t, value.kind == .Map && value.count == 3)
	value, _ = read_one(t, {0xde, 0, 3})
	testing.expect(t, value.kind == .Map && value.count == 3)
}

@(test)
msgpack_wide_string_encodings_decode :: proc(t: ^testing.T) {
	value, consumed := read_one(t, {0xdb, 0, 0, 0, 2, 'h', 'i'})
	testing.expect(t, value.kind == .String && string(value.bytes) == "hi")
	testing.expect_value(t, consumed, 7)
	value, _ = read_one(t, {0xda, 0, 1, 'x'})
	testing.expect(t, value.kind == .String && string(value.bytes) == "x")
	value, _ = read_one(t, {0xc6, 0, 0, 0, 1, 0xff})
	testing.expect(t, value.kind == .Binary && len(value.bytes) == 1 && value.bytes[0] == 0xff)
}

@(test)
msgpack_ext_round_trip :: proc(t: ^testing.T) {
	sizes := [?]int{1, 2, 3, 4, 8, 16, 17, 255, 256, 65535, 65536}
	for size in sizes {
		payload := make([]u8, size)
		defer delete(payload)
		for &b, i in payload {b = u8(i * 7)}
		w: Writer
		neovim.msgpack_write_ext(&w, -3, payload)
		value, consumed := read_one(t, w.bytes[:])
		testing.expect_value(t, value.kind, neovim.Msgpack_Kind.Ext)
		testing.expect_value(t, value.integer, i64(-3))
		testing.expect(t, slice.equal(value.bytes, payload))
		testing.expect_value(t, consumed, len(w.bytes))
		r := neovim.Msgpack_Reader{data = w.bytes[:]}
		testing.expect_value(t, neovim.msgpack_skip(&r), neovim.Msgpack_Error.None)
		testing.expect_value(t, r.offset, len(w.bytes))
		delete(w.bytes)
	}
}

nested_message :: proc(w: ^Writer) {
	neovim.msgpack_write_array(w, 5)
	neovim.msgpack_write_int(w, -300)
	neovim.msgpack_write_str(w, "hello")
	neovim.msgpack_write_map(w, 2)
	neovim.msgpack_write_str(w, "k")
	neovim.msgpack_write_array(w, 3)
	neovim.msgpack_write_f64(w, 1.5)
	neovim.msgpack_write_nil(w)
	neovim.msgpack_write_bin(w, {1, 2, 3})
	neovim.msgpack_write_int(w, 7)
	neovim.msgpack_write_map(w, 0)
	neovim.msgpack_write_ext(w, 5, {9, 9, 9})
	neovim.msgpack_write_bool(w, true)
}

@(test)
msgpack_skip_distinguishes_short_from_malformed :: proc(t: ^testing.T) {
	w: Writer
	defer delete(w.bytes)
	nested_message(&w)
	r := neovim.Msgpack_Reader{data = w.bytes[:]}
	testing.expect_value(t, neovim.msgpack_skip(&r), neovim.Msgpack_Error.None)
	testing.expect_value(t, r.offset, len(w.bytes))
	// Only the whole message completes it: every shorter prefix is merely cut off.
	for length in 0 ..< len(w.bytes) {
		short := neovim.Msgpack_Reader{data = w.bytes[:length]}
		testing.expect_value(t, neovim.msgpack_skip(&short), neovim.Msgpack_Error.Short)
		testing.expect_value(t, short.offset, 0)
	}
	append(&w.bytes, 0xc1)
	trailing := neovim.Msgpack_Reader{data = w.bytes[:]}
	testing.expect_value(t, neovim.msgpack_skip(&trailing), neovim.Msgpack_Error.None)
	testing.expect_value(t, trailing.offset, len(w.bytes) - 1)
}

@(test)
msgpack_skip_reports_garbage_as_malformed :: proc(t: ^testing.T) {
	cases := [?][]u8{
		{0xc1},
		{0x92, 0x01, 0xc1},
		{0x81, 0xa1, 'k', 0xc1},
		{0x91, 0x91, 0x91, 0xc1, 0x00},
	}
	for bytes in cases {
		r := neovim.Msgpack_Reader{data = bytes}
		testing.expect_value(t, neovim.msgpack_skip(&r), neovim.Msgpack_Error.Malformed)
		testing.expect_value(t, r.offset, 0)
		_, error := neovim.msgpack_read(&r)
		if bytes[0] == 0xc1 {testing.expect_value(t, error, neovim.Msgpack_Error.Malformed)}
	}
	empty := neovim.Msgpack_Reader{}
	testing.expect_value(t, neovim.msgpack_skip(&empty), neovim.Msgpack_Error.Short)
}

@(test)
msgpack_skip_survives_hostile_depth :: proc(t: ^testing.T) {
	depth := 1 << 18
	bytes := make([]u8, depth + 1)
	defer delete(bytes)
	for index in 0 ..< depth {bytes[index] = 0x91}
	bytes[depth] = 0xc0
	r := neovim.Msgpack_Reader{data = bytes}
	testing.expect_value(t, neovim.msgpack_skip(&r), neovim.Msgpack_Error.None)
	testing.expect_value(t, r.offset, len(bytes))
	// A claimed 4 billion elements are not allocated or looped over; the bytes simply run out.
	huge := neovim.Msgpack_Reader{data = {0xdd, 0xff, 0xff, 0xff, 0xff, 0x01}}
	testing.expect_value(t, neovim.msgpack_skip(&huge), neovim.Msgpack_Error.Short)
}

// ---- building redraw messages --------------------------------------------------------------------

begin_notification :: proc(w: ^Writer, method: string, params: int) {
	clear(&w.bytes)
	neovim.msgpack_write_array(w, 3)
	neovim.msgpack_write_uint(w, 2)
	neovim.msgpack_write_str(w, method)
	neovim.msgpack_write_array(w, params)
}

begin_redraw :: proc(w: ^Writer, events: int) {
	begin_notification(w, "redraw", events)
}

begin_event :: proc(w: ^Writer, name: string, tuples: int) {
	neovim.msgpack_write_array(w, 1 + tuples)
	neovim.msgpack_write_str(w, name)
}

write_ints :: proc(w: ^Writer, values: ..i64) {
	neovim.msgpack_write_array(w, len(values))
	for value in values {neovim.msgpack_write_int(w, value)}
}

Text_Cell :: struct {
	text: string,
	highlight: i64, // -1 omits it
	repeat: i64, // 0 omits it
}

write_line_event :: proc(w: ^Writer, grid, row, column: i64, cells: []Text_Cell) {
	begin_event(w, "grid_line", 1)
	neovim.msgpack_write_array(w, 5)
	neovim.msgpack_write_int(w, grid)
	neovim.msgpack_write_int(w, row)
	neovim.msgpack_write_int(w, column)
	neovim.msgpack_write_array(w, len(cells))
	for cell in cells {
		neovim.msgpack_write_array(w, 1 + int(cell.highlight >= 0) + int(cell.repeat > 0))
		neovim.msgpack_write_str(w, cell.text)
		if cell.highlight >= 0 {neovim.msgpack_write_int(w, cell.highlight)}
		if cell.repeat > 0 {neovim.msgpack_write_int(w, cell.repeat)}
	}
	neovim.msgpack_write_bool(w, false)
}

write_empty_event :: proc(w: ^Writer, name: string) {
	begin_event(w, name, 1)
	neovim.msgpack_write_array(w, 0)
}

write_string_event :: proc(w: ^Writer, name, text: string) {
	begin_event(w, name, 1)
	neovim.msgpack_write_array(w, 1)
	neovim.msgpack_write_str(w, text)
}

// One redraw notification holding a single event with one args tuple, for tests that need little.
single :: proc(w: ^Writer, name: string, values: ..i64) {
	begin_redraw(w, 1)
	begin_event(w, name, 1)
	write_ints(w, ..values)
}

feed :: proc(t: ^testing.T, c: ^neovim.Client, w: ^Writer) -> neovim.Poll {
	events, error := neovim.receive(c, w.bytes[:])
	testing.expect_value(t, error, neovim.Error.None)
	return events
}

flush_screen :: proc(t: ^testing.T, c: ^neovim.Client, w: ^Writer) {
	begin_redraw(w, 1)
	write_empty_event(w, "flush")
	events := feed(t, c, w)
	testing.expect(t, events.flushed)
}

resize_screen :: proc(t: ^testing.T, c: ^neovim.Client, w: ^Writer, columns, rows: i64) {
	single(w, "grid_resize", 1, columns, rows)
	_ = feed(t, c, w)
	flush_screen(t, c, w)
}

// Grid 1's cells, which hold the whole screen until Neovim shows other grids.
base_cells :: proc(c: ^neovim.Client) -> []neovim.Cell {
	return c.screen.grids[0].cells
}

// What the screen shows in one row, windows and floats composed.
row_text :: proc(c: ^neovim.Client, row: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for column in 0 ..< c.screen.columns {
		cell, _ := neovim.screen_cell(&c.screen, row, column)
		glyph := cell.glyph
		switch {
		case glyph == 0:
		case glyph & neovim.GLYPH_CLUSTER != 0: strings.write_string(&builder, neovim.cluster(c, glyph))
		case: strings.write_rune(&builder, rune(glyph))
		}
	}
	return strings.to_string(builder)
}

Fixture :: struct {
	client: neovim.Client,
	writer: Writer,
}

fixture_destroy :: proc(f: ^Fixture) {
	neovim.destroy(&f.client)
	delete(f.writer.bytes)
}

// ---- redraw model --------------------------------------------------------------------------------

@(test)
redraw_publishes_once_at_flush_even_byte_by_byte :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	begin_redraw(w, 5)
	begin_event(w, "grid_resize", 1)
	write_ints(w, 1, 4, 2)
	write_empty_event(w, "busy_start")
	write_line_event(w, 1, 0, 0, {{"a", 1, 0}, {"b", -1, 0}, {"c", 2, 2}})
	begin_event(w, "grid_cursor_goto", 1)
	write_ints(w, 1, 1, 3)
	write_empty_event(w, "flush")
	flushes := 0
	for _, index in w.bytes {
		events, error := neovim.receive(&f.client, w.bytes[index:index + 1])
		testing.expect_value(t, error, neovim.Error.None)
		if events.flushed {flushes += 1}
		if index < len(w.bytes) - 1 {
			testing.expect_value(t, f.client.screen.generation, u64(0))
			testing.expect_value(t, f.client.screen.columns, 0)
		}
	}
	testing.expect_value(t, flushes, 1)
	screen := f.client.screen
	testing.expect_value(t, screen.generation, u64(1))
	testing.expect_value(t, screen.columns, 4)
	testing.expect_value(t, screen.rows, 2)
	cells := base_cells(&f.client)
	testing.expect_value(t, len(cells), 8)
	testing.expect_value(t, cells[0], neovim.Cell{'a', 1})
	testing.expect_value(t, cells[1], neovim.Cell{'b', 1})
	testing.expect_value(t, cells[2], neovim.Cell{'c', 2})
	testing.expect_value(t, cells[3], neovim.Cell{'c', 2})
	testing.expect_value(t, cells[4], neovim.Cell{' ', 0})
	testing.expect_value(t, screen.cursor_grid, 1)
	testing.expect_value(t, screen.cursor_screen_row, 1)
	testing.expect_value(t, screen.cursor_screen_column, 3)
	testing.expect_value(t, screen.cursor_row, 1)
	testing.expect_value(t, screen.cursor_column, 3)
	testing.expect(t, screen.busy)
}

@(test)
messages_split_across_chunks_wait_for_the_rest :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	first, second: Writer
	defer delete(first.bytes)
	defer delete(second.bytes)
	single(&first, "grid_resize", 1, 3, 1)
	begin_redraw(&second, 2)
	write_line_event(&second, 1, 0, 0, {{"x", 0, 3}})
	write_empty_event(&second, "flush")
	// The first message is whole, the second is cut off inside its flush event.
	chunk := slice.concatenate([][]u8{first.bytes[:], second.bytes[:len(second.bytes) - 3]})
	defer delete(chunk)
	events, error := neovim.receive(&f.client, chunk)
	testing.expect_value(t, error, neovim.Error.None)
	testing.expect(t, !events.flushed)
	events, error = neovim.receive(&f.client, second.bytes[len(second.bytes) - 3:])
	testing.expect_value(t, error, neovim.Error.None)
	testing.expect(t, events.flushed)
	testing.expect_value(t, base_cells(&f.client)[2].glyph, u32('x'))
	// Both messages whole in one chunk, then nothing.
	both := slice.concatenate([][]u8{second.bytes[:], second.bytes[:]})
	defer delete(both)
	events, error = neovim.receive(&f.client, both)
	testing.expect_value(t, error, neovim.Error.None)
	testing.expect(t, events.flushed)
	testing.expect_value(t, f.client.screen.generation, u64(3))
}

@(test)
changes_after_the_last_flush_stay_hidden :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 3, 1)
	begin_redraw(w, 2)
	write_line_event(w, 1, 0, 0, {{"q", 0, 3}})
	begin_event(w, "grid_cursor_goto", 1)
	write_ints(w, 1, 0, 2)
	events := feed(t, &f.client, w)
	testing.expect(t, !events.flushed)
	testing.expect_value(t, base_cells(&f.client)[0].glyph, u32(' '))
	testing.expect_value(t, f.client.screen.cursor_column, 0)
	testing.expect_value(t, f.client.screen.generation, u64(1))
	flush_screen(t, &f.client, w)
	testing.expect_value(t, base_cells(&f.client)[0].glyph, u32('q'))
	testing.expect_value(t, f.client.screen.cursor_column, 2)
	testing.expect_value(t, f.client.screen.generation, u64(2))
}

@(test)
grid_line_repeat_and_highlight_carry :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 8, 2)
	begin_redraw(w, 1)
	write_line_event(w, 1, 1, 1, {{"x", 2, 3}, {"y", -1, 0}, {"z", 5, 0}, {"w", 5, 2}})
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	row := base_cells(&f.client)[8:16]
	expected := [8]neovim.Cell{
		{' ', 0}, {'x', 2}, {'x', 2}, {'x', 2}, {'y', 2}, {'z', 5}, {'w', 5}, {'w', 5},
	}
	for cell, index in expected {testing.expect_value(t, row[index], cell)}
	testing.expect_value(t, base_cells(&f.client)[0], neovim.Cell{' ', 0})
}

@(test)
wide_characters_have_a_zero_tail :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 5, 1)
	begin_redraw(w, 1)
	write_line_event(w, 1, 0, 0, {{"漢", 4, 0}, {"", -1, 0}, {"a", 0, 0}, {"😀", 0, 0}, {"", 0, 0}})
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	cells := base_cells(&f.client)
	testing.expect_value(t, cells[0], neovim.Cell{0x6f22, 4})
	testing.expect_value(t, cells[1], neovim.Cell{0, 4})
	testing.expect_value(t, cells[2], neovim.Cell{'a', 0})
	testing.expect_value(t, cells[3], neovim.Cell{0x1f600, 0})
	testing.expect_value(t, cells[4], neovim.Cell{0, 0})
	testing.expect_value(t, neovim.cluster(&f.client, cells[0].glyph), "")
	testing.expect_value(t, len(f.client.clusters), 0)
}

@(test)
clusters_are_interned_and_round_trip :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 6, 1)
	combining := "e\u0301"
	family := "\U0001F468\u200D\U0001F469\u200D\U0001F467"
	begin_redraw(w, 1)
	write_line_event(w, 1, 0, 0, {
		{combining, 1, 0}, {family, 1, 0}, {"", 1, 0}, {combining, 2, 0}, {"\u00e9", 0, 0},
	})
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	cells := base_cells(&f.client)
	testing.expect(t, cells[0].glyph & neovim.GLYPH_CLUSTER != 0)
	testing.expect(t, cells[1].glyph & neovim.GLYPH_CLUSTER != 0)
	testing.expect_value(t, cells[2].glyph, u32(0))
	testing.expect_value(t, cells[3].glyph, cells[0].glyph)
	testing.expect_value(t, cells[3].highlight, u32(2))
	testing.expect_value(t, cells[4].glyph, u32(0xe9))
	testing.expect_value(t, neovim.cluster(&f.client, cells[0].glyph), combining)
	testing.expect_value(t, neovim.cluster(&f.client, cells[1].glyph), family)
	testing.expect_value(t, neovim.cluster(&f.client, cells[4].glyph), "")
	testing.expect_value(t, neovim.cluster(&f.client, neovim.GLYPH_CLUSTER | 99), "")
	testing.expect_value(t, len(f.client.clusters), 2)
}

@(test)
grid_scroll_moves_only_the_region :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	letters := [6]string{"a", "b", "c", "d", "e", "f"}
	fill :: proc(t: ^testing.T, c: ^neovim.Client, w: ^Writer, letters: []string) {
		begin_redraw(w, len(letters))
		for letter, row in letters {write_line_event(w, 1, i64(row), 0, {{letter, 0, 5}})}
		_ = feed(t, c, w)
	}
	resize_screen(t, &f.client, w, 5, 6)
	fill(t, &f.client, w, letters[:])
	single(w, "grid_scroll", 1, 1, 5, 1, 4, 1, 0)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	up := [6]string{"aaaaa", "bcccb", "cdddc", "deeed", "eeeee", "fffff"}
	for expected, row in up {testing.expect_value(t, row_text(&f.client, row), expected)}
	fill(t, &f.client, w, letters[:])
	single(w, "grid_scroll", 1, 1, 5, 1, 4, -2, 0)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	down := [6]string{"aaaaa", "bbbbb", "ccccc", "dbbbd", "eccce", "fffff"}
	for expected, row in down {testing.expect_value(t, row_text(&f.client, row), expected)}
	// Scrolling by the whole region height or more changes nothing; so does a bogus region.
	fill(t, &f.client, w, letters[:])
	single(w, "grid_scroll", 1, 1, 5, 1, 4, 4, 0)
	_ = feed(t, &f.client, w)
	single(w, "grid_scroll", 1, 4, 2, 0, 5, 1, 0)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	unchanged := [6]string{"aaaaa", "bbbbb", "ccccc", "ddddd", "eeeee", "fffff"}
	for expected, row in unchanged {testing.expect_value(t, row_text(&f.client, row), expected)}
}

@(test)
grid_clear_resize_and_destroy :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 3, 2)
	begin_redraw(w, 1)
	write_line_event(w, 1, 0, 0, {{"k", 3, 3}})
	_ = feed(t, &f.client, w)
	single(w, "grid_clear", 1)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	for cell in base_cells(&f.client) {testing.expect_value(t, cell, neovim.Cell{' ', 0})}
	resize_screen(t, &f.client, w, 2, 3)
	testing.expect_value(t, f.client.screen.columns, 2)
	testing.expect_value(t, f.client.screen.rows, 3)
	testing.expect_value(t, len(base_cells(&f.client)), 6)
	single(w, "grid_destroy", 1)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.columns, 0)
	testing.expect_value(t, len(base_cells(&f.client)), 0)
}

@(test)
unpositioned_grids_stay_hidden :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 3, 1)
	begin_redraw(w, 4)
	write_line_event(w, 2, 0, 0, {{"z", 0, 3}})
	begin_event(w, "grid_cursor_goto", 1)
	write_ints(w, 2, 0, 2)
	begin_event(w, "grid_resize", 1)
	write_ints(w, 2, 9, 9)
	begin_event(w, "grid_clear", 1)
	write_ints(w, 3)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	screen := &f.client.screen
	testing.expect_value(t, screen.columns, 3)
	testing.expect_value(t, len(screen.grids), 1)
	testing.expect_value(t, row_text(&f.client, 0), "   ")
	// The cursor names a grid that is not shown.
	testing.expect_value(t, screen.cursor_grid, 2)
	testing.expect_value(t, screen.cursor_column, 2)
	testing.expect_value(t, screen.cursor_screen_row, -1)
	testing.expect_value(t, screen.cursor_screen_column, -1)
}

@(test)
hostile_values_neither_crash_nor_corrupt :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 4, 2)
	begin_redraw(w, 7)
	write_line_event(w, 1, 5, 0, {{"a", 0, 4}})
	write_line_event(w, 1, -1, 0, {{"a", 0, 4}})
	write_line_event(w, 1, 0, 3, {{"a", 0, 1 << 40}})
	write_line_event(w, 1, 1, -7, {{"b", 0, 9}})
	begin_event(w, "grid_scroll", 1)
	write_ints(w, 1, -5, 1 << 40, -5, 1 << 40, 1 << 40, 0)
	begin_event(w, "grid_resize", 1)
	write_ints(w, 1, 1 << 20, 1 << 20)
	begin_event(w, "grid_resize", 1)
	write_ints(w, 1, -1, 4)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.columns, 4)
	testing.expect_value(t, f.client.screen.rows, 2)
	testing.expect_value(t, row_text(&f.client, 0), "   a")
	testing.expect_value(t, row_text(&f.client, 1), "bb  ")
}

@(test)
hl_attr_define_decodes_attributes_and_colours :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	begin_redraw(w, 1)
	begin_event(w, "hl_attr_define", 2)
	neovim.msgpack_write_array(w, 4)
	neovim.msgpack_write_int(w, 1)
	neovim.msgpack_write_map(w, 6)
	neovim.msgpack_write_str(w, "foreground")
	neovim.msgpack_write_int(w, 0xff0000)
	neovim.msgpack_write_str(w, "background")
	neovim.msgpack_write_int(w, 0x00ff00)
	neovim.msgpack_write_str(w, "bold")
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_str(w, "reverse")
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_str(w, "blend")
	neovim.msgpack_write_int(w, 30)
	neovim.msgpack_write_str(w, "standout")
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_map(w, 1)
	neovim.msgpack_write_str(w, "bold")
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_array(w, 1)
	neovim.msgpack_write_map(w, 0)
	neovim.msgpack_write_array(w, 4)
	neovim.msgpack_write_int(w, 3)
	neovim.msgpack_write_map(w, 10)
	neovim.msgpack_write_str(w, "special")
	neovim.msgpack_write_int(w, 0x123456)
	for name in ([?]string{"undercurl", "italic", "strikethrough", "underline", "underdouble"}) {
		neovim.msgpack_write_str(w, name)
		neovim.msgpack_write_bool(w, true)
	}
	neovim.msgpack_write_str(w, "underdotted")
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_str(w, "underdashed")
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_str(w, "reverse")
	neovim.msgpack_write_bool(w, false)
	neovim.msgpack_write_str(w, "altfont")
	neovim.msgpack_write_str(w, "ignored")
	neovim.msgpack_write_map(w, 0)
	neovim.msgpack_write_array(w, 0)
	_ = feed(t, &f.client, w)
	testing.expect_value(t, len(f.client.screen.highlights), 0)
	flush_screen(t, &f.client, w)
	highlights := f.client.screen.highlights
	if !testing.expect_value(t, len(highlights), 4) {return}
	first := highlights[1]
	testing.expect_value(t, first.foreground, neovim.Color(0xff0000))
	testing.expect_value(t, first.background, neovim.Color(0x00ff00))
	_, has_special := first.special.?
	testing.expect(t, !has_special)
	testing.expect_value(t, first.attributes, bit_set[neovim.Attribute; u16]{.Bold, .Reverse})
	testing.expect_value(t, first.blend, u8(30))
	testing.expect_value(t, highlights[2], neovim.Highlight{})
	third := highlights[3]
	_, has_foreground := third.foreground.?
	testing.expect(t, !has_foreground)
	testing.expect_value(t, third.special, neovim.Color(0x123456))
	testing.expect_value(t, third.attributes, bit_set[neovim.Attribute; u16]{
		.Italic, .Strikethrough, .Underline, .Undercurl, .Underdouble, .Underdotted, .Underdashed,
	})
	// With no highlight change the next publish keeps the same table.
	table := raw_data(highlights)
	flush_screen(t, &f.client, w)
	testing.expect(t, raw_data(f.client.screen.highlights) == table)
}

@(test)
default_colors_keep_the_previous_value_for_negatives :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.default_foreground, neovim.Color(0xFFFFFF))
	testing.expect_value(t, f.client.screen.default_background, neovim.Color(0x000000))
	testing.expect_value(t, f.client.screen.default_special, neovim.Color(0xFF0000))
	single(w, "default_colors_set", 0x112233, 0x445566, 0x778899, 1, 2)
	_ = feed(t, &f.client, w)
	testing.expect_value(t, f.client.screen.default_foreground, neovim.Color(0xFFFFFF))
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.default_foreground, neovim.Color(0x112233))
	testing.expect_value(t, f.client.screen.default_background, neovim.Color(0x445566))
	testing.expect_value(t, f.client.screen.default_special, neovim.Color(0x778899))
	single(w, "default_colors_set", -1, 0xabcdef, -1, -1, -1)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.default_foreground, neovim.Color(0x112233))
	testing.expect_value(t, f.client.screen.default_background, neovim.Color(0xabcdef))
	testing.expect_value(t, f.client.screen.default_special, neovim.Color(0x778899))
}

write_mode_change :: proc(w: ^Writer, name: string, index: i64) {
	begin_event(w, "mode_change", 1)
	neovim.msgpack_write_array(w, 2)
	neovim.msgpack_write_str(w, name)
	neovim.msgpack_write_int(w, index)
}

@(test)
mode_info_and_mode_change_select_the_cursor :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	begin_redraw(w, 2)
	begin_event(w, "mode_info_set", 1)
	neovim.msgpack_write_array(w, 2)
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_array(w, 3)
	neovim.msgpack_write_map(w, 3)
	neovim.msgpack_write_str(w, "cursor_shape")
	neovim.msgpack_write_str(w, "block")
	neovim.msgpack_write_str(w, "name")
	neovim.msgpack_write_str(w, "normal")
	neovim.msgpack_write_str(w, "extra")
	neovim.msgpack_write_array(w, 2)
	neovim.msgpack_write_int(w, 1)
	neovim.msgpack_write_int(w, 2)
	neovim.msgpack_write_map(w, 6)
	neovim.msgpack_write_str(w, "cursor_shape")
	neovim.msgpack_write_str(w, "vertical")
	neovim.msgpack_write_str(w, "cell_percentage")
	neovim.msgpack_write_int(w, 25)
	neovim.msgpack_write_str(w, "blinkwait")
	neovim.msgpack_write_int(w, 700)
	neovim.msgpack_write_str(w, "blinkon")
	neovim.msgpack_write_int(w, 400)
	neovim.msgpack_write_str(w, "blinkoff")
	neovim.msgpack_write_int(w, 250)
	neovim.msgpack_write_str(w, "attr_id")
	neovim.msgpack_write_int(w, 7)
	neovim.msgpack_write_map(w, 2)
	neovim.msgpack_write_str(w, "cursor_shape")
	neovim.msgpack_write_str(w, "horizontal")
	neovim.msgpack_write_str(w, "cell_percentage")
	neovim.msgpack_write_int(w, 20)
	write_mode_change(w, "insert", 1)
	_ = feed(t, &f.client, w)
	testing.expect(t, !f.client.screen.cursor_style_enabled)
	flush_screen(t, &f.client, w)
	testing.expect(t, f.client.screen.cursor_style_enabled)
	testing.expect_value(t, f.client.screen.mode, neovim.Mode{
		shape = .Vertical, percentage = 25, blink_wait = 700, blink_on = 400, blink_off = 250, highlight = 7,
	})
	begin_redraw(w, 1)
	write_mode_change(w, "operator", 2)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.mode, neovim.Mode{shape = .Horizontal, percentage = 20})
	begin_redraw(w, 1)
	write_mode_change(w, "normal", 0)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.mode, neovim.Mode{})
	// An index with no entry falls back to the default mode instead of reading out of range.
	begin_redraw(w, 1)
	write_mode_change(w, "bogus", 40)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.mode, neovim.Mode{})
}

@(test)
title_directory_mouse_busy_and_bell :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	begin_redraw(w, 5)
	write_string_event(w, "set_title", "notes 漢")
	write_string_event(w, "chdir", "C:\\work")
	write_empty_event(w, "mouse_on")
	write_empty_event(w, "busy_start")
	write_empty_event(w, "bell")
	events := feed(t, &f.client, w)
	testing.expect(t, events.title_changed && events.directory_changed && events.bell)
	testing.expect(t, !events.flushed && !events.exited)
	testing.expect_value(t, f.client.title, "notes 漢")
	testing.expect_value(t, f.client.directory, "C:\\work")
	testing.expect(t, f.client.mouse)
	flush_screen(t, &f.client, w)
	testing.expect(t, f.client.screen.busy)
	begin_redraw(w, 3)
	write_string_event(w, "set_title", "second")
	write_empty_event(w, "mouse_off")
	write_empty_event(w, "busy_stop")
	events = feed(t, &f.client, w)
	testing.expect(t, events.title_changed && !events.directory_changed && !events.bell)
	testing.expect_value(t, f.client.title, "second")
	testing.expect(t, !f.client.mouse)
	testing.expect(t, f.client.screen.busy)
	flush_screen(t, &f.client, w)
	testing.expect(t, !f.client.screen.busy)
	begin_redraw(w, 1)
	write_empty_event(w, "visual_bell")
	testing.expect(t, feed(t, &f.client, w).bell)
}

@(test)
buffer_notification_replaces_the_buffer_name :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	send_buffer :: proc(t: ^testing.T, f: ^Fixture, name: string) -> neovim.Poll {
		begin_notification(&f.writer, "aiodev_buffer", 1)
		neovim.msgpack_write_str(&f.writer, name)
		return feed(t, &f.client, &f.writer)
	}
	events := send_buffer(t, &f, "C:\\work\\main.odin")
	testing.expect(t, events.buffer_changed)
	testing.expect_value(t, f.client.buffer, "C:\\work\\main.odin")
	events = send_buffer(t, &f, "C:\\work\\main.odin")
	testing.expect(t, !events.buffer_changed)
	events = send_buffer(t, &f, "")
	testing.expect(t, events.buffer_changed)
	testing.expect_value(t, f.client.buffer, "")
	// Unknown notifications and a malformed one change nothing.
	begin_notification(w, "some_other", 1)
	neovim.msgpack_write_str(w, "x")
	testing.expect_value(t, feed(t, &f.client, w), neovim.Poll{})
	begin_notification(w, "aiodev_buffer", 1)
	neovim.msgpack_write_int(w, 5)
	testing.expect_value(t, feed(t, &f.client, w), neovim.Poll{})
}

@(test)
cursor_goto_is_published_at_flush :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 10, 5)
	single(w, "grid_cursor_goto", 1, 3, 7)
	_ = feed(t, &f.client, w)
	testing.expect_value(t, f.client.screen.cursor_row, 0)
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.cursor_row, 3)
	testing.expect_value(t, f.client.screen.cursor_column, 7)
}

@(test)
unknown_and_malformed_events_are_skipped :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 3, 1)
	begin_redraw(w, 5)
	begin_event(w, "option_set", 2)
	neovim.msgpack_write_array(w, 2)
	neovim.msgpack_write_str(w, "ambiwidth")
	neovim.msgpack_write_str(w, "single")
	neovim.msgpack_write_array(w, 2)
	neovim.msgpack_write_str(w, "linespace")
	neovim.msgpack_write_map(w, 1)
	neovim.msgpack_write_str(w, "k")
	neovim.msgpack_write_array(w, 1)
	neovim.msgpack_write_nil(w)
	begin_event(w, "win_viewport", 1)
	write_ints(w, 2, 1000, 0, 5, 1, 0)
	begin_event(w, "grid_cursor_goto", 2)
	neovim.msgpack_write_array(w, 3)
	neovim.msgpack_write_str(w, "one")
	neovim.msgpack_write_str(w, "two")
	neovim.msgpack_write_nil(w)
	write_ints(w, 1, 0, 1)
	write_line_event(w, 1, 0, 0, {{"m", 0, 3}})
	write_empty_event(w, "flush")
	events := feed(t, &f.client, w)
	testing.expect(t, events.flushed)
	testing.expect_value(t, row_text(&f.client, 0), "mmm")
	testing.expect_value(t, f.client.screen.cursor_column, 1)
}

BLANK_CELL :: neovim.Cell{glyph = ' '}

// ---- multigrid -----------------------------------------------------------------------------------

write_resize :: proc(w: ^Writer, grid, columns, rows: i64) {
	begin_event(w, "grid_resize", 1)
	write_ints(w, grid, columns, rows)
}

// A window handle as Neovim sends it: an ext value holding an integer.
write_window :: proc(w: ^Writer, handle: i64) {
	payload: Writer
	defer delete(payload.bytes)
	neovim.msgpack_write_int(&payload, handle)
	neovim.msgpack_write_ext(w, 1, payload.bytes[:])
}

write_win_pos :: proc(w: ^Writer, grid, window, row, column, width, height: i64) {
	begin_event(w, "win_pos", 1)
	neovim.msgpack_write_array(w, 6)
	neovim.msgpack_write_int(w, grid)
	write_window(w, window)
	for value in ([?]i64{row, column, width, height}) {neovim.msgpack_write_int(w, value)}
}

Float_Pos :: struct {
	grid, window: i64,
	anchor: string,
	anchor_grid: i64,
	anchor_row, anchor_column: f64,
	mouse: bool,
	zindex, compindex: i64,
	screen_row, screen_column: i64,
	// Neovim before 0.11 sends neither the compositor index nor the screen position.
	legacy: bool,
}

write_float_pos :: proc(w: ^Writer, p: Float_Pos) {
	begin_event(w, "win_float_pos", 1)
	neovim.msgpack_write_array(w, p.legacy ? 8 : 11)
	neovim.msgpack_write_int(w, p.grid)
	write_window(w, p.window)
	neovim.msgpack_write_str(w, p.anchor)
	neovim.msgpack_write_int(w, p.anchor_grid)
	neovim.msgpack_write_f64(w, p.anchor_row)
	neovim.msgpack_write_f64(w, p.anchor_column)
	neovim.msgpack_write_bool(w, p.mouse)
	neovim.msgpack_write_int(w, p.zindex)
	if p.legacy {return}
	neovim.msgpack_write_int(w, p.compindex)
	neovim.msgpack_write_int(w, p.screen_row)
	neovim.msgpack_write_int(w, p.screen_column)
}

// A float at a screen position, as Neovim 0.12 sends it.
float_at :: proc(grid, row, column: i64, zindex: i64 = 50, compindex: i64 = 0) -> Float_Pos {
	return {
		grid = grid, window = 1000 + grid, anchor = "NW", anchor_grid = 1, zindex = zindex,
		compindex = compindex, screen_row = row, screen_column = column,
	}
}

// A float as Neovim before 0.11 sends it: only the anchor.
legacy_float :: proc(
	grid: i64,
	anchor: string,
	anchor_grid: i64,
	row, column: f64,
	zindex: i64,
) -> Float_Pos {
	return {
		grid = grid, window = 1000 + grid, anchor = anchor, anchor_grid = anchor_grid, anchor_row = row,
		anchor_column = column, zindex = zindex, legacy = true,
	}
}

write_msg_pos :: proc(w: ^Writer, grid, row, zindex, compindex: i64) {
	begin_event(w, "msg_set_pos", 1)
	neovim.msgpack_write_array(w, 6)
	neovim.msgpack_write_int(w, grid)
	neovim.msgpack_write_int(w, row)
	neovim.msgpack_write_bool(w, false)
	neovim.msgpack_write_str(w, " ")
	neovim.msgpack_write_int(w, zindex)
	neovim.msgpack_write_int(w, compindex)
}

write_viewport :: proc(w: ^Writer, grid, window: i64, scroll_delta: f64) {
	begin_event(w, "win_viewport", 1)
	neovim.msgpack_write_array(w, 8)
	neovim.msgpack_write_int(w, grid)
	write_window(w, window)
	for value in ([?]i64{0, 10, 0, 0, 50}) {neovim.msgpack_write_int(w, value)}
	neovim.msgpack_write_f64(w, scroll_delta)
}

write_margins :: proc(w: ^Writer, grid, window, top, bottom, left, right: i64) {
	begin_event(w, "win_viewport_margins", 1)
	neovim.msgpack_write_array(w, 6)
	neovim.msgpack_write_int(w, grid)
	write_window(w, window)
	for value in ([?]i64{top, bottom, left, right}) {neovim.msgpack_write_int(w, value)}
}

write_grid_ids :: proc(w: ^Writer, name: string, ids: ..i64) {
	for id in ids {
		begin_event(w, name, 1)
		write_ints(w, id)
	}
}

view_of :: proc(c: ^neovim.Client, id: int) -> (found: neovim.Grid_View, ok: bool) {
	for view in c.screen.grids {
		if view.id == id {return view, true}
	}
	return {}, false
}

shown_ids :: proc(c: ^neovim.Client) -> [dynamic]int {
	ids := make([dynamic]int, context.temp_allocator)
	for view in c.screen.grids {append(&ids, view.id)}
	return ids
}

expect_ids :: proc(t: ^testing.T, c: ^neovim.Client, expected: []int, location := #caller_location) {
	ids := shown_ids(c)
	message := fmt.tprintf("grids %v, wanted %v", ids[:], expected)
	testing.expect(t, slice.equal(ids[:], expected), message, loc = location)
}

@(test)
draw_order_is_base_then_windows_then_layers :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 11)
	for id in ([?]i64{4, 2}) {write_resize(w, id, 5, 3)}
	for id in ([?]i64{5, 6, 7}) {write_resize(w, id, 4, 2)}
	write_win_pos(w, 4, 1004, 0, 10, 5, 3)
	write_win_pos(w, 2, 1002, 0, 0, 5, 3)
	write_float_pos(w, float_at(5, 1, 1, 50, 3))
	mouse_float := float_at(6, 2, 2, 50, 1)
	mouse_float.mouse = true
	write_float_pos(w, mouse_float)
	pum := float_at(7, 3, 3, 10, 9)
	pum.window = -1
	write_float_pos(w, pum)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1, 2, 4, 7, 6, 5})
	kinds := [6]neovim.Grid_Kind{.Base, .Window, .Window, .Float, .Float, .Float}
	for view, index in f.client.screen.grids {
		testing.expect_value(t, view.kind, kinds[index])
		testing.expect_value(t, len(view.cells), view.columns * view.rows)
	}
	windows := windows_of(&f.client)
	testing.expect_value(t, windows[0].window, i64(1002))
	testing.expect_value(t, windows[1].window, i64(1004))
	testing.expect_value(t, windows[1].column, 10)
	topmost, _ := view_of(&f.client, 5)
	testing.expect_value(t, topmost.zindex, 50)
	testing.expect_value(t, topmost.compindex, 3)
	testing.expect_value(t, topmost.focusable, false)
	testing.expect_value(t, topmost.row, 1)
	middle, _ := view_of(&f.client, 6)
	testing.expect_value(t, middle.focusable, true)
	below, _ := view_of(&f.client, 7)
	testing.expect_value(t, below.window, i64(-1))
	testing.expect_value(t, below.zindex, 10)
	base, _ := view_of(&f.client, 1)
	testing.expect_value(t, base.focusable, true)
	testing.expect_value(t, f.client.screen.grids[1].zindex, 0)
}

@(test)
win_pos_may_precede_its_grid_resize :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 5)
	// The event's own size is stale or bogus; only the origin counts.
	write_win_pos(w, 2, 1002, 3, 4, 99, 99)
	write_resize(w, 2, 6, 3)
	write_line_event(w, 2, 1, 0, {{"x", 1, 6}})
	write_win_pos(w, 3, 1003, 0, 0, 99, 99)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	window, ok := view_of(&f.client, 2)
	testing.expect(t, ok)
	testing.expect_value(t, window.columns, 6)
	testing.expect_value(t, window.rows, 3)
	testing.expect_value(t, window.row, 3)
	testing.expect_value(t, window.column, 4)
	testing.expect_value(t, window.cells[6], neovim.Cell{'x', 1})
	testing.expect_value(t, window.cells[0], neovim.Cell{' ', 0})
	unsized, shown := view_of(&f.client, 3)
	testing.expect(t, shown)
	testing.expect_value(t, unsized.columns, 0)
	testing.expect_value(t, unsized.rows, 0)
	testing.expect_value(t, len(unsized.cells), 0)
}

@(test)
a_placeholder_grid_is_shown_by_a_later_win_pos :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 3)
	write_resize(w, 2, 4, 2)
	write_line_event(w, 2, 0, 0, {{"p", 0, 4}})
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1})
	begin_redraw(w, 2)
	write_win_pos(w, 2, 1002, 2, 5, 4, 2)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1, 2})
	window, _ := view_of(&f.client, 2)
	testing.expect_value(t, window.cells[0].glyph, u32('p'))
	testing.expect_value(t, row_text(&f.client, 2)[5:9], "pppp")
	// A float placeholder and a message placeholder come the same way.
	begin_redraw(w, 3)
	write_resize(w, 3, 2, 1)
	write_resize(w, 4, 10, 6)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1, 2})
	begin_redraw(w, 3)
	write_float_pos(w, float_at(3, 0, 0))
	write_msg_pos(w, 4, 8, 200, 5)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1, 2, 3, 4})
}

@(test)
float_pos_is_idempotent_and_a_move_changes_the_layout :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	place := float_at(4, 2, 3, 20, 1)
	begin_redraw(w, 3)
	write_resize(w, 4, 5, 2)
	write_float_pos(w, place)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	first, _ := view_of(&f.client, 4)
	testing.expect_value(t, first.row, 2)
	testing.expect_value(t, first.column, 3)

	begin_redraw(w, 3)
	write_float_pos(w, place)
	write_float_pos(w, place)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	same, _ := view_of(&f.client, 4)
	testing.expect_value(t, same.layout, first.layout)

	// Another float opening shifts compindex; that is no move.
	place.compindex = 2
	begin_redraw(w, 2)
	write_float_pos(w, place)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	shifted, _ := view_of(&f.client, 4)
	testing.expect_value(t, shifted.compindex, 2)
	testing.expect_value(t, shifted.layout, first.layout)

	place.screen_row = 5
	begin_redraw(w, 2)
	write_float_pos(w, place)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	moved, _ := view_of(&f.client, 4)
	testing.expect_value(t, moved.row, 5)
	testing.expect(t, moved.layout != first.layout)

	// A resize resets it too.
	begin_redraw(w, 2)
	write_resize(w, 4, 6, 2)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	resized, _ := view_of(&f.client, 4)
	testing.expect(t, resized.layout != moved.layout)
}

@(test)
float_without_a_screen_position_is_anchored_by_its_corner :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 40, 20)
	begin_redraw(w, 7)
	write_resize(w, 2, 10, 5)
	write_win_pos(w, 2, 1002, 3, 4, 10, 5)
	write_resize(w, 3, 5, 2)
	write_resize(w, 4, 3, 1)
	write_float_pos(w, legacy_float(3, "SE", 1, 10, 20, 50))
	write_float_pos(w, legacy_float(4, "NE", 2, 1, 2, 60))
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	south_east, _ := view_of(&f.client, 3)
	testing.expect_value(t, south_east.row, 8)
	testing.expect_value(t, south_east.column, 15)
	north_east, _ := view_of(&f.client, 4)
	testing.expect_value(t, north_east.row, 4)
	testing.expect_value(t, north_east.column, 3)
	testing.expect_value(t, north_east.zindex, 60)
	testing.expect_value(t, north_east.compindex, 0)
	begin_redraw(w, 3)
	write_float_pos(w, legacy_float(3, "SW", 1, 10.5, 20, 50))
	write_float_pos(w, legacy_float(4, "NW", 1, 1, 2, 60))
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	south_west, _ := view_of(&f.client, 3)
	testing.expect_value(t, south_west.row, 8)
	testing.expect_value(t, south_west.column, 20)
	north_west, _ := view_of(&f.client, 4)
	testing.expect_value(t, north_west.row, 1)
	testing.expect_value(t, north_west.column, 2)
}

@(test)
msg_set_pos_ignores_grid_zero_and_clips_to_the_screen :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 10, 6)
	begin_redraw(w, 6)
	write_resize(w, 3, 10, 6)
	write_msg_pos(w, 0, 5, 200, 4)
	for letter, row in ([3]string{"m", "n", "o"}) {write_line_event(w, 3, i64(row), 0, {{letter, 1, 10}})}
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1})

	begin_redraw(w, 2)
	write_msg_pos(w, 3, 4, 200, 7)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1, 3})
	message, _ := view_of(&f.client, 3)
	testing.expect_value(t, message.kind, neovim.Grid_Kind.Message)
	testing.expect_value(t, message.row, 4)
	testing.expect_value(t, message.column, 0)
	testing.expect_value(t, message.columns, 10)
	testing.expect_value(t, message.rows, 2)
	testing.expect_value(t, len(message.cells), 20)
	testing.expect_value(t, message.zindex, 200)
	testing.expect_value(t, message.compindex, 7)
	testing.expect_value(t, message.window, i64(0))
	testing.expect_value(t, message.cells[0].glyph, u32('m'))
	testing.expect_value(t, message.cells[10].glyph, u32('n'))
	testing.expect_value(t, row_text(&f.client, 3), "          ")
	testing.expect_value(t, row_text(&f.client, 4), "mmmmmmmmmm")
	testing.expect_value(t, row_text(&f.client, 5), "nnnnnnnnnn")

	// Message rows above the screen's bottom grow back when the message moves up.
	begin_redraw(w, 2)
	write_msg_pos(w, 3, 5, 200, 7)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	lower, _ := view_of(&f.client, 3)
	testing.expect_value(t, lower.rows, 1)
	testing.expect_value(t, len(lower.cells), 10)
	testing.expect(t, lower.layout != message.layout)
}

@(test)
hide_and_show_again_restarts_the_layout :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 3)
	write_resize(w, 2, 5, 3)
	write_win_pos(w, 2, 1002, 1, 1, 5, 3)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	shown, _ := view_of(&f.client, 2)

	begin_redraw(w, 2)
	write_win_pos(w, 2, 1002, 1, 1, 5, 3)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	again, _ := view_of(&f.client, 2)
	testing.expect_value(t, again.layout, shown.layout)

	begin_redraw(w, 2)
	write_grid_ids(w, "win_hide", 2)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1})

	begin_redraw(w, 2)
	write_win_pos(w, 2, 1002, 1, 1, 5, 3)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	back, ok := view_of(&f.client, 2)
	testing.expect(t, ok)
	testing.expect(t, back.layout != shown.layout)
	testing.expect_value(t, back.cells[0].glyph, u32(' '))
}

@(test)
windows_leave_by_hide_close_destroy_and_external_pos :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 10)
	for id in ([?]i64{2, 3, 4, 5, 6}) {
		write_resize(w, id, 3, 1)
		write_win_pos(w, id, 1000 + id, i64(id), 0, 3, 1)
	}
	_ = feed(t, &f.client, w)
	begin_redraw(w, 1)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1, 2, 3, 4, 5, 6})

	begin_redraw(w, 8)
	write_grid_ids(w, "win_hide", 2)
	write_grid_ids(w, "win_close", 3)
	write_grid_ids(w, "grid_destroy", 4)
	begin_event(w, "win_external_pos", 1)
	neovim.msgpack_write_array(w, 2)
	neovim.msgpack_write_int(w, 5)
	write_window(w, 1005)
	// Events for grids that are gone, and ones Neovim has that this client does not draw.
	write_grid_ids(w, "win_close", 3, 99)
	begin_event(w, "win_extmark", 1)
	write_ints(w, 6, 1006, 1, 1, 0, 0)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1, 6})
	// An external window shown again by a win_pos keeps its cells.
	begin_redraw(w, 2)
	write_win_pos(w, 5, 1005, 0, 0, 3, 1)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	expect_ids(t, &f.client, {1, 5, 6})
}

@(test)
resizing_a_grid_keeps_the_cells_both_sizes_cover :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 6)
	write_resize(w, 2, 4, 3)
	write_win_pos(w, 2, 1002, 0, 0, 4, 3)
	for letter, row in ([3]string{"a", "b", "c"}) {write_line_event(w, 2, i64(row), 0, {{letter, 0, 4}})}
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	before, _ := view_of(&f.client, 2)

	begin_redraw(w, 2)
	write_resize(w, 2, 3, 2)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	smaller, _ := view_of(&f.client, 2)
	testing.expect_value(t, smaller.columns, 3)
	testing.expect_value(t, smaller.rows, 2)
	testing.expect_value(t, row_text(&f.client, 0)[:3], "aaa")
	testing.expect_value(t, row_text(&f.client, 1)[:3], "bbb")
	testing.expect(t, smaller.layout != before.layout)

	begin_redraw(w, 2)
	write_resize(w, 2, 5, 3)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	larger, _ := view_of(&f.client, 2)
	for column in 0 ..< 3 {testing.expect_value(t, larger.cells[column], neovim.Cell{'a', 0})}
	testing.expect_value(t, larger.cells[3], BLANK_CELL)
	testing.expect_value(t, larger.cells[4], BLANK_CELL)
	testing.expect_value(t, larger.cells[5], neovim.Cell{'b', 0})
	testing.expect_value(t, larger.cells[10], BLANK_CELL)

	// The same size again is no change.
	begin_redraw(w, 2)
	write_resize(w, 2, 5, 3)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	same, _ := view_of(&f.client, 2)
	testing.expect_value(t, same.layout, larger.layout)
}

@(test)
scroll_totals_accumulate_between_and_across_flushes :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 6)
	write_resize(w, 2, 5, 3)
	write_win_pos(w, 2, 1002, 0, 0, 5, 3)
	write_viewport(w, 2, 1002, 3)
	write_viewport(w, 2, 1002, -1)
	write_viewport(w, 7, 1007, 9)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	window, _ := view_of(&f.client, 2)
	testing.expect_value(t, window.scrolled, i64(2))
	testing.expect_value(t, f.client.screen.grids[0].scrolled, i64(0))
	begin_redraw(w, 3)
	write_viewport(w, 2, 1002, 1.6)
	write_viewport(w, 2, 1002, -0.4)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	later, _ := view_of(&f.client, 2)
	testing.expect_value(t, later.scrolled, i64(4))
	// Scrolling is no reason to restart an animation.
	testing.expect_value(t, later.layout, window.layout)
}

@(test)
margins_are_kept_when_they_arrive_before_the_grid :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 4)
	write_margins(w, 2, 1002, 1, 0, 0, 0)
	write_resize(w, 2, 5, 3)
	write_win_pos(w, 2, 1002, 0, 0, 5, 3)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	first, _ := view_of(&f.client, 2)
	testing.expect_value(t, first.margins, [4]int{1, 0, 0, 0})

	begin_redraw(w, 2)
	write_margins(w, 2, 1002, 1, 0, 0, 0)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	same, _ := view_of(&f.client, 2)
	testing.expect_value(t, same.layout, first.layout)

	begin_redraw(w, 2)
	write_margins(w, 2, 1002, 1, 2, 3, 4)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	changed, _ := view_of(&f.client, 2)
	testing.expect_value(t, changed.margins, [4]int{1, 2, 3, 4})
	testing.expect(t, changed.layout != first.layout)
}

@(test)
a_floats_blend_attribute_is_kept :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 5)
	begin_event(w, "hl_attr_define", 1)
	neovim.msgpack_write_array(w, 4)
	neovim.msgpack_write_int(w, 7)
	neovim.msgpack_write_map(w, 2)
	neovim.msgpack_write_str(w, "background")
	neovim.msgpack_write_int(w, 0x102030)
	neovim.msgpack_write_str(w, "blend")
	neovim.msgpack_write_int(w, 40)
	neovim.msgpack_write_map(w, 0)
	neovim.msgpack_write_array(w, 0)
	write_resize(w, 3, 4, 1)
	write_float_pos(w, float_at(3, 1, 1))
	write_line_event(w, 3, 0, 0, {{"f", 7, 4}})
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	float, _ := view_of(&f.client, 3)
	testing.expect_value(t, float.cells[0], neovim.Cell{'f', 7})
	testing.expect_value(t, f.client.screen.highlights[7].blend, u8(40))
	background, has_background := f.client.screen.highlights[7].background.?
	testing.expect(t, has_background)
	testing.expect_value(t, background, neovim.Color(0x102030))
}

@(test)
screen_cell_reads_the_topmost_grid :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 8, 4)
	begin_redraw(w, 7)
	write_line_event(w, 1, 3, 0, {{"b", 9, 8}})
	write_resize(w, 2, 8, 3)
	write_win_pos(w, 2, 1002, 0, 0, 8, 3)
	for row in 0 ..< 1 {write_line_event(w, 2, i64(row), 0, {{"w", 1, 8}})}
	write_resize(w, 3, 3, 2)
	write_float_pos(w, float_at(3, 1, 2, compindex = 1))
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	begin_redraw(w, 3)
	write_line_event(w, 2, 1, 0, {{"w", 1, 8}})
	write_line_event(w, 2, 2, 0, {{"w", 1, 8}})
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	begin_redraw(w, 3)
	write_line_event(w, 3, 0, 0, {{"f", 2, 3}})
	write_line_event(w, 3, 1, 0, {{"f", 2, 3}})
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	screen := &f.client.screen
	cell, ok := neovim.screen_cell(screen, 1, 2)
	testing.expect(t, ok)
	testing.expect_value(t, cell, neovim.Cell{'f', 2})
	cell, _ = neovim.screen_cell(screen, 2, 4)
	testing.expect_value(t, cell, neovim.Cell{'f', 2})
	cell, _ = neovim.screen_cell(screen, 1, 5)
	testing.expect_value(t, cell, neovim.Cell{'w', 1})
	cell, _ = neovim.screen_cell(screen, 3, 2)
	testing.expect_value(t, cell, neovim.Cell{'b', 9})
	cell, _ = neovim.screen_cell(screen, 0, 0)
	testing.expect_value(t, cell, neovim.Cell{'w', 1})
	_, ok = neovim.screen_cell(screen, 4, 0)
	testing.expect(t, !ok)
	_, ok = neovim.screen_cell(screen, 0, 8)
	testing.expect(t, !ok)
	_, ok = neovim.screen_cell(screen, -1, 0)
	testing.expect(t, !ok)
	testing.expect_value(t, row_text(&f.client, 1), "wwfffwww")
}

@(test)
the_cursor_follows_its_grids_origin :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 4)
	write_resize(w, 2, 6, 4)
	write_win_pos(w, 2, 1002, 3, 4, 6, 4)
	begin_event(w, "grid_cursor_goto", 1)
	write_ints(w, 2, 1, 2)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	screen := &f.client.screen
	testing.expect_value(t, screen.cursor_grid, 2)
	testing.expect_value(t, screen.cursor_row, 1)
	testing.expect_value(t, screen.cursor_column, 2)
	testing.expect_value(t, screen.cursor_screen_row, 4)
	testing.expect_value(t, screen.cursor_screen_column, 6)

	begin_redraw(w, 2)
	write_grid_ids(w, "win_hide", 2)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	testing.expect_value(t, screen.cursor_screen_row, -1)
	testing.expect_value(t, screen.cursor_screen_column, -1)

	begin_redraw(w, 2)
	begin_event(w, "grid_cursor_goto", 1)
	write_ints(w, 1, 5, 7)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	testing.expect_value(t, screen.cursor_grid, 1)
	testing.expect_value(t, screen.cursor_screen_row, 5)
	testing.expect_value(t, screen.cursor_screen_column, 7)
}

@(test)
steady_flushes_reuse_their_buffers :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	resize_screen(t, &f.client, w, 20, 10)
	begin_redraw(w, 3)
	write_resize(w, 2, 6, 4)
	write_win_pos(w, 2, 1002, 3, 4, 6, 4)
	write_empty_event(w, "flush")
	_ = feed(t, &f.client, w)
	screen := &f.client.screen
	grids := raw_data(screen.grids)
	base, window := raw_data(screen.grids[0].cells), raw_data(screen.grids[1].cells)
	for _ in 0 ..< 3 {
		begin_redraw(w, 2)
		write_line_event(w, 2, 0, 0, {{"s", 1, 6}})
		write_empty_event(w, "flush")
		_ = feed(t, &f.client, w)
	}
	testing.expect(t, raw_data(f.client.screen.grids) == grids, "the grids slice was reallocated")
	testing.expect(t, raw_data(f.client.screen.grids[0].cells) == base, "the pooled cells moved")
	testing.expect(t, raw_data(f.client.screen.grids[1].cells) == window, "the pooled cells moved")
	testing.expect_value(t, f.client.screen.grids[1].cells[0].glyph, u32('s'))
}

// ---- RPC -----------------------------------------------------------------------------------------

Capture :: struct {
	count: int,
	text: [512]u8,
	length: int,
}

capture_log :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	capture := (^Capture)(data)
	if level < .Error {return}
	capture.count += 1
	capture.length = copy(capture.text[:], text)
}

captured :: proc(capture: ^Capture) -> string {
	return string(capture.text[:capture.length])
}

Sent :: struct {
	reader: neovim.Msgpack_Reader,
	t: ^testing.T,
}

sent_open :: proc(t: ^testing.T, c: ^neovim.Client) -> Sent {
	return {reader = {data = c.sent.bytes[:]}, t = t}
}

sent_value :: proc(s: ^Sent) -> neovim.Msgpack_Value {
	value, error := neovim.msgpack_read(&s.reader)
	testing.expect_value(s.t, error, neovim.Msgpack_Error.None)
	return value
}

sent_array :: proc(s: ^Sent, count: int) {
	value := sent_value(s)
	testing.expect_value(s.t, value.kind, neovim.Msgpack_Kind.Array)
	testing.expect_value(s.t, value.count, count)
}

sent_int :: proc(s: ^Sent, expected: i64) {
	value := sent_value(s)
	testing.expect_value(s.t, value.kind, neovim.Msgpack_Kind.Integer)
	testing.expect_value(s.t, value.integer, expected)
}

sent_str :: proc(s: ^Sent, expected: string) {
	value := sent_value(s)
	testing.expect_value(s.t, value.kind, neovim.Msgpack_Kind.String)
	testing.expect_value(s.t, string(value.bytes), expected)
}

sent_bool :: proc(s: ^Sent, expected: bool) {
	value := sent_value(s)
	testing.expect_value(s.t, value.kind, neovim.Msgpack_Kind.Boolean)
	testing.expect_value(s.t, value.boolean, expected)
}

sent_nil :: proc(s: ^Sent) {
	testing.expect_value(s.t, sent_value(s).kind, neovim.Msgpack_Kind.Nil)
}

sent_end :: proc(s: ^Sent) {
	testing.expect_value(s.t, s.reader.offset, len(s.reader.data))
}

@(test)
requests_from_neovim_are_answered_with_an_error :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	neovim.msgpack_write_array(w, 4)
	neovim.msgpack_write_uint(w, 0)
	neovim.msgpack_write_uint(w, 70000)
	neovim.msgpack_write_str(w, "nvim_ui_foo")
	neovim.msgpack_write_array(w, 1)
	neovim.msgpack_write_str(w, "arg")
	events, error := neovim.receive(&f.client, w.bytes[:])
	testing.expect_value(t, error, neovim.Error.None)
	testing.expect_value(t, events, neovim.Poll{})
	s := sent_open(t, &f.client)
	sent_array(&s, 4)
	sent_int(&s, 1)
	sent_int(&s, 70000)
	sent_str(&s, "nvim_ui_foo is not supported by AIODev")
	sent_nil(&s)
	sent_end(&s)
}

@(test)
errors_are_logged_with_the_failing_method :: proc(t: ^testing.T) {
	capture: Capture
	context.logger = log.Logger{procedure = capture_log, data = &capture, lowest_level = .Debug}
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	testing.expect_value(t, neovim.edit(&f.client, "C:\\a b\\file.txt", 12), neovim.Error.Closed)
	s := sent_open(t, &f.client)
	sent_array(&s, 4)
	sent_int(&s, 0)
	id := sent_value(&s).integer
	sent_str(&s, "nvim_exec_lua")
	sent_array(&s, 2)
	code := sent_value(&s)
	testing.expect(t, strings.contains(string(code.bytes), "fnameescape"))
	testing.expect(t, strings.contains(string(code.bytes), "drop"))
	sent_array(&s, 2)
	sent_str(&s, "C:\\a b\\file.txt")
	sent_int(&s, 12)
	sent_end(&s)
	// A success is silent.
	neovim.msgpack_write_array(w, 4)
	neovim.msgpack_write_uint(w, 1)
	neovim.msgpack_write_int(w, id)
	neovim.msgpack_write_nil(w)
	neovim.msgpack_write_nil(w)
	_ = feed(t, &f.client, w)
	testing.expect_value(t, capture.count, 0)
	// A failure names the method and Neovim's message; the table entry is used up by the first reply.
	_ = neovim.edit(&f.client, "x", 0)
	clear(&w.bytes)
	neovim.msgpack_write_array(w, 4)
	neovim.msgpack_write_uint(w, 1)
	neovim.msgpack_write_int(w, 2)
	neovim.msgpack_write_array(w, 2)
	neovim.msgpack_write_int(w, 0)
	neovim.msgpack_write_str(w, "E37: boom")
	neovim.msgpack_write_nil(w)
	_ = feed(t, &f.client, w)
	testing.expect_value(t, capture.count, 1)
	testing.expect(t, strings.contains(captured(&capture), "nvim_exec_lua"), captured(&capture))
	testing.expect(t, strings.contains(captured(&capture), "E37: boom"), captured(&capture))
	// nvim_error_event is logged too.
	clear(&w.bytes)
	begin_notification(w, "nvim_error_event", 2)
	neovim.msgpack_write_int(w, 1)
	neovim.msgpack_write_str(w, "something broke")
	_ = feed(t, &f.client, w)
	testing.expect_value(t, capture.count, 2)
	testing.expect(t, strings.contains(captured(&capture), "something broke"), captured(&capture))
}

@(test)
malformed_input_is_a_protocol_error_and_recoverable :: proc(t: ^testing.T) {
	capture: Capture
	context.logger = log.Logger{procedure = capture_log, data = &capture, lowest_level = .Debug}
	f: Fixture
	defer fixture_destroy(&f)
	w := &f.writer
	events, error := neovim.receive(&f.client, {0x93, 0x02, 0xc1, 0x00})
	testing.expect_value(t, error, neovim.Error.Protocol)
	testing.expect_value(t, events, neovim.Poll{})
	testing.expect_value(t, capture.count, 1)
	testing.expect_value(t, len(f.client.pending), 0)
	resize_screen(t, &f.client, w, 2, 2)
	testing.expect_value(t, f.client.screen.columns, 2)
	// A non-RPC but valid msgpack object is ignored without an error.
	events, error = neovim.receive(&f.client, {0x01, 0xa1, 'x', 0x90})
	testing.expect_value(t, error, neovim.Error.None)
	testing.expect_value(t, events, neovim.Poll{})
}

@(test)
random_bytes_and_mutations_never_crash :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	writer: Writer
	defer delete(writer.bytes)
	w := &writer
	begin_redraw(w, 6)
	begin_event(w, "grid_resize", 1)
	write_ints(w, 1, 6, 3)
	write_line_event(w, 1, 0, 0, {{"abc", 1, 0}, {"e\u0301", 2, 2}, {"漢", 3, 0}, {"", 3, 0}})
	begin_event(w, "grid_scroll", 1)
	write_ints(w, 1, 0, 3, 0, 6, 1, 0)
	begin_event(w, "hl_attr_define", 1)
	neovim.msgpack_write_array(w, 4)
	neovim.msgpack_write_int(w, 2)
	neovim.msgpack_write_map(w, 2)
	neovim.msgpack_write_str(w, "foreground")
	neovim.msgpack_write_int(w, 255)
	neovim.msgpack_write_str(w, "bold")
	neovim.msgpack_write_bool(w, true)
	neovim.msgpack_write_map(w, 0)
	neovim.msgpack_write_array(w, 0)
	write_mode_change(w, "insert", 1)
	write_empty_event(w, "flush")
	seed := u64(0x9e3779b97f4a7c15)
	next :: proc(seed: ^u64) -> u64 {
		seed^ = seed^ * 6364136223846793005 + 1442695040888963407
		return seed^ >> 33
	}
	good := slice.clone(w.bytes[:])
	defer delete(good)
	// A mutation can announce a huge array that never completes; a fresh client per round keeps the
	// pending bytes (and the rescan each chunk costs) small.
	for _ in 0 ..< 3000 {
		c: neovim.Client
		mutated := slice.clone(good)
		for _ in 0 ..< 1 + int(next(&seed) % 4) {
			mutated[int(next(&seed)) % len(mutated)] = u8(next(&seed))
		}
		offset := 0
		for offset < len(mutated) {
			size := min(1 + int(next(&seed) % 37), len(mutated) - offset)
			_, _ = neovim.receive(&c, mutated[offset:offset + size])
			offset += size
		}
		delete(mutated)
		neovim.destroy(&c)
	}
	garbage: [256]u8
	for _ in 0 ..< 500 {
		c: neovim.Client
		for &b in garbage {b = u8(next(&seed))}
		_, _ = neovim.receive(&c, garbage[:])
		neovim.destroy(&c)
	}
}

// ---- outgoing requests ---------------------------------------------------------------------------

@(test)
input_is_a_notification :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, neovim.input(&f.client, "ihello<Esc>"), neovim.Error.Closed)
	s := sent_open(t, &f.client)
	sent_array(&s, 3)
	sent_int(&s, 2)
	sent_str(&s, "nvim_input")
	sent_array(&s, 1)
	sent_str(&s, "ihello<Esc>")
	sent_end(&s)
}

@(test)
input_mouse_names_button_action_and_modifiers :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	mods := bit_set[neovim.Modifier; u8]{.Shift, .Ctrl, .Alt, .Super}
	testing.expect_value(t, neovim.input_mouse(&f.client, .Left, .Press, {.Ctrl, .Shift}, 3, 4), neovim.Error.Closed)
	s := sent_open(t, &f.client)
	sent_array(&s, 3)
	sent_int(&s, 2)
	sent_str(&s, "nvim_input_mouse")
	sent_array(&s, 6)
	sent_str(&s, "left")
	sent_str(&s, "press")
	sent_str(&s, "SC")
	sent_int(&s, 0)
	sent_int(&s, 3)
	sent_int(&s, 4)
	sent_end(&s)
	_ = neovim.input_mouse(&f.client, .Wheel, .Down, mods, 10, 0)
	s = sent_open(t, &f.client)
	sent_array(&s, 3)
	sent_int(&s, 2)
	sent_str(&s, "nvim_input_mouse")
	sent_array(&s, 6)
	sent_str(&s, "wheel")
	sent_str(&s, "down")
	sent_str(&s, "SCAD")
	sent_int(&s, 0)
	sent_int(&s, 10)
	sent_int(&s, 0)
	sent_end(&s)
	_ = neovim.input_mouse(&f.client, .Move, .None, {}, 1, 2)
	s = sent_open(t, &f.client)
	sent_array(&s, 3)
	sent_int(&s, 2)
	sent_str(&s, "nvim_input_mouse")
	sent_array(&s, 6)
	sent_str(&s, "move")
	sent_str(&s, "")
	sent_str(&s, "")
}

@(test)
resize_is_skipped_when_unchanged :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	f.client.columns, f.client.rows = 40, 10
	testing.expect_value(t, neovim.resize(&f.client, 40, 10), neovim.Error.None)
	testing.expect_value(t, len(f.client.sent.bytes), 0)
	testing.expect_value(t, neovim.resize(&f.client, 50, 12), neovim.Error.Closed)
	s := sent_open(t, &f.client)
	sent_array(&s, 3)
	sent_int(&s, 2)
	sent_str(&s, "nvim_ui_try_resize")
	sent_array(&s, 2)
	sent_int(&s, 50)
	sent_int(&s, 12)
	sent_end(&s)
	// A zero-sized pane asks for the 1x1 Neovim accepts, and only once.
	testing.expect_value(t, neovim.resize(&f.client, 0, -3), neovim.Error.Closed)
	s = sent_open(t, &f.client)
	sent_array(&s, 3)
	sent_int(&s, 2)
	sent_str(&s, "nvim_ui_try_resize")
	sent_array(&s, 2)
	sent_int(&s, 1)
	sent_int(&s, 1)
}

@(test)
focus_and_paste_are_notifications :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, neovim.set_focus(&f.client, true), neovim.Error.Closed)
	s := sent_open(t, &f.client)
	sent_array(&s, 3)
	sent_int(&s, 2)
	sent_str(&s, "nvim_ui_set_focus")
	sent_array(&s, 1)
	sent_bool(&s, true)
	sent_end(&s)
	text := "line one\r\nline two \u6f22"
	testing.expect_value(t, neovim.paste(&f.client, text), neovim.Error.Closed)
	s = sent_open(t, &f.client)
	sent_array(&s, 3)
	sent_int(&s, 2)
	sent_str(&s, "nvim_paste")
	sent_array(&s, 3)
	sent_str(&s, text)
	sent_bool(&s, true)
	sent_int(&s, -1)
	sent_end(&s)
}

@(test)
zero_and_failed_clients_destroy_cleanly :: proc(t: ^testing.T) {
	zero: neovim.Client
	neovim.destroy(&zero)
	missing: neovim.Client
	error := neovim.start(&missing, {argv = {"aio-no-such-nvim-5d2f1.exe", "--embed"}, columns = 10, rows = 5}, {})
	testing.expect_value(t, error, neovim.Error.Not_Found)
	neovim.destroy(&missing)
	none: neovim.Client
	error = neovim.start(&none, {columns = 10, rows = 5}, {})
	testing.expect_value(t, error, neovim.Error.Not_Found)
	neovim.destroy(&none)
}

// ---- a real Neovim -------------------------------------------------------------------------------

wait_for :: proc(c: ^neovim.Client, check: proc(c: ^neovim.Client) -> bool) -> bool {
	began := time.tick_now()
	for time.tick_since(began) < 10 * time.Second {
		events := neovim.poll(c)
		if check(c) {return true}
		if events.exited {return check(c)}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

screen_is_ready :: proc(c: ^neovim.Client) -> bool {
	return c.screen.columns == 40 && c.screen.rows == 10 && c.screen.generation > 0
}

shows_hello :: proc(c: ^neovim.Client) -> bool {
	return screen_is_ready(c) && strings.has_prefix(row_text(c, 0), "hello")
}

buffer_is_other :: proc(c: ^neovim.Client) -> bool {
	return strings.has_suffix(c.buffer, "other.txt")
}

shows_file :: proc(c: ^neovim.Client) -> bool {
	return screen_is_ready(c) && strings.has_prefix(row_text(c, 2), "gamma") && c.screen.cursor_row == 2
}

shows_paste :: proc(c: ^neovim.Client) -> bool {
	return screen_is_ready(c) && strings.has_prefix(row_text(c, 0), "helloalphaP1") &&
		strings.has_prefix(row_text(c, 1), "P2")
}

@(test)
real_neovim_draws_edits_and_quits :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio nvim *", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	path := fmt.tprintf("%s\\notes file.txt", directory)
	if !testing.expect_value(t, os.write_entire_file(path, "alpha\nbeta\ngamma\n"), nil) {return}

	c: neovim.Client
	defer neovim.destroy(&c)
	error := neovim.start(&c, {
		argv = {"nvim", "--embed", "--clean", "-n", "-i", "NONE"},
		cwd = directory,
		columns = 40,
		rows = 10,
	}, spawn.Wake{})
	if error == .Not_Found {
		log.info("nvim is not on PATH; skipping the real Neovim test")
		return
	}
	if !testing.expect_value(t, error, neovim.Error.None) {return}
	if !testing.expect(t, wait_for(&c, screen_is_ready), "no 40x10 screen was published") {return}

	other := fmt.tprintf("%s\\other.txt", directory)
	if !testing.expect_value(t, os.write_entire_file(other, "other\n"), nil) {return}
	testing.expect_value(t, neovim.edit(&c, other, 1), neovim.Error.None)
	if !testing.expect(t, wait_for(&c, buffer_is_other), "the buffer name was not reported") {return}
	testing.expect_value(t, neovim.edit(&c, path, 3), neovim.Error.None)
	if !testing.expect(t, wait_for(&c, shows_file), "the file was not opened at line 3") {return}

	testing.expect_value(t, neovim.input(&c, "ggihello<Esc>"), neovim.Error.None)
	if !testing.expect(t, wait_for(&c, shows_hello), "typed text did not reach row 0") {return}

	testing.expect_value(t, neovim.input(&c, "A"), neovim.Error.None)
	testing.expect_value(t, neovim.paste(&c, "P1\r\nP2"), neovim.Error.None)
	testing.expect(t, wait_for(&c, shows_paste), fmt.tprintf("pasted text missing: %q / %q", row_text(&c, 0), row_text(&c, 1)))

	testing.expect_value(t, neovim.input(&c, "<Esc>:qa!<CR>"), neovim.Error.None)
	began := time.tick_now()
	exited := false
	for time.tick_since(began) < 10 * time.Second && !exited {
		exited = neovim.poll(&c).exited
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, exited, "nvim did not exit after :qa!")
	testing.expect_value(t, c.exit_code, 0)
}

wait_until :: proc(
	c: ^neovim.Client,
	data: rawptr,
	check: proc(c: ^neovim.Client, data: rawptr) -> bool,
) -> bool {
	began := time.tick_now()
	for time.tick_since(began) < 10 * time.Second {
		events := neovim.poll(c)
		if check(c, data) {return true}
		if events.exited {return check(c, data)}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

windows_of :: proc(c: ^neovim.Client) -> [dynamic]neovim.Grid_View {
	found := make([dynamic]neovim.Grid_View, context.temp_allocator)
	for view in c.screen.grids {
		if view.kind == .Window {append(&found, view)}
	}
	return found
}

start_nvim :: proc(c: ^neovim.Client, columns, rows: int) -> neovim.Error {
	return neovim.start(c, {
		argv = {"nvim", "--embed", "--clean", "-n", "-i", "NONE"},
		columns = columns,
		rows = rows,
	}, spawn.Wake{})
}

one_window_at_60x20 :: proc(c: ^neovim.Client, _: rawptr) -> bool {
	return c.screen.columns == 60 && c.screen.rows == 20 && len(windows_of(c)) == 1
}

two_windows :: proc(c: ^neovim.Client, _: rawptr) -> bool {
	return len(windows_of(c)) == 2
}

has_float :: proc(c: ^neovim.Client, _: rawptr) -> bool {
	for view in c.screen.grids {
		if view.kind == .Float {return true}
	}
	return false
}

shows_message :: proc(c: ^neovim.Client, _: rawptr) -> bool {
	return strings.has_prefix(row_text(c, 19), "msgtest")
}

nvim_exits :: proc(t: ^testing.T, c: ^neovim.Client) {
	testing.expect_value(t, neovim.input(c, "<Esc>:qa!<CR>"), neovim.Error.None)
	began := time.tick_now()
	exited := false
	for time.tick_since(began) < 10 * time.Second && !exited {
		exited = neovim.poll(c).exited
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, exited, "nvim did not exit after :qa!")
	testing.expect_value(t, c.exit_code, 0)
}

@(test)
real_neovim_shows_splits_floats_and_messages :: proc(t: ^testing.T) {
	c: neovim.Client
	defer neovim.destroy(&c)
	error := start_nvim(&c, 60, 20)
	if error == .Not_Found {
		log.info("nvim is not on PATH; skipping the real Neovim multigrid test")
		return
	}
	if !testing.expect_value(t, error, neovim.Error.None) {return}
	if !testing.expect(t, wait_until(&c, nil, one_window_at_60x20), "no window grid at 60x20") {return}

	testing.expect_value(t, neovim.input(&c, ":vsplit<CR>"), neovim.Error.None)
	if !testing.expect(t, wait_until(&c, nil, two_windows), "no second window grid") {return}
	windows := windows_of(&c)
	testing.expect_value(t, windows[0].row, windows[1].row)
	testing.expect(t, windows[0].column != windows[1].column, "the windows share a column")
	testing.expect_value(t, windows[0].rows, windows[1].rows)
	left, right := windows[0], windows[1]
	if left.column > right.column {left, right = right, left}
	// The left window ends where the separator, one column of grid 1, begins.
	testing.expect_value(t, left.column + left.columns + 1, right.column)
	testing.expect_value(t, right.column + right.columns, 60)
	testing.expect(t, left.window != right.window && left.window > 0 && right.window > 0)

	command := ":lua vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " +
		"{relative = 'editor', row = 3, col = 10, width = 20, height = 4, zindex = 50})<CR>"
	testing.expect_value(t, neovim.input(&c, command), neovim.Error.None)
	if !testing.expect(t, wait_until(&c, nil, has_float), "no float grid") {return}
	for view in c.screen.grids {
		if view.kind != .Float {continue}
		testing.expect_value(t, view.row, 3)
		testing.expect_value(t, view.column, 10)
		testing.expect_value(t, view.columns, 20)
		testing.expect_value(t, view.rows, 4)
		testing.expect_value(t, view.zindex, 50)
		testing.expect_value(t, len(view.cells), 80)
	}
	// Layers come after every window.
	layer_seen := false
	for view in c.screen.grids {
		if view.kind == .Float || view.kind == .Message {layer_seen = true}
		testing.expect(t, !(layer_seen && view.kind == .Window), "a window is drawn over a layer")
	}

	testing.expect_value(t, neovim.input(&c, "<Esc>:echo 'msgtest'<CR>"), neovim.Error.None)
	testing.expect(
		t,
		wait_until(&c, nil, shows_message),
		fmt.tprintf("message missing: %q", row_text(&c, 19)),
	)
	nvim_exits(t, &c)
}

scrolled_of_window :: proc(c: ^neovim.Client) -> i64 {
	windows := windows_of(c)
	return len(windows) == 1 ? windows[0].scrolled : -1
}

shows_first_lines :: proc(c: ^neovim.Client, _: rawptr) -> bool {
	return len(windows_of(c)) == 1 && strings.has_prefix(row_text(c, 0), "1 ") && row_text(c, 3)[0] == '4'
}

scrolled_by_one :: proc(c: ^neovim.Client, baseline: rawptr) -> bool {
	return scrolled_of_window(c) == (^i64)(baseline)^ + 1
}

@(test)
real_neovim_scroll_raises_the_windows_scrolled_total :: proc(t: ^testing.T) {
	c: neovim.Client
	defer neovim.destroy(&c)
	error := start_nvim(&c, 60, 20)
	if error == .Not_Found {
		log.info("nvim is not on PATH; skipping the real Neovim scroll test")
		return
	}
	if !testing.expect_value(t, error, neovim.Error.None) {return}
	if !testing.expect(t, wait_until(&c, nil, one_window_at_60x20), "no window grid at 60x20") {return}
	testing.expect_value(t, neovim.input(&c, ":call setline(1, range(1, 50))<CR>gg"), neovim.Error.None)
	if !testing.expect(t, wait_until(&c, nil, shows_first_lines), "the lines did not appear") {return}

	baseline := scrolled_of_window(&c)
	testing.expect_value(t, neovim.input(&c, "<C-e>"), neovim.Error.None)
	testing.expect(
		t,
		wait_until(&c, &baseline, scrolled_by_one),
		fmt.tprintf("scrolled stayed %d, wanted %d", scrolled_of_window(&c), baseline + 1),
	)
	nvim_exits(t, &c)
}

unsaved_is :: proc(c: ^neovim.Client, count: rawptr) -> bool {
	return c.unsaved == (^int)(count)^
}

asks_to_save :: proc(c: ^neovim.Client, _: rawptr) -> bool {
	for y in 0 ..< c.screen.rows {
		if strings.contains(row_text(c, y), "Save changes") {return true}
	}
	return false
}

// Closing a Neovim pane asks first when a buffer is unsaved: the client knows how many are, and
// `:confirm qa` shows Neovim's own question, reports a cancel, and quits at once with nothing unsaved.
@(test)
real_neovim_reports_unsaved_buffers_and_confirms_quit :: proc(t: ^testing.T) {
	c: neovim.Client
	defer neovim.destroy(&c)
	error := start_nvim(&c, 60, 20)
	if error == .Not_Found {
		log.info("nvim is not on PATH; skipping the real Neovim quit test")
		return
	}
	if !testing.expect_value(t, error, neovim.Error.None) {return}
	if !testing.expect(t, wait_until(&c, nil, one_window_at_60x20), "no window grid at 60x20") {return}
	one, none := 1, 0
	testing.expect_value(t, neovim.input(&c, "ihello<Esc>"), neovim.Error.None)
	if !testing.expect(t, wait_until(&c, &one, unsaved_is), "the changed buffer was not reported") {return}

	testing.expect_value(t, neovim.quit_confirm(&c), neovim.Error.None)
	if !testing.expect(t, wait_until(&c, nil, asks_to_save), "Neovim did not ask to save") {return}
	testing.expect_value(t, neovim.input(&c, "c"), neovim.Error.None)
	cancelled := false
	began := time.tick_now()
	for time.tick_since(began) < 10 * time.Second && !cancelled {
		events := neovim.poll(&c)
		if !testing.expect(t, !events.exited, "Neovim quit although the question was cancelled") {return}
		cancelled = events.quit_cancelled
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, cancelled, "the cancel was not reported")

	testing.expect_value(t, neovim.input(&c, ":set nomodified<CR>"), neovim.Error.None)
	if !testing.expectf(t, wait_until(&c, &none, unsaved_is), "the saved state was not reported: %d %q %q",
		c.unsaved, row_text(&c, 18), row_text(&c, 19)) {return}
	testing.expect_value(t, neovim.quit_confirm(&c), neovim.Error.None)
	exited := false
	began = time.tick_now()
	for time.tick_since(began) < 10 * time.Second && !exited {
		exited = neovim.poll(&c).exited
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, exited, "Neovim did not quit at once with nothing unsaved")
}

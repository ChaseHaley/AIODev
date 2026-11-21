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

row_text :: proc(c: ^neovim.Client, row: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for column in 0 ..< c.screen.columns {
		glyph := c.screen.cells[row * c.screen.columns + column].glyph
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
	testing.expect_value(t, len(screen.cells), 8)
	testing.expect_value(t, screen.cells[0], neovim.Cell{'a', 1})
	testing.expect_value(t, screen.cells[1], neovim.Cell{'b', 1})
	testing.expect_value(t, screen.cells[2], neovim.Cell{'c', 2})
	testing.expect_value(t, screen.cells[3], neovim.Cell{'c', 2})
	testing.expect_value(t, screen.cells[4], neovim.Cell{' ', 0})
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
	testing.expect_value(t, f.client.screen.cells[2].glyph, u32('x'))
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
	testing.expect_value(t, f.client.screen.cells[0].glyph, u32(' '))
	testing.expect_value(t, f.client.screen.cursor_column, 0)
	testing.expect_value(t, f.client.screen.generation, u64(1))
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.cells[0].glyph, u32('q'))
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
	row := f.client.screen.cells[8:16]
	expected := [8]neovim.Cell{
		{' ', 0}, {'x', 2}, {'x', 2}, {'x', 2}, {'y', 2}, {'z', 5}, {'w', 5}, {'w', 5},
	}
	for cell, index in expected {testing.expect_value(t, row[index], cell)}
	testing.expect_value(t, f.client.screen.cells[0], neovim.Cell{' ', 0})
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
	cells := f.client.screen.cells
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
	cells := f.client.screen.cells
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
	for cell in f.client.screen.cells {testing.expect_value(t, cell, neovim.Cell{' ', 0})}
	resize_screen(t, &f.client, w, 2, 3)
	testing.expect_value(t, f.client.screen.columns, 2)
	testing.expect_value(t, f.client.screen.rows, 3)
	testing.expect_value(t, len(f.client.screen.cells), 6)
	single(w, "grid_destroy", 1)
	_ = feed(t, &f.client, w)
	flush_screen(t, &f.client, w)
	testing.expect_value(t, f.client.screen.columns, 0)
	testing.expect_value(t, len(f.client.screen.cells), 0)
}

@(test)
other_grids_are_ignored :: proc(t: ^testing.T) {
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
	testing.expect_value(t, f.client.screen.columns, 3)
	testing.expect_value(t, row_text(&f.client, 0), "   ")
	testing.expect_value(t, f.client.screen.cursor_column, 0)
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

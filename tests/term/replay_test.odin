package term_test

import "aio:ghostty"
import "aio:term"
import "core:os"
import "core:strings"
import "core:testing"

// Replay geometry uses a nonzero cell size even though nothing is rasterized, so libghostty sees the
// same kind of grid a live pane reports.
replay_geometry :: proc(columns, rows: u16) -> term.Geometry {
	return {
		columns = columns,
		rows = rows,
		cell_width = 8,
		cell_height = 16,
		surface_width = u32(columns) * 8,
		surface_height = u32(rows) * 16,
	}
}

@(test)
capture_header_round_trip :: proc(t: ^testing.T) {
	header := term.capture_header(77, 24)
	testing.expect_value(t, len(header), term.CAPTURE_HEADER_SIZE)
	testing.expect_value(t, string(header[:len(term.CAPTURE_MAGIC)]), term.CAPTURE_MAGIC)
	// The byte positions pin the on-disk layout for any reader outside this package.
	testing.expect_value(t, header[7], u8(77))
	testing.expect_value(t, header[8], u8(0))
	testing.expect_value(t, header[9], u8(24))
	testing.expect_value(t, header[10], u8(0))
	columns, rows, ok := term.capture_geometry(header[:])
	testing.expect(t, ok)
	testing.expect_value(t, columns, 77)
	testing.expect_value(t, rows, 24)
	short := header[:term.CAPTURE_HEADER_SIZE - 1]
	_, _, short_ok := term.capture_geometry(short)
	testing.expect(t, !short_ok)
	stranger := header
	stranger[0] = 'X'
	_, _, stranger_ok := term.capture_geometry(stranger[:])
	testing.expect(t, !stranger_ok)
	empty := term.capture_header(0, 24)
	_, _, empty_ok := term.capture_geometry(empty[:])
	testing.expect(t, !empty_ok)
}

@(test)
record_writes_a_header_and_reports_bytes :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-vt-record-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/capture.bin"}, context.temp_allocator)
	defer os.remove(path)
	missing := strings.concatenate({directory, "/missing/capture.bin"}, context.temp_allocator)
	session, session_error := term.create_headless(replay_geometry(20, 3), 100)
	if !testing.expect_value(t, session_error, term.Error.None) {return}
	defer term.destroy(session)
	// A capture that cannot be created is an expected failure, not a test error.
	context.logger = {}
	testing.expect_value(t, term.record_start(session, missing), term.Record_Start_Error.File_Failed)
	testing.expect_value(t, term.record_start(session, path), term.Record_Start_Error.None)
	testing.expect_value(t, term.record_start(session, path), term.Record_Start_Error.Already_Recording)
	stopped, bytes, ok := term.record_stop(session)
	testing.expect(t, ok)
	testing.expect_value(t, stopped, path)
	testing.expect_value(t, bytes, u64(0))
	_, _, again := term.record_stop(session)
	testing.expect(t, !again)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect_value(t, read_error, nil) {return}
	testing.expect_value(t, len(data), term.CAPTURE_HEADER_SIZE)
	columns, rows, header_ok := term.capture_geometry(data)
	testing.expect(t, header_ok)
	testing.expect_value(t, columns, 20)
	testing.expect_value(t, rows, 3)
}

@(test)
replay_reproduces_screen_and_cell_attributes :: proc(t: ^testing.T) {
	geometry := replay_geometry(20, 4)
	header := term.capture_header(geometry.columns, geometry.rows)
	payload :: "hello \u6c49\r\n" + "\x1b[38;2;12;34;56;1mbold\x1b[0m plain"
	directory, directory_error := os.make_directory_temp("", "aio-vt-replay-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/capture.bin"}, context.temp_allocator)
	defer os.remove(path)
	content := strings.concatenate({string(header[:]), payload}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(path, content), nil) {return}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect_value(t, read_error, nil) {return}
	columns, rows, ok := term.capture_geometry(data)
	if !testing.expect(t, ok) {return}
	session, session_error := term.create_headless(replay_geometry(columns, rows), 100)
	if !testing.expect_value(t, session_error, term.Error.None) {return}
	defer term.destroy(session)
	term.replay_write(session, data[term.CAPTURE_HEADER_SIZE:])
	screen, snapshot_error := term.replay_snapshot(session)
	if !testing.expect_value(t, snapshot_error, term.Error.None) {return}
	defer term.snapshot_destroy(&screen)
	testing.expect_value(t, screen.columns, 20)
	testing.expect_value(t, screen.rows, 4)
	first, first_error := term.row_text(&screen, 0)
	defer delete(first)
	testing.expect_value(t, first_error, term.Error.None)
	testing.expect_value(t, first, "hello \u6c49")
	second, second_error := term.row_text(&screen, 1)
	defer delete(second)
	testing.expect_value(t, second_error, term.Error.None)
	testing.expect_value(t, second, "bold plain")
	wide := term.snapshot_cell(&screen, 6, 0)
	testing.expect_value(t, wide.text, "\u6c49")
	testing.expect_value(t, wide.width, ghostty.Cell_Wide.Wide)
	testing.expect_value(t, term.snapshot_cell(&screen, 7, 0).width, ghostty.Cell_Wide.Spacer_Tail)
	bold := term.snapshot_cell(&screen, 0, 1)
	testing.expect_value(t, bold.text, "b")
	testing.expect(t, bold.style.bold)
	testing.expect_value(t, bold.foreground, Maybe(term.Color)(term.Color{12, 34, 56}))
	plain := term.snapshot_cell(&screen, 5, 1)
	testing.expect_value(t, plain.text, "p")
	testing.expect(t, plain.foreground == nil)
	testing.expect(t, !plain.style.bold)
}

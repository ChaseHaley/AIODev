package main

import "aio:control"
import "aio:term"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"

USAGE :: `vtreplay <capture> [--screen [first:last]] [--cells <row> [first:last]]
Replays a PTY capture recorded with "vt record on" on a headless terminal and prints it.
No selector means --screen over every recorded row; ranges are inclusive and zero-based.
--screen mirrors aioctl screen and --cells mirrors aioctl cells, from the same formatters.
Output is evidence from the capture only: no shell runs and no window is touched.
Exit codes: 0 printed, 1 unreadable or invalid capture, 2 bad arguments.
`

// A capture stores raw bytes, not the window that drew them. The replay terminal therefore uses a
// neutral cell size and a scrollback deep enough that long output survives, then prints the viewport.
REPLAY_CELL_WIDTH :: 8
REPLAY_CELL_HEIGHT :: 16
REPLAY_SCROLLBACK :: 1000
REPLAY_CHUNK :: 64 * 1024

@(private)
Mode :: enum {
	Screen,
	Cells,
}

@(private)
Options :: struct {
	capture: string,
	mode:    Mode,
	rows:    control.Range,
	cells:   control.Cells,
	help:    bool,
}

main :: proc() {
	code := run(os.args[1:])
	free_all(context.temp_allocator)
	os.exit(code)
}

@(private, require_results)
run :: proc(args: []string) -> int {
	options, usage_error := parse(args)
	if usage_error != "" {
		fmt.eprintfln("error: %s", usage_error)
		fmt.eprint(USAGE)
		return 2
	}
	if options.help {
		fmt.print(USAGE)
		return 0
	}
	file, open_error := os.open(options.capture)
	if open_error != nil {
		fmt.eprintfln("error: cannot open %s (%v); check the path", options.capture, open_error)
		return 1
	}
	defer os.close(file)
	header: [term.CAPTURE_HEADER_SIZE]u8
	if !read_header(file, header[:]) {
		fmt.eprintfln("error: %s is too short to be a capture", options.capture)
		return 1
	}
	columns, rows, valid := term.capture_geometry(header[:])
	if !valid {
		fmt.eprintfln(
			"error: %s is not a capture; record one with \"vt record on\"",
			options.capture,
		)
		return 1
	}
	geometry := term.Geometry {
		columns     = columns,
		rows        = rows,
		cell_width  = REPLAY_CELL_WIDTH,
		cell_height = REPLAY_CELL_HEIGHT,
	}
	session, create_error := term.create_headless(geometry, REPLAY_SCROLLBACK)
	if create_error != .None {
		fmt.eprintfln("error: building the replay terminal failed (%v)", create_error)
		return 1
	}
	defer term.destroy(session)
	buffer: [REPLAY_CHUNK]u8
	for {
		n, read_error := os.read(file, buffer[:])
		if n > 0 {
			term.replay_write(session, buffer[:n])
		}
		if read_error != nil {
			if read_error == os.Error(io.Error.EOF) {
				break
			}
			fmt.eprintfln(
				"error: reading %s failed (%v); the capture may be cut short",
				options.capture,
				read_error,
			)
			return 1
		}
		if n == 0 {
			break
		}
	}
	snapshot, snapshot_error := term.replay_snapshot(session)
	if snapshot_error != .None {
		fmt.eprintfln("error: reading the replayed screen failed (%v)", snapshot_error)
		return 1
	}
	defer term.snapshot_destroy(&snapshot)
	out := strings.builder_make(context.temp_allocator)
	format_error: control.Error
	switch options.mode {
	case .Screen:
		if failure := screen_range_failure(options.rows, int(snapshot.rows)); failure != "" {
			return usage_failure(failure)
		}
		format_error = control.format_screen(&out, &snapshot, options.rows)
	case .Cells:
		if failure := cells_range_failure(options.cells, int(snapshot.columns), int(snapshot.rows));
		   failure != "" {
			return usage_failure(failure)
		}
		format_error = control.format_cells(&out, &snapshot, options.cells)
	}
	if format_error != .None {
		fmt.eprintfln("error: formatting the replay failed (%v)", format_error)
		return 1
	}
	fmt.print(strings.to_string(out))
	return 0
}

// read_header fills the header instead of trusting one read: a truncated capture fails here rather
// than being replayed from a partly initialised header.
@(private, require_results)
read_header :: proc(file: ^os.File, header: []u8) -> bool {
	at := 0
	for at < len(header) {
		n, err := os.read(file, header[at:])
		if err != nil || n <= 0 {
			return false
		}
		at += n
	}
	return true
}

// parse reads the same selector syntax aioctl screen and cells accept. Ranges cannot be validated
// until the capture header has sized the replay terminal, so that check waits for the snapshot.
@(private, require_results)
parse :: proc(args: []string) -> (o: Options, failure: string) {
	o.mode = .Screen
	selector := false
	for i := 0; i < len(args); {
		arg := args[i]
		switch {
		case arg == "--help" || arg == "-h":
			o.help = true
			i += 1
		case arg == "--screen":
			if selector {
				return {}, "use --screen or --cells once"
			}
			selector = true
			i += 1
			if i < len(args) && !strings.has_prefix(args[i], "--") {
				rows, ok := parse_range(args[i], true)
				if !ok {
					return {}, "use a nonnegative row or first:last after --screen"
				}
				o.rows = rows
				i += 1
			}
		case arg == "--cells":
			if selector {
				return {}, "use --screen or --cells once"
			}
			selector = true
			o.mode = .Cells
			if i + 1 >= len(args) {
				return {}, "supply a row after --cells"
			}
			row, ok := parse_number(args[i + 1])
			if !ok {
				return {}, "use a nonnegative row after --cells"
			}
			o.cells.row = row
			i += 2
			if i < len(args) && !strings.has_prefix(args[i], "--") {
				columns, columns_ok := parse_range(args[i], false)
				if !columns_ok {
					return {}, "use first:last columns after the row"
				}
				o.cells.columns = columns
				i += 1
			}
		case strings.has_prefix(arg, "--"):
			return {}, fmt.tprintf("unknown option %s; use --screen or --cells", arg)
		case o.capture == "":
			o.capture = arg
			i += 1
		case:
			return {}, fmt.tprintf("unexpected argument %s; use one capture path", arg)
		}
	}
	if o.help {
		return o, ""
	}
	if o.capture == "" {
		return {}, "supply the capture file to replay"
	}
	return o, ""
}

@(private, require_results)
parse_number :: proc(text: string) -> (int, bool) {
	if text == "" {
		return 0, false
	}
	for c in text {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	value, ok := strconv.parse_int(text)
	return value, ok && value >= 0
}

@(private, require_results)
parse_range :: proc(text: string, single: bool) -> (control.Range, bool) {
	separator := strings.index_byte(text, ':')
	if separator < 0 {
		value, ok := parse_number(text)
		return {value, value, true}, ok && single
	}
	first, first_ok := parse_number(text[:separator])
	last, last_ok := parse_number(text[separator + 1:])
	return {first, last, true}, first_ok && last_ok && first <= last
}

@(private, require_results)
screen_range_failure :: proc(rows: control.Range, count: int) -> string {
	if !rows.specified {
		return ""
	}
	if rows.first < 0 || rows.last < rows.first || rows.last >= count {
		return fmt.tprintf(
			"row range %d:%d is outside the recorded %d rows",
			rows.first,
			rows.last,
			count,
		)
	}
	return ""
}

@(private, require_results)
cells_range_failure :: proc(request: control.Cells, columns, rows: int) -> string {
	if request.row < 0 || request.row >= rows {
		return fmt.tprintf("row %d is outside the recorded %d rows", request.row, rows)
	}
	if !request.columns.specified {
		return ""
	}
	r := request.columns
	if r.first < 0 || r.last < r.first || r.last >= columns {
		return fmt.tprintf(
			"column range %d:%d is outside the recorded %d columns",
			r.first,
			r.last,
			columns,
		)
	}
	return ""
}

@(private, require_results)
usage_failure :: proc(message: string) -> int {
	fmt.eprintfln("error: %s", message)
	return 2
}

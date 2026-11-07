package verify_protocol

import "aio:commands"
import "aio:layout"
import "core:fmt"
import "core:strings"

HELP_OVERVIEW :: `aioctl <command> [arguments]
Inspect: ping, screen, cells, state, wait, expect, pixels, diff, draws, perf.
Drive: type, key, run, mouse, focus, resize, dpi, tray, command, window.
Record: vt record on|off.
Use help <command> for grammar, evidence, output, and defaults.
Coordinates and inclusive ranges are zero-based; quote each text argument in your shell.
Expect prints one PASS or FAIL line; FAIL includes observed state.
Requests use the isolated instance's local, current-user-only control pipe.
Client commands launch, doctor, and stop are documented by aioctl.
`

// The perf reply, one key=value line per counter in the order the perf help lists them. Times are
// milliseconds.
PERF_REPLY_FORMAT ::
	"frames.presented=%d\n" +
	"frames.built=%d\n" +
	"frame.build.p50=%.3f\n" +
	"frame.build.p95=%.3f\n" +
	"frame.build.max=%.3f\n" +
	"frame.render.p50=%.3f\n" +
	"frame.render.p95=%.3f\n" +
	"frame.render.max=%.3f\n" +
	"input.latency.last=%.3f\n" +
	"input.latency.p50=%.3f\n" +
	"input.latency.p95=%.3f\n" +
	"input.latency.max=%.3f\n" +
	"pty.bytes=%d\n" +
	"pty.bytes_per_second=%.3f\n" +
	"shape.calls=%d\n" +
	"glyph.hits=%d\n" +
	"glyph.misses=%d\n" +
	"idle.presents=%d\n" +
	"uptime.ms=%d\n"

@(private)
put_attribute_names :: proc(
	w: ^Writer,
	kinds: bit_set[Attribute_Kind],
	separator: string,
	width := 100,
) {
	column := 0
	if n := len(w.out.buf); n > 0 {
		start := n
		for start > 0 && w.out.buf[start - 1] != '\n' {
			start -= 1
		}
		column = n - start
	}
	first := true
	for entry in ATTRIBUTE_CATALOGUE {
		if entry.kind not_in kinds {continue}
		if !first {
			if width > 0 && column + len(separator) + len(entry.name) > width {
				trimmed := separator
				for len(trimmed) > 0 && trimmed[len(trimmed) - 1] == ' ' {
					trimmed = trimmed[:len(trimmed) - 1]
				}
				put(w, trimmed)
				put(w, "\n")
				column = 0
			} else {
				put(w, separator)
				column += len(separator)
			}
		}
		put(w, entry.name)
		column += len(entry.name)
		first = false
	}
}

@(private)
put_underline_names :: proc(w: ^Writer, include_none: bool, separator: string) {
	first := true
	for name, i in UNDERLINES {
		if i == 0 && !include_none {continue}
		if !first {put(w, separator)}
		put(w, name)
		first = false
	}
}

// The help spells the split shares literally; these keep the text in step with the declarations.
#assert(layout.SPLIT_SHARE_MIN == 0.05 && layout.SPLIT_SHARE_MAX == 0.95)

@(private)
put_direction_words :: proc(w: ^Writer) {
	for word, direction in commands.DIRECTION_WORDS {
		if direction != min(layout.Direction) {put(w, "|")}
		put(w, word)
	}
}

@(require_results)
help :: proc(out: ^strings.Builder, command: string = "") -> Error {
	w := Writer {
		out = out,
	}
	if command == "" {
		put(&w, HELP_OVERVIEW)
		return w.error
	}
	verb, known := verb_parse(command)
	if !known {return .Invalid_Argument}
	switch verb {
	case .Ping:
		put(
			&w,
			`ping
Proves the instance can answer on its main thread. Output is one line:
pid=<pid> app=<app id> build=<build id> data=<dir|default> settings=<path> log=<path>
No arguments or defaults.
`,
		)
	case .Screen:
		put(
			&w,
			`screen [<first>[:<last>]]
Reads the focused pane's visible terminal text; defaults to all rows. Ranges are inclusive.
Header: screen <cols>x<rows> cursor <col>,<row> [hidden] [blinking], or cursor off-screen.
Rows: right-aligned row number followed by |text; trailing spaces omitted.
Consecutive empty rows collapse: 3-31 blank (one empty row: 3 blank).
Example: 1|hi
Out-of-grid ranges fail; this reads terminal state, not rendered pixels.
`,
		)
	case .Cells:
		put(
			&w,
			`cells <row> [<first>:<last>]
Proves exact text and attributes in a visible row of the focused pane. Defaults to all columns; ranges inclusive.
Header: row <row> cols <first>-<last>. Each following line is a maximal attribute run.
Example: 5-9 "world" fg=#ff0000 bold underline=curly
Text escapes quotes and backslashes, and controls as \xNN. Wide spacers add no text.
Attributes, in order: `,
		)
		put_attribute_names(&w, ~{.Text}, ", ")
		put(&w, `. Only nondefaults appear; colors are resolved #rrggbb.
Underline values: `)
		put_underline_names(&w, false, ", ")
		put(
			&w,
			`. Default trailing blanks: 12-119 blank.
Out-of-grid rows or columns fail.
`,
		)
	case .State:
		put(
			&w,
			`state
Reads app-supplied state entries, including dotted keys such as palette.open and viewport.
Output is one key=value per line; values with spaces or quotes are quoted and escaped.
Example: palette.open=false
Tab selection is one-based; pane IDs are stable within each tab. tabs.selected=0 means no tabs.
Tabs: tabs.count/selected, tab.N.id/focus/panes, tab.N.pane.ID.session/grid.
Windows: windows.count, window.id/workspace_index, window.N.id/origin/size/workspace_index.
Window inventory and workspace indexes are one-based; zero means no selected window/workspace.
Origins are client pixel origins in signed screen coordinates; sizes are client pixels.
State and commands use the selected verification window, otherwise the focused window.
Visible panes: panes.count/focused, pane.ID.rect=x,y,width,height in client pixels.
Focused session: session.id/status/exit/message/title; session.ID.builds counts glyph builds.
Hidden tabs retain their sessions and last grid size; only visible panes have current rectangles.
No arguments or defaults. Available keys come from the app; screen/cells inspect the focused pane.
`,
		)
	case .Wait:
		put(&w, `wait text <s> | gone <s> | idle [<ms>] | frame [--timeout <ms>]
Every form accepts --timeout; default `)
		integer(&w, WAIT_TIMEOUT_MS)
		put(&w, ` ms. Idle defaults to `)
		integer(&w, IDLE_MS)
		put(
			&w,
			` ms without terminal activity.
Text/gone wait for row-text presence/absence; frame waits for a subsequent presented frame.
Keeps the request pending without blocking the app's main loop. Timeout fails with observed state.
Output is one PASS or FAIL line with elapsed time; failures include observed state.
Examples: PASS wait idle 300ms after 840ms
FAIL wait text "done": timeout after 5000ms; last rows: 1|hi 2|PS C:\>
Milliseconds are nonnegative integers, at most `,
		)
		integer(&w, MAX_NUMBER)
		put(&w, ".\n")
	case .Expect:
		put(
			&w,
			`expect text <s> | no-text <s> | cursor <col>,<row>
expect cell <col>,<row> <attr>=<value>...
expect state <key>=<value>
Proves terminal or app state now; no waiting or defaults. Exactly one PASS or FAIL line.
Text searches each trimmed row independently; reported positions are terminal columns, not bytes.
Cell attributes: `,
		)
		put_attribute_names(&w, {.Text}, "")
		put(&w, `=<s>, `)
		put_attribute_names(&w, {.Color}, "/")
		put(&w, `=default|#rrggbb,
`)
		put_attribute_names(&w, {.Underline}, "")
		put(&w, `=`)
		put_underline_names(&w, true, "|")
		put(&w, `, and true|false for
`)
		put_attribute_names(&w, {.Flag}, ", ")
		put(
			&w,
			`.
State compares a supplied key and value exactly; a missing key fails.
Example: PASS cell 0,1 "X" underline=single
Failure includes expected and observed values plus cell content, cursor, or recent rows.
`,
		)
	case .Type:
		put(
			&w,
			`type <text>
Sends one text argument through text input; it does not interpret key names or press Enter.
Proves text-input behavior. Output is one line: ok; <changes>. Failures start with error:.
Example: ok; rows 1-2 changed
No defaults; the empty string is allowed. Use key for shortcuts, run for a shell line.
`,
		)
	case .Key:
		put(
			&w,
			`key <chord> [<chord>...]
Sends keys in order through the app input path using the settings shortcut parser.
Example input: key Ctrl+Shift+P Esc. Output is one line: ok; <changes>. Failures start with error:.
Example: ok; rows 1-2 changed; palette open "rel" app.reload_settings
Modifiers: Ctrl, Shift, Alt, Win; key names match settings. No defaults.
Key names address physical positions. Physical+ and Leader+ are binding metadata, not driver modifiers.
This proves app input handling; it does not test Win32 keyboard-message translation.
`,
		)
	case .Run:
		put(&w, `run <line> [--idle <ms>] [--timeout <ms>]
Types a shell line, presses Enter, then waits for terminal idle.
Defaults: --idle `)
		integer(&w, IDLE_MS)
		put(&w, ", --timeout ")
		integer(&w, RUN_TIMEOUT_MS)
		put(&w, " milliseconds; nonnegative, at most ")
		integer(&w, MAX_NUMBER)
		put(
			&w,
			`.
Proves the input-to-terminal path, not shell success. Use expect to check the result.
Output starts with ok; <changes>, followed by the last three non-blank rows. Failures start with error:.
Example: ok; rows 1-2 changed
1|hi
`,
		)
	case .Mouse:
		put(
			&w,
			`mouse move|down|up|click <pos> [options]
mouse drag <pos> <pos> [options]
mouse wheel <pos> <lines> [options]
Options: --button left|right|middle (default left), --mods Ctrl+Shift (default none), --px or --screen.
Positions are nonnegative col,row cell centers; --px uses x,y pixels instead.
--screen uses signed 32-bit screen pixels, converted to the selected source window's client coordinates.
Wheel lines are signed 32-bit integers; negative scrolls down. Drag uses start and end positions.
Proves the app's mouse path without moving the desktop pointer or taking focus.
Output is one line: ok; <changes>, e.g. ok; no visible change. Failures start with error:.
Options may appear in any order after positions.
`,
		)
	case .Capture:
		put(
			&w,
			`capture [--cell <c,r[,w,h]> | --region <x,y,w,h>] [--out <file.png>]
Renders the selected window's last built frame to an offscreen surface and writes a PNG.
Defaults to the whole client area; --cell addresses columns and rows of the focused pane.
--region uses client pixels with a positive size.
--out defaults to <data>\captures\capture.png.
Output: ok; capture <path> <width>x<height>
Proves rasterization, blending, and pixel-grid alignment at the current DPI. It does not capture
OS composition such as the frame color or shadow; use win32.ps1 -Shot for those.
`,
		)
	case .Pixels:
		put(
			&w,
			`pixels [--cell | --region] [--rows | --columns] [--sample x,y]
Reads pixels from the same offscreen render as capture, without writing a file.
--rows (default) prints one line per row: <n> coverage=<0..1> colors=<n> color=#rrggbbaa.
Coverage is the share of the dominant color; colors is the distinct color count.
--columns prints columns instead. --sample prints one pixel: sample <x>,<y> #rrggbbaa,
where x,y are relative to the resolved region. Use --sample for exact colors; use profiles for
alignment and unintended-change checks.
`,
		)
	case .Diff:
		put(
			&w,
			`diff <baseline.png>
Captures the selected window and compares it with an earlier capture.
Output: diff changed=<n> boxes=<x,y,w,h>[;...] with at most eight row bands, or diff unchanged.
Fails when the baseline is missing, is not a PNG, or has a different size.
Proves visual locality: only the intended cells changed.
`,
		)
	case .Draws:
		put(
			&w,
			`draws [--region <x,y,w,h>] [--kind rect|glyph]
Lists the selected window's last built frame in draw order.
Without --region it prints summaries only:
draws layers=<n> rects=<n> glyphs=<n> [images=<n>]
layer <i> clip=<x,y,w,h> rects=<n> glyphs=<n> [images=<n>]
With --region it lists intersecting instances:
rect <i> <x,y> <w>x<h> <#rrggbbaa> radius=<r>
glyph <i> <x,y> <w>x<h> <#rrggbbaa> flags=<n>
image <i> <x,y> <w>x<h>, only without --kind
--kind limits instance lines to rect or glyph. Coordinates are client pixels.
`,
		)
	case .Perf:
		put(
			&w,
			`perf [--reset]
Reads process-local build counters and frame timing as key=value lines:
frames.presented, frames.built, frame.build.p50/p95/max, frame.render.p50/p95/max,
input.latency.last/p50/p95/max, pty.bytes, pty.bytes_per_second, shape.calls,
glyph.hits, glyph.misses, idle.presents, uptime.ms.
--reset clears the counters after printing. Times are milliseconds.
These are diagnostics for a candidate, not a benchmark receipt; use the TermBench recipe for
performance gates.
`,
		)
	case .Vt:
		put(
			&w,
			`vt record on|off
Starts or stops recording the focused session's raw PTY output.
Output on: ok; recording <path>
Output off: ok; stopped <path> bytes=<n>, or an error naming the path and bytes kept when a
disk error ended the capture early.
The capture is written under the instance data directory and is not committed.
Feed it to tools\vtreplay to reproduce screen and cell state without a shell.
`,
		)
	case .Window:
		put(
			&w,
			`window select <id>
window move <signed-x>,<signed-y>
Select a persistent verification target from state's window.N.id, without changing OS focus.
Reads and subsequent commands use this window until another is selected or it is destroyed.
On destruction, clear the target and fall back to the focused or first remaining window.
Move positions the selected window's outer top-left in screen pixels without activating it.
Coordinates are signed 32-bit integers; quote x,y in PowerShell. Unknown window IDs fail.
Output is one line: ok; <changes>. No defaults.
`,
		)
	case .Focus:
		put(
			&w,
			`focus in|out
Injects focus state through the app event path, proving focus reporting and visual state handling.
Output is one line: ok; <changes>, e.g. ok; no visible change. Failures start with error:.
No defaults; does not activate an OS window.
`,
		)
	case .Resize:
		put(&w, `resize <cols>x<rows>
Resizes the real window on the main thread, proving the normal terminal resize path.
Both dimensions must be 1..`)
		integer(&w, MAX_GRID_DIMENSION)
		put(
			&w,
			`; no defaults.
Output is one line: ok; <changes>, e.g. ok; rows 1-2 changed. Failures start with error:.
`,
		)
	case .Dpi:
		put(&w, `dpi <dpi>
Requests a translated DPI change; proves app layout/rasterization handling, not OS monitor delivery.
Range `)
		integer(&w, MIN_DPI)
		put(&w, "..")
		integer(&w, MAX_DPI)
		put(
			&w,
			`; no default.
Output is one line: ok; <changes>, e.g. ok; no visible change. Failures start with error:.
`,
		)
	case .Tray:
		put(
			&w,
			`tray open|hide|quit
Runs tray actions through the app's normal path; quit fully exits and stops managed processes.
No defaults. Output is one line: ok; <changes>, e.g. ok; no visible change. Failures start with error:.
`,
		)
	case .Command:
		put(&w, `command <command name> [pane.split options]
pane.split accepts --direction `)
		put_direction_words(&w)
		put(&w, ", --ratio 0.05..0.95 (new pane's share),\nand --focus true|false. Defaults: ")
		put(&w, commands.DIRECTION_WORDS[commands.SPLIT_DEFAULT.direction])
		buffer: [32]u8
		put(&w, fmt.bprintf(buffer[:], ", %v", commands.SPLIT_DEFAULT.ratio))
		put(&w, commands.SPLIT_DEFAULT.focus ? ", true" : ", false")
		put(
			&w,
			`. Other commands accept no options.
Invokes a registered palette command by stable name, e.g. command app.reload_settings.
Proves command dispatch. Output is one line: ok; <changes>. Failures start with error:.
Example: ok; rows 1-2 changed; palette open "rel" app.reload_settings
No defaults. Unknown or unavailable commands fail with an explanation from the app.
`,
		)
	case .Help:
		put(
			&w,
			"help [command]\nShows grammar, evidence, output, and defaults. Default: command overview.\n",
		)
	}
	return w.error
}

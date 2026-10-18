package control

import "core:strings"

HELP_OVERVIEW :: `aioctl <command> [arguments]
Inspect: ping, screen, cells, state, wait, expect.
Drive: type, key, run, mouse, focus, resize, dpi, tray, command.
Use help <command> for grammar, evidence, output, and defaults.
Coordinates and inclusive ranges are zero-based; quote each text argument in your shell.
Expect prints one PASS or FAIL line; FAIL includes observed state.
Requests use the isolated instance's local, current-user-only control pipe.
Client commands launch, doctor, and stop are documented by aioctl.
`

@(require_results)
help :: proc(out: ^strings.Builder, command: string = "") -> Error {
	w := Writer{out = out}
	switch command {
	case "":
		put(&w, HELP_OVERVIEW)
	case "ping":
		put(&w, `ping
Proves the instance can answer on its main thread. Output is one line:
pid=<pid> app=<app id> build=<build id> data=<dir|default> settings=<path> log=<path>
No arguments or defaults.
`)
	case "screen":
		put(&w, `screen [<first>[:<last>]]
Reads the focused pane's visible terminal text; defaults to all rows. Ranges are inclusive.
Header: screen <cols>x<rows> cursor <col>,<row> [hidden] [blinking], or cursor off-screen.
Rows: right-aligned row number followed by |text; trailing spaces omitted.
Consecutive empty rows collapse: 3-31 blank (one empty row: 3 blank).
Example: 1|hi
Out-of-grid ranges fail; this reads terminal state, not rendered pixels.
`)
	case "cells":
		put(&w, `cells <row> [<first>:<last>]
Proves exact text and attributes in a visible row of the focused pane. Defaults to all columns; ranges inclusive.
Header: row <row> cols <first>-<last>. Each following line is a maximal attribute run.
Example: 5-9 "world" fg=#ff0000 bold underline=curly
Text escapes quotes and backslashes, and controls as \xNN. Wide spacers add no text.
Attributes, in order: fg, bg, bold, italic, faint, blink, inverse, invisible, strike, overline,
underline, underline-color, selected, wide. Only nondefaults appear; colors are resolved #rrggbb.
Underline values: single, double, curly, dotted, dashed. Default trailing blanks: 12-119 blank.
Out-of-grid rows or columns fail.
`)
	case "state":
		put(&w, `state
Reads app-supplied state entries, including dotted keys such as palette.open and viewport.
Output is one key=value per line; values with spaces or quotes are quoted and escaped.
Example: palette.open=false
Tab selection is one-based; pane IDs are stable within each tab. tabs.selected=0 means no tabs.
Tabs: tabs.count/selected, tab.N.id/focus/panes, tab.N.pane.ID.session/grid.
Visible panes: panes.count/focused, pane.ID.rect=x,y,width,height in client pixels.
Focused session: session.id/status/exit/message/title; session.ID.builds counts glyph builds.
Hidden tabs retain their sessions and last grid size; only visible panes have current rectangles.
No arguments or defaults. Available keys come from the app; screen/cells inspect the focused pane.
`)
	case "wait":
		put(&w, `wait text <s> | gone <s> | idle [<ms>] | frame [--timeout <ms>]
Every form accepts --timeout; default 5000 ms. Idle defaults to 300 ms without terminal activity.
Text/gone wait for row-text presence/absence; frame waits for a subsequent presented frame.
Keeps the request pending without blocking the app's main loop. Timeout fails with observed state.
Output is one PASS or FAIL line with elapsed time; failures include observed state.
Examples: PASS wait idle 300ms after 840ms
FAIL wait text "done": timeout after 5000ms; last rows: 1|hi 2|PS C:\>
Milliseconds are nonnegative integers, at most 2147483647.
`)
	case "expect":
		put(&w, `expect text <s> | no-text <s> | cursor <col>,<row>
expect cell <col>,<row> <attr>=<value>...
expect state <key>=<value>
Proves terminal or app state now; no waiting or defaults. Exactly one PASS or FAIL line.
Text searches each trimmed row independently; reported positions are terminal columns, not bytes.
Cell attributes: text=<s>, fg/bg/underline-color=default|#rrggbb,
underline=none|single|double|curly|dotted|dashed, and true|false for
bold, italic, faint, blink, inverse, invisible, strike, overline, selected, wide.
State compares a supplied key and value exactly; a missing key fails.
Example: PASS cell 0,1 "X" underline=single
Failure includes expected and observed values plus cell content, cursor, or recent rows.
`)
	case "type":
		put(&w, `type <text>
Sends one text argument through text input; it does not interpret key names or press Enter.
Proves text-input behavior. Output is one line: ok; <changes>. Failures start with error:.
Example: ok; rows 1-2 changed
No defaults; the empty string is allowed. Use key for shortcuts, run for a shell line.
`)
	case "key":
		put(&w, `key <chord> [<chord>...]
Sends keys in order through the app input path using the settings shortcut parser.
Example input: key Ctrl+Shift+P Esc. Output is one line: ok; <changes>. Failures start with error:.
Example: ok; rows 1-2 changed; palette open "rel" app.reload_settings
Modifiers: Ctrl, Shift, Alt, Win; key names match settings. No defaults.
This proves app input handling; it does not test Win32 keyboard-message translation.
`)
	case "run":
		put(&w, `run <line> [--idle <ms>] [--timeout <ms>]
Types a shell line, presses Enter, then waits for terminal idle.
Defaults: --idle 300, --timeout 10000 milliseconds; nonnegative, at most 2147483647.
Proves the input-to-terminal path, not shell success. Use expect to check the result.
Output starts with ok; <changes>, followed by the last three non-blank rows. Failures start with error:.
Example: ok; rows 1-2 changed
1|hi
`)
	case "mouse":
		put(&w, `mouse move|down|up|click <pos> [options]
mouse drag <pos> <pos> [options]
mouse wheel <pos> <lines> [options]
Options: --button left|right|middle (default left), --mods Ctrl+Shift (default none), --px.
Positions are nonnegative col,row cell centers; --px uses x,y pixels instead.
Wheel lines are signed 32-bit integers; negative scrolls down. Drag uses start and end positions.
Proves the app's mouse path without moving the desktop pointer or taking focus.
Output is one line: ok; <changes>, e.g. ok; no visible change. Failures start with error:.
Options may appear in any order after positions.
`)
	case "focus":
		put(&w, `focus in|out
Injects focus state through the app event path, proving focus reporting and visual state handling.
Output is one line: ok; <changes>, e.g. ok; no visible change. Failures start with error:.
No defaults; does not activate an OS window.
`)
	case "resize":
		put(&w, `resize <cols>x<rows>
Resizes the real window on the main thread, proving the normal terminal resize path.
Both dimensions must be 1..1000; no defaults.
Output is one line: ok; <changes>, e.g. ok; rows 1-2 changed. Failures start with error:.
`)
	case "dpi":
		put(&w, `dpi <dpi>
Requests a translated DPI change; proves app layout/rasterization handling, not OS monitor delivery.
Range 48..768; no default.
Output is one line: ok; <changes>, e.g. ok; no visible change. Failures start with error:.
`)
	case "tray":
		put(&w, `tray open|hide|quit
Runs tray actions through the app's normal path; quit fully exits and stops managed processes.
No defaults. Output is one line: ok; <changes>, e.g. ok; no visible change. Failures start with error:.
`)
	case "command":
		put(&w, `command <command name> [pane.split options]
pane.split accepts --direction left|right|up|down, --ratio 0.05..0.95 (new pane's share),
and --focus true|false. Defaults: right, 0.5, true. Other commands accept no options.
Invokes a registered palette command by stable name, e.g. command app.reload_settings.
Proves command dispatch. Output is one line: ok; <changes>. Failures start with error:.
Example: ok; rows 1-2 changed; palette open "rel" app.reload_settings
No defaults. Unknown or unavailable commands fail with an explanation from the app.
`)
	case "help":
		put(&w, "help [command]\nShows grammar, evidence, output, and defaults. Default: command overview.\n")
	case:
		return .Invalid_Argument
	}
	return w.error
}

package cli_protocol

import "aio:control"
import "core:fmt"

// The aio command line's wire contract with AIODev, shared by the aio client and the app's CLI pipe
// server (D-046). A request is a JSON string array: the caller pane id or "", the reply format word,
// aio's working directory or "", then the command name and its arguments. The reply's status is the
// CLI exit status.

// Shared invocation outcomes; the values are the CLI exit codes (D-046).
Status :: enum u8 {
	Ok          = 0,
	Failed      = 1,
	Usage       = 2,
	Target      = 3,
	Unreachable = 4,
	// The pipe answered, but its server process was not the expected AIODev.
	Impostor    = 5,
	Interrupted = 130,
}

Format :: enum u8 {
	Text,
	Json,
}

@(rodata)
FORMAT_WORDS := [Format]string {
	.Text = "text",
	.Json = "json",
}

// The caller, format and directory words that precede the command.
HEADER_LENGTH :: 3

// The command whose reply is AIODev's command catalogue; aio's `commands` and `help` ask it.
CATALOGUE_COMMAND :: "app.commands"
// The commands `aio wait` polls: a pane's status when waiting for its exit, its screen otherwise.
PANE_STATUS_COMMAND :: "pane.status"
PANE_READ_COMMAND :: "pane.read"
// The command whose reply is AIODev's build line; aio's `version` asks it, and aio asks it before
// each command to warn when the two builds differ.
VERSION_COMMAND :: "app.version"
APP_NAME :: "AIODev"

// The build every executable embeds. build.ps1 passes the same values to the app and to aio in one
// build run, so the two report the same build exactly when they came from it. A direct odin build,
// such as a test run, is an unknown development build.
BUILD_ID :: #config(AIO_BUILD_ID, "unknown")
BUILD_KIND :: #config(AIO_BUILD_KIND, "development")
// The release version, such as 0.10.0, of a build made from a clean checkout of its release tag; ""
// for any other build.
BUILD_VERSION :: #config(AIO_BUILD_VERSION, "")

// A build as `aio version` names it: `0.10.0 (4dc71c8, release)`, or `dev (510462e+dirty, verify)`
// for a build without a release version.
@(require_results)
build_text :: proc(version, id, kind: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s (%s, %s)", version != "" ? version : "dev", id, kind, allocator = allocator)
}

Request :: struct {
	// The pane aio runs in, or "" outside AIODev.
	caller:    string,
	format:    Format,
	// aio's working directory, against which AIODev resolves relative path arguments; "" leaves
	// them as given.
	directory: string,
	// The command name and its arguments.
	command:   []string,
}

// The pipe arguments for a request. The slice is allocated; its strings borrow from the request.
@(require_results)
request_encode :: proc(request: Request, allocator := context.allocator) -> []string {
	args := make([dynamic]string, 0, HEADER_LENGTH + len(request.command), allocator)
	append(&args, request.caller, FORMAT_WORDS[request.format], request.directory)
	append(&args, ..request.command)
	return args[:]
}

// Reads the header of the pipe arguments. False when the header is missing or names an unknown
// format, or no command follows it. Strings borrow from args.
@(require_results)
request_decode :: proc(args: []string) -> (Request, bool) {
	if len(args) <= HEADER_LENGTH {return {}, false}
	for word, format in FORMAT_WORDS {
		if args[1] != word {continue}
		request := Request {
			caller    = args[0],
			format    = format,
			directory = args[2],
			command   = args[HEADER_LENGTH:],
		}
		return request, true
	}
	return {}, false
}

// The reply to a request: ok exactly when the status is Ok.
@(require_results)
response :: proc(status: Status, text: string) -> control.Response {
	return {ok = status == .Ok, text = text, status = u8(status)}
}

// The exit status a reply carries. A reply without one maps ok to Ok and anything else to Failed.
@(require_results)
response_status :: proc(r: control.Response) -> Status {
	if r.status != 0 {return Status(r.status)}
	return r.ok ? .Ok : .Failed
}

// How a pane's program stands, as the CLI reports it. Closed is a pane closed while its program
// still ran; aio wait --exit prints it in place of an exit code.
Pane_Status :: enum {
	Running,
	Exited,
	Failed,
	Closed,
}

@(rodata)
PANE_STATUS_WORDS := [Pane_Status]string {
	.Running = "running",
	.Exited  = "exited",
	.Failed  = "failed",
	.Closed  = "closed",
}

@(require_results)
pane_status_parse :: proc(word: string) -> (Pane_Status, bool) {
	for status_word, status in PANE_STATUS_WORDS {
		if status_word == word {return status, true}
	}
	return {}, false
}

// One terminal pane as the CLI reports it. Strings are temporary. A JSON reply leaves out empty
// strings and absent values.
Pane_Report :: struct {
	id:             u32,
	name:           string `json:"name,omitempty"`,
	title:          string `json:"title,omitempty"`,
	// The running program the pane's icon names, else the shell itself at its prompt.
	process:        string `json:"process,omitempty"`,
	workspace:      u32,
	workspace_name: string `json:"workspace_name,omitempty"`,
	// The tab's position in its workspace, from 1.
	tab:            int,
	// Whether a window shows this pane focused and that window has keyboard focus.
	focused:        bool,
	// A PANE_STATUS_WORDS word.
	status:         string,
	exit_code:      u32,
	directory:      string `json:"directory,omitempty"`,
	// The process `process` names.
	pid:            Maybe(u32) `json:"pid,omitempty"`,
	// What the tab strip calls the pane's tab.
	tab_name:       string `json:"tab_name,omitempty"`,
	// Where the tab's split arrangement puts the pane; absent while no window shows its workspace or
	// the pane is in a linked window.
	rect:           Maybe(Rect) `json:"rect,omitempty"`,
	// The terminal's size in cells; absent once the pane has closed.
	grid:           Maybe(Grid) `json:"grid,omitempty"`,
}

// A pane's place in DIPs from the top left of its window's pane area, as the split view lays out its
// tab; zoom and fill do not change it, and a floating pane keeps its own place.
Rect :: struct {
	x, y, width, height: int,
}

Grid :: struct {
	columns, rows: u16,
}

// One tab as the CLI reports it. Strings are temporary.
Tab_Report :: struct {
	workspace:      u32,
	workspace_name: string `json:"workspace_name,omitempty"`,
	// The tab's position in its workspace, from 1, as Pane_Report.tab counts.
	tab:            int,
	// What the tab strip calls it.
	name:           string `json:"name,omitempty"`,
	// Every pane in the tab, Markdown and settings panes included.
	panes:          int,
	// Whether it is the tab its workspace shows.
	selected:       bool,
	// Whether it is selected in a window that has keyboard focus.
	focused:        bool,
}

// One workspace as the CLI reports it. Strings are temporary.
Workspace_Report :: struct {
	id:      u32,
	name:    string `json:"name,omitempty"`,
	// Whether a window shows the workspace, and whether that window is on screen and not minimized.
	window:  bool,
	visible: bool,
	tabs:    int,
	// Whether its window has keyboard focus.
	focused: bool,
}

Command_Report :: struct {
	name, title, usage: string,
}

// The reply document of a json-format request. aio reads the same shape back. Every reply carries
// ok and status; the other fields appear only when the command filled them.
Reply_Json :: struct {
	ok:         bool,
	status:     u8,
	error:      string `json:"error,omitempty"`,
	pane:       Maybe(u32) `json:"pane,omitempty"`,
	text:       string `json:"text,omitempty"`,
	panes:      []Pane_Report `json:"panes,omitempty"`,
	commands:   []Command_Report `json:"commands,omitempty"`,
	tabs:       []Tab_Report `json:"tabs,omitempty"`,
	workspaces: []Workspace_Report `json:"workspaces,omitempty"`,
}

package term_test

import "core:sync"
import "core:testing"
import "aio:ghostty"
import "aio:platform"
import "aio:term"

// Terminal output can rename the window, attach a hyperlink to a cell, ring the bell and ask for a
// clipboard write or read. Only the clipboard requests have a host effect, so the oracle below
// requires the in-terminal effects to be observable while the host stays untouched.
HOST_EFFECTS_CHILD :: "pwsh.exe -NoLogo -NoProfile -File \"" + #directory + "/host_effects_output.ps1\""
HOST_EFFECTS_TITLE :: "AIO_HOST_EFFECTS"
HOST_EFFECTS_URI :: "https://example.invalid/aio-host-effects"
HOST_EFFECTS_PAYLOAD :: "AIO_HOST_EFFECTS"
HOST_EFFECTS_TEXT_LIMIT :: 256

// The clipboard callbacks are absent from aio:ghostty because no production code registers them.
// These layouts mirror vendor/ghostty/include/ghostty/vt/terminal.h so the probe can record a
// request without owning any part of it.
Ghostty_Clipboard_Content :: struct {
	mime: ghostty.String,
	data: ghostty.String,
}

Ghostty_Clipboard_Write :: struct {
	size:         uint,
	location:     i32,
	contents:     [^]Ghostty_Clipboard_Content,
	contents_len: uint,
	name:         ghostty.String,
	granted:      bool,
	can_remember: bool,
	ctx:          rawptr,
	// GhosttyClipboardWriteReplyFn. Deliberately never called.
	reply:        rawptr,
}

Ghostty_Clipboard_Read :: struct {
	size:         uint,
	location:     i32,
	mimes:        [^]ghostty.String,
	mimes_len:    uint,
	list:         bool,
	name:         ghostty.String,
	granted:      bool,
	can_remember: bool,
	ctx:          rawptr,
	// GhosttyClipboardReadReplyFn. Deliberately never called.
	reply:        rawptr,
}

#assert(size_of(Ghostty_Clipboard_Content) == 32)
#assert(size_of(Ghostty_Clipboard_Write) == 72)
#assert(size_of(Ghostty_Clipboard_Read) == 80)
#assert(offset_of(Ghostty_Clipboard_Write, contents) == 16)
#assert(offset_of(Ghostty_Clipboard_Write, reply) == 64)
#assert(offset_of(Ghostty_Clipboard_Read, mimes) == 16)
#assert(offset_of(Ghostty_Clipboard_Read, list) == 32)
#assert(offset_of(Ghostty_Clipboard_Read, reply) == 72)

foreign import user32 "system:user32.lib"

// The only clipboard API this test may call. It reports whether the clipboard changed, and never
// reads, writes or clears its contents.
@(default_calling_convention = "system")
foreign user32 {
	GetClipboardSequenceNumber :: proc() -> u32 ---
}

Ghostty_Terminal_Clipboard_Write_Fn :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	write: ^Ghostty_Clipboard_Write,
)

Ghostty_Terminal_Clipboard_Read_Fn :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	read: ^Ghostty_Clipboard_Read,
)

// Counters a registered probe records. Terminal output only reaches the host when an embedder
// consumer exists, so a probe that fires is the mutation the oracle must detect.
Host_Effects :: struct {
	writes:      int,
	reads:       int,
	payload_len: int,
	payload:     [HOST_EFFECTS_TEXT_LIMIT]u8,
}

Host_Observation :: struct {
	title:                [HOST_EFFECTS_TEXT_LIMIT]u8,
	title_len:            int,
	title_changed:        bool,
	hyperlink:            [HOST_EFFECTS_TEXT_LIMIT]u8,
	hyperlink_len:        int,
	hyperlink_launchable: bool,
	clipboard_silent:     bool,
	clipboard_reply:      bool,
	clipboard_unchanged:  bool,
	probe_writes:         int,
	probe_reads:          int,
	probe_payload:        [HOST_EFFECTS_TEXT_LIMIT]u8,
	probe_payload_len:    int,
}

// The one oracle both tests share: every in-terminal effect arrived, and no host-facing effect did.
// `probe_writes` and `probe_reads` are zero whenever no consumer is registered, which is the state
// production sessions run in. The mutant below registers one and must turn this false.
isolation_ok :: proc(o: ^Host_Observation) -> bool {
	return o.title_changed &&
	       string(o.title[:o.title_len]) == HOST_EFFECTS_TITLE &&
	       string(o.hyperlink[:o.hyperlink_len]) == HOST_EFFECTS_URI &&
	       !o.hyperlink_launchable &&
	       o.clipboard_silent &&
	       !o.clipboard_reply &&
	       o.clipboard_unchanged &&
	       o.probe_writes == 0 &&
	       o.probe_reads == 0
}

// Only the mutant test registers a probe, and only it reads this state.
@(private)
probe_effects: Host_Effects

@(private)
clipboard_sequence :: proc() -> u32 {
	return GetClipboardSequenceNumber()
}

// Records the write and stops: an unanswered request is a denial, so the probe cannot reach the
// real clipboard even though it is wired to the same pipeline production uses.
@(private)
clipboard_write :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	write: ^Ghostty_Clipboard_Write,
) {
	if write != nil && write.contents != nil && write.contents_len > 0 {
		data := write.contents[0].data
		n := min(int(data.len), len(probe_effects.payload))
		if n > 0 && data.ptr != nil {
			copy(probe_effects.payload[:n], data.ptr[:n])
			sync.atomic_store(&probe_effects.payload_len, n)
		}
	}
	sync.atomic_add(&probe_effects.writes, 1)
}

// Records the read and stops: OSC 52 then receives an empty clipboard, never host contents.
@(private)
clipboard_read :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	read: ^Ghostty_Clipboard_Read,
) {
	sync.atomic_add(&probe_effects.reads, 1)
}

@(private)
register_clipboard_probe :: proc(terminal: ghostty.Terminal, _: rawptr) -> bool {
	write_callback: Ghostty_Terminal_Clipboard_Write_Fn = clipboard_write
	read_callback: Ghostty_Terminal_Clipboard_Read_Fn = clipboard_read
	ok := ghostty.terminal_set(terminal, .Clipboard_Write, rawptr(write_callback)) == .Success
	ok &&= ghostty.terminal_set(terminal, .Clipboard_Read, rawptr(read_callback)) == .Success
	return ok
}

@(private)
Grid_Scan :: struct {
	columns, rows: u16,
	uri_len:       int,
	uri:           [HOST_EFFECTS_TEXT_LIMIT]u8,
}

// Finds the first cell carrying a hyperlink. The URI lives on the grid ref, not in the cell text,
// so this is also the proof that a link reached the terminal rather than the host.
@(private)
scan_hyperlink :: proc(terminal: ghostty.Terminal, user: rawptr) -> bool {
	scan := cast(^Grid_Scan)user
	buffer: [512]u8
	for y in 0 ..< int(scan.rows) {
		for x in 0 ..< int(scan.columns) {
			ref: ghostty.Grid_Ref
			point := ghostty.Point {
				tag   = .Active,
				value = {coordinate = {x = u16(x), y = u32(y)}},
			}
			if ghostty.terminal_grid_ref(terminal, point, &ref) != .Success {continue}
			n: uint
			if ghostty.grid_ref_hyperlink_uri(&ref, &buffer[0], uint(len(buffer)), &n) != .Success {
				continue
			}
			if n == 0 {continue}
			scan.uri_len = min(int(n), len(scan.uri))
			copy(scan.uri[:scan.uri_len], buffer[:scan.uri_len])
			return true
		}
	}
	return false
}

// Drives one child through the effect sequences and reports what the session and the host saw.
// `probe` is nil for a production-shaped session and the recording probe for the mutant.
@(private)
observe_host_effects :: proc(
	t: ^testing.T,
	s: ^term.Session,
	probe: ^Host_Effects,
) -> (
	Host_Observation,
	bool,
) {
	o: Host_Observation
	if !await(t, s, shows, "READY") {return o, false}
	// The shell may name its own window while starting; only effects after the trigger count.
	term.take_title_change(s)
	baseline := clipboard_sequence()
	term.send_text(s, "host effects")
	press_and_release(s, enter({}, 0))
	if !await(t, s, shows, "DONE") {return o, false}
	o.clipboard_unchanged = clipboard_sequence() == baseline
	o.clipboard_silent = shows(s, "CLIPBOARD_SILENT")
	o.clipboard_reply = shows(s, "CLIPBOARD_REPLY")
	o.title_changed = term.take_title_change(s)
	title := term.title(s, context.temp_allocator)
	o.title_len = min(len(title), len(o.title))
	copy(o.title[:o.title_len], title[:o.title_len])
	geometry := term.geometry(s)
	scan := Grid_Scan {
		columns = geometry.columns,
		rows    = geometry.rows,
	}
	if term.with_terminal(s, scan_hyperlink, &scan) {
		o.hyperlink_len = scan.uri_len
		copy(o.hyperlink[:o.hyperlink_len], scan.uri[:o.hyperlink_len])
		o.hyperlink_launchable = platform.open_path_allowed(string(o.hyperlink[:o.hyperlink_len]))
	}
	if probe != nil {
		o.probe_writes = sync.atomic_load(&probe.writes)
		o.probe_reads = sync.atomic_load(&probe.reads)
		o.probe_payload_len = sync.atomic_load(&probe.payload_len)
		copy(o.probe_payload[:o.probe_payload_len], probe.payload[:o.probe_payload_len])
	}
	return o, true
}

@(test)
output_effects_stay_off_host_clipboard_and_links :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, HOST_EFFECTS_CHILD, &wakes)
	if s == nil {return}
	defer term.destroy(s)
	o, ok := observe_host_effects(t, s, nil)
	if !ok {return}
	testing.expect(t, o.clipboard_silent, "child did not report how the clipboard read was answered")
	testing.expect(t, !o.clipboard_reply, "terminal output answered a clipboard read")
	testing.expect(t, o.clipboard_unchanged, "terminal output changed the clipboard sequence number")
	testing.expect(t, o.title_changed, "the title-change effect never fired")
	testing.expect_value(t, string(o.title[:o.title_len]), HOST_EFFECTS_TITLE)
	testing.expect_value(t, string(o.hyperlink[:o.hyperlink_len]), HOST_EFFECTS_URI)
	testing.expect(t, !o.hyperlink_launchable, "the terminal hyperlink was a launchable path")
	testing.expect(t, isolation_ok(&o), "terminal output reached a host effect")
}

// The mutant: registering the clipboard consumers production never registers makes the same
// sequences observable above the terminal. The shared oracle must reject that session, and the
// rejection must come from the delivered clipboard requests: the in-terminal effects and the
// clipboard sequence number are unchanged, so the oracle is sensitive rather than vacuous.
@(test)
registered_clipboard_probe_turns_the_oracle_false :: proc(t: ^testing.T) {
	probe_effects = {}
	wakes: Wakes
	s := start(t, HOST_EFFECTS_CHILD, &wakes)
	if s == nil {return}
	defer term.destroy(s)
	testing.expect(t, term.with_terminal(s, register_clipboard_probe, nil), "probe registration failed")
	o, ok := observe_host_effects(t, s, &probe_effects)
	if !ok {return}
	testing.expect_value(t, o.probe_writes, 2)
	testing.expect_value(t, o.probe_reads, 1)
	testing.expect_value(t, string(o.probe_payload[:o.probe_payload_len]), HOST_EFFECTS_PAYLOAD)
	testing.expect(t, o.clipboard_unchanged, "the recording probe changed the clipboard")
	// The in-terminal effects and the clipboard sequence number are untouched, so the failure the
	// oracle reports comes only from the registered consumers production never installs. The read
	// probe also makes the child see an answer, so its silence marker is sensitive too.
	testing.expect(t, o.title_changed, "the mutant run broke an in-terminal effect")
	testing.expect_value(t, string(o.hyperlink[:o.hyperlink_len]), HOST_EFFECTS_URI)
	testing.expect(t, !o.hyperlink_launchable, "the mutant run made the hyperlink launchable")
	testing.expect(t, !isolation_ok(&o), "the oracle missed a registered clipboard consumer")
}

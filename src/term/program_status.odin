package term

import "aio:ghostty"
import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

// Mirrors ghostty.Program_Status_State, which reports convert from.
Program_Status_State :: enum i32 {
	Idle,
	Working,
	Done,
	Blocked,
	Error,
}

Program_Status_Kind :: enum i32 {
	None,
	Permission,
	Question,
	Auth,
}

// Progress is -1 when the program sent none.
Program_Status :: struct {
	id, app, title, message: string,
	state:                   Program_Status_State,
	kind:                    Program_Status_Kind,
	progress:                i8,
	// The shell prompt has returned since this finished, so the program that reported it has ended.
	ended:                   bool,
	// The user has read the pane since the record entered its state. Only snapshots fill it in.
	read:                    bool,
	updated_at:              time.Time,
	// When the record entered its state and kind; reports that repeat both keep it.
	since:                   time.Time,
}

@(private)
PROGRAM_STATUS_LIMIT :: 256

@(private)
Stored_Status :: struct {
	value: Program_Status,
	text:  string,
}

@(private)
status_descendant :: proc(id, ancestor: string) -> bool {
	return(
		len(ancestor) == 0 ||
		id == ancestor ||
		(len(id) > len(ancestor) && strings.has_prefix(id, ancestor) && id[len(ancestor)] == '/') \
	)
}

// Which records a removal takes. Done and error records wait for the user; the rest belong to the
// program and go when it can no longer be running.
@(private)
Status_Removal :: enum {
	All,
	Transient,
	Finished,
	// Finished records the user has read.
	Read,
	// Finished records the user has read whose program has ended.
	Read_Ended,
	// The record `id` and its descendants, which the program cleared.
	Subtree,
	// The record `id`, which a new report replaces.
	Replaced,
	// The record `id` if finished, which the user dismissed.
	Dismissed,
}

@(private = "file")
remove_program_status :: proc(s: ^Session, index: int) {
	delete(s.program_statuses[index].text, s.allocator)
	for i in index ..< s.program_status_count - 1 {
		s.program_statuses[i] = s.program_statuses[i + 1]
	}
	s.program_status_count -= 1
	s.program_statuses[s.program_status_count] = {}
	sync.atomic_store(&s.program_status_changed, true)
}

// Whether the user has read a record: they looked at the pane after it entered its state, and have
// not marked the pane unread since. The caller holds the session mutex.
@(private = "file")
program_status_is_read :: proc(s: ^Session, record: Program_Status) -> bool {
	if s.program_status_unread || s.program_status_read_at == {} {return false}
	return time.diff(record.since, s.program_status_read_at) >= 0
}

// Every removal but eviction at the limit comes through here, from the reader thread and the main
// thread alike, so the caller holds the session mutex unless no thread can still reach the session.
@(private)
clear_program_status :: proc(s: ^Session, which: Status_Removal, id := "") {
	for i := s.program_status_count - 1; i >= 0; i -= 1 {
		record := s.program_statuses[i].value
		finished := program_status_finished(record.state)
		removed: bool
		switch which {
		case .All:
			removed = true
		case .Transient:
			removed = !finished
		case .Finished:
			removed = finished
		case .Read:
			removed = finished && program_status_is_read(s, record)
		case .Read_Ended:
			removed = finished && record.ended && program_status_is_read(s, record)
		case .Subtree:
			removed = status_descendant(record.id, id)
		case .Replaced:
			removed = record.id == id
		case .Dismissed:
			removed = record.id == id && finished
		}
		if removed {remove_program_status(s, i)}
	}
}

@(private)
strip_status_formatting :: proc(text: string) -> string {
	data := transmute([]u8)text
	n := 0
	for offset := 0; offset < len(text); {
		r, width := utf8.decode_rune_in_string(text[offset:])
		invalid := r == utf8.RUNE_ERROR && width == 1
		if !invalid && (r == '\u200d' || unicode.is_graphic(r)) {
			copy(data[n:n + width], data[offset:offset + width])
			n += width
		}
		offset += width
	}
	return string(data[:n])
}

@(private)
on_program_status :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	report: ^ghostty.Terminal_Program_Status,
) {
	s := (^Session)(userdata)
	context = s.callback_context
	id := string(report.id.ptr[:report.id.len])
	if report.state == .Clear {
		clear_program_status(s, .Subtree, id)
		return
	}
	parts := [?]string {
		id,
		string(report.app.ptr[:report.app.len]),
		string(report.title.ptr[:report.title.len]),
		string(report.message.ptr[:report.message.len]),
	}
	text, err := strings.concatenate(parts[:], s.allocator)
	if err != nil {
		log.error("term: storing program status failed: out of memory")
		return
	}
	p := Program_Status {
		state      = Program_Status_State(report.state),
		kind       = Program_Status_Kind(report.kind),
		progress   = report.progress,
		updated_at = wall_now(s),
	}
	// A report from a program started since the old record ended is new work, however alike.
	p.since = p.updated_at
	for stored in s.program_statuses[:s.program_status_count] {
		old := stored.value
		if old.id == id && !old.ended && old.state == p.state && old.kind == p.kind {p.since = old.since}
	}
	fields := [?]^string{&p.id, &p.app, &p.title, &p.message}
	offset := 0
	for part, i in parts {
		fields[i]^ = text[offset:offset + len(part)]
		offset += len(part)
	}
	p.title = strip_status_formatting(p.title)
	p.message = strip_status_formatting(p.message)
	clear_program_status(s, .Replaced, id)
	if s.program_status_count == PROGRAM_STATUS_LIMIT {
		remove_program_status(s, 0)
	}
	s.program_statuses[s.program_status_count] = {p, text}
	s.program_status_count += 1
	sync.atomic_store(&s.program_status_changed, true)
}

@(private = "file")
wall_now :: proc(s: ^Session) -> time.Time {
	clock := s.wall_clock
	return clock.procedure != nil ? clock.procedure(clock.user) : time.now()
}

@(private)
on_semantic_prompt :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	event: ^ghostty.Terminal_Semantic_Prompt,
) {
	s := (^Session)(userdata)
	context = s.callback_context
	if event.kind == .Prompt_Start {program_status_end(s)}
}

// The program that reported has ended: its running reports go, and its finished work is marked so.
// The caller holds the session mutex.
@(private = "file")
program_status_end :: proc(s: ^Session) {
	clear_program_status(s, .Transient)
	for &stored in s.program_statuses[:s.program_status_count] {
		if stored.value.ended {continue}
		stored.value.ended = true
		sync.atomic_store(&s.program_status_changed, true)
	}
}

// The pane's program ended as process polling saw it, which a shell without prompt marks reports in
// no other way. The same as a new prompt.
program_status_program_ended :: proc(s: ^Session) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	program_status_end(s)
}

@(private)
inherited_app :: proc(s: ^Session, p: Program_Status) -> string {
	if len(p.app) > 0 {
		return p.app
	}
	app := ""
	nearest := -1
	for record in s.program_statuses[:s.program_status_count] {
		ancestor := record.value
		if len(ancestor.app) > 0 &&
		   len(ancestor.id) > nearest &&
		   ancestor.id != p.id &&
		   status_descendant(p.id, ancestor.id) {
			app, nearest = ancestor.app, len(ancestor.id)
		}
	}
	return app
}

@(require_results)
program_status :: proc(
	s: ^Session,
	allocator := context.allocator,
) -> (
	snapshot: []Program_Status,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	result: []Program_Status
	result, err = make([]Program_Status, s.program_status_count, allocator)
	if err != nil {
		log.error("term: allocating program status snapshot failed")
		return nil, err
	}
	for &p, i in result {
		source := s.program_statuses[s.program_status_count - 1 - i].value
		p.state, p.kind, p.progress = source.state, source.kind, source.progress
		p.updated_at, p.since, p.ended = source.updated_at, source.since, source.ended
		p.read = program_status_is_read(s, source)
		parts := [?]string{source.id, inherited_app(s, source), source.title, source.message}
		fields := [?]^string{&p.id, &p.app, &p.title, &p.message}
		for part, j in parts {
			fields[j]^, err = strings.clone(part, allocator)
			if err != nil {
				destroy_program_status(result, allocator)
				log.error("term: copying program status snapshot failed")
				return nil, err
			}
		}
	}
	return result, nil
}

destroy_program_status :: proc(snapshot: []Program_Status, allocator := context.allocator) {
	for p in snapshot {
		delete(p.id, allocator)
		delete(p.app, allocator)
		delete(p.title, allocator)
		delete(p.message, allocator)
	}
	delete(snapshot, allocator)
}

take_program_status_change :: proc(s: ^Session) -> bool {
	return sync.atomic_exchange(&s.program_status_changed, false)
}

// Done and error work. Everything else is transient: the program is still on it.
program_status_finished :: proc(state: Program_Status_State) -> bool {
	return state == .Done || state == .Error
}

// When the user last read the pane, zero if never, and whether they marked it unread since.
program_status_read_state :: proc(s: ^Session) -> (read_at: time.Time, unread: bool) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	return s.program_status_read_at, s.program_status_unread
}

// The user read the pane at `at`. Looking keeps a mark the user set by hand; `mark` sets the pane read
// as a choice, which clears it. Reading only ever adds read records, so a change in their count is
// the change to report.
program_status_read :: proc(s: ^Session, at: time.Time, mark := false) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	before := program_status_read_count(s)
	s.program_status_read_at = at
	if mark {s.program_status_unread = false}
	if program_status_read_count(s) != before {sync.atomic_store(&s.program_status_changed, true)}
}

// Marks the pane unread until the user next looks at it or marks it read.
program_status_mark_unread :: proc(s: ^Session) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	if s.program_status_unread {return}
	s.program_status_unread = true
	sync.atomic_store(&s.program_status_changed, true)
}

@(private = "file")
program_status_read_count :: proc(s: ^Session) -> (count: int) {
	for stored in s.program_statuses[:s.program_status_count] {
		if program_status_is_read(s, stored.value) {count += 1}
	}
	return
}

// Removes finished records the user has read; with `ended_only`, only those whose program has ended.
program_status_dismiss_read :: proc(s: ^Session, ended_only: bool) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	clear_program_status(s, ended_only ? .Read_Ended : .Read)
}

// Removes every done and error record.
program_status_dismiss_finished :: proc(s: ^Session) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	clear_program_status(s, .Finished)
}

// Removes one done or error record. Running and blocked records belong to the program, not the user.
program_status_dismiss :: proc(s: ^Session, id: string) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	clear_program_status(s, .Dismissed, id)
}

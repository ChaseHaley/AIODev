package term

import "aio:ghostty"
import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

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

// Progress is -1 when the program sent none. Seen marks a done or error record the user has looked at.
Program_Status :: struct {
	id, app, title, message: string,
	state:                   Program_Status_State,
	kind:                    Program_Status_Kind,
	progress:                i8,
	seen:                    bool,
	updated_at:              time.Time,
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

@(private)
remove_program_status :: proc(s: ^Session, index: int) {
	delete(s.program_statuses[index].text, s.allocator)
	for i in index ..< s.program_status_count - 1 {
		s.program_statuses[i] = s.program_statuses[i + 1]
	}
	s.program_status_count -= 1
	s.program_statuses[s.program_status_count] = {}
	sync.atomic_store(&s.program_status_changed, true)
}

@(private)
clear_program_status :: proc(s: ^Session, transient_only: bool) {
	for i := s.program_status_count - 1; i >= 0; i -= 1 {
		state := s.program_statuses[i].value.state
		if !transient_only || state == .Idle || state == .Working || state == .Blocked {
			remove_program_status(s, i)
		}
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
		for i := s.program_status_count - 1; i >= 0; i -= 1 {
			if status_descendant(s.program_statuses[i].value.id, id) {
				remove_program_status(s, i)
			}
		}
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
		updated_at = time.now(),
	}
	fields := [?]^string{&p.id, &p.app, &p.title, &p.message}
	offset := 0
	for part, i in parts {
		fields[i]^ = text[offset:offset + len(part)]
		offset += len(part)
	}
	p.title = strip_status_formatting(p.title)
	p.message = strip_status_formatting(p.message)
	for i in 0 ..< s.program_status_count {
		if s.program_statuses[i].value.id == id {
			remove_program_status(s, i)
			break
		}
	}
	if s.program_status_count == PROGRAM_STATUS_LIMIT {
		remove_program_status(s, 0)
	}
	s.program_statuses[s.program_status_count] = {p, text}
	s.program_status_count += 1
	sync.atomic_store(&s.program_status_changed, true)
}

@(private)
on_semantic_prompt :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	event: ^ghostty.Terminal_Semantic_Prompt,
) {
	s := (^Session)(userdata)
	context = s.callback_context
	if event.kind == .Prompt_Start {
		clear_program_status(s, true)
	}
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
		p.seen, p.updated_at = source.seen, source.updated_at
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

@(private)
status_finished :: proc(state: Program_Status_State) -> bool {
	return state == .Done || state == .Error
}

// Marks every done and error record seen, which is how the user acknowledges finished work.
program_status_acknowledge :: proc(s: ^Session) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	for &record in s.program_statuses[:s.program_status_count] {
		if status_finished(record.value.state) && !record.value.seen {
			record.value.seen = true
			sync.atomic_store(&s.program_status_changed, true)
		}
	}
}

// Removes done and error records, only the seen ones unless `all` is set.
program_status_dismiss_finished :: proc(s: ^Session, all := false) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	for i := s.program_status_count - 1; i >= 0; i -= 1 {
		value := s.program_statuses[i].value
		if status_finished(value.state) && (all || value.seen) {
			remove_program_status(s, i)
		}
	}
}

// Removes one done or error record. Running and blocked records belong to the program, not the user.
program_status_dismiss :: proc(s: ^Session, id: string) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	for i in 0 ..< s.program_status_count {
		value := s.program_statuses[i].value
		if value.id == id && status_finished(value.state) {
			remove_program_status(s, i)
			return
		}
	}
}

// Disabling stops listening: reports are dropped, the support query goes unanswered so programs
// see the protocol as unsupported, and every stored record is removed.
set_program_status_enabled :: proc(s: ^Session, enabled: bool) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	if s.program_status_enabled == enabled {return}
	callback: ghostty.Terminal_Program_Status_Fn = on_program_status
	value := enabled ? rawptr(callback) : nil
	if ghostty.terminal_set(s.terminal, .Program_Status, value) != .Success {
		log.error("term: switching program status reports failed")
		return
	}
	s.program_status_enabled = enabled
	if !enabled {clear_program_status(s, false)}
}

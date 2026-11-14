package turns

// What a pane reported that can open or close its turn. Working..Cleared come from the program's status
// (OSC 7501), Prompt and Stop from harness hooks, and Ended when the pane's program exited.
Pane_Signal :: enum u8 {
	Working,
	Blocked,
	Done,
	Idle,
	Error,
	Cleared,
	Prompt,
	Stop,
	Ended,
}

// The turn a pane is in. After an End boundary `started`, `sources` and `end_state` still describe the
// turn that just closed, until the next Begin replaces them.
Pane_Turn :: struct {
	open:      bool,
	started:   i64,
	sources:   bit_set[Signal_Source],
	end_state: End_State,
}

Boundary :: enum u8 {
	None,
	Begin,
	End,
}

// Moves the pane's turn by one signal and says whether that opened or closed it. Blocked means the
// agent waits for the user inside the same turn, so it never ends one.
pane_turn_signal :: proc(p: ^Pane_Turn, signal: Pane_Signal, now: i64) -> Boundary {
	source: bit_set[Signal_Source]
	switch signal {
	case .Working, .Blocked, .Done, .Idle, .Error, .Cleared:
		source = {.Status}
	case .Prompt, .Stop:
		source = {.Hooks}
	case .Ended:
	}
	if !p.open {
		if signal != .Working && signal != .Prompt {return .None}
		p.open = true
		p.started = now
		p.sources = source
		p.end_state = .Unknown
		return .Begin
	}
	switch signal {
	case .Working, .Prompt, .Blocked:
		p.sources += source
		return .None
	case .Done, .Stop:
		p.end_state = .Done
	case .Idle:
		p.end_state = .Idle
	case .Error:
		p.end_state = .Error
	case .Cleared, .Ended:
		p.end_state = .Ended
	}
	p.sources += source
	p.open = false
	return .End
}

// A mirror of the app's status record, so this package needs no terminal import.
Record_Status :: struct {
	id:      string,
	state:   Status_State,
	updated: i64,
}

Status_State :: enum u8 {
	Idle,
	Working,
	Done,
	Blocked,
	Error,
}

// The record a pane's turn follows: the one with an empty id, else the most recently updated top-level
// record (no '/' in its id), so a subagent's status never ends the main agent's turn.
@(require_results)
main_status :: proc(records: []Record_Status) -> (state: Status_State, ok: bool) {
	for r in records {
		if r.id == "" {return r.state, true}
	}
	latest: i64
	for r in records {
		if contains_slash(r.id) {continue}
		if ok && r.updated <= latest {continue}
		state = r.state
		latest = r.updated
		ok = true
	}
	return
}

@(private)
contains_slash :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] == '/' {return true}
	}
	return false
}

// The signal for a change of the main status between two snapshots, or ok = false for none.
@(require_results)
status_signal :: proc(
	before: Status_State,
	had_before: bool,
	after: Status_State,
	has_after: bool,
) -> (Pane_Signal, bool) {
	if !has_after {return .Cleared, had_before}
	if had_before && before == after {return {}, false}
	switch after {
	case .Working:
		return .Working, true
	case .Blocked:
		return .Blocked, true
	case .Done:
		return .Done, true
	case .Idle:
		return .Idle, true
	case .Error:
		return .Error, true
	}
	return {}, false
}

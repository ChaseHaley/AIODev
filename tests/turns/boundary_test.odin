package turns_test

import "aio:turns"
import "core:testing"

@(test)
working_opens_a_turn_and_records_the_time_and_source :: proc(t: ^testing.T) {
	p: turns.Pane_Turn
	testing.expect_value(t, turns.pane_turn_signal(&p, .Working, 100), turns.Boundary.Begin)
	testing.expect(t, p.open)
	testing.expect_value(t, p.started, 100)
	testing.expect_value(t, p.sources, bit_set[turns.Signal_Source]{.Status})
}

@(test)
prompt_opens_a_turn_from_hooks :: proc(t: ^testing.T) {
	p: turns.Pane_Turn
	testing.expect_value(t, turns.pane_turn_signal(&p, .Prompt, 7), turns.Boundary.Begin)
	testing.expect_value(t, p.sources, bit_set[turns.Signal_Source]{.Hooks})
	testing.expect_value(t, p.started, 7)
}

@(test)
signals_that_cannot_open_a_turn_do_nothing_while_closed :: proc(t: ^testing.T) {
	for signal in ([?]turns.Pane_Signal{.Blocked, .Done, .Idle, .Error, .Cleared, .Stop, .Ended}) {
		p: turns.Pane_Turn
		testing.expect_value(t, turns.pane_turn_signal(&p, signal, 5), turns.Boundary.None)
		testing.expectf(t, !p.open, "%v must not open a turn", signal)
	}
}

@(test)
every_end_signal_closes_an_open_turn_with_its_end_state :: proc(t: ^testing.T) {
	Case :: struct {
		signal: turns.Pane_Signal,
		state:  turns.End_State,
	}
	cases := [?]Case {
		{.Done, .Done},
		{.Idle, .Idle},
		{.Error, .Error},
		{.Cleared, .Ended},
		{.Stop, .Done},
		{.Ended, .Ended},
	}
	for c in cases {
		p: turns.Pane_Turn
		_ = turns.pane_turn_signal(&p, .Working, 1)
		testing.expect_value(t, turns.pane_turn_signal(&p, c.signal, 9), turns.Boundary.End)
		testing.expectf(t, !p.open, "%v must close the turn", c.signal)
		testing.expect_value(t, p.end_state, c.state)
		testing.expect_value(t, p.started, 1)
	}
}

@(test)
blocked_never_ends_a_turn :: proc(t: ^testing.T) {
	p: turns.Pane_Turn
	_ = turns.pane_turn_signal(&p, .Working, 1)
	testing.expect_value(t, turns.pane_turn_signal(&p, .Blocked, 2), turns.Boundary.None)
	testing.expect(t, p.open)
	testing.expect_value(t, turns.pane_turn_signal(&p, .Working, 3), turns.Boundary.None)
	testing.expect_value(t, p.started, 1)
	testing.expect_value(t, turns.pane_turn_signal(&p, .Done, 4), turns.Boundary.End)
}

@(test)
a_second_end_is_ignored_and_keeps_the_first_end_state :: proc(t: ^testing.T) {
	p: turns.Pane_Turn
	_ = turns.pane_turn_signal(&p, .Working, 1)
	testing.expect_value(t, turns.pane_turn_signal(&p, .Done, 2), turns.Boundary.End)
	testing.expect_value(t, turns.pane_turn_signal(&p, .Idle, 3), turns.Boundary.None)
	testing.expect_value(t, turns.pane_turn_signal(&p, .Ended, 4), turns.Boundary.None)
	testing.expect_value(t, p.end_state, turns.End_State.Done)
}

@(test)
prompt_and_working_while_open_do_not_begin_again_but_add_their_source :: proc(t: ^testing.T) {
	p: turns.Pane_Turn
	_ = turns.pane_turn_signal(&p, .Working, 10)
	testing.expect_value(t, turns.pane_turn_signal(&p, .Prompt, 20), turns.Boundary.None)
	testing.expect_value(t, p.started, 10)
	testing.expect_value(t, p.sources, bit_set[turns.Signal_Source]{.Status, .Hooks})
	// The other order: hooks first, then the status report.
	q: turns.Pane_Turn
	_ = turns.pane_turn_signal(&q, .Prompt, 10)
	testing.expect_value(t, turns.pane_turn_signal(&q, .Working, 11), turns.Boundary.None)
	testing.expect_value(t, q.sources, bit_set[turns.Signal_Source]{.Status, .Hooks})
	testing.expect_value(t, turns.pane_turn_signal(&q, .Stop, 12), turns.Boundary.End)
	testing.expect_value(t, q.end_state, turns.End_State.Done)
}

@(test)
a_new_turn_after_an_end_starts_clean :: proc(t: ^testing.T) {
	p: turns.Pane_Turn
	_ = turns.pane_turn_signal(&p, .Prompt, 1)
	_ = turns.pane_turn_signal(&p, .Error, 2)
	testing.expect_value(t, turns.pane_turn_signal(&p, .Working, 50), turns.Boundary.Begin)
	testing.expect_value(t, p.started, 50)
	testing.expect_value(t, p.sources, bit_set[turns.Signal_Source]{.Status})
	testing.expect_value(t, p.end_state, turns.End_State.Unknown)
}

@(test)
main_status_prefers_the_empty_id :: proc(t: ^testing.T) {
	records := [?]turns.Record_Status{{"build", .Working, 900}, {"", .Idle, 1}, {"other", .Done, 800}}
	state, ok := turns.main_status(records[:])
	testing.expect(t, ok)
	testing.expect_value(t, state, turns.Status_State.Idle)
}

@(test)
main_status_without_an_empty_id_takes_the_latest_top_level_record :: proc(t: ^testing.T) {
	records := [?]turns.Record_Status{{"a", .Done, 10}, {"b", .Working, 30}, {"c", .Error, 20}}
	state, ok := turns.main_status(records[:])
	testing.expect(t, ok)
	testing.expect_value(t, state, turns.Status_State.Working)
}

@(test)
main_status_ignores_nested_records :: proc(t: ^testing.T) {
	records := [?]turns.Record_Status{{"a/sub", .Working, 99}, {"a", .Done, 10}, {"b/c/d", .Error, 100}}
	state, ok := turns.main_status(records[:])
	testing.expect(t, ok)
	testing.expect_value(t, state, turns.Status_State.Done)

	only_nested := [?]turns.Record_Status{{"a/sub", .Working, 99}}
	_, ok = turns.main_status(only_nested[:])
	testing.expect(t, !ok)
}

@(test)
main_status_of_nothing_is_none :: proc(t: ^testing.T) {
	_, ok := turns.main_status(nil)
	testing.expect(t, !ok)
}

@(test)
status_signal_reports_changes_of_the_main_status :: proc(t: ^testing.T) {
	signal, ok := turns.status_signal(.Idle, false, .Idle, false)
	testing.expect(t, !ok)

	signal, ok = turns.status_signal(.Working, true, .Idle, false)
	testing.expect(t, ok)
	testing.expect_value(t, signal, turns.Pane_Signal.Cleared)

	_, ok = turns.status_signal(.Working, true, .Working, true)
	testing.expect(t, !ok)

	Case :: struct {
		after:  turns.Status_State,
		signal: turns.Pane_Signal,
	}
	cases := [?]Case {
		{.Working, .Working},
		{.Blocked, .Blocked},
		{.Done, .Done},
		{.Idle, .Idle},
		{.Error, .Error},
	}
	for c in cases {
		// A first status and a change from another state both report the new one.
		signal, ok = turns.status_signal(.Idle, false, c.after, true)
		testing.expect(t, ok)
		testing.expect_value(t, signal, c.signal)
		before: turns.Status_State = .Error if c.after != .Error else .Idle
		signal, ok = turns.status_signal(before, true, c.after, true)
		testing.expect(t, ok)
		testing.expect_value(t, signal, c.signal)
	}
}

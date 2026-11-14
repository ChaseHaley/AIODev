package events_test

import "aio:events"
import "core:mem"
import "core:testing"

@(private = "file")
Pane_Exit :: struct {
	pane, exit_code: u32,
}

@(private = "file")
Pane_Title :: struct {
	pane:  u32,
	title: string,
}

@(private = "file")
Pane_Size :: struct {
	pane:       u32,
	cols, rows: u16,
}

@(private = "file")
Pane :: struct {
	pane: u32,
}

@(private = "file")
Tab_Name :: struct {
	tab, workspace: u32,
	name:           string,
}

@(private = "file")
Empty :: struct {}

@(test)
events_a_kind_nobody_wants_is_neither_stored_nor_marshalled :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	q: events.Queue
	events.init(&q, mem.tracking_allocator(&track))
	defer events.destroy(&q)
	before := track.total_allocation_count
	events.push(&q, .Pane_Exited, Pane_Exit{3, 1})
	testing.expect_value(t, len(events.pending(&q)), 0)
	events.set_interest(&q, .Lua, {.Pane_Closed})
	events.push(&q, .Pane_Exited, Pane_Exit{3, 1})
	events.push(&q, .Pane_Resized, Pane_Size{3, 80, 24})
	events.layout_changed(&q)
	testing.expect_value(t, len(events.pending(&q)), 0)
	testing.expect_value(t, track.total_allocation_count, before)
	events.push(&q, .Pane_Closed, Pane{3})
	testing.expect_value(t, len(events.pending(&q)), 1)
}

// Each event's fields are one compact JSON object with the contract's field names in order, and
// pane.closed leaves out exit_code when no exit was observed.
@(test)
events_fields_are_one_compact_json_object :: proc(t: ^testing.T) {
	q: events.Queue
	events.init(&q)
	defer events.destroy(&q)
	listened := events.Kinds{.Pane_Exited, .Pane_Closed, .Pane_Title_Changed, .Tab_Renamed, .App_Quitting}
	events.set_interest(&q, .Cli, listened)
	events.push(&q, .Pane_Exited, Pane_Exit{3, 1})
	events.push(&q, .Pane_Closed, Pane{4})
	events.push(&q, .Pane_Closed, Pane_Exit{3, 1})
	events.push(&q, .Pane_Title_Changed, Pane_Title{7, `say "hi"`})
	events.push(&q, .Tab_Renamed, Tab_Name{2, 1, "Build"})
	events.push(&q, .App_Quitting, Empty{})
	pending := events.pending(&q)
	if !testing.expect_value(t, len(pending), 6) {return}
	testing.expect_value(t, pending[0].kind, events.Kind.Pane_Exited)
	testing.expect_value(t, pending[0].fields, `{"pane":3,"exit_code":1}`)
	testing.expect_value(t, pending[1].kind, events.Kind.Pane_Closed)
	testing.expect_value(t, pending[1].fields, `{"pane":4}`)
	testing.expect_value(t, pending[2].kind, events.Kind.Pane_Closed)
	testing.expect_value(t, pending[2].fields, `{"pane":3,"exit_code":1}`)
	testing.expect_value(t, pending[3].kind, events.Kind.Pane_Title_Changed)
	testing.expect_value(t, pending[3].fields, `{"pane":7,"title":"say \"hi\""}`)
	testing.expect_value(t, pending[4].kind, events.Kind.Tab_Renamed)
	testing.expect_value(t, pending[4].fields, `{"tab":2,"workspace":1,"name":"Build"}`)
	testing.expect_value(t, pending[5].kind, events.Kind.App_Quitting)
	testing.expect_value(t, pending[5].fields, `{}`)
}

@(test)
events_clear_empties_pending_and_the_queue_takes_new_events :: proc(t: ^testing.T) {
	q: events.Queue
	events.init(&q)
	defer events.destroy(&q)
	events.set_interest(&q, .Lua, {.Pane_Bell, .Pane_Resized})
	events.push(&q, .Pane_Bell, Pane{1})
	events.push(&q, .Pane_Resized, Pane_Size{1, 80, 24})
	testing.expect_value(t, len(events.pending(&q)), 2)
	events.clear(&q)
	testing.expect_value(t, len(events.pending(&q)), 0)
	// A cleared resize no longer coalesces with the next one.
	events.push(&q, .Pane_Resized, Pane_Size{1, 81, 24})
	pending := events.pending(&q)
	if !testing.expect_value(t, len(pending), 1) {return}
	testing.expect_value(t, pending[0].fields, `{"pane":1,"cols":81,"rows":24}`)
}

// One layout.changed per tick with the latest revision, and one pane.resized per pane with its latest
// size, each where the first one stood.
@(test)
events_layout_and_resize_coalesce_within_a_tick :: proc(t: ^testing.T) {
	q: events.Queue
	events.init(&q)
	defer events.destroy(&q)
	events.set_interest(&q, .Lua, {.Layout_Changed, .Pane_Resized, .Pane_Bell})
	events.layout_changed(&q)
	events.push(&q, .Pane_Resized, Pane_Size{1, 80, 24})
	events.push(&q, .Pane_Bell, Pane{1})
	events.push(&q, .Pane_Resized, Pane_Size{2, 40, 10})
	events.layout_changed(&q)
	events.push(&q, .Pane_Resized, Pane_Size{1, 100, 30})
	events.layout_changed(&q)
	pending := events.pending(&q)
	if !testing.expect_value(t, len(pending), 4) {return}
	testing.expect_value(t, pending[0].kind, events.Kind.Layout_Changed)
	testing.expect_value(t, pending[0].fields, `{"revision":3}`)
	testing.expect_value(t, pending[1].kind, events.Kind.Pane_Resized)
	testing.expect_value(t, pending[1].fields, `{"pane":1,"cols":100,"rows":30}`)
	testing.expect_value(t, pending[2].kind, events.Kind.Pane_Bell)
	testing.expect_value(t, pending[3].kind, events.Kind.Pane_Resized)
	testing.expect_value(t, pending[3].fields, `{"pane":2,"cols":40,"rows":10}`)
	events.clear(&q)
	events.layout_changed(&q)
	events.push(&q, .Pane_Resized, Pane_Size{1, 100, 31})
	pending = events.pending(&q)
	if !testing.expect_value(t, len(pending), 2) {return}
	testing.expect_value(t, pending[0].fields, `{"revision":4}`)
	testing.expect_value(t, pending[1].fields, `{"pane":1,"cols":100,"rows":31}`)
}

@(test)
events_layout_revision_advances_when_nobody_listens :: proc(t: ^testing.T) {
	q: events.Queue
	events.init(&q)
	defer events.destroy(&q)
	events.layout_changed(&q)
	events.layout_changed(&q)
	testing.expect_value(t, q.revision, 2)
	testing.expect_value(t, len(events.pending(&q)), 0)
	events.set_interest(&q, .Cli, {.Pane_Bell})
	events.layout_changed(&q)
	testing.expect_value(t, q.revision, 3)
	testing.expect_value(t, len(events.pending(&q)), 0)
	events.set_interest(&q, .Cli, {.Layout_Changed})
	events.layout_changed(&q)
	pending := events.pending(&q)
	if !testing.expect_value(t, len(pending), 1) {return}
	testing.expect_value(t, pending[0].fields, `{"revision":4}`)
}

@(test)
events_wanted_is_the_union_of_every_consumers_interest :: proc(t: ^testing.T) {
	q: events.Queue
	events.init(&q)
	defer events.destroy(&q)
	events.set_interest(&q, .Lua, {.Pane_Bell, .Tab_Created})
	events.set_interest(&q, .Cli, {.Tab_Created, .App_Quitting})
	testing.expect_value(t, q.wanted, events.Kinds{.Pane_Bell, .Tab_Created, .App_Quitting})
	testing.expect(t, events.wants(&q, .Pane_Bell))
	testing.expect(t, !events.wants(&q, .Pane_Closed))
	events.set_interest(&q, .Lua, {})
	testing.expect_value(t, q.wanted, events.Kinds{.Tab_Created, .App_Quitting})
	testing.expect(t, !events.wants(&q, .Pane_Bell))
	events.push(&q, .Pane_Bell, Pane{1})
	testing.expect_value(t, len(events.pending(&q)), 0)
	events.set_interest(&q, .Cli, {})
	testing.expect_value(t, q.wanted, events.Kinds{})
	events.push(&q, .Tab_Created, Pane{1})
	testing.expect_value(t, len(events.pending(&q)), 0)
}

@(test)
events_names_round_trip_in_contract_order :: proc(t: ^testing.T) {
	names := events.NAMES
	for kind in events.Kind {
		named, ok := events.kind_named(names[kind])
		testing.expectf(t, ok, "kind_named(%q)", names[kind])
		testing.expect_value(t, named, kind)
	}
	testing.expect_value(t, names[.Pane_Created], "pane.created")
	testing.expect_value(t, names[.Pane_Process_Changed], "pane.process_changed")
	testing.expect_value(t, names[.Tab_Renamed], "tab.renamed")
	testing.expect_value(t, names[.Layout_Changed], "layout.changed")
	testing.expect_value(t, names[.Prompt_Closed], "prompt.closed")
	testing.expect_value(t, names[.App_Quitting], "app.quitting")
	unknowns := [?]string{"pane.moved", "", "Pane.Created", "pane.created "}
	for unknown in unknowns {
		_, ok := events.kind_named(unknown)
		testing.expectf(t, !ok, "kind_named(%q) should fail", unknown)
	}
}

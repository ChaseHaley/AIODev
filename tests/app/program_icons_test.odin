package app_test

import "base:runtime"
import "core:testing"
import app "../../src"
import "aio:program_art"
import "aio:procinfo"

@(test)
process_snapshot_asked_for_while_one_is_taken_is_not_taken_twice :: proc(t: ^testing.T) {
	s: app.Process_Snapshot
	testing.expect(t, app.process_snapshot_ask(&s), "the first request wakes the worker")
	testing.expect(t, !app.process_snapshot_ask(&s), "a waiting request answers the next one")
	testing.expect(t, app.process_snapshot_begin(&s))
	testing.expect(t, !app.process_snapshot_ask(&s), "the snapshot being taken answers a request")
	app.process_snapshot_finish(&s, nil)
	testing.expect(t, !app.process_snapshot_begin(&s), "the worker takes no second snapshot")
	testing.expect(t, !app.process_snapshot_ask(&s), "a ready snapshot answers a request")
	processes, ready := app.process_snapshot_collect(&s)
	testing.expect(t, ready, "a failed snapshot is ready with no processes")
	testing.expect_value(t, len(processes), 0)
	_, ready = app.process_snapshot_collect(&s)
	testing.expect(t, !ready, "a snapshot is handed over once")
	testing.expect(t, app.process_snapshot_ask(&s), "once taken, the next request wakes the worker")
}

// Refuses every allocation, so the process worker cannot reserve its queues and does not start.
@(private)
icon_queue_refusal :: proc(
	_: rawptr,
	mode: runtime.Allocator_Mode,
	_, _: int,
	_: rawptr,
	_: int,
	_ := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		return nil, .Out_Of_Memory
	}
	return nil, nil
}

@(test)
program_icon_is_not_left_pending_when_the_worker_cannot_start :: proc(t: ^testing.T) {
	state: app.App
	if !art_catalogue(t, &state) {return}
	defer program_art.catalogue_destroy(&state.program_art)
	defer app.program_icon_cache_destroy(&state.program_icons)
	defer app.process_worker_destroy(&state.processes)
	state.settings.tabs.program_icons = true
	entry: app.Session_Entry
	state.processes.jobs.allocator = runtime.Allocator{procedure = icon_queue_refusal}
	{
		context.logger = {}
		_, pending, _ := app.report_icon(&state, &entry, "claude", 16)
		testing.expect(t, pending, "the artwork is still to be read")
	}
	for icon in state.program_icons.icons {
		testing.expect_value(t, icon.state, app.Program_Icon_State.Free)
	}
	state.processes.jobs.allocator = context.allocator
	_, pending, _ := app.report_icon(&state, &entry, "claude", 16)
	testing.expect(t, pending)
	queued := 0
	for icon in state.program_icons.icons {
		if icon.state != .Free {queued += 1}
	}
	testing.expect_value(t, queued, 1)
}

@(test)
program_is_adopted_on_a_second_poll_and_dropped_at_the_prompt :: proc(t: ^testing.T) {
	// Windows process ids are multiples of four, so these name no real process and reading their
	// image and arguments fails as it does for one that has exited.
	ROOT :: 1_000_001
	CLAUDE :: 1_000_003
	CODEX :: 1_000_005
	shell := []procinfo.Process_Info{{id = ROOT, parent = 1, executable = "pwsh.exe"}}
	claude := []procinfo.Process_Info{shell[0], {id = CLAUDE, parent = ROOT, executable = "claude.exe"}}
	codex := []procinfo.Process_Info{shell[0], {id = CODEX, parent = ROOT, executable = "codex.exe"}}
	state: app.App
	if !art_catalogue(t, &state) {return}
	defer program_art.catalogue_destroy(&state.program_art)
	entry: app.Session_Entry
	defer app.program_forget(&entry)

	// A short command seen by one poll and gone by the next neither redraws nor saves the layout.
	app.layout_state_enable(&state, "layout.ini")
	testing.expect(t, !app.program_update(&state, &entry, claude, ROOT))
	testing.expect(t, !app.program_update(&state, &entry, shell, ROOT), "a program seen once ends quietly")
	testing.expect(t, entry.program == nil)
	_, scheduled := app.layout_state_deadline(&state)
	testing.expect(t, !scheduled)

	testing.expect(t, !app.program_update(&state, &entry, claude, ROOT), "one sighting changes no icon")
	testing.expect_value(t, app.program_polled(&entry), CLAUDE)
	testing.expect(t, app.program_adopted(&entry) == nil)
	testing.expect(t, app.program_update(&state, &entry, claude, ROOT), "a second sighting adopts it")
	expect_adopted(t, &entry, CLAUDE, "claude")

	testing.expect(t, !app.program_update(&state, &entry, codex, ROOT))
	testing.expect_value(t, app.program_polled(&entry), CODEX)
	expect_adopted(t, &entry, CLAUDE, "claude")
	testing.expect(t, !app.program_update(&state, &entry, claude, ROOT), "the adopted program returned")
	testing.expect_value(t, app.program_polled(&entry), CLAUDE)
	testing.expect(t, !app.program_update(&state, &entry, codex, ROOT))
	testing.expect(t, app.program_update(&state, &entry, codex, ROOT), "a second sighting replaces it")
	expect_adopted(t, &entry, CODEX, "codex")

	testing.expect(t, app.program_update(&state, &entry, shell, ROOT), "the prompt shows at once")
	testing.expect(t, entry.program == nil)
	testing.expect(t, !app.program_update(&state, &entry, shell, ROOT))
}

@(private)
expect_adopted :: proc(t: ^testing.T, entry: ^app.Session_Entry, id: u32, name: string) {
	program := app.program_adopted(entry)
	if !testing.expect(t, program != nil) {return}
	testing.expect_value(t, program.id, id)
	testing.expect_value(t, program.name, name)
	testing.expect(t, program.has_art)
}

// Program names resolve against the bundled artwork, which the app parses at start.
@(private)
art_catalogue :: proc(t: ^testing.T, state: ^app.App) -> bool {
	catalogue, err := program_art.catalogue_make()
	state.program_art = catalogue
	return testing.expect_value(t, err, nil)
}

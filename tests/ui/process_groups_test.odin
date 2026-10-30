package ui_test

import "aio:settings"
import "aio:ui"
import "base:runtime"
import "core:strings"
import "core:testing"

@(private)
process_fixture :: proc(t: ^testing.T, p: ^ui.Editor) {
	testing.expect_value(t, ui.editor_process_load(p, "Editors:0:nvim,vim;Tools:8:less,nvim", 12), nil)
	p.open = true
	ui.editor_filter(p)
}

@(private)
process_edit :: proc(t: ^testing.T, p: ^ui.Editor, key, value: string) {
	testing.expect(t, ui.editor_reveal(p, key))
	p.focus = .Control
	ui.field_set(&p.value, value)
	testing.expect(t, ui.editor_process_capture(p))
}

@(test)
process_groups_round_trip_and_order_change_real_matching :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	process_fixture(t, &p)
	value, problem := ui.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, value, "Editors:0:nvim,vim;Tools:8:less,nvim")
	ui.editor_process_move(&p, 2, 0)
	value, problem = ui.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, value, "Tools:8:less,nvim;Editors:0:nvim,vim")
	s, issues, error := settings.parse(strings.concatenate({"process.padding_groups = ", value},
		context.temp_allocator))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&issues)
	testing.expect_value(t, error, nil)
	padding, matched := settings.process_padding(&s, "NVIM.EXE")
	testing.expect(t, matched)
	testing.expect_value(t, padding, 8)
}

@(test)
process_groups_keep_incomplete_new_entries_as_drafts_and_validate_each_field :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	process_fixture(t, &p)
	testing.expect(t, ui.editor_reveal(&p, "process.group.0.add"))
	testing.expect_value(t, ui.editor_process_activate(&p, ui.editor_row(&p)), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_row(&p).key, "process.group.3.name")
	process_edit(t, &p, "process.group.3.name", "Focus")
	_, problem := ui.editor_process_value(&p)
	testing.expect(t, problem != "")
	process_edit(t, &p, "process.group.3.program.1", "claude")
	value: string
	value, problem = ui.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_suffix(value, "Focus:12:claude"))
	for invalid in ([?]string{"foo,bar", "x;y", "C:\\tool.exe", "*.exe", "line\nnext"}) {
		process_edit(t, &p, "process.group.3.program.1", invalid)
		_, problem = ui.editor_process_value(&p)
		testing.expect(t, problem != "")
	}
	process_edit(t, &p, "process.group.3.program.1", "claude")
	for invalid in ([?]string{"-1", "1025", "1.5", "bad", ""}) {
		process_edit(t, &p, "process.group.3.padding", invalid)
		_, problem = ui.editor_process_value(&p)
		testing.expect(t, problem != "")
	}
	process_edit(t, &p, "process.group.3.padding", "1024")
	_, problem = ui.editor_process_value(&p)
	testing.expect_value(t, problem, "")
}

@(test)
process_groups_add_remove_programs_without_reusing_keys_or_losing_other_drafts :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	process_fixture(t, &p)
	testing.expect(t, ui.editor_reveal(&p, "process.group.1.add"))
	_ = ui.editor_process_activate(&p, ui.editor_row(&p))
	key := strings.clone(ui.editor_row(&p).key, context.temp_allocator)
	process_edit(t, &p, key, "NVIM.exe")
	_, problem := ui.editor_process_value(&p)
	testing.expect_value(t, problem, "This program is already in the group.")
	process_edit(t, &p, key, "helix")
	_ = ui.editor_process_program_remove(&p, "process.group.1.program.1")
	value: string
	value, problem = ui.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(value, "Editors:0:vim,helix"))
	testing.expect(t, ui.editor_reveal(&p, "process.group.1.add"))
	_ = ui.editor_process_activate(&p, ui.editor_row(&p))
	testing.expect(t, ui.editor_row(&p).key != key)
	copy: ui.Editor
	defer ui.editor_destroy(&copy)
	testing.expect_value(t, ui.editor_process_load(&copy, "Editors:0:nvim,vim;Tools:8:less,nvim", 12), nil)
	testing.expect_value(t, ui.editor_process_copy_draft(&p, &copy), nil)
	testing.expect_value(t, len(copy.rows), len(p.rows))
	testing.expect_value(t, copy.process_expanded, p.process_expanded)
}

@(test)
process_groups_drag_escape_and_required_delete_outcome :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	process_fixture(t, &p)
	l := ui.editor_layout({0, 0, 1100, 900}, 1)
	p.visible_rows = l.rows
	testing.expect(t, ui.editor_reveal(&p, "process.group.1"))
	parts := ui.editor_process_parts(ui.editor_row_parts(&p, l, p.selected).row, 1)
	testing.expect_value(t, ui.editor_press(&p, l, nil, parts.handle.x + 4, parts.handle.y + 4, false),
		ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.drag, ui.Editor_Drag.Process_Order)
	_ = ui.editor_key(&p, {key = .Escape, pressed = true})
	testing.expect_value(t, p.drag, ui.Editor_Drag.None)
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.None)
	_ = ui.editor_press(&p, l, nil, parts.remove.x + 4, parts.remove.y + 4, false)
	testing.expect_value(t, p.process_remove, 1)
	value, problem := ui.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(value, "Editors:"))
	ui.editor_process_group_remove(&p, 1)
	ui.editor_process_group_remove(&p, 2)
	value, problem = ui.editor_process_value(&p)
	testing.expect_value(t, value, "")
	testing.expect_value(t, problem, "")
}

@(private)
Process_Failure_Allocator :: struct {backing: runtime.Allocator, remaining: int}

@(private)
process_failure_allocate :: proc(
	data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location,
) -> ([]u8, runtime.Allocator_Error) {
	failure := cast(^Process_Failure_Allocator)data
	if size > 0 && (mode == .Alloc || mode == .Alloc_Non_Zeroed ||
	   mode == .Resize || mode == .Resize_Non_Zeroed) {
		if failure.remaining == 0 {return nil, .Out_Of_Memory}
		failure.remaining -= 1
	}
	return failure.backing.procedure(failure.backing.data, mode, size, alignment,
		old_memory, old_size, location)
}

@(test)
process_groups_partial_load_and_caption_allocation_failures_are_safe :: proc(t: ^testing.T) {
	backing := context.allocator
	for limit in 0 ..< 100 {
		failure := Process_Failure_Allocator{backing, limit}
		context.allocator = {process_failure_allocate, &failure}
		p: ui.Editor
		_ = ui.editor_process_load(&p, "Editors:0:nvim,vim;Tools:8:less", 12)
		ui.editor_destroy(&p)
		context.allocator = backing
	}
	for limit in 0 ..< 2 {
		p: ui.Editor
		process_fixture(t, &p)
		testing.expect(t, ui.editor_reveal(&p, "process.group.1.name"))
		p.focus = .Control
		ui.field_set(&p.value, "Replacement")
		failure := Process_Failure_Allocator{backing, limit}
		context.allocator = {process_failure_allocate, &failure}
		kept := ui.editor_process_capture(&p)
		context.allocator = backing
		testing.expect(t, !kept)
		testing.expect(t, p.error)
		testing.expect_value(t, ui.editor_row(&p).value, "Editors")
		for row in p.rows {
			if row.process == 1 && row.process_field == .Group {
				testing.expect_value(t, row.title, "Editors")
			}
		}
		ui.editor_destroy(&p)
	}
}

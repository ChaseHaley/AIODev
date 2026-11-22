package views_test

import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:render"
import "aio:settings"
import "aio:views"
import "base:runtime"
import "core:strings"
import "core:testing"
import "core:time"
import fixtures "../fixtures"
import "cosmos:ui"
import "cosmos:testkit"

@(private)
process_fixture :: proc(t: ^testing.T, p: ^views.Editor) {
	testing.expect_value(t, views.editor_process_load(p, "Editors:0:nvim,vim;Tools:8:less,nvim", 12), nil)
	views.editor_filter(p)
}

@(private)
process_edit :: proc(t: ^testing.T, p: ^views.Editor, key, value: string) {
	testing.expect(t, views.editor_reveal(p, views.Reveal_Row{key}))
	views.editor_focus_row(p)
	ui.field_set(&p.value, value)
	testing.expect(t, views.editor_process_capture(p))
}

@(test)
process_groups_round_trip_and_order_change_real_matching :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	process_fixture(t, &p)
	value, problem := views.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, value, "Editors:0:nvim,vim;Tools:8:less,nvim")
	views.editor_process_move(&p, 2, 0)
	value, problem = views.editor_process_value(&p)
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
	p: views.Editor
	defer views.editor_destroy(&p)
	process_fixture(t, &p)
	testing.expect(t, views.editor_reveal(&p, views.Reveal_Row{"process.group.0.add"}))
	testing.expect_value(t, views.editor_process_activate(&p, views.editor_row(&p)), views.Editor_Outcome.Changed)
	testing.expect_value(t, views.editor_row(&p).key, "process.group.3.name")
	process_edit(t, &p, "process.group.3.name", "Focus")
	_, problem := views.editor_process_value(&p)
	testing.expect(t, problem != "")
	process_edit(t, &p, "process.group.3.program.1", "claude")
	value: string
	value, problem = views.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_suffix(value, "Focus:12:claude"))
	for invalid in ([?]string{"foo,bar", "x;y", "C:\\tool.exe", "*.exe", "line\nnext"}) {
		process_edit(t, &p, "process.group.3.program.1", invalid)
		_, problem = views.editor_process_value(&p)
		testing.expect(t, problem != "")
	}
	process_edit(t, &p, "process.group.3.program.1", "claude")
	for invalid in ([?]string{"-1", "1025", "1.5", "bad", ""}) {
		process_edit(t, &p, "process.group.3.padding", invalid)
		_, problem = views.editor_process_value(&p)
		testing.expect(t, problem != "")
	}
	process_edit(t, &p, "process.group.3.padding", "1024")
	_, problem = views.editor_process_value(&p)
	testing.expect_value(t, problem, "")
}

@(test)
process_groups_rows_below_a_focused_field_stay_visible :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme := views.theme_from(testkit.bundled_theme("studio-dark"), fixtures.default_interface())
	p: views.Editor
	defer views.editor_destroy(&p)
	process_fixture(t, &p)
	page := views.editor_layout({0, 0, 1000, 800}, 1)
	views.editor_fit(&p, page)
	testing.expect(t, views.editor_reveal(&p, views.Reveal_Row{"process.group.0.add"}))
	_ = views.editor_process_activate(&p, views.editor_row(&p))
	testing.expect_value(t, views.editor_row(&p).key, "process.group.3.name")
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Control)
	p.scroll = 0
	testing.expect_value(t, views.editor_draw(&p, page, &list, &text, theme, true), render.Build_Status.Ok)
	// Each label below the focused field must paint inside its layer's clip, not the field's.
	for key in ([?]string{"process.group.3.padding", "process.group.3.add", "process.group.0.add"}) {
		row: render.Rect
		for item, index in p.items {
			if item.row >= 0 && p.rows[item.row].key == key {row = views.editor_row_parts(&p, page, index).row}
		}
		if !testing.expectf(t, row.height > 0, "%s is not laid out", key) {continue}
		visible := 0
		for layer in list.layers {
			c := layer.clip
			for glyph in list.glyphs[layer.glyph_start:][:layer.glyph_count] {
				x, y := glyph.rect.x + glyph.rect.width / 2, glyph.rect.y + glyph.rect.height / 2
				in_row := y >= row.y && y < row.y + row.height
				if in_row && x >= c.x && x < c.x + c.width && y >= c.y && y < c.y + c.height {visible += 1}
			}
		}
		testing.expectf(t, visible > 0, "%s draws no visible text", key)
	}
}

@(test)
process_groups_add_remove_programs_without_reusing_keys_or_losing_other_drafts :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	process_fixture(t, &p)
	testing.expect(t, views.editor_reveal(&p, views.Reveal_Row{"process.group.1.add"}))
	_ = views.editor_process_activate(&p, views.editor_row(&p))
	key := strings.clone(views.editor_row(&p).key, context.temp_allocator)
	process_edit(t, &p, key, "NVIM.exe")
	_, problem := views.editor_process_value(&p)
	testing.expect_value(t, problem, "This program is already in the group.")
	process_edit(t, &p, key, "helix")
	_ = views.editor_process_program_remove(&p, "process.group.1.program.1")
	value: string
	value, problem = views.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(value, "Editors:0:vim,helix"))
	testing.expect(t, views.editor_reveal(&p, views.Reveal_Row{"process.group.1.add"}))
	_ = views.editor_process_activate(&p, views.editor_row(&p))
	testing.expect(t, views.editor_row(&p).key != key)
	copy: views.Editor
	defer views.editor_destroy(&copy)
	testing.expect_value(t, views.editor_process_load(&copy, "Editors:0:nvim,vim;Tools:8:less,nvim", 12), nil)
	testing.expect_value(t, views.editor_process_copy_draft(&p, &copy), nil)
	testing.expect_value(t, len(copy.rows), len(p.rows))
	testing.expect_value(t, copy.process_expanded, p.process_expanded)
}

@(test)
process_groups_drag_escape_and_required_delete_outcome :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	process_fixture(t, &p)
	l := views.editor_layout({0, 0, 1100, 900}, 1)
	views.editor_fit(&p, l)
	testing.expect(t, views.editor_reveal(&p, views.Reveal_Row{"process.group.1"}))
	row := views.editor_row_parts(&p, l, p.selected).row
	parts := views.editor_block_parts(row, 1)
	testing.expect_value(t, views.editor_press(&p, l, nil, parts.handle.x + 4, parts.handle.y + 4, false),
		views.Editor_Outcome.Changed)
	testing.expect(t, views.editor_order_dragging(&p, .Process_Groups))
	// Escape mid drag, after the pointer opened another slot, leaves no drag behind: the slot, the
	// lift and the release all end with it, and the group eases back to its own place.
	testing.expect(t, views.editor_drag(&p, l, nil, parts.handle.x + 4, row.y + row.height * 3))
	testing.expect(t, views.editor_order_target(&p) > 0)
	_ = views.editor_key(&p, {key = .Escape, pressed = true})
	testing.expect(t, !views.editor_dragging(&p))
	testing.expect_value(t, views.editor_order_target(&p), -1)
	testing.expect(t, !views.editor_drag(&p, l, nil, parts.handle.x + 4, row.y + row.height * 3))
	testing.expect_value(t, views.editor_release(&p), views.Editor_Outcome.None)
	views.editor_profiles_animate(&p, false, test_frame(time.tick_now()))
	testing.expect(t, !views.editor_profiles_animating(&p))
	testing.expect_value(t, views.editor_row_parts(&p, l, p.selected).row.y, row.y)
	testing.expect_value(t, views.editor_press(&p, l, nil, parts.remove.x + 4, parts.remove.y + 4, false),
		views.Editor_Outcome.Process_Remove)
	request := views.editor_request_take(&p)
	defer views.editor_request_destroy(&request)
	testing.expect_value(t, request.(views.Process_Remove_Request).group, 1)
	value, problem := views.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(value, "Editors:"))
	views.editor_process_group_remove(&p, 1)
	views.editor_process_group_remove(&p, 2)
	value, problem = views.editor_process_value(&p)
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
		p: views.Editor
		_ = views.editor_process_load(&p, "Editors:0:nvim,vim;Tools:8:less", 12)
		views.editor_destroy(&p)
		context.allocator = backing
	}
	for limit in 0 ..< 2 {
		p: views.Editor
		process_fixture(t, &p)
		testing.expect(t, views.editor_reveal(&p, views.Reveal_Row{"process.group.1.name"}))
		views.editor_focus_row(&p)
		ui.field_set(&p.value, "Replacement")
		failure := Process_Failure_Allocator{backing, limit}
		context.allocator = {process_failure_allocate, &failure}
		kept := views.editor_process_capture(&p)
		context.allocator = backing
		testing.expect(t, !kept)
		testing.expect(t, p.error)
		testing.expect_value(t, views.editor_row(&p).value, "Editors")
		for row in p.rows {
			if row.process == 1 && row.process_field == .Group {
				testing.expect_value(t, row.title, "Editors")
			}
		}
		views.editor_destroy(&p)
	}
}

@(test)
process_groups_drag_reflows_whole_groups_like_profiles :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	process_fixture(t, &p)
	l := views.editor_layout({0, 0, 1100, 900}, 1)
	views.editor_fit(&p, l)
	testing.expect(t, views.editor_reveal(&p, views.Reveal_Row{"process.group.1.name"}))
	header := profile_item_index(&p, "process.group.1")
	name := profile_item_index(&p, "process.group.1.name")
	tools := profile_item_index(&p, "process.group.2")
	header_row := views.editor_row_parts(&p, l, header).row
	name_row := views.editor_row_parts(&p, l, name).row
	tools_row := views.editor_row_parts(&p, l, tools).row
	handle := views.editor_block_parts(header_row, 1).handle
	x, y := handle.x + handle.width / 2, handle.y + handle.height / 2
	testing.expect_value(t, views.editor_press(&p, l, nil, x, y, false), views.Editor_Outcome.Changed)
	testing.expect(t, views.editor_order_dragging(&p, .Process_Groups))

	// The grabbed group follows the pointer with its fields.
	testing.expect(t, views.editor_drag(&p, l, nil, x, y + 10))
	testing.expect(t, abs(views.editor_row_parts(&p, l, header).row.y - header_row.y - 10) < 0.01)
	testing.expect(t, abs(views.editor_row_parts(&p, l, name).row.y - name_row.y - 10) < 0.01)
	testing.expect_value(t, views.editor_row_parts(&p, l, tools).row.y, tools_row.y)

	// Past the next group's midpoint, that group eases up into the grabbed group's place.
	testing.expect(t, views.editor_drag(&p, l, nil, x, tools_row.y + tools_row.height * 2))
	testing.expect(t, views.editor_profiles_animate(&p, true, test_frame(time.tick_now())))
	testing.expect(t, views.editor_profiles_animating(&p))
	views.editor_profiles_animate(&p, false, test_frame(time.tick_now()))
	testing.expect_value(t, views.editor_row_parts(&p, l, tools).row.y, header_row.y)

	// Dropping saves the new order, then every row settles on its own line.
	testing.expect_value(t, views.editor_release(&p), views.Editor_Outcome.Process_Save)
	value, problem := views.editor_process_value(&p)
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(value, "Tools:"))
	testing.expect(t, views.editor_profiles_animating(&p))
	views.editor_profiles_animate(&p, false, test_frame(time.tick_now()))
	testing.expect(t, !views.editor_profiles_animating(&p))
}

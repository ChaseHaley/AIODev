package app_test

import app "../../src"
import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private="file")
Picker152_Fixture :: struct {
	state: app.App,
	directory, path: string,
}

@(private="file")
picker152_init :: proc(t: ^testing.T, f: ^Picker152_Fixture, suffix: string) -> bool {
	var_error: os.Error
	f.directory, var_error = os.make_directory_temp("", "aio-picker152-*", context.allocator)
	if !testing.expect_value(t, var_error, nil) {return false}
	f.path = strings.concatenate({f.directory, "/settings.ini"})
	if !testing.expect_value(t, os.write_entire_file(f.path,
		"shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"), nil) {return false}
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.Picker152.%d.%s", os.get_pid(), suffix)
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id),
		platform.Init_Result.Primary) {return false}
	f.state.platform_ready = true
	if !testing.expect(t, app.app_init(&f.state)) {return false}
	f.state.animations = false
	for _ in 0..<20 {
		if !testing.expect(t, app.workspace_create_empty(&f.state) != nil) {return false}
	}
	app.workspace_picker_open(&f.state, f.state.windows[0])
	return true
}

@(private="file")
picker152_destroy :: proc(t: ^testing.T, f: ^Picker152_Fixture) {
	app.app_destroy(&f.state)
	if f.path != "" {testing.expect_value(t, os.remove(f.path), nil); delete(f.path)}
	if f.directory != "" {testing.expect_value(t, os.remove(f.directory), nil); delete(f.directory)}
}

@(private="file")
picker152_compare :: proc(t: ^testing.T, a, b: ^Picker152_Fixture) {
	wa, wb := a.state.windows[0], b.state.windows[0]
	pa, pb := &wa.workspace_picker, &wb.workspace_picker
	testing.expect_value(t, pa.mode, pb.mode)
	testing.expect_value(t, pa.selected, pb.selected)
	testing.expect_value(t, pa.scroll, pb.scroll)
	testing.expect_value(t, pa.target_id, pb.target_id)
	testing.expect_value(t, pa.rename_error, pb.rename_error)
	testing.expect_value(t, ui.field_string(&pa.query), ui.field_string(&pb.query))
	testing.expect_value(t, ui.field_string(&pa.saved_query), ui.field_string(&pb.saved_query))
	testing.expect_value(t, len(pa.rows), len(pb.rows))
	row := app.workspace_picker_row_rect(wa, pa.selected)
	testing.expect_value(t, row, app.workspace_picker_row_rect(wb, pb.selected))
	x, y := row.x+row.width/2, row.y+row.height/2
	testing.expect_value(t, app.workspace_picker_hit(wa, x, y), app.workspace_picker_hit(wb, x, y))
	if pa.mode != .Closed {
		testing.expect_value(t, app.workspace_picker_hit(wa, x, y), pa.selected)
	}
	before := pb^
	render.draw_list_reset(&wb.list)
	testing.expect_value(t, app.workspace_picker_draw(&b.state, wb), glyphs.Result.Ok)
	testing.expect_value(t, pb.mode, before.mode)
	testing.expect_value(t, pb.selected, before.selected)
	testing.expect_value(t, pb.scroll, before.scroll)
	testing.expect_value(t, pb.target_id, before.target_id)
}

@(test)
workspace152_event_order_resize_and_hit_agree_without_intervening_draws :: proc(t: ^testing.T) {
	a, b: Picker152_Fixture
	defer picker152_destroy(t, &a)
	defer picker152_destroy(t, &b)
	if !picker152_init(t, &a, "no-draw") || !picker152_init(t, &b, "draw") {return}
	wa, wb := a.state.windows[0], b.state.windows[0]
	for scale in ([?]u32{96, 144, 168, 192}) {
		for height in ([?]i32{240, 800, 300}) {
			for f in ([?]^Picker152_Fixture{&a, &b}) {
				w := f.state.windows[0]
				app.handle_event(&f.state, platform.Dpi_Event{window = w.id, dpi = scale})
				app.handle_event(&f.state, platform.Resize_Event{window = w.id,
					width = i32(f32(180)*w.scale), height = i32(f32(height)*w.scale)})
			}
			picker152_compare(t, &a, &b)
			for _ in 0..<app.workspace_picker_count(wa)+2 {
				app.handle_event(&a.state, platform.Key_Event{window = wa.id, key = .Arrow_Down, pressed = true})
				app.handle_event(&b.state, platform.Key_Event{window = wb.id, key = .Arrow_Down, pressed = true})
				picker152_compare(t, &a, &b)
			}
			for f in ([?]^Picker152_Fixture{&a, &b}) {
				app.workspace_row_rename_open(&f.state, f.state.windows[0], 21)
			}
			picker152_compare(t, &a, &b)
			for key in ([?]input.Key{.Escape, .F2, .Escape, .Arrow_Right, .Arrow_Down, .Enter}) {
				app.handle_event(&a.state, platform.Key_Event{window = wa.id, key = key, pressed = true})
				app.handle_event(&b.state, platform.Key_Event{window = wb.id, key = key, pressed = true})
				picker152_compare(t, &a, &b)
			}
			for _ in 0..<8 {
				app.handle_event(&a.state, platform.Mouse_Wheel_Event{window = wa.id, delta_y = -1})
				app.handle_event(&b.state, platform.Mouse_Wheel_Event{window = wb.id, delta_y = -1})
				picker152_compare(t, &a, &b)
			}
			for f in ([?]^Picker152_Fixture{&a, &b}) {
				app.workspace_icon_color_open(&f.state, f.state.windows[0])
			}
			for key in ([?]input.Key{.End, .Arrow_Down, .Escape, .Escape}) {
				app.handle_event(&a.state, platform.Key_Event{window = wa.id, key = key, pressed = true})
				app.handle_event(&b.state, platform.Key_Event{window = wb.id, key = key, pressed = true})
				picker152_compare(t, &a, &b)
			}
		}
	}
}

@(test)
workspace152_mode_changes_keep_filter_target_and_emoji_delivery_owned :: proc(t: ^testing.T) {
	f: Picker152_Fixture
	defer picker152_destroy(t, &f)
	if !picker152_init(t, &f, "transitions") {return}
	s, w := &f.state, f.state.windows[0]
	app.handle_event(s, platform.Text_Event{window = w.id, text = "Workspace 2"})
	app.workspace_row_icon_open(s, w, 2)
	app.workspace_icon_color_open(s, w)
	app.workspace_row_icon_open(s, w, 20)
	testing.expect_value(t, ui.field_string(&w.workspace_picker.saved_query), "Workspace 2")
	testing.expect_value(t, w.workspace_picker.target_id, u32(20))
	app.handle_event(s, platform.Focus_Event{window = w.id, focused = false})
	app.handle_event(s, platform.Text_Event{window = w.id, text = "🌈"})
	app.handle_event(s, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect_value(t, app.workspace_find(s, 20).icon.emoji, "🌈")
	testing.expect_value(t, w.workspace.icon.emoji, "")
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "Workspace 2")
	app.workspace_row_icon_open(s, w, 20)
	app.workspace_row_rename_open(s, w, 20)
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "Workspace 2")
	app.handle_event(s, platform.Focus_Event{window = w.id, focused = false})
	testing.expect_value(t, w.workspace_picker.mode, app.Workspace_Picker_Mode.Closed)
	testing.expect_value(t, w.workspace_picker.target_id, u32(0))
	app.workspace_picker_open(s, w)
	app.workspace_row_icon_open(s, w, 20)
	app.workspace_icon_color_open(s, w)
	testing.expect(t, app.workspace_discard_empty(s, app.workspace_find(s, 20)))
	testing.expect_value(t, w.workspace_picker.mode, app.Workspace_Picker_Mode.List)
	testing.expect_value(t, w.workspace_picker.target_id, u32(0))
	testing.expect_value(t, w.workspace.icon.tint, 0)
	app.workspace_picker_cancel(w)
	testing.expect_value(t, w.workspace_picker.target_id, u32(0))
}

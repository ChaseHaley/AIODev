package app_test

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:platform"
import "aio:term"
import "aio:ui"

@(private)
Palette_Fixture :: struct {
	state: app.App,
	directory, path: string,
}

@(private, require_results)
palette_fixture_create :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> bool {
	err: os.Error
	f.directory, err = os.make_directory_temp("", "aio-palette-*", context.allocator)
	if !testing.expect_value(t, err, nil) { return false }
	f.path = strings.concatenate({f.directory, "/settings.ini"})
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile -Command \"Start-Sleep -Seconds 60\"\n"+
		"interface.font_size = 12\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(f.path, settings), nil) { return false }
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.Palette.%s.%d", name, os.get_pid())
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id),
		platform.Init_Result.Primary) { return false }
	f.state.platform_ready = true
	if !testing.expect(t, app.app_init(&f.state)) { return false }
	workspace, allocation_error := new(app.Workspace)
	if !testing.expect_value(t, allocation_error, nil) { return false }
	if _, append_error := append(&f.state.workspaces, workspace); append_error != nil {
		free(workspace)
		testing.expect_value(t, append_error, nil)
		return false
	}
	if !testing.expect(t, app.tab_create(&f.state, workspace)) { return false }
	if !testing.expect(t, app.window_open(&f.state, workspace)) { return false }
	app.tick(&f.state)
	f.state.animations = false
	app.update_motion(&f.state)
	return true
}

@(private)
palette_fixture_destroy :: proc(t: ^testing.T, f: ^Palette_Fixture) {
	app.app_destroy(&f.state)
	if f.path != "" { testing.expect_value(t, os.remove(f.path), nil); delete(f.path) }
	if f.directory != "" { testing.expect_value(t, os.remove(f.directory), nil); delete(f.directory) }
}

@(test)
palette_routes_input_and_render_only_to_its_window :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "routing") { return }
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	app.pane_split(s, first, .Right)
	app.pane_split(s, second, .Right)
	app.handle_event(s, platform.Focus_Event{first.id, true})
	app.handle_event(s, platform.Focus_Event{second.id, true})
	app.window_render(s, second)
	layers := slice.clone(second.list.layers[:])
	defer delete(layers)
	rects := slice.clone(second.list.rects[:])
	defer delete(rects)
	glyphs := slice.clone(second.list.glyphs[:])
	defer delete(glyphs)
	app.run_action(s, first, .Command_Palette)
	app.update_motion(s)
	testing.expect(t, app.palette_active(s, first) && app.palette_visible(s, first))
	testing.expect(t, !app.palette_active(s, second) && !app.palette_visible(s, second))
	testing.expect(t, !app.palette_active(s, nil) && !app.palette_visible(s, nil))
	app.window_render(s, first)
	app.window_render(s, second)
	panel := ui.palette_layout(&s.palette, f32(first.width), f32(first.height), first.scale).panel
	owner_drawn := false
	for rect in first.list.rects { owner_drawn ||= rect.rect == panel && rect.color == s.theme.surface }
	testing.expect(t, owner_drawn)
	testing.expect(t, slice.equal(layers, second.list.layers[:]))
	testing.expect(t, slice.equal(rects, second.list.rects[:]))
	testing.expect(t, slice.equal(glyphs, second.list.glyphs[:]))
	testing.expect(t, !first.views[0].style.focused)
	testing.expect(t, second.views[1].style.focused)
	app.palette_close(s, second)
	testing.expect(t, app.palette_active(s, first))
	app.handle_event(s, platform.Text_Event{first.id, "font"})
	app.run_action(s, second, .Find)
	app.handle_event(s, platform.Text_Event{second.id, "needle"})
	app.handle_event(s, platform.Key_Event{window = second.id, key = .Backspace, pressed = true})
	testing.expect_value(t, ui.field_string(&second.find.query), "needl")
	testing.expect_value(t, ui.palette_query(&s.palette), "font")
	selected, scroll := s.palette.selected, s.palette.scroll
	l := ui.palette_layout(&s.palette, f32(first.width), f32(first.height), first.scale)
	app.handle_event(s, platform.Mouse_Move_Event{window = second.id,
		x = i32(l.list.x+20), y = i32(l.list.y+2*l.row_height)})
	app.handle_event(s, platform.Mouse_Wheel_Event{window = second.id, delta_y = -1})
	app.handle_event(s, platform.Mouse_Button_Event{window = second.id, button = .Left,
		pressed = true, x = i32(l.panel.x-10), y = i32(l.panel.y+20)})
	app.handle_event(s, platform.Mouse_Button_Event{window = second.id, button = .Left,
		x = i32(l.panel.x-10), y = i32(l.panel.y+20)})
	testing.expect(t, app.palette_active(s, first))
	testing.expect_value(t, s.palette.selected, selected)
	testing.expect_value(t, s.palette.scroll, scroll)
	testing.expect_value(t, ui.palette_query(&s.palette), "font")
	app.editor_open(s, second)
	testing.expect(t, app.settings_active(second))
	testing.expect(t, app.palette_active(s, first))
	app.handle_event(s, platform.Text_Event{second.id, "line height"})
	testing.expect_value(t, ui.field_string(&second.editor.filter), "line height")
	testing.expect_value(t, ui.palette_query(&s.palette), "font")
	app.palette_release(s, first)
	app.update_motion(s)
	app.window_render(s, second)
	settings_layers := slice.clone(second.list.layers[:])
	defer delete(settings_layers)
	settings_rects := slice.clone(second.list.rects[:])
	defer delete(settings_rects)
	settings_glyphs := slice.clone(second.list.glyphs[:])
	defer delete(settings_glyphs)
	app.palette_open(s, first)
	app.update_motion(s)
	app.window_render(s, second)
	testing.expect(t, slice.equal(settings_layers, second.list.layers[:]))
	testing.expect(t, slice.equal(settings_rects, second.list.rects[:]))
	testing.expect(t, slice.equal(settings_glyphs, second.list.glyphs[:]))
}

@(test)
palette_transfer_and_lifecycle_preserve_other_window_content :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "lifecycle") { return }
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	first_workspace, first_tree := first.workspace, first.tree
	first_selected, first_focus := first.workspace.selected, first.tree.focus
	first_pid, second_pid := term.process_id(s.sessions[0].session), term.process_id(s.sessions[1].session)
	app.run_action(s, first, .Find)
	app.handle_event(s, platform.Text_Event{first.id, "retained"})
	app.palette_open(s, first)
	s.palette.query.dragging = true
	app.rename_open(s, second, true)
	app.handle_event(s, platform.Text_Event{second.id, "unsaved"})
	testing.expect(t, app.palette_active(s, first))
	app.run_action(s, second, .Command_Palette)
	testing.expect(t, app.palette_active(s, second) && !app.palette_visible(s, first))
	testing.expect(t, !s.palette.query.dragging && !second.rename_open)
	testing.expect(t, first.workspace == first_workspace && first.tree == first_tree)
	testing.expect_value(t, first.workspace.selected, first_selected)
	testing.expect_value(t, first.tree.focus, first_focus)
	testing.expect_value(t, ui.field_string(&first.find.query), "retained")
	testing.expect_value(t, len(first.workspace.tabs), 1)
	testing.expect_value(t, len(s.sessions), 2)
	testing.expect_value(t, term.process_id(s.sessions[0].session), first_pid)
	testing.expect_value(t, term.process_id(s.sessions[1].session), second_pid)
	testing.expect_value(t, app.selected_tab(second.workspace).name, "")
	s.palette.query.dragging = true
	app.rename_open(s, first, true)
	app.handle_event(s, platform.Focus_Event{first.id, false})
	testing.expect(t, !first.rename_open)
	testing.expect(t, app.palette_active(s, second) && s.palette.query.dragging)
	app.tab_menu_open(s, first, 0, 10, 20)
	app.handle_event(s, platform.Focus_Event{first.id, false})
	testing.expect(t, !first.tab_menu.open && app.palette_active(s, second))
	app.pane_split(s, first, .Right)
	app.tab_close_request(s, first, 0)
	testing.expect(t, first.pending_close.confirm.open && app.palette_active(s, second))
	app.handle_event(s, platform.Focus_Event{first.id, false})
	testing.expect(t, !first.pending_close.confirm.open && first.pending_close.confirm.motion.value == 0)
	testing.expect(t, app.palette_active(s, second) && s.palette.query.dragging)
	testing.expect_value(t, len(s.sessions), 3)
	app.palette_close(s, first)
	testing.expect(t, app.palette_active(s, second))
	app.window_close(s, first)
	testing.expect(t, app.palette_active(s, second) && s.palette.query.dragging)
	testing.expect_value(t, len(s.sessions), 3)
	app.handle_event(s, platform.Focus_Event{second.id, false})
	testing.expect(t, !s.palette.open && !s.palette.query.dragging)
	testing.expect_value(t, s.palette_window, platform.Window_Id(0))
	app.palette_open(s, second)
	app.handle_event(s, platform.Key_Event{window = second.id, key = .Escape, pressed = true})
	testing.expect(t, !app.palette_active(s, second) && second.suppressed_key != nil)
	app.handle_event(s, platform.Key_Event{window = second.id, key = .Escape})
	testing.expect(t, second.suppressed_key == nil)
	app.palette_open(s, second)
	second.pane_drag.pressed, second.pane_drag.active = true, true
	second.tab_drag.pressed, second.tab_drag.active = true, true
	app.focus_leave(s, second)
	testing.expect(t, !app.palette_visible(s, second) && s.palette_window == 0)
	testing.expect(t, second.pane_drag.pressed && second.pane_drag.active)
	testing.expect(t, second.tab_drag.pressed && second.tab_drag.active)
	second.pane_drag, second.tab_drag = {}, {}
	app.palette_open(s, second)
	app.update_motion(s)
	app.palette_close(s, second)
	testing.expect(t, app.palette_visible(s, second) && !app.palette_active(s, second))
	app.window_close(s, second)
	testing.expect_value(t, s.palette_window, platform.Window_Id(0))
	testing.expect(t, !s.palette.open && s.palette.motion.value == 0)
	testing.expect_value(t, len(s.sessions), 3)
	if !testing.expect(t, app.window_open(s, first_workspace)) { return }
	testing.expect(t, !app.palette_visible(s, s.windows[0]))
	testing.expect_value(t, term.process_id(s.sessions[0].session), first_pid)
}

@(test)
palette_fade_invalidates_only_owner_and_releases_after_settling :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "animation") { return }
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	app.palette_open(s, first)
	app.update_motion(s)
	app.palette_close(s, first)
	s.animations = true
	s.palette.motion = {from = 1, value = 1, target = 0,
		started = time.tick_add(time.tick_now(), -45*time.Millisecond), duration = 90*time.Millisecond}
	first.dirty, second.dirty = false, false
	app.update_motion(s)
	testing.expect(t, first.dirty && !second.dirty)
	testing.expect(t, app.palette_visible(s, first) && !app.palette_active(s, first))
	testing.expect(t, !app.palette_visible(s, second))
	s.palette.motion.started = time.tick_add(time.tick_now(), -time.Second)
	app.update_motion(s)
	testing.expect_value(t, s.palette_window, platform.Window_Id(0))
	testing.expect(t, !app.palette_visible(s, first))
	testing.expect(t, !app.motion_active(s))
}

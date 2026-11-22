package views_test

import "aio:commands"
import "aio:views"
import "core:strings"
import "core:testing"
import "cosmos:input"
import "cosmos:ui"

@(private)
binding_palette :: proc(t: ^testing.T, p: ^views.Palette) -> commands.Registry {
	r := commands.create()
	testing.expect_value(t, commands.register(&r, {
		id = 1, name = "test.alpha", title = "Alpha", shortcuts = {
			items = {{.K, {.Control}}, {.K, {.Control, .Shift}}}, count = 2,
		},
	}), commands.Error.None)
	testing.expect_value(t, views.palette_init(p, nil), nil)
	views.palette_open_mode(p, &r, .Commands)
	return r
}

// The open shortcut row, or nil.
@(private)
binding_edit :: proc(p: ^views.Palette) -> ^views.Shortcut_Edit {
	binding, open := &p.edit.(views.Shortcut_Edit)
	return open ? binding : nil
}

@(test)
palette_shortcut_replaces_one_alternative_and_cancels_without_running :: proc(t: ^testing.T) {
	p: views.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer views.palette_destroy(&p)
	outcome, _ := views.palette_key(&p, &r, press(.Enter, {.Control}))
	testing.expect_value(t, outcome, views.Outcome.Changed)
	testing.expect_value(t, views.palette_editing(&p), views.Palette_Edit_Kind.Shortcut)
	views.palette_key(&p, &r, press(.Enter))
	views.palette_key(&p, &r, press(.C, {.Control}))
	outcome, _ = views.palette_key(&p, &r, press(.Enter))
	key, value := chosen_value(&p)
	testing.expect_value(t, outcome, views.Outcome.Set_Setting)
	testing.expect_value(t, key, "keys.test.alpha")
	testing.expect_value(t, value, "Ctrl+C, Ctrl+Shift+K")
	views.palette_saved(&p, false)
	b := binding_edit(&p)
	testing.expect(t, b != nil && views.shortcut_capture_recording(&b.capture), "a refused value stays editable")
	views.palette_key(&p, &r, press(.Escape))
	testing.expect_value(t, views.palette_editing(&p), views.Palette_Edit_Kind.None)
	testing.expect(t, ui.presence_is_open(p.presence))
	id: commands.Command_Id
	outcome, id = views.palette_key(&p, &r, press(.Enter))
	testing.expect_value(t, outcome, views.Outcome.Run)
	testing.expect_value(t, id, commands.Command_Id(1))
}

@(test)
palette_shortcut_add_delete_physical_and_leader_use_settings_capture :: proc(t: ^testing.T) {
	p: views.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer views.palette_destroy(&p)
	p.leader = input.Shortcut{.B, {.Control}}
	views.palette_key(&p, &r, press(.Enter, {.Control}))
	views.palette_key(&p, &r, press(.Arrow_Down))
	views.palette_key(&p, &r, press(.Arrow_Down))
	views.palette_key(&p, &r, press(.Enter))
	views.palette_key(&p, &r, press(.B, {.Control}))
	views.palette_key(&p, &r, press(.X))
	outcome, _ := views.palette_key(&p, &r, press(.Enter))
	_, value := chosen_value(&p)
	testing.expect_value(t, outcome, views.Outcome.Set_Setting)
	testing.expect_value(t, value, "Ctrl+K, Ctrl+Shift+K, Leader+X")
	views.palette_saved(&p, true)
	views.palette_key(&p, &r, press(.Enter, {.Control}))
	outcome, _ = views.palette_key(&p, &r, press(.Delete))
	_, value = chosen_value(&p)
	testing.expect_value(t, outcome, views.Outcome.Set_Setting)
	testing.expect_value(t, value, "Ctrl+Shift+K")
	views.palette_saved(&p, true)
	views.palette_key(&p, &r, press(.Enter, {.Control}))
	views.palette_key(&p, &r, press(.Enter))
	if b := binding_edit(&p); testing.expect(t, b != nil) {b.capture.physical = true}
	e := press(.Q, {.Control})
	e.unshifted = 'a'
	views.palette_key(&p, &r, e)
	views.palette_key(&p, &r, press(.Enter))
	_, value = chosen_value(&p)
	testing.expect(t, strings.contains(value, "Physical+"))
	testing.expect(t, strings.contains(value, "Ctrl+Q"))
}

@(test)
palette_shortcut_control_click_and_reset_preserve_command_activation :: proc(t: ^testing.T) {
	p: views.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer views.palette_destroy(&p)
	l := views.palette_layout(&p, 1000, 800, 1)
	parts := views.palette_binding_parts({l.list.x, l.list.y, l.list.width, l.row_height}, 1)
	outcome, _ := views.palette_mouse_press(&p, &r, l, parts.reset.x + 10, parts.reset.y + 10)
	testing.expect_value(t, outcome, views.Outcome.Changed)
	testing.expect_value(t, views.palette_editing(&p), views.Palette_Edit_Kind.None)
	outcome, _ = views.palette_mouse_press(&p, &r, l, parts.field.x + 20, parts.field.y + 10)
	testing.expect_value(t, outcome, views.Outcome.Changed)
	testing.expect_value(t, views.palette_editing(&p), views.Palette_Edit_Kind.Shortcut)
	views.palette_key(&p, &r, press(.Escape))
	testing.expect_value(t, commands.set_shortcuts(&r, 1, {{.F9, {.Control, .Alt}}}), commands.Error.None)
	outcome, _ = views.palette_mouse_press(&p, &r, l, parts.reset.x + 10, parts.reset.y + 10)
	testing.expect_value(t, outcome, views.Outcome.Set_Setting)
	_, value := chosen_value(&p)
	testing.expect_value(t, value, "Ctrl+K, Ctrl+Shift+K")
	views.palette_saved(&p, true)
	id: commands.Command_Id
	outcome, id = views.palette_mouse_press(&p, &r, l, l.list.x + 50, l.list.y + l.row_height / 2)
	testing.expect_value(t, outcome, views.Outcome.Run)
	testing.expect_value(t, id, commands.Command_Id(1))
}

@(test)
palette_can_assign_a_command_without_an_existing_shortcut :: proc(t: ^testing.T) {
	p: views.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer views.palette_destroy(&p)
	testing.expect_value(t, commands.register(&r, {id = 2, name = "test.unbound", title = "Unbound"}),
	                     commands.Error.None)
	views.palette_text(&p, &r, "Unbound")
	views.palette_key(&p, &r, press(.Enter, {.Control}))
	views.palette_key(&p, &r, press(.Enter))
	views.palette_key(&p, &r, press(.F11, {.Control, .Alt}))
	outcome, _ := views.palette_key(&p, &r, press(.Enter))
	key, value := chosen_value(&p)
	testing.expect_value(t, outcome, views.Outcome.Set_Setting)
	testing.expect_value(t, key, "keys.test.unbound")
	testing.expect_value(t, value, "Ctrl+Alt+F11")
}

@(test)
palette_shortcut_popup_opens_below_its_inline_control :: proc(t: ^testing.T) {
	p: views.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer views.palette_destroy(&p)
	for scale in ([?]f32{1, 1.5, 2}) {
		views.palette_open_mode(&p, &r, .Commands)
		l := views.palette_layout(&p, 1200 * scale, 1200 * scale, scale)
		views.palette_key(&p, &r, press(.Enter, {.Control}))
		row := l.list
		row.height = l.row_height
		parts := views.palette_binding_parts(row, scale)
		popup := views.palette_popup_rect(&p, l)
		testing.expect(t, popup.width > 0)
		testing.expect_value(t, popup.y, parts.field.y + parts.field.height + 4 * scale)
	}
}

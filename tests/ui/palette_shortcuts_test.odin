package ui_test

import "aio:commands"
import "aio:ui"
import "core:strings"
import "core:testing"

@(private)
binding_palette :: proc(t: ^testing.T, p: ^ui.Palette) -> commands.Registry {
	r := commands.create()
	testing.expect_value(t, commands.register(&r, {
		id = 1, name = "test.alpha", title = "Alpha", shortcuts = {
			items = {{.K, {.Control}}, {.K, {.Control, .Shift}}}, count = 2,
		},
	}), commands.Error.None)
	testing.expect_value(t, ui.palette_init(p, nil), nil)
	ui.palette_open_mode(p, &r, .Commands)
	return r
}

@(test)
palette_shortcut_replaces_one_alternative_and_cancels_without_running :: proc(t: ^testing.T) {
	p: ui.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer ui.palette_destroy(&p)
	outcome, _ := ui.palette_key(&p, &r, press(.Enter, {.Control}))
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Shortcut)
	ui.palette_key(&p, &r, press(.Enter))
	ui.palette_key(&p, &r, press(.C, {.Control}))
	outcome, _ = ui.palette_key(&p, &r, press(.Enter))
	key, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, key, "keys.test.alpha")
	testing.expect_value(t, value, "Ctrl+C, Ctrl+Shift+K")
	ui.palette_binding_saved(&p, false)
	testing.expect(t, p.binding.capturing, "a refused value stays editable")
	ui.palette_key(&p, &r, press(.Escape))
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.None)
	testing.expect(t, p.open)
	id: commands.Command_Id
	outcome, id = ui.palette_key(&p, &r, press(.Enter))
	testing.expect_value(t, outcome, ui.Outcome.Run)
	testing.expect_value(t, id, commands.Command_Id(1))
}

@(test)
palette_shortcut_add_delete_physical_and_leader_use_settings_capture :: proc(t: ^testing.T) {
	p: ui.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer ui.palette_destroy(&p)
	p.leader = commands.Shortcut{.B, {.Control}}
	ui.palette_key(&p, &r, press(.Enter, {.Control}))
	ui.palette_key(&p, &r, press(.Arrow_Down))
	ui.palette_key(&p, &r, press(.Arrow_Down))
	ui.palette_key(&p, &r, press(.Enter))
	ui.palette_key(&p, &r, press(.B, {.Control}))
	ui.palette_key(&p, &r, press(.X))
	outcome, _ := ui.palette_key(&p, &r, press(.Enter))
	_, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "Ctrl+K, Ctrl+Shift+K, Leader+X")
	ui.palette_binding_saved(&p, true)
	ui.palette_key(&p, &r, press(.Enter, {.Control}))
	outcome, _ = ui.palette_key(&p, &r, press(.Delete))
	_, value = ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "Ctrl+Shift+K")
	ui.palette_binding_saved(&p, true)
	ui.palette_key(&p, &r, press(.Enter, {.Control}))
	ui.palette_key(&p, &r, press(.Enter))
	p.binding.physical = true
	e := press(.Q, {.Control})
	e.unshifted = 'a'
	ui.palette_key(&p, &r, e)
	ui.palette_key(&p, &r, press(.Enter))
	_, value = ui.palette_chosen_value(&p)
	testing.expect(t, strings.contains(value, "Physical+"))
	testing.expect(t, strings.contains(value, "Ctrl+Q"))
}

@(test)
palette_shortcut_control_click_and_reset_preserve_command_activation :: proc(t: ^testing.T) {
	p: ui.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer ui.palette_destroy(&p)
	l := ui.palette_layout(&p, 1000, 800, 1)
	parts := ui.palette_binding_parts({l.list.x, l.list.y, l.list.width, l.row_height}, 1)
	outcome, _ := ui.palette_mouse_press(&p, &r, l, parts.reset.x + 10, parts.reset.y + 10)
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.None)
	outcome, _ = ui.palette_mouse_press(&p, &r, l, parts.field.x + 20, parts.field.y + 10)
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Shortcut)
	ui.palette_key(&p, &r, press(.Escape))
	testing.expect_value(t, commands.set_shortcuts(&r, 1, {{.F9, {.Control, .Alt}}}), commands.Error.None)
	outcome, _ = ui.palette_mouse_press(&p, &r, l, parts.reset.x + 10, parts.reset.y + 10)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	_, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, value, "Ctrl+K, Ctrl+Shift+K")
	ui.palette_binding_saved(&p, true)
	id: commands.Command_Id
	outcome, id = ui.palette_mouse_press(&p, &r, l, l.list.x + 50, l.list.y + l.row_height / 2)
	testing.expect_value(t, outcome, ui.Outcome.Run)
	testing.expect_value(t, id, commands.Command_Id(1))
}

@(test)
palette_can_assign_a_command_without_an_existing_shortcut :: proc(t: ^testing.T) {
	p: ui.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer ui.palette_destroy(&p)
	testing.expect_value(t, commands.register(&r, {id = 2, name = "test.unbound", title = "Unbound"}),
	                     commands.Error.None)
	ui.palette_text(&p, &r, "Unbound")
	ui.palette_key(&p, &r, press(.Enter, {.Control}))
	ui.palette_key(&p, &r, press(.Enter))
	ui.palette_key(&p, &r, press(.F11, {.Control, .Alt}))
	outcome, _ := ui.palette_key(&p, &r, press(.Enter))
	key, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, key, "keys.test.unbound")
	testing.expect_value(t, value, "Ctrl+Alt+F11")
}

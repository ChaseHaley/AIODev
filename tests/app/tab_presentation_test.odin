package app_test

import "core:testing"
import app "../../src"
import "cosmos:ui"

@(test)
tab_presentation_resize_keeps_storage_and_initialises_only_appended_entries :: proc(
	t: ^testing.T,
) {
	presentation: app.Tab_Presentation
	defer app.tab_presentation_destroy(&presentation)
	app.tab_presentation_init(&presentation)
	if !testing.expect(t, app.tab_presentation_resize(&presentation, 3)) {return}
	testing.expect_value(t, len(presentation.tab_offsets), 3)
	testing.expect_value(t, len(presentation.tab_positions), 3)
	presentation.tab_positions[1] = ui.Motion{from = 4, value = 5, target = 6}
	positions := raw_data(presentation.tab_positions)
	if !testing.expect(t, app.tab_presentation_resize(&presentation, 3)) {return}
	// Relayout at the same tab count reconciles nothing and keeps an animating position.
	testing.expect_value(t, raw_data(presentation.tab_positions), positions)
	testing.expect_value(t, presentation.tab_positions[1].value, f32(5))
	testing.expect_value(t, presentation.tab_positions[1].target, f32(6))
	if !testing.expect(t, app.tab_presentation_resize(&presentation, 4)) {return}
	// A new tab starts at its own index without disturbing the motion already under way.
	testing.expect_value(t, presentation.tab_positions[1].value, f32(5))
	testing.expect_value(t, presentation.tab_positions[3].value, f32(3))
	testing.expect_value(t, presentation.tab_positions[3].target, f32(3))
	positions = raw_data(presentation.tab_positions)
	// Hover motion is keyed by tab id and only for tabs not at rest.
	_, append_error := append(&presentation.tab_controls, app.Tab_Control{id = 7})
	testing.expect_value(t, append_error, nil)
	controls := raw_data(presentation.tab_controls)
	presentation.new_tab_control.hover.value = 1
	presentation.profiles_control.press.value = 1
	app.tab_presentation_clear(&presentation)
	testing.expect_value(t, len(presentation.tab_positions), 0)
	testing.expect_value(t, len(presentation.tab_controls), 0)
	testing.expect_value(t, presentation.new_tab_control, ui.Control_Motion{})
	testing.expect_value(t, presentation.profiles_control, ui.Control_Motion{})
	// Workspace adoption retains the storage and lets relayout refill it.
	testing.expect_value(t, raw_data(presentation.tab_controls), controls)
	testing.expect_value(t, raw_data(presentation.tab_positions), positions)
	if !testing.expect(t, app.tab_presentation_resize(&presentation, 3)) {return}
	testing.expect_value(t, raw_data(presentation.tab_positions), positions)
	testing.expect_value(t, presentation.tab_positions[1].value, f32(1))
}

@(test)
tab_presentation_move_follows_the_tab_and_keeps_the_named_controls :: proc(t: ^testing.T) {
	presentation: app.Tab_Presentation
	defer app.tab_presentation_destroy(&presentation)
	app.tab_presentation_init(&presentation)
	if !testing.expect(t, app.tab_presentation_resize(&presentation, 3)) {return}
	for i in 0 ..< 3 {
		presentation.tab_positions[i] = ui.Motion{from = f32(i + 10), value = f32(i + 20), target = f32(i + 30)}
	}
	hovered := app.Tab_Control{id = 7, control = {hover = ui.Motion{value = 40}, press = ui.Motion{value = 50}}}
	_, append_error := append(&presentation.tab_controls, hovered)
	testing.expect_value(t, append_error, nil)
	first_position := presentation.tab_positions[0]
	new_tab := ui.Control_Motion{hover = ui.Motion{value = 60}}
	presentation.new_tab_control = new_tab
	app.tab_presentation_move(&presentation, 0, 2)
	testing.expect_value(t, presentation.tab_positions[2], first_position)
	// The hover motion belongs to tab 7 wherever it moves, so a move leaves it alone.
	testing.expect_value(t, app.tab_control_find(&presentation, 7)^, hovered)
	testing.expect_value(t, presentation.new_tab_control, new_tab)
	testing.expect_value(t, presentation.tab_positions[0].value, f32(21))
	testing.expect_value(t, presentation.tab_positions[1].value, f32(22))
	app.tab_presentation_move(&presentation, 2, 0)
	testing.expect_value(t, presentation.tab_positions[0], first_position)
	testing.expect_value(t, app.tab_selected_after_move(0, 0, 2), 2)
	testing.expect_value(t, app.tab_selected_after_move(1, 0, 2), 0)
	testing.expect_value(t, app.tab_selected_after_move(2, 0, 2), 1)
	testing.expect_value(t, app.tab_selected_after_move(0, 2, 0), 1)
	testing.expect_value(t, app.tab_selected_after_move(1, 2, 0), 2)
	testing.expect_value(t, app.tab_selected_after_move(2, 2, 0), 0)
}

@(test)
tab_presentation_remove_keeps_the_named_controls_and_clamps_the_selection :: proc(t: ^testing.T) {
	presentation: app.Tab_Presentation
	defer app.tab_presentation_destroy(&presentation)
	app.tab_presentation_init(&presentation)
	if !testing.expect(t, app.tab_presentation_resize(&presentation, 4)) {return}
	for i in 0 ..< 4 {presentation.tab_positions[i] = ui.Motion{value = f32(i + 5)}}
	profiles := ui.Control_Motion{press = ui.Motion{value = 9}}
	presentation.profiles_control = profiles
	app.tab_presentation_remove(&presentation, 3)
	testing.expect_value(t, len(presentation.tab_positions), 3)
	testing.expect_value(t, presentation.profiles_control, profiles)
	testing.expect_value(t, presentation.tab_positions[0].value, f32(5))
	testing.expect_value(t, presentation.tab_positions[2].value, f32(7))
	// Closing the last selected tab, an earlier tab, and the only tab.
	testing.expect_value(t, app.tab_selected_after_remove(3, 3, 3), 2)
	testing.expect_value(t, app.tab_selected_after_remove(2, 0, 3), 1)
	testing.expect_value(t, app.tab_selected_after_remove(0, 0, 3), 0)
	testing.expect_value(t, app.tab_selected_after_remove(0, 0, 0), 0)
}

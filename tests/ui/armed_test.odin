package ui_test

import "core:testing"
import "aio:ui"

@(test)
armed_press_and_release_match_one_target :: proc(t: ^testing.T) {
	a: ui.Armed(int)
	testing.expect(t, !ui.armed_down(a))
	fired, ok := ui.armed_release(&a, 1)
	testing.expect(t, !ok && fired == 0)

	testing.expect(t, ui.armed_press(&a, 1))
	testing.expect(t, ui.armed_down(a) && ui.armed_is(a, 1))
	testing.expect(t, !ui.armed_is(a, 2))

	// A release over another target disarms without firing and does not stay armed.
	fired, ok = ui.armed_release(&a, 2)
	testing.expect(t, !ok && fired == 0)
	testing.expect(t, !ui.armed_down(a))
	_, ok = ui.armed_release(&a, 1)
	testing.expect(t, !ok)

	testing.expect(t, ui.armed_press(&a, 1))
	fired, ok = ui.armed_release(&a, 1)
	testing.expect(t, ok && fired == 1)
	testing.expect(t, !ui.armed_down(a) && !ui.armed_is(a, 1))
}

@(test)
armed_press_replaces_target_and_reports_change :: proc(t: ^testing.T) {
	a: ui.Armed(ui.Header_Action)
	testing.expect(t, ui.armed_press(&a, ui.Header_Action.Close))
	// Re-pressing the armed target leaves the activation unchanged; another replaces it.
	testing.expect(t, !ui.armed_press(&a, ui.Header_Action.Close))
	testing.expect(t, ui.armed_press(&a, ui.Header_Action.Zoom))
	testing.expect(t, ui.armed_is(a, ui.Header_Action.Zoom) && !ui.armed_is(a, ui.Header_Action.Close))
	testing.expect(t, ui.armed_cancel(&a))
	testing.expect(t, !ui.armed_down(a) && !ui.armed_cancel(&a))
	fired, ok := ui.armed_release(&a, ui.Header_Action.Zoom)
	testing.expect(t, !ok && fired == ui.Header_Action.None)
}

@(test)
armed_keeps_a_press_that_has_no_target :: proc(t: ^testing.T) {
	// Find-style: a press inside the surface but off every button still owns the release.
	a: ui.Armed(ui.Find_Outcome)
	testing.expect(t, ui.armed_press(&a, ui.Find_Outcome.None))
	testing.expect(t, ui.armed_down(a) && ui.armed_is(a, ui.Find_Outcome.None))
	fired, ok := ui.armed_release(&a, ui.Find_Outcome.None)
	testing.expect(t, ok && fired == ui.Find_Outcome.None)
	testing.expect(t, !ui.armed_down(a))
}

@(test)
armed_index_zero_is_a_real_target :: proc(t: ^testing.T) {
	// Caption and tab-close targets are indices, so zero must arm and fire like any other.
	a: ui.Armed(int)
	testing.expect(t, ui.armed_press(&a, 0))
	testing.expect(t, ui.armed_down(a))
	fired, ok := ui.armed_release(&a, 0)
	testing.expect(t, ok && fired == 0)
}

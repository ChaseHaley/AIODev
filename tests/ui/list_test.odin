package ui_test

import "core:testing"
import "aio:platform"
import "aio:ui"

@(test)
list_step_classifies_navigation_without_text_or_key_releases :: proc(t: ^testing.T) {
	expected := [?]int{-1, 1, 1, -1, 0, 0, 0}
	for e, i in ([?]platform.Key_Event{
		{key = .Arrow_Up, pressed = true}, {key = .Arrow_Down, pressed = true},
		{key = .N, modifiers = {.Control}, pressed = true},
		{key = .P, modifiers = {.Control}, pressed = true},
		{key = .N, modifiers = {.Control, .Alt}, pressed = true},
		{key = .P, pressed = true}, {key = .N, modifiers = {.Control}},
	}) {
		testing.expect_value(t, ui.list_step(e), expected[i])
	}
}

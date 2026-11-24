package app_test

import "core:testing"
import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "cosmos:input"

// Without an nvim on PATH nothing offers Neovim (WORK-650): its commands are unavailable, so the palette
// leaves them out and their keys go to the pane, the content menus have no Neovim row, and `aio
// pane.open_neovim` says why it cannot.
@(test)
neovim_is_not_offered_when_it_is_not_installed :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "neovim-missing", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.neovim_found = false
	testing.expect(t, !app.action_available(s, w, .Open_Neovim))
	testing.expect(t, !app.action_available(s, w, .Swap_Pane_Neovim))

	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	invocation, err := commands.parse_invocation(&s.registry, {"pane.open_neovim"}, context.temp_allocator)
	if !testing.expect_value(t, err.advice, "") {return}
	outcome := app.command_execute(s, app.Control_Request{caller = entry.id, origin = .Cli}, invocation)
	testing.expect_value(t, outcome.status, cli_protocol.Status.Failed)
	testing.expect_value(t, outcome.message, app.NEOVIM_MISSING)

	// Ctrl+Shift+G, Swap pane to Neovim, swaps nothing.
	app.handle_event(s, input.Key_Event{window = w.id, key = .G, modifiers = {.Control, .Shift}, pressed = true})
	app.handle_event(s, input.Key_Event{window = w.id, key = .G, modifiers = {.Control, .Shift}})
	testing.expect_value(t, len(s.neovim_panes), 0)

	for mode in ([?]app.Profile_Menu_Mode{
		app.Profile_Menu_New_Tab{}, app.Profile_Menu_Swap_Pane{{.Terminal, entry.id}}, app.Profile_Menu_Split{},
	}) {
		app.profile_menu_open(s, w, mode, 0, 0)
		for item in w.profile_menu.items {testing.expect(t, item.label != "Neovim", "a Neovim row is offered")}
		testing.expect_value(t, w.profile_menu.items[len(w.profile_menu.items) - 1].label, "Web pane")
		app.overlay_close(s, w)
	}

	s.neovim_found = true
	testing.expect(t, app.action_available(s, w, .Open_Neovim))
	testing.expect(t, app.action_available(s, w, .Swap_Pane_Neovim))
	app.profile_menu_open(s, w, app.Profile_Menu_New_Tab{}, 0, 0)
	testing.expect_value(t, w.profile_menu.items[len(w.profile_menu.items) - 1].label, "Neovim")
	app.overlay_close(s, w)
}

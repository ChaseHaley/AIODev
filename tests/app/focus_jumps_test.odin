package app_test

import "core:slice"
import "core:testing"
import app "../../src"
import "aio:layout"
import "cosmos:platform"

@(private = "file")
shell :: proc(id: u32) -> app.Focus_Jump {return {content = {.Terminal, id}}}

@(private)
jumps_all_reachable :: proc(data: rawptr, jump: app.Focus_Jump) -> bool {return true}

@(private)
jumps_skip_two :: proc(data: rawptr, jump: app.Focus_Jump) -> bool {return jump != shell(2)}

@(test)
focus_jumps_walk_back_and_forward :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for id in ([]u32{1, 2, 2, 3}) {app.focus_jumps_note(&j, shell(id))}
	testing.expect_value(t, len(j.entries), 3)
	jump, ok := app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, ok && jump == shell(2))
	jump, ok = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, ok && jump == shell(1))
	_, ok = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, !ok)
	// Landing on the pane the jump chose records nothing, so forward still works.
	app.focus_jumps_note(&j, shell(1))
	jump, ok = app.focus_jumps_step(&j, 1, jumps_all_reachable, nil)
	testing.expect(t, ok && jump == shell(2))
}

@(test)
focus_jumps_new_focus_drops_forward_path :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for id in ([]u32{1, 2, 3}) {app.focus_jumps_note(&j, shell(id))}
	_, _ = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	app.focus_jumps_note(&j, shell(4))
	testing.expect_value(t, len(j.entries), 3)
	testing.expect_value(t, j.entries[2], shell(4))
	_, ok := app.focus_jumps_step(&j, 1, jumps_all_reachable, nil)
	testing.expect(t, !ok)
}

@(test)
focus_jumps_skip_closed_panes :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for id in ([]u32{1, 2, 3}) {app.focus_jumps_note(&j, shell(id))}
	jump, ok := app.focus_jumps_step(&j, -1, jumps_skip_two, nil)
	testing.expect(t, ok && jump == shell(1))
	testing.expect_value(t, len(j.entries), 2)
	jump, ok = app.focus_jumps_step(&j, 1, jumps_skip_two, nil)
	testing.expect(t, ok && jump == shell(3))
}

// A pane whose content changes in place, as the badge menu and Neovim over a shell do, keeps its entries.
// Settings entries name their workspace, so only that workspace's Settings pane follows the change.
@(test)
focus_jumps_replace_keeps_the_pane_in_place :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	first, second := app.Workspace{id = 1}, app.Workspace{id = 2}
	settings := layout.Content{.Settings, 0}
	markdown := layout.Content{.Markdown, 7}
	app.focus_jumps_note(&j, shell(1))
	app.focus_jumps_note(&j, app.focus_jump_of(&first, settings))
	app.focus_jumps_note(&j, app.focus_jump_of(&second, settings))
	app.focus_jumps_note(&j, shell(2))
	testing.expect_value(t, len(j.entries), 4)

	app.focus_jumps_replace(&j, &second, settings, markdown)
	app.focus_jumps_replace(&j, &first, {.Terminal, 2}, {.Neovim, 3})
	want := []app.Focus_Jump{shell(1), {settings, 1}, {content = markdown}, {content = {.Neovim, 3}}}
	testing.expectf(t, slice.equal(j.entries[:], want), "entries %v, want %v", j.entries[:], want)
	testing.expect_value(t, j.index, 3)
}

// What a tick does for the jump list after its events: linked windows follow their tabs, then the
// focused pane is recorded.
@(private = "file")
jumps_settle :: proc(s: ^app.App) {
	app.pane_links_sync(s)
	app.focus_jumps_track(s)
}

// The OS moving keyboard focus between windows; the tests run inactive, so they deliver it themselves.
@(private = "file")
jumps_focus_moves :: proc(s: ^app.App, from, to: ^app.Window) {
	app.handle_event(s, platform.Focus_Event{from.id, false})
	app.handle_event(s, platform.Focus_Event{to.id, true})
}

@(private = "file")
jumps_focused :: proc(s: ^app.App, w: ^app.Window) -> app.Focus_Jump {
	content, is_pane := app.window_focused_content(w)
	return is_pane ? app.focus_jump_of(w.workspace, content) : {}
}

@(private = "file")
jumps_expect :: proc(
	t: ^testing.T, s: ^app.App, entries: []app.Focus_Jump, index: int, loc := #caller_location,
) {
	testing.expectf(t, slice.equal(s.focus_jumps.entries[:], entries), "entries %v, want %v",
		s.focus_jumps.entries[:], entries, loc = loc)
	testing.expect_value(t, s.focus_jumps.index, index, loc = loc)
}

// A linked window hides as its tab is left and shows as the tab comes back. Neither is a navigation, so
// walking back into that tab and forward out of it again crosses both tabs, rather than looping between
// the panes of the tab with the linked window.
@(test)
focus_jumps_cross_a_tab_with_a_linked_window :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "jumps-linked", second_window = false) {return}
	s := &f.state
	host := s.windows[0]
	app.handle_event(s, platform.Focus_Event{host.id, true})
	jumps_settle(s)
	first := jumps_focused(s, host)

	// The first tab's second pane moves to a linked window, which the user then works in.
	app.pane_split(s, host, .Right)
	app.pane_link_toggle(s, host)
	if !testing.expect_value(t, len(s.windows), 2) {return}
	linked := s.windows[1]
	jumps_settle(s)
	if !testing.expect(t, linked.phase == .Shown) {return}
	jumps_focus_moves(s, host, linked)
	jumps_settle(s)
	second := jumps_focused(s, linked)

	// A second tab, chosen in the host, hides the linked window.
	if _, created := app.tab_create(s, host.workspace); !testing.expect(t, created) {return}
	jumps_focus_moves(s, linked, host)
	app.tab_select(s, host, 1)
	jumps_settle(s)
	testing.expect(t, linked.phase == .Hidden)
	third := jumps_focused(s, host)
	if !testing.expect(t, first != {} && second != {} && third != {}) {return}
	jumps_expect(t, s, {first, second, third}, 2)

	// Back lands in the linked window, shown again with its tab.
	app.focus_jump(s, host, -1)
	jumps_settle(s)
	testing.expect(t, linked.phase == .Shown)
	testing.expect_value(t, host.workspace.selected, 0)
	jumps_focus_moves(s, host, linked)
	jumps_settle(s)
	testing.expect_value(t, jumps_focused(s, linked), second)
	jumps_expect(t, s, {first, second, third}, 1)

	// Back again reaches the host's pane; the command runs in the host, which the linked window activates.
	jumps_focus_moves(s, linked, host)
	app.focus_jump(s, host, -1)
	jumps_settle(s)
	testing.expect_value(t, jumps_focused(s, host), first)
	jumps_expect(t, s, {first, second, third}, 0)

	// Forward walks out through the linked window to the second tab.
	app.focus_jump(s, host, 1)
	jumps_settle(s)
	jumps_focus_moves(s, host, linked)
	jumps_settle(s)
	jumps_expect(t, s, {first, second, third}, 1)
	jumps_focus_moves(s, linked, host)
	app.focus_jump(s, host, 1)
	jumps_settle(s)
	testing.expect_value(t, host.workspace.selected, 1)
	testing.expect(t, linked.phase == .Hidden)
	testing.expect_value(t, jumps_focused(s, host), third)
	jumps_expect(t, s, {first, second, third}, 2)
}

// Places `content` at `placement` beside w's focused pane and focuses it.
@(private = "file")
jumps_place :: proc(
	t: ^testing.T, s: ^app.App, w: ^app.Window, content: layout.Content, placement: app.Pane_Placement,
	loc := #caller_location,
) -> bool {
	tree := app.window_tree(w)
	placed := app.pane_place(s, w, w.workspace, w.workspace.selected, tree.focus, content, placement, true)
	return testing.expectf(t, placed, "placing %v", content, loc = loc)
}

@(private = "file")
jumps_landed :: proc(t: ^testing.T, w: ^app.Window, want: layout.Content, loc := #caller_location) {
	content, _ := app.window_focused_content(w)
	testing.expectf(t, content == want, "landed on %v, want %v", content, want, loc = loc)
}

// Every kind of pane is a landing, in splits, floats and tabs, and Back and Forward walk all of them.
@(test)
focus_jumps_walk_every_pane_kind :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "jumps-kinds", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.handle_event(s, platform.Focus_Event{w.id, true})
	jumps_settle(s)
	terminal, _ := app.window_focused_content(w)

	markdown := app.markdown_pane_create(s, "C:/aio-test/notes.md", false)
	web := app.web_pane_create(s, "")
	changes := app.changes_pane_create(s, {}, "C:/aio-test", .Repository)
	neovim := app.neovim_pane_create(s, "", "")
	if !testing.expect(t, markdown != nil && web != nil && changes != nil && neovim != nil) {return}
	// Neovim never starts here; the pane stands in for one whose Neovim has.
	neovim.exited = true
	Step :: struct {
		content:   layout.Content,
		placement: app.Pane_Placement,
	}
	steps := [?]Step{
		{{.Markdown, markdown.id}, .Split_Right},
		{{.Web, web.id}, .Float},
		{{.Changes, changes.id}, .Tab},
		{{.Settings, 0}, .Tab},
		{{.Neovim, neovim.id}, .Split_Down},
	}
	path: [len(steps) + 1]layout.Content
	path[0] = terminal
	for step, i in steps {
		if !jumps_place(t, s, w, step.content, step.placement) {return}
		jumps_settle(s)
		jumps_landed(t, w, step.content)
		path[i + 1] = step.content
	}
	testing.expect_value(t, len(s.focus_jumps.entries), len(path))

	for i := len(path) - 2; i >= 0; i -= 1 {
		app.focus_jump(s, w, -1)
		jumps_settle(s)
		jumps_landed(t, w, path[i])
	}
	for i in 1 ..< len(path) {
		app.focus_jump(s, w, 1)
		jumps_settle(s)
		jumps_landed(t, w, path[i])
	}
	testing.expect_value(t, s.focus_jumps.index, len(path) - 1)
}

// Each workspace has its own Settings pane, all showing the same content; history keeps them apart.
@(test)
focus_jumps_tell_settings_panes_apart_by_workspace :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "jumps-settings") {return}
	s := &f.state
	if !testing.expect_value(t, len(s.windows), 2) {return}
	first, second := s.windows[0], s.windows[1]
	settings := layout.Content{.Settings, 0}
	app.handle_event(s, platform.Focus_Event{first.id, true})
	jumps_settle(s)
	// The second window opens Settings while the user works in the first, which then opens its own.
	if !jumps_place(t, s, second, settings, .Tab) {return}
	if !jumps_place(t, s, first, settings, .Tab) {return}
	jumps_settle(s)
	jumps_focus_moves(s, first, second)
	jumps_settle(s)
	testing.expect_value(t, len(s.focus_jumps.entries), 3)

	app.focus_jump(s, second, -1)
	jumps_settle(s)
	testing.expect_value(t, s.focus_jumps.window, first.id)
	testing.expect_value(t, s.focus_jumps.index, 1)
	jumps_landed(t, first, settings)
}

// Neovim opened over a shell shows that shell again when it quits. It is the same pane throughout, so
// Back reaches it where Neovim was.
@(test)
focus_jumps_keep_a_pane_when_neovim_quits_to_its_shell :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "jumps-neovim-shell", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.handle_event(s, platform.Focus_Event{w.id, true})
	jumps_settle(s)
	tree := app.window_tree(w)
	terminal, _ := app.window_focused_content(w)
	start := tree.focus

	// Neovim opened from the shell of a new split, as `aio pane.open_neovim` there does: it shows in that
	// pane while the shell keeps running behind it.
	app.pane_split(s, w, .Right)
	behind, _ := app.window_focused_content(w)
	if !testing.expect_value(t, behind.kind, layout.Content_Kind.Terminal) {return}
	neovim := app.neovim_pane_create(s, "", "")
	if !testing.expect(t, neovim != nil) {return}
	neovim.exited = true
	neovim.shell = behind.id
	pane := &tree.nodes[tree.focus].(layout.Pane)
	pane.content = {.Neovim, neovim.id}
	app.window_relayout(s, w)
	jumps_settle(s)
	app.pane_focus(s, w, start)
	jumps_settle(s)
	testing.expect_value(t, len(s.focus_jumps.entries), 3)

	app.neovim_exited(s, neovim)
	jumps_settle(s)
	app.focus_jump(s, w, -1)
	jumps_settle(s)
	jumps_landed(t, w, behind)
	app.focus_jump(s, w, -1)
	jumps_settle(s)
	jumps_landed(t, w, terminal)
}

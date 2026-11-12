package app_test

import "core:testing"
import "core:time"
import app "../../src"
import "aio:layout"
import "aio:settings"
import "aio:term"

@(test)
tab_stack_puts_the_most_telling_other_pane_behind_the_focused_one :: proc(t: ^testing.T) {
	state: app.App
	defaults, err := settings.defaults()
	if !testing.expect_value(t, err, nil) {return}
	state.settings = defaults
	defer settings.destroy(&state.settings)
	defer delete(state.sessions)
	now := time.now()
	working := [1]term.Program_Status{{app = "claude", state = .Working, progress = -1, updated_at = now}}
	asking := [1]term.Program_Status {
		{app = "codex", state = .Blocked, kind = .Permission, progress = -1, updated_at = now},
	}
	entries := [?]app.Session_Entry {
		{id = 1},
		{id = 2},
		{id = 3, statuses = working[:]},
		{id = 4, statuses = asking[:]},
		{id = 5, program = app.Program_Adopted{launch = {harness = .Claude}}},
		{id = 6, program = app.Program_Adopted{name = "nvim"}},
	}
	for entry in entries {
		if _, append_error := append(&state.sessions, entry); !testing.expect_value(t, append_error, nil) {return}
	}
	shell, other_shell := layout.Content{.Terminal, 1}, layout.Content{.Terminal, 2}
	reporter, blocked := layout.Content{.Terminal, 3}, layout.Content{.Terminal, 4}
	quiet_agent, editor := layout.Content{.Terminal, 5}, layout.Content{.Terminal, 6}
	document := layout.Content{.Markdown, 7}
	Case :: struct {
		contents: []layout.Content,
		focus:    int,
		behind:   layout.Content,
		stacked:  bool,
	}
	cases := [?]Case {
		// One pane draws alone.
		{contents = {shell}},
		// An agent beside a focused shell stands behind it, wherever it sits in the layout.
		{contents = {shell, other_shell, reporter}, behind = reporter, stacked = true},
		{contents = {shell, editor, quiet_agent}, behind = quiet_agent, stacked = true},
		// The focused pane is never the one behind, however telling.
		{contents = {reporter, shell}, behind = shell, stacked = true},
		// A program before a document, a document before a shell.
		{contents = {shell, document, editor}, behind = editor, stacked = true},
		{contents = {shell, other_shell, document}, behind = document, stacked = true},
		// Among agents, the one whose status comes first: needing you before working.
		{contents = {shell, reporter, blocked}, behind = blocked, stacked = true},
		// Among equals, the first in the layout.
		{contents = {other_shell, editor, shell}, focus = 1, behind = other_shell, stacked = true},
	}
	for c, i in cases {
		tab, built := stack_tab(t, c.contents, c.focus)
		if !built {return}
		defer app.tab_record_free(tab)
		pane, stacked := app.tab_pane_behind(&state, tab, 0)
		testing.expectf(t, stacked == c.stacked, "case %d: stacked %v", i, stacked)
		if c.stacked {testing.expectf(t, pane.content == c.behind, "case %d: behind %v", i, pane.content)}
	}
}

// A tab whose panes show `contents` in order, focused on the pane at `focus`.
@(private = "file")
stack_tab :: proc(t: ^testing.T, contents: []layout.Content, focus: int) -> (^app.Tab, bool) {
	tab, tab_error := new(app.Tab)
	if !testing.expect_value(t, tab_error, nil) {return nil, false}
	if !testing.expect_value(t, layout.init(&tab.tree, contents[0]), nil) {
		free(tab)
		return nil, false
	}
	focused := tab.tree.focus
	for content, i in contents[1:] {
		node, split_error := layout.split(&tab.tree, tab.tree.focus, .Horizontal, 0.5, content)
		if !testing.expect_value(t, split_error, nil) {
			app.tab_record_free(tab)
			return nil, false
		}
		if i + 1 == focus {focused = node}
	}
	layout.focus_set(&tab.tree, focused)
	return tab, true
}

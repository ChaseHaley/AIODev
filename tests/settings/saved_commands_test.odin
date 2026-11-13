package settings_test

import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
saved_commands_parse_levels_and_drop_incomplete_ones :: proc(t: ^testing.T) {
	fixture :: `saved_command.build.name = "Verify build"
saved_command.build.command = ".\build.ps1 verify"
saved_command.build.level = folder
saved_command.build.folder = "C:\Users\chale\Projects\AIODev"
saved_command.build.profile = pwsh
saved_command.ports.command = "Get-NetTCPConnection | Sort-Object LocalPort"
saved_command.ports.level = profile
saved_command.ports.profile = pwsh
saved_command.commit.command = "git commit -m "docs(work): ""
saved_command.commit.level = everywhere
saved_command.nolevel.command = ls
saved_command.nofolder.command = ls
saved_command.nofolder.level = folder
saved_command.bad.level = sometimes
saved_command.order = commit, build
`
	s, diagnostics, err := settings.parse(fixture)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	// The bad level, then nolevel, nofolder and bad (no command line) are dropped.
	testing.expect_value(t, len(diagnostics), 4)
	commands := &s.saved_commands
	testing.expect_value(t, len(commands.items), 3)
	build := settings.saved_command_find(commands, "build")
	commit := settings.saved_command_find(commands, "commit")
	ports := settings.saved_command_find(commands, "ports")
	if !testing.expect(t, build != nil && commit != nil && ports != nil) {return}
	testing.expect_value(t, build.name, "Verify build")
	testing.expect_value(t, build.command, `.\build.ps1 verify`)
	testing.expect_value(t, build.level, settings.Saved_Command_Level.Folder)
	testing.expect_value(t, build.folder, `C:\Users\chale\Projects\AIODev`)
	testing.expect_value(t, build.profile, "pwsh")
	testing.expect_value(t, ports.level, settings.Saved_Command_Level.Profile)
	testing.expect_value(t, commit.command, `git commit -m "docs(work): "`)
	testing.expect_value(t, commit.name, "")
	indices: [settings.SAVED_COMMAND_LIMIT]int
	count := settings.saved_commands_in_order(commands, indices[:])
	if testing.expect_value(t, count, 3) {
		testing.expect_value(t, commands.items[indices[0]].id, "commit")
		testing.expect_value(t, commands.items[indices[1]].id, "build")
		testing.expect_value(t, commands.items[indices[2]].id, "ports")
	}
}

@(test)
saved_command_folder_contains_its_subfolders_only :: proc(t: ^testing.T) {
	cases := [?]struct {
		folder, directory: string,
		contains:          bool,
	} {
		{`C:\Users\chale\Projects`, `C:\Users\chale\Projects`, true},
		{`C:\Users\chale\Projects`, `C:\Users\chale\Projects\AIODev\src`, true},
		{`C:\Users\chale\Projects\`, `c:/users/chale/projects/aiodev`, true},
		{`C:\Users\chale\Projects`, `C:\Users\chale\Projects2`, false},
		{`C:\Users\chale\Projects\AIODev`, `C:\Users\chale\Projects`, false},
		{`C:\`, `C:\Windows`, true},
		{`C:\Users`, ``, false},
		{``, `C:\Users`, false},
	}
	for c in cases {
		testing.expectf(
			t,
			settings.saved_command_folder_contains(c.folder, c.directory) == c.contains,
			"%q in %q",
			c.directory,
			c.folder,
		)
	}
}

@(test)
saved_command_mutation_adds_edits_and_removes :: proc(t: ^testing.T) {
	source :: "# keep\nsaved_command.command-1.level = folder\n"
	s := saved_parse(t, source)
	defer settings.destroy(&s)
	added, id, issue, error := settings.saved_command_mutate(
		source,
		&s.saved_commands,
		{
			kind = .Add,
			name = "  Commit  ",
			command = `git commit -m "docs(work): "`,
			level = .Folder,
			folder = `C:\Vault`,
			profile = "pwsh",
		},
	)
	defer delete(added)
	defer delete(id)
	defer delete(issue)
	if !testing.expect_value(t, error, settings.Mutation_Error.None) {return}
	// command-1 has lines without a command line, so a new command never takes its ID.
	testing.expect_value(t, id, "command-2")
	testing.expect(t, strings.has_prefix(added, "# keep\n"))
	after := saved_parse(t, added)
	defer settings.destroy(&after)
	commit := settings.saved_command_find(&after.saved_commands, "command-2")
	if !testing.expect(t, commit != nil) {return}
	testing.expect_value(t, commit.name, "Commit")
	testing.expect_value(t, commit.command, `git commit -m "docs(work): "`)
	testing.expect_value(t, commit.folder, `C:\Vault`)
	testing.expect_value(t, commit.profile, "pwsh")

	// Moving it everywhere drops the folder and profile it no longer uses.
	edited, edit_id, edit_issue, edit_error := settings.saved_command_mutate(
		added,
		&after.saved_commands,
		{kind = .Edit, id = "command-2", command = "git status", level = .Everywhere},
	)
	defer delete(edited)
	defer delete(edit_id)
	defer delete(edit_issue)
	if !testing.expect_value(t, edit_error, settings.Mutation_Error.None) {return}
	testing.expect(t, !strings.contains(edited, "command-2.folder") && !strings.contains(edited, "command-2.name"))
	moved := saved_parse(t, edited)
	defer settings.destroy(&moved)
	everywhere := settings.saved_command_find(&moved.saved_commands, "command-2")
	if testing.expect(t, everywhere != nil) {
		testing.expect_value(t, everywhere.level, settings.Saved_Command_Level.Everywhere)
		testing.expect_value(t, everywhere.command, "git status")
	}

	removed, remove_id, remove_issue, remove_error := settings.saved_command_mutate(
		edited,
		&moved.saved_commands,
		{kind = .Remove, id = "command-2"},
	)
	defer delete(removed)
	defer delete(remove_id)
	defer delete(remove_issue)
	testing.expect_value(t, remove_error, settings.Mutation_Error.None)
	testing.expect(t, !strings.contains(removed, "command-2") && !strings.contains(removed, "saved_command.order"))
	testing.expect(t, strings.has_prefix(removed, "# keep\n"))
}

@(test)
saved_command_mutation_refuses_a_missing_command_and_a_command_line_break :: proc(t: ^testing.T) {
	s := saved_parse(t, "")
	defer settings.destroy(&s)
	_, _, _, missing := settings.saved_command_mutate("", &s.saved_commands, {kind = .Remove, id = "nope"})
	testing.expect_value(t, missing, settings.Mutation_Error.Unavailable)
	text, id, issue, error := settings.saved_command_mutate(
		"",
		&s.saved_commands,
		{kind = .Add, command = "ls\nrm -rf", level = .Everywhere},
	)
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	testing.expect_value(t, error, settings.Mutation_Error.Edit)
}

// Parses `source` expecting only the diagnostics of commands it leaves incomplete.
@(private = "file")
saved_parse :: proc(t: ^testing.T, source: string) -> settings.Settings {
	s, diagnostics, error := settings.parse(source)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, error, nil)
	for d in diagnostics {testing.expect(t, strings.contains(d.message, "has no"), d.message)}
	return s
}

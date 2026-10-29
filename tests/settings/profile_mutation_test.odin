package settings_test

import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"

mutation_parse :: proc(t: ^testing.T, source: string) -> settings.Settings {
	s, diagnostics, error := settings.parse(source)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	return s
}

mutation_order :: proc(t: ^testing.T, s: ^settings.Settings, expected: []string) {
	testing.expect_value(t, len(s.profiles.order), len(expected))
	for id, i in expected {
		if i < len(s.profiles.order) {testing.expect_value(t, s.profiles.order[i], id)}
	}
}

@(test)
profile_mutation_add_owns_fields_id_and_eligible_order :: proc(t: ^testing.T) {
	source :: "\xef\xbb\xbf# keep café\r\nfont.size = 14\r\nprofile.order = stale, default\r\n"
	s := mutation_parse(t, source)
	defer settings.destroy(&s)
	testing.expect_value(t, settings.profile_detect(&s, {"profile-1", "Found", "cmd.exe", "~"}), nil)
	text, id, issue, error := settings.profile_mutate(source, &s.profiles, {kind = .Add})
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	testing.expect_value(t, error, settings.Profile_Mutation_Error.None)
	testing.expect_value(t, id, "profile-2")
	testing.expect_value(t, issue, "")
	after := mutation_parse(t, text)
	defer settings.destroy(&after)
	profile := settings.profile_find(&after.profiles, id)
	if !testing.expect(t, profile != nil) {return}
	testing.expect_value(t, profile.name, "New Profile")
	testing.expect_value(t, profile.command, settings.DEFAULT_PROFILE_COMMAND)
	testing.expect_value(t, profile.directory, settings.DEFAULT_PROFILE_DIRECTORY)
	testing.expect(t, profile.name_set && profile.command_set && profile.directory_set)
	testing.expect(t, !profile.hidden_set && !profile.icon_set)
	mutation_order(t, &after, {"default", "profile-2"})
	testing.expect(t, strings.has_prefix(text, "\xef\xbb\xbf# keep café\r\nfont.size = 14\r\n"))
	testing.expect_value(t, len(s.profiles.items), 2)
	testing.expect_value(t, s.profiles.order[0], "stale")
}

@(test)
profile_mutation_duplicate_copies_effective_values_and_resets_hidden :: proc(t: ^testing.T) {
	source :: `profile.default.directory = C:\work
profile.alpha.name = Alpha
profile.alpha.command = cmd.exe /k
profile.alpha.icon = C:\icons\shell.png
profile.alpha.hidden = true
profile.order = found, alpha, default
`
	s := mutation_parse(t, source)
	defer settings.destroy(&s)
	testing.expect_value(t, settings.profile_detect(&s, {"found", "Found", "cmd.exe", "~"}), nil)
	testing.expect_value(t, settings.profile_detect(&s, {"unlisted", "Other", "cmd.exe", "~"}), nil)
	text, id, issue, error := settings.profile_mutate(source, &s.profiles, {kind = .Duplicate, id = "alpha"})
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	testing.expect_value(t, error, settings.Profile_Mutation_Error.None)
	after := mutation_parse(t, text)
	defer settings.destroy(&after)
	profile := settings.profile_find(&after.profiles, id)
	if !testing.expect(t, profile != nil) {return}
	testing.expect_value(t, profile.name, "Alpha copy")
	testing.expect_value(t, profile.command, "cmd.exe /k")
	testing.expect_value(t, profile.directory, `C:\work`)
	testing.expect_value(t, profile.icon, `C:\icons\shell.png`)
	testing.expect(t, profile.hidden_set && !profile.hidden)
	mutation_order(t, &after, {"found", "alpha", id, "default"})
	testing.expect(t, settings.profile_find(&s.profiles, "alpha").hidden)
}

@(test)
profile_mutation_enable_materializes_only_the_selected_detection :: proc(t: ^testing.T) {
	source :: "# keep\nshell.default_profile = found\nprofile.order = default\n"
	s := mutation_parse(t, source)
	defer settings.destroy(&s)
	testing.expect_value(t, settings.profile_detect(&s, {"found", "Found", "cmd.exe", `C:\work`}), nil)
	testing.expect_value(t, settings.profile_detect(&s, {"other", "Other", "cmd.exe", "~"}), nil)
	text, id, issue, error := settings.profile_mutate(source, &s.profiles, {kind = .Enable, id = "found"})
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	testing.expect_value(t, error, settings.Profile_Mutation_Error.None)
	after := mutation_parse(t, text)
	defer settings.destroy(&after)
	profile := settings.profile_find(&after.profiles, id)
	if !testing.expect(t, profile != nil) {return}
	testing.expect_value(t, profile.name, "Found")
	testing.expect_value(t, profile.command, "cmd.exe")
	testing.expect_value(t, profile.directory, `C:\work`)
	testing.expect(t, !profile.detected && profile.hidden_set && !profile.hidden)
	testing.expect_value(t, after.profiles.default_id, "found")
	mutation_order(t, &after, {"default", "found"})
	testing.expect(t, !strings.contains(text, "profile.other."))
}

@(test)
profile_mutation_remove_repairs_order_and_default_in_one_revision :: proc(t: ^testing.T) {
	source :: "\xef\xbb\xbf# keep\r\nprofile.alpha.name = Alpha\r\n" +
		"profile.alpha.command = cmd.exe\r\nprofile.alphabet.command = cmd.exe\r\n" +
		"shell.default_profile = alpha\r\nprofile.order = alpha, default, gone\r\nfont.size = 14\r\n"
	s := mutation_parse(t, source)
	defer settings.destroy(&s)
	text, id, issue, error := settings.profile_mutate(source, &s.profiles, {kind = .Remove, id = "alpha"})
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	testing.expect_value(t, error, settings.Profile_Mutation_Error.None)
	after := mutation_parse(t, text)
	defer settings.destroy(&after)
	testing.expect(t, settings.profile_find(&after.profiles, "alpha") == nil)
	testing.expect_value(t, after.profiles.default_id, "default")
	mutation_order(t, &after, {"default", "alphabet"})
	testing.expect(t, strings.has_prefix(text, "\xef\xbb\xbf# keep\r\nprofile.alphabet.command = cmd.exe\r\n"))
	testing.expect(t, strings.has_suffix(text, "font.size = 14\r\n"))
	testing.expect_value(t, s.profiles.default_id, "alpha")
}

@(test)
profile_mutation_move_owns_main_table_and_listed_detection_order :: proc(t: ^testing.T) {
	source :: "profile.alpha.command = cmd.exe\nprofile.beta.command = cmd.exe\n" +
		"profile.beta.hidden = true\nprofile.order = found, alpha, beta, default, stale\n"
	s := mutation_parse(t, source)
	defer settings.destroy(&s)
	testing.expect_value(t, settings.profile_detect(&s, {"found", "Found", "cmd.exe", "~"}), nil)
	testing.expect_value(t, settings.profile_detect(&s, {"other", "Other", "cmd.exe", "~"}), nil)
	for change in ([?]struct {slot: int, order: []string} {
		{0, {"beta", "alpha", "default", "found"}},
		{2, {"alpha", "beta", "default", "found"}},
		{99, {"alpha", "default", "beta", "found"}},
	}) {
		text, id, issue, error := settings.profile_mutate(
			source, &s.profiles, {kind = .Move, id = "beta", slot = change.slot},
		)
		defer delete(text)
		defer delete(id)
		defer delete(issue)
		testing.expect_value(t, error, settings.Profile_Mutation_Error.None)
		after := mutation_parse(t, text)
		defer settings.destroy(&after)
		mutation_order(t, &after, change.order)
		testing.expect(t, strings.has_prefix(text, "profile.alpha.command = cmd.exe\n"))
	}
}

@(test)
profile_mutation_rejects_ineligible_requests_without_a_revision :: proc(t: ^testing.T) {
	s := mutation_parse(t, "")
	defer settings.destroy(&s)
	testing.expect_value(t, settings.profile_detect(&s, {"found", "Found", "cmd.exe", "~"}), nil)
	for change in ([?]settings.Profile_Mutation {
		{kind = .Remove, id = "default"}, {kind = .Remove, id = "found"},
		{kind = .Move, id = "found"}, {kind = .Enable, id = "default"},
		{kind = .Duplicate, id = "missing"},
	}) {
		text, id, issue, error := settings.profile_mutate("", &s.profiles, change)
		defer delete(text)
		defer delete(id)
		defer delete(issue)
		testing.expect_value(t, error, settings.Profile_Mutation_Error.Unavailable)
		testing.expect_value(t, text, "")
		testing.expect_value(t, id, "")
	}
	for i in 2 ..< settings.PROFILE_LIMIT {
		testing.expect_value(t, settings.profile_detect(&s, {fmt.tprintf("p-%d", i), "Found", "cmd.exe", "~"}), nil)
	}
	for kind in ([?]settings.Profile_Mutation_Kind{.Add, .Duplicate, .Enable}) {
		text, id, issue, error := settings.profile_mutate("", &s.profiles, {kind = kind, id = "found"})
		defer delete(text)
		defer delete(id)
		defer delete(issue)
		testing.expect_value(t, error, kind == .Enable ? settings.Profile_Mutation_Error.None : .Limit)
		testing.expect_value(t, text != "", kind == .Enable)
	}
}

@(test)
profile_mutation_failed_edits_and_allocations_never_return_partial_revisions :: proc(t: ^testing.T) {
	s := mutation_parse(t, "# source\n")
	defer settings.destroy(&s)
	testing.expect_value(t, settings.profile_detect(&s, {"found", "Found", "cmd.exe\nbad", "~"}), nil)
	text, id, issue, error := settings.profile_mutate("# source\n", &s.profiles, {kind = .Enable, id = "found"})
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	testing.expect_value(t, error, settings.Profile_Mutation_Error.Edit)
	testing.expect(t, issue != "")
	testing.expect_value(t, text, "")
	testing.expect_value(t, id, "")
	reached_success := false
	for limit in 0 ..< 256 {
		state := Failure_Allocator{context.allocator, limit}
		allocator := runtime.Allocator{failure_allocate, &state}
		revision, target, problem, result := settings.profile_mutate(
			"# source\n", &s.profiles, {kind = .Add}, allocator,
		)
		delete(revision, allocator)
		delete(target, allocator)
		delete(problem, allocator)
		if result == .None {reached_success = true; break}
		testing.expect_value(t, result, settings.Profile_Mutation_Error.Allocation)
		testing.expect_value(t, revision, "")
		testing.expect_value(t, target, "")
	}
	testing.expect(t, reached_success)
}

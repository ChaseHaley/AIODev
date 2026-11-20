package settings_test

import "aio:settings"
import "base:runtime"
import "core:strings"
import "core:testing"

// Migrates `source`, expecting a file that parses without diagnostics and that a second migration leaves alone.
@(private = "file")
filters_migrate :: proc(t: ^testing.T, source: string) -> (library, updated: string, ok: bool) {
	migrated: bool
	err: runtime.Allocator_Error
	updated, migrated, err = settings.migrate_settings_text(source, context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	s, diagnostics, parse_error := settings.parse(updated)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	if !testing.expect_value(t, parse_error, nil) {return}
	testing.expectf(t, len(diagnostics) == 0, "%q has %d diagnostics", updated, len(diagnostics))
	testing.expect(t, !strings.contains(updated, "turns.diff_filter"), updated)
	again, again_migrated, again_error := settings.migrate_settings_text(updated, context.temp_allocator)
	testing.expect_value(t, again_error, nil)
	testing.expectf(t, !again_migrated && again == updated, "%q migrates again", updated)
	return strings.clone(s.turns.saved_filters, context.temp_allocator), updated, true
}

@(test)
a_plain_diff_filter_becomes_a_saved_filter_named_by_its_text_and_on_by_default :: proc(t: ^testing.T) {
	library, updated, ok := filters_migrate(t, "font.size = 13\nturns.diff_filter = !long foo\nturns.record = true\n")
	if !ok {return}
	testing.expect_value(t, library, "* | !long foo")
	testing.expect_value(t, updated, "font.size = 13\nturns.saved_filters = \"* | !long foo\"\nturns.record = true\n")
}

@(test)
tokens_in_the_diff_filter_mark_their_filters_and_plain_text_is_saved_after_them :: proc(t: ^testing.T) {
	source := "turns.saved_filters = \"No vendor | !^vendor/; Odin | \\.odin$; Docs | \\.md$\"\n" +
		"turns.diff_filter = @Odin ~@Docs @\"No vendor\" @Gone ui !json\n"
	library, _, ok := filters_migrate(t, source)
	if !ok {return}
	testing.expect_value(t, library, "* No vendor | !^vendor/; * Odin | \\.odin$; Docs | \\.md$; * | ui !json")
}

@(test)
text_that_matches_a_saved_pattern_marks_it_instead_of_adding_one :: proc(t: ^testing.T) {
	source := "turns.diff_filter = !^vendor/\nturns.saved_filters = | !^vendor/; Odin | \\.odin$\n"
	library, _, ok := filters_migrate(t, source)
	if !ok {return}
	testing.expect_value(t, library, "* | !^vendor/; Odin | \\.odin$")
}

@(test)
a_text_equal_to_another_filters_name_is_saved_under_a_new_name :: proc(t: ^testing.T) {
	source := "turns.saved_filters = Odin | \\.odin$\nturns.diff_filter = Odin\n"
	library, _, ok := filters_migrate(t, source)
	if !ok {return}
	testing.expect_value(t, library, "Odin | \\.odin$; * Default filter | Odin")
}

@(test)
an_empty_or_token_only_old_filter_is_dropped_with_its_comment_and_adds_nothing :: proc(t: ^testing.T) {
	source := "# The filter a new pane starts with.\nturns.diff_filter = \nturns.record = true\n"
	library, updated, ok := filters_migrate(t, source)
	if !ok {return}
	testing.expect_value(t, library, "")
	testing.expect_value(t, updated, "turns.record = true\n")
	library, updated, ok = filters_migrate(t, "turns.diff_filter = ~@Odin @Gone\n")
	if !ok {return}
	testing.expect_value(t, library, "")
	testing.expect_value(t, updated, "")
}

@(test)
the_diff_filter_key_is_no_longer_a_setting :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse("turns.diff_filter = !long\n")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 1)
}

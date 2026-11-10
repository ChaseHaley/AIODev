package settings_test

import "aio:settings"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
motion_split_line_with_a_user_curve_resolves_without_diagnostics :: proc(t: ^testing.T) {
	s := mutation_parse(t, "motion.panes.split = 420ms wobbly popin\nmotion.curve.mine = 0.3, 1.4, 0.2, 1\n")
	defer settings.destroy(&s)
	r := settings.motion_resolve(&s, .Split)
	testing.expect(t, r.on)
	testing.expect_value(t, r.duration, 420)
	testing.expect_value(t, r.curve_name, "wobbly")
	testing.expect(t, r.curve.spring)
	testing.expect_value(t, r.effect, settings.Motion_Effect.Pop)
	testing.expect_value(t, r.from[.On], settings.Motion_Context.Panes)
	testing.expect_value(t, r.from[.Duration], settings.Motion_Context.Split)
	testing.expect_value(t, r.from[.Curve], settings.Motion_Context.Split)
	testing.expect_value(t, r.from[.Effect], settings.Motion_Context.Split)
	testing.expect_value(t, settings.motion_duration(&s, r), 420 * time.Millisecond)
	curve, found := settings.motion_curve_find(&s, "mine")
	testing.expect(t, found)
	testing.expect_value(t, curve, settings.Motion_Curve{p = {0.3, 1.4, 0.2, 1}})
}

@(test)
motion_spec_grammar_takes_tokens_in_any_order_and_writes_them_canonically :: proc(t: ^testing.T) {
	spec, problem := settings.motion_spec_parse(.Split, "popin wobbly 420ms off")
	testing.expect_value(t, problem, "")
	on, on_set := spec.on.?
	testing.expect(t, on_set && !on)
	duration, duration_set := spec.duration.?
	testing.expect(t, duration_set && duration == 420)
	testing.expect_value(t, spec.curve, "wobbly")
	effect, effect_set := spec.effect.?
	testing.expect(t, effect_set && effect == .Pop)
	text := settings.motion_spec_text(.Split, spec)
	testing.expect_value(t, text, "off 420ms wobbly popin")
	again, again_problem := settings.motion_spec_parse(.Split, text)
	testing.expect_value(t, again_problem, "")
	testing.expect_value(t, settings.motion_spec_text(.Split, again), text)

	empty, empty_problem := settings.motion_spec_parse(.View, "")
	testing.expect_value(t, empty_problem, "")
	testing.expect_value(t, settings.motion_spec_text(.View, empty), "")

	close, close_problem := settings.motion_spec_parse(.Close, "popout")
	testing.expect_value(t, close_problem, "")
	close_effect, close_set := close.effect.?
	testing.expect(t, close_set && close_effect == .Pop)
	testing.expect_value(t, settings.motion_spec_text(.Close, close), "popout")
	testing.expect_value(t, settings.motion_effect_names(.Close)[int(settings.Motion_Effect.Edge)], "collapse")
	testing.expect_value(t, settings.motion_effect_labels(.Split)[int(settings.Motion_Effect.Pop)], "Pop In")
	testing.expect(t, settings.motion_effect_names(.View) == nil)
}

@(test)
motion_spec_grammar_refuses_repeats_and_bad_tokens_readably :: proc(t: ^testing.T) {
	Case :: struct {
		c:            settings.Motion_Context,
		text, wanted: string,
	}
	cases := [?]Case {
		{.Panes, "on off", "give on or off once"},
		{.Panes, "160ms 200ms", "give one duration"},
		{.Panes, "linear smooth", "give one curve; \"linear\" and \"smooth\" both read as curves"},
		{.Split, "popin fade", "give one effect"},
		{.Split, "popout", "\"popout\" is not an effect of Split; use grow, popin, fade or slide"},
		{.View, "fade", "\"fade\" is an effect, and only Split and Close have effects"},
		{.Panes, "160", "\"160\" needs a unit, such as 160ms"},
		{.Panes, "12.5ms", "\"12.5ms\" is not whole milliseconds, such as 160ms"},
		{.Panes, "9000ms", "\"9000ms\" is out of range 0..5000ms"},
		{.View, "Fast!", "\"Fast!\" is not on, off, a duration such as 160ms or a curve name"},
		{
			.Close,
			"Fast!",
			"\"Fast!\" is not on, off, a duration such as 160ms, a curve name or an effect " +
			"(collapse, popout, fade or slide)",
		},
	}
	for test in cases {
		_, problem := settings.motion_spec_parse(test.c, test.text)
		testing.expect_value(t, problem, test.wanted)
	}

	s, d, err := settings.parse("motion.panes.view = fade\n")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	if !testing.expect_value(t, len(d), 1) {return}
	testing.expect_value(t, d[0].key, "motion.panes.view")
	testing.expect_value(t, d[0].line, 1)
	testing.expect(t, strings.contains(d[0].message, "only Split and Close"))
	testing.expect_value(t, s.motion.contexts[.View], "")
}

@(test)
motion_contexts_inherit_from_panes_and_fall_back_at_the_root :: proc(t: ^testing.T) {
	s := mutation_parse(t, "motion.panes = off 300ms smooth\nmotion.panes.view = on spring\nmotion.speed = 2\n")
	defer settings.destroy(&s)
	view := settings.motion_resolve(&s, .View)
	testing.expect(t, view.on)
	testing.expect_value(t, view.from[.On], settings.Motion_Context.View)
	testing.expect_value(t, view.duration, 300)
	testing.expect_value(t, view.from[.Duration], settings.Motion_Context.Panes)
	testing.expect_value(t, view.curve_name, "spring")
	testing.expect_value(t, view.from[.Curve], settings.Motion_Context.View)
	testing.expect_value(t, view.effect, settings.Motion_Effect.Edge)
	testing.expect_value(t, settings.motion_duration(&s, view), 150 * time.Millisecond)
	split := settings.motion_resolve(&s, .Split)
	testing.expect(t, !split.on)
	testing.expect_value(t, split.curve_name, "smooth")
	testing.expect_value(t, settings.motion_duration(&s, split), 0)

	empty := mutation_parse(t, "motion.panes = \"\"\n")
	defer settings.destroy(&empty)
	root := settings.motion_resolve(&empty, .Close)
	testing.expect(t, root.on)
	testing.expect_value(t, root.duration, 160)
	testing.expect_value(t, root.curve_name, "decelerate")
	testing.expect_value(t, root.effect, settings.Motion_Effect.Edge)
	for field in settings.Motion_Field {
		testing.expect_value(t, root.from[field], settings.Motion_Context.Panes)
	}
}

@(test)
motion_unknown_curve_is_reported_and_inherits :: proc(t: ^testing.T) {
	s, d, err := settings.parse("font.size = 12\nmotion.panes.split = 300ms nosuch\n")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	if !testing.expect_value(t, len(d), 1) {return}
	testing.expect_value(t, d[0].key, "motion.panes.split")
	testing.expect_value(t, d[0].line, 2)
	testing.expect(t, strings.contains(d[0].message, "unknown curve \"nosuch\""))
	r := settings.motion_resolve(&s, .Split)
	testing.expect_value(t, r.duration, 300)
	testing.expect_value(t, r.curve_name, "decelerate")
	testing.expect_value(t, r.from[.Curve], settings.Motion_Context.Panes)
}

@(test)
motion_curve_lines_parse_and_refuse_bad_values_and_reserved_names :: proc(t: ^testing.T) {
	s := mutation_parse(t, "motion.curve.soft = spring 0.4\nmotion.curve.quick-out = \"0, 0, 0.2, 1\"\n")
	defer settings.destroy(&s)
	testing.expect_value(t, len(s.motion.curves), 2)
	soft, found := settings.motion_curve_find(&s, "soft")
	testing.expect(t, found)
	testing.expect_value(t, soft, settings.Motion_Curve{spring = true, p = {0.4, 0, 0, 0}})

	refused := [?]string {
		"motion.curve.a = 0.3, 1.4, 0.2",
		"motion.curve.a = 0.3, 1.4, 0.2, 1, 5",
		"motion.curve.a = 1.2, 0, 0, 1",
		"motion.curve.a = 0, 3, 0, 1",
		"motion.curve.a = spring 1",
		"motion.curve.a = bouncy",
		"motion.curve.linear = 0, 0, 1, 1",
		"motion.curve.wobbly = spring 0.1",
		"motion.curve.fade = 0, 0, 1, 1",
		"motion.curve.off = 0, 0, 1, 1",
		"motion.curve.120ms = 0, 0, 1, 1",
		"motion.curve.Bad = 0, 0, 1, 1",
	}
	for line in refused {
		parsed, d, err := settings.parse(line)
		testing.expect_value(t, err, nil)
		testing.expectf(t, len(d) == 1, "%s should give one diagnostic", line)
		testing.expectf(t, len(parsed.motion.curves) == 0, "%s should add no curve", line)
		settings.destroy(&parsed)
		settings.diagnostics_destroy(&d)
	}

	builtin, builtin_d, _ := settings.parse("motion.curve.linear = 0, 0, 1, 1")
	defer settings.destroy(&builtin)
	defer settings.diagnostics_destroy(&builtin_d)
	if testing.expect_value(t, len(builtin_d), 1) {
		testing.expect_value(t, builtin_d[0].kind, settings.Diagnostic_Kind.Unknown_Key)
		testing.expect(t, strings.contains(builtin_d[0].message, "built-in curve"))
	}

	duplicate, duplicate_d, _ := settings.parse("motion.curve.a = spring 0.1\nmotion.curve.a = spring 0.2\n")
	defer settings.destroy(&duplicate)
	defer settings.diagnostics_destroy(&duplicate_d)
	if testing.expect_value(t, len(duplicate_d), 1) {
		testing.expect_value(t, duplicate_d[0].kind, settings.Diagnostic_Kind.Duplicate_Key)
	}
	if testing.expect_value(t, len(duplicate.motion.curves), 1) {
		testing.expect_value(t, duplicate.motion.curves[0].curve.p[0], 0.2)
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..= settings.MOTION_CURVE_LIMIT {fmt.sbprintf(&b, "motion.curve.c%d = spring 0.1\n", i)}
	many, many_d, _ := settings.parse(strings.to_string(b))
	defer settings.destroy(&many)
	defer settings.diagnostics_destroy(&many_d)
	testing.expect_value(t, len(many.motion.curves), settings.MOTION_CURVE_LIMIT)
	if testing.expect_value(t, len(many_d), 1) {
		testing.expect(t, strings.contains(many_d[0].message, "the limit is 32"))
	}
}

@(test)
motion_preset_lines_parse_canonically_and_refuse_bad_values :: proc(t: ^testing.T) {
	s := mutation_parse(t, "motion.preset.mine = split: popin 420ms; panes: off;\n")
	defer settings.destroy(&s)
	if !testing.expect_value(t, len(s.motion.presets), 1) {return}
	preset := s.motion.presets[0]
	testing.expect_value(t, preset.name, "mine")
	testing.expect_value(t, preset.specs[.Panes], "off")
	testing.expect_value(t, preset.specs[.Split], "420ms popin")
	testing.expect_value(t, preset.specs[.Close], "")

	refused := [?]string {
		"motion.preset.x = split popin",
		"motion.preset.x = nowhere: on",
		"motion.preset.x = split: on; split: off",
		"motion.preset.x = view: popin",
		"motion.preset.default = panes: off",
		"motion.preset.X = panes: off",
	}
	for line in refused {
		parsed, d, err := settings.parse(line)
		testing.expect_value(t, err, nil)
		testing.expectf(t, len(d) == 1, "%s should give one diagnostic", line)
		testing.expectf(t, len(parsed.motion.presets) == 0, "%s should add no preset", line)
		settings.destroy(&parsed)
		settings.diagnostics_destroy(&d)
	}
}

// Applies `m` to `source` and parses the revision, which must have no diagnostics.
motion_mutated :: proc(
	t: ^testing.T,
	source: string,
	m: settings.Motion_Mutation,
) -> (
	settings.Settings,
	bool,
) {
	model := mutation_parse(t, source)
	defer settings.destroy(&model)
	revision, message, err := settings.motion_mutate(&model, source, m)
	defer delete(revision)
	defer delete(message)
	testing.expect_value(t, err, nil)
	if !testing.expect_value(t, message, "") {return {}, false}
	return mutation_parse(t, revision), true
}

// Applies `m` to `source`, which it must refuse.
motion_refused :: proc(t: ^testing.T, source: string, m: settings.Motion_Mutation) {
	model := mutation_parse(t, source)
	defer settings.destroy(&model)
	revision, message, err := settings.motion_mutate(&model, source, m)
	defer delete(message)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, revision, "")
	testing.expect(t, message != "")
}

@(test)
motion_preset_apply_copies_the_preset_into_every_context :: proc(t: ^testing.T) {
	after, ok := motion_mutated(t, "motion.panes.chrome = off\n", settings.Motion_Preset_Apply{"bouncy", .Panes})
	if !ok {return}
	defer settings.destroy(&after)
	testing.expect_value(t, settings.motion_preset_matching(&after), "bouncy")
	testing.expect_value(t, after.motion.contexts[.Split], "420ms wobbly popin")
	testing.expect_value(t, after.motion.contexts[.Chrome], "")
	r := settings.motion_resolve(&after, .Split)
	testing.expect_value(t, r.duration, 420)
	testing.expect_value(t, r.effect, settings.Motion_Effect.Pop)
	motion_refused(t, "", settings.Motion_Preset_Apply{"nosuch", .Panes})
}

@(test)
motion_preset_apply_to_one_context_takes_the_presets_resolved_values :: proc(t: ^testing.T) {
	source :: "motion.panes = on 300ms linear\nmotion.panes.split = fade\n"
	after, ok := motion_mutated(t, source, settings.Motion_Preset_Apply{"bouncy", .Close})
	if !ok {return}
	defer settings.destroy(&after)
	testing.expect_value(t, after.motion.contexts[.Close], "on 220ms accelerate popout")
	testing.expect_value(t, after.motion.contexts[.Panes], "on 300ms linear")
	testing.expect_value(t, after.motion.contexts[.Split], "fade")

	view, view_ok := motion_mutated(t, source, settings.Motion_Preset_Apply{"snappy", .View})
	if !view_ok {return}
	defer settings.destroy(&view)
	testing.expect_value(t, view.motion.contexts[.View], "on 110ms quick")
}

@(test)
motion_preset_save_and_remove_round_trip :: proc(t: ^testing.T) {
	after, ok := motion_mutated(t, "motion.panes.split = popin\n", settings.Motion_Preset_Save{"mine"})
	if !ok {return}
	defer settings.destroy(&after)
	if !testing.expect_value(t, len(after.motion.presets), 1) {return}
	testing.expect_value(t, after.motion.presets[0].specs[.Panes], "on 160ms decelerate")
	testing.expect_value(t, after.motion.presets[0].specs[.Split], "popin")
	testing.expect_value(t, settings.motion_preset_matching(&after), "mine")
	motion_refused(t, "", settings.Motion_Preset_Save{"default"})
	motion_refused(t, "", settings.Motion_Preset_Save{"Not A Name"})

	source :: "motion.preset.mine = split: popin\n"
	removed, removed_ok := motion_mutated(t, source, settings.Motion_Preset_Remove{"mine"})
	if !removed_ok {return}
	defer settings.destroy(&removed)
	testing.expect_value(t, len(removed.motion.presets), 0)
	motion_refused(t, source, settings.Motion_Preset_Remove{"other"})
	motion_refused(t, source, settings.Motion_Preset_Remove{"default"})
}

@(test)
motion_curve_set_saves_the_curve_and_assigns_it :: proc(t: ^testing.T) {
	curve := settings.Motion_Curve{p = {0.3, 1.4, 0.2, 1}}
	set := settings.Motion_Curve_Set{"mine", curve, settings.Motion_Context.Split}
	after, ok := motion_mutated(t, "motion.panes.split = 300ms\n", set)
	if !ok {return}
	defer settings.destroy(&after)
	found, known := settings.motion_curve_find(&after, "mine")
	testing.expect(t, known)
	testing.expect_value(t, found, curve)
	testing.expect_value(t, after.motion.contexts[.Split], "300ms mine")
	testing.expect_value(t, settings.motion_resolve(&after, .Split).curve_name, "mine")

	unassigned, unassigned_ok := motion_mutated(t, "", settings.Motion_Curve_Set{name = "soft", curve = curve})
	if !unassigned_ok {return}
	defer settings.destroy(&unassigned)
	testing.expect_value(t, len(unassigned.motion.curves), 1)
	testing.expect_value(t, unassigned.motion.contexts[.Split], "")

	motion_refused(t, "", settings.Motion_Curve_Set{name = "linear", curve = curve})
	motion_refused(t, "", settings.Motion_Curve_Set{name = "mine", curve = {p = {2, 0, 0, 1}}})
}

@(test)
motion_curve_remove_points_contexts_and_presets_back_at_inheriting :: proc(t: ^testing.T) {
	source :: "motion.curve.mine = spring 0.3\nmotion.panes.split = 300ms mine\n" +
		"motion.preset.keep = split: mine popin\n"
	model := mutation_parse(t, source)
	defer settings.destroy(&model)
	revision, message, err := settings.motion_mutate(&model, source, settings.Motion_Curve_Remove{"mine"})
	defer delete(revision)
	defer delete(message)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, message, "")
	after, d, parse_error := settings.parse(revision)
	defer settings.destroy(&after)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, len(after.motion.curves), 0)
	testing.expect_value(t, after.motion.contexts[.Split], "300ms")
	if testing.expect_value(t, len(after.motion.presets), 1) {
		testing.expect_value(t, after.motion.presets[0].specs[.Split], "popin")
	}
	motion_refused(t, source, settings.Motion_Curve_Remove{"spring"})
	motion_refused(t, source, settings.Motion_Curve_Remove{"other"})
}

@(test)
motion_curve_rename_moves_the_curve_and_everything_naming_it :: proc(t: ^testing.T) {
	source :: "motion.curve.mine = 0.3, 1.4, 0.2, 1\nmotion.curve.other = spring 0.2\n" +
		"motion.panes.split = 300ms mine\nmotion.panes.close = other\nmotion.preset.keep = split: mine popin\n"
	after, ok := motion_mutated(t, source, settings.Motion_Curve_Rename{"mine", "snap"})
	if !ok {return}
	defer settings.destroy(&after)
	_, old := settings.motion_curve_find(&after, "mine")
	testing.expect(t, !old)
	curve, renamed := settings.motion_curve_find(&after, "snap")
	testing.expect(t, renamed)
	testing.expect_value(t, curve, settings.Motion_Curve{p = {0.3, 1.4, 0.2, 1}})
	testing.expect_value(t, after.motion.contexts[.Split], "300ms snap")
	testing.expect_value(t, after.motion.contexts[.Close], "other")
	if testing.expect_value(t, len(after.motion.presets), 1) {
		testing.expect_value(t, after.motion.presets[0].specs[.Split], "snap popin")
	}
	motion_refused(t, source, settings.Motion_Curve_Rename{"mine", "other"})
	motion_refused(t, source, settings.Motion_Curve_Rename{"mine", "linear"})
	motion_refused(t, source, settings.Motion_Curve_Rename{"mine", "Not A Name"})
	motion_refused(t, source, settings.Motion_Curve_Rename{"decelerate", "slow"})
	motion_refused(t, source, settings.Motion_Curve_Rename{"nosuch", "slow"})
}

@(test)
motion_preset_matching_names_the_preset_the_settings_equal :: proc(t: ^testing.T) {
	defaults, err := settings.defaults()
	defer settings.destroy(&defaults)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, settings.motion_preset_matching(&defaults), "default")
	off := mutation_parse(t, "motion.panes = off\n")
	defer settings.destroy(&off)
	testing.expect_value(t, settings.motion_preset_matching(&off), "off")
	custom := mutation_parse(t, "motion.panes.chrome = 10ms\n")
	defer settings.destroy(&custom)
	testing.expect_value(t, settings.motion_preset_matching(&custom), "")
}

@(test)
motion_curves_ease_from_zero_to_one_and_may_overshoot :: proc(t: ^testing.T) {
	s, err := settings.defaults()
	defer settings.destroy(&s)
	testing.expect_value(t, err, nil)
	for builtin in settings.MOTION_BUILTIN_CURVES {
		testing.expect_value(t, settings.motion_curve_ease(builtin.curve, 0), 0)
		testing.expect_value(t, settings.motion_curve_ease(builtin.curve, 1), 1)
		testing.expect_value(t, settings.motion_curve_ease(builtin.curve, 1.5), 1)
	}
	linear, _ := settings.motion_curve_find(&s, "linear")
	testing.expect(t, abs(settings.motion_curve_ease(linear, 0.5) - 0.5) < 0.001)
	back, _ := settings.motion_curve_find(&s, "back")
	testing.expect(t, settings.motion_curve_ease(back, 0.6) > 1)
	wobbly, _ := settings.motion_curve_find(&s, "wobbly")
	testing.expect(t, abs(settings.motion_curve_ease(wobbly, 0.99) - 1) < 0.05)
	peak: f32
	for i in 1 ..< 100 {peak = max(peak, settings.motion_curve_ease(wobbly, f32(i) / 100))}
	testing.expect(t, peak > 1)
}

@(test)
motion_names_come_from_free_text :: proc(t: ^testing.T) {
	testing.expect_value(t, settings.motion_name_from("My Preset!"), "my-preset")
	testing.expect_value(t, settings.motion_name_from("  Fast & Loose 2 "), "fast-loose-2")
	testing.expect_value(t, settings.motion_name_from("--__x--y"), "x-y")
	testing.expect_value(t, settings.motion_name_from("!!!"), "")
}

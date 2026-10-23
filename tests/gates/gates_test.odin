package gates_test

import "core:strings"
import "core:testing"
import "../../tools/gates"

has_test :: proc(plan: gates.Plan, name: string) -> bool {
	for item in plan.tests {
		if item == name {return true}
	}
	return false
}

has_reason :: proc(plan: gates.Plan, reason: string) -> bool {
	for item in plan.reasons {
		if item == reason {return true}
	}
	return false
}

count_test :: proc(plan: gates.Plan, name: string) -> int {
	count := 0
	for item in plan.tests {
		if item == name {count += 1}
	}
	return count
}

@(test)
control_change_runs_app_and_control_tests_without_a_live_pass :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"src/control/requests.odin"})
	defer gates.plan_destroy(&plan)
	testing.expect(t, has_test(plan, "app"))
	testing.expect(t, has_test(plan, "control"))
	testing.expect(t, !plan.live)
	testing.expect(t, !plan.solo)
	testing.expect(t, !plan.perf)
	testing.expect(t, !plan.fallback)
}

@(test)
render_change_requires_a_live_pass_and_the_performance_tier :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"src/render/frame_windows.odin"})
	defer gates.plan_destroy(&plan)
	testing.expect(t, has_test(plan, "app"))
	testing.expect(t, has_test(plan, "render"))
	testing.expect(t, plan.live)
	testing.expect(t, plan.perf)
	testing.expect(t, plan.solo)
	testing.expect(t, has_reason(plan, "ui"))
	testing.expect(t, has_reason(plan, "hot path"))
}

@(test)
native_change_is_solo_and_names_the_native_boundary :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"src/platform/platform_windows.odin"})
	defer gates.plan_destroy(&plan)
	testing.expect(t, plan.live)
	testing.expect(t, plan.solo)
	testing.expect(t, !plan.perf)
	testing.expect(t, has_reason(plan, "native boundary"))
}

@(test)
settings_change_is_solo_because_it_owns_persistence :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"src/settings/settings.odin"})
	defer gates.plan_destroy(&plan)
	testing.expect(t, plan.solo)
	testing.expect(t, has_reason(plan, "persistence schema"))
}

@(test)
documentation_owes_only_the_cheap_gates :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"README.md", "AGENTS.md"})
	defer gates.plan_destroy(&plan)
	testing.expect_value(t, len(plan.tests), 0)
	testing.expect(t, !plan.live)
	testing.expect(t, !plan.solo)
	testing.expect(t, !plan.perf)
	testing.expect(t, !plan.fallback)
}

@(test)
unknown_path_fails_open :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"mystery.bin"})
	defer gates.plan_destroy(&plan)
	testing.expect_value(t, len(plan.tests), 0)
	testing.expect(t, plan.fallback)
	testing.expect(t, plan.live)
	testing.expect(t, plan.solo)
	testing.expect(t, has_reason(plan, "unknown path"))
}

@(test)
several_paths_share_one_live_reason_and_one_test_name :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"src/ui/palette.odin", "src/ui/notices.odin"})
	defer gates.plan_destroy(&plan)
	testing.expect_value(t, count_test(plan, "ui"), 1)
	testing.expect_value(t, count_test(plan, "app"), 1)
	testing.expect_value(t, len(plan.reasons), 1)
	testing.expect(t, has_reason(plan, "ui"))
}

@(test)
test_change_maps_to_its_package_only :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"tests/control/requests_test.odin"})
	defer gates.plan_destroy(&plan)
	testing.expect(t, has_test(plan, "control"))
	testing.expect(t, !has_test(plan, "app"))
	testing.expect(t, !plan.live)
}

@(test)
report_names_the_commands_to_run :: proc(t: ^testing.T) {
	plan := gates.classify([]string{"src/control/requests.odin"})
	defer gates.plan_destroy(&plan)
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	gates.format_plan(&out, plan)
	text := strings.to_string(out)
	testing.expect(t, strings.has_prefix(text, "change: 1 paths\n"))
	testing.expect(t, strings.contains(text, "tier0.tests: app control\n"))
	testing.expect(t, strings.contains(text, "tier1.live: no\n"))
	testing.expect(t, strings.contains(text, "tier2.batch: eligible\n"))
	testing.expect(t, strings.contains(text, "run: .\\build.ps1 check\n"))
	testing.expect(t, strings.contains(text, "run: .\\build.ps1 test app\n"))
	testing.expect(t, strings.contains(text, "run: .\\build.ps1 test control\n"))
}

@(test)
no_changes_reports_no_work :: proc(t: ^testing.T) {
	plan := gates.classify(nil)
	defer gates.plan_destroy(&plan)
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	gates.format_plan(&out, plan)
	testing.expect_value(t, strings.to_string(out), "change: 0 paths\nplan: no changes\n")
}

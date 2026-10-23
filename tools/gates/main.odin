package gates

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

USAGE :: `gates <path>...
gates --stdin
Reports the validation tiers a change owes under the accepted cadence.
Paths are repository-relative. --stdin reads newline-separated paths, so:
  git diff --name-only main...HEAD | build\gates.exe --stdin
Output is key=value lines. The plan is advisory: an unknown path fails open to the full suite and a live pass.
Exit codes: 0 planned, 2 no paths or bad arguments.
`

// UI-affecting changes need one live pass; native paths may also need real OS input; hot paths need
// the performance gate and are validated alone rather than in a batch.
UI_PREFIXES :: []string {
	"src/ui/",
	"src/term_view/",
	"src/render/",
	"src/layout/",
	"src/commands/",
	"src/term/",
	"src/ghostty/",
}
NATIVE_PREFIXES :: []string{"src/platform/", "src/input/", "src/instance/", "src/pty/"}
NATIVE_FILES :: []string{"src/term/input.odin", "src/term/input_windows.odin"}
PERF_PREFIXES :: []string {
	"src/render/",
	"src/term/",
	"src/pty/",
	"src/font/",
	"src/dwrite/",
	"src/glyphs/",
	"src/term_view/",
}
PERF_FILES :: []string{"src/window.odin"}

Plan :: struct {
	allocator: runtime.Allocator,
	paths:     []string,
	tests:     [dynamic]string,
	reasons:   [dynamic]string,
	fallback:  bool,
	live:      bool,
	solo:      bool,
	perf:      bool,
}

// classify maps changed paths to tier obligations. It does not inspect the filesystem; finalize adds
// the missing-test fallback and drops packages that do not exist.
@(require_results)
classify :: proc(paths: []string, allocator := context.allocator) -> Plan {
	plan := Plan {
		allocator = allocator,
		paths     = paths,
		tests     = make([dynamic]string, allocator),
		reasons   = make([dynamic]string, allocator),
	}
	for raw in paths {
		path, _ := strings.replace_all(raw, "\\", "/", context.temp_allocator)
		classify_path(&plan, path)
	}
	return plan
}

plan_destroy :: proc(plan: ^Plan) {
	delete(plan.tests)
	delete(plan.reasons)
	plan^ = {}
}

@(private)
classify_path :: proc(plan: ^Plan, path: string) {
	switch {
	case strings.has_suffix(path, ".md"), path == ".gitignore", path == ".gitattributes":
		return
	case strings.has_prefix(path, "src/"):
		classify_source(plan, path)
	case strings.has_prefix(path, "tests/"):
		classify_test(plan, path)
	case strings.has_prefix(path, "tools/"):
		// Tools are compiled by check; a dedicated test package is optional.
		parts := strings.split(path, "/", context.temp_allocator)
		if len(parts) >= 2 {add_test(plan, parts[1])}
	case path == "build.ps1":
		plan.fallback = true
		plan.solo = true
		add_reason(plan, "build script")
	case strings.has_prefix(path, "assets/"), strings.has_prefix(path, "vendor/"):
		plan.live = true
		add_reason(plan, "asset")
	case:
		// An unfamiliar path cannot be classified safely.
		plan.fallback = true
		plan.live = true
		plan.solo = true
		add_reason(plan, "unknown path")
	}
}

@(private)
classify_source :: proc(plan: ^Plan, path: string) {
	rest := path[len("src/"):]
	// The app tests exercise the composed application and are cheap enough for every source change.
	add_test(plan, "app")
	if separator := strings.index_byte(rest, '/'); separator >= 0 {
		add_test(plan, rest[:separator])
	}
	if in_list(path, NATIVE_FILES) || has_prefix_any(path, NATIVE_PREFIXES) {
		plan.live = true
		plan.solo = true
		add_reason(plan, "native boundary")
	}
	if strings.has_prefix(path, "src/settings/") {
		plan.solo = true
		add_reason(plan, "persistence schema")
	}
	if in_list(path, PERF_FILES) || has_prefix_any(path, PERF_PREFIXES) {
		plan.perf = true
		plan.solo = true
		add_reason(plan, "hot path")
	}
	if has_prefix_any(path, UI_PREFIXES) || !strings.contains(rest, "/") {
		plan.live = true
		add_reason(plan, "ui")
	}
}

@(private)
classify_test :: proc(plan: ^Plan, path: string) {
	rest := path[len("tests/"):]
	if strings.has_prefix(rest, "live/") {
		plan.live = true
		add_reason(plan, "live script")
		return
	}
	if separator := strings.index_byte(rest, '/'); separator >= 0 {
		add_test(plan, rest[:separator])
	}
}

@(private)
has_prefix_any :: proc(path: string, prefixes: []string) -> bool {
	for prefix in prefixes {
		if strings.has_prefix(path, prefix) {return true}
	}
	return false
}

@(private)
in_list :: proc(value: string, values: []string) -> bool {
	for item in values {
		if value == item {return true}
	}
	return false
}

@(private)
add_test :: proc(plan: ^Plan, name: string) {
	if name == "" {return}
	for existing in plan.tests {
		if existing == name {return}
	}
	append(&plan.tests, name)
}

@(private)
add_reason :: proc(plan: ^Plan, reason: string) {
	for existing in plan.reasons {
		if existing == reason {return}
	}
	append(&plan.reasons, reason)
}

// finalize drops test packages that do not exist and fails open when a source package has none.
finalize :: proc(plan: ^Plan) {
	for path in plan.paths {
		if !strings.has_prefix(path, "src/") {continue}
		rest := path[len("src/"):]
		name := rest
		if separator := strings.index_byte(rest, '/'); separator >= 0 {
			name = rest[:separator]
		} else {
			name = "app"
		}
		if !test_package_exists(name) {
			plan.fallback = true
			return
		}
	}
	kept := make([dynamic]string, plan.allocator)
	for name in plan.tests {
		if test_package_exists(name) {append(&kept, name)}
	}
	delete(plan.tests)
	plan.tests = kept
}

@(private)
test_package_exists :: proc(name: string) -> bool {
	return os.exists(fmt.tprintf("tests/%s", name)) || os.exists(fmt.tprintf("tests\\%s", name))
}

format_plan :: proc(out: ^strings.Builder, plan: Plan) {
	fmt.sbprintf(out, "change: %d paths\n", len(plan.paths))
	if len(plan.paths) == 0 {
		fmt.sbprintf(out, "plan: no changes\n")
		return
	}
	fmt.sbprintf(out, "tier0.check: yes\n")
	if plan.fallback {
		fmt.sbprintf(out, "tier0.tests: all\n")
	} else if len(plan.tests) == 0 {
		fmt.sbprintf(out, "tier0.tests: none\n")
	} else {
		fmt.sbprintf(out, "tier0.tests: %s\n", strings.join(plan.tests[:], " ", context.temp_allocator))
	}
	fmt.sbprintf(out, "tier0.fallback: %s\n", plan.fallback ? "full" : "no")
	fmt.sbprintf(out, "tier1.live: %s\n", plan.live ? "required" : "no")
	fmt.sbprintf(
		out,
		"tier1.reason: %s\n",
		len(plan.reasons) == 0 ? "none" : strings.join(plan.reasons[:], ", ", context.temp_allocator),
	)
	fmt.sbprintf(out, "tier2.batch: %s\n", plan.solo ? "solo" : "eligible")
	fmt.sbprintf(out, "tier3.perf: %s\n", plan.perf ? "required" : "no")
	fmt.sbprintf(out, "tier4.review: required\n")
	fmt.sbprintf(out, "run: .\\build.ps1 check\n")
	if plan.fallback {
		fmt.sbprintf(out, "run: .\\build.ps1 test\n")
	} else {
		for name in plan.tests {
			fmt.sbprintf(out, "run: .\\build.ps1 test %s\n", name)
		}
	}
}

main :: proc() {
	code := run(os.args[1:])
	free_all(context.temp_allocator)
	os.exit(code)
}

@(private, require_results)
run :: proc(args: []string) -> int {
	if len(args) == 1 && (args[0] == "--help" || args[0] == "help") {
		fmt.print(USAGE)
		return 0
	}
	paths: []string
	if len(args) == 1 && args[0] == "--stdin" {
		paths = read_stdin(context.temp_allocator)
	} else if len(args) == 1 && args[0] == "" {
		paths = nil
	} else {
		paths = args
	}
	if len(paths) == 0 {
		fmt.eprint(USAGE)
		return 2
	}
	plan := classify(paths, context.temp_allocator)
	defer plan_destroy(&plan)
	finalize(&plan)
	out := strings.builder_make(context.temp_allocator)
	format_plan(&out, plan)
	fmt.print(strings.to_string(out))
	return 0
}

@(private, require_results)
read_stdin :: proc(allocator := context.allocator) -> []string {
	data := make([dynamic]u8, allocator)
	buffer: [4096]u8
	for {
		n, err := os.read(os.stdin, buffer[:])
		if n > 0 {append(&data, ..buffer[:n])}
		if err != nil || n == 0 {break}
	}
	if len(data) == 0 {return nil}
	lines := strings.split_lines(string(data[:]), allocator)
	kept := make([dynamic]string, allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed != "" {append(&kept, trimmed)}
	}
	return kept[:]
}

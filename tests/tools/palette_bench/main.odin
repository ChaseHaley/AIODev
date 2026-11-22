// Per-keystroke cost of palette and Settings search (WORK-470). Not a test: it prints timings for a
// person to compare before and after a matcher change.
//
//   odin build tests/tools/palette_bench -collection:aio=src -collection:cosmos=../Cosmos/src -o:speed `
//       -out:build/palette_bench.exe
//   build/palette_bench.exe
//
// The corpus is every palette command, every schema setting with its choice labels, 200 tab titles and
// 12 workspaces; the Settings page gets a row per schema setting. Each query is typed one character at
// a time and every keystroke's full re-rank is timed. Allocations count every call through the heap
// and temp allocators while a keystroke runs, after a warm-up pass sized every buffer.
package palette_bench

import app "../../../src"
import "aio:commands"
import "aio:settings"
import "aio:views"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:time"
import "cosmos:ui"

QUERIES :: [?]string {
	"c", "c1", "rs", "ws", "cls", "aio", "fon", "font", "comfy", "split", "theme", "nwtab", "scrollb",
	"palette", "terminal", "activity", "zqxjzqxj",
}

@(rodata)
TAB_TITLES := [?]string {
	"pwsh", "(card 1) foo", "C:\\Users\\chale\\Projects\\AIODev", "nvim src/ui/palette.odin", "claude",
	"git log --oneline", "npm run dev", "cargo watch -x test", "htop", "ssh build-box", "python manage.py runserver",
	"Administrator: Windows PowerShell", "docker compose up", "(card 12) review notes", "odin build src",
	"tail -f server.log", "lazygit", "bun test --watch", "C:\\Windows\\System32\\cmd.exe", "codex",
}

@(rodata)
WORKSPACES := [?]string {
	"AIODev", "Obsidian", "Website", "Infra", "Scratch", "Card game", "Dotfiles", "Research", "Billing",
	"Mobile app", "Data pipeline", "Notes",
}

Tab :: struct {
	label, detail, owner: string,
}

Bench :: struct {
	tabs:       [dynamic]Tab,
	workspaces: [dynamic]Tab,
}

tab_count :: proc(user: rawptr) -> int {return len((cast(^[dynamic]Tab)user)^)}
tab_at :: proc(user: rawptr, index: int) -> views.Palette_Item {
	t := (cast(^[dynamic]Tab)user)[index]
	return {label = t.label, detail = t.detail, owner = t.owner, id = u64(index + 1)}
}

Counter :: struct {
	inner:        runtime.Allocator,
	calls, bytes: int,
}

counting :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	c := cast(^Counter)data
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		c.calls += 1
		c.bytes += size
	}
	return c.inner.procedure(c.inner.data, mode, size, alignment, old_memory, old_size, location)
}

Sample :: struct {
	us:                            f64,
	heap_calls, temp_calls, bytes: int,
}

report :: proc(name: string, samples: []Sample) {
	times := make([]f64, len(samples), context.temp_allocator)
	total, heap_calls, temp_calls, bytes := 0.0, 0, 0, 0
	for s, i in samples {
		times[i] = s.us
		total += s.us
		heap_calls += s.heap_calls
		temp_calls += s.temp_calls
		bytes += s.bytes
	}
	slice.sort(times)
	n := len(times)
	fmt.printfln(
		"%-16s keystrokes %d  mean %.1f us  p50 %.1f  p95 %.1f  max %.1f  per key: heap allocs %.2f, temp allocs %.2f, bytes %.1f",
		name, n, total / f64(n), times[n / 2], times[min(n - 1, n * 95 / 100)], times[n - 1],
		f64(heap_calls) / f64(n), f64(temp_calls) / f64(n), f64(bytes) / f64(n),
	)
}

main :: proc() {
	heap := Counter{inner = context.allocator}
	temp := Counter{inner = context.temp_allocator}
	context.allocator = {counting, &heap}
	context.temp_allocator = {counting, &temp}

	registry := commands.create()
	if app.register_actions(&registry) != .None {fmt.eprintln("commands failed"); return}
	table := make([dynamic]views.Palette_Setting)
	choice_labels := 0
	for entry in settings.SCHEMA {
		if entry.embedded {continue}
		append(&table, views.palette_setting(entry))
		choice_labels += len(entry.names)
	}
	b: Bench
	for i in 0 ..< 200 {
		title := TAB_TITLES[i % len(TAB_TITLES)]
		if i >= len(TAB_TITLES) {title = fmt.aprintf("%s %d", title, i / len(TAB_TITLES))}
		append(&b.tabs, Tab{title, "pwsh.exe", WORKSPACES[i % len(WORKSPACES)]})
	}
	for w in WORKSPACES {append(&b.workspaces, Tab{w, "pwsh", ""})}

	p: views.Palette
	if views.palette_init(&p, table[:]) != nil {fmt.eprintln("palette failed"); return}
	views.palette_set_sources(&p, {&b.tabs, tab_count, tab_at}, {&b.workspaces, tab_count, tab_at})

	defaults, _ := settings.defaults()
	editor: views.Editor
	rows := 0
	for entry in settings.SCHEMA {
		if entry.control == .Group || entry.embedded {continue}
		row := views.schema_row(entry)
		row.value = settings.value_text(&defaults, entry)
		if views.editor_add(&editor, row, settings.group_title(entry.key)) != nil {fmt.eprintln("editor failed"); return}
		rows += 1
	}
	fmt.printfln(
		"corpus: %d commands, %d settings (%d choice labels), %d tabs, %d workspaces; Settings page %d rows",
		len(registry.items), len(table), choice_labels, len(b.tabs), len(b.workspaces), rows,
	)

	palette_samples := make([dynamic]Sample)
	editor_samples := make([dynamic]Sample)
	reserve(&palette_samples, 4096)
	reserve(&editor_samples, 4096)
	for pass in 0 ..< 21 {
		measured := pass > 0
		for query in QUERIES {
			views.palette_open_mode(&p, &registry, .All)
			for i in 0 ..< len(query) {
				heap.calls, heap.bytes, temp.calls, temp.bytes = 0, 0, 0, 0
				start := time.tick_now()
				_ = views.palette_text(&p, &registry, query[i:i + 1])
				elapsed := time.tick_since(start)
				if measured {
					append(&palette_samples, Sample{
						time.duration_microseconds(elapsed), heap.calls, temp.calls, heap.bytes + temp.bytes,
					})
				}
				free_all(context.temp_allocator)
			}
			for i in 0 ..< len(query) {
				heap.calls, heap.bytes, temp.calls, temp.bytes = 0, 0, 0, 0
				start := time.tick_now()
				ui.field_set(&editor.filter, query[:i + 1])
				views.editor_filter(&editor)
				elapsed := time.tick_since(start)
				if measured {
					append(&editor_samples, Sample{
						time.duration_microseconds(elapsed), heap.calls, temp.calls, heap.bytes + temp.bytes,
					})
				}
				free_all(context.temp_allocator)
			}
		}
	}
	report("palette (All)", palette_samples[:])
	report("Settings search", editor_samples[:])

	// What each query lists, so a ranking change is visible next to its cost.
	for query in ([?]string{"c1", "comfy"}) {
		views.palette_open_mode(&p, &registry, .All)
		_ = views.palette_text(&p, &registry, query)
		fmt.printf("palette %q:", query)
		for r, i in p.results {
			if i == 5 {break}
			fmt.printf(" [%s]", views.palette_result_title(&p, r))
		}
		fmt.println()
		ui.field_set(&editor.filter, query)
		views.editor_filter(&editor)
		fmt.printf("Settings %q:", query)
		shown := 0
		for item in editor.items {
			if item.row < 0 || item.part > 0 {continue}
			if shown == 5 {break}
			fmt.printf(" [%s]", editor.rows[item.row].title)
			shown += 1
		}
		fmt.println()
		free_all(context.temp_allocator)
	}
}

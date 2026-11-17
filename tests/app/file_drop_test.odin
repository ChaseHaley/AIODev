package app_test

import "aio:layout"
import "aio:platform"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import app "../../src"

// What a file dropped from Explorer opens: a Markdown file in a Markdown pane, a folder in a shell, any
// other file in Neovim in a terminal pane, each beside the pane under the drop.

@(private = "file")
Drop_Fixture :: struct {
	palette: Palette_Fixture,
	root:    string,
	// PATH before the test changed it, restored by drop_fixture_destroy.
	path:    string,
}

@(private = "file", require_results)
drop_fixture_create :: proc(t: ^testing.T, f: ^Drop_Fixture, name: string) -> bool {
	if !palette_fixture_create(t, &f.palette, name, false) {return false}
	root, err := os.make_directory_temp("", "aio-file-drop-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return false}
	f.root = root
	f.path = os.get_env("PATH", context.allocator)
	return true
}

@(private = "file")
drop_fixture_destroy :: proc(t: ^testing.T, f: ^Drop_Fixture) {
	if f.path != "" {
		testing.expect_value(t, os.set_env("PATH", f.path), nil)
		delete(f.path)
	}
	palette_fixture_destroy(t, &f.palette)
	if f.root != "" {
		testing.expect_value(t, os.remove_all(f.root), nil)
		delete(f.root)
	}
}

// Puts a program named nvim ahead of the real one on PATH: the idle shell, a live child that needs no
// interpreter. An empty directory instead leaves no nvim to find.
@(private = "file", require_results)
drop_path_with_nvim :: proc(t: ^testing.T, f: ^Drop_Fixture, present: bool) -> bool {
	bin := fmt.tprintf(`%s\bin`, f.root)
	if !testing.expect_value(t, os.make_directory(bin), nil) {return false}
	if present {
		directory, dir_error := os.get_executable_directory(context.temp_allocator)
		if !testing.expect_value(t, dir_error, nil) {return false}
		shell, read_error := os.read_entire_file(fmt.tprintf("%s/idle-shell.exe", directory), context.allocator)
		if !testing.expect_value(t, read_error, nil) {return false}
		defer delete(shell)
		if !testing.expect_value(t, os.write_entire_file(fmt.tprintf(`%s\nvim.exe`, bin), shell), nil) {return false}
	}
	return testing.expect_value(t, os.set_env("PATH", bin), nil)
}

@(private = "file", require_results)
drop_file :: proc(t: ^testing.T, f: ^Drop_Fixture, name: string) -> (string, bool) {
	path := fmt.tprintf(`%s\%s`, f.root, name)
	return path, testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("# x\n")), nil)
}

@(private = "file")
drop :: proc(s: ^app.App, w: ^app.Window, x, y: f32, paths: ..string) {
	joined := strings.join(paths, "\n", context.temp_allocator)
	app.handle_event(s, platform.Files_Drop_Event{w.id, i32(x), i32(y), joined})
}

@(private = "file")
centre_of :: proc(w: ^app.Window, index: int) -> (f32, f32) {
	r := w.panes[index].rect
	return r.x + r.width / 2, r.y + r.height / 2
}

// The kinds of the window's panes, left to right.
@(private = "file")
pane_kinds :: proc(w: ^app.Window) -> []layout.Content_Kind {
	panes := slice.clone(w.panes[:], context.temp_allocator)
	slice.sort_by(panes, proc(a, b: layout.Pane_Rect) -> bool {return a.rect.x < b.rect.x})
	kinds := make([]layout.Content_Kind, len(panes), context.temp_allocator)
	for pane, i in panes {kinds[i] = pane.content.kind}
	return kinds
}

@(private = "file")
last_notice :: proc(s: ^app.App) -> string {
	return len(s.notices.items) == 0 ? "" : s.notices.items[len(s.notices.items) - 1].text
}

@(test)
dropped_markdown_opens_beside_the_pane_under_the_drop :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-markdown") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	app.pane_split(s, w, .Right)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	doc, made := drop_file(t, &f, "doc.md")
	if !made {return}

	// On the left pane the viewer splits to its right, between the two terminals.
	left := w.panes[0].rect.x < w.panes[1].rect.x ? 0 : 1
	x, y := centre_of(w, left)
	drop(s, w, x, y, doc)
	if !testing.expect_value(t, len(s.markdown_panes), 1) {return}
	testing.expect_value(t, s.markdown_panes[0].title, "doc.md")
	kinds := pane_kinds(w)
	if !testing.expect_value(t, len(kinds), 3) {return}
	testing.expect_value(t, kinds[0], layout.Content_Kind.Terminal)
	testing.expect_value(t, kinds[1], layout.Content_Kind.Markdown)
	testing.expect_value(t, kinds[2], layout.Content_Kind.Terminal)

	// A file already shown is shown again, not opened twice.
	drop(s, w, x, y, doc)
	testing.expect_value(t, len(s.markdown_panes), 1)
	testing.expect_value(t, len(w.panes), 3)
}

@(test)
a_drop_on_chrome_opens_beside_the_focused_pane :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-chrome") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	app.pane_split(s, w, .Right)
	doc, made := drop_file(t, &f, "doc.md")
	if !made {return}
	// The new pane is focused and rightmost; the point is above every pane.
	drop(s, w, 2, 2, doc)
	kinds := pane_kinds(w)
	if !testing.expect_value(t, len(kinds), 3) {return}
	testing.expect_value(t, kinds[2], layout.Content_Kind.Markdown)
}

@(test)
dropped_files_open_in_neovim_in_their_folder :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-nvim") {return}
	if !drop_path_with_nvim(t, &f, true) {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	notes, made := drop_file(t, &f, "notes.txt")
	if !made {return}
	before := len(s.sessions)
	notices := len(s.notices.items)
	x, y := centre_of(w, 0)
	drop(s, w, x, y, notes)
	if !testing.expect_value(t, len(s.sessions), before + 1) {return}
	opened := &s.sessions[len(s.sessions) - 1]
	// The program is named by the path found for it, then the file, as a link program's line is.
	command := opened.header.command
	testing.expect(t, strings.has_prefix(command, `"`), command)
	testing.expect(t, strings.has_suffix(command, fmt.tprintf(`\bin\nvim.exe" %s`, notes)), command)
	testing.expect(t, strings.equal_fold(opened.header.launch_directory, f.root), opened.header.launch_directory)
	kinds := pane_kinds(w)
	if !testing.expect_value(t, len(kinds), 2) {return}
	testing.expect_value(t, len(s.notices.items), notices)
}

@(test)
dropped_files_without_neovim_report_it_once_and_markdown_still_opens :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-no-nvim") {return}
	if !drop_path_with_nvim(t, &f, false) {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	first, made := drop_file(t, &f, "one.txt")
	if !made {return}
	second, made_second := drop_file(t, &f, "two.log")
	if !made_second {return}
	doc, made_doc := drop_file(t, &f, "doc.md")
	if !made_doc {return}
	before := len(s.sessions)
	notices := len(s.notices.items)
	x, y := centre_of(w, 0)
	drop(s, w, x, y, first, second, doc)
	testing.expect_value(t, len(s.sessions), before)
	testing.expect_value(t, len(s.markdown_panes), 1)
	testing.expect_value(t, len(s.notices.items), notices + 1)
	testing.expect_value(
		t,
		last_notice(s),
		"nvim is not on PATH, so only Markdown files and folders open from a drop.",
	)
}

@(test)
a_dropped_folder_opens_a_shell_in_it :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-folder") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	before := len(s.sessions)
	x, y := centre_of(w, 0)
	drop(s, w, x, y, f.root)
	if !testing.expect_value(t, len(s.sessions), before + 1) {return}
	opened := &s.sessions[len(s.sessions) - 1]
	testing.expect(t, strings.equal_fold(opened.header.launch_directory, f.root), opened.header.launch_directory)
}

@(test)
a_drop_opens_at_most_eight_files_and_says_so :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-limit") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	paths := make([]string, 10, context.temp_allocator)
	for i in 0 ..< len(paths) {
		made: bool
		if paths[i], made = drop_file(t, &f, fmt.tprintf("doc%d.md", i)); !made {return}
	}
	x, y := centre_of(w, 0)
	drop(s, w, x, y, ..paths)
	testing.expect_value(t, len(s.markdown_panes), app.FILE_DROP_LIMIT)
	testing.expect_value(t, last_notice(s), "Opened the first 8 of 10 dropped files.")
}

@(test)
a_dropped_path_that_is_not_there_is_reported :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-missing") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	before := len(s.sessions)
	notices := len(s.notices.items)
	x, y := centre_of(w, 0)
	drop(s, w, x, y, fmt.tprintf(`%s\gone.txt`, f.root), `\\server\share\remote.md`)
	testing.expect_value(t, len(s.sessions), before)
	testing.expect_value(t, len(s.markdown_panes), 0)
	testing.expect_value(t, len(s.notices.items), notices + 1)
	testing.expect_value(t, last_notice(s), "That local file is not available.")
}

package turns_test

import "aio:turns"
import "core:strings"
import "core:testing"

@(private)
join_lines :: proc(eol: string, lines: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for line in lines {
		strings.write_string(&b, line)
		strings.write_string(&b, eol)
	}
	return strings.to_string(b)
}

@(private)
unified :: proc(lines: ..string) -> string {
	return join_lines("\n", ..lines)
}

@(private)
parse :: proc(t: ^testing.T, text: string) -> turns.Diff {
	d, ok := turns.diff_parse(text)
	testing.expect(t, ok)
	return d
}

MODIFY_SAMPLE :: [?]string {
	"diff --git a/src/main.odin b/src/main.odin",
	"index 83db48f..bf2a1c3 100644",
	"--- a/src/main.odin",
	"+++ b/src/main.odin",
	"@@ -1,5 +1,5 @@ package main",
	` import "core:fmt"`,
	" ",
	"-main :: proc() {",
	"+main :: proc() { // changed",
	" \tfmt.println(\"hi\")",
	" }",
	"@@ -20,3 +20,4 @@ helper :: proc() {",
	" \ta := 1",
	" \tb := 2",
	"+\tc := 3",
	" \t_ = a",
}

@(private)
expect_modify_sample :: proc(t: ^testing.T, d: turns.Diff) {
	testing.expect_value(t, len(d.files), 1)
	if len(d.files) != 1 {return}
	f := d.files[0]
	testing.expect_value(t, f.old_path, "src/main.odin")
	testing.expect_value(t, f.new_path, "src/main.odin")
	testing.expect_value(t, f.status, turns.File_Status.Modified)
	testing.expect(t, !f.binary)
	testing.expect_value(t, f.added, 2)
	testing.expect_value(t, f.removed, 1)
	testing.expect_value(t, len(f.hunks), 2)
	if len(f.hunks) != 2 {return}
	h := f.hunks[0]
	testing.expect_value(t, h.old_start, 1)
	testing.expect_value(t, h.old_count, 5)
	testing.expect_value(t, h.new_start, 1)
	testing.expect_value(t, h.new_count, 5)
	testing.expect_value(t, h.section, "package main")
	testing.expect_value(t, len(h.lines), 6)
	if len(h.lines) == 6 {
		testing.expect_value(t, h.lines[0], turns.Diff_Line{.Context, 1, 1, `import "core:fmt"`})
		testing.expect_value(t, h.lines[1], turns.Diff_Line{.Context, 2, 2, ""})
		testing.expect_value(t, h.lines[2], turns.Diff_Line{.Removed, 3, 0, "main :: proc() {"})
		testing.expect_value(t, h.lines[3], turns.Diff_Line{.Added, 0, 3, "main :: proc() { // changed"})
		testing.expect_value(t, h.lines[4], turns.Diff_Line{.Context, 4, 4, "\tfmt.println(\"hi\")"})
		testing.expect_value(t, h.lines[5], turns.Diff_Line{.Context, 5, 5, "}"})
	}
	h = f.hunks[1]
	testing.expect_value(t, h.old_start, 20)
	testing.expect_value(t, h.old_count, 3)
	testing.expect_value(t, h.new_start, 20)
	testing.expect_value(t, h.new_count, 4)
	testing.expect_value(t, h.section, "helper :: proc() {")
	testing.expect_value(t, len(h.lines), 4)
	if len(h.lines) == 4 {
		testing.expect_value(t, h.lines[2], turns.Diff_Line{.Added, 0, 22, "\tc := 3"})
		testing.expect_value(t, h.lines[3], turns.Diff_Line{.Context, 22, 23, "\t_ = a"})
	}
}

@(test)
modified_file_with_two_hunks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sample := MODIFY_SAMPLE
	d := parse(t, unified(..sample[:]))
	defer turns.diff_destroy(&d)
	expect_modify_sample(t, d)
}

@(test)
crlf_line_endings_are_stripped_from_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sample := MODIFY_SAMPLE
	d := parse(t, join_lines("\r\n", ..sample[:]))
	defer turns.diff_destroy(&d)
	expect_modify_sample(t, d)
}

@(test)
text_without_a_final_newline_keeps_its_last_line :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := unified(
		"diff --git a/f b/f",
		"--- a/f",
		"+++ b/f",
		"@@ -1 +1 @@",
		"-a",
		"+b",
	)
	d := parse(t, text[:len(text) - 1])
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	testing.expect_value(t, d.files[0].added, 1)
	testing.expect_value(t, d.files[0].hunks[0].lines[1], turns.Diff_Line{.Added, 0, 1, "b"})
}

@(test)
added_file :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/new.txt b/new.txt",
			"new file mode 100644",
			"index 0000000..e69de29",
			"--- /dev/null",
			"+++ b/new.txt",
			"@@ -0,0 +1,2 @@",
			"+one",
			"+two",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	f := d.files[0]
	testing.expect_value(t, f.status, turns.File_Status.Added)
	testing.expect_value(t, f.old_path, "new.txt")
	testing.expect_value(t, f.new_path, "new.txt")
	testing.expect_value(t, f.added, 2)
	testing.expect_value(t, f.removed, 0)
	testing.expect_value(t, f.hunks[0].old_start, 0)
	testing.expect_value(t, f.hunks[0].old_count, 0)
	testing.expect_value(t, f.hunks[0].new_count, 2)
	testing.expect_value(t, f.hunks[0].lines[1], turns.Diff_Line{.Added, 0, 2, "two"})
}

@(test)
empty_new_file_has_a_path_and_no_hunks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified("diff --git a/empty b/empty", "new file mode 100644", "index 0000000..e69de29"),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	testing.expect_value(t, d.files[0].status, turns.File_Status.Added)
	testing.expect_value(t, d.files[0].new_path, "empty")
	testing.expect_value(t, len(d.files[0].hunks), 0)
}

@(test)
deleted_file :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/old.txt b/old.txt",
			"deleted file mode 100644",
			"index 5716ca5..0000000",
			"--- a/old.txt",
			"+++ /dev/null",
			"@@ -1 +0,0 @@",
			"-bye",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	f := d.files[0]
	testing.expect_value(t, f.status, turns.File_Status.Deleted)
	testing.expect_value(t, f.old_path, "old.txt")
	testing.expect_value(t, f.new_path, "old.txt")
	testing.expect_value(t, f.removed, 1)
	testing.expect_value(t, f.hunks[0].old_count, 1)
	testing.expect_value(t, f.hunks[0].new_start, 0)
	testing.expect_value(t, f.hunks[0].new_count, 0)
}

@(test)
rename_with_edits_names_both_paths_even_with_spaces :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/lib/old name.txt b/lib/new.txt",
			"similarity index 80%",
			"rename from lib/old name.txt",
			"rename to lib/new.txt",
			"index 1111111..2222222 100644",
			"--- a/lib/old name.txt\t",
			"+++ b/lib/new.txt",
			"@@ -1,2 +1,2 @@",
			" keep",
			"-old",
			"+new",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	f := d.files[0]
	testing.expect_value(t, f.status, turns.File_Status.Renamed)
	testing.expect_value(t, f.old_path, "lib/old name.txt")
	testing.expect_value(t, f.new_path, "lib/new.txt")
	testing.expect_value(t, f.added, 1)
	testing.expect_value(t, f.removed, 1)
	testing.expect_value(t, len(f.hunks), 1)
}

@(test)
pure_rename_has_no_hunks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/a.txt b/b.txt",
			"similarity index 100%",
			"rename from a.txt",
			"rename to b.txt",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	f := d.files[0]
	testing.expect_value(t, f.status, turns.File_Status.Renamed)
	testing.expect_value(t, f.old_path, "a.txt")
	testing.expect_value(t, f.new_path, "b.txt")
	testing.expect_value(t, len(f.hunks), 0)
	testing.expect_value(t, f.added + f.removed, 0)
}

@(test)
copy_names_both_paths :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/orig.txt b/copy.txt",
			"similarity index 100%",
			"copy from orig.txt",
			"copy to copy.txt",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	testing.expect_value(t, d.files[0].status, turns.File_Status.Copied)
	testing.expect_value(t, d.files[0].old_path, "orig.txt")
	testing.expect_value(t, d.files[0].new_path, "copy.txt")
}

@(test)
binary_files_are_marked_and_have_no_hunks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/img.png b/img.png",
			"index 1234567..89abcde 100644",
			"Binary files a/img.png and b/img.png differ",
			"diff --git a/new.bin b/new.bin",
			"new file mode 100644",
			"index 0000000..1234567",
			"Binary files /dev/null and b/new.bin differ",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 2)
	testing.expect(t, d.files[0].binary)
	testing.expect_value(t, d.files[0].new_path, "img.png")
	testing.expect_value(t, d.files[0].status, turns.File_Status.Modified)
	testing.expect_value(t, len(d.files[0].hunks), 0)
	testing.expect(t, d.files[1].binary)
	testing.expect_value(t, d.files[1].status, turns.File_Status.Added)
	testing.expect_value(t, d.files[1].new_path, "new.bin")
}

@(test)
mode_change_only_keeps_the_path_from_the_diff_line :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/my dir/run.sh b/my dir/run.sh",
			"old mode 100644",
			"new mode 100755",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	testing.expect_value(t, d.files[0].status, turns.File_Status.Modified)
	testing.expect_value(t, d.files[0].old_path, "my dir/run.sh")
	testing.expect_value(t, d.files[0].new_path, "my dir/run.sh")
	testing.expect_value(t, len(d.files[0].hunks), 0)
	testing.expect(t, !d.files[0].binary)
}

@(test)
no_newline_markers_attach_to_the_line_before_them :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/n.txt b/n.txt",
			"index 1111111..2222222 100644",
			"--- a/n.txt",
			"+++ b/n.txt",
			"@@ -1 +1 @@",
			"-old",
			"\\ No newline at end of file",
			"+new",
			"\\ No newline at end of file",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	f := d.files[0]
	testing.expect_value(t, f.added, 1)
	testing.expect_value(t, f.removed, 1)
	lines := f.hunks[0].lines
	testing.expect_value(t, len(lines), 4)
	testing.expect_value(t, lines[0].kind, turns.Line_Kind.Removed)
	testing.expect_value(t, lines[1].kind, turns.Line_Kind.No_Newline)
	testing.expect_value(t, lines[1].text, "No newline at end of file")
	testing.expect_value(t, lines[2].kind, turns.Line_Kind.Added)
	testing.expect_value(t, lines[3].kind, turns.Line_Kind.No_Newline)
}

@(test)
no_newline_marker_after_the_last_counted_line_still_belongs_to_the_hunk :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/n.txt b/n.txt",
			"--- a/n.txt",
			"+++ b/n.txt",
			"@@ -1,2 +1,2 @@",
			" same",
			"+tail",
			"-tail",
			"\\ No newline at end of file",
			"diff --git a/o.txt b/o.txt",
			"--- a/o.txt",
			"+++ b/o.txt",
			"@@ -1 +1 @@",
			"-a",
			"+b",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 2)
	testing.expect_value(t, len(d.files[0].hunks[0].lines), 4)
	testing.expect_value(t, d.files[0].hunks[0].lines[3].kind, turns.Line_Kind.No_Newline)
	testing.expect_value(t, len(d.files[1].hunks[0].lines), 2)
}

@(test)
missing_hunk_counts_default_to_one :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified("diff --git a/f b/f", "--- a/f", "+++ b/f", "@@ -3 +3 @@ func", "-a", "+b"),
	)
	defer turns.diff_destroy(&d)
	h := d.files[0].hunks[0]
	testing.expect_value(t, h.old_start, 3)
	testing.expect_value(t, h.old_count, 1)
	testing.expect_value(t, h.new_start, 3)
	testing.expect_value(t, h.new_count, 1)
	testing.expect_value(t, h.section, "func")
	testing.expect_value(t, h.lines[0], turns.Diff_Line{.Removed, 3, 0, "a"})
	testing.expect_value(t, h.lines[1], turns.Diff_Line{.Added, 0, 3, "b"})
}

@(test)
a_removed_line_that_looks_like_a_file_header_is_still_a_removed_line :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/q.sql b/q.sql",
			"index 1111111..2222222 100644",
			"--- a/q.sql",
			"+++ b/q.sql",
			"@@ -1,3 +1,2 @@",
			" select 1;",
			"--- a comment",
			" select 2;",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	testing.expect_value(t, d.files[0].removed, 1)
	testing.expect_value(t, d.files[0].hunks[0].lines[1], turns.Diff_Line{.Removed, 2, 0, "-- a comment"})
	testing.expect_value(t, d.files[0].hunks[0].lines[2], turns.Diff_Line{.Context, 3, 2, "select 2;"})
}

@(test)
quoted_paths_with_octal_escapes_decode_to_utf8 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			`diff --git "a/dir with space/caf\303\251 \346\227\245.txt" "b/dir with space/caf\303\251 \346\227\245.txt"`,
			"index 1111111..2222222 100644",
			`--- "a/dir with space/caf\303\251 \346\227\245.txt"`,
			`+++ "b/dir with space/caf\303\251 \346\227\245.txt"`,
			"@@ -1 +1 @@",
			"-a",
			"+b",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	testing.expect_value(t, d.files[0].old_path, "dir with space/café 日.txt")
	testing.expect_value(t, d.files[0].new_path, "dir with space/café 日.txt")
	testing.expect_value(t, d.files[0].added, 1)
}

@(test)
quoted_paths_decode_c_escapes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			`diff --git "a/tab\there \"q\" \\ nl\n.txt" "b/tab\there \"q\" \\ nl\n.txt"`,
			"new file mode 100644",
			"index 0000000..1111111",
			"--- /dev/null",
			`+++ "b/tab\there \"q\" \\ nl\n.txt"`,
			"@@ -0,0 +1 @@",
			"+x",
			`diff --git "a/old\tname" "b/new\tname"`,
			"similarity index 100%",
			`rename from "old\tname"`,
			`rename to "new\tname"`,
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 2)
	testing.expect_value(t, d.files[0].new_path, "tab\there \"q\" \\ nl\n.txt")
	testing.expect_value(t, d.files[0].status, turns.File_Status.Added)
	testing.expect_value(t, d.files[1].old_path, "old\tname")
	testing.expect_value(t, d.files[1].new_path, "new\tname")
	testing.expect_value(t, d.files[1].status, turns.File_Status.Renamed)
}

@(test)
quoted_name_only_in_the_diff_line_still_gives_the_path :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(`diff --git "a/m\303\251.sh" "b/m\303\251.sh"`, "old mode 100644", "new mode 100755"),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	testing.expect_value(t, d.files[0].new_path, "mé.sh")
}

@(test)
unquoted_paths_with_spaces_lose_git_s_trailing_tab :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/my file.txt b/my file.txt",
			"index 1111111..2222222 100644",
			"--- a/my file.txt\t",
			"+++ b/my file.txt\t",
			"@@ -1 +1 @@",
			"-a",
			"+b",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, d.files[0].new_path, "my file.txt")
	testing.expect_value(t, d.files[0].old_path, "my file.txt")
}

@(test)
several_files_come_out_in_order_with_their_own_counts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/a b/a",
			"--- a/a",
			"+++ b/a",
			"@@ -1 +1,2 @@",
			" x",
			"+y",
			"diff --git a/b b/b",
			"--- a/b",
			"+++ b/b",
			"@@ -1,2 +1 @@",
			" x",
			"-y",
			"diff --git a/c b/c",
			"old mode 100644",
			"new mode 100755",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 3)
	testing.expect_value(t, d.files[0].new_path, "a")
	testing.expect_value(t, d.files[0].added, 1)
	testing.expect_value(t, d.files[0].removed, 0)
	testing.expect_value(t, d.files[1].new_path, "b")
	testing.expect_value(t, d.files[1].added, 0)
	testing.expect_value(t, d.files[1].removed, 1)
	testing.expect_value(t, d.files[2].new_path, "c")
	testing.expect_value(t, len(d.files[0].hunks), 1)
	testing.expect_value(t, len(d.files[1].hunks), 1)
	testing.expect_value(t, len(d.files[2].hunks), 0)
}

@(test)
empty_and_non_diff_text_have_no_files :: proc(t: ^testing.T) {
	d, ok := turns.diff_parse("")
	testing.expect(t, ok)
	testing.expect_value(t, len(d.files), 0)
	turns.diff_destroy(&d)

	d, ok = turns.diff_parse("hello\nworld\n\n")
	testing.expect(t, ok)
	testing.expect_value(t, len(d.files), 0)
	turns.diff_destroy(&d)
}

@(test)
a_damaged_hunk_header_fails_the_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for header in ([?]string{"@@ -1,2 +x @@", "@@ -a +1 @@", "@@ -1 +1", "@@ -1,2 1,2 @@"}) {
		text := unified("diff --git a/f b/f", "--- a/f", "+++ b/f", header, "-a")
		d, ok := turns.diff_parse(text)
		if ok {turns.diff_destroy(&d)}
		testing.expectf(t, !ok, "%q should fail", header)
	}
}

@(test)
a_hunk_cut_short_ends_at_the_next_header :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/f b/f",
			"--- a/f",
			"+++ b/f",
			"@@ -1,5 +1,5 @@",
			" a",
			"diff --git a/g b/g",
			"--- a/g",
			"+++ b/g",
			"@@ -1 +1 @@",
			"-x",
			"+y",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 2)
	testing.expect_value(t, len(d.files[0].hunks[0].lines), 1)
	testing.expect_value(t, d.files[1].new_path, "g")
	testing.expect_value(t, d.files[1].added, 1)
}

@(test)
git_binary_patches_are_marked_binary_and_skipped :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/x.bin b/x.bin",
			"index 1111111..2222222 100644",
			"GIT binary patch",
			"literal 4",
			"Lc${NkU|;!R0RR7g",
			"",
			"diff --git a/y b/y",
			"--- a/y",
			"+++ b/y",
			"@@ -1 +1 @@",
			"-a",
			"+b",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 2)
	testing.expect(t, d.files[0].binary)
	testing.expect_value(t, len(d.files[0].hunks), 0)
	testing.expect_value(t, d.files[1].added, 1)
}

@(test)
a_hundred_thousand_line_diff_parses_into_a_few_allocations :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	defer free_all(context.temp_allocator)
	strings.write_string(&b, "diff --git a/big.txt b/big.txt\nnew file mode 100644\n")
	strings.write_string(&b, "--- /dev/null\n+++ b/big.txt\n@@ -0,0 +1,100000 @@\n")
	for _ in 0 ..< 100000 {
		strings.write_string(&b, "+some line of text\r\n")
	}
	d := parse(t, strings.to_string(b))
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 1)
	testing.expect_value(t, d.files[0].added, 100000)
	testing.expect_value(t, len(d.files[0].hunks[0].lines), 100000)
	testing.expect_value(t, d.files[0].hunks[0].lines[99999], turns.Diff_Line{.Added, 0, 100000, "some line of text"})
}

@(test)
a_combined_diff_section_ends_the_file_before_it_and_is_skipped :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := parse(
		t,
		unified(
			"diff --git a/img.png b/img.png",
			"index 1234567..89abcde 100644",
			"Binary files a/img.png and b/img.png differ",
			"diff --cc conflicted.txt",
			"index 1111111,2222222..0000000",
			"--- a/conflicted.txt",
			"+++ b/conflicted.txt",
			"@@@ -1,3 -1,3 +1,7 @@@",
			"  a",
			"++<<<<<<< ours",
			"diff --git a/after.txt b/after.txt",
			"--- a/after.txt",
			"+++ b/after.txt",
			"@@ -1 +1 @@",
			"-x",
			"+y",
		),
	)
	defer turns.diff_destroy(&d)
	testing.expect_value(t, len(d.files), 2)
	testing.expect_value(t, d.files[0].old_path, "img.png")
	testing.expect_value(t, d.files[0].new_path, "img.png")
	testing.expect(t, d.files[0].binary)
	testing.expect_value(t, len(d.files[0].hunks), 0)
	testing.expect_value(t, d.files[1].new_path, "after.txt")
	testing.expect_value(t, d.files[1].added, 1)
}

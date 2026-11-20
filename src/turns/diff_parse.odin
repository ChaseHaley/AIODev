package turns

import "base:runtime"
import "core:strings"

Line_Kind :: enum u8 {
	Context,
	Added,
	Removed,
	// The "\ No newline at end of file" marker for the line before it.
	No_Newline,
}

// One line of a hunk. `old_line` and `new_line` are 1-based numbers in the old and new file; the side a
// line is not on is 0. `text` excludes the sign and the line ending.
Diff_Line :: struct {
	kind:     Line_Kind,
	old_line: i32,
	new_line: i32,
	text:     string,
}

// A changed byte range inside a diff line; end is exclusive.
Diff_Range :: struct {
	start, end: int,
}

// Similar lines in a hunk, with their changed byte ranges on either side of `split`.
Diff_Edit :: struct {
	left, right:       int,
	first, split, end: int,
}

Hunk :: struct {
	old_start: i32,
	old_count: i32,
	new_start: i32,
	new_count: i32,
	// What git prints after the second @@, usually the enclosing function.
	section:   string,
	lines:     []Diff_Line,
	edits:       []Diff_Edit,
	edit_ranges: []Diff_Range,
}

File_Status :: enum u8 {
	Modified,
	Added,
	Deleted,
	Renamed,
	Copied,
}

// One file of a diff. Both paths are always set: they are the same unless the file was renamed or
// copied, so an added or deleted file names itself and `status` says which side exists. The oids come
// from the "index" line, borrowing from the parsed text; a side that does not exist, or a diff without
// that line (a pure rename or mode change), has "". They are full ids only when git ran with
// --full-index.
Diff_File :: struct {
	old_path: string,
	new_path: string,
	old_oid:  Oid,
	new_oid:  Oid,
	status:   File_Status,
	binary:   bool,
	added:    int,
	removed:  int,
	hunks:    []Hunk,
}

// A parsed diff. The paths, hunk sections and line texts borrow from the parsed text, except the paths
// git quoted with escapes, which `owned` holds. The files, hunks and lines live in three slabs so a
// diff of a hundred thousand lines costs a few allocations; diff_destroy frees them all.
Diff :: struct {
	files:     []Diff_File,
	hunk_slab: []Hunk,
	line_slab: []Diff_Line,
	owned:     [dynamic]string,
	allocator: runtime.Allocator,
}

// What the extended header lines of the file being read have said so far.
@(private)
Header :: struct {
	git_old:     string,
	git_new:     string,
	from:        string,
	to:          string,
	from_null:   bool,
	to_null:     bool,
	rename_from: string,
	rename_to:   string,
	copy_from:   string,
	copy_to:     string,
	new_file:    bool,
	deleted:     bool,
}

@(private)
Parser :: struct {
	d:           ^Diff,
	files_n:     int,
	hunks_n:     int,
	lines_n:     int,
	hunk_first:  int,
	line_first:  int,
	in_file:     bool,
	in_hunk:     bool,
	old_left:    i32,
	new_left:    i32,
	old_no:      i32,
	new_no:      i32,
	head:        Header,
}

// Parses git's unified diff output (`diff`, `diff-tree -p`, `--no-color`). Empty text has no files.
// False when a hunk header is damaged or memory runs out; text that is not a diff at all has no files.
@(require_results)
diff_parse :: proc(text: string, allocator := context.allocator) -> (d: Diff, ok: bool) {
	line_count, hunk_count, file_count := count_starts(text)
	d.allocator = allocator
	d.owned.allocator = allocator
	err: runtime.Allocator_Error
	if d.files, err = make([]Diff_File, file_count, allocator); err != nil {return {}, false}
	if d.hunk_slab, err = make([]Hunk, hunk_count, allocator); err != nil {
		diff_destroy(&d)
		return {}, false
	}
	if d.line_slab, err = make([]Diff_Line, line_count, allocator); err != nil {
		diff_destroy(&d)
		return {}, false
	}
	p := Parser {
		d = &d,
	}
	rest := text
	for len(rest) > 0 {
		line: string
		if end := strings.index_byte(rest, '\n'); end < 0 {
			line, rest = rest, ""
		} else {
			line, rest = rest[:end], rest[end + 1:]
		}
		if len(line) > 0 && line[len(line) - 1] == '\r' {line = line[:len(line) - 1]}
		if !parse_line(&p, line) {
			diff_destroy(&d)
			return {}, false
		}
	}
	if p.in_file {finish_file(&p)}
	return d, true
}

// Frees everything the parse allocated; the parsed text is not touched.
diff_destroy :: proc(d: ^Diff) {
	for s in d.owned {
		delete(s, d.allocator)
	}
	delete(d.owned)
	for &h in d.hunk_slab {
		delete(h.edits, d.allocator)
		delete(h.edit_ranges, d.allocator)
	}
	delete(d.files, d.allocator)
	delete(d.hunk_slab, d.allocator)
	delete(d.line_slab, d.allocator)
	d^ = {}
}

// Upper bounds for the slabs: every line may be a diff line, every "@@" line a hunk, and each
// "diff --git" line is exactly one file.
@(private)
count_starts :: proc(text: string) -> (lines, hunks, files: int) {
	rest := text
	for len(rest) > 0 {
		lines += 1
		if strings.has_prefix(rest, "@@") {
			hunks += 1
		} else if strings.has_prefix(rest, "diff --git ") {
			files += 1
		}
		end := strings.index_byte(rest, '\n')
		if end < 0 {break}
		rest = rest[end + 1:]
	}
	return
}

@(private)
parse_line :: proc(p: ^Parser, line: string) -> bool {
	if p.old_left > 0 || p.new_left > 0 {
		if body_line(p, line) {return true}
		// A hunk shorter than its header says: whatever this line is, the hunk is over.
		p.old_left, p.new_left = 0, 0
	}
	if strings.has_prefix(line, "diff --git ") {
		if p.in_file {finish_file(p)}
		p.in_file = true
		p.in_hunk = false
		p.head = {}
		p.hunk_first = p.hunks_n
		p.files_n += 1
		from, to := git_names(p, line[len("diff --git "):]) or_return
		p.head.git_old, p.head.git_new = from, to
		return true
	}
	// "diff --cc" and "diff --combined" (conflicted files) have no hunks this parser reads; their
	// header lines must not overwrite the file before them.
	if strings.has_prefix(line, "diff ") {
		if p.in_file {finish_file(p)}
		p.in_hunk = false
		return true
	}
	if !p.in_file {return true}
	file := &p.d.files[p.files_n - 1]
	if strings.has_prefix(line, "@@ ") {
		return hunk_start(p, line)
	}
	if len(line) > 0 && line[0] == '\\' {
		if p.in_hunk {no_newline(p, line)}
		return true
	}
	if p.hunks_n > p.hunk_first {return true}
	return header_line(p, file, line)
}

@(private)
hunk_start :: proc(p: ^Parser, line: string) -> bool {
	h, ok := hunk_header(line)
	if !ok {return false}
	p.d.hunk_slab[p.hunks_n] = h
	p.hunks_n += 1
	p.in_hunk = true
	p.line_first = p.lines_n
	p.old_left, p.new_left = h.old_count, h.new_count
	p.old_no, p.new_no = h.old_start, h.new_start
	return true
}

// Takes the line as part of the open hunk, or says it is not one.
@(private)
body_line :: proc(p: ^Parser, line: string) -> bool {
	kind: Line_Kind
	text := line
	switch {
	case len(line) == 0 || line[0] == ' ':
		if p.old_left == 0 || p.new_left == 0 {return false}
		if len(line) > 0 {text = line[1:]}
		kind = .Context
	case line[0] == '-':
		if p.old_left == 0 {return false}
		text = line[1:]
		kind = .Removed
	case line[0] == '+':
		if p.new_left == 0 {return false}
		text = line[1:]
		kind = .Added
	case line[0] == '\\':
		no_newline(p, line)
		return true
	case:
		return false
	}
	out := Diff_Line {
		kind = kind,
		text = text,
	}
	file := &p.d.files[p.files_n - 1]
	switch kind {
	case .Context:
		out.old_line, out.new_line = p.old_no, p.new_no
		p.old_no, p.new_no = p.old_no + 1, p.new_no + 1
		p.old_left, p.new_left = p.old_left - 1, p.new_left - 1
	case .Removed:
		out.old_line = p.old_no
		p.old_no += 1
		p.old_left -= 1
		file.removed += 1
	case .Added:
		out.new_line = p.new_no
		p.new_no += 1
		p.new_left -= 1
		file.added += 1
	case .No_Newline:
	}
	push_line(p, out)
	return true
}

@(private)
no_newline :: proc(p: ^Parser, line: string) {
	push_line(p, Diff_Line{kind = .No_Newline, text = line[2:] if len(line) > 2 else ""})
}

@(private)
push_line :: proc(p: ^Parser, line: Diff_Line) {
	p.d.line_slab[p.lines_n] = line
	p.lines_n += 1
	p.d.hunk_slab[p.hunks_n - 1].lines = p.d.line_slab[p.line_first:p.lines_n]
}

// "@@ -a[,b] +c[,d] @@[ section]"; a missing count is 1. A "@@@" line is a combined diff's, which git
// prints only for merges, and is not read.
@(require_results)
@(private)
hunk_header :: proc(line: string) -> (h: Hunk, ok: bool) {
	pos := len("@@ -")
	if !strings.has_prefix(line, "@@ -") {return}
	h.old_start = number(line, &pos) or_return
	h.old_count = 1
	if pos < len(line) && line[pos] == ',' {
		pos += 1
		h.old_count = number(line, &pos) or_return
	}
	if !strings.has_prefix(line[pos:], " +") {return {}, false}
	pos += len(" +")
	h.new_start = number(line, &pos) or_return
	h.new_count = 1
	if pos < len(line) && line[pos] == ',' {
		pos += 1
		h.new_count = number(line, &pos) or_return
	}
	if !strings.has_prefix(line[pos:], " @@") {return {}, false}
	pos += len(" @@")
	h.section = line[pos:]
	if strings.has_prefix(h.section, " ") {h.section = h.section[1:]}
	return h, true
}

@(require_results)
@(private)
number :: proc(s: string, pos: ^int) -> (n: i32, ok: bool) {
	start := pos^
	for pos^ < len(s) && s[pos^] >= '0' && s[pos^] <= '9' {
		if n > (max(i32) - 9) / 10 {return 0, false}
		n = n * 10 + i32(s[pos^] - '0')
		pos^ += 1
	}
	return n, pos^ > start
}

// An extended header line between "diff --git" and the first hunk.
@(private)
header_line :: proc(p: ^Parser, file: ^Diff_File, line: string) -> bool {
	h := &p.head
	switch {
	case strings.has_prefix(line, "new file mode"):
		h.new_file = true
	case strings.has_prefix(line, "deleted file mode"):
		h.deleted = true
	case strings.has_prefix(line, "rename from "):
		h.rename_from = path_token(p, line[len("rename from "):]) or_return
	case strings.has_prefix(line, "rename to "):
		h.rename_to = path_token(p, line[len("rename to "):]) or_return
	case strings.has_prefix(line, "copy from "):
		h.copy_from = path_token(p, line[len("copy from "):]) or_return
	case strings.has_prefix(line, "copy to "):
		h.copy_to = path_token(p, line[len("copy to "):]) or_return
	case strings.has_prefix(line, "--- "):
		h.from, h.from_null = side_path(p, line[len("--- "):], "a/") or_return
	case strings.has_prefix(line, "+++ "):
		h.to, h.to_null = side_path(p, line[len("+++ "):], "b/") or_return
	case strings.has_prefix(line, "Binary files ") || strings.has_prefix(line, "GIT binary patch"):
		file.binary = true
	case strings.has_prefix(line, "index "):
		file.old_oid, file.new_oid = index_oids(line[len("index "):])
	}
	return true
}

// "<old>..<new>[ <mode>]"; an all-zero id is git's name for the side that does not exist.
@(private)
index_oids :: proc(rest: string) -> (old_oid, new_oid: Oid) {
	ids := rest
	if space := strings.index_byte(ids, ' '); space >= 0 {ids = ids[:space]}
	dots := strings.index(ids, "..")
	if dots < 0 {return "", ""}
	return real_oid(ids[:dots]), real_oid(ids[dots + 2:])
}

@(private)
real_oid :: proc(id: string) -> Oid {
	for c in transmute([]u8)id {
		if c != '0' {return id}
	}
	return ""
}

// The file a "---" or "+++" line names, without git's a/ or b/, or null for /dev/null.
@(require_results)
@(private)
side_path :: proc(p: ^Parser, text, prefix: string) -> (path: string, null: bool, ok: bool) {
	token := path_token(p, text) or_return
	if token == "/dev/null" {return "", true, true}
	return strip_prefix(token, prefix), false, true
}

@(private)
strip_prefix :: proc(path, prefix: string) -> string {
	return path[len(prefix):] if strings.has_prefix(path, prefix) else path
}

// A path as git writes it after a keyword: bare, with the trailing tab git adds after a name that has
// spaces, or in quotes with C escapes.
@(require_results)
@(private)
path_token :: proc(p: ^Parser, text: string) -> (token: string, ok: bool) {
	if len(text) > 0 && text[0] == '"' {
		decoded, _ := unquote(p, text) or_return
		return decoded, true
	}
	return strings.trim_right(text, "\t"), true
}

// The two names on a "diff --git" line. Only a mode change or an empty file has no other line that
// names the file, so this need not be perfect for renames of names with spaces: "rename from" and
// "rename to" override it.
@(require_results)
@(private)
git_names :: proc(p: ^Parser, rest: string) -> (from, to: string, ok: bool) {
	if len(rest) > 0 && rest[0] == '"' {
		a, used := unquote(p, rest) or_return
		b := path_token(p, strings.trim_left(rest[used:], " ")) or_return
		return strip_prefix(a, "a/"), strip_prefix(b, "b/"), true
	}
	if at := strings.last_index(rest, ` "b/`); at >= 0 && strings.has_suffix(rest, `"`) {
		b, _ := unquote(p, rest[at + 1:]) or_return
		return strip_prefix(rest[:at], "a/"), strip_prefix(b, "b/"), true
	}
	if len(rest) % 2 == 1 && rest[len(rest) / 2] == ' ' {
		a := strip_prefix(rest[:len(rest) / 2], "a/")
		b := strip_prefix(rest[len(rest) / 2 + 1:], "b/")
		if a == b {return a, b, true}
	}
	at := strings.index(rest, " b/")
	if at < 0 {at = strings.index_byte(rest, ' ')}
	if at < 0 {return rest, rest, true}
	return strip_prefix(rest[:at], "a/"), strip_prefix(rest[at + 1:], "b/"), true
}

// The path in the quotes `text` starts with, and how many bytes the quoted token took. A path without
// escapes borrows from the text; one with them is decoded into memory the diff owns.
@(require_results)
@(private)
unquote :: proc(p: ^Parser, text: string) -> (path: string, used: int, ok: bool) {
	end := 1
	escaped := false
	for end < len(text) && text[end] != '"' {
		if text[end] == '\\' {
			escaped = true
			end += 1
		}
		end += 1
	}
	if end >= len(text) {return "", 0, false}
	inner := text[1:end]
	if !escaped {return inner, end + 1, true}
	buf, err := make([]u8, unescape(nil, inner), p.d.allocator)
	if err != nil {return "", 0, false}
	unescape(buf, inner)
	decoded := string(buf)
	if _, err = append(&p.d.owned, decoded); err != nil {
		delete(buf, p.d.allocator)
		return "", 0, false
	}
	return decoded, end + 1, true
}

// Decodes git's C-style escapes (\a \b \f \n \r \t \v \" \\ and \ooo octal) into `out`, or only counts
// the decoded bytes when `out` is nil.
@(private)
unescape :: proc(out: []u8, text: string) -> int {
	n := 0
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '\\' && i + 1 < len(text) {
			i += 1
			c = text[i]
			switch c {
			case 'a':
				c = 7
			case 'b':
				c = 8
			case 'f':
				c = 12
			case 'n':
				c = 10
			case 'r':
				c = 13
			case 't':
				c = 9
			case 'v':
				c = 11
			case '0' ..= '7':
				value := int(c - '0')
				for digits := 1; digits < 3 && i + 1 < len(text); digits += 1 {
					next := text[i + 1]
					if next < '0' || next > '7' {break}
					i += 1
					value = value * 8 + int(next - '0')
				}
				c = u8(value)
			}
		}
		if out != nil {out[n] = c}
		n += 1
	}
	return n
}

// Fixes the finished file's paths, status and hunks from what its header said.
@(private)
finish_file :: proc(p: ^Parser) {
	h := &p.head
	file := &p.d.files[p.files_n - 1]
	file.hunks = p.d.hunk_slab[p.hunk_first:p.hunks_n]
	switch {
	case h.rename_from != "" || h.rename_to != "":
		file.status = .Renamed
		file.old_path = first_set(h.rename_from, h.from, h.git_old)
		file.new_path = first_set(h.rename_to, h.to, h.git_new)
	case h.copy_from != "" || h.copy_to != "":
		file.status = .Copied
		file.old_path = first_set(h.copy_from, h.from, h.git_old)
		file.new_path = first_set(h.copy_to, h.to, h.git_new)
	case:
		file.status = .Modified
		if h.new_file || h.from_null {
			file.status = .Added
		} else if h.deleted || h.to_null {
			file.status = .Deleted
		}
		path := first_set(h.to, h.from, h.git_new, h.git_old)
		file.old_path, file.new_path = path, path
	}
	p.in_file = false
}

@(private)
first_set :: proc(candidates: ..string) -> string {
	for s in candidates {
		if s != "" {return s}
	}
	return ""
}

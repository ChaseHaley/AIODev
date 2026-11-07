package links

import "aio:localpath"
import "core:strings"

// Row_Join says whether two rows without a wrap flag are one line a program wrapped itself. Word is a
// line broken between words, which loses a space. Direct is a word broken at the edge.
Row_Join :: enum {
	None,
	Word,
	Direct,
}

// Row_Edge describes the end of one row and the start of the row below, in cells.
Row_Edge :: struct {
	above, below:           string,
	tail, head:             string,
	tail_cells, head_cells: int,
	used, indent, columns:  int,
}

// Text interfaces often stop just short of the last column.
@(private)
RIGHT_MARGIN :: 2
// A word holding one of these can be part of a target, or open a quoted one.
@(private)
TARGET_SHAPE :: ":/\\.\"'`"
@(private)
SPACED_LOOKAHEAD :: 3
@(private)
SPACED_BYTES :: 1024
@(private)
CANDIDATE_ENDS :: 32
@(private)
CANDIDATE_BYTES :: 1024
@(private)
LEFT_TOKENS :: 3
@(private)
BREAK_VARIANTS :: 3
SELECTION_ROWS :: 8
@(private)
SELECTION_BYTES :: 4096

// A wrapper only moves to the next row when the next word does not fit, so a shorter word is a real
// line of its own. This never reads the filesystem; a wrong guess is settled by the click.
@(require_results)
row_join :: proc(e: Row_Edge) -> Row_Join {
	if e.used <= 0 || e.head == "" || e.used + 1 + e.head_cells <= e.columns - RIGHT_MARGIN {
		return .None
	}
	if e.used >= e.columns - RIGHT_MARGIN && word_was_split(e) {return .Direct}
	// Ordinary prose gains nothing from joining, and joining it would only lengthen the scan.
	shaped := strings.contains_any(e.above, TARGET_SHAPE) || strings.contains_any(e.below, TARGET_SHAPE)
	return shaped ? .Word : .None
}

@(private, require_results)
word_was_split :: proc(e: Row_Edge) -> bool {
	if !strings.contains_any(e.tail, ":/\\.") {return false}
	last := e.tail[len(e.tail) - 1]
	if last == '/' || last == '\\' {return true}
	// Wrappers only split a word too long for a row of its own. A shorter file path may still be one
	// word, which a click settles, but a URL has no check at click time and reads its evidence here.
	if e.tail_cells + e.head_cells > e.columns - e.indent {return true}
	if !strings.contains(e.tail, "://") {return false}
	return strings.contains_any(e.head[:trim_prose(e.head, 0, len(e.head))], "/\\?=&%#.")
}

@(private, require_results)
has_extension :: proc(path: string) -> bool {
	name := strip_location(path)
	if i := strings.last_index_any(name, "/\\"); i >= 0 {name = name[i + 1:]}
	dot := strings.last_index_byte(name, '.')
	if dot < 0 {return false}
	extension := name[dot + 1:]
	if len(extension) == 0 || len(extension) > 8 || !has_letter(extension) {return false}
	for i in 0 ..< len(extension) {
		c := extension[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {return false}
	}
	return true
}

// A word ends a spaced path when it could not be part of one.
@(private, require_results)
ends_spaced_path :: proc(token: string) -> bool {
	if token == "" || token[0] == '-' {return true}
	if strings.contains_any(strip_location(token), ":\"'<>|*?`") {return true}
	return false
}

// spaced_end extends a drive path across single spaces while later words show the path goes on: a
// word holding a separator, or a nearby filename. Prose punctuation or a filename already reached ends
// it. No filesystem access, so this only sets the underline; the click checks what exists.
@(private, require_results)
spaced_end :: proc(text: string, start, end: int) -> int {
	last := end
	for last - start < SPACED_BYTES {
		if has_extension(text[start:last]) {return last}
		at := last
		next := -1
		ended := false
		for _ in 0 ..< SPACED_LOOKAHEAD {
			if at + 1 >= len(text) || (text[at] != ' ' && text[at] != '\n') || text[at + 1] <= ' ' {
				return last
			}
			first := at + 1
			stop := first
			for stop < len(text) && text[stop] > ' ' {stop += 1}
			trimmed := trim_prose(text, first, stop)
			token := text[first:trimmed]
			if ends_spaced_path(token) {return last}
			ended = trimmed != stop
			if strings.contains_any(token, "/\\") || has_extension(token) {
				next = trimmed
				break
			}
			if ended {return last}
			at = stop
		}
		if next < 0 {return last}
		last = next
		if ended {return last}
	}
	return last
}

// Row breaks are stored as a newline so scanning treats them as a space. A break can also stand for
// nothing, because a program may have broken the word there.
@(require_results)
break_variants :: proc(text: string) -> int {
	count := strings.count(text, "\n")
	return 1 << uint(min(count, BREAK_VARIANTS))
}

// break_variant writes one reading of text into buffer: bit n of mask keeps break n as a space, and
// breaks past the mask stay spaces. The last mask reads every break as a space.
@(require_results)
break_variant :: proc(text: string, mask: int, buffer: []u8) -> (string, bool) {
	at, seen := 0, 0
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '\n' {
			space := seen >= BREAK_VARIANTS || mask & (1 << uint(seen)) != 0
			seen += 1
			if !space {continue}
			c = ' '
		}
		if at >= len(buffer) {return "", false}
		buffer[at] = c
		at += 1
	}
	return string(buffer[:at]), true
}

// candidates appends what a click on the target at start..end could mean, longest first. Ends fall at
// spaces, row breaks and cuts, the places a program broke a word. A relative target can also start at
// the words before it. Callers check each range against the filesystem at click time.
@(require_results)
candidates :: proc(line: string, start, end: int, cuts: []int, out: ^[dynamic]Range) -> bool {
	if start < 0 || start >= end || end > len(line) {return true}
	target := line[start:end]
	if len(target) >= 5 && strings.equal_fold(target[:5], "file:") {return true}
	ends: [CANDIDATE_ENDS]int
	count := 0
	limit := min(len(line), start + CANDIDATE_BYTES)
	for i := start + 1; i <= limit && count < len(ends); i += 1 {
		boundary := false
		if i == len(line) {
			boundary = line[i - 1] > ' '
		} else if (line[i] == ' ' || line[i] == '\n') && line[i - 1] > ' ' {
			boundary = true
		}
		for cut in cuts {
			if cut == i {boundary = true}
		}
		if boundary {
			ends[count] = i
			count += 1
		}
	}
	starts: [1 + LEFT_TOKENS]int
	starts[0] = start
	first_count := 1
	drive := len(target) >= 2 && target[1] == ':'
	if !drive {
		at := start
		for first_count < len(starts) {
			if at == 0 || (line[at - 1] != ' ' && line[at - 1] != '\n') {break}
			stop := at - 1
			if stop == 0 || line[stop - 1] <= ' ' {break}
			begin := stop
			for begin > 0 && line[begin - 1] > ' ' {begin -= 1}
			if line[begin] == '"' || line[begin] == '\'' || line[begin] == '`' {break}
			starts[first_count] = begin
			first_count += 1
			at = begin
		}
	}
	for from in starts[:first_count] {
		previous := -1
		for k := count - 1; k >= 0; k -= 1 {
			to := trim_prose(line, from, ends[k])
			if to == previous || to <= from || (from < start && to < end) {continue}
			previous = to
			if _, err := append(out, Range{from, to}); err != nil {return false}
		}
	}
	return true
}

// selection_line normalizes selected text into out: one line per row, without the indentation a
// program adds to continued rows, with breaks stored as newlines. A long selection is ordinary text.
@(require_results)
selection_line :: proc(raw: string, out: ^[dynamic]u8) -> bool {
	clear(out)
	if raw == "" || len(raw) > SELECTION_BYTES || strings.count(raw, "\n") >= SELECTION_ROWS {return false}
	rest := raw
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim(line, " \t\r")
		if trimmed == "" {continue}
		if len(out) > 0 {
			if _, err := append(out, '\n'); err != nil {return false}
		}
		if _, err := append(out, trimmed); err != nil {return false}
	}
	return len(out) > 0
}

// selection_target finds the target in normalized selected text, without quotes around it. The
// selection is the user's own statement of where the target ends, so spaces are kept. Nothing here
// reads the filesystem; an unavailable file is reported when clicked.
@(require_results)
selection_target :: proc(line: string, relative: bool) -> (Range, bool) {
	start, end := 0, len(line)
	if end >= 2 && line[0] == line[end - 1] && strings.contains_rune("\"'`", rune(line[0])) {
		start += 1
		end -= 1
	}
	if start >= end {return {}, false}
	end = max(trim_prose(line, start, end), start)
	if start >= end {return {}, false}
	text := line[start:end]
	buffer: [SELECTION_BYTES]u8 = ---
	resolved: [TARGET_BYTES]u8 = ---
	for mask := break_variants(text) - 1; mask >= 0; mask -= 1 {
		variant, ok := break_variant(text, mask, buffer[:])
		if !ok {continue}
		if allowed(variant) {return {start, end}, true}
		absolute := localpath.local_absolute(strip_location(variant))
		if !absolute && (!relative || !strings.contains_any(variant, ".\\/") || !relative_plausible(variant)) {
			continue
		}
		if _, resolves := resolve_file(variant, relative ? "C:/" : "", nil, resolved[:]); resolves {
			return {start, end}, true
		}
	}
	return {}, false
}

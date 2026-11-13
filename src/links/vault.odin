package links

import "aio:localpath"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Obsidian wikilinks name notes, not paths: [[Note]] is whichever Note.md the vault holds. Resolving
// one reads the filesystem, so it runs when a link is opened, never while a document draws.

// The folder Obsidian keeps a vault's settings in; the folder holding it is the vault.
@(private)
VAULT_MARKER :: ".obsidian"

// A name search reads at most this many entries, so a link in a document above a huge tree, such
// as a home folder with no vault marker, cannot stall the UI. Real vaults are far smaller.
VAULT_SEARCH_ENTRIES :: 50_000

// The text before any '#' of a wikilink in the document at `document`, as the file it names.
// Empty names the document itself. A name without an extension names a Markdown note; one with
// another extension (chart.png) names that file, or a note whose name merely contains a dot. A name
// with a folder in it is tried against the vault root and then the document's folder; otherwise,
// and when that fails, the vault is searched for a file whose path ends with the name, ignoring
// case and folders starting with '.', and the match nearest the document wins. The vault is the
// nearest folder above the document holding `.obsidian`, else the document's own folder. The
// returned path borrows buffer.
@(require_results)
resolve_wiki :: proc(name, document: string, buffer: []u8) -> (string, bool) {
	if name == "" {return buffer_path(buffer, document)}
	if !localpath.valid_characters(name) || localpath.is_separator(name[0]) {return "", false}
	// Without its trailing separator, so a document at a drive root joins names like any other.
	folder := strings.trim_right(filepath.dir(document), `\/`)
	root := vault_root(folder)

	spellings: [2]string
	count := 0
	extension := filepath.ext(name)
	if extension != "" {spellings[count], count = backslashed(name), count + 1}
	if !strings.equal_fold(extension, ".md") {
		spellings[count], count = backslashed(strings.concatenate({name, ".md"}, context.temp_allocator)), count + 1
	}

	if strings.index_any(name, `/\`) >= 0 {
		for base in ([2]string{root, folder}) {
			for spelling in spellings[:count] {
				path := strings.concatenate({base, `\`, spelling}, context.temp_allocator)
				if os.is_file(path) {return buffer_path(buffer, path)}
			}
		}
	}
	if best, found := vault_search(root, folder, spellings[:count]); found {return buffer_path(buffer, best)}
	return "", false
}

// The nearest folder from `folder` up holding the vault marker, else `folder` itself.
@(private, require_results)
vault_root :: proc(folder: string) -> string {
	for at := len(folder); at > 0; {
		candidate := folder[:at]
		if os.is_dir(strings.concatenate({candidate, `\`, VAULT_MARKER}, context.temp_allocator)) {return candidate}
		at = strings.last_index_any(candidate, `\/`)
	}
	return folder
}

// The file under root whose path ends with one of the spellings, nearest `folder`: fewest folder
// steps between them, then the shortest path, then the first alphabetically. Symbolic links and
// junctions are not followed, so a link cycle cannot loop. Allocates in the temp allocator.
@(private, require_results)
vault_search :: proc(root, folder: string, spellings: []string) -> (best: string, found: bool) {
	// From the root's own folder: a bare drive "C:" would name the drive's current directory.
	walker := os.walker_create(strings.concatenate({root, `\`}, context.temp_allocator))
	defer os.walker_destroy(&walker)
	best_steps := 0
	entries := 0
	for info in os.walker_walk(&walker) {
		entries += 1
		if entries > VAULT_SEARCH_ENTRIES {break}
		// An unreadable folder comes back as an empty entry; the walk goes on without it.
		if info.name == "" {continue}
		if info.type == .Directory {
			if info.name[0] == '.' {os.walker_skip_dir(&walker)}
			continue
		}
		relative := strings.trim_left(info.fullpath[min(len(root), len(info.fullpath)):], `\`)
		if !path_ends_with(relative, spellings) {continue}
		steps := folder_steps(folder, filepath.dir(info.fullpath))
		if found {
			if steps > best_steps {continue}
			if steps == best_steps {
				if len(info.fullpath) > len(best) {continue}
				if len(info.fullpath) == len(best) && info.fullpath >= best {continue}
			}
		}
		owned, err := strings.clone(info.fullpath, context.temp_allocator)
		if err != nil {return best, found}
		best, best_steps, found = owned, steps, true
	}
	return best, found
}

// Whether path is one of the spellings or ends with one after a separator, ignoring case.
@(private, require_results)
path_ends_with :: proc(path: string, spellings: []string) -> bool {
	for spelling in spellings {
		if len(spelling) > len(path) {continue}
		start := len(path) - len(spelling)
		if start > 0 && path[start - 1] != '\\' {continue}
		if strings.equal_fold(path[start:], spelling) {return true}
	}
	return false
}

// The folders between two absolute folders: up from `from` to the folder they share and down to `to`.
@(private, require_results)
folder_steps :: proc(from, to: string) -> int {
	a, b := strings.trim_right(from, `\`), strings.trim_right(to, `\`)
	for a != "" && b != "" {
		a_part, a_rest := split_first(a)
		b_part, b_rest := split_first(b)
		if !strings.equal_fold(a_part, b_part) {break}
		a, b = a_rest, b_rest
	}
	return strings.count(a, `\`) + int(a != "") + strings.count(b, `\`) + int(b != "")
}

@(private, require_results)
split_first :: proc(path: string) -> (first, rest: string) {
	at := strings.index_byte(path, '\\')
	if at < 0 {return path, ""}
	return path[:at], path[at + 1:]
}

// Wikilinks separate folders with '/'; Windows reports paths with '\'.
@(private, require_results)
backslashed :: proc(name: string) -> string {
	if strings.index_byte(name, '/') < 0 {return name}
	out, _ := strings.replace_all(name, "/", `\`, context.temp_allocator)
	return out
}

@(private, require_results)
buffer_path :: proc(buffer: []u8, path: string) -> (string, bool) {
	if len(path) > len(buffer) {return "", false}
	copy(buffer, path)
	return string(buffer[:len(path)]), true
}

package turns

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// The user's repository is only ever read: git runs there with optional locks off, and nothing below
// writes its index, refs, config or objects. What is recorded goes into a private bare repository, the
// store, which borrows the user's objects through `alternates` and keeps one ref per segment so git's
// own reachability decides what a prune may delete. Every proc blocks on git and belongs on the
// recorder's worker thread.

@(private = "file")
FNV_OFFSET :: u64(14695981039346656037)
@(private = "file")
FNV_PRIME :: u64(1099511628211)
@(private = "file")
STORE_NAME :: "store.git"
// The folder in a store directory that holds one file per saved segment.
SEGMENTS_NAME :: "segments"
@(private = "file")
SEGMENT_REFS :: "refs/turns/"

// At most this many untracked files get a patch in an uncommitted diff.
DIFF_UNTRACKED_LIMIT :: 50

// A git repository by its work tree and its common directory, absolute with '/' separators. A linked
// worktree has a work tree of its own but shares the common directory, so every worktree of one
// repository shares one store. The key names the store: 16 lowercase hex digits of FNV-1a 64 over the
// lowercased common directory.
Repository :: struct {
	worktree:   string,
	common_dir: string,
	key:        string,
}

// Not_Repository for a directory that is missing, is not inside a work tree, or that git refuses.
@(require_results)
repository_find :: proc(
	directory: string,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	repo: Repository,
	err: Error,
) {
	defer if err != .None {repository_destroy(&repo, allocator)}
	if !os.is_directory(directory) {return {}, .Not_Repository}
	args := [?]string{"rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"}
	output := git_run(args[:], {cwd = directory, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	if output.code != 0 {return {}, .Not_Repository}
	lines := string(output.stdout)
	toplevel, has_toplevel := strings.split_lines_iterator(&lines)
	common, has_common := strings.split_lines_iterator(&lines)
	if !has_toplevel || !has_common || toplevel == "" || common == "" {
		return {}, .Not_Repository
	}
	repo.worktree = repository_path(toplevel, allocator) or_return
	repo.common_dir = repository_path(common, allocator) or_return
	repo.key = repository_key(repo.common_dir, allocator) or_return
	return repo, .None
}

// Accepts a partly built repository.
repository_destroy :: proc(r: ^Repository, allocator := context.allocator) {
	delete(r.worktree, allocator)
	delete(r.common_dir, allocator)
	delete(r.key, allocator)
	r^ = {}
}

@(private = "file", require_results)
repository_path :: proc(path: string, allocator: runtime.Allocator) -> (result: string, err: Error) {
	end := len(path)
	for end > 1 && repository_separator(path[end - 1]) && !(end == 3 && path[1] == ':') {
		end -= 1
	}
	cloned := git_clone(path[:end], allocator) or_return
	git_slashes(cloned)
	return cloned, .None
}

@(private = "file")
repository_separator :: proc(c: u8) -> bool {
	return c == '/' || c == '\\'
}

// Windows paths differ only in case when they name the same directory, so the key ignores it.
@(private = "file", require_results)
repository_key :: proc(common_dir: string, allocator: runtime.Allocator) -> (string, Error) {
	lowered, lower_error := strings.to_lower(common_dir, allocator)
	if lower_error != nil {return "", .Out_Of_Memory}
	defer delete(lowered, allocator)
	hash := FNV_OFFSET
	for b in transmute([]u8)lowered {
		hash = (hash ~ u64(b)) * FNV_PRIME
	}
	key := fmt.aprintf("%016x", hash, allocator = allocator)
	if key == "" {return "", .Out_Of_Memory}
	return key, .None
}

// The private object store of one repository: <turns>/<key>, with the bare repository in store.git.
Store :: struct {
	directory: string,
	git_dir:   string,
}

// Creates the store when it is missing and repairs what is missing of it otherwise, so it can be
// called again for the same repository. `turns_directory` is absolute.
@(require_results)
store_open :: proc(
	turns_directory: string,
	repo: Repository,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	s: Store,
	err: Error,
) {
	defer if err != .None {store_destroy(&s, allocator)}
	s.directory = git_join_path(allocator, turns_directory, repo.key) or_return
	s.git_dir = git_join_path(allocator, s.directory, STORE_NAME) or_return
	if !store_make_directory(s.directory) {return s, .Failed}
	head := git_join_path(context.temp_allocator, s.git_dir, "HEAD") or_return
	if !os.exists(head) {
		init_args := [?]string{"init", "--bare", "-q", s.git_dir}
		git_check(init_args[:], {cwd = s.directory, cancel = cancel}, allocator) or_return
	}
	// gc would otherwise prune and repack on its own schedule; maintenance here is explicit. Bitmaps
	// are of no use to a store this small.
	settings := [?][2]string{{"gc.auto", "0"}, {"repack.writeBitmaps", "false"}}
	for setting in settings {
		config_args := [?]string{"config", setting[0], setting[1]}
		config_run := Git_Run {
			cwd     = s.directory,
			git_dir = s.git_dir,
			cancel  = cancel,
		}
		git_check(config_args[:], config_run, allocator) or_return
	}
	info := git_join_path(context.temp_allocator, s.git_dir, "objects/info") or_return
	if !store_make_directory(info) {return s, .Failed}
	alternates := git_join_path(context.temp_allocator, info, "alternates") or_return
	// The line ends with LF alone: git ignores a line that ends with CRLF.
	borrowed := git_join_path(context.temp_allocator, repo.common_dir, "objects\n") or_return
	store_write_text(alternates, borrowed, allocator) or_return
	note := git_join_path(context.temp_allocator, s.directory, "repository.txt") or_return
	store_write_text(note, repo.common_dir, allocator) or_return
	segments := git_join_path(context.temp_allocator, s.directory, SEGMENTS_NAME) or_return
	if !store_make_directory(segments) {return s, .Failed}
	return s, .None
}

// Accepts a partly built store.
store_destroy :: proc(s: ^Store, allocator := context.allocator) {
	delete(s.directory, allocator)
	delete(s.git_dir, allocator)
	s^ = {}
}

@(private = "file")
store_make_directory :: proc(path: string) -> bool {
	if make_error := os.make_directory_all(path); make_error != nil {
		log.errorf("could not create %q: %v", path, make_error)
		return false
	}
	return true
}

// Leaves the file alone when it already says `text`.
@(private = "file", require_results)
store_write_text :: proc(path, text: string, allocator: runtime.Allocator) -> Error {
	current, read_error := os.read_entire_file(path, allocator)
	if read_error == nil {
		same := string(current) == text
		delete(current, allocator)
		if same {return .None}
	}
	if write_error := os.write_entire_file(path, text); write_error != nil {
		log.errorf("could not write %q: %v", path, write_error)
		return .Failed
	}
	return .None
}

// A path with uncommitted changes, relative to the work tree with '/' separators. `deleted` is true
// when git says the file is gone from the work tree.
Path_State :: struct {
	path:    string,
	deleted: bool,
}

// Every path with a change in the index or the work tree, untracked files included, ignored files
// not. A rename lists both its names. Submodules are left out.
@(require_results)
dirty_paths :: proc(
	worktree: string,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	states: []Path_State,
	err: Error,
) {
	args := [?]string {
		"status",
		"--porcelain=v1",
		"-z",
		"--untracked-files=all",
		"--ignore-submodules=all",
	}
	output := git_run(args[:], {cwd = worktree, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	if output.code != 0 {return nil, git_failure(args[:], output)}
	return status_parse(string(output.stdout), allocator)
}

path_states_destroy :: proc(states: []Path_State, allocator := context.allocator) {
	for state in states {delete(state.path, allocator)}
	delete(states, allocator)
}

// Porcelain v1 with -z: `XY path`, and after a rename or copy the path it came from as a record of
// its own.
@(private = "file", require_results)
status_parse :: proc(text: string, allocator: runtime.Allocator) -> (result: []Path_State, err: Error) {
	found := make([dynamic]Path_State, 0, 64, context.allocator)
	defer delete(found)
	positions := make(map[string]int, 64, context.allocator)
	defer delete(positions)
	rest := text
	for len(rest) > 0 {
		record := git_take_record(&rest)
		if len(record) < 4 || record[2] != ' ' {continue}
		x, y := record[0], record[1]
		unmerged := x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D')
		deleted := y == 'D' || (x == 'D' && y == ' ')
		// Unmerged files stay in the work tree unless both sides deleted them.
		if unmerged {deleted = x == 'D' && y == 'D'}
		if !status_note(&found, &positions, record[3:], deleted) {return nil, .Out_Of_Memory}
		if x == 'R' || x == 'C' || y == 'R' || y == 'C' {
			source := git_take_record(&rest)
			// A copy leaves its source as it was.
			renamed := x == 'R' || y == 'R'
			if renamed && source != "" && !status_note(&found, &positions, source, true) {
				return nil, .Out_Of_Memory
			}
		}
	}
	states := git_make(Path_State, len(found), allocator) or_return
	for entry, i in found {
		path, clone_error := git_clone(entry.path, allocator)
		if clone_error != .None {
			path_states_destroy(states, allocator)
			return nil, clone_error
		}
		states[i] = {path = path, deleted = entry.deleted}
	}
	return states, .None
}

// A path listed twice, as a staged delete and an untracked file that came back, exists unless every
// entry says it is gone.
@(private = "file")
status_note :: proc(
	found: ^[dynamic]Path_State,
	positions: ^map[string]int,
	path: string,
	deleted: bool,
) -> bool {
	if at, seen := positions^[path]; seen {
		found^[at].deleted = found^[at].deleted && deleted
		return true
	}
	_, append_error := append(found, Path_State{path = path, deleted = deleted})
	if append_error != nil {return false}
	positions^[path] = len(found^) - 1
	return true
}

// `paths` without the ones .gitignore rules out, in order. Tracked files are never ignored. The result
// slice belongs to `allocator`; its strings are the caller's own `paths`.
@(require_results)
keep_unignored :: proc(
	worktree: string,
	paths: []string,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	filtered: []string,
	err: Error,
) {
	if len(paths) == 0 {return nil, .None}
	input, input_error := make([dynamic]u8, 0, 4096, context.allocator)
	if input_error != nil {return nil, .Out_Of_Memory}
	defer delete(input)
	for path in paths {
		if !git_text_add(&input, path, "\x00") {return nil, .Out_Of_Memory}
	}
	args := [?]string{"check-ignore", "--stdin", "-z"}
	run := Git_Run {
		cancel = cancel,
		cwd   = worktree,
		stdin = string(input[:]),
	}
	output := git_run(args[:], run, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	// Exit 1 says that none of the paths is ignored.
	if output.code != 0 && output.code != 1 {return nil, git_failure(args[:], output)}
	ignored := make(map[string]struct{}, 16, context.allocator)
	defer delete(ignored)
	rest := string(output.stdout)
	for len(rest) > 0 {
		record := git_take_record(&rest)
		if record != "" {ignored[record] = {}}
	}
	kept := 0
	for path in paths {
		if path not_in ignored {kept += 1}
	}
	result := git_make(string, kept, allocator) or_return
	at := 0
	for path in paths {
		if path in ignored {continue}
		result[at] = path
		at += 1
	}
	return result, .None
}

oids_destroy :: proc(oids: []Oid, allocator := context.allocator) {
	for oid in oids {delete(oid, allocator)}
	delete(oids, allocator)
}

// Writes the current content of each path, relative to `worktree`, into the store as a blob and
// returns its id; "" for a path that is not a file now, or that git could not read. The work tree
// gives git the .gitattributes and line-ending rules a commit of the file would apply.
@(require_results)
hash_paths :: proc(
	s: Store,
	worktree: string,
	paths: []string,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	result: []Oid,
	err: Error,
) {
	present := make([dynamic]int, 0, len(paths), context.allocator)
	defer delete(present)
	input := make([dynamic]u8, 0, 4096, context.allocator)
	defer delete(input)
	for path, i in paths {
		if !hash_readable(worktree, path) {continue}
		if !git_text_add(&input, path, "\n") {return nil, .Out_Of_Memory}
		append(&present, i)
	}
	oids := git_make(Oid, len(paths), allocator) or_return
	if len(present) == 0 {return oids, .None}
	done, batch_error := hash_batch(s, worktree, string(input[:]), present[:], oids, allocator, cancel)
	if batch_error != .None {
		oids_destroy(oids, allocator)
		return nil, batch_error
	}
	if !done {
		for index in present {
			oid, one_error := hash_one(s, worktree, paths[index], allocator, cancel)
			if one_error != .None {
				oids_destroy(oids, allocator)
				return nil, one_error
			}
			oids[index] = oid
		}
	}
	return oids, .None
}

// hash-object --stdin-paths reads one path per line and unquotes a line that starts with '"'. NTFS
// has no such names, and none with a line break, so a path like that is not a file.
@(private = "file")
hash_readable :: proc(worktree, path: string) -> bool {
	if path == "" || path[0] == '"' || strings.contains_any(path, "\r\n") {return false}
	full, join_error := git_join_path(context.temp_allocator, worktree, path)
	if join_error != .None {return false}
	info, stat_error := os.stat(full, context.temp_allocator)
	if stat_error != nil {return false}
	defer os.file_info_delete(info, context.temp_allocator)
	return info.type == .Regular || info.type == .Symlink
}

// Hashes every path in one git. false when git stopped part way, so the caller hashes them one by
// one: a file that is locked or went away would otherwise cost the ids of all the rest.
@(private = "file", require_results)
hash_batch :: proc(
	s: Store,
	worktree, input: string,
	present: []int,
	oids: []Oid,
	allocator: runtime.Allocator,
	cancel: ^Git_Cancel,
) -> (
	complete: bool,
	err: Error,
) {
	args := [?]string{"hash-object", "-w", "--stdin-paths"}
	edits := [?]string{hash_environment(s)}
	run := Git_Run {
		cancel = cancel,
		cwd   = worktree,
		env   = edits[:],
		stdin = input,
	}
	output := git_run(args[:], run, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	if output.code != 0 {return false, .None}
	counting := string(output.stdout)
	lines := 0
	for line in strings.split_lines_iterator(&counting) {
		if line == "" || !oid_valid(line) {return false, .None}
		lines += 1
	}
	if lines != len(present) {return false, .None}
	reading := string(output.stdout)
	for index in present {
		line, _ := strings.split_lines_iterator(&reading)
		oids[index] = git_clone(line, allocator) or_return
	}
	return true, .None
}

// Blobs go to the store's object directory only, and git finds the user's objects through the store's
// alternates file. git runs in the user's work tree, not with the store as its git dir, so that
// repository's config, attributes and filters (autocrlf, eol, LFS, git-crypt) decide the blob.
@(private = "file")
hash_environment :: proc(s: Store) -> string {
	return fmt.tprintf("GIT_OBJECT_DIRECTORY=%s/objects", s.git_dir)
}

// "" for a file git could not read, which is logged: a file another program holds locked is not a
// reason to lose the rest of a turn.
@(private = "file", require_results)
hash_one :: proc(
	s: Store,
	worktree, path: string,
	allocator: runtime.Allocator,
	cancel: ^Git_Cancel,
) -> (
	oid: Oid,
	err: Error,
) {
	args := [?]string{"hash-object", "-w", "--", path}
	edits := [?]string{hash_environment(s)}
	run := Git_Run {
		cancel = cancel,
		cwd = worktree,
		env = edits[:],
	}
	output := git_run(args[:], run, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	if output.code != 0 {
		log.warnf("could not hash %q: %s", path, strings.trim_space(output.stderr))
		return "", .None
	}
	line := strings.trim_space(string(output.stdout))
	if line == "" || !oid_valid(line) {return "", .None}
	return git_clone(line, allocator)
}

// Keeps the blobs `oids` (the "" ones are skipped) under the ref of segment `id`, so they survive until
// the segment is dropped. The blobs go into a flat tree whose entry names are their ids, and the ref
// points at that tree. Packing the ref copies the blobs borrowed from the user's repository into the
// store, so a gc or prune there cannot take them; the loose copies are then removed.
@(require_results)
segment_keep :: proc(s: Store, id: u64, oids: []Oid, cancel: ^Git_Cancel = nil) -> Error {
	listing := make([dynamic]u8, 0, 4096, context.allocator)
	defer delete(listing)
	seen := make(map[string]struct{}, len(oids), context.allocator)
	defer delete(seen)
	for oid in oids {
		if oid == "" || oid in seen {continue}
		seen[oid] = {}
		if !git_text_add(&listing, "100644 blob ", oid, "\t", oid, "\n") {return .Out_Of_Memory}
	}
	mktree_args := [?]string{"mktree"}
	mktree_run := Git_Run {
		cancel  = cancel,
		cwd     = s.directory,
		git_dir = s.git_dir,
		stdin   = string(listing[:]),
	}
	output := git_run(mktree_args[:], mktree_run, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	if output.code != 0 {return git_failure(mktree_args[:], output)}
	tree := strings.trim_space(string(output.stdout))
	if tree == "" || !oid_valid(tree) {return .Failed}

	run := Git_Run {
		cancel  = cancel,
		cwd     = s.directory,
		git_dir = s.git_dir,
	}
	ref := fmt.tprintf("%s%016x", SEGMENT_REFS, id)
	update_args := [?]string{"update-ref", ref, tree}
	git_check(update_args[:], run, context.allocator) or_return
	// The ref goes first so the objects are reachable while they are packed.
	pack_base := git_join_path(context.temp_allocator, s.git_dir, "objects/pack/pack") or_return
	pack_args := [?]string{"pack-objects", "--revs", "-q", pack_base}
	run.stdin = fmt.tprintf("%s\n", ref)
	git_check(pack_args[:], run, context.allocator) or_return
	run.stdin = ""
	prune_args := [?]string{"prune-packed", "-q"}
	return git_check(prune_args[:], run, context.allocator)
}

// Deletes the refs of the segments; an id with no ref is not an error. Their objects stay until
// store_maintain prunes them.
@(require_results)
segment_drop :: proc(s: Store, ids: []u64, cancel: ^Git_Cancel = nil) -> Error {
	if len(ids) == 0 {return .None}
	input := make([dynamic]u8, 0, 4096, context.allocator)
	defer delete(input)
	for id in ids {
		if !git_text_add(&input, fmt.tprintf("delete %s%016x\n", SEGMENT_REFS, id)) {
			return .Out_Of_Memory
		}
	}
	args := [?]string{"update-ref", "--stdin"}
	run := Git_Run {
		cancel  = cancel,
		cwd     = s.directory,
		git_dir = s.git_dir,
		stdin   = string(input[:]),
	}
	return git_check(args[:], run, context.allocator)
}

// Repacks what the refs still reach into one pack, dropping the packs of deleted segments, then prunes
// the loose objects nothing reaches. Never run between hash_paths and the segment_keep that follows:
// until then nothing reaches the new blobs.
@(require_results)
store_maintain :: proc(s: Store, cancel: ^Git_Cancel = nil) -> Error {
	run := Git_Run {
		cancel  = cancel,
		cwd     = s.directory,
		git_dir = s.git_dir,
		timeout = GIT_LONG_TIMEOUT,
	}
	repack_args := [?]string{"repack", "-a", "-d", "-q"}
	git_check(repack_args[:], run, context.allocator) or_return
	prune_args := [?]string{"prune", "--expire=now"}
	return git_check(prune_args[:], run, context.allocator)
}

// One file's blobs on both sides of a change. The path is already labelled: it carries the work tree
// as a prefix when a diff spans several.
Diff_Entry :: struct {
	path:   string,
	before: Oid,
	after:  Oid,
}

// The patch between the `before` and the `after` side of `entries`, as git writes it for two trees:
// each side is a temporary index in the store, written out as a tree, and the trees are compared with
// rename detection. A side without a blob for a path does not have the file. Equal sides give "".
@(require_results)
diff_entries :: proc(
	s: Store,
	entries: []Diff_Entry,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	patch: string,
	err: Error,
) {
	before_index := git_join_path(context.temp_allocator, s.directory, "diff-before.index") or_return
	after_index := git_join_path(context.temp_allocator, s.directory, "diff-after.index") or_return
	// update-index adds to an index that exists, so one a crashed run left would add its entries.
	_ = os.remove(before_index)
	_ = os.remove(after_index)
	defer {
		_ = os.remove(before_index)
		_ = os.remove(after_index)
	}
	before_tree := diff_side_tree(s, entries, false, before_index, cancel) or_return
	defer delete(before_tree)
	after_tree := diff_side_tree(s, entries, true, after_index, cancel) or_return
	defer delete(after_tree)
	// An explicit prefix keeps a user's diff.noprefix or diff.mnemonicPrefix out of the patch.
	args := [?]string {
		"-c",
		"core.quotePath=false",
		"diff-tree",
		"-p",
		"-r",
		"-M",
		"--no-color",
		"--no-ext-diff",
		"-U3",
		"--src-prefix=a/",
		"--dst-prefix=b/",
		before_tree,
		after_tree,
	}
	run := Git_Run {
		cwd     = s.directory,
		git_dir = s.git_dir,
		cancel  = cancel,
	}
	output := git_run(args[:], run, allocator) or_return
	if output.code != 0 {
		failure := git_failure(args[:], output)
		git_output_destroy(&output, allocator)
		return "", failure
	}
	text := string(output.stdout)
	delete(output.stderr, allocator)
	return text, .None
}

// The tree of one side of a diff, written from a temporary index at `index`. An index with no entries
// writes the empty tree, whatever the object format.
@(private = "file", require_results)
diff_side_tree :: proc(
	s: Store,
	entries: []Diff_Entry,
	after: bool,
	index: string,
	cancel: ^Git_Cancel,
) -> (
	tree: string,
	err: Error,
) {
	input := make([dynamic]u8, 0, 4096, context.allocator)
	defer delete(input)
	for entry in entries {
		oid := entry.after if after else entry.before
		if oid == "" {continue}
		// -z records: <mode> SP <oid> TAB <path> NUL, which takes any path.
		if !git_text_add(&input, "100644 ", oid, "\t", entry.path, "\x00") {return "", .Out_Of_Memory}
	}
	edits := [?]string{fmt.tprintf("GIT_INDEX_FILE=%s", index)}
	run := Git_Run {
		cancel  = cancel,
		cwd     = s.directory,
		git_dir = s.git_dir,
		env     = edits[:],
	}
	if len(input) > 0 {
		run.stdin = string(input[:])
		update_args := [?]string{"update-index", "-z", "--index-info"}
		git_check(update_args[:], run, context.allocator) or_return
		run.stdin = ""
	}
	write_args := [?]string{"write-tree"}
	output := git_run(write_args[:], run, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	if output.code != 0 {return "", git_failure(write_args[:], output)}
	written := strings.trim_space(string(output.stdout))
	if written == "" || !oid_valid(written) {return "", .Failed}
	return git_clone(written, context.allocator)
}

// Which changes of a repository a plain diff shows.
Plain_Mode :: enum u8 {
	// Everything since HEAD: staged and unstaged changes, and untracked files.
	Uncommitted,
	Staged,
	Unstaged,
}

// A git diff of the work tree as the user would see it, read-only. In an uncommitted diff each
// untracked file (up to DIFF_UNTRACKED_LIMIT) is a new-file patch, and `omitted` counts the ones left
// out. A repository without commits is compared with the empty tree.
@(require_results)
diff_plain :: proc(
	worktree: string,
	mode: Plain_Mode,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	patch: string,
	omitted: int,
	err: Error,
) {
	buffer := make([dynamic]u8, 0, 4096, allocator)
	defer if err != .None {delete(buffer)}
	staged := [?]string{"--cached"}
	base: [1]string
	revisions: []string
	switch mode {
	case .Staged:
		revisions = staged[:]
	case .Unstaged:
	case .Uncommitted:
		base[0] = plain_base(worktree, cancel) or_return
		revisions = base[:]
	}
	tracked := plain_diff(worktree, revisions, nil, context.allocator, cancel) or_return
	defer git_output_destroy(&tracked, context.allocator)
	if tracked.code != 0 {
		diff_args := [?]string{"diff"}
		return "", 0, git_failure(diff_args[:], tracked)
	}
	if !git_text_add(&buffer, string(tracked.stdout)) {return "", 0, .Out_Of_Memory}
	if mode == .Uncommitted {
		omitted = plain_untracked(worktree, &buffer, cancel) or_return
	}
	return string(buffer[:]), omitted, .None
}

// HEAD, or the empty tree of the repository's object format when there is no commit yet.
@(private = "file", require_results)
plain_base :: proc(worktree: string, cancel: ^Git_Cancel) -> (base: string, err: Error) {
	head_args := [?]string{"rev-parse", "--verify", "--quiet", "HEAD"}
	head := git_run(head_args[:], {cwd = worktree, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&head, context.allocator)
	if head.code == 0 {return "HEAD", .None}
	if head.code != 1 {return "", git_failure(head_args[:], head)}
	tree_args := [?]string{"hash-object", "-t", "tree", "--stdin"}
	empty := git_run(tree_args[:], {cwd = worktree, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&empty, context.allocator)
	if empty.code != 0 {return "", git_failure(tree_args[:], empty)}
	tree := strings.trim_space(string(empty.stdout))
	if tree == "" || !oid_valid(tree) {return "", .Failed}
	return git_clone(tree, context.temp_allocator)
}

// One `git diff`, whose output the caller reads. git diff refreshes the index when file times changed
// but contents did not, and rewrites .git/index to say so even with optional locks off; the user's
// index stays as it is with autoRefreshIndex off. The prefix is explicit as in diff_entries.
@(private = "file", require_results)
plain_diff :: proc(
	worktree: string,
	revisions, tail: []string,
	allocator: runtime.Allocator,
	cancel: ^Git_Cancel,
) -> (
	Git_Output,
	Error,
) {
	args := make([dynamic]string, 0, 16 + len(revisions) + len(tail), context.allocator)
	defer delete(args)
	append(&args, "-c", "diff.autoRefreshIndex=false", "-c", "core.quotePath=false", "diff")
	append(&args, ..revisions)
	append(&args, "--no-color", "--no-ext-diff", "-U3", "--src-prefix=a/", "--dst-prefix=b/")
	append(&args, ..tail)
	// Without a path list a file named like the revision would make the argument ambiguous.
	if len(tail) == 0 {append(&args, "--")}
	return git_run(args[:], {cwd = worktree, cancel = cancel}, allocator)
}

// Appends the new-file patch of each untracked file to `buffer`; returns how many files were past
// the limit.
@(private = "file", require_results)
plain_untracked :: proc(
	worktree: string,
	buffer: ^[dynamic]u8,
	cancel: ^Git_Cancel,
) -> (
	omitted: int,
	err: Error,
) {
	list_args := [?]string{"ls-files", "-o", "--exclude-standard", "-z"}
	listing := git_run(list_args[:], {cwd = worktree, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&listing, context.allocator)
	if listing.code != 0 {return 0, git_failure(list_args[:], listing)}
	no_index := [?]string{"--no-index"}
	rest := string(listing.stdout)
	taken := 0
	for len(rest) > 0 {
		path := git_take_record(&rest)
		// A nested repository is listed as a directory, which has no patch.
		if path == "" || path[len(path) - 1] == '/' {continue}
		if taken == DIFF_UNTRACKED_LIMIT {
			omitted += 1
			continue
		}
		taken += 1
		tail := [?]string{"--", "/dev/null", path}
		patch := plain_diff(worktree, no_index[:], tail[:], context.allocator, cancel) or_return
		defer git_output_destroy(&patch, context.allocator)
		// Exit 1 says the files differ. It also says the file went away meanwhile, with no patch.
		if patch.code != 1 || len(patch.stdout) == 0 {continue}
		if !git_text_add(buffer, string(patch.stdout)) {return 0, .Out_Of_Memory}
	}
	return omitted, .None
}

// One entry of `git worktree list`: `path` is absolute with '/' separators, `head` the commit checked out
// ("" for an unborn branch or a bare repository). A prunable worktree's directory is gone.
Worktree :: struct {
	path:     string,
	head:     Oid,
	bare:     bool,
	prunable: bool,
}

// Every worktree of the repository `directory` belongs to, the main one first. Read-only.
@(require_results)
worktrees_list :: proc(
	directory: string,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	list: []Worktree,
	err: Error,
) {
	args := [?]string{"worktree", "list", "--porcelain", "-z"}
	output := git_run(args[:], {cwd = directory, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	if output.code != 0 {return nil, git_failure(args[:], output)}
	found := make([dynamic]Worktree, 0, 4, allocator)
	current: Worktree
	defer if err != .None {
		delete(current.path, allocator)
		delete(current.head, allocator)
		worktrees_destroy(found[:], allocator)
	}
	// A block is its attribute records and an empty record after them.
	rest := string(output.stdout)
	for len(rest) > 0 {
		record := git_take_record(&rest)
		if record == "" {
			worktree_flush(&found, &current) or_return
			continue
		}
		key, _, value := strings.partition(record, " ")
		switch key {
		case "worktree":
			worktree_flush(&found, &current) or_return
			current.path = repository_path(value, allocator) or_return
		case "HEAD":
			if strings.trim_left(value, "0") != "" {current.head = git_clone(value, allocator) or_return}
		case "bare":
			current.bare = true
		case "prunable":
			current.prunable = true
		}
	}
	worktree_flush(&found, &current) or_return
	return found[:], .None
}

// Moves a finished entry into the list; one without a path is nothing.
@(private = "file", require_results)
worktree_flush :: proc(found: ^[dynamic]Worktree, current: ^Worktree) -> Error {
	if current.path == "" {return .None}
	if _, append_error := append(found, current^); append_error != nil {return .Out_Of_Memory}
	current^ = {}
	return .None
}

// Frees the strings and the slice; `allocator` is the one worktrees_list got.
worktrees_destroy :: proc(list: []Worktree, allocator := context.allocator) {
	for entry in list {
		delete(entry.path, allocator)
		delete(entry.head, allocator)
	}
	delete(list, allocator)
}

// The commit the worktree's HEAD started at: where its oldest HEAD reflog entry came from (the entry's
// new commit when it created HEAD), else its current HEAD; "" when unborn.
@(require_results)
worktree_origin :: proc(
	worktree: string,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	oid: Oid,
	err: Error,
) {
	path_args := [?]string{"rev-parse", "--path-format=absolute", "--git-path", "logs/HEAD"}
	located := git_run(path_args[:], {cwd = worktree, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&located, context.allocator)
	if located.code == 0 {
		log_path := strings.trim_space(string(located.stdout))
		if first, found := reflog_first_oid(log_path); found {return git_clone(first, allocator)}
	}
	head_args := [?]string{"rev-parse", "--verify", "--quiet", "HEAD^{commit}"}
	head := git_run(head_args[:], {cwd = worktree, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&head, context.allocator)
	if head.code == 1 {return "", .None}
	if head.code != 0 {return "", git_failure(head_args[:], head)}
	text := strings.trim_space(string(head.stdout))
	if !oid_valid(text) {return "", .Failed}
	return git_clone(text, allocator)
}

// The first line of a reflog is `<old> <new> <identity>`: the commit the log started from. Only the
// head of the file is read. The result lives in the temp allocator.
@(private = "file")
reflog_first_oid :: proc(path: string) -> (oid: string, found: bool) {
	file, open_error := os.open(path)
	if open_error != nil {return "", false}
	defer os.close(file)
	buffer: [512]u8
	count, read_error := os.read(file, buffer[:])
	if read_error != nil || count <= 0 {return "", false}
	line := string(buffer[:count])
	if end := strings.index_byte(line, '\n'); end >= 0 {line = line[:end]}
	old, _, tail := strings.partition(line, " ")
	next, _, _ := strings.partition(tail, " ")
	if oid_valid(old) && strings.trim_left(old, "0") != "" {
		cloned, _ := strings.clone(old, context.temp_allocator)
		return cloned, cloned != ""
	}
	if oid_valid(next) && strings.trim_left(next, "0") != "" {
		cloned, _ := strings.clone(next, context.temp_allocator)
		return cloned, cloned != ""
	}
	return "", false
}

// Worktree-relative paths whose content differs from `base`, committed or not, plus untracked files
// that are not ignored. An empty `base` lists every tracked and untracked file.
@(require_results)
changed_since :: proc(
	worktree: string,
	base: Oid,
	allocator := context.allocator,
	cancel: ^Git_Cancel = nil,
) -> (
	paths: []string,
	err: Error,
) {
	seen := make(map[string]struct{}, 64, context.allocator)
	defer delete(seen)
	found := make([dynamic]string, 0, 64, allocator)
	defer if err != .None {
		for path in found {delete(path, allocator)}
		delete(found)
	}
	if base != "" {
		diff_args := [?]string {
			"-c",
			"diff.autoRefreshIndex=false",
			"diff",
			"--name-only",
			"-z",
			"--no-renames",
			"--ignore-submodules=all",
			base,
			"--",
		}
		changed_collect(worktree, diff_args[:], &found, &seen, allocator, cancel) or_return
	}
	list_args := [?]string{"ls-files", "-z", "-o", "--exclude-standard"}
	changed_collect(worktree, list_args[:], &found, &seen, allocator, cancel) or_return
	if base == "" {
		tracked_args := [?]string{"ls-files", "-z", "-c"}
		changed_collect(worktree, tracked_args[:], &found, &seen, allocator, cancel) or_return
	}
	return found[:], .None
}

// Runs git and appends each NUL-separated path it prints that is not in `seen` yet.
@(private = "file", require_results)
changed_collect :: proc(
	worktree: string,
	args: []string,
	found: ^[dynamic]string,
	seen: ^map[string]struct{},
	allocator: runtime.Allocator,
	cancel: ^Git_Cancel,
) -> Error {
	output := git_run(args, {cwd = worktree, cancel = cancel}, context.allocator) or_return
	defer git_output_destroy(&output, context.allocator)
	if output.code != 0 {return git_failure(args, output)}
	rest := string(output.stdout)
	for len(rest) > 0 {
		path := git_take_record(&rest)
		// A nested repository is listed as a directory.
		if path == "" || path[len(path) - 1] == '/' || path in seen^ {continue}
		cloned := git_clone(path, allocator) or_return
		if _, append_error := append(found, cloned); append_error != nil {
			delete(cloned, allocator)
			return .Out_Of_Memory
		}
		// The key is the caller's clone, which stays alive as long as the map is used.
		seen^[cloned] = {}
	}
	return .None
}

// Removes the turns directory with everything in it, recorded turns, inbox and marker alike; a
// directory that is not there is already removed. A store's packs are read-only files, which
// os.remove clears before deleting.
@(require_results)
store_delete_all :: proc(turns_directory: string) -> Error {
	if turns_directory == "" || !os.exists(turns_directory) {return .None}
	if remove_error := store_remove_tree(turns_directory); remove_error != nil {
		log.errorf("could not delete %q: %v", turns_directory, remove_error)
		return .Failed
	}
	return .None
}

@(private = "file", require_results)
store_remove_tree :: proc(path: string) -> os.Error {
	entries, read_error := os.read_all_directory_by_path(path, context.allocator)
	if read_error != nil {
		if read_error == .Not_Exist {return nil}
		return read_error
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		if entry.type == .Directory {
			store_remove_tree(entry.fullpath) or_return
		} else {
			os.remove(entry.fullpath) or_return
		}
	}
	return os.remove(path)
}

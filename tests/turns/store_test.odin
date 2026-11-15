package turns_test

import "aio:turns"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import w "core:sys/windows"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Every test runs real git in directories of its own under the temp directory, and skips when git is
// not installed. Temporary strings live in the temp allocator, which the test runner clears.

@(private = "file")
store_git_installed :: proc() -> bool {
	output, err := turns.git_run({"--version"}, {})
	if err != .None {
		log.warnf("git is not available (%v): skipping", err)
		return false
	}
	turns.git_output_destroy(&output)
	return true
}

@(private = "file")
store_root :: proc(t: ^testing.T) -> (string, bool) {
	made, err := os.make_directory_temp("", "aio-store-*", context.allocator)
	if !testing.expectf(t, err == nil, "temp directory: %v", err) {return "", false}
	bytes := transmute([]u8)made
	for &b in bytes {
		if b == '\\' {b = '/'}
	}
	return made, true
}

// store_delete_all is what removes the read-only files git leaves in a store.
@(private = "file")
store_remove :: proc(root: string) {
	if err := turns.store_delete_all(root); err != .None {log.warnf("could not remove %s", root)}
	delete(root)
}

// The trimmed stdout of git run in `directory`; false, and a failed test, unless it exits 0.
@(private = "file")
store_git :: proc(t: ^testing.T, directory: string, args: ..string) -> (string, bool) {
	output, err := turns.git_run(args, {cwd = directory}, context.temp_allocator)
	if !testing.expectf(t, err == .None, "git %v: %v", args, err) {return "", false}
	if !testing.expectf(t, output.code == 0, "git %v exited %d: %s", args, output.code, output.stderr) {
		return "", false
	}
	return strings.trim_space(string(output.stdout)), true
}

// The exit code of git, -1 when it did not run.
@(private = "file")
store_git_code :: proc(directory: string, args: ..string) -> int {
	output, err := turns.git_run(args, {cwd = directory}, context.temp_allocator)
	if err != .None {return -1}
	return output.code
}

@(private = "file")
store_write :: proc(t: ^testing.T, directory, name, text: string) -> bool {
	path := fmt.tprintf("%s/%s", directory, name)
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		if !testing.expectf(t, os.make_directory_all(path[:slash]) == nil, "mkdir %s", path[:slash]) {
			return false
		}
	}
	return testing.expectf(t, os.write_entire_file(path, text) == nil, "write %s", path)
}

@(private = "file")
store_read :: proc(t: ^testing.T, path: string) -> ([]u8, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expectf(t, err == nil, "read %s: %v", path, err) {return nil, false}
	return data, true
}

@(private = "file")
store_repo :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
	path := fmt.tprintf("%s/%s", root, name)
	if !testing.expect(t, os.make_directory_all(path) == nil) {return "", false}
	if _, ok := store_git(t, path, "init", "-q"); !ok {return "", false}
	if _, ok := store_git(t, path, "config", "user.name", "Test"); !ok {return "", false}
	if _, ok := store_git(t, path, "config", "user.email", "test@example.com"); !ok {return "", false}
	if _, ok := store_git(t, path, "config", "core.autocrlf", "false"); !ok {return "", false}
	return path, true
}

@(private = "file")
store_commit :: proc(t: ^testing.T, repo: string) -> bool {
	if _, ok := store_git(t, repo, "add", "-A"); !ok {return false}
	_, committed := store_git(t, repo, "commit", "-q", "-m", "test")
	return committed
}

// A repository with one commit, found, with its store open.
@(private = "file")
Store_Setup :: struct {
	root:  string,
	repo:  string,
	found: turns.Repository,
	store: turns.Store,
}

@(private = "file")
store_setup :: proc(t: ^testing.T) -> (setup: Store_Setup, ok: bool) {
	if !store_git_installed() {return {}, false}
	root, root_ok := store_root(t)
	if !root_ok {return {}, false}
	setup.root = root
	defer if !ok {store_teardown(&setup)}
	repo, repo_ok := store_repo(t, root, "repo")
	if !repo_ok {return setup, false}
	setup.repo = repo
	store_write(t, repo, "base.txt", "base\n")
	if !store_commit(t, repo) {return setup, false}
	found, find_error := turns.repository_find(repo)
	if !testing.expect_value(t, find_error, turns.Error.None) {return setup, false}
	setup.found = found
	opened, open_error := turns.store_open(fmt.tprintf("%s/turns", root), found)
	if !testing.expect_value(t, open_error, turns.Error.None) {return setup, false}
	setup.store = opened
	return setup, true
}

@(private = "file")
store_teardown :: proc(setup: ^Store_Setup) {
	turns.store_destroy(&setup.store)
	turns.repository_destroy(&setup.found)
	if setup.root != "" {store_remove(setup.root)}
	setup^ = {}
}

// The FNV-1a 64 key of a common directory, worked out apart from the package.
@(private = "file")
store_expected_key :: proc(common_dir: string) -> string {
	lowered := strings.to_lower(common_dir, context.temp_allocator)
	hash := u64(14695981039346656037)
	for b in transmute([]u8)lowered {
		hash = (hash ~ u64(b)) * 1099511628211
	}
	return fmt.tprintf("%016x", hash)
}

@(private = "file")
store_expect_state :: proc(t: ^testing.T, states: []turns.Path_State, path: string, deleted: bool) {
	for state in states {
		if state.path != path {continue}
		testing.expectf(t, state.deleted == deleted, "%s: deleted is %v", path, state.deleted)
		return
	}
	testing.expectf(t, false, "%s is not listed", path)
}

@(private = "file")
store_expect_absent :: proc(t: ^testing.T, states: []turns.Path_State, path: string) {
	for state in states {
		testing.expectf(t, state.path != path, "%s is listed", path)
	}
}

// Whether a pack of the store, not an alternate, holds `oid`.
@(private = "file")
store_pack_has :: proc(t: ^testing.T, store: turns.Store, oid: string) -> bool {
	pack_directory := fmt.tprintf("%s/objects/pack", store.git_dir)
	entries, err := os.read_all_directory_by_path(pack_directory, context.temp_allocator)
	if !testing.expectf(t, err == nil, "read %s: %v", pack_directory, err) {return false}
	for entry in entries {
		if !strings.has_suffix(entry.name, ".idx") {continue}
		verify := []string{"--git-dir", store.git_dir, "verify-pack", "-v", entry.fullpath}
		listing, ok := store_git(t, store.directory, ..verify)
		if ok && strings.contains(listing, oid) {return true}
	}
	return false
}

// A blob of `text` in the store, hashed from a scratch file of the work tree.
@(private = "file")
store_blob :: proc(t: ^testing.T, setup: Store_Setup, text: string) -> string {
	store_write(t, setup.repo, "scratch.tmp", text)
	paths := [?]string{"scratch.tmp"}
	oids, err := turns.hash_paths(setup.store, setup.repo, paths[:], context.temp_allocator)
	if !testing.expect_value(t, err, turns.Error.None) || len(oids) != 1 {return ""}
	return oids[0]
}

// What a read-only look at a repository must leave as it was.
@(private = "file")
Store_Snapshot :: struct {
	index:   []u8,
	mtime:   time.Time,
	config:  []u8,
	head:    []u8,
	objects: string,
	refs:    string,
	names:   string,
}

@(private = "file")
store_snapshot :: proc(t: ^testing.T, repo: string) -> (snapshot: Store_Snapshot, ok: bool) {
	git_dir := fmt.tprintf("%s/.git", repo)
	index_path := fmt.tprintf("%s/index", git_dir)
	info, stat_error := os.stat(index_path, context.temp_allocator)
	if !testing.expectf(t, stat_error == nil, "stat %s: %v", index_path, stat_error) {return {}, false}
	snapshot.mtime = info.modification_time
	snapshot.index = store_read(t, index_path) or_return
	snapshot.config = store_read(t, fmt.tprintf("%s/config", git_dir)) or_return
	snapshot.head = store_read(t, fmt.tprintf("%s/HEAD", git_dir)) or_return
	snapshot.objects = store_git(t, repo, "count-objects", "-v") or_return
	snapshot.refs = store_git(t, repo, "for-each-ref") or_return
	entries, list_error := os.read_all_directory_by_path(git_dir, context.temp_allocator)
	if !testing.expectf(t, list_error == nil, "read %s: %v", git_dir, list_error) {return {}, false}
	names := make([dynamic]string, 0, len(entries), context.temp_allocator)
	for entry in entries {append(&names, entry.name)}
	slice.sort(names[:])
	snapshot.names = strings.join(names[:], "|", context.temp_allocator)
	return snapshot, true
}

@(private = "file")
store_expect_same :: proc(t: ^testing.T, before, after: Store_Snapshot) {
	testing.expect(t, slice.equal(before.index, after.index), "the user's index bytes changed")
	testing.expect(t, before.mtime == after.mtime, "the user's index time changed")
	testing.expect(t, slice.equal(before.config, after.config), "the user's config changed")
	testing.expect(t, slice.equal(before.head, after.head), "the user's HEAD changed")
	testing.expect_value(t, after.objects, before.objects)
	testing.expect_value(t, after.refs, before.refs)
	testing.expect_value(t, after.names, before.names)
}

@(test)
repository_find_reports_the_work_tree_the_common_directory_and_a_key :: proc(t: ^testing.T) {
	if !store_git_installed() {return}
	root, root_ok := store_root(t)
	if !root_ok {return}
	defer store_remove(root)
	path, repo_ok := store_repo(t, root, "repo")
	if !repo_ok {return}
	deep := fmt.tprintf("%s/deep/er", path)
	if !testing.expect(t, os.make_directory_all(deep) == nil) {return}

	repo, err := turns.repository_find(path)
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.repository_destroy(&repo)
	testing.expect(t, strings.equal_fold(repo.worktree, path), repo.worktree)
	testing.expect(t, strings.equal_fold(repo.common_dir, fmt.tprintf("%s/.git", path)), repo.common_dir)
	testing.expect(t, !strings.contains(repo.worktree, "\\"), repo.worktree)
	testing.expect(t, !strings.contains(repo.common_dir, "\\"), repo.common_dir)
	testing.expect_value(t, repo.key, store_expected_key(repo.common_dir))
	testing.expect_value(t, len(repo.key), 16)

	nested, nested_error := turns.repository_find(deep)
	if !testing.expect_value(t, nested_error, turns.Error.None) {return}
	defer turns.repository_destroy(&nested)
	testing.expect_value(t, nested.worktree, repo.worktree)
	testing.expect_value(t, nested.common_dir, repo.common_dir)
	testing.expect_value(t, nested.key, repo.key)

	plain := fmt.tprintf("%s/plain", root)
	if !testing.expect(t, os.make_directory_all(plain) == nil) {return}
	_, plain_error := turns.repository_find(plain)
	testing.expect_value(t, plain_error, turns.Error.Not_Repository)
	_, missing_error := turns.repository_find(fmt.tprintf("%s/missing", root))
	testing.expect_value(t, missing_error, turns.Error.Not_Repository)
}

@(test)
a_linked_worktree_has_its_own_work_tree_and_its_repository_s_key :: proc(t: ^testing.T) {
	if !store_git_installed() {return}
	root, root_ok := store_root(t)
	if !root_ok {return}
	defer store_remove(root)
	path, repo_ok := store_repo(t, root, "repo")
	if !repo_ok {return}
	store_write(t, path, "a.txt", "a\n")
	if !store_commit(t, path) {return}
	linked_path := fmt.tprintf("%s/linked", root)
	if _, ok := store_git(t, path, "worktree", "add", "-q", linked_path, "-b", "side"); !ok {return}

	main_repo, main_error := turns.repository_find(path)
	if !testing.expect_value(t, main_error, turns.Error.None) {return}
	defer turns.repository_destroy(&main_repo)
	linked, linked_error := turns.repository_find(linked_path)
	if !testing.expect_value(t, linked_error, turns.Error.None) {return}
	defer turns.repository_destroy(&linked)
	testing.expect(t, strings.equal_fold(linked.worktree, linked_path), linked.worktree)
	testing.expect(t, !strings.equal_fold(linked.worktree, main_repo.worktree), "same work tree")
	testing.expect_value(t, linked.common_dir, main_repo.common_dir)
	testing.expect_value(t, linked.key, main_repo.key)
}

@(test)
store_open_builds_the_store_and_a_second_open_changes_nothing :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	blob, blob_ok := store_git(t, setup.repo, "rev-parse", ":base.txt")
	if !blob_ok {return}
	store := setup.store
	alternates_path := fmt.tprintf("%s/objects/info/alternates", store.git_dir)
	first_alternates, read_ok := store_read(t, alternates_path)
	if !read_ok {return}

	again, again_error := turns.store_open(fmt.tprintf("%s/turns", setup.root), setup.found)
	if !testing.expect_value(t, again_error, turns.Error.None) {return}
	defer turns.store_destroy(&again)
	testing.expect_value(t, again.directory, store.directory)
	testing.expect_value(t, again.git_dir, store.git_dir)
	testing.expect(t, strings.has_suffix(store.directory, setup.found.key), store.directory)
	testing.expect(t, strings.has_suffix(store.git_dir, "/store.git"), store.git_dir)

	second_alternates, second_ok := store_read(t, alternates_path)
	if !second_ok {return}
	testing.expect(t, slice.equal(first_alternates, second_alternates), "the alternates file changed")
	testing.expect_value(t, string(second_alternates), fmt.tprintf("%s/objects\n", setup.found.common_dir))
	testing.expect(t, !strings.contains(string(second_alternates), "\r"), "the alternates file has a CR")

	note, note_ok := store_read(t, fmt.tprintf("%s/repository.txt", store.directory))
	if note_ok {testing.expect_value(t, string(note), setup.found.common_dir)}
	testing.expect(t, os.is_directory(fmt.tprintf("%s/segments", store.directory)), "no segments directory")
	auto, auto_ok := store_git(t, store.directory, "--git-dir", store.git_dir, "config", "--get", "gc.auto")
	if auto_ok {testing.expect_value(t, auto, "0")}
	// An alternates file git ignores would leave the user's blobs out of reach.
	code := store_git_code(store.directory, "--git-dir", store.git_dir, "cat-file", "-e", blob)
	testing.expect_value(t, code, 0)
}

@(test)
dirty_paths_lists_modified_deleted_renamed_and_untracked_files :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	repo := setup.repo
	store_write(t, repo, ".gitignore", "*.log\n")
	store_write(t, repo, "a.txt", "alpha\n")
	store_write(t, repo, "gone.txt", "going away\n")
	store_write(t, repo, "old.txt", "a body long enough for rename detection\nsecond line\nthird line\n")
	if !store_commit(t, repo) {return}
	store_write(t, repo, "a.txt", "alpha changed\n")
	testing.expect(t, os.remove(fmt.tprintf("%s/gone.txt", repo)) == nil, "could not delete gone.txt")
	store_git(t, repo, "mv", "old.txt", "renamed.txt")
	store_write(t, repo, "nest/deep/n.txt", "untracked\n")
	store_write(t, repo, "x.log", "ignored\n")
	store_write(t, repo, "staged.txt", "staged\n")
	store_git(t, repo, "add", "staged.txt")

	states, err := turns.dirty_paths(repo)
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.path_states_destroy(states)
	store_expect_state(t, states, "a.txt", false)
	store_expect_state(t, states, "gone.txt", true)
	store_expect_state(t, states, "renamed.txt", false)
	store_expect_state(t, states, "old.txt", true)
	store_expect_state(t, states, "nest/deep/n.txt", false)
	store_expect_state(t, states, "staged.txt", false)
	store_expect_absent(t, states, "x.log")
	store_expect_absent(t, states, ".gitignore")
	store_expect_absent(t, states, "base.txt")
	testing.expect_value(t, len(states), 6)
}

@(test)
a_staged_delete_whose_file_came_back_is_not_deleted :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	store_git(t, setup.repo, "rm", "-q", "--cached", "base.txt")
	states, err := turns.dirty_paths(setup.repo)
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.path_states_destroy(states)
	testing.expect_value(t, len(states), 1)
	store_expect_state(t, states, "base.txt", false)
}

@(test)
dirty_paths_of_a_clean_repository_is_empty :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	states, err := turns.dirty_paths(setup.repo)
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.path_states_destroy(states)
	testing.expect_value(t, len(states), 0)
}

@(test)
keep_unignored_drops_ignored_paths_and_keeps_tracked_ones :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	repo := setup.repo
	store_write(t, repo, ".gitignore", "*.log\nbuild/\n")
	store_write(t, repo, "forced.log", "tracked although ignored\n")
	store_git(t, repo, "add", "-f", "forced.log")
	if !store_commit(t, repo) {return}
	paths := [?]string {
		"a.txt",
		"x.log",
		"build/out.o",
		"src/main.odin",
		"build/deeper/y.c",
		"forced.log",
		"new.txt",
	}
	kept, err := turns.keep_unignored(repo, paths[:])
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer delete(kept)
	expected := [?]string{"a.txt", "src/main.odin", "forced.log", "new.txt"}
	if testing.expect_value(t, len(kept), len(expected)) {
		for want, i in expected {testing.expect_value(t, kept[i], want)}
	}

	// git exits 1 when none of the paths is ignored.
	clean := [?]string{"a.txt", "src/x.odin"}
	all, all_error := turns.keep_unignored(repo, clean[:])
	if !testing.expect_value(t, all_error, turns.Error.None) {return}
	defer delete(all)
	testing.expect_value(t, len(all), 2)

	none, none_error := turns.keep_unignored(repo, nil)
	testing.expect_value(t, none_error, turns.Error.None)
	testing.expect_value(t, len(none), 0)
}

@(test)
hash_paths_matches_git_hash_object_and_leaves_the_users_repository_alone :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	repo := setup.repo
	store_write(t, repo, ".gitattributes", "*.txt text eol=lf\n")
	store_write(t, repo, "plain.txt", "hash me\n")
	store_write(t, repo, "dir with space/s p.txt", "spaced\n")
	store_write(t, repo, "crlf.txt", "a\r\nb\r\n")

	paths := [?]string {
		"plain.txt",
		"dir with space/s p.txt",
		"crlf.txt",
		"missing.txt",
		"dir with space",
		"plain.txt",
	}
	oids, err := turns.hash_paths(setup.store, repo, paths[:])
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.oids_destroy(oids)
	if !testing.expect_value(t, len(oids), len(paths)) {return}

	for index in ([?]int{0, 1, 2, 5}) {
		expected, expected_ok := store_git(t, repo, "hash-object", paths[index])
		if !expected_ok {continue}
		testing.expect_value(t, oids[index], expected)
		in_store := store_git_code(
			setup.store.directory,
			"--git-dir",
			setup.store.git_dir,
			"cat-file",
			"-e",
			oids[index],
		)
		testing.expectf(t, in_store == 0, "%s is not in the store", paths[index])
		// Hashing wrote into the store only.
		borrowed := store_git_code(repo, "cat-file", "-e", oids[index])
		testing.expectf(t, borrowed != 0, "%s was written to the user's repository", paths[index])
	}
	// The work tree's .gitattributes decided the line endings: without them the blob differs.
	raw, raw_ok := store_git(t, repo, "hash-object", "--no-filters", "crlf.txt")
	if raw_ok {testing.expect(t, raw != oids[2], "the line-ending rule was not applied")}
	testing.expect_value(t, oids[3], "")
	testing.expect_value(t, oids[4], "")
}

@(test)
hash_paths_follows_the_users_repository_config_and_writes_no_object_there :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	repo := setup.repo
	// The repository's own setting is the opposite of what any other repository would get.
	probe, _ := turns.git_run({"config", "--get", "core.autocrlf"}, {cwd = setup.root}, context.temp_allocator)
	global := strings.trim_space(string(probe.stdout))
	local := "false" if global == "true" else "true"
	if _, local_ok := store_git(t, repo, "config", "core.autocrlf", local); !local_ok {return}
	store_write(t, repo, "crlf.dat", "a\r\nb\r\n")
	before, before_ok := store_git(t, repo, "count-objects", "-v")
	if !before_ok {return}

	paths := [?]string{"crlf.dat"}
	oids, err := turns.hash_paths(setup.store, repo, paths[:])
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.oids_destroy(oids)
	if !testing.expect_value(t, len(oids), 1) {return}
	expected, expected_ok := store_git(t, repo, "hash-object", "crlf.dat")
	if expected_ok {testing.expect_value(t, oids[0], expected)}
	git_dir := setup.store.git_dir
	in_store := store_git_code(setup.store.directory, "--git-dir", git_dir, "cat-file", "-e", oids[0])
	testing.expect_value(t, in_store, 0)
	after, after_ok := store_git(t, repo, "count-objects", "-v")
	if after_ok {testing.expect_value(t, after, before)}
	borrowed := store_git_code(repo, "cat-file", "-e", oids[0])
	testing.expect(t, borrowed != 0, "the blob is in the user's repository")
}

@(test)
a_plain_diff_works_when_a_file_is_named_like_the_revision :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	store_write(t, setup.repo, "HEAD", "not a revision\n")
	patch, _, err := turns.diff_plain(setup.repo, .Uncommitted)
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer delete(patch)
	testing.expect(t, strings.contains(patch, "diff --git a/HEAD b/HEAD"), patch)
}

@(test)
hash_paths_keeps_the_other_ids_when_a_file_cannot_be_read :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	repo := setup.repo
	store_write(t, repo, "first.txt", "first\n")
	store_write(t, repo, "locked.txt", "locked\n")
	store_write(t, repo, "last.txt", "last\n")
	locked_path := fmt.tprintf("%s/locked.txt", repo)
	wide := w.utf8_to_wstring(locked_path, context.temp_allocator)
	// No sharing at all: git cannot open the file while this handle lives.
	handle := w.CreateFileW(wide, w.GENERIC_READ, 0, nil, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, nil)
	if !testing.expect(t, handle != w.INVALID_HANDLE_VALUE, "could not lock the file") {return}
	defer testing.expect(t, bool(w.CloseHandle(handle)))

	paths := [?]string{"first.txt", "locked.txt", "last.txt"}
	oids, err := turns.hash_paths(setup.store, repo, paths[:])
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.oids_destroy(oids)
	if !testing.expect_value(t, len(oids), 3) {return}
	first, first_ok := store_git(t, repo, "hash-object", "first.txt")
	last, last_ok := store_git(t, repo, "hash-object", "last.txt")
	if first_ok {testing.expect_value(t, oids[0], first)}
	testing.expect_value(t, oids[1], "")
	if last_ok {testing.expect_value(t, oids[2], last)}
}

@(test)
segment_keep_makes_a_ref_and_packs_the_blobs_including_the_users :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	store := setup.store
	users, users_ok := store_git(t, setup.repo, "rev-parse", ":base.txt")
	if !users_ok {return}
	added := store_blob(t, setup, "only in the store\n")
	if added == "" {return}

	oids := [?]string{users, added, "", users}
	id := u64(0x1234abcd)
	if !testing.expect_value(t, turns.segment_keep(store, id, oids[:]), turns.Error.None) {return}

	ref := "refs/turns/000000001234abcd"
	rev_parse := []string{"--git-dir", store.git_dir, "rev-parse", "--verify", "-q", ref}
	tree, tree_ok := store_git(t, store.directory, ..rev_parse)
	if !tree_ok {return}
	listing, listing_ok := store_git(t, store.directory, "--git-dir", store.git_dir, "ls-tree", tree)
	if listing_ok {
		testing.expect_value(t, len(strings.split_lines(listing, context.temp_allocator)), 2)
		testing.expect(t, strings.contains(listing, fmt.tprintf("%s\t%s", users, users)), listing)
		testing.expect(t, strings.contains(listing, fmt.tprintf("%s\t%s", added, added)), listing)
	}
	counts, counts_ok := store_git(t, store.directory, "--git-dir", store.git_dir, "count-objects", "-v")
	if counts_ok {testing.expect(t, strings.contains(counts, "count: 0\n"), counts)}
	testing.expect(t, store_pack_has(t, store, users), "the user's blob is not in the store's pack")
	testing.expect(t, store_pack_has(t, store, added), "the new blob is not in the store's pack")

	// The copy stands on its own: the store reads both blobs with its alternates file gone.
	alternates_path := fmt.tprintf("%s/objects/info/alternates", store.git_dir)
	if !testing.expect(t, os.rename(alternates_path, fmt.tprintf("%s.off", alternates_path)) == nil) {return}
	for oid in ([?]string{users, added}) {
		code := store_git_code(store.directory, "--git-dir", store.git_dir, "cat-file", "-e", oid)
		testing.expectf(t, code == 0, "%s is missing without the alternates", oid)
	}
}

@(test)
segment_keep_of_no_blobs_still_makes_a_ref_to_the_empty_tree :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	store := setup.store
	if !testing.expect_value(t, turns.segment_keep(store, 7, nil), turns.Error.None) {return}
	tree, tree_ok := store_git(
		t,
		store.directory,
		"--git-dir",
		store.git_dir,
		"rev-parse",
		"--verify",
		"-q",
		"refs/turns/0000000000000007",
	)
	if tree_ok {testing.expect_value(t, tree, "4b825dc642cb6eb9a060e54bf8d69288fbee4904")}
	// Keeping the same segment again is not an error.
	testing.expect_value(t, turns.segment_keep(store, 7, nil), turns.Error.None)
}

@(test)
dropping_segments_and_maintaining_removes_their_blobs_and_keeps_the_others :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	store := setup.store
	blob_a := store_blob(t, setup, "only in a\n")
	blob_b := store_blob(t, setup, "only in b\n")
	if blob_a == "" || blob_b == "" {return}
	a_oids := [?]string{blob_a}
	b_oids := [?]string{blob_b}
	if !testing.expect_value(t, turns.segment_keep(store, 1, a_oids[:]), turns.Error.None) {return}
	if !testing.expect_value(t, turns.segment_keep(store, 2, b_oids[:]), turns.Error.None) {return}

	// An id that has no ref is not an error.
	drop := [?]u64{1, 0xdead}
	testing.expect_value(t, turns.segment_drop(store, drop[:]), turns.Error.None)
	testing.expect_value(t, turns.segment_drop(store, nil), turns.Error.None)
	refs, refs_ok := store_git(t, store.directory, "--git-dir", store.git_dir, "for-each-ref", "refs/turns")
	if refs_ok {
		testing.expect(t, !strings.contains(refs, "0000000000000001"), refs)
		testing.expect(t, strings.contains(refs, "0000000000000002"), refs)
	}
	// Nothing is deleted before maintenance.
	still := store_git_code(store.directory, "--git-dir", store.git_dir, "cat-file", "-e", blob_a)
	testing.expect_value(t, still, 0)

	testing.expect_value(t, turns.store_maintain(store), turns.Error.None)
	gone := store_git_code(store.directory, "--git-dir", store.git_dir, "cat-file", "-e", blob_a)
	testing.expectf(t, gone != 0, "the dropped segment's blob survived maintenance")
	kept := store_git_code(store.directory, "--git-dir", store.git_dir, "cat-file", "-e", blob_b)
	testing.expect_value(t, kept, 0)
}

@(test)
diff_entries_writes_added_modified_deleted_and_renamed_files :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	store := setup.store
	body := "a body long enough for rename detection\nline two\nline three\nline four\n"
	before_mod := store_blob(t, setup, "one\ntwo\nthree\n")
	after_mod := store_blob(t, setup, "one\nTWO\nthree\n")
	deleted := store_blob(t, setup, "to be deleted\n")
	added := store_blob(t, setup, "brand new\n")
	same := store_blob(t, setup, "unchanged\n")
	moved := store_blob(t, setup, body)
	if before_mod == "" || after_mod == "" || deleted == "" || added == "" || same == "" || moved == "" {
		return
	}

	entries := [?]turns.Diff_Entry {
		{path = "mod.txt", before = before_mod, after = after_mod},
		{path = "gone.txt", before = deleted},
		{path = "added.txt", after = added},
		{path = "dir/same.txt", before = same, after = same},
		{path = "old/name.txt", before = moved},
		{path = "new/name.txt", after = moved},
	}
	patch, err := turns.diff_entries(store, entries[:])
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer delete(patch)
	for want in ([?]string {
			"diff --git a/mod.txt b/mod.txt",
			"-two\n",
			"+TWO\n",
			"diff --git a/added.txt b/added.txt",
			"new file mode 100644",
			"+brand new\n",
			"diff --git a/gone.txt b/gone.txt",
			"deleted file mode 100644",
			"-to be deleted\n",
			"rename from old/name.txt",
			"rename to new/name.txt",
		}) {
		testing.expectf(t, strings.contains(patch, want), "the patch lacks %q:\n%s", want, patch)
	}
	testing.expect(t, !strings.contains(patch, "same.txt"), "an unchanged file is in the patch")
	for name in ([?]string{"diff-before.index", "diff-after.index"}) {
		left := fmt.tprintf("%s/%s", store.directory, name)
		testing.expectf(t, !os.exists(left), "%s was left behind", name)
	}

	parsed, parsed_ok := turns.diff_parse(patch)
	if testing.expect(t, parsed_ok, "diff_parse rejected the patch") {
		defer turns.diff_destroy(&parsed)
		testing.expect_value(t, len(parsed.files), 4)
	}

	// Equal sides, and no entries at all, make an empty patch.
	flat := [?]turns.Diff_Entry{{path = "dir/same.txt", before = same, after = same}}
	empty, empty_error := turns.diff_entries(store, flat[:])
	testing.expect_value(t, empty_error, turns.Error.None)
	testing.expect_value(t, empty, "")
	delete(empty)
	nothing, nothing_error := turns.diff_entries(store, nil)
	testing.expect_value(t, nothing_error, turns.Error.None)
	testing.expect_value(t, nothing, "")
	delete(nothing)
}

@(test)
diff_plain_shows_staged_unstaged_and_uncommitted_changes_and_leaves_the_index_alone :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	repo := setup.repo
	store_write(t, repo, "a.txt", "a1\n")
	store_write(t, repo, "b.txt", "b1\n")
	store_write(t, repo, "keep.txt", "keep\n")
	if !store_commit(t, repo) {return}
	store_write(t, repo, "a.txt", "a2\n")
	store_write(t, repo, "staged.txt", "s\n")
	store_git(t, repo, "add", "a.txt", "staged.txt")
	store_write(t, repo, "b.txt", "b2\n")
	store_write(t, repo, "u/new file.txt", "untracked\n")
	// New file time, same content: a plain git diff would rewrite the index to record it.
	store_write(t, repo, "keep.txt", "keep\n")
	before, snapshot_ok := store_snapshot(t, repo)
	if !snapshot_ok {return}

	staged, staged_omitted, staged_error := turns.diff_plain(repo, .Staged)
	if !testing.expect_value(t, staged_error, turns.Error.None) {return}
	defer delete(staged)
	testing.expect(t, strings.contains(staged, "diff --git a/a.txt b/a.txt"), staged)
	testing.expect(t, strings.contains(staged, "+++ b/staged.txt"), staged)
	testing.expect(t, !strings.contains(staged, "b.txt"), "an unstaged file is in the staged diff")
	testing.expect(t, !strings.contains(staged, "new file.txt"), "an untracked file is in the staged diff")
	testing.expect_value(t, staged_omitted, 0)

	unstaged, unstaged_omitted, unstaged_error := turns.diff_plain(repo, .Unstaged)
	if !testing.expect_value(t, unstaged_error, turns.Error.None) {return}
	defer delete(unstaged)
	testing.expect(t, strings.contains(unstaged, "diff --git a/b.txt b/b.txt"), unstaged)
	testing.expect(t, !strings.contains(unstaged, "a.txt"), "a staged file is in the unstaged diff")
	testing.expect(t, !strings.contains(unstaged, "keep.txt"), "a file with the same content is in the diff")
	testing.expect_value(t, unstaged_omitted, 0)

	all, all_omitted, all_error := turns.diff_plain(repo, .Uncommitted)
	if !testing.expect_value(t, all_error, turns.Error.None) {return}
	defer delete(all)
	for want in ([?]string {
			"diff --git a/a.txt b/a.txt",
			"diff --git a/b.txt b/b.txt",
			"diff --git a/staged.txt b/staged.txt",
			"diff --git a/u/new file.txt b/u/new file.txt",
			"new file mode 100644",
			"+untracked\n",
		}) {
		testing.expectf(t, strings.contains(all, want), "the uncommitted diff lacks %q:\n%s", want, all)
	}
	testing.expect(t, !strings.contains(all, "keep.txt"), "a file with the same content is in the diff")
	testing.expect_value(t, all_omitted, 0)

	parsed, parsed_ok := turns.diff_parse(all)
	if testing.expect(t, parsed_ok, "diff_parse rejected the patch") {
		defer turns.diff_destroy(&parsed)
		testing.expect_value(t, len(parsed.files), 4)
	}

	after, after_ok := store_snapshot(t, repo)
	if after_ok {store_expect_same(t, before, after)}
}

@(test)
an_uncommitted_diff_stops_at_fifty_untracked_files_and_counts_the_rest :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	extra := 3
	for i in 0 ..< turns.DIFF_UNTRACKED_LIMIT + extra {
		store_write(t, setup.repo, fmt.tprintf("many/f%02d.txt", i), "x\n")
	}
	patch, omitted, err := turns.diff_plain(setup.repo, .Uncommitted)
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer delete(patch)
	testing.expect_value(t, strings.count(patch, "diff --git "), turns.DIFF_UNTRACKED_LIMIT)
	testing.expect_value(t, omitted, extra)
}

@(test)
a_repository_without_commits_diffs_against_the_empty_tree :: proc(t: ^testing.T) {
	if !store_git_installed() {return}
	root, root_ok := store_root(t)
	if !root_ok {return}
	defer store_remove(root)
	repo, repo_ok := store_repo(t, root, "fresh")
	if !repo_ok {return}
	store_write(t, repo, "s.txt", "staged\n")
	store_git(t, repo, "add", "s.txt")
	store_write(t, repo, "s.txt", "staged and edited\n")
	store_write(t, repo, "u.txt", "untracked\n")

	all, _, all_error := turns.diff_plain(repo, .Uncommitted)
	if !testing.expect_value(t, all_error, turns.Error.None) {return}
	defer delete(all)
	testing.expect(t, strings.contains(all, "+staged and edited\n"), all)
	testing.expect(t, strings.contains(all, "diff --git a/u.txt b/u.txt"), all)

	staged, _, staged_error := turns.diff_plain(repo, .Staged)
	if !testing.expect_value(t, staged_error, turns.Error.None) {return}
	defer delete(staged)
	testing.expect(t, strings.contains(staged, "+staged\n"), staged)
	testing.expect(t, !strings.contains(staged, "u.txt"), staged)

	unstaged, _, unstaged_error := turns.diff_plain(repo, .Unstaged)
	if !testing.expect_value(t, unstaged_error, turns.Error.None) {return}
	defer delete(unstaged)
	testing.expect(t, strings.contains(unstaged, "+staged and edited\n"), unstaged)
}

@(test)
no_proc_writes_to_the_users_repository :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	repo := setup.repo
	store_write(t, repo, ".gitignore", "*.log\n")
	store_write(t, repo, "tracked.txt", "tracked\n")
	store_write(t, repo, "sub/other.txt", "other\n")
	if !store_commit(t, repo) {return}
	store_write(t, repo, "sub/other.txt", "other changed\n")
	store_git(t, repo, "add", "sub/other.txt")
	store_write(t, repo, "tracked.txt", "tracked\n")
	store_write(t, repo, "new.txt", "new\n")
	store_write(t, repo, "x.log", "ignored\n")
	before, before_ok := store_snapshot(t, repo)
	if !before_ok {return}

	found, find_error := turns.repository_find(repo)
	if !testing.expect_value(t, find_error, turns.Error.None) {return}
	defer turns.repository_destroy(&found)
	store, store_error := turns.store_open(fmt.tprintf("%s/turns", setup.root), found)
	if !testing.expect_value(t, store_error, turns.Error.None) {return}
	defer turns.store_destroy(&store)
	states, states_error := turns.dirty_paths(repo)
	testing.expect_value(t, states_error, turns.Error.None)
	defer turns.path_states_destroy(states)
	paths := [?]string{"tracked.txt", "sub/other.txt", "new.txt", "x.log", "gone.txt"}
	kept, kept_error := turns.keep_unignored(repo, paths[:])
	testing.expect_value(t, kept_error, turns.Error.None)
	defer delete(kept)
	hashed, hashed_error := turns.hash_paths(store, repo, paths[:])
	testing.expect_value(t, hashed_error, turns.Error.None)
	defer turns.oids_destroy(hashed)
	if len(hashed) == len(paths) {
		entries := [?]turns.Diff_Entry{{path = "tracked.txt", after = hashed[0]}}
		patch, patch_error := turns.diff_entries(store, entries[:])
		testing.expect_value(t, patch_error, turns.Error.None)
		delete(patch)
		testing.expect_value(t, turns.segment_keep(store, 1, hashed), turns.Error.None)
	}
	for mode in ([?]turns.Plain_Mode{.Uncommitted, .Staged, .Unstaged}) {
		patch, _, patch_error := turns.diff_plain(repo, mode)
		testing.expect_value(t, patch_error, turns.Error.None)
		delete(patch)
	}
	ids := [?]u64{1}
	testing.expect_value(t, turns.segment_drop(store, ids[:]), turns.Error.None)
	testing.expect_value(t, turns.store_maintain(store), turns.Error.None)

	after, after_ok := store_snapshot(t, repo)
	if after_ok {store_expect_same(t, before, after)}
}

@(test)
store_delete_all_removes_the_whole_directory_and_is_fine_when_it_is_gone :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	users, users_ok := store_git(t, setup.repo, "rev-parse", ":base.txt")
	if !users_ok {return}
	oids := [?]string{users}
	// A pack, whose files git marks read-only, and a file of the app's own.
	if !testing.expect_value(t, turns.segment_keep(setup.store, 3, oids[:]), turns.Error.None) {return}
	turns_directory := fmt.tprintf("%s/turns", setup.root)
	store_write(t, turns_directory, "inbox/event.json", "{}")
	testing.expect(t, os.is_directory(setup.store.git_dir), "no store to delete")

	testing.expect_value(t, turns.store_delete_all(turns_directory), turns.Error.None)
	testing.expect(t, !os.exists(turns_directory), "the turns directory is still there")
	testing.expect_value(t, turns.store_delete_all(turns_directory), turns.Error.None)
	testing.expect_value(t, turns.store_delete_all(""), turns.Error.None)
}

@(test)
git_run_hands_over_bytes_untouched_and_reports_a_missing_git :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	// CRLF through stdin and stdout, and a NUL, must arrive as they were sent.
	content := "a\r\nb\r\n\x00c"
	written, write_error := turns.git_run(
		{"hash-object", "-w", "--no-filters", "--stdin"},
		{cwd = setup.repo, stdin = content},
		context.temp_allocator,
	)
	if !testing.expect_value(t, write_error, turns.Error.None) {return}
	testing.expect_value(t, written.code, 0)
	oid := strings.trim_space(string(written.stdout))
	read, read_error := turns.git_run({"cat-file", "blob", oid}, {cwd = setup.repo}, context.temp_allocator)
	if !testing.expect_value(t, read_error, turns.Error.None) {return}
	testing.expect_value(t, string(read.stdout), content)

	missing := "0000000000000000000000000000000000000000"
	failed, failed_error := turns.git_run({"cat-file", "-p", missing}, {cwd = setup.repo})
	testing.expect_value(t, failed_error, turns.Error.None)
	testing.expect(t, failed.code != 0, "git did not fail")
	testing.expect(t, failed.stderr != "", "no stderr kept")
	turns.git_output_destroy(&failed)

	// With PATH gone there is no git to start.
	_, missing_error := turns.git_run({"--version"}, {env = {"PATH="}})
	testing.expect_value(t, missing_error, turns.Error.Git_Missing)
}

@(private = "file")
store_raise_after_a_moment :: proc(cancel: ^turns.Git_Cancel) {
	time.sleep(100 * time.Millisecond)
	sync.atomic_store(&cancel.flag, true)
}

@(test)
a_raised_cancel_flag_makes_every_store_proc_fail_at_once :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	cancel := turns.Git_Cancel {
		flag = true,
	}
	started := time.tick_now()
	paths := [?]string{"base.txt"}
	ids := [?]u64{1}
	_, find_error := turns.repository_find(setup.repo, context.allocator, &cancel)
	testing.expect_value(t, find_error, turns.Error.Failed)
	other := fmt.tprintf("%s/other", setup.root)
	_, open_error := turns.store_open(other, setup.found, context.allocator, &cancel)
	testing.expect_value(t, open_error, turns.Error.Failed)
	_, dirty_error := turns.dirty_paths(setup.repo, context.allocator, &cancel)
	testing.expect_value(t, dirty_error, turns.Error.Failed)
	_, keep_error := turns.keep_unignored(setup.repo, paths[:], context.allocator, &cancel)
	testing.expect_value(t, keep_error, turns.Error.Failed)
	_, hash_error := turns.hash_paths(setup.store, setup.repo, paths[:], context.allocator, &cancel)
	testing.expect_value(t, hash_error, turns.Error.Failed)
	testing.expect_value(t, turns.segment_keep(setup.store, 1, nil, &cancel), turns.Error.Failed)
	testing.expect_value(t, turns.segment_drop(setup.store, ids[:], &cancel), turns.Error.Failed)
	testing.expect_value(t, turns.store_maintain(setup.store, &cancel), turns.Error.Failed)
	_, entries_error := turns.diff_entries(setup.store, nil, context.allocator, &cancel)
	testing.expect_value(t, entries_error, turns.Error.Failed)
	_, _, plain_error := turns.diff_plain(setup.repo, .Uncommitted, context.allocator, &cancel)
	testing.expect_value(t, plain_error, turns.Error.Failed)
	// Nothing was started, so nothing had to be waited for.
	testing.expect(t, time.tick_since(started) < time.Second, "cancelled calls were slow")
}

@(test)
cancelling_during_a_slow_diff_stops_it_within_a_moment :: proc(t: ^testing.T) {
	setup, ok := store_setup(t)
	if !ok {return}
	defer store_teardown(&setup)
	// One git per untracked file keeps the diff busy for longer than the flag takes to rise.
	for i in 0 ..< turns.DIFF_UNTRACKED_LIMIT {
		store_write(t, setup.repo, fmt.tprintf("many/f%02d.txt", i), "x\n")
	}
	cancel: turns.Git_Cancel
	raiser := thread.create_and_start_with_poly_data(&cancel, store_raise_after_a_moment)
	defer {
		thread.join(raiser)
		thread.destroy(raiser)
	}
	started := time.tick_now()
	patch, _, err := turns.diff_plain(setup.repo, .Uncommitted, context.allocator, &cancel)
	elapsed := time.tick_since(started)
	delete(patch)
	testing.expect_value(t, err, turns.Error.Failed)
	testing.expect(t, elapsed < time.Second, "the diff did not stop soon after the flag rose")
}

@(test)
worktrees_list_names_the_main_worktree_first_and_flags_a_deleted_one_prunable :: proc(t: ^testing.T) {
	if !store_git_installed() {return}
	root, root_ok := store_root(t)
	if !root_ok {return}
	defer store_remove(root)
	repo, repo_ok := store_repo(t, root, "repo")
	if !repo_ok {return}
	store_write(t, repo, "a.txt", "a\n")
	if !store_commit(t, repo) {return}
	head, head_ok := store_git(t, repo, "rev-parse", "HEAD")
	if !head_ok {return}
	locked_path := fmt.tprintf("%s/locked", root)
	gone_path := fmt.tprintf("%s/gone", root)
	if _, ok := store_git(t, repo, "worktree", "add", "-q", locked_path, "-b", "locked"); !ok {return}
	if _, ok := store_git(t, repo, "worktree", "lock", locked_path); !ok {return}
	if _, ok := store_git(t, repo, "worktree", "add", "-q", gone_path, "-b", "gone"); !ok {return}
	if !testing.expect_value(t, turns.store_delete_all(gone_path), turns.Error.None) {return}

	// Listing from a linked worktree gives the same list.
	list, err := turns.worktrees_list(locked_path)
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.worktrees_destroy(list)
	if !testing.expect_value(t, len(list), 3) {return}
	testing.expect(t, strings.equal_fold(list[0].path, repo), list[0].path)
	testing.expect_value(t, list[0].head, head)
	testing.expect(t, !list[0].prunable && !list[0].bare, "main worktree flags")
	found_locked, found_gone := false, false
	for entry in list[1:] {
		testing.expect(t, !strings.contains_rune(entry.path, '\\'), entry.path)
		testing.expect_value(t, entry.head, head)
		testing.expect(t, !entry.bare, entry.path)
		if strings.equal_fold(entry.path, locked_path) {
			found_locked = true
			testing.expect(t, !entry.prunable, "a locked worktree is not prunable")
		} else if strings.equal_fold(entry.path, gone_path) {
			found_gone = true
			testing.expect(t, entry.prunable, "a deleted worktree is prunable")
		}
	}
	testing.expect(t, found_locked, "the locked worktree is listed")
	testing.expect(t, found_gone, "the deleted worktree is listed")
}

@(test)
worktrees_list_of_a_repository_without_commits_has_an_empty_head :: proc(t: ^testing.T) {
	if !store_git_installed() {return}
	root, root_ok := store_root(t)
	if !root_ok {return}
	defer store_remove(root)
	repo, repo_ok := store_repo(t, root, "repo")
	if !repo_ok {return}
	list, err := turns.worktrees_list(repo)
	if !testing.expect_value(t, err, turns.Error.None) {return}
	defer turns.worktrees_destroy(list)
	if !testing.expect_value(t, len(list), 1) {return}
	testing.expect_value(t, list[0].head, "")
	origin, origin_error := turns.worktree_origin(repo)
	testing.expect_value(t, origin_error, turns.Error.None)
	testing.expect_value(t, origin, "")
}

@(test)
worktree_origin_is_the_commit_the_worktree_was_created_from :: proc(t: ^testing.T) {
	if !store_git_installed() {return}
	root, root_ok := store_root(t)
	if !root_ok {return}
	defer store_remove(root)
	repo, repo_ok := store_repo(t, root, "repo")
	if !repo_ok {return}
	store_write(t, repo, "a.txt", "a\n")
	if !store_commit(t, repo) {return}
	start, start_ok := store_git(t, repo, "rev-parse", "HEAD")
	if !start_ok {return}
	store_write(t, repo, "a.txt", "main moved on\n")
	if !store_commit(t, repo) {return}
	linked := fmt.tprintf("%s/linked", root)
	if _, ok := store_git(t, repo, "worktree", "add", "-q", linked, "-b", "side", start); !ok {return}
	store_write(t, linked, "b.txt", "one\n")
	if !store_commit(t, linked) {return}
	store_write(t, linked, "b.txt", "two\n")
	if !store_commit(t, linked) {return}

	origin, err := turns.worktree_origin(linked)
	testing.expect_value(t, err, turns.Error.None)
	testing.expect_value(t, origin, start)
	testing.expect_value(t, store_git_code(linked, "diff", "--quiet", start, "HEAD"), 1)
	delete(origin)
}

@(private = "file")
store_expect_paths :: proc(t: ^testing.T, got: []string, want: ..string) {
	testing.expect_value(t, len(got), len(want))
	for path in want {
		testing.expectf(t, slice.contains(got, path), "%q is missing from %v", path, got)
	}
}

@(test)
changed_since_lists_committed_uncommitted_and_untracked_paths_but_not_ignored_ones :: proc(t: ^testing.T) {
	if !store_git_installed() {return}
	root, root_ok := store_root(t)
	if !root_ok {return}
	defer store_remove(root)
	repo, repo_ok := store_repo(t, root, "repo")
	if !repo_ok {return}
	store_write(t, repo, ".gitignore", "*.log\n")
	store_write(t, repo, "base.txt", "base\n")
	store_write(t, repo, "keep.txt", "keep\n")
	store_write(t, repo, "gone.txt", "gone\n")
	if !store_commit(t, repo) {return}
	base, base_ok := store_git(t, repo, "rev-parse", "HEAD")
	if !base_ok {return}

	clean, clean_error := turns.changed_since(repo, base)
	testing.expect_value(t, clean_error, turns.Error.None)
	store_expect_paths(t, clean)
	delete(clean)

	store_write(t, repo, "sub/committed.txt", "c\n")
	if !store_commit(t, repo) {return}
	store_write(t, repo, "base.txt", "changed\n")
	if !testing.expect(t, os.remove(fmt.tprintf("%s/gone.txt", repo)) == nil) {return}
	store_write(t, repo, "new dir/untracked.txt", "u\n")
	store_write(t, repo, "noise.log", "ignored\n")

	paths, err := turns.changed_since(repo, base)
	testing.expect_value(t, err, turns.Error.None)
	store_expect_paths(t, paths, "sub/committed.txt", "base.txt", "gone.txt", "new dir/untracked.txt")
	for path in paths {delete(path)}
	delete(paths)

	everything, all_error := turns.changed_since(repo, "")
	testing.expect_value(t, all_error, turns.Error.None)
	store_expect_paths(
		t,
		everything,
		".gitignore",
		"base.txt",
		"keep.txt",
		"gone.txt",
		"sub/committed.txt",
		"new dir/untracked.txt",
	)
	for path in everything {delete(path)}
	delete(everything)
}

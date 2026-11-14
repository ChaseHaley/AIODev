package app_test

import "aio:turns"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"

// Each test drives a real turn worker over real git, in directories of its own under the temp
// directory and with no platform, so results are polled. They skip when git is not installed.

@(private = "file")
WAIT :: 10 * time.Second

// A change is reported by the watcher within moments, but a drain only takes what has arrived.
@(private = "file")
SETTLE :: 600 * time.Millisecond

@(private = "file")
KEY_A :: "0123456789abcdef0123456789abcdef"

@(private = "file")
KEY_B :: "fedcba9876543210fedcba9876543210"

@(private = "file")
Worker_Fixture :: struct {
	root:      string,
	repo:      string,
	turns_dir: string,
	worker:    ^app.Turn_Worker,
	held:      [dynamic]app.Turn_Result,
}

@(private = "file")
worker_git_installed :: proc() -> bool {
	output, err := turns.git_run({"--version"}, {})
	if err != .None {
		log.warnf("git is not available (%v): skipping", err)
		return false
	}
	turns.git_output_destroy(&output)
	return true
}

@(private = "file")
worker_git :: proc(t: ^testing.T, directory: string, args: ..string) -> bool {
	output, err := turns.git_run(args, {cwd = directory}, context.temp_allocator)
	if !testing.expectf(t, err == .None, "git %v: %v", args, err) {return false}
	return testing.expectf(t, output.code == 0, "git %v exited %d: %s", args, output.code, output.stderr)
}

@(private = "file")
worker_write :: proc(t: ^testing.T, f: ^Worker_Fixture, name, text: string) -> bool {
	path := fmt.tprintf("%s/%s", f.repo, name)
	return testing.expectf(t, os.write_entire_file(path, text) == nil, "write %s", path)
}

// A repository with two committed files, and a worker over a turns directory next to it. False, with
// nothing to clean up beyond worker_stop, when git is missing or a step failed.
@(private = "file")
worker_start :: proc(t: ^testing.T, f: ^Worker_Fixture) -> bool {
	if !worker_git_installed() {return false}
	root, root_error := os.make_directory_temp("", "aio-turn-worker-*", context.allocator)
	if !testing.expectf(t, root_error == nil, "temp directory: %v", root_error) {return false}
	bytes := transmute([]u8)root
	for &b in bytes {
		if b == '\\' {b = '/'}
	}
	f.root = root
	f.repo = fmt.aprintf("%s/repo", root)
	f.turns_dir = fmt.aprintf("%s/turns", root)
	if !testing.expect(t, os.make_directory_all(f.repo) == nil) {return false}
	if !worker_git(t, f.repo, "init", "-q") {return false}
	if !worker_git(t, f.repo, "config", "user.name", "Test") {return false}
	if !worker_git(t, f.repo, "config", "user.email", "test@example.com") {return false}
	if !worker_git(t, f.repo, "config", "core.autocrlf", "false") {return false}
	if !worker_write(t, f, "a.txt", "one\ntwo\nthree\n") {return false}
	if !worker_write(t, f, "b.txt", "alpha\nbeta\n") {return false}
	if !worker_git(t, f.repo, "add", "-A") {return false}
	if !worker_git(t, f.repo, "commit", "-q", "-m", "base") {return false}
	f.worker = app.turn_worker_create(f.turns_dir, nil)
	return testing.expect(t, f.worker != nil, "creating the worker")
}

@(private = "file")
worker_stop :: proc(f: ^Worker_Fixture) {
	app.turn_worker_destroy(f.worker)
	for &result in f.held {app.turn_result_destroy(&result)}
	delete(f.held)
	// The worker's watches are closed by now, and the store_delete_all clears the read-only files git
	// leaves in a repository.
	if f.root != "" && turns.store_delete_all(f.root) != .None {log.warnf("could not remove %s", f.root)}
	delete(f.root)
	delete(f.repo)
	delete(f.turns_dir)
	f^ = {}
}

@(private = "file")
worker_now :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / i64(time.Millisecond)
}

@(private = "file")
worker_post :: proc(t: ^testing.T, f: ^Worker_Fixture, job: app.Turn_Job) -> bool {
	return testing.expect(t, app.turn_worker_post(f.worker, job), "posting a job")
}

@(private = "file")
worker_idle :: proc(t: ^testing.T, f: ^Worker_Fixture) -> bool {
	started := time.tick_now()
	for app.turn_worker_pending(f.worker) > 0 {
		if time.tick_since(started) > WAIT {
			return testing.expect(t, false, "the worker did not finish its jobs")
		}
		time.sleep(5 * time.Millisecond)
	}
	return true
}

// The first result of type T, which the caller frees with worker_release. A failure the worker
// reports meanwhile fails the test.
@(private = "file")
worker_await :: proc(t: ^testing.T, f: ^Worker_Fixture, $T: typeid) -> (value: T, ok: bool) {
	started := time.tick_now()
	for {
		app.turn_worker_take(f.worker, &f.held)
		for i in 0 ..< len(f.held) {
			if found, matched := f.held[i].(T); matched {
				ordered_remove(&f.held, i)
				return found, true
			}
			if failure, failed := f.held[i].(app.Result_Failure); failed {
				testing.expectf(t, false, "the worker reported %v in %s", failure.error, failure.what)
				ordered_remove(&f.held, i)
				return {}, false
			}
		}
		if time.tick_since(started) > WAIT {
			testing.expectf(t, false, "no %v result within %v", typeid_of(T), WAIT)
			return {}, false
		}
		time.sleep(5 * time.Millisecond)
	}
}

@(private = "file")
worker_release :: proc(value: $T) {
	result: app.Turn_Result = value
	app.turn_result_destroy(&result)
}

@(private = "file")
worker_session :: proc(key: string) -> turns.Session {
	return {pane_key = key, harness = "claude", session = fmt.tprintf("session-%s", key[:4])}
}

@(private = "file")
worker_begin :: proc(t: ^testing.T, f: ^Worker_Fixture, key: string, started: i64) -> bool {
	job := app.Job_Begin {
		pane_key  = key,
		session   = worker_session(key),
		directory = f.repo,
		started   = started,
	}
	return worker_post(t, f, job) && worker_idle(t, f)
}

@(private = "file")
worker_end :: proc(
	t: ^testing.T,
	f: ^Worker_Fixture,
	key: string,
	started, ended: i64,
	title: string,
) -> (
	app.Result_Saved,
	bool,
) {
	job := app.Job_End {
		pane_key  = key,
		session   = worker_session(key),
		started   = started,
		ended     = ended,
		end_state = .Done,
		title     = title,
		sources   = {.Status},
	}
	if !worker_post(t, f, job) {return {}, false}
	return worker_await(t, f, app.Result_Saved)
}

// A whole turn that rewrites a.txt.
@(private = "file")
worker_record :: proc(
	t: ^testing.T,
	f: ^Worker_Fixture,
	key: string,
	base: i64,
	text: string,
) -> (
	app.Result_Saved,
	bool,
) {
	if !worker_begin(t, f, key, base) || !worker_write(t, f, "a.txt", text) {return {}, false}
	time.sleep(SETTLE)
	return worker_end(t, f, key, base, base + 1000, "Rewrite a")
}

@(private = "file")
worker_query :: proc(
	t: ^testing.T,
	f: ^Worker_Fixture,
	directory, key: string,
	agent: bool,
	selected: []u64,
) -> (
	app.Result_Query,
	bool,
) {
	job := app.Job_Query {
		pane      = 7,
		request   = 1,
		directory = directory,
		agent     = agent,
		session   = worker_session(key),
		selected  = selected,
	}
	if !worker_post(t, f, job) {return {}, false}
	return worker_await(t, f, app.Result_Query)
}

@(private = "file")
worker_plain :: proc(
	t: ^testing.T,
	f: ^Worker_Fixture,
	directory: string,
	mode: turns.Plain_Mode,
) -> (
	app.Result_Plain,
	bool,
) {
	job := app.Job_Plain {
		pane      = 2,
		request   = 5,
		directory = directory,
		mode      = mode,
	}
	if !worker_post(t, f, job) {return {}, false}
	return worker_await(t, f, app.Result_Plain)
}

@(private = "file")
worker_file :: proc(t: ^testing.T, diff: turns.Diff, path: string) -> (int, bool) {
	for file, i in diff.files {
		if file.new_path == path {return i, true}
	}
	testing.expectf(t, false, "the diff has no %s", path)
	return -1, false
}

// How many segment files a store holds.
@(private = "file")
worker_segment_files :: proc(f: ^Worker_Fixture, key: string) -> int {
	directory := fmt.tprintf("%s/%s/segments", f.turns_dir, key)
	files, err := os.read_all_directory_by_path(directory, context.temp_allocator)
	if err != nil {return 0}
	count := 0
	for file in files {
		if file.type == .Regular {count += 1}
	}
	return count
}

@(test)
turn_worker_records_a_turn_and_reads_it_back :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) {return}
	if !worker_write(t, &f, "a.txt", "one\nthree\nfour\n") {return}
	if !worker_write(t, &f, "c.txt", "x\ny\n") {return}
	time.sleep(SETTLE)
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Fix things\nand more")
	if !saved_ok {return}
	defer worker_release(saved)
	if !testing.expect_value(t, len(saved.repositories), 1) {return}
	testing.expect_value(t, saved.segments, 1)

	query, query_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !query_ok {return}
	defer worker_release(query)
	testing.expect_value(t, query.error, turns.Error.None)
	testing.expect_value(t, query.repository, saved.repositories[0])
	testing.expectf(t, strings.has_suffix(query.worktree, "/repo"), "worktree %q", query.worktree)
	if !testing.expect_value(t, len(query.rows), 1) {return}
	row := query.rows[0]
	testing.expect_value(t, row.kind, turns.Segment_Kind.Turn)
	testing.expect_value(t, row.title, "Fix things\nand more")
	testing.expect_value(t, row.end_state, turns.End_State.Done)
	testing.expect_value(t, row.started, base)
	testing.expect_value(t, row.ended, base + 1000)
	testing.expect_value(t, row.files, 2)
	testing.expect_value(t, row.added, 3)
	testing.expect_value(t, row.removed, 1)
	testing.expect_value(t, len(query.selected), 1)
	if len(query.selected) == 1 {testing.expect_value(t, query.selected[0], row.id)}
	if !testing.expect_value(t, len(query.diff.files), 2) {return}
	testing.expect_value(t, len(query.marked), 2)
	for marked in query.marked {testing.expect(t, !marked)}
	if i, found := worker_file(t, query.diff, "a.txt"); found {
		testing.expect_value(t, query.diff.files[i].added, 1)
		testing.expect_value(t, query.diff.files[i].removed, 1)
	}
	if i, found := worker_file(t, query.diff, "c.txt"); found {
		testing.expect_value(t, query.diff.files[i].added, 2)
		testing.expect_value(t, query.diff.files[i].removed, 0)
		testing.expect_value(t, query.diff.files[i].status, turns.File_Status.Added)
	}

	// Another agent's turn is not this agent's.
	other, other_ok := worker_query(t, &f, f.repo, KEY_B, true, nil)
	if !other_ok {return}
	defer worker_release(other)
	testing.expect_value(t, len(other.rows), 0)
	testing.expect_value(t, len(other.diff.files), 0)
}

@(test)
turn_worker_marks_a_file_that_changed_between_two_turns :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	base := worker_now()
	first, first_ok := worker_record(t, &f, KEY_A, base, "one\nthree\nfour\n")
	if !first_ok {return}
	defer worker_release(first)

	// Nobody has a turn open now: this is the owner's edit.
	if !worker_write(t, &f, "a.txt", "one\nthree\nfour\nfive\n") {return}
	time.sleep(SETTLE)
	if !worker_begin(t, &f, KEY_A, base + 3000) {return}
	between, between_ok := worker_await(t, &f, app.Result_Saved)
	if !between_ok {return}
	defer worker_release(between)
	if !worker_write(t, &f, "a.txt", "one\nthree\nfour\nfive\nsix\n") {return}
	time.sleep(SETTLE)
	second, second_ok := worker_end(t, &f, KEY_A, base + 3000, base + 4000, "Second")
	if !second_ok {return}
	defer worker_release(second)

	all, all_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !all_ok {return}
	defer worker_release(all)
	if !testing.expect_value(t, len(all.rows), 3) {return}
	testing.expect_value(t, all.rows[0].kind, turns.Segment_Kind.Turn)
	testing.expect_value(t, all.rows[1].kind, turns.Segment_Kind.Between)
	testing.expect_value(t, all.rows[2].kind, turns.Segment_Kind.Turn)
	testing.expect_value(t, all.rows[1].files, 1)
	testing.expect_value(t, all.rows[1].started, base + 1000)
	testing.expect_value(t, all.rows[1].ended, base + 3000)
	// The newest row alone is selected, and nothing came between its start and its end.
	testing.expect_value(t, len(all.selected), 1)
	if i, found := worker_file(t, all.diff, "a.txt"); found {
		testing.expect_value(t, all.diff.files[i].added, 1)
		testing.expect_value(t, all.diff.files[i].removed, 0)
		testing.expect(t, !all.marked[i])
	}

	agent, agent_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !agent_ok {return}
	defer worker_release(agent)
	testing.expect_value(t, len(agent.rows), 2)

	both := [?]u64{all.rows[2].id, all.rows[0].id}
	net, net_ok := worker_query(t, &f, f.repo, KEY_A, true, both[:])
	if !net_ok {return}
	defer worker_release(net)
	testing.expect_value(t, len(net.selected), 2)
	if !testing.expect_value(t, len(net.diff.files), 1) {return}
	testing.expect_value(t, net.diff.files[0].added, 3)
	testing.expect_value(t, net.diff.files[0].removed, 1)
	testing.expect(t, net.marked[0], "a.txt changed between the two turns")
}

@(test)
turn_worker_shares_what_overlapping_turns_cannot_tell_apart :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) || !worker_begin(t, &f, KEY_B, base) {return}
	ack := fmt.tprintf("%s/ack.json", f.root)
	if !testing.expect(t, os.write_entire_file(ack, "{}") == nil) {return}
	edit := app.Job_Edit {
		pane_key = KEY_A,
		paths    = {fmt.tprintf("%s/b.txt", f.repo)},
		ack      = ack,
	}
	if !worker_post(t, &f, edit) || !worker_idle(t, &f) {return}
	testing.expect(t, !os.exists(ack), "the worker deletes the file a hook waits on")

	// A hook named b.txt for the first turn; nothing says whose a.txt is.
	if !worker_write(t, &f, "b.txt", "alpha\nbeta\ngamma\n") {return}
	if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nchanged\n") {return}
	time.sleep(SETTLE)
	first, first_ok := worker_end(t, &f, KEY_A, base, base + 1000, "First")
	if !first_ok {return}
	defer worker_release(first)
	second, second_ok := worker_end(t, &f, KEY_B, base, base + 2000, "Second")
	if !second_ok {return}
	defer worker_release(second)

	all, all_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !all_ok {return}
	defer worker_release(all)
	if !testing.expect_value(t, len(all.rows), 2) {return}
	testing.expect_value(t, all.rows[0].files, 1)
	testing.expect_value(t, all.rows[1].files, 2)

	only_first := [?]u64{all.rows[1].id}
	query, query_ok := worker_query(t, &f, f.repo, KEY_A, false, only_first[:])
	if !query_ok {return}
	defer worker_release(query)
	if !testing.expect_value(t, len(query.diff.files), 2) {return}
	if i, found := worker_file(t, query.diff, "a.txt"); found {
		testing.expect(t, query.marked[i], "a.txt was changed while two turns were open")
	}
	if i, found := worker_file(t, query.diff, "b.txt"); found {
		testing.expect(t, !query.marked[i], "a hook named b.txt")
	}
}

@(test)
turn_worker_reads_git_diffs_and_watches_a_work_tree :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nchanged\n") {return}
	if !worker_write(t, &f, "c.txt", "x\n") {return}

	all, all_ok := worker_plain(t, &f, f.repo, .Uncommitted)
	if !all_ok {return}
	defer worker_release(all)
	testing.expect_value(t, all.error, turns.Error.None)
	testing.expect_value(t, all.request, 5)
	testing.expect_value(t, all.pane, 2)
	testing.expect_value(t, all.omitted, 0)
	testing.expect(t, len(all.worktree) > 0)
	if !testing.expect_value(t, len(all.diff.files), 2) {return}
	if i, found := worker_file(t, all.diff, "a.txt"); found {
		testing.expect_value(t, all.diff.files[i].added, 1)
	}
	if i, found := worker_file(t, all.diff, "c.txt"); found {
		testing.expect_value(t, all.diff.files[i].status, turns.File_Status.Added)
	}

	if !worker_git(t, f.repo, "add", "c.txt") {return}
	staged, staged_ok := worker_plain(t, &f, f.repo, .Staged)
	if !staged_ok {return}
	defer worker_release(staged)
	if testing.expect_value(t, len(staged.diff.files), 1) {
		testing.expect_value(t, staged.diff.files[0].new_path, "c.txt")
	}
	unstaged, unstaged_ok := worker_plain(t, &f, f.repo, .Unstaged)
	if !unstaged_ok {return}
	defer worker_release(unstaged)
	if testing.expect_value(t, len(unstaged.diff.files), 1) {
		testing.expect_value(t, unstaged.diff.files[0].new_path, "a.txt")
	}

	outside, outside_ok := worker_plain(t, &f, f.root, .Uncommitted)
	if !outside_ok {return}
	defer worker_release(outside)
	testing.expect_value(t, outside.error, turns.Error.Not_Repository)

	watch := app.Job_View_Watch {
		pane      = 3,
		directory = f.repo,
	}
	if !worker_post(t, &f, watch) || !worker_idle(t, &f) {return}
	if !worker_write(t, &f, "d.txt", "new\n") {return}
	dirty, dirty_ok := worker_await(t, &f, app.Result_Dirty)
	if !dirty_ok {return}
	testing.expect_value(t, dirty.pane, 3)

	// Once the pane stops watching, changes no longer reach it.
	if !worker_post(t, &f, app.Job_View_Unwatch{pane = 3}) || !worker_idle(t, &f) {return}
	app.turn_worker_take(f.worker, &f.held)
	for &result in f.held {app.turn_result_destroy(&result)}
	clear(&f.held)
	if !worker_write(t, &f, "e.txt", "new\n") {return}
	time.sleep(1200 * time.Millisecond)
	app.turn_worker_take(f.worker, &f.held)
	for result in f.held {
		_, is_dirty := result.(app.Result_Dirty)
		testing.expect(t, !is_dirty, "a pane that stopped watching is not told of changes")
	}
}

@(test)
turn_worker_maintain_drops_expired_segments_and_the_empty_store :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	base := worker_now()
	saved, saved_ok := worker_record(t, &f, KEY_A, base, "one\ntwo\nthree\nfour\n")
	if !saved_ok {return}
	defer worker_release(saved)
	if !testing.expect_value(t, len(saved.repositories), 1) {return}
	key := saved.repositories[0]
	store_directory := fmt.tprintf("%s/%s", f.turns_dir, key)
	testing.expect_value(t, worker_segment_files(&f, key), 1)

	recent := app.Job_Maintain {
		days = 1,
		now  = base + 1000 + 60 * 60 * 1000,
	}
	if !worker_post(t, &f, recent) || !worker_idle(t, &f) {return}
	testing.expect_value(t, worker_segment_files(&f, key), 1)
	testing.expect(t, os.is_directory(store_directory), "a recent segment keeps its store")

	later := app.Job_Maintain {
		days = 1,
		now  = base + 1000 + 3 * turns.DAY_MS,
	}
	if !worker_post(t, &f, later) || !worker_idle(t, &f) {return}
	testing.expect(t, os.is_directory(store_directory), "a store a root uses is never removed")
	testing.expect_value(t, worker_segment_files(&f, key), 0)
	// Once recording stops no root is left, and the empty store goes.
	if !worker_post(t, &f, app.Job_Stop{}) || !worker_post(t, &f, later) || !worker_idle(t, &f) {return}
	testing.expect(t, !os.exists(store_directory), "an expired segment takes the empty store with it")

	query, query_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !query_ok {return}
	defer worker_release(query)
	testing.expect_value(t, query.error, turns.Error.None)
	testing.expect_value(t, len(query.rows), 0)
}

@(test)
turn_worker_delete_all_removes_the_turns_directory :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	saved, saved_ok := worker_record(t, &f, KEY_A, worker_now(), "one\ntwo\nthree\nfour\n")
	if !saved_ok {return}
	defer worker_release(saved)
	testing.expect(t, os.is_directory(f.turns_dir))

	if !worker_post(t, &f, app.Job_Delete_All{}) {return}
	deleted, deleted_ok := worker_await(t, &f, app.Result_Deleted)
	if !deleted_ok {return}
	defer worker_release(deleted)
	testing.expect_value(t, deleted.error, turns.Error.None)
	testing.expect(t, !os.exists(f.turns_dir), "the turns directory is gone")

	query, query_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !query_ok {return}
	defer worker_release(query)
	testing.expect_value(t, query.error, turns.Error.None)
	testing.expect_value(t, len(query.rows), 0)
}

@(test)
turn_worker_ignores_a_directory_outside_git_and_a_turn_it_never_began :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	base := worker_now()
	begin := app.Job_Begin {
		pane_key  = KEY_A,
		session   = worker_session(KEY_A),
		directory = f.root,
		started   = base,
	}
	end := app.Job_End {
		pane_key = KEY_A,
		session  = worker_session(KEY_A),
		started  = base,
		ended    = base + 1000,
	}
	unknown := app.Job_End {
		pane_key = KEY_B,
		started  = base,
		ended    = base + 1000,
	}
	if !worker_post(t, &f, begin) || !worker_post(t, &f, end) || !worker_post(t, &f, unknown) {return}
	if !worker_idle(t, &f) {return}
	app.turn_worker_take(f.worker, &f.held)
	testing.expect_value(t, len(f.held), 0)

	query, query_ok := worker_query(t, &f, f.root, KEY_A, true, nil)
	if !query_ok {return}
	defer worker_release(query)
	testing.expect_value(t, query.error, turns.Error.Not_Repository)
	testing.expect_value(t, query.repository, "")
	testing.expect_value(t, len(query.rows), 0)
}

@(test)
turn_worker_baseline_taken_early_sees_an_edit_made_right_after_a_turn_begins :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	// The first turn of a repository sets up its store, which takes long enough for an agent to edit a
	// file first. A root watched before any turn begins has its baseline by then.
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.repo}) || !worker_idle(t, &f) {return}
	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) {return}
	if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nfour\n") {return}
	time.sleep(SETTLE)
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Quick edit")
	if !saved_ok {return}
	defer worker_release(saved)
	testing.expect_value(t, len(saved.repositories), 1)

	query, query_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !query_ok {return}
	defer worker_release(query)
	if !testing.expect_value(t, len(query.rows), 1) {return}
	testing.expect_value(t, query.rows[0].files, 1)
	testing.expect_value(t, query.rows[0].added, 1)

	// Watching a root again, or a directory outside git, is harmless.
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.repo}) {return}
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.root}) || !worker_idle(t, &f) {return}
	app.turn_worker_take(f.worker, &f.held)
	testing.expect_value(t, len(f.held), 0)
}

// One round of the race a baseline can lose: the edit lands while the root is being set up.
@(private = "file")
worker_edit_during_baseline :: proc(t: ^testing.T) -> bool {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return false}
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.repo}) {return false}
	// Without waiting for the worker, rewrite the file to its final text for a while, so a write lands
	// between the watch starting and the baseline hashing.
	started := time.tick_now()
	for time.tick_since(started) < 250 * time.Millisecond {
		if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nfour\n") {return false}
		time.sleep(5 * time.Millisecond)
	}
	if !worker_idle(t, &f) {return false}
	time.sleep(SETTLE)
	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) {return false}
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "")
	if !saved_ok {return false}
	defer worker_release(saved)

	query, query_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !query_ok {return false}
	defer worker_release(query)
	if !testing.expect(t, len(query.rows) >= 1, "the edit was lost") {return false}
	// The root began with the watch, so the edit is this turn's, not an owner's edit between turns.
	testing.expect_value(t, query.rows[0].kind, turns.Segment_Kind.Turn)
	i, found := worker_file(t, query.diff, "a.txt")
	if !found {return false}
	testing.expect_value(t, query.diff.files[i].added, 1)
	testing.expect_value(t, query.diff.files[i].removed, 0)
	return true
}

@(test)
turn_worker_keeps_an_edit_made_while_its_baseline_is_taken :: proc(t: ^testing.T) {
	for _ in 0 ..< 5 {
		if !worker_edit_during_baseline(t) {return}
	}
}

@(test)
turn_worker_keeps_what_a_turn_stages_or_commits :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) {return}
	if !worker_write(t, &f, "a.txt", "one\nthree\nfour\n") {return}
	if !worker_write(t, &f, "c.txt", "x\n") {return}
	// By the time the turn ends the index and HEAD say what the files now hold.
	if !worker_git(t, f.repo, "add", "a.txt", "c.txt") {return}
	if !worker_git(t, f.repo, "rm", "-q", "b.txt") {return}
	if !worker_git(t, f.repo, "commit", "-q", "-m", "inside the turn") {return}
	time.sleep(SETTLE)
	first, first_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Committed")
	if !first_ok {return}
	defer worker_release(first)

	committed, committed_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !committed_ok {return}
	defer worker_release(committed)
	if !testing.expect_value(t, len(committed.diff.files), 3) {return}
	if i, found := worker_file(t, committed.diff, "a.txt"); found {
		testing.expect_value(t, committed.diff.files[i].added, 1)
		testing.expect_value(t, committed.diff.files[i].removed, 1)
	}
	if i, found := worker_file(t, committed.diff, "c.txt"); found {
		testing.expect_value(t, committed.diff.files[i].status, turns.File_Status.Added)
	}
	if i, found := worker_file(t, committed.diff, "b.txt"); found {
		testing.expect_value(t, committed.diff.files[i].status, turns.File_Status.Deleted)
	}

	// A change that is only staged is no different.
	later := base + 5000
	if !worker_begin(t, &f, KEY_A, later) {return}
	if !worker_write(t, &f, "a.txt", "one\nthree\nfour\nfive\n") {return}
	if !worker_git(t, f.repo, "add", "a.txt") {return}
	time.sleep(SETTLE)
	second, second_ok := worker_end(t, &f, KEY_A, later, later + 1000, "Staged")
	if !second_ok {return}
	defer worker_release(second)
	staged, staged_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !staged_ok {return}
	defer worker_release(staged)
	if !testing.expect_value(t, len(staged.diff.files), 1) {return}
	testing.expect_value(t, staged.diff.files[0].new_path, "a.txt")
	testing.expect_value(t, staged.diff.files[0].added, 1)
}

@(test)
turn_worker_runs_turn_jobs_before_reads_and_answers_only_the_newest_read_of_a_pane :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	// The first job keeps the worker busy while the rest queue behind it.
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.repo}) {return}
	first := app.Job_Plain {
		pane      = 2,
		request   = 1,
		directory = f.repo,
		mode      = .Uncommitted,
	}
	newer := app.Job_Plain {
		pane      = 2,
		request   = 2,
		directory = f.repo,
		mode      = .Uncommitted,
	}
	query := app.Job_Query {
		pane      = 7,
		request   = 3,
		directory = f.repo,
	}
	if !worker_post(t, &f, first) || !worker_post(t, &f, newer) || !worker_post(t, &f, query) {return}
	if !worker_post(t, &f, app.Job_Delete_All{}) || !worker_idle(t, &f) {return}
	app.turn_worker_take(f.worker, &f.held)
	if !testing.expect_value(t, len(f.held), 3) {return}
	_, deleted := f.held[0].(app.Result_Deleted)
	testing.expect(t, deleted, "the turn job ran ahead of the reads")
	plain, is_plain := f.held[1].(app.Result_Plain)
	if testing.expect(t, is_plain) {testing.expect_value(t, plain.request, 2)}
	answer, is_query := f.held[2].(app.Result_Query)
	if testing.expect(t, is_query) {testing.expect_value(t, answer.request, 3)}
}

@(test)
turn_worker_maintain_keeps_what_a_live_root_holds_and_what_it_cannot_read :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	// b.txt is dirty when the root begins, so its blob is only known, reachable from no ref.
	if !worker_write(t, &f, "b.txt", "alpha\nbeta\nowner\n") {return}
	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) {return}
	if !worker_post(t, &f, app.Job_Maintain{days = 1, now = base}) || !worker_idle(t, &f) {return}
	if !worker_write(t, &f, "b.txt", "alpha\nbeta\nowner\nagent\n") {return}
	time.sleep(SETTLE)
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Edit b")
	if !saved_ok {return}
	defer worker_release(saved)
	query, query_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !query_ok {return}
	defer worker_release(query)
	if !testing.expect_value(t, len(query.diff.files), 1) {return}
	testing.expect_value(t, query.diff.files[0].added, 1)
	testing.expect_value(t, query.diff.files[0].removed, 0)

	// A segment file that does not decode still counts as one: its store is not empty.
	key := saved.repositories[0]
	damaged := fmt.tprintf("%s/%s/segments/ffffffffffffffff.json", f.turns_dir, key)
	if !testing.expect(t, os.write_entire_file(damaged, "not json") == nil) {return}
	later := app.Job_Maintain {
		days = 1,
		now  = base + 1000 + 3 * turns.DAY_MS,
	}
	if !worker_post(t, &f, later) || !worker_idle(t, &f) {return}
	testing.expect(t, os.exists(damaged), "a store with a file it cannot read is kept")
}

@(test)
turn_worker_view_watch_ignores_what_git_ignores :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	if !worker_write(t, &f, ".gitignore", "ignored.txt\n") {return}
	watch := app.Job_View_Watch {
		pane      = 3,
		directory = f.repo,
	}
	if !worker_post(t, &f, watch) || !worker_idle(t, &f) {return}
	if !worker_write(t, &f, "ignored.txt", "x\n") {return}
	time.sleep(1500 * time.Millisecond)
	app.turn_worker_take(f.worker, &f.held)
	for result in f.held {
		_, is_dirty := result.(app.Result_Dirty)
		testing.expect(t, !is_dirty, "an ignored file does not refresh a diff")
	}
	if !worker_write(t, &f, "d.txt", "new\n") {return}
	dirty, dirty_ok := worker_await(t, &f, app.Result_Dirty)
	if dirty_ok {testing.expect_value(t, dirty.pane, 3)}
}

@(test)
turn_worker_gives_a_carried_path_to_the_turn_even_when_the_watch_reports_it_again :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.repo}) {return}
	// Rewrite the file until the root is ready, so the watch reports it during the baseline, and once
	// more after it: both reports are the turn's, whichever the worker sees first.
	started := time.tick_now()
	for app.turn_worker_pending(f.worker) > 0 && time.tick_since(started) < WAIT {
		if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nfour\n") {return}
		time.sleep(5 * time.Millisecond)
	}
	if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nfour\n") {return}
	time.sleep(SETTLE)
	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) {return}
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "")
	if !saved_ok {return}
	defer worker_release(saved)
	query, query_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !query_ok {return}
	defer worker_release(query)
	if !testing.expect_value(t, len(query.rows), 1) {return}
	testing.expect_value(t, query.rows[0].kind, turns.Segment_Kind.Turn)
	testing.expect_value(t, query.rows[0].added, 1)
}

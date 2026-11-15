package app_test

import "aio:syntax"
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

@(private = "file")
KEY_A :: "0123456789abcdef0123456789abcdef"

@(private = "file")
KEY_B :: "fedcba9876543210fedcba9876543210"

@(private = "file")
KEY_C :: "1111222233334444aaaabbbbccccdddd"

@(private = "file")
KEY_D :: "9999888877776666ddddccccbbbbaaaa"

@(private = "file")
Worker_Fixture :: struct {
	root:      string,
	repo:      string,
	turns_dir: string,
	worker:    ^app.Turn_Worker,
	held:      [dynamic]app.Turn_Result,
	// Watches the whole fixture, so a test can tell when the OS has reported what it just changed.
	probe:     ^turns.Watch_Set,
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
	// Written into the repository's config directly: a git run per setting is the slowest part of a test.
	config_path := fmt.tprintf("%s/.git/config", f.repo)
	config, config_error := os.read_entire_file(config_path, context.temp_allocator)
	if !testing.expectf(t, config_error == nil, "read %s", config_path) {return false}
	identity := "[user]\n\tname = Test\n\temail = test@example.com\n[core]\n\tautocrlf = false\n" +
		"[gc]\n\tauto = 0\n[maintenance]\n\tauto = false\n"
	config_text := fmt.tprintf("%s\n%s", string(config), identity)
	if !testing.expect(t, os.write_entire_file(config_path, config_text) == nil) {return false}
	if !worker_write(t, f, "a.txt", "one\ntwo\nthree\n") {return false}
	if !worker_write(t, f, "b.txt", "alpha\nbeta\n") {return false}
	if !worker_git(t, f.repo, "add", "-A") {return false}
	if !worker_git(t, f.repo, "commit", "-q", "-m", "base") {return false}
	probe, probe_ok := turns.watch_set_create({}, context.allocator)
	if !testing.expect(t, probe_ok, "creating the probe watch") {return false}
	f.probe = probe
	_, added := turns.watch_set_add(probe, f.root, true)
	if !testing.expect(t, added, "probing the fixture") {return false}
	f.worker = app.turn_worker_create(f.turns_dir, nil)
	return testing.expect(t, f.worker != nil, "creating the worker")
}

@(private = "file")
worker_stop :: proc(f: ^Worker_Fixture) {
	app.turn_worker_destroy(f.worker)
	turns.watch_set_destroy(f.probe)
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

// Waits until what the test just changed has been reported by the OS: the probe sees a change, then nothing
// more for a moment. The worker's own watches are told about as soon, and a drain only takes what has
// arrived. Gives up quietly after a while: the test's own checks tell what that meant.
@(private = "file")
worker_settle :: proc(f: ^Worker_Fixture) {
	started := time.tick_now()
	last := started
	seen := false
	ready := make([dynamic]turns.Watch_Id, context.temp_allocator)
	paths := make([dynamic]string, context.temp_allocator)
	for time.tick_since(started) < 2 * time.Second {
		clear(&ready)
		turns.watch_set_ready(f.probe, &ready)
		if len(ready) > 0 {
			for id in ready {
				clear(&paths)
				_, _ = turns.watch_set_take(f.probe, id, &paths, context.temp_allocator)
			}
			seen, last = true, time.tick_now()
		} else if seen && time.tick_since(last) >= 40 * time.Millisecond {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
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

// A turn ends at `ended`, or now if that is later: what was written after a turn ended is not its.
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
		ended     = max(ended, worker_now()),
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
	worker_settle(f)
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
	worker_settle(&f)
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
	testing.expect(t, row.ended >= base + 1000, "the turn ended when its End said, or later")
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

	// Two turns open at once in one work tree cannot tell whose edit is whose, unless a hook said so.
	overlap := base + 10_000
	if !worker_begin(t, &f, KEY_A, overlap) || !worker_begin(t, &f, KEY_B, overlap) {return}
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
	worker_settle(&f)
	first, first_ok := worker_end(t, &f, KEY_A, overlap, overlap + 1000, "First")
	if !first_ok {return}
	defer worker_release(first)
	second, second_ok := worker_end(t, &f, KEY_B, overlap, overlap + 2000, "Second")
	if !second_ok {return}
	defer worker_release(second)
	all, all_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !all_ok {return}
	defer worker_release(all)
	if !testing.expect_value(t, len(all.rows), 3) {return}
	testing.expect_value(t, all.rows[0].files, 1)
	testing.expect_value(t, all.rows[1].files, 2)
	only_first := [?]u64{all.rows[1].id}
	shared, shared_ok := worker_query(t, &f, f.repo, KEY_A, false, only_first[:])
	if !shared_ok {return}
	defer worker_release(shared)
	if !testing.expect_value(t, len(shared.diff.files), 2) {return}
	if i, found := worker_file(t, shared.diff, "a.txt"); found {
		testing.expect_value(t, len(shared.ambiguous), len(shared.diff.files))
		testing.expect(t, shared.ambiguous[i], "a.txt was changed while two turns were open in one work tree")
	}
	if i, found := worker_file(t, shared.diff, "b.txt"); found {
		testing.expect(t, !shared.marked[i], "a hook named b.txt")
		testing.expect(t, !shared.ambiguous[i], "a hook named b.txt")
	}

	// Deleting every recorded turn takes the turns directory with it.
	if !worker_post(t, &f, app.Job_Delete_All{}) {return}
	deleted, deleted_ok := worker_await(t, &f, app.Result_Deleted)
	if !deleted_ok {return}
	defer worker_release(deleted)
	testing.expect_value(t, deleted.error, turns.Error.None)
	testing.expect(t, !os.exists(f.turns_dir), "the turns directory is gone")
	gone, gone_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !gone_ok {return}
	defer worker_release(gone)
	testing.expect_value(t, len(gone.rows), 0)
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
	worker_settle(&f)
	if !worker_begin(t, &f, KEY_A, base + 3000) {return}
	between, between_ok := worker_await(t, &f, app.Result_Saved)
	if !between_ok {return}
	defer worker_release(between)
	if !worker_write(t, &f, "a.txt", "one\nthree\nfour\nfive\nsix\n") {return}
	worker_settle(&f)
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
	testing.expect_value(t, all.rows[1].started, all.rows[2].ended)
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

	// Once the pane stops watching, changes no longer reach it, and a pane that watches is not told of what
	// git ignores.
	if !worker_post(t, &f, app.Job_View_Unwatch{pane = 3}) || !worker_idle(t, &f) {return}
	if !worker_write(t, &f, ".gitignore", "ignored.txt\n") {return}
	again := app.Job_View_Watch {
		pane      = 4,
		directory = f.repo,
	}
	if !worker_post(t, &f, again) || !worker_idle(t, &f) {return}
	app.turn_worker_take(f.worker, &f.held)
	for &result in f.held {app.turn_result_destroy(&result)}
	clear(&f.held)
	if !worker_write(t, &f, "ignored.txt", "x\n") {return}
	time.sleep(1000 * time.Millisecond)
	app.turn_worker_take(f.worker, &f.held)
	for result in f.held {
		_, is_dirty := result.(app.Result_Dirty)
		testing.expect(t, !is_dirty, "an ignored file, or an unwatched pane, is not told of changes")
	}
	if !worker_write(t, &f, "e.txt", "new\n") {return}
	again_dirty, again_ok := worker_await(t, &f, app.Result_Dirty)
	if again_ok {testing.expect_value(t, again_dirty.pane, 4)}
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
	worker_settle(&f)
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
	worker_settle(&f)
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
	worker_settle(&f)
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

	// Without the file it cannot read, the expired segments go, and a store no root uses goes with them.
	if !testing.expect(t, os.remove(damaged) == nil) {return}
	testing.expect_value(t, worker_segment_files(&f, key), 0)
	fresh := base + 10 * turns.DAY_MS
	recorded, recorded_ok := worker_record(t, &f, KEY_A, fresh, "one\ntwo\nthree\nfour\n")
	if !recorded_ok {return}
	defer worker_release(recorded)
	store_directory := fmt.tprintf("%s/%s", f.turns_dir, key)
	testing.expect_value(t, worker_segment_files(&f, key), 1)
	recent := app.Job_Maintain {
		days = 1,
		now  = fresh + 1000 + 60 * 60 * 1000,
	}
	if !worker_post(t, &f, recent) || !worker_idle(t, &f) {return}
	testing.expect_value(t, worker_segment_files(&f, key), 1)
	testing.expect(t, os.is_directory(store_directory), "a recent segment keeps its store")
	expired := app.Job_Maintain {
		days = 1,
		now  = fresh + 1000 + 3 * turns.DAY_MS,
	}
	if !worker_post(t, &f, expired) || !worker_idle(t, &f) {return}
	testing.expect(t, os.is_directory(store_directory), "a store a root uses is never removed")
	testing.expect_value(t, worker_segment_files(&f, key), 0)
	// Once recording stops no root is left, and the empty store goes.
	if !worker_post(t, &f, app.Job_Stop{}) || !worker_post(t, &f, expired) || !worker_idle(t, &f) {return}
	testing.expect(t, !os.exists(store_directory), "an expired segment takes the empty store with it")
	emptied, emptied_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !emptied_ok {return}
	defer worker_release(emptied)
	testing.expect_value(t, emptied.error, turns.Error.None)
	testing.expect_value(t, len(emptied.rows), 0)
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
	worker_settle(&f)
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

@(private = "file")
worker_write_at :: proc(t: ^testing.T, path, text: string) -> bool {
	return testing.expectf(t, os.write_entire_file(path, text) == nil, "write %s", path)
}

// A linked worktree of the fixture's repository, next to it, on a branch of its own.
@(private = "file")
worker_worktree :: proc(t: ^testing.T, f: ^Worker_Fixture, name: string) -> (string, bool) {
	path := fmt.tprintf("%s/%s", f.root, name)
	return path, worker_git(t, f.repo, "worktree", "add", "-q", "-b", name, path)
}

@(private = "file")
worker_begin_in :: proc(
	t: ^testing.T,
	f: ^Worker_Fixture,
	key, directory: string,
	started: i64,
	transcript := "",
) -> bool {
	job := app.Job_Begin {
		pane_key   = key,
		session    = worker_session(key),
		directory  = directory,
		started    = started,
		transcript = transcript,
	}
	return worker_post(t, f, job) && worker_idle(t, f)
}

@(private = "file")
worker_plain_for :: proc(
	t: ^testing.T,
	f: ^Worker_Fixture,
	directory, key, pick: string,
) -> (
	app.Result_Plain,
	bool,
) {
	job := app.Job_Plain {
		pane      = 2,
		request   = 5,
		directory = directory,
		mode      = .Uncommitted,
		session   = worker_session(key),
		worktree  = pick,
	}
	if !worker_post(t, f, job) {return {}, false}
	return worker_await(t, f, app.Result_Plain)
}

@(test)
turn_worker_records_a_turn_that_edits_only_a_linked_worktree :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	wt, wt_ok := worker_worktree(t, &f, "wt-a")
	if !wt_ok {return}
	base := worker_now()
	// The agent was started in the main work tree and goes to the other one.
	if !worker_begin(t, &f, KEY_A, base) {return}
	if !worker_write_at(t, fmt.tprintf("%s/a.txt", wt), "one\ntwo\nthree\nlinked\n") {return}
	worker_settle(&f)
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Work elsewhere")
	if !saved_ok {return}
	defer worker_release(saved)

	query, query_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !query_ok {return}
	defer worker_release(query)
	if !testing.expect_value(t, len(query.rows), 1) {return}
	testing.expect_value(t, query.rows[0].files, 1)
	if !testing.expect_value(t, len(query.diff.files), 1) {return}
	testing.expect_value(t, query.diff.files[0].new_path, "a.txt")
	testing.expect_value(t, query.diff.files[0].added, 1)
	testing.expect(t, !query.ambiguous[0], "the only open turn changed it")

	// A work tree made during a turn is found when it ends, from where it started.
	later := base + 5000
	if !worker_begin(t, &f, KEY_A, later) {return}
	created, created_ok := worker_worktree(t, &f, "wt-new")
	if !created_ok {return}
	if !worker_write_at(t, fmt.tprintf("%s/b.txt", created), "alpha\nbeta\ncreated\n") {return}
	worker_settle(&f)
	second, second_ok := worker_end(t, &f, KEY_A, later, later + 1000, "Branch out")
	if !second_ok {return}
	defer worker_release(second)
	newest, newest_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !newest_ok {return}
	defer worker_release(newest)
	testing.expect_value(t, len(newest.rows), 2)
	if !testing.expect_value(t, len(newest.diff.files), 1) {return}
	testing.expect_value(t, newest.diff.files[0].new_path, "b.txt")
	testing.expect_value(t, newest.diff.files[0].added, 1)
	testing.expect_value(t, newest.diff.files[0].removed, 0)

	// A hook names a file in a work tree nested in one already followed. The turn's agent has no folder of
	// its own to start from, and the other turn is linked to the main work tree only, so nothing but the
	// hook tells whose change it is.
	third := base + 10_000
	if !worker_begin(t, &f, KEY_B, third) {return}
	nested := fmt.tprintf("%s/nested", f.repo)
	if !worker_git(t, f.repo, "worktree", "add", "-q", "-b", "nested", nested) {return}
	begin := app.Job_Begin {
		pane_key = KEY_A,
		session  = worker_session(KEY_A),
		paths    = {fmt.tprintf("%s/a.txt", nested)},
		started  = third,
	}
	if !worker_post(t, &f, begin) || !worker_idle(t, &f) {return}
	if !worker_write_at(t, fmt.tprintf("%s/a.txt", nested), "one\ntwo\nthree\nnested\n") {return}
	worker_settle(&f)
	if !worker_post(t, &f, app.Job_End{pane_key = KEY_B, session = worker_session(KEY_B), started = third}) {
		return
	}
	hooked, hooked_ok := worker_end(t, &f, KEY_A, third, third + 1000, "Nested")
	if !hooked_ok {return}
	defer worker_release(hooked)
	inner, inner_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !inner_ok {return}
	defer worker_release(inner)
	if !testing.expect_value(t, len(inner.diff.files), 1) {return}
	testing.expect_value(t, inner.diff.files[0].new_path, "a.txt")
	testing.expect(t, !inner.ambiguous[0], "the hook named the file for this turn alone")
	idle, idle_ok := worker_query(t, &f, f.repo, KEY_B, true, nil)
	if !idle_ok {return}
	defer worker_release(idle)
	testing.expect_value(t, len(idle.rows), 0)
}

@(test)
turn_worker_shares_what_two_unlinked_worktrees_cannot_tell_apart :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	wt_a, a_ok := worker_worktree(t, &f, "wt-a")
	if !a_ok {return}
	wt_b, b_ok := worker_worktree(t, &f, "wt-b")
	if !b_ok {return}
	// Two agents, each started in a work tree of its own, change only what is there.
	early := worker_now()
	if !worker_begin_in(t, &f, KEY_C, f.repo, early) {return}
	if !worker_begin_in(t, &f, KEY_D, wt_a, early) {return}
	if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nmain\n") {return}
	if !worker_write_at(t, fmt.tprintf("%s/b.txt", wt_a), "alpha\nbeta\nlinked\n") {return}
	worker_settle(&f)
	main_saved, main_saved_ok := worker_end(t, &f, KEY_C, early, early + 1000, "Main")
	if !main_saved_ok {return}
	defer worker_release(main_saved)
	linked_saved, linked_saved_ok := worker_end(t, &f, KEY_D, early, early + 1000, "Linked")
	if !linked_saved_ok {return}
	defer worker_release(linked_saved)
	main_query, main_ok := worker_query(t, &f, f.repo, KEY_C, true, nil)
	if !main_ok {return}
	defer worker_release(main_query)
	if !testing.expect_value(t, len(main_query.diff.files), 1) {return}
	testing.expect_value(t, main_query.diff.files[0].new_path, "a.txt")
	testing.expect(t, !main_query.ambiguous[0])
	linked_query, linked_ok := worker_query(t, &f, f.repo, KEY_D, true, nil)
	if !linked_ok {return}
	defer worker_release(linked_query)
	if !testing.expect_value(t, len(linked_query.diff.files), 1) {return}
	testing.expect_value(t, linked_query.diff.files[0].new_path, "b.txt")
	testing.expect(t, !linked_query.ambiguous[0])

	base := worker_now()
	// Both agents were started in the main work tree and work in the others, which belong to neither.
	if !worker_begin_in(t, &f, KEY_A, f.repo, base) {return}
	if !worker_begin_in(t, &f, KEY_B, f.repo, base) {return}
	if !worker_write_at(t, fmt.tprintf("%s/a.txt", wt_a), "one\ntwo\nthree\nin a\n") {return}
	if !worker_write_at(t, fmt.tprintf("%s/b.txt", wt_b), "alpha\nbeta\nin b\n") {return}
	worker_settle(&f)
	first, first_ok := worker_end(t, &f, KEY_A, base, base + 1000, "First")
	if !first_ok {return}
	defer worker_release(first)
	second, second_ok := worker_end(t, &f, KEY_B, base, base + 1000, "Second")
	if !second_ok {return}
	defer worker_release(second)

	for key in ([?]string{KEY_A, KEY_B}) {
		query, query_ok := worker_query(t, &f, f.repo, key, true, nil)
		if !query_ok {return}
		defer worker_release(query)
		if !testing.expect_value(t, len(query.diff.files), 2) {return}
		testing.expect_value(t, len(query.ambiguous), 2)
		for ambiguous in query.ambiguous {
			testing.expect(t, ambiguous, "either agent may have made it")
		}
		worker_file(t, query.diff, "wt-a/a.txt")
		worker_file(t, query.diff, "wt-b/b.txt")
	}

	// A session whose transcript is in a work tree is linked to it, and alone has changed what is there.
	transcript := fmt.tprintf("%s/session.jsonl", f.root)
	line := fmt.tprintf("{{\"type\":\"user\",\"cwd\":\"%s\"}}\n", wt_a)
	if !worker_write_at(t, transcript, line) {return}
	later := base + 5000
	if !worker_begin_in(t, &f, KEY_A, f.repo, later, transcript) {return}
	if !worker_begin_in(t, &f, KEY_B, f.repo, later) {return}
	if !worker_write_at(t, fmt.tprintf("%s/a.txt", wt_a), "one\ntwo\nthree\nin a, again\n") {return}
	worker_settle(&f)
	idle := app.Job_End {
		pane_key = KEY_B,
		session  = worker_session(KEY_B),
		started  = later,
		ended    = later + 1000,
	}
	if !worker_post(t, &f, idle) {return}
	third, third_ok := worker_end(t, &f, KEY_A, later, later + 1000, "Named by its transcript")
	if !third_ok {return}
	defer worker_release(third)
	named, named_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !named_ok {return}
	defer worker_release(named)
	testing.expect_value(t, len(named.rows), 2)
	if !testing.expect_value(t, len(named.diff.files), 1) {return}
	testing.expect_value(t, named.diff.files[0].new_path, "a.txt")
	testing.expect(t, !named.ambiguous[0])
	other, other_ok := worker_query(t, &f, f.repo, KEY_B, true, nil)
	if !other_ok {return}
	defer worker_release(other)
	testing.expect_value(t, len(other.rows), 1)
}

@(test)
turn_worker_plain_follows_the_agent_and_honours_a_pick :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	wt, wt_ok := worker_worktree(t, &f, "wt-a")
	if !wt_ok {return}
	// An agent that has changed nothing yet is shown the work tree of the request.
	idle, idle_ok := worker_plain_for(t, &f, f.repo, KEY_A, "")
	if !idle_ok {return}
	defer worker_release(idle)
	testing.expectf(t, strings.has_suffix(idle.worktree, "/repo"), "worktree %q", idle.worktree)
	testing.expect(t, idle.following)
	testing.expect_value(t, len(idle.worktrees), 2)

	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) {return}
	if !worker_write_at(t, fmt.tprintf("%s/a.txt", wt), "one\ntwo\nthree\nlinked\n") {return}
	worker_settle(&f)
	// No boundary has come since, so looking at the turn is the pane's own doing.
	open, open_ok := worker_plain_for(t, &f, f.repo, KEY_A, "")
	if !open_ok {return}
	defer worker_release(open)
	testing.expectf(t, strings.has_suffix(open.worktree, "/wt-a"), "worktree %q", open.worktree)
	testing.expect(t, open.following)
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Elsewhere")
	if !saved_ok {return}
	defer worker_release(saved)

	followed, followed_ok := worker_plain_for(t, &f, f.repo, KEY_A, "")
	if !followed_ok {return}
	defer worker_release(followed)
	testing.expectf(t, strings.has_suffix(followed.worktree, "/wt-a"), "worktree %q", followed.worktree)
	testing.expect(t, followed.following)
	if !testing.expect_value(t, len(followed.worktrees), 2) {return}
	testing.expect_value(t, followed.worktrees[0], followed.worktree)
	testing.expectf(t, strings.has_suffix(followed.worktrees[1], "/repo"), "worktrees %v", followed.worktrees)
	if !testing.expect_value(t, len(followed.diff.files), 1) {return}
	testing.expect_value(t, followed.diff.files[0].new_path, "a.txt")

	picked, picked_ok := worker_plain_for(t, &f, f.repo, KEY_A, followed.worktrees[1])
	if !picked_ok {return}
	defer worker_release(picked)
	testing.expect_value(t, picked.worktree, followed.worktrees[1])
	testing.expect(t, !picked.following)
	testing.expect_value(t, len(picked.diff.files), 0)

	// Another agent has changed nothing: it is shown where the request is.
	other, other_ok := worker_plain_for(t, &f, f.repo, KEY_B, "")
	if !other_ok {return}
	defer worker_release(other)
	testing.expectf(t, strings.has_suffix(other.worktree, "/repo"), "worktree %q", other.worktree)
	testing.expect(t, other.following)
}

@(test)
turn_worker_does_not_attribute_what_was_dirty_in_a_worktree_when_a_rescan_finds_it :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	wt, wt_ok := worker_worktree(t, &f, "wt-a")
	if !wt_ok {return}
	// The owner's own uncommitted work, there before anything follows the work tree: a file deleted.
	deleted := fmt.tprintf("%s/b.txt", wt)
	if !testing.expect(t, os.remove(deleted) == nil) {return}
	base := worker_now()
	if !worker_begin(t, &f, KEY_A, base) {return}
	if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nmain\n") {return}
	// The work tree is removed and made again, which its watch cannot survive. The new one is not watched
	// yet, so nothing tells of what happens in it: the end of the turn rescans, and finds it dirty.
	if !worker_git(t, f.repo, "worktree", "remove", "--force", wt) {return}
	if !worker_git(t, f.repo, "worktree", "add", "-q", "-b", "wt-a-again", wt) {return}
	// A deletion has no time, and a file last written before the work tree was followed is older than
	// the turn: neither is the agent's. A file written since is.
	if !testing.expect(t, os.remove(deleted) == nil) {return}
	old := fmt.tprintf("%s/owner.txt", wt)
	if !worker_write_at(t, old, "owner\n") {return}
	past := time.time_add(time.now(), -time.Hour)
	if !testing.expect(t, os.change_times(old, past, past) == nil) {return}
	if !worker_write_at(t, fmt.tprintf("%s/fresh.txt", wt), "fresh\n") {return}
	worker_settle(&f)
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Main and a new file")
	if !saved_ok {return}
	defer worker_release(saved)

	query, query_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !query_ok {return}
	defer worker_release(query)
	if !testing.expect_value(t, len(query.diff.files), 2) {return}
	worker_file(t, query.diff, "repo/a.txt")
	worker_file(t, query.diff, "wt-a/fresh.txt")
}

// One round of the race a baseline can lose when the root is followed without one first: the file is
// created while the baseline of the turn's own folder is taken.
@(private = "file")
worker_create_during_upgrade :: proc(t: ^testing.T) -> bool {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return false}
	wt, wt_ok := worker_worktree(t, &f, "wt-a")
	if !wt_ok {return false}
	// Following one work tree follows the others without a baseline.
	if !worker_post(t, &f, app.Job_Watch_Root{directory = wt}) || !worker_idle(t, &f) {return false}
	base := worker_now()
	begin := app.Job_Begin {
		pane_key  = KEY_A,
		session   = worker_session(KEY_A),
		directory = f.repo,
		started   = base,
	}
	// As an agent's first status posts them, back to back, while the file is being created.
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.repo}) || !worker_post(t, &f, begin) {
		return false
	}
	started := time.tick_now()
	for time.tick_since(started) < 300 * time.Millisecond {
		if !worker_write(t, &f, "c.txt", "x\ny\n") {return false}
		time.sleep(5 * time.Millisecond)
	}
	if !worker_idle(t, &f) {return false}
	worker_settle(&f)
	end := app.Job_End {
		pane_key = KEY_A,
		session  = worker_session(KEY_A),
		started  = base,
		ended    = base + 1000,
	}
	if !worker_post(t, &f, end) || !worker_idle(t, &f) {return false}

	// However it was told apart from the owner's work, the file is somewhere in what was recorded.
	rows, rows_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !rows_ok {return false}
	defer worker_release(rows)
	if !testing.expect(t, len(rows.rows) >= 1, "the new file was lost") {return false}
	ids := make([]u64, len(rows.rows), context.temp_allocator)
	for row, i in rows.rows {ids[i] = row.id}
	all, all_ok := worker_query(t, &f, f.repo, KEY_A, false, ids)
	if !all_ok {return false}
	defer worker_release(all)
	i, found := worker_file(t, all.diff, "c.txt")
	if !found {return false}
	testing.expect_value(t, all.diff.files[i].status, turns.File_Status.Added)
	return true
}

@(test)
turn_worker_keeps_a_file_created_while_a_followed_roots_baseline_is_taken :: proc(t: ^testing.T) {
	_ = worker_create_during_upgrade(t)
}

@(test)
turn_worker_gives_a_turn_what_was_written_after_it_started_but_before_it_could_begin :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.repo}) || !worker_idle(t, &f) {return}
	// The agent reported working and began editing while the worker was busy: the turn started first.
	base := worker_now()
	time.sleep(20 * time.Millisecond)
	if !worker_write(t, &f, "c.txt", "x\ny\n") {return}
	worker_settle(&f)
	if !worker_begin(t, &f, KEY_A, base) {return}
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Started first")
	if !saved_ok {return}
	defer worker_release(saved)
	turn, turn_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !turn_ok {return}
	defer worker_release(turn)
	if !testing.expect_value(t, len(turn.diff.files), 1) {return}
	testing.expect_value(t, turn.diff.files[0].new_path, "c.txt")
	testing.expect_value(t, turn.diff.files[0].status, turns.File_Status.Added)

	// What was written before a turn started is the owner's, however late the turn was registered.
	if !worker_write(t, &f, "d.txt", "owner\n") {return}
	worker_settle(&f)
	later := worker_now()
	if !worker_begin(t, &f, KEY_A, later) {return}
	between, between_ok := worker_await(t, &f, app.Result_Saved)
	if !between_ok {return}
	defer worker_release(between)
	// An edit made once the turn is registered, in a root that is already followed, is the turn's.
	if !worker_write(t, &f, "e.txt", "agent\n") {return}
	worker_settle(&f)
	second, second_ok := worker_end(t, &f, KEY_A, later, later + 1000, "Edit after")
	if !second_ok {return}
	defer worker_release(second)
	all, all_ok := worker_query(t, &f, f.repo, KEY_A, false, nil)
	if !all_ok {return}
	defer worker_release(all)
	turns_seen, betweens_seen := 0, 0
	for row in all.rows {
		if row.kind == .Turn {turns_seen += 1} else {betweens_seen += 1}
	}
	testing.expect_value(t, turns_seen, 2)
	testing.expect_value(t, betweens_seen, 1)

	// Watching a root again, or a directory outside git, is harmless.
	app.turn_worker_take(f.worker, &f.held)
	for &result in f.held {app.turn_result_destroy(&result)}
	clear(&f.held)
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.repo}) {return}
	if !worker_post(t, &f, app.Job_Watch_Root{directory = f.root}) || !worker_idle(t, &f) {return}
	app.turn_worker_take(f.worker, &f.held)
	testing.expect_value(t, len(f.held), 0)
}

// The diff lines of a file in hunk order, as highlights index them.
@(private = "file")
worker_line_count :: proc(file: turns.Diff_File) -> int {
	count := 0
	for hunk in file.hunks {count += len(hunk.lines)}
	return count
}

// Whether the file is highlighted line for line and some line has a span.
@(private = "file")
worker_highlighted :: proc(t: ^testing.T, highlights: []syntax.File_Lines, diff: turns.Diff, path: string) {
	if !testing.expect_value(t, len(highlights), len(diff.files)) {return}
	i, found := worker_file(t, diff, path)
	if !found {return}
	lines := highlights[i].lines
	counted := worker_line_count(diff.files[i])
	if !testing.expectf(t, len(lines) == counted, "%s has %d lines, not %d", path, len(lines), counted) {
		return
	}
	spans := 0
	for line in lines {spans += len(line)}
	testing.expectf(t, spans > 0, "%s has no spans", path)
}

@(test)
turn_worker_shows_an_open_turn_live_and_saves_it_under_the_same_id :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	base := worker_now()
	begin := app.Job_Begin {
		pane_key  = KEY_A,
		session   = worker_session(KEY_A),
		directory = f.repo,
		started   = base,
		title     = "Working",
	}
	if !worker_post(t, &f, begin) {return}
	// A Begin says at once that the repository has an open turn.
	begun, begun_ok := worker_await(t, &f, app.Result_Live)
	if !begun_ok {return}
	defer worker_release(begun)
	if !testing.expect_value(t, len(begun.repositories), 1) {return}
	// Only a pane that reads turns is told of what the turn changes.
	first, first_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !first_ok {return}
	defer worker_release(first)
	if testing.expect_value(t, len(first.rows), 1) {testing.expect(t, first.rows[0].live)}

	if !worker_write(t, &f, "a.txt", "one\ntwo\nthree\nfour\n") {return}
	if !worker_write(t, &f, "c.odin", "package c\n\nmain :: proc() {}\n") {return}
	// The watch saw the agent write, and once the work tree is quiet the panes are told.
	changed, changed_ok := worker_await(t, &f, app.Result_Live)
	if !changed_ok {return}
	defer worker_release(changed)
	if testing.expect_value(t, len(changed.repositories), 1) {
		testing.expect_value(t, changed.repositories[0], begun.repositories[0])
	}
	// A prompt reported later names the turn better.
	if !worker_post(t, &f, app.Job_Edit{pane_key = KEY_A, title = "Add c"}) || !worker_idle(t, &f) {return}

	open, open_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !open_ok {return}
	defer worker_release(open)
	testing.expect_value(t, open.error, turns.Error.None)
	if !testing.expect_value(t, len(open.rows), 1) {return}
	live := open.rows[0]
	testing.expect(t, live.live, "the open turn is a live row")
	testing.expect_value(t, live.title, "Add c")
	testing.expect_value(t, live.started, base)
	testing.expect_value(t, live.ended, 0)
	testing.expect_value(t, live.end_state, turns.End_State.Unknown)
	testing.expect_value(t, live.files, 2)
	testing.expect_value(t, live.added, 4)
	testing.expect_value(t, live.removed, 0)
	testing.expect_value(t, live.agent, 0)
	if testing.expect_value(t, len(open.selected), 1) {testing.expect_value(t, open.selected[0], live.id)}
	if testing.expect_value(t, len(open.agents), 1) {
		testing.expect(t, open.agents[0].live)
		testing.expect_value(t, open.agents[0].turns, 1)
		testing.expect_value(t, open.agents[0].title, "Add c")
		testing.expect_value(t, open.agents[0].session.session, worker_session(KEY_A).session)
	}
	if !testing.expect_value(t, len(open.diff.files), 2) {return}
	worker_highlighted(t, open.highlights, open.diff, "c.odin")
	if i, found := worker_file(t, open.diff, "a.txt"); found && len(open.highlights) > i {
		testing.expect(t, open.highlights[i].lines == nil, "a .txt file has no language")
	}
	// The full ids of both sides come with each file.
	if i, found := worker_file(t, open.diff, "a.txt"); found {
		testing.expect_value(t, len(open.diff.files[i].old_oid), 40)
		testing.expect_value(t, len(open.diff.files[i].new_oid), 40)
	}

	// A git diff of the work tree is highlighted from the files on disk, and the index's blobs. A file
	// over the highlight limit is left plain.
	if !worker_write(t, &f, "big.odin", strings.repeat("x := 1\n", 150_000, context.temp_allocator)) {return}
	plain, plain_ok := worker_plain(t, &f, f.repo, .Uncommitted)
	if !plain_ok {return}
	defer worker_release(plain)
	worker_highlighted(t, plain.highlights, plain.diff, "c.odin")
	if i, found := worker_file(t, plain.diff, "big.odin"); found && len(plain.highlights) > i {
		testing.expect(t, plain.highlights[i].lines == nil, "a file over the limit is plain")
	}
	if testing.expect_value(t, len(plain.agents), 1) {testing.expect(t, plain.agents[0].live)}
	if !worker_git(t, f.repo, "add", "c.odin") {return}
	staged, staged_ok := worker_plain(t, &f, f.repo, .Staged)
	if !staged_ok {return}
	defer worker_release(staged)
	worker_highlighted(t, staged.highlights, staged.diff, "c.odin")

	// The saved turn keeps the id the pane selected while it was open.
	saved, saved_ok := worker_end(t, &f, KEY_A, base, base + 1000, "Add c")
	if !saved_ok {return}
	defer worker_release(saved)
	picked := [?]u64{live.id}
	ended, ended_ok := worker_query(t, &f, f.repo, KEY_A, false, picked[:])
	if !ended_ok {return}
	defer worker_release(ended)
	if !testing.expect_value(t, len(ended.rows), 1) {return}
	testing.expect(t, !ended.rows[0].live)
	testing.expect_value(t, ended.rows[0].id, live.id)
	if testing.expect_value(t, len(ended.selected), 1) {testing.expect_value(t, ended.selected[0], live.id)}
	if testing.expect_value(t, len(ended.agents), 1) {
		testing.expect(t, !ended.agents[0].live)
		testing.expect_value(t, ended.agents[0].latest, ended.rows[0].ended)
	}
	testing.expect_value(t, len(ended.diff.files), 3)
	if i, found := worker_file(t, ended.diff, "big.odin"); found && len(ended.highlights) > i {
		testing.expect(t, ended.highlights[i].lines == nil, "a blob over the limit is not read")
	}
}

// An End that arrives after the agent has written again, as a busy worker runs it.
@(private = "file")
worker_end_late :: proc(
	t: ^testing.T,
	f: ^Worker_Fixture,
	started, ended: i64,
	title: string,
) -> (
	app.Result_Saved,
	bool,
) {
	job := app.Job_End {
		pane_key  = KEY_A,
		session   = worker_session(KEY_A),
		started   = started,
		ended     = ended,
		end_state = .Done,
		title     = title,
	}
	if !worker_post(t, f, job) {return {}, false}
	return worker_await(t, f, app.Result_Saved)
}

// The files of each saved segment by its title, Between's all under "", as "path=after" in the temp
// allocator.
@(private = "file")
worker_saved_files :: proc(f: ^Worker_Fixture, key: string) -> map[string][dynamic]string {
	temp := context.temp_allocator
	found := make(map[string][dynamic]string, temp)
	directory := fmt.tprintf("%s/%s/segments", f.turns_dir, key)
	files, _ := os.read_all_directory_by_path(directory, temp)
	for file in files {
		data, read_error := os.read_entire_file(file.fullpath, temp)
		if read_error != nil {continue}
		segment, decoded := turns.segment_decode(data, temp)
		if !decoded {continue}
		title := segment.title if segment.kind == .Turn else ""
		if title not_in found {found[title] = make([dynamic]string, temp)}
		for change in segment.changes {
			append(&found[title], fmt.tprintf("%s=%s", change.path, change.after))
		}
	}
	return found
}

@(test)
turn_worker_ends_a_turn_when_it_ended_not_when_its_end_runs :: proc(t: ^testing.T) {
	f: Worker_Fixture
	defer worker_stop(&f)
	if !worker_start(t, &f) {return}
	// The End runs after the agent wrote a file of its next turn: that file is not the ending turn's.
	first := worker_now()
	if !worker_begin(t, &f, KEY_A, first) || !worker_write(t, &f, "one.txt", "1\n") {return}
	worker_settle(&f)
	first_ended := worker_now()
	time.sleep(20 * time.Millisecond)
	if !worker_write(t, &f, "late-one.txt", "x\n") {return}
	worker_settle(&f)
	one, one_ok := worker_end_late(t, &f, first, first_ended, "one")
	if !one_ok {return}
	defer worker_release(one)
	if !testing.expect_value(t, len(one.repositories), 1) {return}

	// The same, when a read took the later file into the turn before its End ran.
	second := worker_now()
	if !worker_begin(t, &f, KEY_A, second) {return}
	between, between_ok := worker_await(t, &f, app.Result_Saved)
	if !between_ok {return}
	defer worker_release(between)
	if !worker_write(t, &f, "two.txt", "2\n") {return}
	worker_settle(&f)
	second_ended := worker_now()
	time.sleep(20 * time.Millisecond)
	if !worker_write(t, &f, "late-two.txt", "y\n") {return}
	worker_settle(&f)
	read, read_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !read_ok {return}
	worker_release(read)
	two, two_ok := worker_end_late(t, &f, second, second_ended, "two")
	if !two_ok {return}
	defer worker_release(two)

	// A file a read took in while the turn was open keeps what the turn wrote, though it was written
	// again after the turn ended.
	third := worker_now()
	if !worker_begin(t, &f, KEY_A, third) {return}
	again, again_ok := worker_await(t, &f, app.Result_Saved)
	if !again_ok {return}
	defer worker_release(again)
	if !worker_write(t, &f, "keep.txt", "one\n") {return}
	worker_settle(&f)
	kept, kept_ok := worker_query(t, &f, f.repo, KEY_A, true, nil)
	if !kept_ok {return}
	worker_release(kept)
	third_ended := worker_now()
	time.sleep(20 * time.Millisecond)
	if !worker_write(t, &f, "keep.txt", "one\ntwo\n") {return}
	worker_settle(&f)
	three, three_ok := worker_end_late(t, &f, third, third_ended, "three")
	if !three_ok {return}
	defer worker_release(three)

	// A file written while the End runs is judged by when the End looks at it, not by when it began.
	fourth := worker_now()
	if !worker_begin(t, &f, KEY_A, fourth) {return}
	rewritten, rewritten_ok := worker_await(t, &f, app.Result_Saved)
	if !rewritten_ok {return}
	defer worker_release(rewritten)
	if !worker_write(t, &f, "four.txt", "4\n") {return}
	worker_settle(&f)
	fourth_ended := worker_now()
	settling := time.tick_add(time.tick_now(), 150 * time.Millisecond)
	end := app.Job_End {
		pane_key     = KEY_A,
		session      = worker_session(KEY_A),
		started      = fourth,
		ended        = fourth_ended,
		end_state    = .Done,
		title        = "four",
		settle_until = settling,
	}
	if !worker_post(t, &f, end) {return}
	time.sleep(50 * time.Millisecond)
	if !worker_write(t, &f, "late-four.txt", "z\n") {return}
	four, four_ok := worker_await(t, &f, app.Result_Saved)
	if !four_ok {return}
	defer worker_release(four)

	hash_run := turns.Git_Run {
		cwd   = f.repo,
		stdin = "one\n",
	}
	hashed, hash_error := turns.git_run({"hash-object", "--stdin"}, hash_run, context.temp_allocator)
	if !testing.expect_value(t, hash_error, turns.Error.None) {return}
	written := strings.trim_space(string(hashed.stdout))
	saved := worker_saved_files(&f, one.repositories[0])
	testing.expect_value(t, len(saved["one"]), 1)
	if len(saved["one"]) == 1 {testing.expect(t, strings.has_prefix(saved["one"][0], "one.txt="))}
	testing.expect_value(t, len(saved["two"]), 1)
	if len(saved["two"]) == 1 {testing.expect(t, strings.has_prefix(saved["two"][0], "two.txt="))}
	if testing.expect_value(t, len(saved["three"]), 1) {
		testing.expect_value(t, saved["three"][0], fmt.tprintf("keep.txt=%s", written))
	}
	if testing.expect_value(t, len(saved["four"]), 1) {
		testing.expect(t, strings.has_prefix(saved["four"][0], "four.txt="))
	}
	// The later files were written before the next turn began, so they are Between's, as is keep.txt as
	// it was rewritten after its turn ended.
	testing.expect_value(t, len(saved[""]), 3)
	for entry in saved[""] {
		later := strings.has_prefix(entry, "late-") || strings.has_prefix(entry, "keep.txt=")
		testing.expectf(t, later, "Between has %s", entry)
	}
}

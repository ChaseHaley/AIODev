package main

import "aio:agent"
import platform_api "aio:platform"
import "aio:syntax"
import "aio:turns"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

// Everything about recorded turns that needs git runs on one thread of its own, so no frame waits for
// it. The main thread posts jobs and takes results; the worker alone owns the repositories it watches,
// the private stores it writes, the pre-image of every file it has seen and the segments it has read.
// It wakes the main loop when a result is ready.

Job_Begin :: struct {
	pane_key:   string,
	session:    turns.Session,
	directory:  string,
	// Files a hook already named as edited, absolute or relative to `directory`.
	paths:      []string,
	started:    i64,
	// The prompt a hook reported, else the status report's title; may be empty.
	title:      string,
	// An inbox file to delete once the roots are baselined: the hook waits for it to go.
	ack:        string,
	// The agent's transcript file, "" when there is none to read.
	transcript: string,
}

Job_Edit :: struct {
	pane_key: string,
	paths:    []string,
	ack:      string,
	// A prompt the open turn's hook reported since it began, "" when none.
	title:    string,
}

Job_End :: struct {
	pane_key:     string,
	session:      turns.Session,
	started:      i64,
	ended:        i64,
	end_state:    turns.End_State,
	title:        string,
	sources:      bit_set[turns.Signal_Source],
	// When the turn's last writes have surely reached the watches; the worker waits until then, at most
	// TURN_SETTLE, before it takes the turn's changes in. Zero for no wait.
	settle_until: time.Tick,
}

Job_Query :: struct {
	pane:      u32,
	request:   u64,
	directory: string,
	// Agent scope; false is Repository scope.
	agent:     bool,
	session:   turns.Session,
	selected:  []u64,
}

Job_Plain :: struct {
	pane:      u32,
	request:   u64,
	directory: string,
	mode:      turns.Plain_Mode,
	// The agent of the pane: the work tree shown follows its latest change.
	session:   turns.Session,
	// The work tree picked to be shown, "" to follow the agent.
	worktree:  string,
}

Job_View_Watch :: struct {
	pane:      u32,
	directory: string,
}

Job_View_Unwatch :: struct {
	pane: u32,
}

Job_Maintain :: struct {
	days: int,
	now:  i64,
}

Job_Stop :: struct {}

Job_Delete_All :: struct {}

// Follows the work tree of `directory` without opening a turn, so a later turn starts from a baseline
// taken before its agent edits anything. Idempotent.
Job_Watch_Root :: struct {
	directory: string,
}

Turn_Job :: union {
	Job_Begin,
	Job_Edit,
	Job_End,
	Job_Query,
	Job_Plain,
	Job_View_Watch,
	Job_View_Unwatch,
	Job_Maintain,
	Job_Stop,
	Job_Delete_All,
	Job_Watch_Root,
}

// One recorded segment, or an open turn, as the turn list shows it. Only a turn with a changed file has a
// row (tw_listed).
Turn_Row :: struct {
	id:        u64,
	kind:      turns.Segment_Kind,
	// An open turn: `ended` is 0, `end_state` Unknown, and the counts are its changes so far.
	live:      bool,
	// Its index in the result's `agents`, -1 for a Between row.
	agent:     int,
	started:   i64,
	ended:     i64,
	end_state: turns.End_State,
	title:     string,
	files:     int,
	added:     int,
	removed:   int,
}

// One agent with a listed turn in a repository: a session, by its id when known, else by its pane.
Turn_Agent :: struct {
	session: turns.Session,
	// Its saved turns, plus the open one.
	turns:   int,
	// It has a turn open now.
	live:    bool,
	// When its newest turn ended, or now while one is open; Unix milliseconds.
	latest:  i64,
	// The newest of its turns' titles that is not empty.
	title:   string,
}

// The memory one result owns. It is heap allocated so the result may be copied by value, and its
// arena holds every string, slice and parsed diff the result refers to.
Turn_Memory :: struct {
	arena:  vmem.Arena,
	parent: mem.Allocator,
}

// Everything in a Result_Query or Result_Plain lives in `memory`, which turn_result_destroy frees.
Result_Query :: struct {
	pane:       u32,
	request:    u64,
	error:      turns.Error,
	// The repository key, "" when the directory is not in a repository.
	repository: string,
	// The work tree found for the request's directory, with '/' separators.
	worktree:   string,
	// Newest first; only turns that changed a file.
	rows:       []Turn_Row,
	// The ids the diff covers.
	selected:   []u64,
	// Its strings borrow from `patch`.
	diff:       turns.Diff,
	patch:      string,
	// Parallel to diff.files.
	marked:     []bool,
	// Parallel to diff.files: a selected change may be another agent's.
	ambiguous:  []bool,
	// Newest `latest` first.
	agents:     []Turn_Agent,
	// Parallel to diff.files; see tw_highlights.
	highlights: []syntax.File_Lines,
	memory:     ^Turn_Memory,
}

Result_Plain :: struct {
	pane:       u32,
	request:    u64,
	error:      turns.Error,
	// The work tree shown, with '/' separators.
	worktree:   string,
	// Every work tree of the repository that can be shown: the one the agent is followed to first, then
	// the request directory's own, then the rest by path.
	worktrees:  []string,
	// The shown work tree was chosen by following the agent, not picked.
	following:  bool,
	diff:       turns.Diff,
	patch:      string,
	omitted:    int,
	agents:     []Turn_Agent,
	highlights: []syntax.File_Lines,
	memory:     ^Turn_Memory,
}

// The repository keys where an open turn's changes may have changed since the last answer.
Result_Live :: struct {
	repositories: []string,
	allocator:    mem.Allocator,
}

// A watched work tree changed and has been quiet since.
Result_Dirty :: struct {
	pane: u32,
}

// The repository keys that gained a segment, and how many segment files the job wrote.
Result_Saved :: struct {
	repositories: []string,
	segments:     int,
	allocator:    mem.Allocator,
}

// `error` is None when every recorded turn is gone.
Result_Deleted :: struct {
	error: turns.Error,
}

// A job that could not do its work. `what` is a short word for the job, a literal.
Result_Failure :: struct {
	error: turns.Error,
	what:  string,
}

Turn_Result :: union {
	Result_Query,
	Result_Plain,
	Result_Dirty,
	Result_Saved,
	Result_Live,
	Result_Deleted,
	Result_Failure,
}

// The worker looks at its view watches this often when no job arrives.
@(private = "file")
TW_TICK :: 250 * time.Millisecond

// A watched work tree must be quiet this long before its panes are told to refresh.
@(private = "file")
TW_VIEW_QUIET :: 500 * time.Millisecond

// After an open turn's work tree changes, its panes are told once it has been quiet this long, and at
// least this often while it keeps changing.
@(private = "file")
TW_LIVE_QUIET :: 500 * time.Millisecond
@(private = "file")
TW_LIVE_EVERY :: time.Second

// The longest a turn's boundary waits for the watch thread to catch up with what the OS reported.
@(private = "file")
TW_WATCH_SYNC :: time.Second

// Source a result may highlight, over all its files; more is left plain, since lexing is not free.
@(private = "file")
TW_HIGHLIGHT_BUDGET :: 16 * mem.Megabyte

// Blobs read per git run while highlighting, so a large diff stops reading once the budget is used.
@(private = "file")
TW_HIGHLIGHT_GROUP :: 32

@(private = "file")
TW_RESULT_BLOCK :: 256 * mem.Kilobyte

@(private = "file")
TW_STORE :: "store.git"

// One file's change within a turn or between turns: the content before the first change and after the
// latest. Both ids belong to the worker allocator.
@(private)
Tw_Net :: struct {
	before: turns.Oid,
	after:  turns.Oid,
	shared: bool,
	// Orders changes in time: the value of Tw_State.stamp when the latest change was taken in.
	stamp:  u64,
	// Unix milliseconds when a drain first took the change in.
	taken:  i64,
}

// A turn that has begun and not ended.
@(private)
Tw_Open :: struct {
	pane_key:   string,
	session:    turns.Session,
	// The agent's transcript file, "" when there is none to read.
	transcript: string,
	// The id its segments are saved under, taken when it began, so a row selected while it is open
	// still names it once it is saved.
	id:         u64,
	started:    i64,
	title:      string,
	// The line counts of its changes so far, per repository.
	measures:   [dynamic]Tw_Measure,
}

// An open turn's changes in one repository, counted when they last changed.
@(private)
Tw_Measure :: struct {
	key:     string,
	// The newest stamp of the changes when counted.
	stamp:   u64,
	added:   int,
	removed: int,
}

// How much of a transcript file was read: only whole lines are. Kept for the length of the recording, so a
// later turn of the same session does not read it again.
@(private)
Tw_Transcript :: struct {
	path:    string,
	offset:  i64,
	// False until the first read, which starts near the end of a long file.
	scanned: bool,
}

// The work trees `git worktree list` gave for a repository during the job being run, in the temp allocator.
@(private)
Tw_Listing :: struct {
	key:  string,
	list: []turns.Worktree,
}

// A session known to work in a work tree. The key is the session id, else the pane key.
@(private)
Tw_Link :: struct {
	key:      string,
	worktree: string,
	// When the link was last seen, to tell the most recent.
	stamp:    u64,
}

// An open turn's presence in one root: what it changed there and what hooks named as theirs.
@(private)
Tw_Presence :: struct {
	open:    ^Tw_Open,
	named:   map[string]struct{},
	changes: map[string]Tw_Net,
}

// One repository's private store with the segments read from it. A store the worker only reads has
// `opened` false, since opening writes to it.
@(private)
Tw_Store :: struct {
	key:      string,
	store:    turns.Store,
	opened:   bool,
	loaded:   bool,
	segments: [dynamic]turns.Segment,
}

// A work tree whose changes are followed: its watch, the content last seen of every file that was
// dirty or changed since, the changes no turn claimed, and the open turns in it.
@(private)
Tw_Root :: struct {
	repository: turns.Repository,
	store:      ^Tw_Store,
	// 0 when the directory could not be watched; every drain then rescans.
	watch:      turns.Watch_Id,
	known:      map[string]turns.Oid,
	pending:    map[string]Tw_Net,
	presences:  [dynamic]^Tw_Presence,
	// Paths the watch reported while the baseline was taken, which the next drain looks at.
	carry:      [dynamic]string,
	// The last time the root's changes were settled: its baseline, a turn's end, a Between save.
	since:      i64,
	// Changes may have been missed, so the next drain asks git what is dirty.
	rescan:     bool,
	// The commit the work tree was on when it was last settled, "" before the first commit. A file the
	// root has not seen changed had its content there, whatever the index says by the time of a drain.
	base:       string,
	// Set until a turn first enters the root, so the base just read is not read again.
	fresh:      bool,
	// The directory vanished and the watch with it.
	lost:       bool,
	// No baseline was taken: nothing was hashed, and a file not seen changing had its content in `base`.
	lazy:       bool,
	// Paths that changed before the root was followed, which the next drain looks at.
	seed:       [dynamic]string,
	// Unix nanoseconds when a lazy root's work tree was first followed alongside its family, else 0. A
	// rescan of the root only takes a file that was written since: what an older one held is unknown.
	followed_at: i64,
	// Changes drained while a turn was beginning, written since it started: the turn takes them.
	claimed:    map[string]Tw_Net,
	// Paths tw_live_tick took from the watch for the next drain, each once, with what is known of them.
	taken:      map[string]Tw_Taken,
	// The work tree changed while a turn was open in it, and its panes have not been told.
	live_waiting: bool,
	// A change git would show is among them; else only the unchecked taken paths may be one.
	live_sure:  bool,
	// When the first and the latest of those changes were seen.
	live_first: time.Tick,
	live_last:  time.Tick,
}

// Whether a path taken from a root's watch is one git would show.
@(private)
Tw_Taken :: enum u8 {
	Unchecked,
	Shown,
	Ignored,
}

// A recursive watch of a work tree for the panes that show its git diffs.
@(private)
Tw_View :: struct {
	worktree: string,
	watch:    turns.Watch_Id,
	panes:    [dynamic]u32,
	// Set while changes wait for their quiet period; `changed` is when the last one arrived.
	waiting:  bool,
	changed:  time.Tick,
}

@(private)
Tw_State :: struct {
	allocator: mem.Allocator,
	// The turns directory, borrowed from the worker; '/' separators.
	directory: string,
	wake:      turns.Watch_Wake,
	roots:     [dynamic]^Tw_Root,
	stores:    [dynamic]^Tw_Store,
	opens:     [dynamic]^Tw_Open,
	views:     [dynamic]^Tw_View,
	// Every directory the worker watches, roots and views alike.
	watches:   ^turns.Watch_Set,
	// The repository keys whose work trees are followed.
	families:  [dynamic]string,
	links:     [dynamic]Tw_Link,
	stamp:     u64,
	// Unix milliseconds when the turn a Begin job is running started, else 0.
	claim_since: i64,
	// Unix milliseconds when the turn an End job is closing ended, else 0. The worker may run the End
	// well after the turn ended, once the agent has gone on to its next turn: what was written since is
	// not the ending turn's, and is left for the drain that follows. A file stamped later than the moment
	// it is looked at has a time that cannot be trusted, and stays.
	drain_until: i64,
	// The listings made by the job being run: a job lists a repository once.
	listings:  [dynamic]Tw_Listing,
	transcripts: [dynamic]Tw_Transcript,
	// Results of the job being run, handed to the main thread once it is done.
	outbox:    [dynamic]Turn_Result,
	last_id:   u64,
	// Raised by turn_worker_destroy to stop the git run of a read; every git call of the worker holds it.
	cancel:    ^turns.Git_Cancel,
	// The panes whose latest read is of turns: only they are told of an open turn's changes.
	readers:   [dynamic]u32,
}

// A file's content on both sides of a change, from a segment or a composed run.
@(private)
Tw_Side :: struct {
	worktree: string,
	path:     string,
	before:   turns.Oid,
	after:    turns.Oid,
}

Turn_Worker :: struct {
	// Guards jobs, results, running and stop: all the main thread and the worker share.
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	jobs:      [dynamic]Turn_Job,
	results:   [dynamic]Turn_Result,
	running:   bool,
	stop:      bool,
	// The running job is a read, which destroy may cancel; a turn's own jobs are let finish.
	reading:   bool,
	cancel:    turns.Git_Cancel,
	// Fixed before the thread starts.
	thread:    ^thread.Thread,
	platform:  ^platform_api.Platform,
	allocator: mem.Allocator,
	directory: string,
	// Only the worker thread touches this, and destroy once the thread is joined.
	state:     Tw_State,
}

// The platform may be nil, as in headless tests: results are then only polled. nil on failure.
@(require_results)
turn_worker_create :: proc(
	turns_directory: string,
	platform: ^platform_api.Platform,
	allocator := context.allocator,
) -> ^Turn_Worker {
	worker, new_error := new(Turn_Worker, allocator)
	if new_error != nil {return nil}
	directory, clone_error := strings.clone(turns_directory, allocator)
	if clone_error != nil {
		free(worker, allocator)
		return nil
	}
	tw_slashes(directory)
	worker.allocator = allocator
	worker.platform = platform
	worker.directory = directory
	worker.jobs.allocator = allocator
	worker.results.allocator = allocator
	state := &worker.state
	state.allocator = allocator
	state.directory = directory
	state.cancel = &worker.cancel
	state.wake = {
		data = worker,
		wake = tw_wake,
	}
	state.roots.allocator = allocator
	state.readers.allocator = allocator
	state.stores.allocator = allocator
	state.opens.allocator = allocator
	state.views.allocator = allocator
	state.outbox.allocator = allocator
	state.families.allocator = allocator
	state.links.allocator = allocator
	state.listings.allocator = allocator
	state.transcripts.allocator = allocator
	watches, watches_ok := turns.watch_set_create(state.wake, allocator)
	if !watches_ok {
		log.error("starting the turn worker failed: no watches")
		delete(directory, allocator)
		free(worker, allocator)
		return nil
	}
	state.watches = watches
	worker.thread = thread.create(tw_main)
	if worker.thread == nil {
		log.error("starting the turn worker failed")
		turns.watch_set_destroy(state.watches)
		delete(directory, allocator)
		free(worker, allocator)
		return nil
	}
	// The thread allocates and logs as its creator does, with the worker's allocator, which the git
	// reader threads share. It gets a temp allocator of its own from the runtime.
	thread_context := context
	thread_context.allocator = allocator
	worker.thread.init_context = thread_context
	worker.thread.data = worker
	thread.start(worker.thread)
	return worker
}

// Stops the watches, joins the thread and frees everything, including results nobody took. A job that
// is running finishes first.
turn_worker_destroy :: proc(worker: ^Turn_Worker) {
	if worker == nil {return}
	allocator := worker.allocator
	if worker.thread != nil {
		sync.mutex_lock(&worker.mutex)
		worker.stop = true
		// A read stops at once; a turn's own job is let finish, since its changes are not to be lost.
		if worker.reading {sync.atomic_store(&worker.cancel.flag, true)}
		sync.cond_signal(&worker.cond)
		sync.mutex_unlock(&worker.mutex)
		thread.join(worker.thread)
		thread.destroy(worker.thread)
	}
	for &job in worker.jobs {tw_job_free(&job, allocator)}
	delete(worker.jobs)
	for &result in worker.results {turn_result_destroy(&result)}
	delete(worker.results)
	tw_state_destroy(&worker.state)
	delete(worker.directory, allocator)
	free(worker, allocator)
}

// Whether a job must not wait behind reads: a turn's boundaries are timed by the agent, and a hook is
// held until its job is done.
@(private = "file")
tw_job_urgent :: proc(job: Turn_Job) -> bool {
	#partial switch _ in job {
	case Job_Begin, Job_Edit, Job_End, Job_Stop, Job_Delete_All, Job_Watch_Root:
		return true
	}
	return false
}

// The pane a read answers. A pane shows one answer at a time.
@(private = "file")
tw_job_reader :: proc(job: Turn_Job) -> (pane: u32, ok: bool) {
	#partial switch j in job {
	case Job_Query:
		return j.pane, true
	case Job_Plain:
		return j.pane, true
	}
	return 0, false
}

// Copies the job, strings and slices included, so callers may pass temporary memory. False when the
// worker is stopping or memory ran out. Turn jobs go ahead of reads, each kept in post order, and a
// read still queued for the same pane is replaced by the newer one.
@(require_results)
turn_worker_post :: proc(worker: ^Turn_Worker, job: Turn_Job) -> bool {
	if worker == nil {return false}
	copied, copied_ok := tw_job_dup(job, worker.allocator)
	if !copied_ok {return false}
	sync.mutex_lock(&worker.mutex)
	defer sync.mutex_unlock(&worker.mutex)
	if worker.stop {
		tw_job_free(&copied, worker.allocator)
		return false
	}
	if pane, reads := tw_job_reader(copied); reads {
		for &queued in worker.jobs {
			if queued_pane, same := tw_job_reader(queued); !same || queued_pane != pane {continue}
			tw_job_free(&queued, worker.allocator)
			queued = copied
			sync.cond_signal(&worker.cond)
			return true
		}
	}
	at := len(worker.jobs)
	if tw_job_urgent(copied) {
		at = 0
		for queued, i in worker.jobs {
			if tw_job_urgent(queued) {at = i + 1}
		}
	}
	placed := false
	if at == len(worker.jobs) {
		_, append_error := append(&worker.jobs, copied)
		placed = append_error == nil
	} else {
		inserted, insert_error := inject_at(&worker.jobs, at, copied)
		placed = inserted && insert_error == nil
	}
	if !placed {
		tw_job_free(&copied, worker.allocator)
		return false
	}
	sync.cond_signal(&worker.cond)
	return true
}

// Moves every finished result into `out`. The caller owns them and frees each with turn_result_destroy.
turn_worker_take :: proc(worker: ^Turn_Worker, out: ^[dynamic]Turn_Result) {
	if worker == nil {return}
	sync.mutex_lock(&worker.mutex)
	defer sync.mutex_unlock(&worker.mutex)
	if _, append_error := append(out, ..worker.results[:]); append_error != nil {
		log.error("taking the turn results failed: out of memory")
		return
	}
	clear(&worker.results)
}

// Jobs queued plus the one running; results of a finished job are already takable. Only the harness
// report and the tests read it.
when AIO_CONTROL {
	@(require_results)
	turn_worker_pending :: proc(worker: ^Turn_Worker) -> int {
		if worker == nil {return 0}
		sync.mutex_lock(&worker.mutex)
		defer sync.mutex_unlock(&worker.mutex)
		return len(worker.jobs) + (1 if worker.running else 0)
	}
}

// Frees what a result owns and leaves it empty. A result copied by value is freed once, through
// either copy.
turn_result_destroy :: proc(result: ^Turn_Result) {
	switch &value in result^ {
	case Result_Query:
		tw_memory_free(value.memory)
	case Result_Plain:
		tw_memory_free(value.memory)
	case Result_Saved:
		for key in value.repositories {delete(key, value.allocator)}
		delete(value.repositories, value.allocator)
	case Result_Live:
		for key in value.repositories {delete(key, value.allocator)}
		delete(value.repositories, value.allocator)
	case Result_Dirty, Result_Deleted, Result_Failure:
	}
	result^ = nil
}

@(private = "file")
tw_slashes :: proc(path: string) {
	bytes := transmute([]u8)path
	for &b in bytes {
		if b == '\\' {b = '/'}
	}
}

// Runs on a watch's own thread, so it only signals.
@(private = "file")
tw_wake :: proc "contextless" (data: rawptr) {
	worker := (^Turn_Worker)(data)
	sync.cond_signal(&worker.cond)
}

@(private = "file")
tw_now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / i64(time.Millisecond)
}

@(private = "file")
tw_dup :: proc(text: string, allocator: mem.Allocator) -> (string, bool) {
	cloned, err := strings.clone(text, allocator)
	return cloned, err == nil
}

@(private = "file")
tw_copy :: proc(text: string, allocator: mem.Allocator) -> (string, turns.Error) {
	cloned, err := strings.clone(text, allocator)
	if err != nil {return "", .Out_Of_Memory}
	return cloned, .None
}

@(private = "file")
tw_dup_all :: proc(items: []string, allocator: mem.Allocator) -> ([]string, bool) {
	if len(items) == 0 {return nil, true}
	copies, make_error := make([]string, len(items), allocator)
	if make_error != nil {return nil, false}
	for item, i in items {
		copied, ok := tw_dup(item, allocator)
		if !ok {
			tw_free_all(copies[:i], allocator)
			return nil, false
		}
		copies[i] = copied
	}
	return copies, true
}

@(private = "file")
tw_free_all :: proc(items: []string, allocator: mem.Allocator) {
	for item in items {delete(item, allocator)}
	delete(items, allocator)
}

@(private = "file")
tw_session_dup :: proc(session: turns.Session, allocator: mem.Allocator) -> (dup: turns.Session, ok: bool) {
	defer if !ok {tw_session_free(&dup, allocator)}
	dup.pane_key = tw_dup(session.pane_key, allocator) or_return
	dup.harness = tw_dup(session.harness, allocator) or_return
	dup.session = tw_dup(session.session, allocator) or_return
	return dup, true
}

@(private = "file")
tw_session_free :: proc(session: ^turns.Session, allocator: mem.Allocator) {
	delete(session.pane_key, allocator)
	delete(session.harness, allocator)
	delete(session.session, allocator)
	session^ = {}
}

@(private = "file")
tw_job_dup :: proc(job: Turn_Job, allocator: mem.Allocator) -> (dup: Turn_Job, ok: bool) {
	switch j in job {
	case Job_Begin:
		c := Job_Begin {
			started = j.started,
		}
		defer if !ok {tw_job_free_begin(&c, allocator)}
		c.pane_key = tw_dup(j.pane_key, allocator) or_return
		c.session = tw_session_dup(j.session, allocator) or_return
		c.directory = tw_dup(j.directory, allocator) or_return
		c.paths = tw_dup_all(j.paths, allocator) or_return
		c.ack = tw_dup(j.ack, allocator) or_return
		c.transcript = tw_dup(j.transcript, allocator) or_return
		c.title = tw_dup(j.title, allocator) or_return
		return c, true
	case Job_Edit:
		c: Job_Edit
		defer if !ok {tw_job_free_edit(&c, allocator)}
		c.pane_key = tw_dup(j.pane_key, allocator) or_return
		c.paths = tw_dup_all(j.paths, allocator) or_return
		c.ack = tw_dup(j.ack, allocator) or_return
		c.title = tw_dup(j.title, allocator) or_return
		return c, true
	case Job_End:
		c := Job_End {
			started      = j.started,
			ended        = j.ended,
			end_state    = j.end_state,
			sources      = j.sources,
			settle_until = j.settle_until,
		}
		defer if !ok {tw_job_free_end(&c, allocator)}
		c.pane_key = tw_dup(j.pane_key, allocator) or_return
		c.session = tw_session_dup(j.session, allocator) or_return
		c.title = tw_dup(j.title, allocator) or_return
		return c, true
	case Job_Query:
		c := Job_Query {
			pane    = j.pane,
			request = j.request,
			agent   = j.agent,
		}
		defer if !ok {tw_job_free_query(&c, allocator)}
		c.directory = tw_dup(j.directory, allocator) or_return
		c.session = tw_session_dup(j.session, allocator) or_return
		if len(j.selected) > 0 {
			selected, selected_error := slice.clone(j.selected, allocator)
			if selected_error != nil {return {}, false}
			c.selected = selected
		}
		return c, true
	case Job_Plain:
		c := Job_Plain {
			pane    = j.pane,
			request = j.request,
			mode    = j.mode,
		}
		defer if !ok {tw_job_free_plain(&c, allocator)}
		c.directory = tw_dup(j.directory, allocator) or_return
		c.session = tw_session_dup(j.session, allocator) or_return
		c.worktree = tw_dup(j.worktree, allocator) or_return
		return c, true
	case Job_View_Watch:
		c := Job_View_Watch {
			pane = j.pane,
		}
		c.directory = tw_dup(j.directory, allocator) or_return
		return c, true
	case Job_Watch_Root:
		c: Job_Watch_Root
		c.directory = tw_dup(j.directory, allocator) or_return
		return c, true
	case Job_View_Unwatch, Job_Maintain, Job_Stop, Job_Delete_All:
		return j, true
	}
	return nil, false
}

@(private = "file")
tw_job_free_begin :: proc(job: ^Job_Begin, allocator: mem.Allocator) {
	delete(job.pane_key, allocator)
	tw_session_free(&job.session, allocator)
	delete(job.directory, allocator)
	tw_free_all(job.paths, allocator)
	delete(job.ack, allocator)
	delete(job.transcript, allocator)
	delete(job.title, allocator)
}

@(private = "file")
tw_job_free_edit :: proc(job: ^Job_Edit, allocator: mem.Allocator) {
	delete(job.pane_key, allocator)
	tw_free_all(job.paths, allocator)
	delete(job.ack, allocator)
	delete(job.title, allocator)
}

@(private = "file")
tw_job_free_end :: proc(job: ^Job_End, allocator: mem.Allocator) {
	delete(job.pane_key, allocator)
	tw_session_free(&job.session, allocator)
	delete(job.title, allocator)
}

@(private = "file")
tw_job_free_query :: proc(job: ^Job_Query, allocator: mem.Allocator) {
	delete(job.directory, allocator)
	tw_session_free(&job.session, allocator)
	delete(job.selected, allocator)
}

@(private = "file")
tw_job_free_plain :: proc(job: ^Job_Plain, allocator: mem.Allocator) {
	delete(job.directory, allocator)
	tw_session_free(&job.session, allocator)
	delete(job.worktree, allocator)
}

@(private = "file")
tw_job_free :: proc(job: ^Turn_Job, allocator: mem.Allocator) {
	switch &j in job^ {
	case Job_Begin:
		tw_job_free_begin(&j, allocator)
	case Job_Edit:
		tw_job_free_edit(&j, allocator)
	case Job_End:
		tw_job_free_end(&j, allocator)
	case Job_Query:
		tw_job_free_query(&j, allocator)
	case Job_Plain:
		tw_job_free_plain(&j, allocator)
	case Job_View_Watch:
		delete(j.directory, allocator)
	case Job_Watch_Root:
		delete(j.directory, allocator)
	case Job_View_Unwatch, Job_Maintain, Job_Stop, Job_Delete_All:
	}
	job^ = nil
}

@(private = "file")
tw_memory_make :: proc(parent: mem.Allocator) -> ^Turn_Memory {
	memory, new_error := new(Turn_Memory, parent)
	if new_error != nil {return nil}
	memory.parent = parent
	if vmem.arena_init_growing(&memory.arena, TW_RESULT_BLOCK) != nil {
		free(memory, parent)
		return nil
	}
	return memory
}

@(private = "file")
tw_memory_free :: proc(memory: ^Turn_Memory) {
	if memory == nil {return}
	parent := memory.parent
	vmem.arena_destroy(&memory.arena)
	free(memory, parent)
}

@(private = "file")
tw_main :: proc(t: ^thread.Thread) {
	worker := (^Turn_Worker)(t.data)
	state := &worker.state
	// The thread was started with a context of its own, so nothing frees its temp allocator for it.
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy((^runtime.Default_Temp_Allocator)(context.temp_allocator.data))
	}
	ticked := time.tick_now()
	for {
		sync.mutex_lock(&worker.mutex)
		for len(worker.jobs) == 0 && !worker.stop {
			// Only the worker changes its views, open turns and readers, so it may read them here.
			if len(state.views) == 0 && !tw_live_on(state) {
				sync.cond_wait(&worker.cond, &worker.mutex)
			} else if !sync.cond_wait_with_timeout(&worker.cond, &worker.mutex, TW_TICK) ||
			   time.tick_since(ticked) >= TW_TICK {
				break
			}
		}
		if worker.stop {
			// A turn that ends while the app closes still has its changes to save; the rest is dropped.
			remaining := make([dynamic]Turn_Job, 0, len(worker.jobs), worker.allocator)
			_, move_error := append(&remaining, ..worker.jobs[:])
			if move_error == nil {clear(&worker.jobs)}
			sync.mutex_unlock(&worker.mutex)
			// The read that was cancelled is over, and the turn jobs left must not be cancelled with it.
			sync.atomic_store(&worker.cancel.flag, false)
			for &queued in remaining {
				#partial switch _ in queued {
				case Job_Begin, Job_Edit, Job_End:
					tw_run(state, queued)
				}
				tw_job_free(&queued, worker.allocator)
			}
			delete(remaining)
			free_all(context.temp_allocator)
			return
		}
		job: Turn_Job
		has_job := len(worker.jobs) > 0
		if has_job {job = pop_front(&worker.jobs)}
		worker.running = has_job
		worker.reading = has_job && !tw_job_urgent(job)
		sync.mutex_unlock(&worker.mutex)

		if has_job {
			tw_run(state, job)
			tw_job_free(&job, worker.allocator)
			tw_prune(state)
		}
		tw_views_tick(state)
		tw_live_tick(state)
		ticked = time.tick_now()
		free_all(context.temp_allocator)
		tw_flush(worker)
		sync.mutex_lock(&worker.mutex)
		worker.running = false
		sync.mutex_unlock(&worker.mutex)
	}
}

// Hands the results of the work just done to the main thread and wakes its loop.
@(private = "file")
tw_flush :: proc(worker: ^Turn_Worker) {
	state := &worker.state
	if len(state.outbox) == 0 {return}
	sync.mutex_lock(&worker.mutex)
	_, append_error := append(&worker.results, ..state.outbox[:])
	sync.mutex_unlock(&worker.mutex)
	if append_error != nil {
		log.error("queueing turn results failed: out of memory")
		for &result in state.outbox {turn_result_destroy(&result)}
	}
	clear(&state.outbox)
	if worker.platform != nil && platform_api.wake(worker.platform) != .None {
		log.error("waking the main loop from the turn worker failed")
	}
}

@(private = "file")
tw_post :: proc(state: ^Tw_State, result: Turn_Result) {
	posted := result
	if _, append_error := append(&state.outbox, posted); append_error != nil {
		log.error("queueing a turn result failed: out of memory")
		turn_result_destroy(&posted)
	}
}

// Posts the failure of a job that needed git or the store, unless it did not fail. A directory that is
// not in a repository is no failure: most panes never run an agent in one.
@(private = "file")
tw_failed :: proc(state: ^Tw_State, err: turns.Error, what: string) {
	if err == .None {return}
	log.warnf("turn recording: %s failed: %v", what, err)
	tw_post(state, Result_Failure{error = err, what = what})
}

// Remembers the first error that matters.
@(private = "file")
tw_note :: proc(failure: ^turns.Error, err: turns.Error) {
	if err == .None || err == .Not_Repository || failure^ != .None {return}
	failure^ = err
}

@(private = "file")
tw_run :: proc(state: ^Tw_State, job: Turn_Job) {
	clear(&state.listings)
	state.claim_since, state.drain_until = 0, 0
	switch j in job {
	case Job_Begin:
		tw_begin(state, j)
	case Job_Edit:
		tw_edit(state, j)
	case Job_End:
		tw_end(state, j)
	case Job_Query:
		tw_reader_set(state, j.pane, true)
		tw_query(state, j)
	case Job_Plain:
		tw_reader_set(state, j.pane, false)
		tw_plain(state, j)
	case Job_View_Watch:
		tw_view_watch(state, j)
	case Job_View_Unwatch:
		// Sent when a pane stops watching, and when it closes.
		tw_reader_set(state, j.pane, false)
		tw_view_leave(state, j.pane)
	case Job_Maintain:
		tw_maintain(state, j)
	case Job_Stop:
		tw_stop(state)
	case Job_Delete_All:
		tw_delete_all(state)
	case Job_Watch_Root:
		tw_watch_root(state, j)
	}
}

// Notes whether the pane's latest read is of turns.
@(private = "file")
tw_reader_set :: proc(state: ^Tw_State, pane: u32, reads: bool) {
	at, found := slice.linear_search(state.readers[:], pane)
	if !reads && found {unordered_remove(&state.readers, at)}
	if reads && !found {
		if _, append_error := append(&state.readers, pane); append_error != nil {
			log.error("noting a pane that shows turns failed: out of memory")
		}
	}
}

// Whether an open turn's changes have a pane to tell.
@(private = "file")
tw_live_on :: proc(state: ^Tw_State) -> bool {
	return len(state.opens) > 0 && len(state.readers) > 0
}

// A root whose work tree is gone has nothing left to follow once no turn or change refers to it.
@(private = "file")
tw_prune :: proc(state: ^Tw_State) {
	for i := len(state.roots) - 1; i >= 0; i -= 1 {
		root := state.roots[i]
		if len(root.presences) > 0 || len(root.pending) > 0 {continue}
		if os.is_directory(root.repository.worktree) {continue}
		tw_root_destroy(state, root)
		unordered_remove(&state.roots, i)
	}
}

@(private = "file")
tw_state_destroy :: proc(state: ^Tw_State) {
	tw_stop(state)
	delete(state.roots)
	delete(state.readers)
	delete(state.opens)
	delete(state.links)
	delete(state.listings)
	delete(state.transcripts)
	delete(state.families)
	for store in state.stores {tw_store_free(state, store)}
	delete(state.stores)
	for view in state.views {tw_view_free(state, view)}
	delete(state.views)
	turns.watch_set_destroy(state.watches)
	for &result in state.outbox {turn_result_destroy(&result)}
	delete(state.outbox)
}

@(private = "file")
tw_stop :: proc(state: ^Tw_State) {
	for root in state.roots {tw_root_destroy(state, root)}
	clear(&state.roots)
	for open in state.opens {tw_open_free(state, open)}
	clear(&state.opens)
	for link in state.links {
		delete(link.key, state.allocator)
		delete(link.worktree, state.allocator)
	}
	clear(&state.links)
	for key in state.families {delete(key, state.allocator)}
	clear(&state.families)
	for transcript in state.transcripts {delete(transcript.path, state.allocator)}
	clear(&state.transcripts)
}

@(private = "file")
tw_delete_all :: proc(state: ^Tw_State) {
	tw_stop(state)
	for store in state.stores {tw_store_free(state, store)}
	clear(&state.stores)
	err := turns.store_delete_all(state.directory)
	if err != .None {log.warnf("turn recording: deleting the recorded turns failed: %v", err)}
	tw_post(state, Result_Deleted{error = err})
}

@(private = "file")
tw_ack :: proc(path: string) {
	if path == "" {return}
	if err := os.remove(path); err != nil && err != .Not_Exist {
		log.warnf("could not delete the hook file %q: %v", path, err)
	}
}

@(private = "file")
tw_text_valid :: proc(path: string) -> bool {
	return utf8.valid_string(path) && strings.index_byte(path, 0) < 0
}

@(private = "file")
tw_git_internal :: proc(path: string) -> bool {
	if path == ".git" || strings.has_prefix(path, ".git/") {return true}
	return strings.contains(path, "/.git/") || strings.has_suffix(path, "/.git")
}

// The folder a work tree is in, the last part of its path.
@(private = "file")
tw_folder :: proc(worktree: string) -> string {
	trimmed := strings.trim_right(worktree, "/")
	name := trimmed[strings.last_index_byte(trimmed, '/') + 1:]
	return name if name != "" else "root"
}

// `path` relative to `worktree` when it lies inside it. Windows paths differ only in case when they
// name the same file.
@(private = "file")
tw_path_under :: proc(worktree, path: string) -> (relative: string, ok: bool) {
	if worktree == "" || len(path) <= len(worktree) {return "", false}
	if !strings.equal_fold(path[:len(worktree)], worktree) {return "", false}
	rest := path[len(worktree):]
	if worktree[len(worktree) - 1] != '/' {
		if rest[0] != '/' {return "", false}
		rest = rest[1:]
	}
	return rest, rest != ""
}

// An absolute path with '/' separators in the temp allocator; a relative one is taken from `directory`.
@(private = "file")
tw_absolute :: proc(directory, path: string) -> (string, bool) {
	parts := [?]string{directory, path}
	used := parts[:]
	if os.is_absolute_path(path) {used = parts[1:]}
	absolute, err := strings.join(used, "/", context.temp_allocator)
	if err != nil {return "", false}
	tw_slashes(absolute)
	return absolute, true
}

@(private = "file")
tw_store_find :: proc(state: ^Tw_State, key: string) -> ^Tw_Store {
	for store in state.stores {
		if store.key == key {return store}
	}
	return nil
}

@(private = "file")
tw_store_new :: proc(state: ^Tw_State, key: string) -> ^Tw_Store {
	allocator := state.allocator
	store, new_error := new(Tw_Store, allocator)
	if new_error != nil {return nil}
	cloned, clone_error := strings.clone(key, allocator)
	if clone_error != nil {
		free(store, allocator)
		return nil
	}
	store.key = cloned
	store.segments.allocator = allocator
	if _, append_error := append(&state.stores, store); append_error != nil {
		delete(cloned, allocator)
		free(store, allocator)
		return nil
	}
	return store
}

@(private = "file")
tw_store_free :: proc(state: ^Tw_State, store: ^Tw_Store) {
	allocator := state.allocator
	for &segment in store.segments {turns.segment_destroy(&segment, allocator)}
	delete(store.segments)
	turns.store_destroy(&store.store, allocator)
	delete(store.key, allocator)
	free(store, allocator)
}

// Drops the store from the list and frees it. Roots that use it must be gone first.
@(private = "file")
tw_store_remove :: proc(state: ^Tw_State, store: ^Tw_Store) {
	if at, found := slice.linear_search(state.stores[:], store); found {unordered_remove(&state.stores, at)}
	tw_store_free(state, store)
}

// The store a repository records into, opened (created or repaired) once per run.
@(private = "file")
tw_store_open :: proc(
	state: ^Tw_State,
	repository: turns.Repository,
) -> (
	store: ^Tw_Store,
	err: turns.Error,
) {
	store = tw_store_find(state, repository.key)
	if store != nil && store.opened {return store, .None}
	opened := turns.store_open(state.directory, repository, state.allocator, state.cancel) or_return
	if store == nil {
		store = tw_store_new(state, repository.key)
		if store == nil {
			discarded := opened
			turns.store_destroy(&discarded, state.allocator)
			return nil, .Out_Of_Memory
		}
	} else {
		turns.store_destroy(&store.store, state.allocator)
	}
	store.store = opened
	store.opened = true
	return store, .None
}

// The store of a repository that has a directory under the turns directory, for reading; nil when it
// has none. Reading never creates one.
@(private = "file")
tw_store_existing :: proc(state: ^Tw_State, key: string) -> ^Tw_Store {
	if store := tw_store_find(state, key); store != nil {
		return store if os.is_directory(store.store.directory) else nil
	}
	allocator := state.allocator
	directory, directory_error := strings.join({state.directory, key}, "/", allocator)
	if directory_error != nil {return nil}
	if !os.is_directory(directory) {
		delete(directory, allocator)
		return nil
	}
	git_dir, git_error := strings.join({directory, TW_STORE}, "/", allocator)
	store: ^Tw_Store
	if git_error == nil {store = tw_store_new(state, key)}
	if store == nil {
		delete(directory, allocator)
		delete(git_dir, allocator)
		return nil
	}
	store.store = {
		directory = directory,
		git_dir   = git_dir,
	}
	return store
}

// The path of a segment file in the store, or of the segments directory when `name` is empty.
@(private = "file")
tw_segment_path :: proc(store: ^Tw_Store, name: string, allocator: mem.Allocator) -> string {
	if name == "" {return strings.join({store.store.directory, turns.SEGMENTS_NAME}, "/", allocator)}
	return strings.join({store.store.directory, turns.SEGMENTS_NAME, name}, "/", allocator)
}

// Reads the segment files once; saved segments are added to the cache from then on. A file that cannot
// be read is skipped, so one bad file never hides the rest.
@(private = "file")
tw_store_load :: proc(state: ^Tw_State, store: ^Tw_Store) {
	if store.loaded {return}
	allocator := state.allocator
	directory := tw_segment_path(store, "", context.temp_allocator)
	files, read_error := os.read_all_directory_by_path(directory, allocator)
	if read_error != nil {
		if read_error == .Not_Exist {
			store.loaded = true
		} else {
			log.warnf("could not list the segments in %q: %v", directory, read_error)
		}
		return
	}
	defer os.file_info_slice_delete(files, allocator)
	store.loaded = true
	for file in files {
		if file.type != .Regular || !strings.has_suffix(file.name, turns.SEGMENT_EXTENSION) {continue}
		if file.size > turns.SEGMENT_LIMIT {
			log.warnf("skipping the oversize segment file %q", file.fullpath)
			continue
		}
		data, data_error := os.read_entire_file(file.fullpath, allocator)
		if data_error != nil {
			log.warnf("could not read the segment file %q: %v", file.fullpath, data_error)
			continue
		}
		segment, decoded := turns.segment_decode(data, allocator)
		delete(data, allocator)
		if !decoded {
			log.warnf("skipping the unreadable segment file %q", file.fullpath)
			continue
		}
		if turns.segment_file_name(segment.id, context.temp_allocator) != file.name {
			log.warnf("skipping the segment file %q, which names another id", file.fullpath)
			turns.segment_destroy(&segment, allocator)
			continue
		}
		if _, append_error := append(&store.segments, segment); append_error != nil {
			turns.segment_destroy(&segment, allocator)
			return
		}
	}
}

// Forgets the cache, so the next read lists the files again.
@(private = "file")
tw_store_unload :: proc(state: ^Tw_State, store: ^Tw_Store) {
	for &segment in store.segments {turns.segment_destroy(&segment, state.allocator)}
	clear(&store.segments)
	store.loaded = false
}

// Whether a root uses the store. The blobs of the files a root has seen are reachable from no ref, so
// such a store is never pruned unpinned, and never removed: its root's baseline lives in it.
@(private = "file")
tw_store_live :: proc(state: ^Tw_State, store: ^Tw_Store) -> bool {
	for root in state.roots {
		if root.store == store {return true}
	}
	return false
}

@(private = "file")
tw_id_taken :: proc(stores: []^Tw_Store, id: u64) -> bool {
	name := turns.segment_file_name(id, context.temp_allocator)
	for store in stores {
		path := tw_segment_path(store, name, context.temp_allocator)
		if os.exists(path) {return true}
	}
	return false
}

// Ids follow the clock, so a newer segment has a larger id, and are never reused in any of `stores`.
@(private = "file")
tw_next_id :: proc(state: ^Tw_State, stores: []^Tw_Store) -> u64 {
	id := max(u64(tw_now_ms()) << 8, state.last_id + 1)
	for tw_id_taken(stores, id) {id += 1}
	state.last_id = id
	return id
}

@(private = "file")
tw_changes_sort :: proc(changes: []turns.Change) {
	slice.sort_by(changes, proc(a, b: turns.Change) -> bool {
		if a.worktree != b.worktree {return a.worktree < b.worktree}
		return a.path < b.path
	})
}

// The git entries of sides, their paths prefixed with the work tree's folder name when more than one
// work tree is involved, so equal paths in two work trees stay apart. Two folders of one name are told
// apart by a number.
@(private = "file")
tw_entries :: proc(sides: []Tw_Side, allocator: mem.Allocator) -> ([]turns.Diff_Entry, bool) {
	entries, make_error := make([]turns.Diff_Entry, len(sides), allocator)
	if make_error != nil {return nil, false}
	worktrees := make([dynamic]string, 0, 4, context.temp_allocator)
	for side in sides {
		if !slice.contains(worktrees[:], side.worktree) {append(&worktrees, side.worktree)}
	}
	labels := make([dynamic]string, 0, len(worktrees), context.temp_allocator)
	if len(worktrees) > 1 {
		for worktree in worktrees {
			label := tw_folder(worktree)
			for number := 2; slice.contains(labels[:], label); number += 1 {
				label = fmt.tprintf("%s (%d)", tw_folder(worktree), number)
			}
			append(&labels, label)
		}
	}
	for side, i in sides {
		path := side.path
		if len(worktrees) > 1 {
			at, _ := slice.linear_search(worktrees[:], side.worktree)
			joined, join_error := strings.join({labels[at], side.path}, "/", allocator)
			if join_error != nil {return nil, false}
			path = joined
		}
		entries[i] = {
			path   = path,
			before = side.before,
			after  = side.after,
		}
	}
	return entries, true
}

// Lines added and removed over the changes, as the diff of their blobs counts them; zero when git
// cannot tell, since the counts are only for display.
@(private = "file")
tw_measure :: proc(state: ^Tw_State, store: ^Tw_Store, changes: []turns.Change) -> (added, removed: int) {
	if len(changes) == 0 {return}
	sides := make([]Tw_Side, len(changes), context.temp_allocator)
	for change, i in changes {
		sides[i] = {change.worktree, change.path, change.before, change.after}
	}
	entries, labelled := tw_entries(sides, context.temp_allocator)
	if !labelled {return}
	allocator := state.allocator
	patch, patch_error := turns.diff_entries(store.store, entries, allocator, state.cancel)
	if patch_error != .None {
		log.warnf("counting the lines of a segment failed: %v", patch_error)
		return
	}
	defer delete(patch, allocator)
	diff, parsed := turns.diff_parse(patch, allocator)
	if !parsed {
		log.warn("counting the lines of a segment failed: the patch did not parse")
		return
	}
	defer turns.diff_destroy(&diff)
	for file in diff.files {
		added += file.added
		removed += file.removed
	}
	return
}

// Keeps the segment's blobs in the store, writes its file, and adds it to the cache. The blobs are
// kept first: until a ref reaches them nothing stops a prune from taking them.
@(private = "file")
tw_segment_save :: proc(state: ^Tw_State, store: ^Tw_Store, segment: ^turns.Segment) -> turns.Error {
	segment.added, segment.removed = tw_measure(state, store, segment.changes)
	oids := make([dynamic]turns.Oid, 0, 2 * len(segment.changes), context.temp_allocator)
	for change in segment.changes {
		if change.before != "" {append(&oids, change.before)}
		if change.after != "" {append(&oids, change.after)}
	}
	turns.segment_keep(store.store, segment.id, oids[:], state.cancel) or_return
	err := tw_segment_write(state, store, segment^)
	if err != .None {
		ids := [?]u64{segment.id}
		if drop_error := turns.segment_drop(store.store, ids[:], state.cancel); drop_error != .None {
			log.warnf("dropping the blobs of an unsaved segment failed: %v", drop_error)
		}
	}
	return err
}

@(private = "file")
tw_segment_write :: proc(state: ^Tw_State, store: ^Tw_Store, segment: turns.Segment) -> turns.Error {
	temp := context.temp_allocator
	encoded := segment
	text, text_ok := turns.segment_encode(encoded, temp)
	if !text_ok && encoded.title != "" {
		// A title is the one free text a program supplies, and not always valid UTF-8.
		log.warn("a segment's title cannot be stored, so it is saved without one")
		encoded.title = ""
		text, text_ok = turns.segment_encode(encoded, temp)
	}
	if !text_ok {
		log.warn("a segment cannot be encoded")
		return .Failed
	}
	name := turns.segment_file_name(segment.id, temp)
	path := tw_segment_path(store, name, temp)
	partial := strings.concatenate({path, ".tmp"}, temp)
	if write_error := os.write_entire_file(partial, text); write_error != nil {
		log.errorf("could not write %q: %v", partial, write_error)
		return .Failed
	}
	// The file appears whole or not at all, so a crash never leaves half a segment to be skipped.
	if rename_error := os.rename(partial, path); rename_error != nil {
		log.errorf("could not rename %q: %v", partial, rename_error)
		_ = os.remove(partial)
		return .Failed
	}
	// Past the rename the segment exists whatever happens to the cache, so nothing here fails the save.
	// A cache that falls behind is dropped, and the next read lists the files again.
	if !store.loaded {
		tw_store_load(state, store)
		return .None
	}
	cached, decoded := turns.segment_decode(transmute([]u8)text, state.allocator)
	if !decoded {
		log.warn("a segment that was just written does not decode")
		tw_store_unload(state, store)
		return .None
	}
	if _, append_error := append(&store.segments, cached); append_error != nil {
		turns.segment_destroy(&cached, state.allocator)
		tw_store_unload(state, store)
	}
	return .None
}

// The keys, each once, copied into `allocator`; false when memory ran out.
@(private = "file")
tw_keys_copy :: proc(keys: []string, allocator: mem.Allocator) -> ([]string, bool) {
	unique := make([dynamic]string, 0, len(keys), context.temp_allocator)
	for key in keys {
		if !slice.contains(unique[:], key) {append(&unique, key)}
	}
	return tw_dup_all(unique[:], allocator)
}

// Posts the keys as one Result_Saved, each once; one key stands for one segment file written.
@(private = "file")
tw_saved_post :: proc(state: ^Tw_State, keys: []string) {
	if len(keys) == 0 {return}
	repositories, copied := tw_keys_copy(keys, state.allocator)
	if !copied {
		log.error("posting the saved segments failed: out of memory")
		return
	}
	saved := Result_Saved {
		repositories = repositories,
		segments     = len(keys),
		allocator    = state.allocator,
	}
	tw_post(state, saved)
}

// Posts the keys as one Result_Live, each once.
@(private = "file")
tw_live_post :: proc(state: ^Tw_State, keys: []string) {
	if len(keys) == 0 {return}
	repositories, copied := tw_keys_copy(keys, state.allocator)
	if !copied {
		log.error("posting a turn's changes failed: out of memory")
		return
	}
	tw_post(state, Result_Live{repositories = repositories, allocator = state.allocator})
}

@(private = "file")
tw_root_find :: proc(state: ^Tw_State, worktree: string) -> ^Tw_Root {
	for root in state.roots {
		if strings.equal_fold(root.repository.worktree, worktree) {return root}
	}
	return nil
}

@(private = "file")
tw_watch_add :: proc(state: ^Tw_State, worktree: string) -> turns.Watch_Id {
	id, added := turns.watch_set_add(state.watches, worktree, true)
	return id if added else 0
}

@(private = "file")
tw_watch_remove :: proc(state: ^Tw_State, id: turns.Watch_Id) {
	if id != 0 {turns.watch_set_remove(state.watches, id)}
}

// Takes what the root's watch has collected into `out`. True when changes may have been lost: the watch
// overflowed or stopped. A watch that stopped is dropped and the root is lost until a drain finds its
// directory again.
@(private = "file")
tw_root_take :: proc(state: ^Tw_State, root: ^Tw_Root, out: ^[dynamic]string) -> bool {
	if root.watch == 0 {return true}
	overflowed, dead := turns.watch_set_take(state.watches, root.watch, out, context.temp_allocator)
	if dead {
		tw_watch_remove(state, root.watch)
		root.watch = 0
		root.lost = true
	}
	return overflowed || dead
}

@(private = "file")
tw_net_merge :: proc(
	nets: ^map[string]Tw_Net,
	path: string,
	before, after: turns.Oid,
	shared: bool,
	stamp: u64,
	allocator: mem.Allocator,
) -> bool {
	if net, found := &nets^[path]; found {
		latest := tw_dup(after, allocator) or_return
		delete(net.after, allocator)
		net.after = latest
		net.shared = net.shared || shared
		net.stamp = stamp
		return true
	}
	key := tw_dup(path, allocator) or_return
	first, first_ok := tw_dup(before, allocator)
	latest, latest_ok := tw_dup(after, allocator)
	if first_ok && latest_ok {
		_, value, _, insert_error := map_entry(nets, key)
		if insert_error == nil {
			value^ = Tw_Net{first, latest, shared, stamp, tw_now_ms()}
			return true
		}
	}
	delete(key, allocator)
	delete(first, allocator)
	delete(latest, allocator)
	return false
}

@(private = "file")
tw_net_clear :: proc(nets: ^map[string]Tw_Net, allocator: mem.Allocator) {
	for path, net in nets^ {
		delete(path, allocator)
		delete(net.before, allocator)
		delete(net.after, allocator)
	}
	clear(nets)
}

// Records `oid` as the path's content as last seen.
@(private = "file")
tw_known_set :: proc(known: ^map[string]turns.Oid, path, oid: string, allocator: mem.Allocator) -> bool {
	latest := tw_dup(oid, allocator) or_return
	if current, found := &known^[path]; found {
		delete(current^, allocator)
		current^ = latest
		return true
	}
	key, key_ok := tw_dup(path, allocator)
	if key_ok {
		_, value, _, insert_error := map_entry(known, key)
		if insert_error == nil {
			value^ = latest
			return true
		}
	}
	delete(key, allocator)
	delete(latest, allocator)
	return false
}

@(private = "file")
tw_presence_free :: proc(state: ^Tw_State, presence: ^Tw_Presence) {
	allocator := state.allocator
	for path in presence.named {delete(path, allocator)}
	delete(presence.named)
	tw_net_clear(&presence.changes, allocator)
	delete(presence.changes)
	free(presence, allocator)
}

@(private = "file")
tw_presence_find :: proc(root: ^Tw_Root, open: ^Tw_Open) -> ^Tw_Presence {
	for presence in root.presences {
		if presence.open == open {return presence}
	}
	return nil
}

@(private = "file")
tw_presence_name :: proc(presence: ^Tw_Presence, path: string, allocator: mem.Allocator) -> bool {
	if path in presence.named {return true}
	key := tw_dup(path, allocator) or_return
	if _, _, _, insert_error := map_entry(&presence.named, key); insert_error != nil {
		delete(key, allocator)
		return false
	}
	return true
}

@(private = "file")
tw_root_destroy :: proc(state: ^Tw_State, root: ^Tw_Root) {
	allocator := state.allocator
	tw_watch_remove(state, root.watch)
	for path in root.carry {delete(path, allocator)}
	delete(root.carry)
	for path in root.seed {delete(path, allocator)}
	delete(root.seed)
	tw_net_clear(&root.claimed, allocator)
	delete(root.claimed)
	for path in root.taken {delete(path, allocator)}
	delete(root.taken)
	delete(root.base, allocator)
	for presence in root.presences {tw_presence_free(state, presence)}
	delete(root.presences)
	for path, oid in root.known {
		delete(path, allocator)
		delete(oid, allocator)
	}
	delete(root.known)
	tw_net_clear(&root.pending, allocator)
	delete(root.pending)
	turns.repository_destroy(&root.repository, allocator)
	free(root, allocator)
}

// The commit the work tree is on: "" when it has none yet.
@(private = "file")
tw_head :: proc(
	worktree: string,
	allocator: mem.Allocator,
	cancel: ^turns.Git_Cancel,
) -> (
	oid: string,
	err: turns.Error,
) {
	args := [?]string{"rev-parse", "--verify", "-q", "HEAD"}
	output := turns.git_run(args[:], {cwd = worktree, cancel = cancel}, context.temp_allocator) or_return
	if output.code != 0 {return "", .None}
	head := strings.trim_space(string(output.stdout))
	if head == "" || !turns.oid_valid(head) {return "", .None}
	return tw_copy(head, allocator)
}

@(private = "file")
tw_root_set_base :: proc(state: ^Tw_State, root: ^Tw_Root) -> turns.Error {
	base := tw_head(root.repository.worktree, state.allocator, state.cancel) or_return
	delete(root.base, state.allocator)
	root.base = base
	return .None
}

// A path list on a command line must stay short of what Windows accepts.
@(private = "file")
TW_TREE_BATCH :: 8000

// The blob each path has in commit `base`, "" for a path it lacks, and for every path when there is no
// commit. The paths go to git in batches, whatever their number.
@(private = "file")
tw_tree_oids :: proc(
	worktree, base: string,
	paths: []string,
	allocator: mem.Allocator,
	cancel: ^turns.Git_Cancel,
) -> (
	oids: []turns.Oid,
	err: turns.Error,
) {
	oids = make([]turns.Oid, len(paths), allocator)
	if base == "" || len(paths) == 0 {return oids, .None}
	at := make(map[string]int, len(paths), context.temp_allocator)
	for path, i in paths {at[path] = i}
	for first := 0; first < len(paths); {
		args := make([dynamic]string, 0, 64, context.temp_allocator)
		append(&args, "ls-tree", "-z", "--full-tree", base, "--")
		size := 0
		last := first
		for last < len(paths) && (last == first || size < TW_TREE_BATCH) {
			append(&args, paths[last])
			size += len(paths[last]) + 1
			last += 1
		}
		first = last
		output := turns.git_run(args[:], {cwd = worktree, cancel = cancel}, context.temp_allocator) or_return
		if output.code != 0 {
			log.warnf("git ls-tree exited with %d: %s", output.code, strings.trim_space(output.stderr))
			return nil, .Failed
		}
		rest := string(output.stdout)
		for len(rest) > 0 {
			// <mode> SP <type> SP <oid> TAB <path>, each record ending in NUL.
			end := strings.index_byte(rest, 0)
			record := rest if end < 0 else rest[:end]
			rest = "" if end < 0 else rest[end + 1:]
			tab := strings.index_byte(record, '\t')
			if tab < 0 {continue}
			index, wanted := at[record[tab + 1:]]
			fields := strings.split(record[:tab], " ", context.temp_allocator)
			if !wanted || len(fields) != 3 || fields[1] != "blob" {continue}
			oids[index] = tw_copy(fields[2], allocator) or_return
		}
	}
	return oids, .None
}

// Takes the baseline of a root whose watch is already running: the content of every file git calls
// dirty. Those are the files whose before is not in the base commit.
@(private = "file")
tw_root_baseline :: proc(state: ^Tw_State, root: ^Tw_Root) -> turns.Error {
	temp := context.temp_allocator
	worktree := root.repository.worktree
	tw_root_set_base(state, root) or_return
	states := turns.dirty_paths(worktree, temp, state.cancel) or_return
	paths := make([dynamic]string, 0, len(states), temp)
	for item in states {
		if tw_text_valid(item.path) && !tw_git_internal(item.path) {append(&paths, item.path)}
	}
	kept := turns.keep_unignored(worktree, paths[:], temp, state.cancel) or_return
	oids := turns.hash_paths(root.store.store, worktree, kept, temp, state.cancel) or_return
	for path, i in kept {
		if !tw_known_set(&root.known, path, oids[i], state.allocator) {return .Out_Of_Memory}
	}
	return tw_root_suspect(state, root)
}

// A file written after the watch started and before its baseline was hashed has been hashed as it is
// now, so the baseline would take an edit for the content before it, and the drain would then see no
// change. Whatever the watch reported meanwhile is therefore known by its content in the base commit
// instead (nothing for a file that is not there), and stays for the next drain. A file an earlier
// uncommitted edit changed may be counted into the next turn: that is the lesser harm.
@(private = "file")
tw_root_suspect :: proc(state: ^Tw_State, root: ^Tw_Root) -> turns.Error {
	temp := context.temp_allocator
	worktree := root.repository.worktree
	candidates := make([dynamic]string, temp)
	if root.watch != 0 && tw_root_take(state, root, &candidates) {root.rescan = true}
	paths := tw_drain_paths(state, root, candidates[:])
	kept := turns.keep_unignored(worktree, paths, temp, state.cancel) or_return
	indexed := tw_tree_oids(worktree, root.base, kept, temp, state.cancel) or_return
	for path, i in kept {
		if !tw_known_set(&root.known, path, indexed[i], state.allocator) {return .Out_Of_Memory}
		copied, copied_ok := tw_dup(path, state.allocator)
		if !copied_ok {return .Out_Of_Memory}
		if _, append_error := append(&root.carry, copied); append_error != nil {
			delete(copied, state.allocator)
			return .Out_Of_Memory
		}
	}
	return .None
}

// A root with nothing followed yet. Takes ownership of `repository`.
@(private = "file")
tw_root_new :: proc(state: ^Tw_State, repository: turns.Repository) -> (root: ^Tw_Root, err: turns.Error) {
	allocator := state.allocator
	fresh, new_error := new(Tw_Root, allocator)
	if new_error != nil {
		discarded := repository
		turns.repository_destroy(&discarded, allocator)
		return nil, .Out_Of_Memory
	}
	fresh.repository = repository
	fresh.known = make(map[string]turns.Oid, allocator)
	fresh.pending = make(map[string]Tw_Net, allocator)
	fresh.presences.allocator = allocator
	fresh.carry.allocator = allocator
	fresh.seed.allocator = allocator
	fresh.claimed = make(map[string]Tw_Net, allocator)
	fresh.taken = make(map[string]Tw_Taken, allocator)
	fresh.fresh = true
	return fresh, .None
}

// Takes ownership of `repository`.
@(private = "file")
tw_root_create :: proc(state: ^Tw_State, repository: turns.Repository) -> (root: ^Tw_Root, err: turns.Error) {
	fresh := tw_root_new(state, repository) or_return
	defer if err != .None {tw_root_destroy(state, fresh)}
	// The watch comes first: a change from here on is seen by it, and one made earlier is in the baseline.
	// Opening the store takes long enough for an agent to have edited a file meanwhile.
	fresh.watch = tw_watch_add(state, repository.worktree)
	fresh.since = tw_now_ms()
	fresh.store, err = tw_store_open(state, repository)
	if err != .None {return nil, err}
	err = tw_root_baseline(state, fresh)
	if err != .None {return nil, err}
	if _, append_error := append(&state.roots, fresh); append_error != nil {return nil, .Out_Of_Memory}
	return fresh, .None
}

// A root for a work tree no turn began in: nothing is hashed, and a file not seen changing had its content
// in `base`. `listed`: the work tree was already there when its family was first followed, so a rescan
// does not take what was dirty in it then. Takes ownership of `repository`.
@(private = "file")
tw_root_create_lazy :: proc(
	state: ^Tw_State,
	repository: turns.Repository,
	base: turns.Oid,
	listed: bool,
) -> (
	root: ^Tw_Root,
	err: turns.Error,
) {
	fresh := tw_root_new(state, repository) or_return
	defer if err != .None {tw_root_destroy(state, fresh)}
	fresh.lazy = true
	if listed {fresh.followed_at = time.to_unix_nanoseconds(time.now())}
	fresh.base = tw_copy(base, state.allocator) or_return
	fresh.watch = tw_watch_add(state, repository.worktree)
	fresh.since = tw_now_ms()
	fresh.store, err = tw_store_open(state, repository)
	if err != .None {return nil, err}
	if _, append_error := append(&state.roots, fresh); append_error != nil {return nil, .Out_Of_Memory}
	return fresh, .None
}

// Whether the file was last written at or after `since` (Unix nanoseconds); false when it cannot be read.
@(private = "file")
tw_written_after :: proc(worktree, path: string, since: i64) -> bool {
	full := strings.join({worktree, path}, "/", context.temp_allocator)
	info, stat_error := os.stat(full, context.temp_allocator)
	return stat_error == nil && time.to_unix_nanoseconds(info.modification_time) >= since
}

// Whether the file was last written after `from` and no later than `to` (Unix milliseconds); false when
// it cannot be read.
@(private = "file")
tw_written_between :: proc(worktree, path: string, from, to: i64) -> bool {
	full := strings.join({worktree, path}, "/", context.temp_allocator)
	info, stat_error := os.stat(full, context.temp_allocator)
	if stat_error != nil {return false}
	written := time.to_unix_nanoseconds(info.modification_time)
	return written >= (from + 1) * i64(time.Millisecond) && written < (to + 1) * i64(time.Millisecond)
}

// Whether a dirty path that a lazy root's rescan found, and the watch never reported, was changed since the
// root was followed: a file counts when written then or later; a deletion has no time to tell.
@(private = "file")
tw_written_since :: proc(worktree: string, item: turns.Path_State, since: i64) -> bool {
	return !item.deleted && tw_written_after(worktree, item.path, since)
}

// Has the next drain of the root look at the path.
@(private = "file")
tw_seed_add :: proc(state: ^Tw_State, root: ^Tw_Root, path: string) -> bool {
	copied := tw_dup(path, state.allocator) or_return
	if _, append_error := append(&root.seed, copied); append_error != nil {
		delete(copied, state.allocator)
		return false
	}
	return true
}

// Gives the changes no turn took, because it began elsewhere, to Between.
@(private = "file")
tw_claims_release :: proc(state: ^Tw_State) {
	state.claim_since = 0
	for root in state.roots {
		for path, net in root.claimed {
			if !tw_net_merge(&root.pending, path, net.before, net.after, net.shared, net.stamp, state.allocator) {
				log.error("keeping a change failed: out of memory")
			}
		}
		tw_net_clear(&root.claimed, state.allocator)
	}
}

// A root that was followed without a baseline gets one when a turn begins in its own folder: what is
// dirty now is what that turn starts from. Changes seen so far are drained first, and keep their before.
@(private = "file")
tw_root_upgrade :: proc(state: ^Tw_State, root: ^Tw_Root) -> turns.Error {
	if !root.lazy {return .None}
	temp := context.temp_allocator
	worktree := root.repository.worktree
	tw_drain(state, root, false) or_return
	states := turns.dirty_paths(worktree, temp, state.cancel) or_return
	paths := make([dynamic]string, 0, len(states), temp)
	for item in states {
		if tw_text_valid(item.path) && !tw_git_internal(item.path) && item.path not_in root.known {
			append(&paths, item.path)
		}
	}
	kept := turns.keep_unignored(worktree, paths[:], temp, state.cancel) or_return
	oids := turns.hash_paths(root.store.store, worktree, kept, temp, state.cancel) or_return
	for path, i in kept {
		if !tw_known_set(&root.known, path, oids[i], state.allocator) {return .Out_Of_Memory}
	}
	root.lazy = false
	// What the watch reported while the baseline was taken may have been hashed as it is now, so it is known
	// by its content in the base commit and carried to the turn that begins, as at a root's creation.
	return tw_root_suspect(state, root)
}

@(private = "file")
tw_repository_clone :: proc(
	repository: turns.Repository,
	worktree: string,
	allocator: mem.Allocator,
) -> (
	clone: turns.Repository,
	ok: bool,
) {
	worktree_copy, worktree_ok := tw_dup(worktree, allocator)
	common_copy, common_ok := tw_dup(repository.common_dir, allocator)
	key_copy, key_ok := tw_dup(repository.key, allocator)
	clone = {worktree_copy, common_copy, key_copy}
	if worktree_ok && common_ok && key_ok {return clone, true}
	turns.repository_destroy(&clone, allocator)
	return {}, false
}

@(private = "file")
tw_family_known :: proc(state: ^Tw_State, key: string) -> bool {
	return slice.contains(state.families[:], key)
}

// The open turns that are in a root of the repository, in the temp allocator.
@(private = "file")
tw_family_opens :: proc(state: ^Tw_State, key: string) -> []^Tw_Open {
	opens := make([dynamic]^Tw_Open, context.temp_allocator)
	for root in state.roots {
		if root.repository.key != key {continue}
		for presence in root.presences {
			if !slice.contains(opens[:], presence.open) {append(&opens, presence.open)}
		}
	}
	return opens[:]
}

// Makes the turn open in the root, with nothing drained or saved.
@(private = "file")
tw_presence_new :: proc(state: ^Tw_State, root: ^Tw_Root, open: ^Tw_Open) -> (^Tw_Presence, bool) {
	allocator := state.allocator
	presence, new_error := new(Tw_Presence, allocator)
	if new_error != nil {return nil, false}
	presence.open = open
	presence.named = make(map[string]struct{}, allocator)
	presence.changes = make(map[string]Tw_Net, allocator)
	if _, append_error := append(&root.presences, presence); append_error != nil {
		tw_presence_free(state, presence)
		return nil, false
	}
	return presence, true
}

// Follows a work tree of the repository the family has no root for. One listed when the family was first
// followed has been on its commit since; a new one started where its HEAD log begins, and the files that
// changed there since are left for the next drain, which comes once the sessions' links are known. Every
// open turn of the family enters it first.
@(private = "file")
tw_family_follow :: proc(
	state: ^Tw_State,
	repository: turns.Repository,
	item: turns.Worktree,
	first: bool,
) -> turns.Error {
	temp := context.temp_allocator
	allocator := state.allocator
	base := item.head
	if !first {base = turns.worktree_origin(item.path, temp, state.cancel) or_return}
	cloned, cloned_ok := tw_repository_clone(repository, item.path, allocator)
	if !cloned_ok {return .Out_Of_Memory}
	opens := tw_family_opens(state, repository.key)
	root := tw_root_create_lazy(state, cloned, base, first) or_return
	for open in opens {
		if _, added := tw_presence_new(state, root, open); !added {return .Out_Of_Memory}
		root.fresh = false
	}
	if first {return .None}
	// The watch is already on, so no change falls between it and this look.
	paths, paths_error := turns.changed_since(item.path, base, temp, state.cancel)
	if paths_error != .None {
		root.rescan = true
		return paths_error
	}
	for path in paths {
		copied, copied_ok := tw_dup(path, allocator)
		if !copied_ok {return .Out_Of_Memory}
		if _, append_error := append(&root.seed, copied); append_error != nil {
			delete(copied, allocator)
			return .Out_Of_Memory
		}
	}
	return .None
}

@(private = "file")
tw_listing_find :: proc(state: ^Tw_State, key: string) -> (list: []turns.Worktree, found: bool) {
	for listing in state.listings {
		if listing.key == key {return listing.list, true}
	}
	return nil, false
}

// Where the root's work tree is now, as the job's listing says; false when it has none or lacks the tree.
@(private = "file")
tw_listed_head :: proc(state: ^Tw_State, root: ^Tw_Root) -> (head: turns.Oid, found: bool) {
	list, listed := tw_listing_find(state, root.repository.key)
	if !listed {return "", false}
	for item in list {
		if !item.bare && !item.prunable && strings.equal_fold(item.path, root.repository.worktree) {
			return item.head, true
		}
	}
	return "", false
}

// Points the root's base at the commit its work tree is on. The job's listing says so; only a root the
// listing lacks costs a git run.
@(private = "file")
tw_root_settle :: proc(state: ^Tw_State, root: ^Tw_Root) -> turns.Error {
	head, found := tw_listed_head(state, root)
	if !found {return tw_root_set_base(state, root)}
	base := tw_copy(head, state.allocator) or_return
	delete(root.base, state.allocator)
	root.base = base
	return .None
}

// Lists the work trees of the repository and follows each one that can be: a root per work tree. Only a
// family already followed is listed unless `create`. A job lists a repository once. The list is in the
// temp allocator; a failure to follow one work tree is the error, and the list is still good.
@(private = "file")
tw_family_sync :: proc(
	state: ^Tw_State,
	repository: turns.Repository,
	create: bool,
) -> (
	list: []turns.Worktree,
	err: turns.Error,
) {
	if cached, found := tw_listing_find(state, repository.key); found {return cached, .None}
	listed, list_error := turns.worktrees_list(repository.worktree, context.temp_allocator, state.cancel)
	if list_error != .None {return nil, list_error}
	known := tw_family_known(state, repository.key)
	if !known {
		if !create {return listed, .None}
		key, key_error := tw_copy(repository.key, state.allocator)
		if key_error != .None {return listed, key_error}
		if _, append_error := append(&state.families, key); append_error != nil {
			delete(key, state.allocator)
			return listed, .Out_Of_Memory
		}
	}
	for item in listed {
		if item.bare || item.prunable || tw_root_find(state, item.path) != nil {continue}
		tw_note(&err, tw_family_follow(state, repository, item, !known))
	}
	if key, key_error := strings.clone(repository.key, context.temp_allocator); key_error == nil {
		append(&state.listings, Tw_Listing{key, listed})
	}
	return listed, err
}

// The root of the work tree `directory` is in, created when it is new. `own`: a turn begins in this folder,
// so a root followed without a baseline gets one. A root is returned with an error only when that failed.
@(private = "file")
tw_root_for_directory :: proc(
	state: ^Tw_State,
	directory: string,
	own: bool,
) -> (
	root: ^Tw_Root,
	err: turns.Error,
) {
	repository := turns.repository_find(directory, state.allocator, state.cancel) or_return
	root = tw_root_find(state, repository.worktree)
	if root == nil && tw_family_known(state, repository.key) {
		// A work tree the family has not seen yet is found by listing the family again.
		_, sync_error := tw_family_sync(state, repository, false)
		root = tw_root_find(state, repository.worktree)
		if root == nil && sync_error != .None {
			turns.repository_destroy(&repository, state.allocator)
			return nil, sync_error
		}
	}
	if root == nil {return tw_root_create(state, repository)}
	turns.repository_destroy(&repository, state.allocator)
	if own {err = tw_root_upgrade(state, root)}
	return root, err
}

// The root of the work tree holding `path`, which is absolute with '/' separators, and the path
// relative to it. A known root answers without asking git: a hook waits for the answer.
@(private = "file")
tw_root_for_path :: proc(
	state: ^Tw_State,
	path: string,
) -> (
	root: ^Tw_Root,
	relative: string,
	err: turns.Error,
) {
	longest := 0
	for candidate in state.roots {
		worktree := candidate.repository.worktree
		if inside, ok := tw_path_under(worktree, path); ok && len(worktree) > longest {
			root, relative, longest = candidate, inside, len(worktree)
		}
	}
	if root != nil {return root, relative, .None}
	// A file about to be created has no directory to ask yet: the nearest one that exists does.
	directory := path
	for {
		cut := strings.last_index_byte(directory, '/')
		if cut <= 0 {return nil, "", .Not_Repository}
		directory = directory[:cut]
		if os.is_directory(directory) {break}
	}
	root = tw_root_for_directory(state, directory, false) or_return
	inside, ok := tw_path_under(root.repository.worktree, path)
	if !ok {return nil, "", .Not_Repository}
	return root, inside, .None
}

// Takes in what changed in the work tree since the last drain, and gives each change to the open turn
// that made it, or to Between when none is open. A turn that began later does not see it. The paths
// the watch reported while the root's baseline was taken changed after the root's watch started, so
// after the activity that made the root: they are only taken when `carried`, which a beginning turn
// asks for once it is registered, so they go to it.
@(private = "file")
tw_drain :: proc(state: ^Tw_State, root: ^Tw_Root, carried: bool) -> turns.Error {
	temp := context.temp_allocator
	worktree := root.repository.worktree
	candidates := make([dynamic]string, temp)
	if carried {
		for path in root.carry {
			copied, copy_error := strings.clone(path, temp)
			if copy_error == nil {append(&candidates, copied)}
			delete(path, state.allocator)
		}
		clear(&root.carry)
	}
	for path in root.seed {
		copied, copy_error := strings.clone(path, temp)
		if copy_error == nil {append(&candidates, copied)}
		delete(path, state.allocator)
	}
	clear(&root.seed)
	for path in root.taken {
		copied, copy_error := strings.clone(path, temp)
		if copy_error == nil {append(&candidates, copied)}
		delete(path, state.allocator)
	}
	clear(&root.taken)
	overflowed := root.watch == 0 || root.rescan
	if root.watch != 0 && tw_root_take(state, root, &candidates) {overflowed = true}
	if len(candidates) == 0 && !overflowed && !root.lost {return .None}
	if !os.is_directory(worktree) {
		tw_watch_remove(state, root.watch)
		root.watch, root.lost, root.rescan = 0, true, true
		return .None
	}
	if root.lost {
		// The watch stopped or the directory is back: watch it again, and look at everything.
		tw_watch_remove(state, root.watch)
		root.watch = tw_watch_add(state, worktree)
		root.lost = false
		overflowed = true
	}
	root.rescan = true
	if overflowed {
		// With no turn open the root is settled, so what it was based on may have moved: a checkout, a
		// commit. With one open the base stays, or the turn's own commit would take its change away.
		if len(root.presences) == 0 {tw_root_settle(state, root) or_return}
		states := turns.dirty_paths(worktree, temp, state.cancel) or_return
		dirty := make(map[string]struct{}, len(states), temp)
		for item in states {
			dirty[item.path] = {}
			// A lazy root never saw what a file held before it was followed: only the watch can say who
			// changed one that is older than that.
			if root.followed_at != 0 && root.lazy && item.path not_in root.known {
				if !tw_written_since(worktree, item, root.followed_at) {continue}
			}
			append(&candidates, item.path)
		}
		for path in root.known {
			if path not_in dirty {append(&candidates, path)}
		}
	}
	paths := tw_drain_paths(state, root, candidates[:])
	if !carried && len(root.carry) > 0 {
		// A turn about to begin takes those, so they are neither Between's nor this drain's.
		held := make(map[string]struct{}, len(root.carry), temp)
		for path in root.carry {held[path] = {}}
		unheld := make([dynamic]string, 0, len(paths), temp)
		for path in paths {
			if path not_in held {append(&unheld, path)}
		}
		paths = unheld[:]
	}
	if len(paths) == 0 {
		root.rescan = false
		return .None
	}
	kept := turns.keep_unignored(worktree, paths, temp, state.cancel) or_return
	unknown := make([dynamic]string, 0, len(kept), temp)
	for path in kept {
		if path not_in root.known {append(&unknown, path)}
	}
	// What a file had before it first changed here is what the base commit holds. The index says that
	// only until something stages or commits it, which a turn may well do.
	tree := tw_tree_oids(worktree, root.base, unknown[:], temp, state.cancel) or_return
	tree_of := make(map[string]turns.Oid, len(unknown), temp)
	for path, i in unknown {tree_of[path] = tree[i]}
	after := turns.hash_paths(root.store.store, worktree, kept, temp, state.cancel) or_return
	// Looked at once hashed: a write after the look shows up in the next drain, and one between the hash
	// and the look makes the file late, so the content hashed is never newer than the time judged.
	looked := tw_now_ms()
	changed := false
	for path, i in kept {
		if state.drain_until != 0 && tw_written_between(worktree, path, state.drain_until, looked) {
			if !tw_seed_add(state, root, path) {return .Out_Of_Memory}
			continue
		}
		before, seen := root.known[path]
		if !seen {before = tree_of[path]}
		if !tw_known_set(&root.known, path, after[i], state.allocator) {return .Out_Of_Memory}
		if before == after[i] {continue}
		if !tw_attribute(state, root, path, before, after[i]) {return .Out_Of_Memory}
		changed = true
	}
	// The watch tick may not have seen these: a hook's edit, or a read, drained them first. Another pane
	// on the repository still needs telling; the reading pane's next read finds nothing new.
	if changed && len(root.presences) > 0 {
		tw_live_mark(root)
		root.live_sure = true
	}
	root.rescan = false
	return .None
}

// The candidates without repeats, git's own files, names that cannot be stored, directories, and what lies in
// another work tree of the family: the OS reports a directory as changed whenever an entry in it is, a
// work tree nested in this one is watched by its own root, and a file is reported by every watch over it.
@(private = "file")
tw_drain_paths :: proc(state: ^Tw_State, root: ^Tw_Root, candidates: []string) -> []string {
	temp := context.temp_allocator
	worktree := root.repository.worktree
	inner := make([dynamic]string, temp)
	for other in state.roots {
		if other == root || other.repository.key != root.repository.key {continue}
		if _, inside := tw_path_under(worktree, other.repository.worktree); inside {
			append(&inner, other.repository.worktree)
		}
	}
	seen := make(map[string]struct{}, len(candidates), temp)
	paths := make([dynamic]string, 0, len(candidates), temp)
	for path in candidates {
		if path == "" || path in seen || tw_git_internal(path) || !tw_text_valid(path) {continue}
		seen[path] = {}
		full := strings.join({worktree, path}, "/", temp)
		nested := false
		for tree in inner {
			if _, under := tw_path_under(tree, full); under || strings.equal_fold(tree, full) {nested = true}
		}
		if nested {continue}
		info, stat_error := os.stat(full, temp)
		if stat_error == nil && info.type == .Directory {continue}
		append(&paths, path)
	}
	return paths[:]
}

// Gives one change to whoever made it, in this order: the open turns a hook named the path for; the open
// turns whose sessions work in this work tree (several: each, shared, since the change may be another's);
// the only open turn of the repository, or every one of them, shared; else Between.
@(private = "file")
tw_attribute :: proc(state: ^Tw_State, root: ^Tw_Root, path: string, before, after: turns.Oid) -> bool {
	allocator := state.allocator
	state.stamp += 1
	stamp := state.stamp
	named := 0
	for presence in root.presences {
		if path in presence.named {named += 1}
	}
	if named > 0 {
		for presence in root.presences {
			if path not_in presence.named {continue}
			tw_net_merge(&presence.changes, path, before, after, named > 1, stamp, allocator) or_return
		}
		return true
	}
	worktree := root.repository.worktree
	linked := 0
	for presence in root.presences {
		if tw_linked(state, presence.open, worktree) {linked += 1}
	}
	if linked > 0 {
		for presence in root.presences {
			if !tw_linked(state, presence.open, worktree) {continue}
			tw_net_merge(&presence.changes, path, before, after, linked > 1, stamp, allocator) or_return
		}
		return true
	}
	if len(root.presences) == 0 {
		// A turn that is beginning started before its job could run: what was written since is its, not
		// Between's. It takes the changes once it is in the root.
		claim := state.claim_since * i64(time.Millisecond)
		if state.claim_since != 0 && tw_written_after(worktree, path, claim) {
			return tw_net_merge(&root.claimed, path, before, after, false, stamp, allocator)
		}
		return tw_net_merge(&root.pending, path, before, after, false, stamp, allocator)
	}
	shared := len(root.presences) > 1
	for presence in root.presences {
		tw_net_merge(&presence.changes, path, before, after, shared, stamp, allocator) or_return
	}
	return true
}

// Saves the changes no turn claimed as a Between segment. They happened since the root was last
// settled, which is when the segment starts.
@(private = "file")
tw_between_save :: proc(state: ^Tw_State, root: ^Tw_Root, now: i64, saved: ^[dynamic]string) -> turns.Error {
	if len(root.pending) == 0 {return .None}
	changes := make([dynamic]turns.Change, 0, len(root.pending), context.temp_allocator)
	for path, net in root.pending {
		if net.before == net.after {continue}
		append(
			&changes,
			turns.Change {
				worktree = root.repository.worktree,
				path = path,
				before = net.before,
				after = net.after,
				shared = net.shared,
			},
		)
	}
	ended := max(now, root.since)
	if len(changes) > 0 {
		tw_changes_sort(changes[:])
		segment := turns.Segment {
			id      = tw_next_id(state, {root.store}),
			kind    = .Between,
			started = root.since,
			ended   = ended,
			changes = changes[:],
		}
		tw_segment_save(state, root.store, &segment) or_return
		append(saved, root.store.key)
	}
	tw_net_clear(&root.pending, state.allocator)
	root.since = ended
	return .None
}

@(private = "file")
tw_open_find :: proc(state: ^Tw_State, pane_key: string) -> ^Tw_Open {
	for open in state.opens {
		if open.pane_key == pane_key {return open}
	}
	return nil
}

@(private = "file")
tw_open_free :: proc(state: ^Tw_State, open: ^Tw_Open) {
	allocator := state.allocator
	delete(open.pane_key, allocator)
	tw_session_free(&open.session, allocator)
	delete(open.transcript, allocator)
	delete(open.title, allocator)
	for measure in open.measures {delete(measure.key, allocator)}
	delete(open.measures)
	free(open, allocator)
}

// The agent's transcript, once it is known.
@(private = "file")
tw_open_transcript :: proc(state: ^Tw_State, open: ^Tw_Open, path: string) {
	if path == "" || path == open.transcript {return}
	copied, copied_ok := tw_dup(path, state.allocator)
	if !copied_ok {
		log.error("remembering a transcript failed: out of memory")
		return
	}
	delete(open.transcript, state.allocator)
	open.transcript = copied
}

// Registers a turn, or refreshes the session and transcript of one that is already open.
@(private = "file")
tw_open_set :: proc(
	state: ^Tw_State,
	pane_key: string,
	session: turns.Session,
	transcript: string,
) -> ^Tw_Open {
	allocator := state.allocator
	copied, copied_ok := tw_session_dup(session, allocator)
	if !copied_ok {return nil}
	if open := tw_open_find(state, pane_key); open != nil {
		tw_session_free(&open.session, allocator)
		open.session = copied
		tw_open_transcript(state, open, transcript)
		return open
	}
	open, new_error := new(Tw_Open, allocator)
	if new_error != nil {
		tw_session_free(&copied, allocator)
		return nil
	}
	key, key_ok := tw_dup(pane_key, allocator)
	if !key_ok {
		tw_session_free(&copied, allocator)
		free(open, allocator)
		return nil
	}
	open.pane_key = key
	open.session = copied
	open.measures.allocator = allocator
	if _, append_error := append(&state.opens, open); append_error != nil {
		tw_open_free(state, open)
		return nil
	}
	tw_open_transcript(state, open, transcript)
	return open
}

// The session id names an agent session for as long as it lives; before it is known the pane does.
@(private = "file")
tw_session_key :: proc(session: turns.Session) -> string {
	return session.session if session.session != "" else session.pane_key
}

@(private = "file")
tw_linked :: proc(state: ^Tw_State, open: ^Tw_Open, worktree: string) -> bool {
	key := tw_session_key(open.session)
	if key == "" {key = open.pane_key}
	for link in state.links {
		if link.key == key && strings.equal_fold(link.worktree, worktree) {return true}
	}
	return false
}

// Notes that the turn's session works in the work tree. Links last until recording stops.
@(private = "file")
tw_link :: proc(state: ^Tw_State, open: ^Tw_Open, worktree: string) -> bool {
	key := tw_session_key(open.session)
	if key == "" {key = open.pane_key}
	state.stamp += 1
	for &link in state.links {
		if link.key == key && strings.equal_fold(link.worktree, worktree) {
			link.stamp = state.stamp
			return true
		}
	}
	allocator := state.allocator
	key_copy, key_ok := tw_dup(key, allocator)
	worktree_copy, worktree_ok := tw_dup(worktree, allocator)
	if key_ok && worktree_ok {
		link := Tw_Link{key_copy, worktree_copy, state.stamp}
		if _, append_error := append(&state.links, link); append_error == nil {
			return true
		}
	}
	delete(key_copy, allocator)
	delete(worktree_copy, allocator)
	return false
}

@(private = "file")
tw_open_in_roots :: proc(state: ^Tw_State, open: ^Tw_Open) -> bool {
	for root in state.roots {
		if tw_presence_find(root, open) != nil {return true}
	}
	return false
}

// The most of a transcript read in one go, and how far from its end a first read starts.
@(private = "file")
TW_TRANSCRIPT_CHUNK :: 8 * mem.Megabyte

// Appends the places the transcript names since the last read, cut at the last whole line.
@(private = "file")
tw_transcript_places :: proc(state: ^Tw_State, open: ^Tw_Open, places: ^[dynamic]string) {
	file, open_error := os.open(open.transcript)
	if open_error != nil {return}
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil {return}
	at := -1
	for transcript, i in state.transcripts {
		if transcript.path == open.transcript {at = i}
	}
	if at < 0 {
		path, path_ok := tw_dup(open.transcript, state.allocator)
		if !path_ok {return}
		if _, append_error := append(&state.transcripts, Tw_Transcript{path = path}); append_error != nil {
			delete(path, state.allocator)
			return
		}
		at = len(state.transcripts) - 1
	}
	position := &state.transcripts[at]
	if !position.scanned {
		position.scanned = true
		position.offset = max(i64(0), size - TW_TRANSCRIPT_CHUNK)
	}
	if size < position.offset {position.offset = 0}
	if size == position.offset {return}
	count := int(min(size - position.offset, TW_TRANSCRIPT_CHUNK))
	buffer, make_error := make([]u8, count, state.allocator)
	if make_error != nil {return}
	defer delete(buffer, state.allocator)
	read, read_error := os.read_at(file, buffer, position.offset)
	if read_error != nil && read <= 0 {return}
	chunk := buffer[:max(read, 0)]
	end := strings.last_index_byte(string(chunk), '\n')
	if end < 0 {
		// A line still being written waits for its end; one longer than any read is given up.
		if len(chunk) == TW_TRANSCRIPT_CHUNK {position.offset += i64(len(chunk))}
		return
	}
	position.offset += i64(end + 1)
	agent.claude_transcript_places(chunk[:end + 1], places, context.temp_allocator)
}

// Reads what every open turn's transcript has added, and links each session to the work tree (of the
// repositories its turn is in) that holds each place it names: the innermost, as work trees nest.
@(private = "file")
tw_links_read :: proc(state: ^Tw_State) {
	for open in state.opens {
		if open.transcript == "" || !tw_open_in_roots(state, open) {continue}
		places := make([dynamic]string, context.temp_allocator)
		tw_transcript_places(state, open, &places)
		for place in places {
			inside := strings.trim_right(place, "/")
			target: ^Tw_Root
			for root in state.roots {
				worktree := root.repository.worktree
				if tw_presence_find(root, open) == nil {continue}
				_, under := tw_path_under(worktree, inside)
				if !under && !strings.equal_fold(worktree, inside) {continue}
				if target == nil || len(worktree) > len(target.repository.worktree) {target = root}
			}
			if target != nil && !tw_link(state, open, target.repository.worktree) {
				log.error("linking a session to a work tree failed: out of memory")
			}
		}
	}
}

// Makes the turn open in the root. Changes made before that belong to whoever else is open there, or
// to Between, so they are taken in and saved first. The turn is registered even when that fails, so
// its end still finds the root; the error is the first that happened.
@(private = "file")
tw_root_enter :: proc(
	state: ^Tw_State,
	root: ^Tw_Root,
	open: ^Tw_Open,
	now: i64,
	saved: ^[dynamic]string,
) -> (
	presence: ^Tw_Presence,
	err: turns.Error,
) {
	if existing := tw_presence_find(root, open); existing != nil {return existing, .None}
	if drain_error := tw_drain(state, root, false); err == .None {err = drain_error}
	if between_error := tw_between_save(state, root, now, saved); err == .None {err = between_error}
	// Only now may the base move to what the work tree is on: a file the owner edited and committed
	// between turns had its Between change measured from the old base.
	if root.fresh {
		root.fresh = false
	} else if len(root.presences) == 0 {
		if base_error := tw_root_settle(state, root); err == .None {err = base_error}
	}
	fresh, added := tw_presence_new(state, root, open)
	if !added {return nil, .Out_Of_Memory}
	allocator := state.allocator
	for path, net in root.claimed {
		if !tw_net_merge(&fresh.changes, path, net.before, net.after, net.shared, net.stamp, allocator) {
			err = .Out_Of_Memory
		} else if merged, found := &fresh.changes[path]; found {
			merged.taken = net.taken
		}
	}
	tw_net_clear(&root.claimed, allocator)
	// What the watch saw while the root's baseline was taken happened after the root's watch began, so
	// it is this turn's, not Between's.
	if len(root.carry) > 0 {
		if carry_error := tw_drain(state, root, true); err == .None {err = carry_error}
	}
	return fresh, err
}

// Makes the turn open in every work tree of the root's repository: any of them may be where the agent
// goes, and the turn must be there to be given what changes.
@(private = "file")
tw_attach_family :: proc(
	state: ^Tw_State,
	open: ^Tw_Open,
	root: ^Tw_Root,
	now: i64,
	saved: ^[dynamic]string,
	failure: ^turns.Error,
) {
	_, sync_error := tw_family_sync(state, root.repository, true)
	tw_note(failure, sync_error)
	for candidate in state.roots {
		if candidate.repository.key != root.repository.key {continue}
		_, enter_error := tw_root_enter(state, candidate, open, now, saved)
		tw_note(failure, enter_error)
	}
}

// The turn's agent was started in this folder, so it works in this work tree.
@(private = "file")
tw_attach_directory :: proc(
	state: ^Tw_State,
	open: ^Tw_Open,
	directory: string,
	now: i64,
	saved: ^[dynamic]string,
	failure: ^turns.Error,
) {
	root, find_error := tw_root_for_directory(state, directory, true)
	tw_note(failure, find_error)
	if root == nil {return}
	tw_attach_family(state, open, root, now, saved, failure)
	if !tw_link(state, open, root.repository.worktree) {tw_note(failure, .Out_Of_Memory)}
}

// Makes the turn open in the repository of a file a hook named, notes the file as the turn's, and links
// the turn's session to the file's work tree.
@(private = "file")
tw_attach_path :: proc(
	state: ^Tw_State,
	open: ^Tw_Open,
	directory, path: string,
	now: i64,
	saved: ^[dynamic]string,
	failure: ^turns.Error,
) {
	absolute, absolute_ok := tw_absolute(directory, path)
	if !absolute_ok {
		tw_note(failure, .Out_Of_Memory)
		return
	}
	root, relative, find_error := tw_root_for_path(state, absolute)
	if find_error != .None {
		tw_note(failure, find_error)
		return
	}
	tw_attach_family(state, open, root, now, saved, failure)
	// A work tree nested in another may only have been found just now.
	if inner, inside, inner_error := tw_root_for_path(state, absolute); inner_error == .None {
		root, relative = inner, inside
	}
	presence := tw_presence_find(root, open)
	if presence != nil && !tw_presence_name(presence, relative, state.allocator) {
		tw_note(failure, .Out_Of_Memory)
	}
	if !tw_link(state, open, root.repository.worktree) {tw_note(failure, .Out_Of_Memory)}
}

// Keeps the newest title a turn has been given; an empty one says nothing new.
@(private = "file")
tw_open_title :: proc(state: ^Tw_State, open: ^Tw_Open, title: string) -> bool {
	if title == "" || title == open.title {return false}
	copied, copied_ok := tw_dup(title, state.allocator)
	if !copied_ok {
		log.error("remembering a turn's title failed: out of memory")
		return false
	}
	delete(open.title, state.allocator)
	open.title = copied
	return true
}

// The repositories the open turn is in, each once, in the temp allocator.
@(private = "file")
tw_open_keys :: proc(state: ^Tw_State, open: ^Tw_Open) -> []string {
	keys := make([dynamic]string, context.temp_allocator)
	for root in state.roots {
		if tw_presence_find(root, open) == nil || slice.contains(keys[:], root.repository.key) {continue}
		append(&keys, root.repository.key)
	}
	return keys[:]
}

@(private = "file")
tw_begin :: proc(state: ^Tw_State, job: Job_Begin) {
	defer tw_ack(job.ack)
	open := tw_open_set(state, job.pane_key, job.session, job.transcript)
	if open == nil {
		tw_failed(state, .Out_Of_Memory, "begin")
		return
	}
	saved := make([dynamic]string, context.temp_allocator)
	failure: turns.Error
	state.claim_since = job.started
	// What changed before the turn began must be taken in before it does, or it would count as its.
	_ = turns.watch_set_sync(state.watches, TW_WATCH_SYNC)
	tw_links_read(state)
	if job.directory != "" {
		tw_attach_directory(state, open, job.directory, job.started, &saved, &failure)
	}
	for path in job.paths {
		tw_attach_path(state, open, job.directory, path, job.started, &saved, &failure)
	}
	tw_links_read(state)
	tw_claims_release(state)
	// A Begin of a turn already open, as a later status report sends, keeps its id and start.
	if open.id == 0 {
		stores := make([dynamic]^Tw_Store, context.temp_allocator)
		for root in state.roots {
			if tw_presence_find(root, open) != nil && !slice.contains(stores[:], root.store) {
				append(&stores, root.store)
			}
		}
		open.id = tw_next_id(state, stores[:])
		open.started = job.started
	}
	_ = tw_open_title(state, open, job.title)
	tw_saved_post(state, saved[:])
	tw_live_post(state, tw_open_keys(state, open))
	tw_failed(state, failure, "begin")
}

@(private = "file")
tw_watch_root :: proc(state: ^Tw_State, job: Job_Watch_Root) {
	failure: turns.Error
	root, find_error := tw_root_for_directory(state, job.directory, true)
	tw_note(&failure, find_error)
	if root != nil {
		_, sync_error := tw_family_sync(state, root.repository, true)
		tw_note(&failure, sync_error)
	}
	tw_failed(state, failure, "watch")
}

// Lists the work trees of every repository the turn is in, so one made since is followed before the turn's
// files are looked at. One root per repository stands for it: a root whose directory is gone cannot be
// listed from.
@(private = "file")
tw_open_sync :: proc(state: ^Tw_State, open: ^Tw_Open, failure: ^turns.Error) {
	families := make([dynamic]^Tw_Root, context.temp_allocator)
	for root in state.roots {
		if tw_presence_find(root, open) == nil {continue}
		listed := false
		for &known in families {
			if known.repository.key != root.repository.key {continue}
			listed = true
			if !os.is_directory(known.repository.worktree) {known = root}
		}
		if !listed {append(&families, root)}
	}
	for root in families {
		_, sync_error := tw_family_sync(state, root.repository, true)
		tw_note(failure, sync_error)
	}
}

@(private = "file")
tw_edit :: proc(state: ^Tw_State, job: Job_Edit) {
	defer tw_ack(job.ack)
	open := tw_open_find(state, job.pane_key)
	if open == nil {return}
	saved := make([dynamic]string, context.temp_allocator)
	failure: turns.Error
	now := tw_now_ms()
	tw_open_sync(state, open, &failure)
	tw_links_read(state)
	for path in job.paths {
		tw_attach_path(state, open, "", path, now, &saved, &failure)
	}
	if tw_open_title(state, open, job.title) {tw_live_post(state, tw_open_keys(state, open))}
	tw_saved_post(state, saved[:])
	tw_failed(state, failure, "edit")
}

// A change with when it was taken in, so a segment can end with the latest.
@(private = "file")
Tw_Stamped :: struct {
	change: turns.Change,
	stamp:  u64,
}

@(private = "file")
tw_stamped_before :: proc(a, b: Tw_Stamped) -> bool {
	if a.stamp != b.stamp {return a.stamp < b.stamp}
	if a.change.worktree != b.change.worktree {return a.change.worktree < b.change.worktree}
	return a.change.path < b.change.path
}

@(private = "file")
tw_end :: proc(state: ^Tw_State, job: Job_End) {
	open := tw_open_find(state, job.pane_key)
	if open == nil {return}
	if job.settle_until != {} {
		left := time.tick_diff(time.tick_now(), job.settle_until)
		if left > 0 {time.sleep(min(left, TURN_SETTLE))}
	}
	temp := context.temp_allocator
	failure: turns.Error
	// A work tree made during the turn is found now, so what was changed in it is in the turn.
	tw_open_sync(state, open, &failure)
	tw_links_read(state)
	// A busy machine may not have run the watch thread since the turn's last writes; their reports must
	// be in before the drains, or the turn looks empty and its changes go to whatever comes next.
	_ = turns.watch_set_sync(state.watches, TW_WATCH_SYNC)
	involved := make([dynamic]^Tw_Root, temp)
	stores := make([dynamic]^Tw_Store, temp)
	state.drain_until = job.ended
	for root in state.roots {
		if tw_presence_find(root, open) == nil {continue}
		append(&involved, root)
		if !slice.contains(stores[:], root.store) {append(&stores, root.store)}
		tw_note(&failure, tw_drain(state, root, true))
	}
	state.drain_until = 0
	// A drain after the turn ended may have given it a file written since: a Begin of the next turn that
	// ran late, or a read. That change goes back, so the next drain gives it whole to whoever made it. A
	// change taken in before the turn ended keeps its content, whatever was written over it since. An End
	// without a time (0) keeps everything.
	for root in involved {
		if job.ended == 0 {break}
		presence := tw_presence_find(root, open)
		late := make([dynamic]string, temp)
		for path, net in presence.changes {
			if net.taken <= job.ended {continue}
			worktree := root.repository.worktree
			if tw_written_between(worktree, path, job.ended, tw_now_ms()) {append(&late, path)}
		}
		for path in late {
			key, net := delete_key(&presence.changes, path)
			restored := tw_known_set(&root.known, key, net.before, state.allocator)
			if !restored || !tw_seed_add(state, root, key) {tw_note(&failure, .Out_Of_Memory)}
			delete(key, state.allocator)
			delete(net.before, state.allocator)
			delete(net.after, state.allocator)
		}
	}
	session := job.session
	if session.pane_key == "" {session.pane_key = job.pane_key}
	if session.harness == "" {session.harness = open.session.harness}
	if session.session == "" {session.session = open.session.session}
	// A turn that touched two repositories is saved once in each, under the id it took when it began.
	id := open.id
	if id == 0 || tw_id_taken(stores[:], id) {id = tw_next_id(state, stores[:])}
	saved := make([dynamic]string, temp)
	for store in stores {
		stamped := make([dynamic]Tw_Stamped, temp)
		for root in involved {
			if root.store != store {continue}
			presence := tw_presence_find(root, open)
			for path, net in presence.changes {
				if net.before == net.after {continue}
				append(
					&stamped,
					Tw_Stamped {
						change = {
							worktree = root.repository.worktree,
							path = path,
							before = net.before,
							after = net.after,
							shared = net.shared,
						},
						stamp = net.stamp,
					},
				)
			}
		}
		if len(stamped) == 0 {continue}
		// The latest change comes last: it is where the agent was working when the turn ended.
		slice.sort_by(stamped[:], tw_stamped_before)
		changes := make([]turns.Change, len(stamped), temp)
		for item, i in stamped {changes[i] = item.change}
		segment := turns.Segment {
			id        = id,
			kind      = .Turn,
			session   = session,
			started   = job.started,
			ended     = job.ended,
			end_state = job.end_state,
			title     = job.title,
			sources   = job.sources,
			changes   = changes,
		}
		save_error := tw_segment_save(state, store, &segment)
		tw_note(&failure, save_error)
		if save_error == .None {append(&saved, store.key)}
	}
	for root in involved {
		presence := tw_presence_find(root, open)
		if at, found := slice.linear_search(root.presences[:], presence); found {
			unordered_remove(&root.presences, at)
		}
		tw_presence_free(state, presence)
		root.since = job.ended
	}
	if at, found := slice.linear_search(state.opens[:], open); found {unordered_remove(&state.opens, at)}
	tw_open_free(state, open)
	tw_saved_post(state, saved[:])
	tw_failed(state, failure, "end")
}

// Whether a turn of `have` is the agent `want`: by session id when both know one, else by pane.
@(private = "file")
tw_session_matches :: proc(want, have: turns.Session) -> bool {
	if want.session != "" && have.session != "" {return have.session == want.session}
	return want.pane_key != "" && have.pane_key == want.pane_key
}

// Whether a turn is listed, and counts for its agent: it changed at least one file. A change that left a
// file as it was (before and after the same) is not recorded, so no changes means no net change. This is
// the one place the rule lives; the turn list, the strip, the range label and the agents all read what it
// lets through.
@(private = "file")
tw_listed :: proc(segment: turns.Segment) -> bool {
	return len(segment.changes) > 0
}

@(private = "file")
tw_query_matches :: proc(job: Job_Query, segment: turns.Segment) -> bool {
	if !tw_listed(segment) {return false}
	if !job.agent {return true}
	return segment.kind == .Turn && tw_session_matches(job.session, segment.session)
}

// Newest first: by when a segment ended, then began, then by id.
@(private = "file")
tw_segment_newer :: proc(a, b: int, user: rawptr) -> bool {
	store := (^Tw_Store)(user)
	x, y := &store.segments[a], &store.segments[b]
	if x.ended != y.ended {return x.ended > y.ended}
	if x.started != y.started {return x.started > y.started}
	return x.id > y.id
}

@(private = "file")
tw_query :: proc(state: ^Tw_State, job: Job_Query) {
	result := Result_Query {
		pane    = job.pane,
		request = job.request,
	}
	memory := tw_memory_make(state.allocator)
	if memory == nil {
		result.error = .Out_Of_Memory
	} else {
		result.memory = memory
		result.error = tw_query_fill(state, job, &result, vmem.arena_allocator(&memory.arena))
	}
	tw_post(state, result)
}

@(private = "file")
tw_query_fill :: proc(
	state: ^Tw_State,
	job: Job_Query,
	result: ^Result_Query,
	arena: mem.Allocator,
) -> turns.Error {
	temp := context.temp_allocator
	repository := turns.repository_find(job.directory, temp, state.cancel) or_return
	result.repository = tw_copy(repository.key, arena) or_return
	result.worktree = tw_copy(repository.worktree, arena) or_return
	tw_drain_open(state, repository.key)
	store := tw_store_existing(state, repository.key)
	if store == nil {return .None}
	tw_store_load(state, store)
	now := tw_now_ms()
	lives := tw_lives(state, repository.key, now)
	agents := tw_agents(store, lives, now, arena) or_return
	result.agents = agents

	order := make([dynamic]int, 0, len(store.segments), temp)
	for segment, i in store.segments {
		if tw_query_matches(job, segment) {append(&order, i)}
	}
	slice.sort_by_with_data(order[:], tw_segment_newer, store)
	shown := make([dynamic]int, 0, len(lives), temp)
	for live, i in lives {
		if !tw_listed(live.segment) {continue}
		if !job.agent || tw_session_matches(job.session, live.segment.session) {append(&shown, i)}
	}
	rows, rows_error := make([]Turn_Row, len(shown) + len(order), arena)
	if rows_error != nil {return .Out_Of_Memory}
	// Open turns come first: nothing saved is newer.
	for index, i in shown {
		live := &lives[index]
		title := tw_copy(live.segment.title, arena) or_return
		added, removed := tw_live_measure(state, store, live^)
		rows[i] = {
			id      = live.segment.id,
			kind    = .Turn,
			live    = true,
			agent   = tw_agent_index(agents, live.segment.session),
			started = live.segment.started,
			title   = title,
			files   = len(live.segment.changes),
			added   = added,
			removed = removed,
		}
	}
	for index, i in order {
		segment := &store.segments[index]
		title := tw_copy(segment.title, arena) or_return
		rows[len(shown) + i] = {
			id        = segment.id,
			kind      = segment.kind,
			agent     = tw_agent_index(agents, segment.session) if segment.kind == .Turn else -1,
			started   = segment.started,
			ended     = segment.ended,
			end_state = segment.end_state,
			title     = title,
			files     = len(segment.changes),
			added     = segment.added,
			removed   = segment.removed,
		}
	}
	result.rows = rows

	// What the pane selected, if the rows still hold it, else the newest turn, an open one if any.
	chosen := make([dynamic]u64, 0, max(len(job.selected), 1), temp)
	for row in rows {
		if slice.contains(job.selected, row.id) {append(&chosen, row.id)}
	}
	if len(chosen) == 0 && len(rows) > 0 {append(&chosen, rows[0].id)}
	selected, selected_error := slice.clone(chosen[:], arena)
	if selected_error != nil {return .Out_Of_Memory}
	result.selected = selected
	if len(chosen) == 0 {return .None}

	// Each open turn is an unsaved segment ending now: selected it is shown, and otherwise it marks
	// what it changed during a selected run.
	segments := make([]turns.Segment, len(store.segments) + len(lives), temp)
	copy(segments, store.segments[:])
	for live, i in lives {segments[len(store.segments) + i] = live.segment}
	composed, compose_error := turns.compose(segments, chosen[:], temp)
	if compose_error != nil {return .Out_Of_Memory}
	if len(composed) == 0 {return .None}
	sides := make([]Tw_Side, len(composed), temp)
	for item, i in composed {
		sides[i] = {item.worktree, item.path, item.before, item.after}
	}
	entries, labelled := tw_entries(sides, temp)
	if !labelled {return .Out_Of_Memory}
	result.patch = turns.diff_entries(store.store, entries, arena, state.cancel) or_return
	diff, parsed := turns.diff_parse(result.patch, arena)
	if !parsed {return .Failed}
	turns.diff_refine(&diff)
	result.diff = diff
	// A file is marked when the entry of either of its paths is, which a rename pairs up.
	marks := make(map[string]bool, len(entries), temp)
	uncertain := make(map[string]bool, len(entries), temp)
	for entry, i in entries {
		marks[entry.path] = composed[i].marked
		uncertain[entry.path] = composed[i].ambiguous
	}
	marked, marked_error := make([]bool, len(diff.files), arena)
	ambiguous, ambiguous_error := make([]bool, len(diff.files), arena)
	if marked_error != nil || ambiguous_error != nil {return .Out_Of_Memory}
	for file, i in diff.files {
		marked[i] = marks[file.new_path] || marks[file.old_path]
		ambiguous[i] = uncertain[file.new_path] || uncertain[file.old_path]
	}
	result.marked = marked
	result.ambiguous = ambiguous
	result.highlights = tw_highlights(state, diff, {store = &store.store}, arena)
	return .None
}

// Takes in what the open turns of the repository have changed, so their rows are up to date.
@(private = "file")
tw_drain_open :: proc(state: ^Tw_State, key: string) {
	if len(state.opens) == 0 {return}
	tw_links_read(state)
	for root in state.roots {
		if root.repository.key != key || len(root.presences) == 0 {continue}
		if drain_error := tw_drain(state, root, false); drain_error != .None {
			log.warnf("turn recording: looking at %q failed: %v", root.repository.worktree, drain_error)
		}
	}
}

// An open turn of a repository as the unsaved Turn segment it would be if it ended now. The segment
// borrows from the turn; its changes are in the temp allocator.
@(private = "file")
Tw_Live :: struct {
	open:    ^Tw_Open,
	segment: turns.Segment,
	// The newest stamp of its changes in the repository, 0 when it has none.
	stamp:   u64,
}

// The open turns of the repository, newest first, in the temp allocator.
@(private = "file")
tw_lives :: proc(state: ^Tw_State, key: string, now: i64) -> []Tw_Live {
	temp := context.temp_allocator
	opens := tw_family_opens(state, key)
	lives := make([]Tw_Live, len(opens), temp)
	for open, i in opens {
		changes := make([dynamic]turns.Change, temp)
		stamp: u64
		for root in state.roots {
			if root.repository.key != key {continue}
			presence := tw_presence_find(root, open)
			if presence == nil {continue}
			for path, net in presence.changes {
				stamp = max(stamp, net.stamp)
				if net.before == net.after {continue}
				change := turns.Change {
					worktree = root.repository.worktree,
					path     = path,
					before   = net.before,
					after    = net.after,
					shared   = net.shared,
				}
				append(&changes, change)
			}
		}
		tw_changes_sort(changes[:])
		session := open.session
		if session.pane_key == "" {session.pane_key = open.pane_key}
		lives[i] = {
			open = open,
			stamp = stamp,
			segment = {
				id = open.id,
				kind = .Turn,
				session = session,
				started = open.started,
				ended = max(now, open.started),
				title = open.title,
				changes = changes[:],
			},
		}
	}
	slice.sort_by(lives, proc(a, b: Tw_Live) -> bool {
		if a.segment.started != b.segment.started {return a.segment.started > b.segment.started}
		return a.segment.id > b.segment.id
	})
	return lives
}

// The lines the open turn has added and removed in the store's repository, counted again only once its
// changes there have changed.
@(private = "file")
tw_live_measure :: proc(state: ^Tw_State, store: ^Tw_Store, live: Tw_Live) -> (added, removed: int) {
	open := live.open
	for &measure in open.measures {
		if measure.key != store.key {continue}
		if measure.stamp != live.stamp {
			measure.added, measure.removed = tw_measure(state, store, live.segment.changes)
			measure.stamp = live.stamp
		}
		return measure.added, measure.removed
	}
	added, removed = tw_measure(state, store, live.segment.changes)
	key, key_ok := tw_dup(store.key, state.allocator)
	if !key_ok {return}
	measure := Tw_Measure{key, live.stamp, added, removed}
	if _, append_error := append(&open.measures, measure); append_error != nil {
		delete(key, state.allocator)
	}
	return
}

// Adds a turn to its agent's tally, or makes a new agent of it. `found` and `titled` (when the agent's
// title was given) run in parallel.
@(private = "file")
tw_agent_note :: proc(
	found: ^[dynamic]Turn_Agent,
	titled: ^[dynamic]i64,
	session: turns.Session,
	live: bool,
	latest: i64,
	title: string,
) {
	key := tw_session_key(session)
	for &agent, i in found {
		if tw_session_key(agent.session) != key {continue}
		agent.turns += 1
		agent.live = agent.live || live
		if latest > agent.latest {
			agent.latest = latest
			agent.session = session
		}
		if title != "" && latest >= titled[i] {
			agent.title = title
			titled[i] = latest
		}
		return
	}
	append(found, Turn_Agent{session = session, turns = 1, live = live, latest = latest, title = title})
	append(titled, latest if title != "" else min(i64))
}

// Every agent with a saved turn in the store or an open one among `lives`, newest first, in `arena`.
@(private = "file")
tw_agents :: proc(
	store: ^Tw_Store,
	lives: []Tw_Live,
	now: i64,
	arena: mem.Allocator,
) -> (
	agents: []Turn_Agent,
	err: turns.Error,
) {
	temp := context.temp_allocator
	found := make([dynamic]Turn_Agent, temp)
	titled := make([dynamic]i64, temp)
	if store != nil {
		for segment in store.segments {
			if segment.kind != .Turn || !tw_listed(segment) {continue}
			tw_agent_note(&found, &titled, segment.session, false, segment.ended, segment.title)
		}
	}
	for live in lives {
		if !tw_listed(live.segment) {continue}
		tw_agent_note(&found, &titled, live.segment.session, true, now, live.segment.title)
	}
	slice.sort_by(found[:], proc(a, b: Turn_Agent) -> bool {
		if a.latest != b.latest {return a.latest > b.latest}
		return tw_session_key(a.session) < tw_session_key(b.session)
	})
	make_error: mem.Allocator_Error
	agents, make_error = make([]Turn_Agent, len(found), arena)
	if make_error != nil {return nil, .Out_Of_Memory}
	for agent, i in found {
		session, session_ok := tw_session_dup(agent.session, arena)
		if !session_ok {return nil, .Out_Of_Memory}
		title := tw_copy(agent.title, arena) or_return
		agents[i] = agent
		agents[i].session = session
		agents[i].title = title
	}
	return agents, .None
}

// The index of the agent a turn of `session` belongs to, -1 when none.
@(private = "file")
tw_agent_index :: proc(agents: []Turn_Agent, session: turns.Session) -> int {
	key := tw_session_key(session)
	for agent, i in agents {
		if tw_session_key(agent.session) == key {return i}
	}
	return -1
}

// Where tw_highlights reads the two sides of a diff's files: the store's blobs, else the blobs of the
// repository at `worktree`, whose files on disk are the after side when `disk`.
@(private = "file")
Tw_Source :: struct {
	store:    ^turns.Store,
	worktree: string,
	disk:     bool,
}

// A file of a diff to highlight, and which of its sides its lines show.
@(private = "file")
Tw_Lexed :: struct {
	file:     int,
	language: syntax.Language,
	before:   bool,
	after:    bool,
}

// The syntax spans of every diff line, per file and parallel to diff.files: a file's lines run through its
// hunks in order, a Context or Added line has the spans of its line in the after file, a Removed line those
// of its line in the before file, a No_Newline line none. A file is nil when its language is unknown, it is
// binary, a side it shows is over syntax.HIGHLIGHT_LIMIT or cannot be read or lexed, or the files before it
// used up TW_HIGHLIGHT_BUDGET. Every side read counts against the budget, and a side over what is left is
// not read at all, so no diff costs more than the budget. Whole files are read and lexed in scratch memory;
// only the spans the diff lines use are copied into `arena`. Highlighting is only a help, so a failure
// leaves files plain.
@(private = "file")
tw_highlights :: proc(
	state: ^Tw_State,
	diff: turns.Diff,
	source: Tw_Source,
	arena: mem.Allocator,
) -> []syntax.File_Lines {
	temp := context.temp_allocator
	wanted := make([dynamic]Tw_Lexed, 0, len(diff.files), temp)
	for file, i in diff.files {
		if file.binary {continue}
		item := Tw_Lexed {
			file     = i,
			language = syntax.language_for_path(file.new_path),
		}
		if item.language == .None {continue}
		for hunk in file.hunks {
			for line in hunk.lines {
				switch line.kind {
				case .Context, .Added:
					item.after = true
				case .Removed:
					item.before = true
				case .No_Newline:
				}
			}
		}
		if item.before || item.after {append(&wanted, item)}
	}
	if len(wanted) == 0 {return nil}
	highlights, make_error := make([]syntax.File_Lines, len(diff.files), arena)
	if make_error != nil {return nil}
	scratch: vmem.Arena
	if vmem.arena_init_growing(&scratch) != nil {return highlights}
	defer vmem.arena_destroy(&scratch)
	scratch_allocator := vmem.arena_allocator(&scratch)
	budget := TW_HIGHLIGHT_BUDGET
	oids := make([dynamic]turns.Oid, 0, TW_HIGHLIGHT_GROUP, temp)
	for start := 0; start < len(wanted) && budget > 0; {
		// Each side of the group is at most `limit`, and the group's sides together at most the budget.
		limit := min(syntax.HIGHLIGHT_LIMIT, budget)
		sides := clamp(budget / limit, 1, TW_HIGHLIGHT_GROUP)
		clear(&oids)
		end, counted := start, 0
		for end < len(wanted) {
			item := wanted[end]
			count := (1 if item.before else 0) + (1 if item.after else 0)
			if counted > 0 && counted + count > sides {break}
			file := diff.files[item.file]
			if item.before {append(&oids, file.old_oid)}
			if item.after && !source.disk {append(&oids, file.new_oid)}
			counted += count
			end += 1
		}
		contents: []string
		read_error: turns.Error
		if source.store != nil {
			store := source.store^
			contents, read_error = turns.blobs_read(store, oids[:], scratch_allocator, state.cancel, limit)
		} else {
			contents, read_error = turns.repository_blobs_read(
				source.worktree,
				oids[:],
				scratch_allocator,
				state.cancel,
				limit,
			)
		}
		if read_error != .None {
			log.warnf("turn recording: reading the files to highlight failed: %v", read_error)
			return highlights
		}
		at := 0
		for item in wanted[start:end] {
			file := diff.files[item.file]
			before, after: string
			if item.before {
				before = contents[at]
				at += 1
			}
			if item.after && source.disk {
				after = tw_disk_read(source.worktree, file.new_path, limit, scratch_allocator)
			} else if item.after {
				after = contents[at]
				at += 1
			}
			budget -= len(before) + len(after)
			// A side the diff shows has a line, so it is not empty: "" is a blob over the limit or one that
			// could not be read.
			if (item.before && before == "") || (item.after && after == "") {continue}
			highlights[item.file] = tw_highlight_file(item, file, before, after, scratch_allocator, arena)
		}
		vmem.arena_free_all(&scratch)
		start = end
	}
	return highlights
}

// A work tree's file as it is on disk; "" when it is not a file of at most `limit` bytes that can be read.
@(private = "file")
tw_disk_read :: proc(worktree, path: string, limit: int, allocator: mem.Allocator) -> string {
	full, join_error := strings.join({worktree, path}, "/", context.temp_allocator)
	if join_error != nil {return ""}
	info, stat_error := os.stat(full, context.temp_allocator)
	if stat_error != nil || info.type != .Regular || info.size > i64(limit) {return ""}
	data, read_error := os.read_entire_file(full, allocator)
	if read_error != nil {return ""}
	return string(data)
}

// One file's spans per diff line, copied into `arena`; its sides are lexed in `scratch`.
@(private = "file")
tw_highlight_file :: proc(
	item: Tw_Lexed,
	file: turns.Diff_File,
	before, after: string,
	scratch, arena: mem.Allocator,
) -> syntax.File_Lines {
	old_lines, new_lines: syntax.File_Lines
	lexed: bool
	if item.before {
		old_lines, lexed = syntax.highlight(item.language, before, scratch)
		if !lexed {return {}}
	}
	if item.after {
		new_lines, lexed = syntax.highlight(item.language, after, scratch)
		if !lexed {return {}}
	}
	count, spans := 0, 0
	for hunk in file.hunks {
		for line in hunk.lines {
			count += 1
			spans += len(tw_line_spans(line, old_lines, new_lines))
		}
	}
	lines, lines_error := make([][]syntax.Span, count, arena)
	if lines_error != nil {return {}}
	slab, slab_error := make([]syntax.Span, spans, arena)
	if slab_error != nil {return {}}
	at, used := 0, 0
	for hunk in file.hunks {
		for line in hunk.lines {
			found := tw_line_spans(line, old_lines, new_lines)
			lines[at] = slab[used:used + len(found)]
			copy(lines[at], found)
			used += len(found)
			at += 1
		}
	}
	return {lines = lines}
}

@(private = "file")
tw_line_spans :: proc(line: turns.Diff_Line, old_lines, new_lines: syntax.File_Lines) -> []syntax.Span {
	switch line.kind {
	case .Context, .Added:
		return tw_spans_at(new_lines, line.new_line)
	case .Removed:
		return tw_spans_at(old_lines, line.old_line)
	case .No_Newline:
	}
	return nil
}

@(private = "file")
tw_spans_at :: proc(file: syntax.File_Lines, number: i32) -> []syntax.Span {
	if number < 1 || int(number) > len(file.lines) {return nil}
	return file.lines[number - 1]
}

@(private = "file")
tw_plain :: proc(state: ^Tw_State, job: Job_Plain) {
	result := Result_Plain {
		pane    = job.pane,
		request = job.request,
	}
	memory := tw_memory_make(state.allocator)
	if memory == nil {
		result.error = .Out_Of_Memory
	} else {
		result.memory = memory
		result.error = tw_plain_fill(state, job, &result, vmem.arena_allocator(&memory.arena))
	}
	tw_post(state, result)
}

@(private = "file")
tw_tree_index :: proc(trees: []string, worktree: string) -> int {
	for tree, i in trees {
		if strings.equal_fold(tree, worktree) {return i}
	}
	return -1
}

@(private = "file")
tw_open_for_session :: proc(state: ^Tw_State, session: turns.Session) -> ^Tw_Open {
	for open in state.opens {
		if session.pane_key != "" && open.pane_key == session.pane_key {return open}
		if session.session != "" && open.session.session == session.session {return open}
	}
	return nil
}

// The work tree of the latest change the open turn has taken in.
@(private = "file")
tw_open_latest :: proc(state: ^Tw_State, open: ^Tw_Open) -> (worktree: string, found: bool) {
	latest: u64
	for root in state.roots {
		presence := tw_presence_find(root, open)
		if presence == nil {continue}
		for _, net in presence.changes {
			if net.before != net.after && net.stamp > latest {
				latest = net.stamp
				worktree, found = root.repository.worktree, true
			}
		}
	}
	return
}

// The work tree the agent of `session` last changed: in the turn it has open, else in its newest saved
// turn of the repository, else the one it was last seen working in, else `fallback`. Only `trees` qualify.
@(private = "file")
tw_follow :: proc(
	state: ^Tw_State,
	repository: turns.Repository,
	session: turns.Session,
	trees: []string,
	fallback: string,
) -> string {
	if open := tw_open_for_session(state, session); open != nil {
		if worktree, found := tw_open_latest(state, open); found {
			if at := tw_tree_index(trees, worktree); at >= 0 {return trees[at]}
		}
	}
	if store := tw_store_existing(state, repository.key); store != nil {
		tw_store_load(state, store)
		matching := Job_Query {
			agent   = true,
			session = session,
		}
		order := make([dynamic]int, 0, len(store.segments), context.temp_allocator)
		for segment, i in store.segments {
			if len(segment.changes) > 0 && tw_query_matches(matching, segment) {append(&order, i)}
		}
		slice.sort_by_with_data(order[:], tw_segment_newer, store)
		for index in order {
			changes := store.segments[index].changes
			if at := tw_tree_index(trees, changes[len(changes) - 1].worktree); at >= 0 {return trees[at]}
		}
	}
	if key := tw_session_key(session); key != "" {
		newest: u64
		found := ""
		for link in state.links {
			at := tw_tree_index(trees, link.worktree)
			if link.key == key && at >= 0 && link.stamp > newest {
				newest = link.stamp
				found = trees[at]
			}
		}
		if found != "" {return found}
	}
	return fallback
}

@(private = "file")
tw_plain_fill :: proc(
	state: ^Tw_State,
	job: Job_Plain,
	result: ^Result_Plain,
	arena: mem.Allocator,
) -> turns.Error {
	temp := context.temp_allocator
	repository := turns.repository_find(job.directory, temp, state.cancel) or_return
	// A listing that fails leaves the request's own work tree to show.
	list, list_error := tw_family_sync(state, repository, false)
	if list_error != .None {log.warnf("turn recording: listing the work trees failed: %v", list_error)}
	trees := make([dynamic]string, temp)
	for item in list {
		if !item.bare && !item.prunable {append(&trees, item.path)}
	}
	own := tw_tree_index(trees[:], repository.worktree)
	if own < 0 {
		append(&trees, repository.worktree)
		own = len(trees) - 1
	}
	// What the agent's open turn changed since the last boundary decides where to follow it.
	if open := tw_open_for_session(state, job.session); open != nil {
		tw_links_read(state)
		for root in state.roots {
			if tw_presence_find(root, open) == nil {continue}
			if drain_error := tw_drain(state, root, false); drain_error != .None {
				log.warnf("turn recording: looking at %q failed: %v", root.repository.worktree, drain_error)
			}
		}
	}
	followed := tw_follow(state, repository, job.session, trees[:], trees[own])
	shown := followed
	result.following = true
	if job.worktree != "" {
		if at := tw_tree_index(trees[:], job.worktree); at >= 0 {
			shown = trees[at]
			result.following = false
		}
	}
	ordered := make([dynamic]string, 0, len(trees), temp)
	append(&ordered, followed)
	if !strings.equal_fold(trees[own], followed) {append(&ordered, trees[own])}
	rest := make([dynamic]string, temp)
	for tree in trees {
		if !slice.contains(ordered[:], tree) {append(&rest, tree)}
	}
	slice.sort(rest[:])
	append(&ordered, ..rest[:])
	worktrees, worktrees_error := make([]string, len(ordered), arena)
	if worktrees_error != nil {return .Out_Of_Memory}
	for tree, i in ordered {worktrees[i] = tw_copy(tree, arena) or_return}
	result.worktrees = worktrees
	result.worktree = tw_copy(shown, arena) or_return
	store := tw_store_existing(state, repository.key)
	if store != nil {tw_store_load(state, store)}
	now := tw_now_ms()
	result.agents = tw_agents(store, tw_lives(state, repository.key, now), now, arena) or_return
	patch, omitted, patch_error := turns.diff_plain(shown, job.mode, arena, state.cancel)
	if patch_error != .None {return patch_error}
	result.patch = patch
	result.omitted = omitted
	diff, parsed := turns.diff_parse(patch, arena)
	if !parsed {return .Failed}
	turns.diff_refine(&diff)
	result.diff = diff
	// The index and HEAD sides are blobs of the user's repository; a work tree side is the file on disk.
	source := Tw_Source {
		worktree = shown,
		disk     = job.mode != .Staged,
	}
	result.highlights = tw_highlights(state, diff, source, arena)
	return .None
}

@(private = "file")
tw_view_free :: proc(state: ^Tw_State, view: ^Tw_View) {
	tw_watch_remove(state, view.watch)
	delete(view.worktree, state.allocator)
	delete(view.panes)
	free(view, state.allocator)
}

// Takes the pane out of the view it is in; a view nobody is in any more is stopped.
@(private = "file")
tw_view_leave :: proc(state: ^Tw_State, pane: u32) {
	for i := len(state.views) - 1; i >= 0; i -= 1 {
		view := state.views[i]
		if at, found := slice.linear_search(view.panes[:], pane); found {unordered_remove(&view.panes, at)}
		if len(view.panes) > 0 {continue}
		tw_view_free(state, view)
		unordered_remove(&state.views, i)
	}
}

@(private = "file")
tw_view_watch :: proc(state: ^Tw_State, job: Job_View_Watch) {
	allocator := state.allocator
	repository, find_error := turns.repository_find(job.directory, context.temp_allocator, state.cancel)
	if find_error != .None {
		// The pane shows why through its own query; there is nothing to watch.
		tw_view_leave(state, job.pane)
		return
	}
	for view in state.views {
		if !strings.equal_fold(view.worktree, repository.worktree) {continue}
		if slice.contains(view.panes[:], job.pane) {return}
		tw_view_leave(state, job.pane)
		if _, append_error := append(&view.panes, job.pane); append_error != nil {
			log.error("watching a work tree failed: out of memory")
		}
		return
	}
	tw_view_leave(state, job.pane)
	watch := tw_watch_add(state, repository.worktree)
	if watch == 0 {return}
	view, new_error := new(Tw_View, allocator)
	worktree, worktree_ok := tw_dup(repository.worktree, allocator)
	if new_error != nil || !worktree_ok {
		log.error("watching a work tree failed: out of memory")
		tw_watch_remove(state, watch)
		if new_error == nil {free(view, allocator)}
		if worktree_ok {delete(worktree, allocator)}
		return
	}
	view.worktree = worktree
	view.watch = watch
	view.panes.allocator = allocator
	_, pane_error := append(&view.panes, job.pane)
	_, view_error := append(&state.views, view)
	if pane_error != nil || view_error != nil {
		log.error("watching a work tree failed: out of memory")
		tw_view_free(state, view)
		if view_error == nil {pop(&state.views)}
	}
}

// Tells the panes of a work tree that changed and has been quiet for a while to look again. Only
// changes git would show count: not git's own files, and not what .gitignore rules out.
@(private = "file")
tw_views_tick :: proc(state: ^Tw_State) {
	if len(state.views) == 0 {return}
	now := time.tick_now()
	temp := context.temp_allocator
	ready := make([dynamic]turns.Watch_Id, temp)
	turns.watch_set_ready(state.watches, &ready)
	paths := make([dynamic]string, temp)
	for view in state.views {
		changed := false
		relevant := make([dynamic]string, temp)
		if view.watch == 0 {
			// A watch that stopped is set again once its directory is back.
			if os.is_directory(view.worktree) {
				view.watch = tw_watch_add(state, view.worktree)
				changed = view.watch != 0
			}
		} else if slice.contains(ready[:], view.watch) {
			clear(&paths)
			overflowed, dead := turns.watch_set_take(state.watches, view.watch, &paths, temp)
			changed = overflowed || dead
			if dead {
				tw_watch_remove(state, view.watch)
				view.watch = 0
			}
			for path in paths {
				if !tw_git_internal(path) {append(&relevant, path)}
			}
		}
		if !changed && len(relevant) > 0 {
			// One git run for the whole batch. When it cannot tell, the change counts.
			unignored, ignore_error := turns.keep_unignored(view.worktree, relevant[:], temp, state.cancel)
			changed = ignore_error != .None || len(unignored) > 0
		}
		if changed {
			view.waiting = true
			view.changed = now
		}
		if !view.waiting || time.tick_diff(view.changed, now) < TW_VIEW_QUIET {continue}
		view.waiting = false
		for pane in view.panes {tw_post(state, Result_Dirty{pane = pane})}
	}
}

// Notes that a work tree with an open turn changed, for tw_live_tick.
@(private = "file")
tw_live_mark :: proc(root: ^Tw_Root) {
	now := time.tick_now()
	if !root.live_waiting {
		root.live_waiting = true
		root.live_first = now
	}
	root.live_last = now
}

// Tells the panes of a repository that an open turn's work tree changed: once it has been quiet for
// TW_LIVE_QUIET, and every TW_LIVE_EVERY while it keeps changing. Runs only while a pane reads turns.
// The paths are taken from the watch to tell, so they are kept for the next drain, which hashes them.
// Only changes git would show count, which one git run per root and post decides for the paths not
// seen before.
@(private = "file")
tw_live_tick :: proc(state: ^Tw_State) {
	if !tw_live_on(state) {return}
	temp := context.temp_allocator
	now := time.tick_now()
	ready := make([dynamic]turns.Watch_Id, temp)
	turns.watch_set_ready(state.watches, &ready)
	paths := make([dynamic]string, temp)
	due := make([dynamic]string, temp)
	for root in state.roots {
		if len(root.presences) == 0 {
			root.live_waiting, root.live_sure = false, false
			continue
		}
		if root.watch != 0 && slice.contains(ready[:], root.watch) {
			clear(&paths)
			if tw_root_take(state, root, &paths) {
				root.rescan, root.live_sure = true, true
				tw_live_mark(root)
			}
			for path in paths {
				if tw_git_internal(path) {continue}
				known, found := root.taken[path]
				if found && known == .Ignored {continue}
				if found && known == .Shown {root.live_sure = true}
				tw_live_mark(root)
				if !found && !tw_taken_add(state, root, path) {root.rescan, root.live_sure = true, true}
			}
		}
		if !root.live_waiting {continue}
		quiet := time.tick_diff(root.live_last, now) >= TW_LIVE_QUIET
		if !quiet && time.tick_diff(root.live_first, now) < TW_LIVE_EVERY {continue}
		root.live_waiting = false
		if !root.live_sure && !tw_taken_check(state, root) {continue}
		root.live_sure = false
		append(&due, root.repository.key)
	}
	tw_live_post(state, due[:])
}

// Keeps a path taken from the root's watch for the next drain. False when it was not kept: past the
// watch's own limit the taken paths are dropped, and the drain rescans instead.
@(private = "file")
tw_taken_add :: proc(state: ^Tw_State, root: ^Tw_Root, path: string) -> bool {
	if len(root.taken) >= turns.WATCH_PENDING_LIMIT {
		for held in root.taken {delete(held, state.allocator)}
		clear(&root.taken)
		return false
	}
	key := tw_dup(path, state.allocator) or_return
	if _, _, _, insert_error := map_entry(&root.taken, key); insert_error != nil {
		delete(key, state.allocator)
		return false
	}
	return true
}

// Asks git about the taken paths not asked about yet; true when one of them is a change git would show,
// or git cannot tell.
@(private = "file")
tw_taken_check :: proc(state: ^Tw_State, root: ^Tw_Root) -> bool {
	temp := context.temp_allocator
	unchecked := make([dynamic]string, temp)
	for path, known in root.taken {
		if known == .Unchecked {append(&unchecked, path)}
	}
	if len(unchecked) == 0 {return false}
	shown, ignore_error := turns.keep_unignored(root.repository.worktree, unchecked[:], temp, state.cancel)
	if ignore_error != .None {return true}
	for path in unchecked {root.taken[path] = .Ignored}
	for path in shown {root.taken[path] = .Shown}
	return len(shown) > 0
}

// Drops the expired segments of every store and repacks it, which deletes the objects no ref reaches.
// What a root still holds is kept under a ref for the repack. A store with no segment file left and no
// root using it is removed whole; one a root uses stays, since the root's baseline lives in it.
@(private = "file")
tw_maintain :: proc(state: ^Tw_State, job: Job_Maintain) {
	failure: turns.Error
	allocator := state.allocator
	entries, read_error := os.read_all_directory_by_path(state.directory, allocator)
	if read_error != nil {
		if read_error != .Not_Exist {
			log.warnf("could not list %q: %v", state.directory, read_error)
			tw_failed(state, .Failed, "maintain")
		}
		return
	}
	defer os.file_info_slice_delete(entries, allocator)
	for entry in entries {
		if entry.type != .Directory {continue}
		// The inbox and anything else that is no store has no bare repository in it.
		marker := strings.join({entry.fullpath, TW_STORE}, "/", context.temp_allocator)
		if !os.is_directory(marker) {continue}
		store := tw_store_existing(state, entry.name)
		if store == nil {continue}
		tw_note(&failure, tw_maintain_store(state, store, job))
		free_all(context.temp_allocator)
	}
	tw_failed(state, failure, "maintain")
}

@(private = "file")
tw_maintain_store :: proc(state: ^Tw_State, store: ^Tw_Store, job: Job_Maintain) -> turns.Error {
	tw_store_load(state, store)
	// A store whose segments could not be listed is not known to be empty.
	if !store.loaded {return .None}
	ids := turns.expired(store.segments[:], job.now, job.days, context.temp_allocator)
	if len(ids) > 0 {
		turns.segment_drop(store.store, ids, state.cancel) or_return
		tw_segments_delete(state, store, ids)
	}
	if tw_store_live(state, store) {return tw_maintain_pinned(state, store)}
	if len(store.segments) == 0 {
		// Files that did not decode are still files: only a directory with none is empty.
		files, counted := tw_segment_file_count(state, store)
		if !counted || files > 0 {return .None}
		directory := strings.clone(store.store.directory, context.temp_allocator)
		tw_store_remove(state, store)
		return turns.store_delete_all(directory)
	}
	return turns.store_maintain(store.store, state.cancel)
}

// How many segment files a store holds; false when its directory could not be listed.
@(private = "file")
tw_segment_file_count :: proc(state: ^Tw_State, store: ^Tw_Store) -> (count: int, ok: bool) {
	files, read_error := os.read_all_directory_by_path(
		tw_segment_path(store, "", context.temp_allocator),
		state.allocator,
	)
	if read_error != nil {return 0, read_error == .Not_Exist}
	defer os.file_info_slice_delete(files, state.allocator)
	for file in files {
		if strings.has_suffix(file.name, turns.SEGMENT_EXTENSION) {count += 1}
	}
	return count, true
}

// The reserved id the blobs of live roots are kept under while a store is repacked.
@(private = "file")
TW_PIN :: u64(0)

// Repacks a store a root still records into. The blobs the roots hold, the files they have seen and
// the changes no segment has taken yet, are reachable from no ref, and a prune would delete them, so
// they are kept under a ref of their own for the length of the repack.
@(private = "file")
tw_maintain_pinned :: proc(state: ^Tw_State, store: ^Tw_Store) -> turns.Error {
	oids := make([dynamic]turns.Oid, context.temp_allocator)
	for root in state.roots {
		if root.store != store {continue}
		for _, oid in root.known {append(&oids, oid)}
		for _, net in root.pending {append(&oids, net.before, net.after)}
		for presence in root.presences {
			for _, net in presence.changes {append(&oids, net.before, net.after)}
		}
	}
	if len(oids) == 0 {return turns.store_maintain(store.store, state.cancel)}
	pin := [?]u64{TW_PIN}
	turns.segment_keep(store.store, TW_PIN, oids[:], state.cancel) or_return
	err := turns.store_maintain(store.store, state.cancel)
	if drop_error := turns.segment_drop(store.store, pin[:], state.cancel); err == .None {err = drop_error}
	return err
}

// Deletes the files of the segments, whose refs are already dropped, and forgets them.
@(private = "file")
tw_segments_delete :: proc(state: ^Tw_State, store: ^Tw_Store, ids: []u64) {
	for id in ids {
		name := turns.segment_file_name(id, context.temp_allocator)
		path := tw_segment_path(store, name, context.temp_allocator)
		if remove_error := os.remove(path); remove_error != nil && remove_error != .Not_Exist {
			log.warnf("could not delete %q: %v", path, remove_error)
		}
	}
	for i := len(store.segments) - 1; i >= 0; i -= 1 {
		if !slice.contains(ids, store.segments[i].id) {continue}
		turns.segment_destroy(&store.segments[i], state.allocator)
		unordered_remove(&store.segments, i)
	}
}

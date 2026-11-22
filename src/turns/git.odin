package turns

import "aio:spawn"
import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"
import "core:time"
import "cosmos:host"

// What went wrong running git or reading a repository.
Error :: enum u8 {
	None,
	Git_Missing,
	Not_Repository,
	Failed,
	Out_Of_Memory,
}

// A git that runs longer than this is stuck on a lock, a prompt or an unreachable drive.
GIT_TIMEOUT :: 2 * time.Minute

// How often a waiting run looks at its cancel flag.
@(private)
GIT_CANCEL_POLL :: 50 * time.Millisecond

// Repacking a store that holds many turns takes longer than reading a status.
GIT_LONG_TIMEOUT :: 10 * time.Minute

// Only the head of stderr is kept, for the log.
@(private)
GIT_STDERR_LIMIT :: 4096

Git_Run :: struct {
	cwd:       string,
	// Put in front of the arguments as --git-dir and --work-tree when set.
	git_dir:   string,
	work_tree: string,
	// NAME=value edits applied after the ones every run gets; NAME= removes the variable.
	env:       []string,
	stdin:     string,
	// Zero means GIT_TIMEOUT.
	timeout:   time.Duration,
	// Set by another thread to stop the run: git is killed and git_run returns Failed. nil never cancels.
	cancel:    ^Git_Cancel,
}

// Raised with sync.atomic_store(&cancel.flag, true) from any thread to abort the git runs that hold it,
// so shutdown need not wait out a long run. It stays raised; a new job uses a new one.
Git_Cancel :: struct {
	flag: bool,
}

// What a git run printed. stdout is the bytes git wrote, with no newline translation, so -z output
// and patches arrive untouched.
Git_Output :: struct {
	stdout: []u8,
	stderr: string,
	code:   int,
}

// Runs git with `args` and blocks until it exits. A non-zero exit is the caller's to judge; the error
// is for git not starting, a run that never ends, or memory. Only for the recorder's worker thread:
// the calling thread's temp allocator grows with every run, so the caller frees it between jobs.
// spawn's reader threads allocate from context.allocator, which must therefore allow threads;
// `allocator` only holds what comes back.
@(require_results)
git_run :: proc(args: []string, run: Git_Run, allocator := context.allocator) -> (Git_Output, Error) {
	if git_cancelled(run.cancel) {return {}, .Failed}
	argv, argv_error := make([dynamic]string, 0, len(args) + 5, allocator)
	if argv_error != nil {return {}, .Out_Of_Memory}
	defer delete(argv)
	append(&argv, "git")
	if run.git_dir != "" {append(&argv, "--git-dir", run.git_dir)}
	if run.work_tree != "" {append(&argv, "--work-tree", run.work_tree)}
	append(&argv, ..args)
	// A hook or script that started the app may leave these set, and git would then work on someone
	// else's repository or index. Optional locks stay off so reading never writes the user's index.
	common := [?]string {
		"GIT_OPTIONAL_LOCKS=0",
		"GIT_DIR=",
		"GIT_WORK_TREE=",
		"GIT_INDEX_FILE=",
		"GIT_COMMON_DIR=",
		"GIT_OBJECT_DIRECTORY=",
		"GIT_ALTERNATE_OBJECT_DIRECTORIES=",
		"GIT_PREFIX=",
		"GIT_NAMESPACE=",
	}
	edits, edits_error := make([dynamic]string, 0, len(common) + len(run.env), allocator)
	if edits_error != nil {return {}, .Out_Of_Memory}
	defer delete(edits)
	append(&edits, ..common[:])
	append(&edits, ..run.env)

	wake: sync.Sema
	options := spawn.Options {
		cwd       = run.cwd,
		env       = edits[:],
		stdin     = run.stdin,
		keep_crlf = true,
	}
	wake_target := host.Waker{procedure = git_wake, data = &wake}
	process, start_error := spawn.start(argv[:], options, wake_target, context.allocator)
	switch start_error {
	case .None:
	case .Not_Found, .Not_Executable:
		return {}, .Git_Missing
	case .Out_Of_Memory:
		return {}, .Out_Of_Memory
	case .Start_Failed, .Closed:
		log.errorf("git did not start in %q: %v", run.cwd, start_error)
		return {}, .Failed
	}
	// Destroy joins the threads that call git_wake, so it must run before `wake` goes away.
	defer spawn.destroy(process)

	stdout, stdout_error := make([dynamic]u8, 0, 4096, allocator)
	if stdout_error != nil {return {}, .Out_Of_Memory}
	stderr: [GIT_STDERR_LIMIT]u8
	stderr_length := 0
	timeout := run.timeout if run.timeout > 0 else GIT_TIMEOUT
	started := time.tick_now()
	code := 0
	for {
		polled := spawn.poll(process)
		if _, append_error := append(&stdout, ..polled.stdout); append_error != nil {
			delete(stdout)
			return {}, .Out_Of_Memory
		}
		stderr_length += copy(stderr[stderr_length:], polled.stderr)
		if polled.exited {
			code = polled.code
			break
		}
		if git_cancelled(run.cancel) {
			spawn.kill(process)
			delete(stdout)
			return {}, .Failed
		}
		remaining := timeout - time.tick_since(started)
		if remaining <= 0 {
			log.errorf("git %v did not finish in %v", args, timeout)
			spawn.kill(process)
			delete(stdout)
			return {}, .Failed
		}
		// A cancel raises no wake, so the wait is short enough to see it soon.
		_ = sync.sema_wait_with_timeout(&wake, min(remaining, GIT_CANCEL_POLL))
	}
	message, clone_error := strings.clone(string(stderr[:stderr_length]), allocator)
	if clone_error != nil {
		delete(stdout)
		return {}, .Out_Of_Memory
	}
	return {stdout = stdout[:], stderr = message, code = code}, .None
}

git_output_destroy :: proc(o: ^Git_Output, allocator := context.allocator) {
	delete(o.stdout, allocator)
	delete(o.stderr, allocator)
	o^ = {}
}

@(private = "file")
git_wake :: proc "contextless" (data: rawptr) {
	sync.sema_post((^sync.Sema)(data))
}

// Logs a git run that exited non-zero where success was expected.
@(private)
git_failure :: proc(args: []string, output: Git_Output) -> Error {
	log.warnf("git %v exited with %d: %s", args, output.code, strings.trim_space(output.stderr))
	return .Failed
}

@(private)
git_cancelled :: proc(cancel: ^Git_Cancel) -> bool {
	return cancel != nil && sync.atomic_load(&cancel.flag)
}

// Runs git where only a zero exit is success and nothing is read back.
@(private, require_results)
git_check :: proc(args: []string, run: Git_Run, allocator := context.allocator) -> Error {
	output := git_run(args, run, allocator) or_return
	defer git_output_destroy(&output, allocator)
	if output.code != 0 {return git_failure(args, output)}
	return .None
}

@(private, require_results)
git_make :: proc($T: typeid, count: int, allocator: runtime.Allocator) -> ([]T, Error) {
	items, make_error := make([]T, count, allocator)
	if make_error != nil {return nil, .Out_Of_Memory}
	return items, .None
}

@(private, require_results)
git_clone :: proc(text: string, allocator: runtime.Allocator) -> (string, Error) {
	cloned, clone_error := strings.clone(text, allocator)
	if clone_error != nil {return "", .Out_Of_Memory}
	return cloned, .None
}

// Appends every part, false when memory ran out.
@(private, require_results)
git_text_add :: proc(buffer: ^[dynamic]u8, parts: ..string) -> bool {
	for part in parts {
		if _, append_error := append(buffer, part); append_error != nil {return false}
	}
	return true
}

// Paths go to git and into files with '/' separators, which Windows and git both accept.
@(private)
git_slashes :: proc(path: string) {
	bytes := transmute([]u8)path
	for &b in bytes {
		if b == '\\' {b = '/'}
	}
}

@(private, require_results)
git_join_path :: proc(allocator: runtime.Allocator, parts: ..string) -> (string, Error) {
	joined, join_error := strings.join(parts, "/", allocator)
	if join_error != nil {return "", .Out_Of_Memory}
	git_slashes(joined)
	return joined, .None
}

// The next NUL-terminated record of `text`, which moves past it.
@(private)
git_take_record :: proc(text: ^string) -> string {
	end := strings.index_byte(text^, 0)
	if end < 0 {
		record := text^
		text^ = ""
		return record
	}
	record := text^[:end]
	text^ = text^[end + 1:]
	return record
}

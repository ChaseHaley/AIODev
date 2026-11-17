// Recording what coding agents change, one turn at a time (WORK-487). A turn runs from an agent
// starting work to it finishing, as its program status (OSC 7501) or its hooks report. Only the files
// that changed are recorded: each change keeps the file's git blob before and after, in a private
// object store per repository, so a diff over any run of turns is one net change per file.
package turns

// A git object id in lowercase hex. Empty means the file did not exist on that side.
Oid :: string

// Who made a turn. The pane key is always known; the harness session id only once a hook or the
// session discovery of WORK-361 has named it.
Session :: struct {
	pane_key: string,
	harness:  string,
	session:  string,
}

// One file's net change within a segment. The path is relative to the worktree, with '/' separators.
Change :: struct {
	worktree: string,
	path:     string,
	before:   Oid,
	after:    Oid,
	// Made while another session also had a turn open in the same worktree, and no hook said whose
	// tool wrote it.
	shared:   bool,
}

Segment_Kind :: enum u8 {
	// What one session changed during one of its turns.
	Turn,
	// What changed in a worktree while no turn there was open: the owner's edits, formatters, builds.
	Between,
}

// How a turn ended.
End_State :: enum u8 {
	Unknown,
	Done,
	Idle,
	Error,
	// The program cleared its status or the pane's program ended mid-turn.
	Ended,
}

Signal_Source :: enum u8 {
	Status,
	Hooks,
}

// A recorded run of changes in one repository. A turn that touched two repositories is saved once in
// each, under the same id. Times are Unix milliseconds.
Segment :: struct {
	id:        u64,
	kind:      Segment_Kind,
	session:   Session,
	started:   i64,
	ended:     i64,
	end_state: End_State,
	// The prompt a hook reported, else the status report's title or message; may be empty.
	title:     string,
	sources:   bit_set[Signal_Source],
	// Lines added and removed over all changes, counted once when the segment is saved.
	added:     int,
	removed:   int,
	changes:   []Change,
}

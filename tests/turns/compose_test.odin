package turns_test

import "aio:turns"
import "core:mem"
import "core:testing"

@(private)
compose :: proc(segments: []turns.Segment, ids: ..u64) -> ([]turns.Composed, mem.Allocator_Error) {
	return turns.compose(segments, ids)
}

@(private)
turn :: proc(id: u64, started, ended: i64, changes: []turns.Change) -> turns.Segment {
	return {id = id, kind = .Turn, started = started, ended = ended, changes = changes}
}

@(private)
between :: proc(id: u64, started, ended: i64, changes: []turns.Change) -> turns.Segment {
	return {id = id, kind = .Between, started = started, ended = ended, changes = changes}
}

@(private)
find_composed :: proc(files: []turns.Composed, path: string) -> (turns.Composed, bool) {
	for f in files {
		if f.path == path {return f, true}
	}
	return {}, false
}

@(test)
one_segment_composes_to_its_own_changes :: proc(t: ^testing.T) {
	changes := [?]turns.Change{{"/r", "a.txt", "", "a1", false}, {"/r", "b.txt", "b0", "b1", false}}
	segments := [?]turns.Segment{turn(1, 0, 10, changes[:])}
	files, err := compose(segments[:], 1)
	defer delete(files)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	testing.expect_value(t, len(files), 2)
	testing.expect_value(t, files[0], turns.Composed{"/r", "a.txt", "", "a1", false})
	testing.expect_value(t, files[1], turns.Composed{"/r", "b.txt", "b0", "b1", false})
}

@(test)
a_path_changed_twice_nets_from_the_first_before_to_the_last_after :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "f", "f0", "f1", false}, {"/r", "g", "g0", "g1", false}}
	c2 := [?]turns.Change{{"/r", "f", "f1", "f2", false}}
	c3 := [?]turns.Change{{"/r", "f", "f2", "f3", false}}
	segments := [?]turns.Segment{turn(1, 0, 10, c1[:]), turn(2, 10, 20, c2[:]), turn(3, 20, 30, c3[:])}
	// Any order of ids, and the segments themselves in any order.
	shuffled := [?]turns.Segment{segments[2], segments[0], segments[1]}
	files, err := compose(shuffled[:], 3, 1, 2)
	defer delete(files)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	testing.expect_value(t, len(files), 2)
	f, found := find_composed(files, "f")
	testing.expect(t, found)
	testing.expect_value(t, f.before, "f0")
	testing.expect_value(t, f.after, "f3")
	testing.expect(t, !f.marked)
	g, _ := find_composed(files, "g")
	testing.expect_value(t, g.before, "g0")
	testing.expect_value(t, g.after, "g1")
}

@(test)
a_file_added_then_deleted_is_dropped :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "tmp", "", "t1", false}, {"/r", "keep", "k0", "k1", false}}
	c2 := [?]turns.Change{{"/r", "tmp", "t1", "", false}}
	segments := [?]turns.Segment{turn(1, 0, 10, c1[:]), turn(2, 10, 20, c2[:])}
	files, err := compose(segments[:], 1, 2)
	defer delete(files)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	testing.expect_value(t, len(files), 1)
	testing.expect_value(t, files[0].path, "keep")
}

@(test)
a_file_restored_to_its_original_content_is_dropped :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "f", "f0", "f1", false}}
	c2 := [?]turns.Change{{"/r", "f", "f1", "f0", false}}
	segments := [?]turns.Segment{turn(1, 0, 10, c1[:]), turn(2, 10, 20, c2[:])}
	files, err := compose(segments[:], 1, 2)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	testing.expect_value(t, len(files), 0)
	delete(files)
}

@(test)
a_shared_change_marks_the_file :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "f", "f0", "f1", true}, {"/r", "g", "g0", "g1", false}}
	segments := [?]turns.Segment{turn(1, 0, 10, c1[:])}
	files, _ := compose(segments[:], 1)
	defer delete(files)
	f, _ := find_composed(files, "f")
	g, _ := find_composed(files, "g")
	testing.expect(t, f.marked)
	testing.expect(t, !g.marked)
}

@(test)
an_unselected_between_segment_inside_the_window_marks_the_file :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "f", "f0", "f1", false}, {"/r", "g", "g0", "g1", false}}
	cb := [?]turns.Change{{"/r", "f", "f1", "fx", false}}
	c3 := [?]turns.Change{{"/r", "f", "fx", "f3", false}}
	segments := [?]turns.Segment {
		turn(1, 0, 10, c1[:]),
		between(2, 10, 20, cb[:]),
		turn(3, 20, 30, c3[:]),
	}
	files, _ := compose(segments[:], 1, 3)
	defer delete(files)
	testing.expect_value(t, len(files), 2)
	f, _ := find_composed(files, "f")
	g, _ := find_composed(files, "g")
	testing.expect_value(t, f.before, "f0")
	testing.expect_value(t, f.after, "f3")
	testing.expect(t, f.marked)
	testing.expect(t, !g.marked)
}

@(test)
an_unselected_segment_outside_the_window_does_not_mark :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "f", "f0", "f1", false}}
	cb := [?]turns.Change{{"/r", "f", "f1", "f2", false}}
	cbefore := [?]turns.Change{{"/r", "f", "f_", "f0", false}}
	segments := [?]turns.Segment {
		between(8, 0, 10, cbefore[:]),
		turn(1, 10, 20, c1[:]),
		// Starts the moment the turn ends and ends well after; not inside the turn.
		between(2, 20, 40, cb[:]),
		turn(4, 50, 60, cb[:]),
	}
	files, _ := compose(segments[:], 1)
	defer delete(files)
	testing.expect_value(t, len(files), 1)
	testing.expect(t, !files[0].marked)
}

@(test)
an_unselected_segment_overlapping_a_selected_one_marks_the_file :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "f", "f0", "f1", false}}
	c2 := [?]turns.Change{{"/r", "f", "f1", "f2", false}}
	segments := [?]turns.Segment{turn(1, 0, 10, c1[:]), turn(2, 5, 15, c2[:])}
	files, _ := compose(segments[:], 1)
	defer delete(files)
	testing.expect_value(t, len(files), 1)
	testing.expect(t, files[0].marked)
}

@(test)
an_unselected_segment_touching_another_file_or_worktree_does_not_mark :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "f", "f0", "f1", false}}
	c2 := [?]turns.Change{{"/r", "other", "o0", "o1", false}, {"/elsewhere", "f", "x0", "x1", false}}
	c3 := [?]turns.Change{{"/r", "f", "f1", "f9", false}}
	segments := [?]turns.Segment{turn(1, 0, 30, c1[:]), turn(2, 5, 15, c2[:]), turn(3, 40, 50, c3[:])}
	files, _ := compose(segments[:], 1, 3)
	defer delete(files)
	testing.expect_value(t, len(files), 1)
	testing.expect(t, !files[0].marked)
}

@(test)
worktrees_and_paths_come_out_sorted :: proc(t: ^testing.T) {
	c1 := [?]turns.Change {
		{"/b", "z", "", "z1", false},
		{"/a", "y", "", "y1", false},
		{"/a", "b/x", "", "x1", false},
		{"/a", "a", "", "a1", false},
	}
	segments := [?]turns.Segment{turn(1, 0, 10, c1[:])}
	files, _ := compose(segments[:], 1)
	defer delete(files)
	testing.expect_value(t, len(files), 4)
	order := [?][2]string{{"/a", "a"}, {"/a", "b/x"}, {"/a", "y"}, {"/b", "z"}}
	for want, i in order {
		testing.expect_value(t, files[i].worktree, want[0])
		testing.expect_value(t, files[i].path, want[1])
	}
}

@(test)
nothing_selected_or_unknown_ids_compose_to_nothing :: proc(t: ^testing.T) {
	c1 := [?]turns.Change{{"/r", "f", "f0", "f1", false}}
	segments := [?]turns.Segment{turn(1, 0, 10, c1[:])}
	files, err := compose(segments[:])
	testing.expect_value(t, err, mem.Allocator_Error.None)
	testing.expect_value(t, len(files), 0)
	files, err = compose(segments[:], 99)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	testing.expect_value(t, len(files), 0)
	files, err = compose(nil, 1)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	testing.expect_value(t, len(files), 0)
}

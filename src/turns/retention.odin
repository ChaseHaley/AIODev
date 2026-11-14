package turns

DAY_MS :: 24 * 60 * 60 * 1000

// Ids of segments that ended more than `days` days before `now`; one ended exactly `days` days ago is
// kept. `days` <= 0 keeps everything.
expired :: proc(segments: []Segment, now: i64, days: int, allocator := context.allocator) -> []u64 {
	if days <= 0 {return nil}
	cutoff := now - i64(days) * DAY_MS
	count := 0
	for s in segments {
		if s.ended < cutoff {count += 1}
	}
	if count == 0 {return nil}
	ids := make([]u64, count, allocator)
	if ids == nil {return nil}
	count = 0
	for s in segments {
		if s.ended >= cutoff {continue}
		ids[count] = s.id
		count += 1
	}
	return ids
}

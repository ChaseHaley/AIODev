package render

import "core:log"

// Construction owns the usable-frame rule for windows and previews. A reset atlas invalidates
// every earlier glyph in the attempt; one fresh attempt is allowed before the frame is discarded.
Frame_Build :: struct {
	list: ^Draw_List,
	device: ^Device,
	generation: u64,
	attempt: int,
}

Frame_Build_Result :: enum { Ready, Retry, Failed }

frame_build_begin :: proc(list: ^Draw_List, device: ^Device) -> Frame_Build {
	draw_list_reset(list)
	return {list, device, atlas_generation(device), 1}
}

@(require_results)
frame_build_finish :: proc(build: ^Frame_Build) -> Frame_Build_Result {
	list := build.list
	if list.error == .None {
		generation := atlas_generation(build.device)
		if generation == build.generation {
			list.atlas_generation = generation
			list.failure_reported = false
			return .Ready
		}
		if build.attempt < 2 {
			build.attempt += 1
			build.generation = generation
			draw_list_reset(list)
			return .Retry
		}
		list.error = .Atlas_Invalidated
	}
	// Retain the error so a direct render or evidence read also rejects this frame.
	clear(&list.layers)
	clear(&list.rects)
	clear(&list.glyphs)
	if !list.failure_reported {
		log.errorf("constructing a frame failed: %v", list.error)
		list.failure_reported = true
	}
	return .Failed
}

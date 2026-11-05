package term_test

import "aio:ghostty"
import "aio:term"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// Fixtures are real encoder output, base64 as the protocol carries it: 2x1 unless noted.
PNG_RGB8 :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DA8J8BAAf/Af8Bf4mnAAAAAElFTkSuQmCC"
PNG_RGBA8 :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8AAQg0AD3oDfnfpf5cAAAAASUVORK5CYII="
PNG_GRAY8 :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAAAAADRSSBWAAAAC0lEQVR4nGNwOAEAAUsBCc6FfVMAAAAASUVORK5CYII="
PNG_GRAY_ALPHA8 :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAQAAABeK7cBAAAADUlEQVR4nGM48T+lAQAHagKsT6leEQAAAABJRU5ErkJggg=="
PNG_GRAY1 :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABAQAAAADcWUInAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg=="
PNG_PALETTE :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAMAAADD/I+4AAAABlBMVEUKFB4oMjzVG7TpAAAAAnRSTlP/AOW3MEoAAAALSURBVHicY2BgBAAABAACv3o/SgAAAABJRU5ErkJggg=="
PNG_RGBA16 :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABEAYAAACksqPJAAAAGklEQVR4nGP4/5+BgYHh/38hkwaG1Wf//wcAPusIOQqWdY8AAAAASUVORK5CYII="
// 2x2, Adam7.
PNG_INTERLACED :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAGK06rlAAAAEklEQVR4nGP4z8DAwAAhODk5ARsqAxnZ8kK2AAAAAElFTkSuQmCC"
// 8000x8000 with no pixel data: inside the storage limit, so only the decoder can refuse it.
PNG_OVERSIZED :: "iVBORw0KGgoAAAANSUhEUgAAH0AAAB9ACAYAAAAG8a30AAAACUlEQVR4nGMAAAABAAFe/335AAAAAElFTkSuQmCC"
// 60000x60000 from a tiny file: must be refused from its header alone.
PNG_BOMB :: "iVBORw0KGgoAAAANSUhEUgAA6mAAAOpgCAYAAACA0nVCAAAACUlEQVR4nGMAAAABAAFe/335AAAAAElFTkSuQmCC"
PNG_TRUNCATED :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7"
// zlib of the RGB bytes 9 8 7 6 5 4.
ZLIB_RGB :: "eJzj5GBnY2UBAACgACg="

Image_Fixture :: struct {
	session: ^term.Session,
	state:   ghostty.Render_State,
	images:  term.Image_Capture,
}

@(private = "file")
fixture_create :: proc(t: ^testing.T, rows: u16 = 10) -> (f: Image_Fixture, ok: bool) {
	testing.set_fail_timeout(t, 30 * time.Second)
	err: term.Error
	f.session, err = term.create_headless(replay_geometry(20, rows), 100)
	if !testing.expect_value(t, err, term.Error.None) {return}
	if !testing.expect_value(t, ghostty.render_state_new(nil, &f.state), ghostty.Result.Success) {return}
	ok = testing.expect(t, term.image_capture_create(&f.images))
	return f, ok
}

@(private = "file")
fixture_destroy :: proc(f: ^Image_Fixture) {
	term.image_capture_destroy(&f.images)
	ghostty.render_state_free(f.state)
	term.destroy(f.session)
}

@(private = "file")
write :: proc(f: ^Image_Fixture, text: string) {
	term.replay_write(f.session, transmute([]u8)text)
}

// Sends a protocol command whose payload is raw bytes.
@(private = "file")
send :: proc(f: ^Image_Fixture, control: string, payload: []u8 = nil) {
	encoded, _ := base64.encode(payload, allocator = context.temp_allocator)
	write(f, fmt.tprintf("\x1b_G%s;%s\x1b\\", control, encoded))
}

@(private = "file")
placements :: proc(t: ^testing.T, f: ^Image_Fixture) -> []term.Image_Placement {
	testing.expect(t, term.capture(f.session, f.state, nil, &f.images))
	return f.images.placements[:]
}

// Replies libghostty wrote, drained so each check sees only its own.
@(private = "file")
replies :: proc(f: ^Image_Fixture) -> string {
	text := strings.clone(string(f.session.queue.pending[:]), context.temp_allocator)
	clear(&f.session.queue.pending)
	return text
}

@(private = "file")
RED_2X2 := [12]u8{255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0}

@(test)
terminal_without_images_reports_none :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "text only\r\n")
	testing.expect_value(t, len(placements(t, &f)), 0)
}

@(test)
query_replies_ok_and_places_nothing :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	payload := [3]u8{}
	send(&f, "i=31,s=1,v=1,a=q,t=d,f=24", payload[:])
	testing.expect_value(t, replies(&f), "\x1b_Gi=31;OK\x1b\\")
	testing.expect_value(t, len(placements(t, &f)), 0)
}

// Output over SSH must not make the terminal open local files, so only direct transmission works.
@(test)
media_other_than_direct_are_refused :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	path := "C:\\Windows\\win.ini"
	for medium in ([?]string{"f", "t", "s"}) {
		send(&f, fmt.tprintf("i=5,s=1,v=1,a=T,f=24,t=%s", medium), transmute([]u8)path)
		reply := replies(&f)
		testing.expectf(t, !strings.contains(reply, ";OK"), "medium %s answered %q", medium, reply)
		testing.expectf(t, strings.has_prefix(reply, "\x1b_Gi=5;E"), "medium %s answered %q", medium, reply)
	}
	testing.expect_value(t, len(placements(t, &f)), 0)
}

@(test)
placement_reports_natural_size_at_the_cursor :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "\x1b[3;5H")
	send(&f, "a=T,f=24,s=2,v=2,i=7", RED_2X2[:])
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 1) {return}
	p := found[0]
	testing.expect_value(t, p.image_id, 7)
	testing.expect_value(t, p.column, 4)
	testing.expect_value(t, p.row, 2)
	testing.expect_value(t, p.width, 2)
	testing.expect_value(t, p.height, 2)
	testing.expect_value(t, p.source_width, 2)
	testing.expect_value(t, p.layer, term.Image_Layer.Above_Text)
	testing.expect(t, p.generation != 0)
}

@(test)
placement_scales_to_requested_cells_and_keeps_crop_and_offset :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	pixels := [48]u8{}
	send(&f, "a=T,f=24,s=4,v=4,i=1,c=4,r=2,x=1,y=2,w=3,h=2,X=3,Y=5", pixels[:])
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 1) {return}
	p := found[0]
	// The requested cells bound the image, so its offsets come out of the 32x32 they cover.
	testing.expect_value(t, p.width, 29)
	testing.expect_value(t, p.height, 27)
	testing.expect_value(t, p.source_x, 1)
	testing.expect_value(t, p.source_y, 2)
	testing.expect_value(t, p.source_width, 3)
	testing.expect_value(t, p.source_height, 2)
	testing.expect_value(t, p.offset_x, 3)
	testing.expect_value(t, p.offset_y, 5)
}

@(test)
z_sorts_placements_and_selects_their_layer :: proc(t: ^testing.T) {
	testing.expect_value(t, term.image_layer(0), term.Image_Layer.Above_Text)
	testing.expect_value(t, term.image_layer(-1), term.Image_Layer.Below_Text)
	testing.expect_value(t, term.image_layer(min(i32) / 2), term.Image_Layer.Below_Text)
	testing.expect_value(t, term.image_layer(min(i32) / 2 - 1), term.Image_Layer.Below_Background)
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	send(&f, "a=T,f=24,s=2,v=2,i=1,z=5", RED_2X2[:])
	send(&f, "a=T,f=24,s=2,v=2,i=2,z=-1073741825", RED_2X2[:])
	send(&f, "a=T,f=24,s=2,v=2,i=3,z=-3", RED_2X2[:])
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 3) {return}
	testing.expect_value(t, found[0].image_id, 2)
	testing.expect_value(t, found[0].layer, term.Image_Layer.Below_Background)
	testing.expect_value(t, found[1].image_id, 3)
	testing.expect_value(t, found[1].layer, term.Image_Layer.Below_Text)
	testing.expect_value(t, found[2].image_id, 1)
	testing.expect_value(t, found[2].layer, term.Image_Layer.Above_Text)
}

@(test)
equal_z_draws_the_lower_image_id_below :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	send(&f, "a=T,f=24,s=2,v=2,i=9,C=1", RED_2X2[:])
	send(&f, "a=T,f=24,s=2,v=2,i=7,C=1", RED_2X2[:])
	send(&f, "a=T,f=24,s=2,v=2,i=8,C=1", RED_2X2[:])
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 3) {return}
	testing.expect_value(t, found[0].image_id, 7)
	testing.expect_value(t, found[1].image_id, 8)
	testing.expect_value(t, found[2].image_id, 9)
}

@(test)
equal_z_orders_one_images_placements_by_id :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	send(&f, "a=t,f=24,s=2,v=2,i=1", RED_2X2[:])
	send(&f, "a=p,i=1,p=3,C=1")
	send(&f, "a=p,i=1,p=1,C=1")
	send(&f, "a=p,i=1,p=2,C=1")
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 3) {return}
	testing.expect_value(t, found[0].placement_id, 1)
	testing.expect_value(t, found[1].placement_id, 2)
	testing.expect_value(t, found[2].placement_id, 3)
}

@(private = "file")
expect_pixels :: proc(t: ^testing.T, f: ^Image_Fixture, expected: []u8, loc := #caller_location) {
	found := placements(t, f)
	if !testing.expect_value(t, len(found), 1, loc) {return}
	pixels, ok := term.image_pixels(f.session, found[0].image_id, found[0].generation)
	defer delete(pixels)
	if !testing.expect(t, ok, "image pixels unavailable", loc = loc) {return}
	if !testing.expect_value(t, len(pixels), len(expected), loc) {return}
	for value, i in expected {
		testing.expectf(t, pixels[i] == value, "byte %d: got %d, want %d", i, pixels[i], value, loc = loc)
	}
}

@(test)
every_raw_format_becomes_premultiplied_rgba :: proc(t: ^testing.T) {
	Case :: struct {
		format:   string,
		pixels:   []u8,
		expected: []u8,
	}
	cases := [?]Case {
		{"24", {10, 20, 30}, {10, 20, 30, 255}},
		{"32", {200, 100, 50, 128}, {100, 50, 25, 128}},
		{"32", {200, 100, 50, 0}, {0, 0, 0, 0}},
		{"32", {200, 100, 50, 255}, {200, 100, 50, 255}},
	}
	for c in cases {
		f, ok := fixture_create(t)
		defer fixture_destroy(&f)
		if !ok {return}
		send(&f, fmt.tprintf("a=T,f=%s,s=1,v=1,i=1", c.format), c.pixels)
		expect_pixels(t, &f, c.expected)
	}
}

// libghostty can store gray formats internally though the protocol has no value that names them.
@(test)
stored_gray_formats_expand_and_wrong_lengths_are_refused :: proc(t: ^testing.T) {
	out: [4]u8
	gray := [1]u8{77}
	testing.expect(t, term.premultiplied_rgba(.Gray, gray[:], out[:]))
	testing.expect_value(t, out, [4]u8{77, 77, 77, 255})
	gray_alpha := [2]u8{200, 128}
	testing.expect(t, term.premultiplied_rgba(.Gray_Alpha, gray_alpha[:], out[:]))
	testing.expect_value(t, out, [4]u8{100, 100, 100, 128})
	testing.expect(t, !term.premultiplied_rgba(.Rgb, gray[:], out[:]))
	testing.expect(t, !term.premultiplied_rgba(.Rgba, gray[:], out[:]))
	testing.expect(t, !term.premultiplied_rgba(.Gray, gray_alpha[:], out[:]))
	testing.expect(t, !term.premultiplied_rgba(.Gray_Alpha, gray[:], out[:]))
	testing.expect(t, !term.premultiplied_rgba(.Png, gray[:], out[:]))
}

@(test)
zlib_and_chunked_payloads_are_reassembled :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "\x1b_Ga=T,f=24,s=2,v=1,i=1,o=z;" + ZLIB_RGB + "\x1b\\")
	expect_pixels(t, &f, {9, 8, 7, 255, 6, 5, 4, 255})
	send(&f, "a=d,d=A")
	// Chunks split on base64 boundaries, as the protocol requires.
	write(&f, "\x1b_Ga=T,f=24,s=2,v=1,i=2,m=1;CQgH\x1b\\")
	testing.expect_value(t, len(placements(t, &f)), 0)
	write(&f, "\x1b_Gm=0;BgUE\x1b\\")
	expect_pixels(t, &f, {9, 8, 7, 255, 6, 5, 4, 255})
}

@(test)
png_variants_decode_to_their_pixels :: proc(t: ^testing.T) {
	Case :: struct {
		name, data: string,
		expected:   []u8,
	}
	cases := [?]Case {
		{"rgb", PNG_RGB8, {255, 0, 0, 255, 0, 255, 0, 255}},
		{"rgba", PNG_RGBA8, {255, 0, 0, 255, 0, 0, 128, 128}},
		{"gray", PNG_GRAY8, {64, 64, 64, 255, 200, 200, 200, 255}},
		{"gray alpha", PNG_GRAY_ALPHA8, {200, 200, 200, 255, 50, 50, 50, 128}},
		{"one bit", PNG_GRAY1, {255, 255, 255, 255, 0, 0, 0, 255}},
		{"palette", PNG_PALETTE, {10, 20, 30, 255, 0, 0, 0, 0}},
		// The second pixel is 0x1234 0x8000 0xABCD 0xFFFF: each channel keeps its high byte.
		{"16 bit", PNG_RGBA16, {255, 0, 0, 255, 0x12, 0x80, 0xAB, 255}},
		{"interlaced", PNG_INTERLACED, {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 9, 9, 255}},
	}
	for c in cases {
		f, ok := fixture_create(t)
		defer fixture_destroy(&f)
		if !ok {return}
		write(&f, fmt.tprintf("\x1b_Ga=T,f=100,i=1;%s\x1b\\", c.data))
		testing.expectf(t, replies(&f) == "\x1b_Gi=1;OK\x1b\\", "%s was not accepted", c.name)
		expect_pixels(t, &f, c.expected)
	}
}

@(test)
bad_png_is_refused_and_the_terminal_keeps_working :: proc(t: ^testing.T) {
	for data, i in ([?]string{PNG_TRUNCATED, PNG_BOMB, PNG_OVERSIZED, "AAAAAAAA"}) {
		f, ok := fixture_create(t)
		defer fixture_destroy(&f)
		if !ok {return}
		write(&f, fmt.tprintf("\x1b_Ga=T,f=100,i=1;%s\x1b\\", data))
		reply := replies(&f)
		testing.expectf(t, strings.has_prefix(reply, "\x1b_Gi=1;E"), "case %d answered %q", i, reply)
		testing.expect_value(t, len(placements(t, &f)), 0)
		write(&f, "still alive")
		shot, err := term.replay_snapshot(f.session)
		defer term.snapshot_destroy(&shot)
		testing.expect_value(t, err, term.Error.None)
		text, _ := term.row_text(&shot, 0, context.temp_allocator)
		testing.expect(t, strings.contains(text, "still alive"))
	}
}

@(test)
retransmitting_an_id_changes_its_generation :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	send(&f, "a=T,f=24,s=2,v=2,i=1", RED_2X2[:])
	first := placements(t, &f)[0].generation
	send(&f, "a=t,f=24,s=2,v=2,i=1", RED_2X2[:])
	stale, stale_ok := term.image_pixels(f.session, 1, first)
	defer delete(stale)
	testing.expect(t, !stale_ok)
	send(&f, "a=p,i=1")
	found := placements(t, &f)
	if !testing.expect(t, len(found) >= 1) {return}
	testing.expect(t, found[0].generation != first)
}

@(test)
delete_removes_the_placement :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	send(&f, "a=T,f=24,s=2,v=2,i=1", RED_2X2[:])
	send(&f, "a=T,f=24,s=2,v=2,i=2", RED_2X2[:])
	testing.expect_value(t, len(placements(t, &f)), 2)
	send(&f, "a=d,d=I,i=1")
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 1) {return}
	testing.expect_value(t, found[0].image_id, 2)
	send(&f, "a=d,d=A")
	testing.expect_value(t, len(placements(t, &f)), 0)
}

@(test)
placement_follows_scrollback_and_leaves_when_scrolled_away :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 5)
	defer fixture_destroy(&f)
	if !ok {return}
	// Two rows tall at 16 pixel cells.
	tall: [3 * 32]u8
	send(&f, "a=T,f=24,s=1,v=32,i=1,C=1", tall[:])
	testing.expect_value(t, placements(t, &f)[0].row, 0)
	write(&f, "\x1b[5;1H\n")
	testing.expect_value(t, placements(t, &f)[0].row, -1)
	write(&f, "\n\n\n")
	testing.expect_value(t, len(placements(t, &f)), 0)
	term.scroll_viewport(f.session, -4)
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 1) {return}
	testing.expect_value(t, found[0].row, 0)
}

@(test)
primary_and_alternate_screens_keep_separate_images :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	send(&f, "a=T,f=24,s=2,v=2,i=1", RED_2X2[:])
	write(&f, "\x1b[?1049h")
	testing.expect_value(t, len(placements(t, &f)), 0)
	send(&f, "a=T,f=24,s=2,v=2,i=2", RED_2X2[:])
	testing.expect_value(t, placements(t, &f)[0].image_id, 2)
	write(&f, "\x1b[?1049l")
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 1) {return}
	testing.expect_value(t, found[0].image_id, 1)
}

@(test)
reset_clears_images_and_leaves_the_protocol_enabled :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	send(&f, "a=T,f=24,s=2,v=2,i=1", RED_2X2[:])
	write(&f, "\x1bc")
	testing.expect_value(t, len(placements(t, &f)), 0)
	send(&f, "a=T,f=24,s=2,v=2,i=2", RED_2X2[:])
	testing.expect_value(t, len(placements(t, &f)), 1)
}

@(test)
resize_changes_how_cell_sized_placements_measure :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	send(&f, "a=T,f=24,s=2,v=2,i=1,c=2,r=1", RED_2X2[:])
	testing.expect_value(t, placements(t, &f)[0].width, 16)
	geometry := replay_geometry(20, 10)
	geometry.cell_width, geometry.cell_height = 16, 32
	term.resize(f.session, geometry)
	found := placements(t, &f)
	if !testing.expect_value(t, len(found), 1) {return}
	testing.expect_value(t, found[0].width, 32)
	testing.expect_value(t, found[0].height, 32)
}

@(test)
size_queries_report_the_pane_in_pixels_and_cells :: proc(t: ^testing.T) {
	f, ok := fixture_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "\x1b[14t")
	testing.expect_value(t, replies(&f), "\x1b[4;160;160t")
	write(&f, "\x1b[16t")
	testing.expect_value(t, replies(&f), "\x1b[6;16;8t")
	write(&f, "\x1b[18t")
	testing.expect_value(t, replies(&f), "\x1b[8;10;20t")
	geometry := replay_geometry(40, 20)
	geometry.cell_width, geometry.cell_height = 10, 20
	term.resize(f.session, geometry)
	write(&f, "\x1b[16t")
	testing.expect_value(t, replies(&f), "\x1b[6;20;10t")
}

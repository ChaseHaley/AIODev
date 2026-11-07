package markdown

foreign import md4c "../../build/native/md4c.lib"

@(private)
Md_Block :: enum i32 {
	Doc,
	Quote,
	Ul,
	Ol,
	Li,
	Hr,
	H,
	Code,
	Html,
	P,
	Table,
	Thead,
	Tbody,
	Tr,
	Th,
	Td,
}

@(private)
Md_Span :: enum i32 {
	Em,
	Strong,
	A,
	Img,
	Code,
	Ins,
	Del,
}

@(private)
Md_Text :: enum i32 {
	Normal,
	Null_Char,
	Br,
	Soft_Br,
	Entity,
	Code,
	Html,
	Latex_Math,
}

@(private)
Md_Attribute :: struct {
	text:           [^]u8,
	size:           u32,
	substr_types:   [^]Md_Text,
	substr_offsets: [^]u32,
}

@(private)
Md_Ol_Detail :: struct {
	start:          u32,
	is_tight:       i32,
	mark_delimiter: u8,
}

@(private)
Md_Ul_Detail :: struct {
	is_tight: i32,
	mark:     u8,
}

@(private)
Md_Li_Detail :: struct {
	is_task:          i32,
	task_mark:        u8,
	task_mark_offset: u32,
}

@(private)
Md_H_Detail :: struct {
	level: u32,
}

@(private)
Md_Table_Detail :: struct {
	col_count, head_row_count, body_row_count: u32,
}

@(private)
Md_Align :: enum i32 {
	Default,
	Left,
	Center,
	Right,
}

@(private)
Md_Td_Detail :: struct {
	align: Md_Align,
}

@(private)
Md_A_Detail :: struct {
	href, title: Md_Attribute,
	is_autolink: i32,
}

@(private)
Md_Img_Detail :: struct {
	src, title: Md_Attribute,
}

@(private)
Md_Parser :: struct {
	abi_version: u32,
	flags:       u32,
	enter_block: proc "c" (type: i32, detail, user: rawptr) -> i32,
	leave_block: proc "c" (type: i32, detail, user: rawptr) -> i32,
	enter_span:  proc "c" (type: i32, detail, user: rawptr) -> i32,
	leave_span:  proc "c" (type: i32, detail, user: rawptr) -> i32,
	text:        proc "c" (type: Md_Text, text: [^]u8, size: u32, user: rawptr) -> i32,
	debug_log:   proc "c" (message: cstring, user: rawptr),
	syntax:      proc "c" (),
}

// The GitHub dialect without footnotes or admonitions. Raw HTML stays literal text: file content is
// untrusted and nothing here interprets it. E-mail autolinks are left out because the shared link
// policy has no mailto target.
@(private)
MD_FLAGS: u32 : 0x1 /* collapse whitespace */ | 0x4 /* URL autolinks */ | 0x400 /* www autolinks */ |
	0x60 /* no HTML */ | 0x100 /* tables */ | 0x200 /* strikethrough */ | 0x800 /* task lists */

@(private, default_calling_convention = "c")
foreign md4c {
	md_parse :: proc(text: [^]u8, size: u32, parser: ^Md_Parser, user: rawptr) -> i32 ---
}

package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Search :: distinct rawptr

Search_Status :: enum i32 {
	Running = 0,
	Feed_Required = 1,
	Complete = 2,
}

Search_Scroll :: enum i32 {
	If_Needed = 0,
	None = 1,
}

Search_Data :: enum i32 {
	Status = 0,
	Needle = 1,
	Total_Matches = 2,
	Selected_Index = 3,
	Selected_Match = 4,
	Matches = 5,
	Viewport_Matches = 6,
	Select_Scroll = 7,
}

Search_Option :: enum i32 {
	Needle = 0,
	Select_Next = 1,
	Select_Prev = 2,
	Select_Scroll = 3,
}

@(default_calling_convention="c", link_prefix="ghostty_")
foreign lib {
	@(require_results)
	search_new :: proc(allocator: ^Allocator, out_search: ^Search, terminal: Terminal) -> Result ---
	search_free :: proc(search: Search) ---
	@(require_results)
	search_tick :: proc(search: Search, out_status: ^Search_Status) -> Result ---
	@(require_results)
	search_feed :: proc(search: Search) -> Result ---
	@(require_results)
	search_run :: proc(search: Search) -> Result ---
	@(require_results)
	search_set :: proc(search: Search, option: Search_Option, value: rawptr) -> Result ---
	@(require_results)
	search_get :: proc(search: Search, data: Search_Data, value: rawptr) -> Result ---
	@(require_results)
	search_get_multi :: proc(
		search: Search,
		count: uint,
		keys: [^]Search_Data,
		values: [^]rawptr,
		out_written: ^uint,
	) -> Result ---
}

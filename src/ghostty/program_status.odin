package ghostty

Program_Status_State :: enum i32 {
	Idle,
	Working,
	Done,
	Blocked,
	Error,
	Clear,
}

Program_Status_Kind :: enum i32 {
	None,
	Permission,
	Question,
	Auth,
}

Terminal_Program_Status :: struct {
	size:                    uint,
	state:                   Program_Status_State,
	kind:                    Program_Status_Kind,
	progress:                i8,
	id, app, title, message: String,
}

Terminal_Program_Status_Fn :: proc "c" (
	terminal: Terminal,
	userdata: rawptr,
	report: ^Terminal_Program_Status,
)

Semantic_Prompt_Kind :: enum i32 {
	Invalid,
	Prompt_Start,
	Input_Start,
	Output_Start,
	Command_End,
}

Semantic_Prompt_Prompt_Kind :: enum i32 {
	Primary,
	Right,
	Continuation,
	Secondary,
}

Terminal_Semantic_Prompt :: struct {
	size:           uint,
	kind:           Semantic_Prompt_Kind,
	prompt_kind:    Semantic_Prompt_Prompt_Kind,
	has_exit_code:  bool,
	exit_code:      i32,
	command, error: String,
}

Terminal_Semantic_Prompt_Fn :: proc "c" (
	terminal: Terminal,
	userdata: rawptr,
	event: ^Terminal_Semantic_Prompt,
)

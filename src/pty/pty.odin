package pty

Env_Var :: struct {
	name, value: string,
}

Spawn_Options :: struct {
	command_line, working_directory: string,
	environment:                     []Env_Var,
	// A directory added at the end of the child's PATH, after the overrides apply.
	path_append:                     string,
	cols, rows:                      u16,
	refresh_environment:             bool,
}

Spawn_Error_Kind :: enum {
	None,
	Invalid_Argument,
	Invalid_Working_Directory,
	Out_Of_Memory,
	Invalid_Environment,
	Environment,
	Pipe,
	Console,
	Attributes,
	Job,
	Start_Process,
	Resume_Process,
}

Spawn_Error :: struct {
	kind:    Spawn_Error_Kind,
	os_code: u32,
}

Error :: enum {
	None,
	Closed,
	Invalid_Argument,
	Out_Of_Memory,
	Read,
	Write,
	Resize,
	Wait,
	Terminate,
}

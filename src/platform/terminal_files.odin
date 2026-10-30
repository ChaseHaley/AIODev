package platform

// Terminal_File owns the canonical clicked path and effective shortcut target. Preparation is
// click-only; an active type always needs confirmation, including shortcuts carrying arguments.
Terminal_File :: struct {
	path, target: string,
	confirm:      bool,
}

terminal_file_destroy :: proc(file: ^Terminal_File) {
	delete(file.path)
	delete(file.target)
	file^ = {}
}

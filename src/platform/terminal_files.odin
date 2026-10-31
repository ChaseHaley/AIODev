package platform

// Terminal_File owns the canonical clicked path and effective target. Preparation is click-only;
// an active type always needs confirmation, and every shortcut is active. The target is what opens.
Terminal_File :: struct {
	path, target: string,
	confirm:      bool,
}

terminal_file_destroy :: proc(file: ^Terminal_File) {
	delete(file.path)
	delete(file.target)
	file^ = {}
}

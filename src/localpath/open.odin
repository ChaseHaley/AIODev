package localpath

import "core:strings"

// Open_File owns the canonical clicked path and effective target. Preparation is click-only;
// an active type always needs confirmation, and every shortcut is active. The target is what opens.
Open_File :: struct {
	path, target: string,
	confirm:      bool,
}

open_file_destroy :: proc(file: ^Open_File) {
	delete(file.path)
	delete(file.target)
	file^ = {}
}

// Includes shell-active formats absent from a stock PATHEXT. Empty PATHEXT entries never match.
@(require_results)
file_needs_confirmation :: proc(path, pathext: string) -> bool {
	ext := ""
	for i := len(path) - 1; i >= 0; i -= 1 {
		if is_separator(path[i]) {break}
		if path[i] == '.' {ext = path[i:]; break}
	}
	for active in ([?]string{
		".exe", ".com", ".bat", ".cmd", ".ps1", ".psm1", ".psd1", ".vbs", ".vbe", ".js", ".jse",
		".wsf", ".wsh", ".msc", ".scr", ".pif", ".cpl", ".dll", ".ocx", ".sys", ".drv", ".reg",
		".lnk", ".url", ".website", ".scf", ".msi", ".msp", ".mst", ".hta", ".chm", ".hlp",
		".library-ms", ".settingcontent-ms", ".appref-ms", ".application", ".gadget", ".inf", ".ins",
		".isp", ".sct", ".wsc", ".appx", ".appxbundle", ".msix", ".msixbundle", ".appinstaller",
		".py", ".pyw", ".pl", ".rb", ".sh", ".bash", ".jar", ".jnlp", ".diagcab",
		".msu", ".search-ms", ".searchconnector-ms", ".xll", ".wll", ".xlam", ".ppam", ".iqy",
		".slk", ".iso", ".vhd", ".vhdx", ".msh", ".msh1", ".msh2", ".mshxml", ".msh1xml",
		".msh2xml", ".ps1xml", ".cdxml",
	}) {
		if strings.equal_fold(ext, active) {return true}
	}
	start := 0
	for i := 0; i <= len(pathext); i += 1 {
		if i < len(pathext) && pathext[i] != ';' {continue}
		entry := strings.trim_space(pathext[start:i])
		if entry != "" && ext != "" && strings.equal_fold(ext, entry) {return true}
		start = i + 1
	}
	return false
}

package settings

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Machine facts a settings revision is parsed with: the theme files in the themes folder and the
// shells found on this machine. The app reads them once per settings read; every parse of that
// revision, of its edits and of the settings page shares the snapshot, so a save reads neither the
// themes folder nor the registry. Everything is owned by `allocator`; a parse copies what it keeps.
Inputs :: struct {
	// Empty when the folder is unknown; exports then fail.
	themes_directory: string,
	theme_files:      [dynamic]Theme_File,
	detected:         [dynamic]Detected_Profile,
	allocator:        runtime.Allocator,
}

// One themes-folder result in scan order: a parsed theme, or the problem reported under `path`.
Theme_File :: struct {
	path, issue: string,
	theme:       Custom_Theme,
}

@(private)
THEME_SCAN_LIMIT :: 1024

// Reads the themes folder and keeps a copy of `detected`. A folder that cannot be read becomes a
// diagnostic of every parse, as a file that cannot be read or parsed does; only allocation fails.
@(require_results)
inputs_read :: proc(
	themes_directory: string,
	detected: []Detected_Profile,
	allocator := context.allocator,
) -> (
	inputs: Inputs,
	err: runtime.Allocator_Error,
) {
	inputs.allocator = allocator
	inputs.theme_files.allocator = allocator
	inputs.detected.allocator = allocator
	defer if err != nil {inputs_destroy(&inputs)}
	inputs.themes_directory = strings.clone(themes_directory, allocator) or_return
	for shell in detected {
		append(&inputs.detected, Detected_Profile{}) or_return
		kept := &inputs.detected[len(inputs.detected) - 1]
		targets := [?]^string{&kept.id, &kept.name, &kept.command, &kept.directory}
		for source, i in ([?]string{shell.id, shell.name, shell.command, shell.directory}) {
			targets[i]^ = strings.clone(source, allocator) or_return
		}
	}
	if themes_directory == "" {return}
	files, read_error := os.read_directory_by_path(themes_directory, THEME_SCAN_LIMIT, context.temp_allocator)
	if read_error == .Not_Exist {return}
	if read_error != nil {
		err = theme_file_keep(&inputs, themes_directory, "Could not read themes directory.", {})
		return
	}
	defer os.file_info_slice_delete(files, context.temp_allocator)
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	if len(files) == THEME_SCAN_LIMIT {
		theme_file_keep(&inputs, themes_directory, "Only the first 1024 entries were scanned.", {}) or_return
	}
	for file in files {
		if file.type != .Regular {continue}
		if !strings.has_suffix(file.name, ".theme.json") {continue}
		path := fmt.tprintf("%s/%s", themes_directory, file.name)
		if file.size > THEME_FILE_MAX_BYTES {
			theme_file_keep(&inputs, path, THEME_FILE_SIZE_NOTICE, {}) or_return
			continue
		}
		data, error := os.read_entire_file(path, context.temp_allocator)
		if error != nil {
			theme_file_keep(&inputs, path, "Could not read theme file.", {}) or_return
			continue
		}
		theme, issue := theme_file_parse(string(data))
		delete(data, context.temp_allocator)
		theme_file_keep(&inputs, path, issue, theme) or_return
	}
	return
}

inputs_destroy :: proc(inputs: ^Inputs) {
	allocator := inputs.allocator
	delete(inputs.themes_directory, allocator)
	for file in inputs.theme_files {
		for text in ([?]string{file.path, file.issue, file.theme.id, file.theme.base, file.theme.name}) {
			delete(text, allocator)
		}
	}
	delete(inputs.theme_files)
	for shell in inputs.detected {
		for text in ([?]string{shell.id, shell.name, shell.command, shell.directory}) {delete(text, allocator)}
	}
	delete(inputs.detected)
	inputs^ = {}
}

// Records one scan result; `theme` matters only when `issue` is empty. Its strings may be temporary.
@(private, require_results)
theme_file_keep :: proc(
	inputs: ^Inputs,
	path, issue: string,
	theme: Custom_Theme,
) -> runtime.Allocator_Error {
	append(&inputs.theme_files, Theme_File{}) or_return
	kept := &inputs.theme_files[len(inputs.theme_files) - 1]
	kept.path = strings.clone(path, inputs.allocator) or_return
	if issue != "" {
		kept.issue = strings.clone(issue, inputs.allocator) or_return
		return nil
	}
	kept.theme = theme
	kept.theme.id, kept.theme.base, kept.theme.name = "", "", ""
	kept.theme.id = strings.clone(theme.id, inputs.allocator) or_return
	kept.theme.base = strings.clone(theme.base, inputs.allocator) or_return
	kept.theme.name = strings.clone(theme.name, inputs.allocator) or_return
	return nil
}

// Adds the snapshot's theme files, in folder order, after the settings file's own themes: a file
// whose ID the settings file already defines is ignored, and only a second file reports it.
@(private, require_results)
theme_files_apply :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	files: []Theme_File,
) -> runtime.Allocator_Error {
	for file in files {
		if file.issue != "" {
			diagnostic_append(diagnostics, 0, file.path, file.issue) or_return
			continue
		}
		if existing := custom_theme_find(s, file.theme.id); existing != nil {
			if existing.external {
				diagnostic_append(diagnostics, 0, file.path, "Duplicate theme ID; file ignored.") or_return
			}
			continue
		}
		stored := custom_theme_add(s, file.theme.id) or_return
		if stored == nil {
			diagnostic_append(diagnostics, 0, file.path, "Custom theme limit reached.") or_return
			continue
		}
		custom_theme_store(s, stored, file.theme) or_return
	}
	return nil
}

// Adds the shells `detected` lists to a parsed revision. Hidden profiles and file overrides win in
// profile_detect; detection from an earlier snapshot is dropped first.
@(require_results)
profiles_apply_detection :: proc(s: ^Settings, detected: []Detected_Profile) -> runtime.Allocator_Error {
	profiles_begin_detection(&s.profiles)
	for profile in detected {profile_detect(s, profile) or_return}
	return profiles_finalize(s)
}

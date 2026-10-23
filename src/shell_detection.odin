package main

import "aio:settings"
import platform_api "aio:platform"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// Adds the shells this machine has, without starting one. Only file existence and the WSL
// registry are consulted; hidden profiles and file overrides win in profile_detect.
detect_shell_profiles :: proc(app: ^App) {
	detected := make([dynamic]settings.Detected_Profile, context.temp_allocator)
	system_root := os.get_env("SystemRoot", context.temp_allocator)
	if system_root == "" {system_root = `C:\Windows`}
	windows_powershell := fmt.tprintf(
		"%s\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
		system_root,
	)
	if os.exists(windows_powershell) {
		detect_append(&detected, "powershell", "Windows PowerShell", "powershell.exe -NoLogo")
	}
	if os.exists(fmt.tprintf("%s\\System32\\cmd.exe", system_root)) {
		detect_append(&detected, "cmd", "Command Prompt", "cmd.exe")
	}
	program_files := os.get_env("ProgramFiles", context.temp_allocator)
	local_app_data := os.get_env("LOCALAPPDATA", context.temp_allocator)
	pwsh_found := false
	if program_files != "" {
		for pair in ([?][2]string{
			{fmt.tprintf("%s\\PowerShell\\7\\pwsh.exe", program_files), "pwsh"},
			{fmt.tprintf("%s\\PowerShell\\7-preview\\pwsh.exe", program_files), "pwsh-preview"},
		}) {
			if pwsh_found || !os.exists(pair[0]) {continue}
			name := pair[1] == "pwsh" ? "PowerShell 7" : "PowerShell 7 Preview"
			detect_append(&detected, pair[1], name, "pwsh.exe -NoLogo")
			pwsh_found = true
		}
	}
	if !pwsh_found &&
	   local_app_data != "" &&
	   os.exists(fmt.tprintf("%s\\Microsoft\\WindowsApps\\pwsh.exe", local_app_data)) {
		detect_append(&detected, "pwsh", "PowerShell 7", "pwsh.exe -NoLogo")
	}
	if os.exists(fmt.tprintf("%s\\System32\\wsl.exe", system_root)) {
		distributions, distribution_error := platform_api.wsl_distributions(
			context.temp_allocator,
		)
		if distribution_error != nil {
			log.errorf("listing WSL distributions failed: %v", distribution_error)
		}
		for name in distributions {
			id := profile_id_for(name)
			for existing in detected {if existing.id == id {id = fmt.tprintf("%s-2", id)}}
			detect_append(
				&detected,
				id,
				name,
				fmt.tprintf("wsl.exe -d \"%s\"", name),
			)
		}
	}
	settings.profiles_begin_detection(&app.settings.profiles)
	for profile in detected {
		if profile_error := settings.profile_detect(&app.settings, profile);
		   profile_error != nil {
			log.errorf("adding detected shell profiles failed: %v", profile_error)
			break
		}
	}
	if finalize_error := settings.profiles_finalize(&app.settings); finalize_error != nil {
		log.errorf("resolving detected shell profiles failed: %v", finalize_error)
	}
}

@(private)
detect_append :: proc(
	out: ^[dynamic]settings.Detected_Profile,
	id, name, command: string,
) {
	if _, err := append(out, settings.Detected_Profile{id, name, command, "~"}); err != nil {
		log.errorf("recording a detected shell failed: %v", err)
	}
}

// Turns a distribution name into a stable lowercase profile ID. Collisions get a -2 suffix
// at the call site.
profile_id_for :: proc(name: string) -> string {
	buffer: [settings.PROFILE_ID_MAX_LENGTH]u8
	count := 0
	previous_separator := true
	for r in strings.to_lower(name, context.temp_allocator) {
		letter := r >= 'a' && r <= 'z'
		digit := r >= '0' && r <= '9'
		if letter || digit {
			buffer[count] = u8(r)
			count += 1
			previous_separator = false
		} else if !previous_separator && count > 0 {
			buffer[count] = '-'
			count += 1
			previous_separator = true
		}
		if count == len(buffer) {break}
	}
	for count > 0 && buffer[count - 1] == '-' {count -= 1}
	if count == 0 {return "wsl"}
	return strings.clone(string(buffer[:count]), context.temp_allocator)
}

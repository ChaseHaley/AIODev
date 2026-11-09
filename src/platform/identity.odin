package platform

import "core:log"
import w "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

// The instance identity both backends share: one named mutex per app id and Windows user, which
// `aioctl` and a second launch look for.

@(require_results)
@(private)
os_ok :: proc(ok: w.BOOL, call: string) -> bool {
	if !bool(ok) {
		log.errorf("%s failed: Win32 %d", call, w.GetLastError())
		return false
	}
	return true
}

@(private, require_results)
user_identity :: proc(out: []u16) -> (length: int, err: Error) {
	token: w.HANDLE
	if !os_ok(
		w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &token),
		"OpenProcessToken",
	) {
		return 0, .Os
	}
	defer {
		if !os_ok(w.CloseHandle(token), "CloseHandle(token)") {
			err = .Os
		}
	}
	storage: [16]u64
	needed: u32
	if !os_ok(
		w.GetTokenInformation(token, .TokenUser, &storage, size_of(storage), &needed),
		"GetTokenInformation",
	) {
		return 0, .Os
	}
	user := cast(^w.TOKEN_USER)&storage
	sid := cast(^w.SID)user.User.Sid
	count := 8 + 4 * int(sid.SubAuthorityCount)
	if count > size_of(w.SID) || count * 2 > len(out) {return 0, .Invalid_Argument}
	bytes := (cast([^]u8)sid)[:count]
	digits := "0123456789abcdef"
	for byte, i in bytes {
		out[i * 2] = u16(digits[byte >> 4])
		out[i * 2 + 1] = u16(digits[byte & 15])
	}
	return count * 2, .None
}

@(private, require_results)
mutex_name :: proc(app_id: string) -> (name: [512]u16, err: Error) {
	if len(app_id) == 0 || len(app_id) > 120 || !utf8.valid_string(app_id) {
		return {}, .Invalid_Argument
	}
	for c in app_id {
		if c == 0 || c == '\\' || c == '/' {return {}, .Invalid_Argument}
	}
	n := utf16.encode_string(name[:], "Local\\")
	n += utf16.encode_string(name[n:], app_id)
	name[n] = '.'
	n += 1
	_, err = user_identity(name[n:])
	return
}

@(require_results)
instance_running :: proc(app_id: string) -> (running: bool, err: Error) {
	name, name_error := mutex_name(app_id)
	if name_error != .None {return false, name_error}
	mutex := OpenMutexW(w.SYNCHRONIZE, false, cstring16(raw_data(name[:])))
	if mutex == nil {
		if w.GetLastError() == w.ERROR_FILE_NOT_FOUND {return false, .None}
		log.errorf("OpenMutexW failed: Win32 %d", w.GetLastError())
		return false, .Os
	}
	if !os_ok(w.CloseHandle(mutex), "CloseHandle(mutex)") {return false, .Os}
	return true, .None
}

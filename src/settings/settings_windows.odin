package settings

import "core:log"
import "core:os"
import "core:strings"
import "core:sys/windows"

@(require_results)
default_path :: proc(allocator := context.allocator) -> (string, os.Error) {
	wide: windows.LPWSTR
	id := windows.FOLDERID_RoamingAppData
	hr := windows.SHGetKnownFolderPath(&id, 0, nil, &wide)
	defer if wide != nil {
		windows.CoTaskMemFree(wide)
	}
	if hr < 0 {
		log.errorf("SHGetKnownFolderPath failed: HRESULT 0x%08x", u32(hr))
		return "", os.Platform_Error(hr)
	}
	base, err := windows.wstring_to_utf8(windows.wstring(wide), -1, allocator)
	if err != nil { return "", err }
	defer delete(base, allocator)
	result, copy_error := strings.concatenate({base, "\\AIODev\\settings.ini"}, allocator)
	if copy_error != nil { return "", copy_error }
	return result, nil
}


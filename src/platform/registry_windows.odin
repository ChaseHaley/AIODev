package platform

import "base:runtime"
import w "core:sys/windows"

// Reads installed WSL distribution names from HKCU Lxss. Detection never starts a process.
wsl_distributions :: proc(
	allocator := context.allocator,
) -> (
	[]string,
	runtime.Allocator_Error,
) {
	root: w.HKEY
	path := w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss")
	if w.RegOpenKeyExW(w.HKEY_CURRENT_USER, cast(w.LPCWSTR)path, 0, w.KEY_READ, &root) != 0 {
		return nil, nil
	}
	defer w.RegCloseKey(root)
	names := make([dynamic]string, allocator)
	index: w.DWORD
	for {
		name: [256]u16
		length := w.DWORD(len(name) - 1)
		result := w.RegEnumKeyExW(
			root,
			index,
			&name[0],
			&length,
			nil,
			nil,
			nil,
			nil,
		)
		if result != 0 {break}
		index += 1
		if length == 0 || length >= len(name) {continue}
		name[length] = 0
		subkey: w.HKEY
		if w.RegOpenKeyExW(root, cast(w.LPCWSTR)&name[0], 0, w.KEY_READ, &subkey) != 0 {
			continue
		}
		value: [256]u16
		size := w.DWORD(len(value) * size_of(u16))
		kind: w.DWORD
		found := w.RegGetValueW(
			subkey,
			nil,
			w.L("DistributionName"),
			w.RRF_RT_REG_SZ,
			&kind,
			&value[0],
			&size,
		) == 0
		w.RegCloseKey(subkey)
		if !found || size < 2 {continue}
		units := value[:size / 2]
		count := 0
		for count < len(units) && units[count] != 0 {count += 1}
		if count == 0 {continue}
		converted, err := w.utf16_to_utf8(units[:count], allocator)
		if err != nil {
			for existing in names {delete(existing, allocator)}
			delete(names)
			return nil, err
		}
		if _, append_error := append(&names, converted); append_error != nil {
			delete(converted, allocator)
			for existing in names {delete(existing, allocator)}
			delete(names)
			return nil, append_error
		}
	}
	return names[:], nil
}

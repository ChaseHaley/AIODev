package localpath

import "core:log"
import "core:sync"
import w "core:sys/windows"
import "core:unicode/utf16"

foreign import hosts_kernel32 "system:kernel32.lib"

@(default_calling_convention = "system")
foreign hosts_kernel32 {
	GetComputerNameExW :: proc(format: u32, buffer: w.LPWSTR, size: ^u32) -> w.BOOL ---
}

@(private)
Local_Hosts :: struct {
	once:  sync.Once,
	text:  [3][256]u8,
	names: [3]string,
	count: int,
}
@(private)
local_hosts_state: Local_Hosts

// This machine's DNS host, fully qualified and NetBIOS names, which local shells and ls write
// into file URI authorities. Read once; callers on any thread borrow the result.
local_hosts :: proc() -> []string {
	sync.once_do(&local_hosts_state.once, proc() {
		hosts := &local_hosts_state
		for format in ([?]u32{1, 3, 0}) {
			wide: [256]u16
			size := u32(len(wide))
			if !bool(GetComputerNameExW(format, &wide[0], &size)) || size == 0 {
				log.errorf("GetComputerNameExW(%d) failed: %d", format, w.GetLastError())
				continue
			}
			n := utf16.decode_to_utf8(hosts.text[hosts.count][:], wide[:size])
			hosts.names[hosts.count] = string(hosts.text[hosts.count][:n])
			hosts.count += 1
		}
	})
	return local_hosts_state.names[:local_hosts_state.count]
}

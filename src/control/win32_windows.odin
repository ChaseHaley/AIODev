package control

import w "core:sys/windows"

@(private)
SDDL_REVISION_1 :: 1
@(private)
ERROR_PIPE_NOT_CONNECTED :: 233

@(private)
SECURITY_IDENTIFICATION :: u32(w.SECURITY_IMPERSONATION_LEVEL.SecurityIdentification) << 16

foreign import kernel32 "system:kernel32.lib"
foreign import advapi32 "system:advapi32.lib"

@(private, default_calling_convention="system")
foreign kernel32 {
	GetNamedPipeServerProcessId :: proc(Pipe: w.HANDLE, ServerProcessId: ^w.ULONG) -> w.BOOL ---
}

@(private, default_calling_convention="system")
foreign advapi32 {
	ConvertStringSecurityDescriptorToSecurityDescriptorW :: proc(
		StringSecurityDescriptor: w.LPCWSTR, StringSDRevision: w.DWORD,
		SecurityDescriptor: ^w.PSECURITY_DESCRIPTOR, SecurityDescriptorSize: ^w.ULONG,
	) -> w.BOOL ---
}

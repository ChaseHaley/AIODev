package control_test

import "aio:control"
import "core:fmt"
import w "core:sys/windows"
import "core:testing"

foreign import pipe_acl_advapi32 "system:advapi32.lib"

@(private, default_calling_convention = "system")
foreign pipe_acl_advapi32 {
	GetSecurityInfo :: proc(
		handle: w.HANDLE,
		object_type, information: w.DWORD,
		owner, group: ^w.PSID,
		dacl, sacl: ^w.PACL,
		descriptor: ^w.PSECURITY_DESCRIPTOR,
	) -> w.DWORD ---
	GetSecurityDescriptorDacl :: proc(
		descriptor: w.PSECURITY_DESCRIPTOR,
		present: ^w.BOOL,
		dacl: ^w.PACL,
		defaulted: ^w.BOOL,
	) -> w.BOOL ---
	GetSecurityDescriptorControl :: proc(
		descriptor: w.PSECURITY_DESCRIPTOR,
		control: ^u16,
		revision: ^w.DWORD,
	) -> w.BOOL ---
	IsValidAcl :: proc(acl: w.PACL) -> w.BOOL ---
	GetAce :: proc(acl: w.PACL, index: w.DWORD, ace: ^rawptr) -> w.BOOL ---
	IsValidSid :: proc(sid: w.PSID) -> w.BOOL ---
	EqualSid :: proc(first, second: w.PSID) -> w.BOOL ---
}

@(private)
Pipe_Ace_Header :: struct {
	kind, flags: u8,
	size: u16,
}

@(private)
Pipe_Allowed_Ace :: struct {
	header: Pipe_Ace_Header,
	mask, sid_start: u32,
}

#assert(size_of(Pipe_Ace_Header) == 4)
#assert(offset_of(Pipe_Allowed_Ace, sid_start) == 8)

@(private, require_results)
acl_expect_win32 :: proc(t: ^testing.T, result: w.BOOL, call: string) -> bool {
	error := w.GetLastError()
	return testing.expect(t, bool(result), fmt.tprintf("%s: %v", call, error))
}

@(test)
pipe_dacl_allows_only_its_current_user :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	if name == "" {return}
	defer delete(name)
	server, error := control.create(name, {})
	if !testing.expect_value(t, error, control.Error.None) {return}
	defer control.destroy(server)
	acl: w.PACL
	descriptor: w.PSECURITY_DESCRIPTOR
	// SE_KERNEL_OBJECT is a Windows C enum, whose argument width is DWORD.
	result := GetSecurityInfo(server.pipe, 6, w.DACL_SECURITY_INFORMATION, nil, nil, &acl, nil, &descriptor)
	if !testing.expect(t, result == 0, fmt.tprintf("GetSecurityInfo: %v", result)) {return}
	defer testing.expect(t, w.LocalFree(descriptor) == nil, "LocalFree descriptor")
	present, defaulted: w.BOOL
	stored_acl: w.PACL
	if !acl_expect_win32(
		t, GetSecurityDescriptorDacl(descriptor, &present, &stored_acl, &defaulted), "GetSecurityDescriptorDacl",
	) {return}
	if !testing.expect(t, bool(present) && acl != nil && stored_acl == acl, "non-null explicit DACL") {return}
	testing.expect(t, !bool(defaulted), "DACL was supplied explicitly")
	control_bits: u16
	revision: w.DWORD
	if !acl_expect_win32(
		t, GetSecurityDescriptorControl(descriptor, &control_bits, &revision), "GetSecurityDescriptorControl",
	) {return}
	testing.expect(t, control_bits & 0x1000 != 0, "SE_DACL_PROTECTED")
	if !acl_expect_win32(t, IsValidAcl(acl), "IsValidAcl") {return}
	testing.expect_value(t, acl.AceCount, u16(1))
	token: w.HANDLE
	if !acl_expect_win32(
		t, w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &token), "OpenProcessToken",
	) {return}
	defer {_ = acl_expect_win32(t, w.CloseHandle(token), "CloseHandle token")}
	size: w.DWORD
	queried := w.GetTokenInformation(token, .TokenUser, nil, 0, &size)
	query_error := w.GetLastError()
	if !testing.expect(t, !bool(queried) && query_error == w.ERROR_INSUFFICIENT_BUFFER) {return}
	if !testing.expect(t, size >= size_of(w.TOKEN_USER)) {return}
	buffer, allocation_error := make([]u8, int(size), context.allocator)
	if !testing.expect(t, allocation_error == nil) {return}
	defer delete(buffer)
	if !acl_expect_win32(
		t, w.GetTokenInformation(token, .TokenUser, raw_data(buffer), size, &size), "GetTokenInformation TokenUser",
	) {return}
	user := cast(^w.TOKEN_USER)raw_data(buffer)
	for index in 0..<int(acl.AceCount) {
		entry: rawptr
		if !acl_expect_win32(t, GetAce(acl, w.DWORD(index), &entry), "GetAce") {continue}
		header := cast(^Pipe_Ace_Header)entry
		if !testing.expect_value(t, header.kind, u8(0)) {continue}
		if !testing.expect(t, int(header.size) >= size_of(Pipe_Allowed_Ace)) {continue}
		testing.expect_value(t, header.flags, u8(0))
		allowed := cast(^Pipe_Allowed_Ace)entry
		sid := rawptr(&allowed.sid_start)
		if !acl_expect_win32(t, IsValidSid(sid), "IsValidSid") {continue}
		testing.expect(t, bool(EqualSid(sid, user.User.Sid)), "only the creating account has an allow ACE")
	}
}

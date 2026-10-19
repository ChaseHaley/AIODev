package pty

import w "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"
foreign import userenv "system:userenv.lib"

@(private, default_calling_convention = "system")
foreign userenv {
	CreateEnvironmentBlock :: proc(environment: ^rawptr, token: w.HANDLE, inherit: w.BOOL) -> w.BOOL ---
	DestroyEnvironmentBlock :: proc(environment: rawptr) -> w.BOOL ---
}

@(private) HPCON :: distinct rawptr
@(private) PSEUDOCONSOLE_RESIZE_QUIRK :: 0x2
@(private) PSEUDOCONSOLE_WIN32_INPUT_MODE :: 0x4
@(private) PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x20016
@(private) JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000
@(private) JobObjectExtendedLimitInformation :: 9
@(private) ERROR_DIRECTORY :: 267
@(private) CSTR_LESS_THAN :: 1
@(private) CSTR_EQUAL :: 2

@(private)
STARTUPINFOEXW :: struct {
	StartupInfo: w.STARTUPINFOW,
	lpAttributeList: rawptr,
}

@(private)
IO_COUNTERS :: struct {
	ReadOperationCount: u64,
	WriteOperationCount: u64,
	OtherOperationCount: u64,
	ReadTransferCount: u64,
	WriteTransferCount: u64,
	OtherTransferCount: u64,
}

@(private)
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: w.LARGE_INTEGER,
	PerJobUserTimeLimit: w.LARGE_INTEGER,
	LimitFlags: w.DWORD,
	MinimumWorkingSetSize: w.SIZE_T,
	MaximumWorkingSetSize: w.SIZE_T,
	ActiveProcessLimit: w.DWORD,
	Affinity: w.ULONG_PTR,
	PriorityClass: w.DWORD,
	SchedulingClass: w.DWORD,
}

@(private)
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo: IO_COUNTERS,
	ProcessMemoryLimit: w.SIZE_T,
	JobMemoryLimit: w.SIZE_T,
	PeakProcessMemoryUsed: w.SIZE_T,
	PeakJobMemoryUsed: w.SIZE_T,
}

@(private, default_calling_convention = "system")
foreign kernel32 {
	CreatePseudoConsole :: proc(
		size: w.COORD, hInput, hOutput: w.HANDLE, dwFlags: w.DWORD, phPC: ^HPCON,
	) -> w.HRESULT ---
	ResizePseudoConsole :: proc(hPC: HPCON, size: w.COORD) -> w.HRESULT ---
	ClosePseudoConsole :: proc(hPC: HPCON) ---
	InitializeProcThreadAttributeList :: proc(
		lpAttributeList: rawptr, dwAttributeCount, dwFlags: w.DWORD, lpSize: ^w.SIZE_T,
	) -> w.BOOL ---
	UpdateProcThreadAttribute :: proc(
		lpAttributeList: rawptr, dwFlags: w.DWORD, Attribute: w.DWORD_PTR,
		lpValue: rawptr, cbSize: w.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^w.SIZE_T,
	) -> w.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
	CreateJobObjectW :: proc(lpJobAttributes: w.LPSECURITY_ATTRIBUTES, lpName: w.LPCWSTR) -> w.HANDLE ---
	SetInformationJobObject :: proc(
		hJob: w.HANDLE, JobObjectInformationClass: i32,
		lpJobObjectInformation: rawptr, cbJobObjectInformationLength: w.DWORD,
	) -> w.BOOL ---
	AssignProcessToJobObject :: proc(hJob, hProcess: w.HANDLE) -> w.BOOL ---
	TerminateJobObject :: proc(hJob: w.HANDLE, uExitCode: w.UINT) -> w.BOOL ---
	CompareStringOrdinal :: proc(
		lpString1: ^u16, cchCount1: i32, lpString2: ^u16, cchCount2: i32, bIgnoreCase: w.BOOL,
	) -> i32 ---
}

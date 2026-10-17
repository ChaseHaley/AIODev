package pty

import "core:log"
import "core:sync"
import w "core:sys/windows"

// Tells the bundled OpenConsole to measure text by grapheme cluster, matching libghostty with
// mode 2027 (D-042). The system ConPTY measures per codepoint and rewrites full-screen rows
// with those widths, so emoji sequences drift (D-043).
@(private) PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES :: 0x08

@(private)
Conpty :: struct {
	create: proc "system" (size: w.COORD, input, output: w.HANDLE, flags: w.DWORD, console: ^HPCON) -> w.HRESULT,
	resize: proc "system" (console: HPCON, size: w.COORD) -> w.HRESULT,
	close: proc "system" (console: HPCON),
	bundled: bool,
}

@(private) conpty_api: Conpty
@(private) conpty_once: sync.Once

// The ConPTY every console in this process uses: conpty.dll beside the executable (which starts
// the OpenConsole.exe beside it) when present, otherwise the system ConPTY in kernel32.
@(private)
conpty :: proc() -> ^Conpty {
	sync.once_do(&conpty_once, conpty_load)
	return &conpty_api
}

// Reports whether consoles use the bundled ConPTY with grapheme widths.
bundled_conpty :: proc() -> bool {
	return conpty().bundled
}

@(private)
conpty_load :: proc() {
	conpty_api = {CreatePseudoConsole, ResizePseudoConsole, ClosePseudoConsole, false}
	path: [w.MAX_PATH + 16]u16
	n := int(w.GetModuleFileNameW(nil, &path[0], w.MAX_PATH))
	if n == 0 || n >= w.MAX_PATH {
		log.warn("pty: locating the executable failed; using the system ConPTY")
		return
	}
	for n > 0 && path[n - 1] != '\\' && path[n - 1] != '/' {
		n -= 1
	}
	for c, i in "conpty.dll" {
		path[n + i] = u16(c)
	}
	path[n + len("conpty.dll")] = 0
	module := w.LoadLibraryW(cstring16(&path[0]))
	if module == nil {
		log.warnf("pty: conpty.dll is not beside the executable (error %d); using the system ConPTY", w.GetLastError())
		return
	}
	create := w.GetProcAddress(module, "ConptyCreatePseudoConsole")
	resize := w.GetProcAddress(module, "ConptyResizePseudoConsole")
	close := w.GetProcAddress(module, "ConptyClosePseudoConsole")
	if create == nil || resize == nil || close == nil {
		log.warn("pty: conpty.dll lacks the ConPTY entry points; using the system ConPTY")
		w.FreeLibrary(module)
		return
	}
	conpty_api = {
		create = auto_cast create,
		resize = auto_cast resize,
		close = auto_cast close,
		bundled = true,
	}
}

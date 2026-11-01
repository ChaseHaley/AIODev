package platform

import "core:log"
import w "core:sys/windows"

foreign import icons_shell32 "system:shell32.lib"
foreign import icons_user32 "system:user32.lib"

@(private, default_calling_convention = "system")
foreign icons_shell32 {
	SHDefExtractIconW :: proc(
		pszIconFile: w.LPCWSTR,
		iIndex: w.INT,
		uFlags: w.UINT,
		phiconLarge, phiconSmall: ^w.HICON,
		nIconSize: w.UINT,
	) -> w.HRESULT ---
}

@(private, default_calling_convention = "system")
foreign icons_user32 {
	GetIconInfo :: proc(hIcon: w.HICON, piconinfo: ^w.ICONINFO) -> w.BOOL ---
}

EXECUTABLE_ICON_MAX :: 256

// Reads an executable's own first icon at size x size into premultiplied RGBA. A file without an
// icon resource returns false rather than the generic application icon, so callers can fall back
// to something more specific. Blocking file I/O: call it away from the UI thread.
@(require_results)
executable_icon :: proc(path: string, size: int, pixels: []u8) -> bool {
	if size < 1 || size > EXECUTABLE_ICON_MAX || len(pixels) < size * size * 4 {return false}
	wide: [4096]u16
	name := w.utf8_to_wstring_buf(wide[:], path)
	if name == nil {return false}
	icon: w.HICON
	if SHDefExtractIconW(name, 0, 0, &icon, nil, w.UINT(size)) != w.S_OK || icon == nil {return false}
	defer if !bool(w.DestroyIcon(icon)) {log.errorf("DestroyIcon failed: %v", w.GetLastError())}
	info: w.ICONINFO
	if !bool(GetIconInfo(icon, &info)) {
		log.errorf("GetIconInfo failed: %v", w.GetLastError())
		return false
	}
	defer if info.hbmColor != nil {w.DeleteObject(w.HGDIOBJ(info.hbmColor))}
	defer if info.hbmMask != nil {w.DeleteObject(w.HGDIOBJ(info.hbmMask))}
	if info.hbmColor == nil {return false}
	bitmap: w.BITMAP
	if w.GetObjectW(w.HANDLE(info.hbmColor), size_of(bitmap), &bitmap) == 0 ||
	   int(bitmap.bmWidth) != size ||
	   int(bitmap.bmHeight) != size {return false}
	dc := w.CreateCompatibleDC(nil)
	if dc == nil {log.errorf("CreateCompatibleDC failed: %v", w.GetLastError()); return false}
	defer w.DeleteDC(dc)
	header := w.BITMAPINFO {
		bmiHeader = {
			biSize = size_of(w.BITMAPINFOHEADER),
			biWidth = w.LONG(size),
			biHeight = -w.LONG(size),
			biPlanes = 1,
			biBitCount = 32,
			biCompression = w.BI_RGB,
		},
	}
	rgba := pixels[:size * size * 4]
	if w.GetDIBits(dc, info.hbmColor, 0, w.UINT(size), raw_data(rgba), &header, w.DIB_RGB_COLORS) !=
	   w.INT(size) {return false}
	has_alpha := false
	for i := 3; i < len(rgba); i += 4 {has_alpha ||= rgba[i] != 0}
	if !has_alpha {
		// Icons without an alpha channel carry transparency in the AND mask, where set bits are clear.
		mask := make([]u8, size * size * 4, context.allocator)
		defer delete(mask)
		if info.hbmMask == nil ||
		   w.GetDIBits(dc, info.hbmMask, 0, w.UINT(size), raw_data(mask), &header, w.DIB_RGB_COLORS) !=
			   w.INT(size) {return false}
		for i := 0; i < len(rgba); i += 4 {rgba[i + 3] = mask[i] == 0 ? 255 : 0}
	}
	for i := 0; i < len(rgba); i += 4 {
		b, g, r, a := u32(rgba[i]), u32(rgba[i + 1]), u32(rgba[i + 2]), u32(rgba[i + 3])
		rgba[i] = u8((r * a + 127) / 255)
		rgba[i + 1] = u8((g * a + 127) / 255)
		rgba[i + 2] = u8((b * a + 127) / 255)
	}
	return true
}

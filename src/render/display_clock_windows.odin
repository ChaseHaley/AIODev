package render

import win "core:sys/windows"
import "core:time"

// The compositor runs on one clock, the fastest display's, and shows a window on a slower display at that
// display's own vblanks, taking the compositor frame just before each. Swap chain statistics only see the
// compositor's clock, so a window on such a display must be built for that display's vblanks instead,
// or the frames it shows would be unevenly spaced in motion time (on a 144 Hz display beside a 240 Hz
// one, three of every five compositor frames reach it). The compositor's per-display statistics
// (Windows 11) give each display's vblanks; elsewhere the window keeps the compositor's grid.
Display_Clock :: struct {
	// The monitor the window was last on, and how the compositor names that display.
	monitor:   win.HMONITOR,
	target:    Display_Target,
	// The display refreshes with the compositor, decided against this compositor period, so there is
	// nothing to read until the window moves or the compositor's refresh changes.
	same:      time.Duration,
	// A recent vblank of that display and its period; zero period when the compositor's grid is the
	// window's display grid.
	vblank:    time.Tick,
	period:    time.Duration,
}

@(private)
Display_Target :: struct {
	luid:   win.LUID,
	source: u32,
	known:  bool,
}

// A display's period this close to the compositor's is the compositor's own display.
@(private = "file")
DISPLAY_PERIOD_TOLERANCE :: 20

// Follows the window to its display and reads that display's latest vblank from the compositor.
@(private)
display_clock_sample :: proc(c: ^Display_Clock, window: win.HWND, compositor_period: time.Duration) {
	monitor := win.MonitorFromWindow(window, .MONITOR_DEFAULTTONEAREST)
	if monitor != c.monitor {
		c^ = {monitor = monitor, target = display_target(monitor)}
	}
	if !c.target.known || compositor_period == 0 {return}
	if c.same > 0 && abs(c.same - compositor_period) * DISPLAY_PERIOD_TOLERANCE < compositor_period {return}
	stats, found := display_target_stats(c.target)
	if !found || stats.vblankDuration == 0 {
		c.period = 0
		return
	}
	period := time.tick_diff(qpc_tick(0), qpc_tick(i64(stats.vblankDuration)))
	if abs(period - compositor_period) * DISPLAY_PERIOD_TOLERANCE < compositor_period {
		c.period, c.same = 0, compositor_period
		return
	}
	c.vblank, c.period = qpc_tick(i64(stats.presentedStats.time)), period
}

// The display's vblank that shows a frame the compositor takes at `composed`: the compositor composes at
// its tick and each display shows the newest composition at its own next vblank.
@(private)
display_clock_after :: proc(c: Display_Clock, composed: time.Tick) -> time.Tick {
	since := time.tick_diff(c.vblank, composed)
	refreshes := since >= 0 ? i64(since / c.period) + 1 : 0
	return time.tick_add(c.vblank, time.Duration(refreshes) * c.period)
}

// The adapter and video source that drive `monitor`, as the compositor names its targets.
@(private = "file")
display_target :: proc(monitor: win.HMONITOR) -> Display_Target {
	info := win.MONITORINFOEXW {
		cbSize = size_of(win.MONITORINFOEXW),
	}
	if !win.GetMonitorInfoW(monitor, (^win.MONITORINFO)(&info)) {return {}}
	open := D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME {
		DeviceName = info.szDevice,
	}
	if D3DKMTOpenAdapterFromGdiDisplayName(&open) != 0 {return {}}
	close := D3DKMT_CLOSEADAPTER {
		hAdapter = open.hAdapter,
	}
	_ = D3DKMTCloseAdapter(&close)
	return {open.AdapterLuid, open.VidPnSourceId, true}
}

// The compositor's statistics for `target` in its last completed frame.
@(private = "file")
display_target_stats :: proc(target: Display_Target) -> (stats: COMPOSITION_TARGET_STATS, found: bool) {
	api := dcomp_statistics()
	if api == nil {return}
	frame: u64
	if FAILED(api.get_frame_id(.COMPLETED, &frame)) {return}
	frame_stats: COMPOSITION_FRAME_STATS
	targets: [8]COMPOSITION_TARGET_ID
	count: u32
	if FAILED(api.get_statistics(frame, &frame_stats, len(targets), &targets[0], &count)) {return}
	for &id in targets[:min(int(count), len(targets))] {
		if id.vidPnSourceId != target.source || id.displayAdapterLuid != target.luid {continue}
		return stats, !FAILED(api.get_target_statistics(frame, &id, &stats))
	}
	return
}

@(private = "file")
COMPOSITION_FRAME_ID_TYPE :: enum i32 {
	CREATED   = 0,
	CONFIRMED = 1,
	COMPLETED = 2,
}

@(private = "file")
COMPOSITION_FRAME_STATS :: struct {
	startTime, targetTime, framePeriod: u64,
}

@(private = "file")
COMPOSITION_TARGET_ID :: struct {
	displayAdapterLuid, renderAdapterLuid: win.LUID,
	vidPnSourceId, vidPnTargetId, uniqueId: u32,
}

@(private = "file")
COMPOSITION_STATS :: struct {
	presentCount, refreshCount, virtualRefreshCount: u32,
	time:                                            u64,
}

@(private = "file")
COMPOSITION_TARGET_STATS :: struct {
	outstandingPresents:            u32,
	presentTime, vblankDuration:    u64,
	presentedStats, completedStats: COMPOSITION_STATS,
}

// The compositor statistics exist from Windows 11 (build 22000), so they are looked up at run time.
@(private = "file")
Dcomp_Statistics :: struct {
	get_frame_id:          proc "system" (kind: COMPOSITION_FRAME_ID_TYPE, id: ^u64) -> win.HRESULT,
	get_statistics:        proc "system" (
		frame: u64,
		stats: ^COMPOSITION_FRAME_STATS,
		count: u32,
		targets: [^]COMPOSITION_TARGET_ID,
		actual: ^u32,
	) -> win.HRESULT,
	get_target_statistics: proc "system" (
		frame: u64,
		target: ^COMPOSITION_TARGET_ID,
		stats: ^COMPOSITION_TARGET_STATS,
	) -> win.HRESULT,
}

@(private = "file")
dcomp_statistics :: proc() -> ^Dcomp_Statistics {
	@(static) api: Dcomp_Statistics
	@(static) loaded: bool
	if !loaded {
		loaded = true
		module := win.LoadLibraryW(win.L("dcomp.dll"))
		if module != nil {
			api.get_frame_id = auto_cast win.GetProcAddress(module, "DCompositionGetFrameId")
			api.get_statistics = auto_cast win.GetProcAddress(module, "DCompositionGetStatistics")
			target := win.GetProcAddress(module, "DCompositionGetTargetStatistics")
			api.get_target_statistics = auto_cast target
		}
	}
	if api.get_frame_id == nil || api.get_statistics == nil || api.get_target_statistics == nil {return nil}
	return &api
}

@(private = "file")
D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME :: struct {
	DeviceName:    [32]u16,
	hAdapter:      u32,
	AdapterLuid:   win.LUID,
	VidPnSourceId: u32,
}

@(private = "file")
D3DKMT_CLOSEADAPTER :: struct {
	hAdapter: u32,
}

foreign import gdi32 "system:gdi32.lib"

@(private = "file", default_calling_convention = "system")
foreign gdi32 {
	D3DKMTOpenAdapterFromGdiDisplayName :: proc(open: ^D3DKMT_OPENADAPTERFROMGDIDISPLAYNAME) -> i32 ---
	D3DKMTCloseAdapter :: proc(close: ^D3DKMT_CLOSEADAPTER) -> i32 ---
}


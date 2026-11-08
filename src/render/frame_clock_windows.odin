package render

import win "core:sys/windows"
import "core:log"
import "core:time"
import "vendor:directx/dxgi"

// When a swap chain's frames reach the screen. The swap chain's statistics place its output's vblanks
// on the performance counter clock and measure their period, so a frame can be built for the vblank
// that will show it. That one prediction is the whole of frame pacing: every motion samples at it, so
// each frame on screen is exactly one refresh further on than the one before.
Frame_Clock :: struct {
	// A recent vblank on the window's output and the swap chain's running count for it.
	vblank:       time.Tick,
	vblank_count: u32,
	// Where the current measurement of the period began; zero until the statistics give a vblank.
	origin:       time.Tick,
	origin_count: u32,
	// Zero while no display has reported a refresh.
	period:       time.Duration,
	// The compositor tick and the display time the last presented frame was built for; zero before the
	// first. `presented_late` when that frame was built for the vblank after the one it was due, which it
	// may still have made. `resumed` counts the resuming frames presented in a row.
	presented, presented_display: time.Tick,
	presented_late: bool,
	resumed:      int,
	// The window's display, when it keeps its own vblanks apart from the compositor's.
	display:      Display_Clock,
	// How long before its vblank a present must return for the compositor to take it at that vblank,
	// learned from presents that missed and presents that made it; DEADLINE_PRIOR until one teaches it.
	deadline:     time.Duration,
	// When frames that left plenty of time reached the screen, after the instant they were built for;
	// the reference that tells a present that missed from one that made it.
	latency:      Maybe(time.Duration),
	// How long a frame takes from its prediction to the return of its present, as a slowly decaying
	// maximum so one heavy frame keeps later estimates cautious, and when the frame now being built was
	// predicted.
	build:        time.Duration,
	predicted_at: time.Tick,
	// The swap chain has room for one more frame, taken by the main loop's wait or by frame_acquire.
	acquired:     bool,
	// The last displayed present the statistics reported, for counting repeated vblanks.
	shown:        Frame_Shown,
	history:      [FRAME_HISTORY]Frame_Record,
	report:       Frame_Report,
}

// How well animation frames met the display, counted from the swap chain's own statistics. A frame-
// perfect animation shows every animated frame on its own vblank (`repeated` stays zero) and every
// frame lands the same distance after the moment it was built for (`offset_min` equals `offset_max`
// to within the counter's jitter).
Frame_Report :: struct {
	// Presents built while something moved, and how many of them the display has confirmed showing.
	animated, confirmed: u64,
	// Vblanks on which an animation left the previous frame on screen.
	repeated:            u64,
	// On a display that keeps its own vblanks: its vblanks that no animated frame was built for. Every
	// composition shown there is the newest before that display's vblank, so with none skipped each of
	// its vblanks shows a frame built for exactly that vblank.
	display_skipped:     u64,
	// When confirmed animated frames reached the screen, less the display time they were built for.
	offset_min, offset_max: time.Duration,
}

// The period is measured over at least this many refreshes before it replaces the reported one.
@(private)
PERIOD_MEASURE_REFRESHES :: 60

// Enough presents to cover the swap chain's queue and the statistics' delay several times over.
@(private)
FRAME_HISTORY :: 32

@(private)
Frame_Record :: struct {
	present:  u32,
	display:  time.Tick,
	animated: bool,
	// Built for the vblank after the one it was due (see Frame_Time.late).
	late:     bool,
	// How long before `display` the present returned.
	ahead:    time.Duration,
}

// A pause, then frames woken late by a busy main thread: up to four in a row may wait before motions
// start, a frame at 60 Hz.
@(private)
RESUMING_FRAMES :: 4

// What the compositor is assumed to need before a vblank until presents measure it. Composed windows
// were seen to miss with 0.55 ms to spare and directly flipped ones to make it with 0.54 ms.
@(private)
DEADLINE_PRIOR :: 500 * time.Microsecond

// Room left above the latest present that missed.
@(private)
DEADLINE_MARGIN :: 100 * time.Microsecond

@(private)
Frame_Shown :: struct {
	present, refresh: u32,
	valid:            bool,
}

// Takes the frame the swap chain has room for, waiting up to timeout_ms. A nonzero wait that times out
// still lets the caller draw, so a stalled compositor cannot freeze the window; with 0 the caller draws
// only when room is there. A surface without a swap chain is always ready. The main loop passes 0 and
// waits on frame_waitable instead.
@(require_results)
frame_acquire :: proc(s: ^Surface, timeout_ms: u32) -> (ready: bool, err: Error) {
	if s.clock.acquired || s.waitable == nil {return true, .None}
	switch win.WaitForSingleObject(s.waitable, timeout_ms) {
	case win.WAIT_OBJECT_0:
		frame_signaled(s)
		return true, .None
	case win.WAIT_TIMEOUT:
		return timeout_ms > 0, .None
	case:
		log.errorf("WaitForSingleObject frame latency failed: %d", win.GetLastError())
		return true, .Wait_Failed
	}
}

// The handle that signals when the swap chain has room for a frame, for the main loop to wait on
// beside its messages; nil when the surface needs no wait.
frame_waitable :: proc(s: ^Surface) -> rawptr {
	if s.clock.acquired {return nil}
	return rawptr(s.waitable)
}

// The main loop's wait consumed the swap chain's signal: the next frame may draw without waiting.
frame_signaled :: proc(s: ^Surface) {
	s.clock.acquired = true
	frame_clock_sample(s)
}

// When the frame built now will be on screen; see frame_clock_predict.
frame_predict :: proc(s: ^Surface, now: time.Tick) -> Frame_Time {
	if s.chain == nil {return {display = now, period = FRAME_PERIOD_DEFAULT}}
	if s.clock.period == 0 {frame_clock_compositor(&s.clock)}
	s.clock.predicted_at = now
	return frame_clock_predict(s.clock, now)
}

// The frame built now will be on screen at the first vblank after `now`, or one refresh after the last
// presented frame if that one is not on screen yet, so consecutive frames are one refresh apart even
// when the loop wakes early. A frame that missed its vblank is built for the next one, not the missed
// one, so motion catches up instead of falling behind. Without a known refresh the frame shows now.
frame_clock_predict :: proc(c: Frame_Clock, now: time.Tick) -> Frame_Time {
	if c.period == 0 {return {display = now, period = FRAME_PERIOD_DEFAULT}}
	since := time.tick_diff(c.vblank, now)
	refreshes := since >= 0 ? i64(since / c.period) + 1 : 0
	next := time.tick_add(c.vblank, time.Duration(refreshes) * c.period)
	// The earliest vblank the last frame can hold; a late one may have made the vblank it was due.
	held := time.tick_add(c.presented, c.presented_late ? -c.period : 0)
	if c.presented != {} && time.tick_diff(held, next) <= 0 {
		// The last frame still holds that vblank, so this one takes the next. Presents faster than the
		// display (a timed-out wait) cannot push frames further ahead than that.
		next = time.tick_add(next, c.period)
	}
	deadline := c.deadline > 0 ? c.deadline : min(DEADLINE_PRIOR, c.period / 4)
	late := time.tick_diff(now, next) - c.build < deadline
	if late {
		// Built too late for the compositor to take it at that vblank, it shows at the next one; built
		// for that one, it still shows the right instant, and the frame before it stays a refresh longer.
		next = time.tick_add(next, c.period)
	}
	// A frame resumes after a pause in presenting, or when it is late or starts with less than half a
	// refresh to spare: whether the compositor takes it at its vblank is uncertain, so no motion starts
	// on it. At most RESUMING_FRAMES resume in a row, so a window too slow to draw back to back still
	// starts its motions.
	paused := c.presented == {} || time.tick_diff(c.presented, next) > c.period + c.period / 2
	tight := time.tick_diff(now, next) - c.build < c.period / 2
	resuming := (paused || late || tight) && c.resumed < RESUMING_FRAMES
	if c.display.period == 0 {return {next, c.period, resuming, next, late}}
	shown := display_clock_after(c.display, next)
	// Frames that land on the same display vblank show the same instant; the newest is shown.
	period := c.display.period
	paused = c.presented_display == {} || time.tick_diff(c.presented_display, shown) > period + period / 2
	resuming = (paused || late || tight) && c.resumed < RESUMING_FRAMES
	return {shown, period, resuming, next, late}
}

// Records a present: which display time it was built for, and whether it showed motion.
frame_presented :: proc(s: ^Surface, frame: Frame_Time, animated: bool) {
	c := &s.clock
	c.acquired = false
	composed := frame.composed != {} ? frame.composed : frame.display
	if animated && c.display.period > 0 && c.presented_display != {} {
		// Whole display periods between consecutive animated frames, less the one that should be there.
		gap := (time.tick_diff(c.presented_display, frame.display) + frame.period / 2) / frame.period
		if gap > 1 {c.report.display_skipped += u64(gap - 1)}
	}
	c.presented, c.presented_display, c.presented_late = composed, frame.display, frame.late
	c.resumed = frame.resuming ? c.resumed + 1 : 0
	if s.chain == nil {return}
	end := time.tick_now()
	if c.predicted_at != {} {c.build = max(time.tick_diff(c.predicted_at, end), c.build - c.build / 8)}
	count: u32
	if FAILED(s.chain->GetLastPresentCount(&count)) {return}
	c.history[count % FRAME_HISTORY] = {count, composed, animated, frame.late, time.tick_diff(end, composed)}
	if animated {c.report.animated += 1}
}

frame_report :: proc(s: ^Surface) -> Frame_Report {
	frame_clock_sample(s)
	return s.clock.report
}

frame_report_reset :: proc(s: ^Surface) {
	s.clock.report = {}
}

// The refresh period of the window's display, or zero while unknown.
frame_period :: proc(s: ^Surface) -> time.Duration {
	return s.clock.display.period > 0 ? s.clock.display.period : s.clock.period
}

// Reads the swap chain's statistics: a fresh vblank for the grid, a longer measurement of the period,
// and, for the last displayed present, whether it repeated a vblank and when it showed.
@(private)
frame_clock_sample :: proc(s: ^Surface) {
	if s.chain == nil {return}
	c := &s.clock
	stats: dxgi.FRAME_STATISTICS
	if FAILED(s.chain->GetFrameStatistics(&stats)) {
		// Disjoint or not yet available: the counts restart, so does every measurement.
		c.origin, c.shown = {}, {}
		return
	}
	frame_clock_vblank(c, qpc_tick(i64(stats.SyncQPCTime)), stats.SyncRefreshCount)
	if c.period == 0 {frame_clock_compositor(c)}
	frame_clock_account(c, stats.PresentCount, stats.PresentRefreshCount)
	display_clock_sample(&c.display, s.window, c.period)
}

// Moves the grid to a vblank the compositor reported, with its running count, and measures the period
// over at least PERIOD_MEASURE_REFRESHES. When the compositor changes its refresh, the latest step stands
// in until a new measurement is long enough to replace it.
frame_clock_vblank :: proc(c: ^Frame_Clock, vblank: time.Tick, count: u32) {
	if c.origin == {} || count < c.origin_count {
		c.origin, c.origin_count = vblank, count
	} else if c.period > 0 && count > c.vblank_count {
		step := time.tick_diff(c.vblank, vblank) / time.Duration(count - c.vblank_count)
		if abs(step - c.period) > c.period / 8 {
			c.origin, c.origin_count, c.period = c.vblank, c.vblank_count, step
		}
	}
	c.vblank, c.vblank_count = vblank, count
	if measured := count - c.origin_count; measured >= PERIOD_MEASURE_REFRESHES {
		c.period = time.tick_diff(c.origin, vblank) / time.Duration(measured)
	}
}

@(private)
frame_clock_account :: proc(c: ^Frame_Clock, present, refresh: u32) {
	previous := c.shown
	c.shown = {present, refresh, true}
	if !previous.valid || present == previous.present || c.period == 0 {return}
	shown := c.history[present % FRAME_HISTORY]
	if shown.present != present {return}
	at := time.tick_add(c.vblank, time.Duration(i64(refresh) - i64(c.vblank_count)) * c.period)
	offset := time.tick_diff(shown.display, at)
	// A late frame teaches what the vblank it was due would have done.
	due := shown.late ? c.period : 0
	frame_clock_learn(c, shown.ahead - due, offset + due)
	if !shown.animated {return}
	before := c.history[previous.present % FRAME_HISTORY]
	presents, refreshes := present - previous.present, refresh - previous.refresh
	if before.present == previous.present && before.animated && refreshes > presents {
		c.report.repeated += u64(refreshes - presents)
	}
	if c.report.confirmed == 0 || offset < c.report.offset_min {c.report.offset_min = offset}
	if c.report.confirmed == 0 || offset > c.report.offset_max {c.report.offset_max = offset}
	c.report.confirmed += 1
}

// A present that left more than half a refresh is on time and sets the reference latency. One that left
// less and showed a refresh later than that missed its vblank, so presents need more time than it left;
// one that left less than thought needed and still made it shows they need less.
@(private)
frame_clock_learn :: proc(c: ^Frame_Clock, ahead, offset: time.Duration) {
	if ahead > c.period / 2 {
		c.latency = offset
		return
	}
	latency, known := c.latency.?
	if !known {return}
	if offset > latency + c.period / 2 {
		c.deadline = max(c.deadline, ahead + DEADLINE_MARGIN)
	} else if c.deadline > 0 && ahead < c.deadline {
		c.deadline = max(ahead, 0)
	}
}

// Until the swap chain has shown frames, the compositor's clock gives the grid and the period.
@(private)
frame_clock_compositor :: proc(c: ^Frame_Clock) {
	info := DWM_TIMING_INFO {
		cbSize = size_of(DWM_TIMING_INFO),
	}
	if FAILED(DwmGetCompositionTimingInfo(nil, &info)) || info.qpcRefreshPeriod == 0 {return}
	c.vblank = qpc_tick(i64(info.qpcVBlank))
	c.period = time.tick_diff(qpc_tick(0), qpc_tick(i64(info.qpcRefreshPeriod)))
}

// A performance counter reading on time.tick_now's scale.
@(private)
qpc_tick :: proc(counter: i64) -> time.Tick {
	@(static) frequency: win.LARGE_INTEGER
	if frequency == 0 {win.QueryPerformanceFrequency(&frequency)}
	f := i64(frequency)
	return {(counter / f) * 1e9 + (counter % f) * 1e9 / f}
}

@(private)
FAILED :: proc(hr: win.HRESULT) -> bool {
	return hr < 0
}

foreign import dwmapi "system:dwmapi.lib"

@(private, default_calling_convention = "system")
foreign dwmapi {
	DwmGetCompositionTimingInfo :: proc(hwnd: win.HWND, info: ^DWM_TIMING_INFO) -> win.HRESULT ---
}

// dwmapi.h packs its structures to one byte.
@(private)
DWM_TIMING_INFO :: struct #packed {
	cbSize:                 u32,
	rateRefresh:            [2]u32,
	qpcRefreshPeriod:       u64,
	rateCompose:            [2]u32,
	qpcVBlank:              u64,
	cRefresh:               u64,
	cDXRefresh:             u32,
	qpcCompose:             u64,
	cFrame:                 u64,
	cDXPresent:             u32,
	cRefreshFrame:          u64,
	cFrameSubmitted:        u64,
	cDXPresentSubmitted:    u32,
	cFrameConfirmed:        u64,
	cDXPresentConfirmed:    u32,
	cRefreshConfirmed:      u64,
	cDXRefreshConfirmed:    u32,
	cFramesLate:            u64,
	cFramesOutstanding:     u32,
	cFrameDisplayed:        u64,
	qpcFrameDisplayed:      u64,
	cRefreshFrameDisplayed: u64,
	cFrameComplete:         u64,
	qpcFrameComplete:       u64,
	cFramePending:          u64,
	qpcFramePending:        u64,
	cFramesDisplayed:       u64,
	cFramesComplete:        u64,
	cFramesPending:         u64,
	cFramesAvailable:       u64,
	cFramesDropped:         u64,
	cFramesMissed:          u64,
	cRefreshNextDisplayed:  u64,
	cRefreshNextPresented:  u64,
	cRefreshesDisplayed:    u64,
	cRefreshesPresented:    u64,
	cRefreshStarted:        u64,
	cPixelsReceived:        u64,
	cPixelsDrawn:           u64,
	cBuffersEmpty:          u64,
}

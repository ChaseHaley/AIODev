#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>
#include "WebView2.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <string>
#include <vector>

namespace {

template <typename T>
class Com_Ptr {
public:
    Com_Ptr() noexcept = default;
    ~Com_Ptr() noexcept { reset(); }
    Com_Ptr(const Com_Ptr &other) noexcept : ptr_(other.ptr_) {
        if (ptr_) ptr_->AddRef();
    }
    Com_Ptr(Com_Ptr &&other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
    Com_Ptr &operator=(const Com_Ptr &other) noexcept {
        if (this != &other) {
            reset();
            ptr_ = other.ptr_;
            if (ptr_) ptr_->AddRef();
        }
        return *this;
    }
    Com_Ptr &operator=(Com_Ptr &&other) noexcept {
        if (this != &other) {
            reset();
            ptr_ = other.ptr_;
            other.ptr_ = nullptr;
        }
        return *this;
    }
    void reset() noexcept {
        if (ptr_) {
            ptr_->Release();
            ptr_ = nullptr;
        }
    }
    T *get() const noexcept { return ptr_; }
    T *operator->() const noexcept { return ptr_; }
    explicit operator bool() const noexcept { return ptr_ != nullptr; }
    T **put() noexcept {
        reset();
        return &ptr_;
    }
    void **put_void() noexcept { return reinterpret_cast<void **>(put()); }

private:
    T *ptr_ = nullptr;
};

template <template <typename> class T, typename Fn>
static Com_Ptr<T<Fn>> make_handler(Fn &&fn) {
    Com_Ptr<T<Fn>> ptr;
    *ptr.put() = new T<Fn>(std::forward<Fn>(fn));
    return ptr;
}

// Concrete callback wrappers for the exact WebView2 handler interfaces we register.
#define DEFINE_WV2_HANDLER_2(Name, Iface, A1, A2)                                      \
    template <typename Fn>                                                             \
    class Name final : public Iface {                                                  \
    public:                                                                            \
        explicit Name(Fn fn) : fn_(std::move(fn)) {}                                   \
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {\
            if (!object) return E_POINTER;                                             \
            if (riid == IID_IUnknown || riid == __uuidof(Iface)) {                     \
                *object = static_cast<Iface *>(this);                                  \
                AddRef();                                                              \
                return S_OK;                                                           \
            }                                                                          \
            *object = nullptr;                                                         \
            return E_NOINTERFACE;                                                      \
        }                                                                              \
        ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }                  \
        ULONG STDMETHODCALLTYPE Release() override {                                   \
            auto n = --refs_;                                                          \
            if (n == 0) delete this;                                                   \
            return n;                                                                  \
        }                                                                              \
        HRESULT STDMETHODCALLTYPE Invoke(A1 a1, A2 a2) override { return fn_(a1, a2); }\
    private:                                                                           \
        std::atomic<ULONG> refs_{1};                                                   \
        Fn fn_;                                                                        \
    };

// The same wrapper for completion handlers that take only an HRESULT.
#define DEFINE_WV2_HANDLER_1(Name, Iface, A1)                                          \
    template <typename Fn>                                                             \
    class Name final : public Iface {                                                  \
    public:                                                                            \
        explicit Name(Fn fn) : fn_(std::move(fn)) {}                                   \
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {\
            if (!object) return E_POINTER;                                             \
            if (riid == IID_IUnknown || riid == __uuidof(Iface)) {                     \
                *object = static_cast<Iface *>(this);                                  \
                AddRef();                                                              \
                return S_OK;                                                           \
            }                                                                          \
            *object = nullptr;                                                         \
            return E_NOINTERFACE;                                                      \
        }                                                                              \
        ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }                  \
        ULONG STDMETHODCALLTYPE Release() override {                                   \
            auto n = --refs_;                                                          \
            if (n == 0) delete this;                                                   \
            return n;                                                                  \
        }                                                                              \
        HRESULT STDMETHODCALLTYPE Invoke(A1 a1) override { return fn_(a1); }           \
    private:                                                                           \
        std::atomic<ULONG> refs_{1};                                                   \
        Fn fn_;                                                                        \
    };

DEFINE_WV2_HANDLER_1(Find_Started_Handler, ICoreWebView2FindStartCompletedHandler, HRESULT)

DEFINE_WV2_HANDLER_2(Env_Completed_Handler, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
                     HRESULT, ICoreWebView2Environment *)
DEFINE_WV2_HANDLER_2(Comp_Completed_Handler,
                     ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler, HRESULT,
                     ICoreWebView2CompositionController *)
DEFINE_WV2_HANDLER_2(Nav_Starting_Handler, ICoreWebView2NavigationStartingEventHandler, ICoreWebView2 *,
                     ICoreWebView2NavigationStartingEventArgs *)
DEFINE_WV2_HANDLER_2(Nav_Completed_Handler, ICoreWebView2NavigationCompletedEventHandler, ICoreWebView2 *,
                     ICoreWebView2NavigationCompletedEventArgs *)
DEFINE_WV2_HANDLER_2(Source_Changed_Handler, ICoreWebView2SourceChangedEventHandler, ICoreWebView2 *,
                     ICoreWebView2SourceChangedEventArgs *)
DEFINE_WV2_HANDLER_2(History_Changed_Handler, ICoreWebView2HistoryChangedEventHandler, ICoreWebView2 *,
                     IUnknown *)
DEFINE_WV2_HANDLER_2(Title_Changed_Handler, ICoreWebView2DocumentTitleChangedEventHandler, ICoreWebView2 *,
                     IUnknown *)
DEFINE_WV2_HANDLER_2(New_Window_Handler, ICoreWebView2NewWindowRequestedEventHandler, ICoreWebView2 *,
                     ICoreWebView2NewWindowRequestedEventArgs *)
DEFINE_WV2_HANDLER_2(Cursor_Changed_Handler, ICoreWebView2CursorChangedEventHandler,
                     ICoreWebView2CompositionController *, IUnknown *)
DEFINE_WV2_HANDLER_2(Accel_Key_Handler, ICoreWebView2AcceleratorKeyPressedEventHandler,
                     ICoreWebView2Controller *, ICoreWebView2AcceleratorKeyPressedEventArgs *)
DEFINE_WV2_HANDLER_2(Focus_Changed_Handler, ICoreWebView2FocusChangedEventHandler,
                     ICoreWebView2Controller *, IUnknown *)
DEFINE_WV2_HANDLER_2(Zoom_Changed_Handler, ICoreWebView2ZoomFactorChangedEventHandler,
                     ICoreWebView2Controller *, IUnknown *)
DEFINE_WV2_HANDLER_2(Process_Failed_Handler, ICoreWebView2ProcessFailedEventHandler, ICoreWebView2 *,
                     ICoreWebView2ProcessFailedEventArgs *)
DEFINE_WV2_HANDLER_2(Permission_Handler, ICoreWebView2PermissionRequestedEventHandler, ICoreWebView2 *,
                     ICoreWebView2PermissionRequestedEventArgs *)
DEFINE_WV2_HANDLER_2(Download_Starting_Handler, ICoreWebView2DownloadStartingEventHandler, ICoreWebView2 *,
                     ICoreWebView2DownloadStartingEventArgs *)
DEFINE_WV2_HANDLER_2(Download_State_Handler, ICoreWebView2StateChangedEventHandler,
                     ICoreWebView2DownloadOperation *, IUnknown *)
DEFINE_WV2_HANDLER_2(Favicon_Changed_Handler, ICoreWebView2FaviconChangedEventHandler, ICoreWebView2 *,
                     IUnknown *)
DEFINE_WV2_HANDLER_2(Favicon_Completed_Handler, ICoreWebView2GetFaviconCompletedHandler, HRESULT, IStream *)
DEFINE_WV2_HANDLER_2(Find_Count_Handler, ICoreWebView2FindMatchCountChangedEventHandler, ICoreWebView2Find *,
                     IUnknown *)
DEFINE_WV2_HANDLER_2(Find_Index_Handler, ICoreWebView2FindActiveMatchIndexChangedEventHandler,
                     ICoreWebView2Find *, IUnknown *)

static std::string wide_to_utf8(const wchar_t *text) {
    if (!text || !text[0]) return {};
    int needed = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 1) return {};
    std::string out(static_cast<size_t>(needed - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), needed, nullptr, nullptr);
    return out;
}

// Match the app's explicit drive-path form. Never interpret a file authority as a local path.
static bool local_file_url(const wchar_t *uri) {
    if (!uri || _wcsnicmp(uri, L"file:///", 8) != 0) return false;
    const wchar_t *path = uri + 8;
    const wchar_t drive = path[0];
    if (!((drive >= L'A' && drive <= L'Z') || (drive >= L'a' && drive <= L'z')) ||
        path[1] != L':' || path[2] != L'/') return false;
    for (const wchar_t *c = path + 3; *c; ++c) {
        if (*c < 0x20 || *c == 0x7f || *c == L'\\') return false;
    }
    return true;
}

static bool web_url_allowed(const wchar_t *uri) {
    if (!uri) return false;
    return _wcsnicmp(uri, L"http://", 7) == 0 || _wcsnicmp(uri, L"https://", 8) == 0 ||
           _wcsicmp(uri, L"about:blank") == 0;
}

static bool url_allowed(const wchar_t *uri) {
    return web_url_allowed(uri) || local_file_url(uri);
}

// The most favicon bytes kept; a larger icon is dropped and the pane shows its globe.
constexpr size_t FAVICON_MAX_BYTES = 256 * 1024;

struct Overlay_Layer {
    Com_Ptr<IDCompositionVisual> visual;
    Com_Ptr<IDXGISwapChain1> chain;
    Com_Ptr<ID3D11RenderTargetView> rtv;
    int width = 0;
    int height = 0;
    bool attached = false;
};

// One window's DirectComposition tree. Above the HWND's own flip-model swap chain the levels stack bottom
// to top as web_roots[0], overlays[0], web_roots[1], overlays[1], ... Level 0 holds tiled web views; each
// floating group with a web view gets the next level, so a float drawn later (in a higher overlay) covers it.
struct Aio_Webview_Host {
    HWND hwnd = nullptr;
    Com_Ptr<ID3D11Device> d3d;
    Com_Ptr<ID3D11DeviceContext> ctx;
    Com_Ptr<IDXGIFactory2> factory;
    Com_Ptr<IDCompositionDevice> dcomp;
    Com_Ptr<IDCompositionTarget> target;
    Com_Ptr<IDCompositionVisual> root;
    std::vector<Com_Ptr<IDCompositionVisual>> web_roots;
    std::vector<Overlay_Layer> overlays;
};

// Grows the host to `count` levels; existing levels keep their order and contents.
static bool host_ensure_levels(Aio_Webview_Host *host, size_t count) {
    while (host->web_roots.size() < count) {
        Com_Ptr<IDCompositionVisual> web;
        Overlay_Layer layer;
        if (FAILED(host->dcomp->CreateVisual(web.put())) || !web) return false;
        if (FAILED(host->dcomp->CreateVisual(layer.visual.put())) || !layer.visual) return false;
        IDCompositionVisual *top = host->overlays.empty() ? nullptr : host->overlays.back().visual.get();
        if (FAILED(host->root->AddVisual(web.get(), top != nullptr, top))) return false;
        if (FAILED(host->root->AddVisual(layer.visual.get(), TRUE, web.get()))) {
            host->root->RemoveVisual(web.get());
            return false;
        }
        host->web_roots.push_back(std::move(web));
        host->overlays.push_back(std::move(layer));
    }
    return true;
}

static void overlay_release(Aio_Webview_Host *host, Overlay_Layer &layer) {
    if (layer.visual) layer.visual->SetContent(nullptr);
    layer.attached = false;
    layer.rtv.reset();
    if (layer.chain && host->ctx) {
        host->ctx->ClearState();
        host->ctx->Flush();
    }
    layer.chain.reset();
    layer.width = 0;
    layer.height = 0;
}

using Accel_Callback = bool (*)(void *user, uint32_t pane_id, uint32_t vk, uint32_t kind, int32_t lparam);

struct Aio_Webview;

struct Aio_Webview_Env {
    Com_Ptr<ICoreWebView2Environment> env;
    Com_Ptr<ICoreWebView2Environment3> env3;
    Com_Ptr<ICoreWebView2Environment15> env15;
    HWND wake_hwnd = nullptr;
    UINT wake_msg = 0;
    Accel_Callback accel_cb = nullptr;
    void *accel_user = nullptr;
    bool ready = false;
    bool failed = false;
    HRESULT error_hr = S_OK;
    std::vector<Aio_Webview *> pending;
    std::shared_ptr<std::atomic_bool> alive = std::make_shared<std::atomic_bool>(true);

    void wake() const {
        if (wake_hwnd && wake_msg) PostMessageW(wake_hwnd, wake_msg, 0, 0);
    }
};

// What a page did that the app reports as a notice, oldest first.
enum Note_Kind : int32_t {
    NOTE_NONE = 0,
    NOTE_DOWNLOAD_STARTED = 1,
    NOTE_DOWNLOAD_DONE = 2,
    NOTE_DOWNLOAD_FAILED = 3,
    NOTE_PERMISSION_DENIED = 4,
};

struct Note {
    int32_t kind = NOTE_NONE;
    int32_t detail = 0;
    std::string text;
};

// Why the page stopped: 0 none, 1 its renderer exited, 2 the browser process exited (the view must be
// created again), 3 its renderer stopped responding.
enum Crash_Kind : uint8_t {
    CRASH_NONE = 0,
    CRASH_RENDERER = 1,
    CRASH_BROWSER = 2,
    CRASH_UNRESPONSIVE = 3,
};

struct Aio_Webview {
    Aio_Webview_Env *env = nullptr;
    Aio_Webview_Host *host = nullptr;
    uint32_t pane_id = 0;
    std::shared_ptr<std::atomic_bool> alive = std::make_shared<std::atomic_bool>(true);

    Com_Ptr<ICoreWebView2CompositionController> comp;
    Com_Ptr<ICoreWebView2Controller> controller;
    Com_Ptr<ICoreWebView2Controller3> controller3;
    Com_Ptr<ICoreWebView2> webview;
    Com_Ptr<ICoreWebView2_13> webview13;
    Com_Ptr<ICoreWebView2_15> webview15;
    Com_Ptr<ICoreWebView2Find> find;
    Com_Ptr<IDCompositionVisual> visual;
    Com_Ptr<IDCompositionRectangleClip> clip;
    Aio_Webview_Host *visual_host = nullptr;
    bool visual_attached = false;
    int visual_level = 0;

    bool visible = false;
    int level = 0;
    int vis_x = 0, vis_y = 0, vis_w = 0, vis_h = 0;
    float clip_l = 0.0f, clip_t = 0.0f, clip_r = 0.0f, clip_b = 0.0f;
    int bounds_w = 0, bounds_h = 0;
    int applied_bounds_w = -1, applied_bounds_h = -1;
    float radius_bl = 0.0f, radius_br = 0.0f;
    float raster_scale = 1.0f;
    float applied_scale = 0.0f;
    COREWEBVIEW2_PREFERRED_COLOR_SCHEME color_scheme = COREWEBVIEW2_PREFERRED_COLOR_SCHEME_AUTO;
    double zoom = 1.0;

    std::wstring pending_url;
    bool creating = false;
    bool ready = false;
    bool failed = false;
    bool loading = false;
    bool can_back = false;
    bool can_forward = false;
    bool focused = false;
    bool state_dirty = false;
    uint8_t crashed = CRASH_NONE;
    uint32_t cursor_id = 32512; // IDC_ARROW
    int32_t find_count = 0;
    int32_t find_index = -1;
    std::string url_utf8;
    std::string title_utf8;
    std::string new_window_url_utf8;
    std::vector<uint8_t> favicon;
    uint32_t favicon_serial = 0;
    std::deque<Note> notes;

    void changed() {
        state_dirty = true;
        if (env) env->wake();
    }
    void note(int32_t kind, int32_t detail, std::string text) {
        notes.push_back(Note{kind, detail, std::move(text)});
        changed();
    }
};

static void detach_visual(Aio_Webview *v) {
    if (!v->visual_attached || !v->visual_host || !v->visual) return;
    auto &roots = v->visual_host->web_roots;
    if (v->visual_level >= 0 && static_cast<size_t>(v->visual_level) < roots.size()) {
        roots[static_cast<size_t>(v->visual_level)]->RemoveVisual(v->visual.get());
    }
    v->visual_attached = false;
}

static void ensure_visual_for_host(Aio_Webview *v, Aio_Webview_Host *host) {
    if (!v || !host || !v->comp) return;
    if (v->visual_host != host) {
        auto *old_host = v->visual_host;
        detach_visual(v);
        v->comp->put_RootVisualTarget(nullptr);
        v->visual.reset();
        v->clip.reset();
        if (old_host && old_host->dcomp) old_host->dcomp->Commit();
        v->visual_host = host;
        // Force bounds and scale reapplication so Chromium commits a fresh frame to the new visual.
        v->applied_bounds_w = -1;
        v->applied_bounds_h = -1;
        v->applied_scale = 0.0f;
        if (v->controller) {
            v->controller->put_ParentWindow(host->hwnd);
            v->controller->NotifyParentWindowPositionChanged();
        }
        host->dcomp->CreateVisual(v->visual.put());
        host->dcomp->CreateRectangleClip(v->clip.put());
        if (v->visual) {
            if (v->clip) v->visual->SetClip(v->clip.get());
            v->comp->put_RootVisualTarget(v->visual.get());
        }
    }
}

static void apply_color_scheme(Aio_Webview *v) {
    if (!v->webview13) return;
    Com_Ptr<ICoreWebView2Profile> profile;
    if (SUCCEEDED(v->webview13->get_Profile(profile.put())) && profile) {
        profile->put_PreferredColorScheme(v->color_scheme);
    }
}

static void apply_placement(Aio_Webview *v) {
    if (!v || !v->ready || !v->controller || !v->comp) return;
    // Hidden views still need to leave their old host before that window can be destroyed.
    if (v->host) ensure_visual_for_host(v, v->host);
    if (!v->host || !v->visible || v->vis_w <= 0 || v->vis_h <= 0) {
        detach_visual(v);
        v->controller->put_IsVisible(FALSE);
        return;
    }
    if (!v->visual) return;
    if (!host_ensure_levels(v->host, static_cast<size_t>(v->level) + 1)) return;

    if (!v->visual_attached || v->visual_level != v->level) {
        detach_visual(v);
        auto *parent = v->host->web_roots[static_cast<size_t>(v->level)].get();
        if (SUCCEEDED(parent->AddVisual(v->visual.get(), TRUE, nullptr))) {
            v->visual_attached = true;
            v->visual_level = v->level;
        }
    }

    v->visual->SetOffsetX(static_cast<float>(v->vis_x));
    v->visual->SetOffsetY(static_cast<float>(v->vis_y));
    if (v->clip) {
        v->clip->SetLeft(v->clip_l);
        v->clip->SetTop(v->clip_t);
        v->clip->SetRight(v->clip_r);
        v->clip->SetBottom(v->clip_b);
        v->clip->SetTopLeftRadiusX(0.0f);
        v->clip->SetTopLeftRadiusY(0.0f);
        v->clip->SetTopRightRadiusX(0.0f);
        v->clip->SetTopRightRadiusY(0.0f);
        v->clip->SetBottomLeftRadiusX(v->radius_bl);
        v->clip->SetBottomLeftRadiusY(v->radius_bl);
        v->clip->SetBottomRightRadiusX(v->radius_br);
        v->clip->SetBottomRightRadiusY(v->radius_br);
    }

    if (v->controller3 && v->raster_scale > 0.0f && v->raster_scale != v->applied_scale) {
        v->controller3->put_RasterizationScale(static_cast<double>(v->raster_scale));
        v->applied_scale = v->raster_scale;
    }

    int bw = (v->bounds_w > 0) ? v->bounds_w : v->vis_w;
    int bh = (v->bounds_h > 0) ? v->bounds_h : v->vis_h;
    if (bw != v->applied_bounds_w || bh != v->applied_bounds_h) {
        RECT bounds{0, 0, bw, bh};
        v->controller->put_Bounds(bounds);
        v->applied_bounds_w = bw;
        v->applied_bounds_h = bh;
    }
    v->controller->put_IsVisible(TRUE);
}

static void refresh_webview_state(Aio_Webview *v) {
    if (!v || !v->webview) return;
    LPWSTR uri = nullptr;
    if (SUCCEEDED(v->webview->get_Source(&uri)) && uri) {
        v->url_utf8 = wide_to_utf8(uri);
        CoTaskMemFree(uri);
    }
    LPWSTR title = nullptr;
    if (SUCCEEDED(v->webview->get_DocumentTitle(&title)) && title) {
        v->title_utf8 = wide_to_utf8(title);
        CoTaskMemFree(title);
    }
    BOOL back = FALSE, fwd = FALSE;
    if (SUCCEEDED(v->webview->get_CanGoBack(&back))) v->can_back = (back != FALSE);
    if (SUCCEEDED(v->webview->get_CanGoForward(&fwd))) v->can_forward = (fwd != FALSE);
    v->changed();
}

static void refresh_find_state(Aio_Webview *v) {
    if (!v->find) return;
    INT32 count = 0, index = -1;
    if (SUCCEEDED(v->find->get_MatchCount(&count))) v->find_count = count;
    if (SUCCEEDED(v->find->get_ActiveMatchIndex(&index))) v->find_index = index;
    v->changed();
}

// Reads a whole favicon stream, or nothing when it is larger than FAVICON_MAX_BYTES.
static std::vector<uint8_t> read_stream(IStream *stream) {
    std::vector<uint8_t> out;
    if (!stream) return out;
    uint8_t chunk[4096];
    for (;;) {
        ULONG got = 0;
        HRESULT hr = stream->Read(chunk, sizeof(chunk), &got);
        if (got > 0) {
            if (out.size() + got > FAVICON_MAX_BYTES) return {};
            out.insert(out.end(), chunk, chunk + got);
        }
        if (FAILED(hr) || hr == S_FALSE || got == 0) break;
    }
    return out;
}

static void request_favicon(Aio_Webview *v) {
    if (!v->webview15) return;
    LPWSTR uri = nullptr;
    bool has_icon = SUCCEEDED(v->webview15->get_FaviconUri(&uri)) && uri && uri[0];
    if (uri) CoTaskMemFree(uri);
    if (!has_icon) {
        v->favicon.clear();
        v->favicon_serial += 1;
        v->changed();
        return;
    }
    auto alive = v->alive;
    v->webview15->GetFavicon(
        COREWEBVIEW2_FAVICON_IMAGE_FORMAT_PNG,
        make_handler<Favicon_Completed_Handler>([v, alive](HRESULT hr, IStream *stream) -> HRESULT {
            if (!alive->load()) return S_OK;
            v->favicon = SUCCEEDED(hr) ? read_stream(stream) : std::vector<uint8_t>{};
            v->favicon_serial += 1;
            v->changed();
            return S_OK;
        }).get());
}

static void on_download_state(Aio_Webview *v, ICoreWebView2DownloadOperation *op) {
    COREWEBVIEW2_DOWNLOAD_STATE state = COREWEBVIEW2_DOWNLOAD_STATE_IN_PROGRESS;
    if (!op || FAILED(op->get_State(&state)) || state == COREWEBVIEW2_DOWNLOAD_STATE_IN_PROGRESS) return;
    LPWSTR path = nullptr;
    std::string text;
    if (SUCCEEDED(op->get_ResultFilePath(&path)) && path) {
        text = wide_to_utf8(path);
        CoTaskMemFree(path);
    }
    if (state == COREWEBVIEW2_DOWNLOAD_STATE_COMPLETED) {
        v->note(NOTE_DOWNLOAD_DONE, 0, std::move(text));
        return;
    }
    COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON reason = COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON_NONE;
    op->get_InterruptReason(&reason);
    v->note(NOTE_DOWNLOAD_FAILED, static_cast<int32_t>(reason), std::move(text));
}

// Subscribes to the page's events once its controller exists. Every handler checks `alive` first: the
// view may have been destroyed while WebView2 still held a queued callback.
static void register_events(Aio_Webview *v) {
    auto alive = v->alive;
    EventRegistrationToken tok{};
    v->webview->add_NavigationStarting(
        make_handler<Nav_Starting_Handler>([v, alive](
            ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
            if (!alive->load() || !args) return S_OK;
            LPWSTR uri = nullptr;
            if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                BOOL redirected = FALSE;
                const bool local = local_file_url(uri) &&
                                   SUCCEEDED(args->get_IsRedirected(&redirected)) && !redirected;
                if (!web_url_allowed(uri) && !local) {
                    args->put_Cancel(TRUE);
                } else {
                    v->loading = true;
                    v->crashed = CRASH_NONE;
                    v->url_utf8 = wide_to_utf8(uri);
                    v->changed();
                }
                CoTaskMemFree(uri);
            }
            return S_OK;
        }).get(),
        &tok);

    v->webview->add_NavigationCompleted(
        make_handler<Nav_Completed_Handler>([v, alive](
            ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *) -> HRESULT {
            if (!alive->load()) return S_OK;
            v->loading = false;
            refresh_webview_state(v);
            return S_OK;
        }).get(),
        &tok);

    v->webview->add_SourceChanged(
        make_handler<Source_Changed_Handler>([v, alive](
            ICoreWebView2 *, ICoreWebView2SourceChangedEventArgs *) -> HRESULT {
            if (!alive->load()) return S_OK;
            refresh_webview_state(v);
            return S_OK;
        }).get(),
        &tok);

    v->webview->add_HistoryChanged(
        make_handler<History_Changed_Handler>([v, alive](ICoreWebView2 *, IUnknown *) -> HRESULT {
            if (!alive->load()) return S_OK;
            refresh_webview_state(v);
            return S_OK;
        }).get(),
        &tok);

    v->webview->add_DocumentTitleChanged(
        make_handler<Title_Changed_Handler>([v, alive](ICoreWebView2 *, IUnknown *) -> HRESULT {
            if (!alive->load()) return S_OK;
            refresh_webview_state(v);
            return S_OK;
        }).get(),
        &tok);

    v->webview->add_NewWindowRequested(
        make_handler<New_Window_Handler>([v, alive](
            ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args) -> HRESULT {
            if (!alive->load() || !args) return S_OK;
            args->put_Handled(TRUE);
            BOOL initiated = FALSE;
            if (FAILED(args->get_IsUserInitiated(&initiated)) || !initiated) return S_OK;
            LPWSTR uri = nullptr;
            if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                // Replaying a popup as a host navigation bypasses Chromium's renderer-origin checks.
                if (web_url_allowed(uri)) {
                    v->new_window_url_utf8 = wide_to_utf8(uri);
                    v->changed();
                }
                CoTaskMemFree(uri);
            }
            return S_OK;
        }).get(),
        &tok);

    v->webview->add_ProcessFailed(
        make_handler<Process_Failed_Handler>([v, alive](
            ICoreWebView2 *, ICoreWebView2ProcessFailedEventArgs *args) -> HRESULT {
            if (!alive->load() || !args) return S_OK;
            COREWEBVIEW2_PROCESS_FAILED_KIND kind = COREWEBVIEW2_PROCESS_FAILED_KIND_UNKNOWN_PROCESS_EXITED;
            args->get_ProcessFailedKind(&kind);
            // GPU, utility and sub-frame processes restart on their own; only these leave the page dead.
            switch (kind) {
            case COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED: v->crashed = CRASH_BROWSER; break;
            case COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED: v->crashed = CRASH_RENDERER; break;
            case COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_UNRESPONSIVE:
                v->crashed = CRASH_UNRESPONSIVE;
                break;
            default: return S_OK;
            }
            v->loading = false;
            v->changed();
            return S_OK;
        }).get(),
        &tok);

    // Pages ask for the camera, microphone, location, notifications and the like; a viewer for docs and
    // dev servers grants none of them, and the denial is not saved so the policy stays the app's.
    v->webview->add_PermissionRequested(
        make_handler<Permission_Handler>([v, alive](
            ICoreWebView2 *, ICoreWebView2PermissionRequestedEventArgs *args) -> HRESULT {
            if (!alive->load() || !args) return S_OK;
            args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
            Com_Ptr<ICoreWebView2PermissionRequestedEventArgs3> args3;
            if (SUCCEEDED(args->QueryInterface(IID_PPV_ARGS(args3.put()))) && args3) {
                args3->put_SavesInProfile(FALSE);
            }
            COREWEBVIEW2_PERMISSION_KIND kind = COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
            args->get_PermissionKind(&kind);
            LPWSTR uri = nullptr;
            std::string text;
            if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                text = wide_to_utf8(uri);
                CoTaskMemFree(uri);
            }
            v->note(NOTE_PERMISSION_DENIED, static_cast<int32_t>(kind), std::move(text));
            return S_OK;
        }).get(),
        &tok);

    // Downloads save to the user's Downloads folder without Edge's download flyout; the app reports start,
    // completion and failure as notices.
    Com_Ptr<ICoreWebView2_4> webview4;
    if (SUCCEEDED(v->webview->QueryInterface(IID_PPV_ARGS(webview4.put()))) && webview4) {
        webview4->add_DownloadStarting(
            make_handler<Download_Starting_Handler>([v, alive](
                ICoreWebView2 *, ICoreWebView2DownloadStartingEventArgs *args) -> HRESULT {
                if (!alive->load() || !args) return S_OK;
                args->put_Handled(TRUE);
                LPWSTR path = nullptr;
                std::string text;
                if (SUCCEEDED(args->get_ResultFilePath(&path)) && path) {
                    text = wide_to_utf8(path);
                    CoTaskMemFree(path);
                }
                Com_Ptr<ICoreWebView2DownloadOperation> op;
                if (SUCCEEDED(args->get_DownloadOperation(op.put())) && op) {
                    EventRegistrationToken state_tok{};
                    op->add_StateChanged(
                        make_handler<Download_State_Handler>([v, alive](
                            ICoreWebView2DownloadOperation *sender, IUnknown *) -> HRESULT {
                            if (alive->load()) on_download_state(v, sender);
                            return S_OK;
                        }).get(),
                        &state_tok);
                }
                v->note(NOTE_DOWNLOAD_STARTED, 0, std::move(text));
                return S_OK;
            }).get(),
            &tok);
    }

    if (v->webview15) {
        v->webview15->add_FaviconChanged(
            make_handler<Favicon_Changed_Handler>([v, alive](ICoreWebView2 *, IUnknown *) -> HRESULT {
                if (alive->load()) request_favicon(v);
                return S_OK;
            }).get(),
            &tok);
    }

    v->comp->add_CursorChanged(
        make_handler<Cursor_Changed_Handler>([v, alive](
            ICoreWebView2CompositionController *sender, IUnknown *) -> HRESULT {
            if (!alive->load() || !sender) return S_OK;
            UINT32 id = 32512;
            if (SUCCEEDED(sender->get_SystemCursorId(&id))) {
                v->cursor_id = id;
                v->changed();
            }
            return S_OK;
        }).get(),
        &tok);

    v->controller->add_GotFocus(
        make_handler<Focus_Changed_Handler>([v, alive](ICoreWebView2Controller *, IUnknown *) -> HRESULT {
            if (!alive->load()) return S_OK;
            v->focused = true;
            v->changed();
            return S_OK;
        }).get(),
        &tok);

    v->controller->add_LostFocus(
        make_handler<Focus_Changed_Handler>([v, alive](ICoreWebView2Controller *, IUnknown *) -> HRESULT {
            if (!alive->load()) return S_OK;
            v->focused = false;
            v->changed();
            return S_OK;
        }).get(),
        &tok);

    v->controller->add_ZoomFactorChanged(
        make_handler<Zoom_Changed_Handler>([v, alive](ICoreWebView2Controller *sender, IUnknown *) -> HRESULT {
            if (!alive->load() || !sender) return S_OK;
            double zoom = 1.0;
            if (SUCCEEDED(sender->get_ZoomFactor(&zoom))) {
                v->zoom = zoom;
                v->changed();
            }
            return S_OK;
        }).get(),
        &tok);

    v->controller->add_AcceleratorKeyPressed(
        make_handler<Accel_Key_Handler>([v, alive](
            ICoreWebView2Controller *, ICoreWebView2AcceleratorKeyPressedEventArgs *args) -> HRESULT {
            if (!alive->load() || !args || !v->env || !v->env->accel_cb) return S_OK;
            UINT vk = 0;
            COREWEBVIEW2_KEY_EVENT_KIND kind = COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN;
            INT lparam = 0;
            args->get_VirtualKey(&vk);
            args->get_KeyEventKind(&kind);
            args->get_KeyEventLParam(&lparam);
            if (v->env->accel_cb(v->env->accel_user, v->pane_id, static_cast<uint32_t>(vk),
                                 static_cast<uint32_t>(kind), static_cast<int32_t>(lparam))) {
                args->put_Handled(TRUE);
            }
            return S_OK;
        }).get(),
        &tok);
}

static void start_controller_creation(Aio_Webview *v) {
    if (!v || !v->env || !v->env->ready || !v->env->env3 || !v->host || v->creating || v->ready) return;
    v->creating = true;
    auto alive = v->alive;
    auto env_alive = v->env->alive;

    Com_Ptr<ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler> handler;
    *handler.put() = new Comp_Completed_Handler([v, alive, env_alive](
                                                    HRESULT hr,
                                                    ICoreWebView2CompositionController *comp) -> HRESULT {
        if (!alive->load() || !env_alive->load()) {
            if (comp) {
                Com_Ptr<ICoreWebView2Controller> ctrl;
                if (SUCCEEDED(comp->QueryInterface(IID_PPV_ARGS(ctrl.put()))) && ctrl) ctrl->Close();
            }
            return S_OK;
        }
        v->creating = false;
        if (FAILED(hr) || !comp) {
            v->failed = true;
            v->changed();
            return S_OK;
        }
        v->comp.reset();
        comp->AddRef();
        *v->comp.put() = comp;
        if (FAILED(comp->QueryInterface(IID_PPV_ARGS(v->controller.put()))) || !v->controller) {
            v->failed = true;
            v->changed();
            return S_OK;
        }
        v->controller->QueryInterface(IID_PPV_ARGS(v->controller3.put()));
        if (FAILED(v->controller->get_CoreWebView2(v->webview.put())) || !v->webview) {
            v->failed = true;
            v->changed();
            return S_OK;
        }
        v->webview->QueryInterface(IID_PPV_ARGS(v->webview13.put()));
        v->webview->QueryInterface(IID_PPV_ARGS(v->webview15.put()));

        if (v->controller3) {
            v->controller3->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS);
            v->controller3->put_ShouldDetectMonitorScaleChanges(FALSE);
        }
        if (v->zoom > 0.0) v->controller->put_ZoomFactor(v->zoom);
        apply_color_scheme(v);

        Com_Ptr<ICoreWebView2Settings> settings;
        if (SUCCEEDED(v->webview->get_Settings(settings.put())) && settings) {
            settings->put_AreHostObjectsAllowed(FALSE);
            settings->put_IsWebMessageEnabled(FALSE);
            settings->put_AreDefaultContextMenusEnabled(TRUE);
            settings->put_IsStatusBarEnabled(FALSE);
            settings->put_AreDevToolsEnabled(TRUE);
            Com_Ptr<ICoreWebView2Settings4> settings4;
            if (SUCCEEDED(settings->QueryInterface(IID_PPV_ARGS(settings4.put()))) && settings4) {
                settings4->put_IsPasswordAutosaveEnabled(FALSE);
            }
        }

        register_events(v);

        v->ready = true;
        apply_placement(v);
        if (v->host) v->host->dcomp->Commit();
        if (!v->pending_url.empty()) {
            if (url_allowed(v->pending_url.c_str())) {
                v->webview->Navigate(v->pending_url.c_str());
            }
            v->pending_url.clear();
        }
        v->changed();
        return S_OK;
    });

    // Creation is asynchronous: a pane can leave its original window before the callback.
    HRESULT hr = v->env->env3->CreateCoreWebView2CompositionController(v->env->wake_hwnd, handler.get());
    if (FAILED(hr)) {
        v->creating = false;
        v->failed = true;
        v->changed();
    }
}

// The find session, created on first use with its count and position handlers.
static ICoreWebView2Find *find_session(Aio_Webview *v) {
    if (v->find) return v->find.get();
    if (!v->webview) return nullptr;
    Com_Ptr<ICoreWebView2_28> webview28;
    if (FAILED(v->webview->QueryInterface(IID_PPV_ARGS(webview28.put()))) || !webview28) return nullptr;
    if (FAILED(webview28->get_Find(v->find.put())) || !v->find) return nullptr;
    auto alive = v->alive;
    EventRegistrationToken tok{};
    v->find->add_MatchCountChanged(
        make_handler<Find_Count_Handler>([v, alive](ICoreWebView2Find *, IUnknown *) -> HRESULT {
            if (alive->load()) refresh_find_state(v);
            return S_OK;
        }).get(),
        &tok);
    v->find->add_ActiveMatchIndexChanged(
        make_handler<Find_Index_Handler>([v, alive](ICoreWebView2Find *, IUnknown *) -> HRESULT {
            if (alive->load()) refresh_find_state(v);
            return S_OK;
        }).get(),
        &tok);
    return v->find.get();
}

static bool overlay_ensure(Aio_Webview_Host *host, Overlay_Layer &layer, int width, int height) {
    if (width <= 0 || height <= 0) return false;
    if (layer.chain && layer.rtv && layer.width == width && layer.height == height) {
        if (!layer.attached && layer.visual) {
            layer.visual->SetContent(layer.chain.get());
            layer.attached = true;
        }
        return true;
    }
    if (!layer.chain) {
        DXGI_SWAP_CHAIN_DESC1 desc{};
        desc.Width = static_cast<UINT>(width);
        desc.Height = static_cast<UINT>(height);
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
        HRESULT hr = host->factory->CreateSwapChainForComposition(host->d3d.get(), &desc, nullptr,
                                                                  layer.chain.put());
        if (FAILED(hr) || !layer.chain) return false;
        if (layer.visual) {
            layer.visual->SetContent(layer.chain.get());
            layer.attached = true;
        }
    } else {
        layer.rtv.reset();
        if (host->ctx) {
            host->ctx->ClearState();
            host->ctx->Flush();
        }
        HRESULT hr = layer.chain->ResizeBuffers(2, static_cast<UINT>(width), static_cast<UINT>(height),
                                                DXGI_FORMAT_B8G8R8A8_UNORM, 0);
        if (FAILED(hr)) return false;
        if (!layer.attached && layer.visual) {
            layer.visual->SetContent(layer.chain.get());
            layer.attached = true;
        }
    }
    Com_Ptr<ID3D11Texture2D> back;
    if (FAILED(layer.chain->GetBuffer(0, IID_PPV_ARGS(back.put()))) || !back) return false;
    if (FAILED(host->d3d->CreateRenderTargetView(back.get(), nullptr, layer.rtv.put()))) return false;
    layer.width = width;
    layer.height = height;
    return true;
}

} // namespace

struct Aio_Webview_Snapshot {
    const char *url;
    int url_len;
    const char *title;
    int title_len;
    const char *new_window_url;
    int new_window_url_len;
    const uint8_t *favicon;
    int favicon_len;
    const char *note_text;
    int note_text_len;
    double zoom;
    uint32_t cursor_id;
    uint32_t favicon_serial;
    int32_t find_count;
    int32_t find_index;
    int32_t note_kind;
    int32_t note_detail;
    uint8_t ready;
    uint8_t failed;
    uint8_t loading;
    uint8_t can_back;
    uint8_t can_forward;
    uint8_t focused;
    uint8_t dirty;
    uint8_t crashed;
};

extern "C" {

// True when this process runs with an elevated token. WebView2 would then run elevated too, so the app
// opens links in the default browser instead.
int aio_webview_process_elevated(void) noexcept {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return 0;
    TOKEN_ELEVATION elevation{};
    DWORD size = 0;
    BOOL ok = GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size);
    CloseHandle(token);
    return ok && elevation.TokenIsElevated ? 1 : 0;
}

HRESULT aio_webview_host_create(HWND hwnd, ID3D11Device *d3d_device, IDXGIFactory2 *dxgi_factory,
                                void **out_host) noexcept {
    if (!hwnd || !d3d_device || !dxgi_factory || !out_host) return E_INVALIDARG;
    *out_host = nullptr;
    auto host = std::make_unique<Aio_Webview_Host>();
    host->hwnd = hwnd;
    d3d_device->AddRef();
    *host->d3d.put() = d3d_device;
    d3d_device->GetImmediateContext(host->ctx.put());
    dxgi_factory->AddRef();
    *host->factory.put() = dxgi_factory;

    Com_Ptr<IDXGIDevice> dxgi_device;
    HRESULT hr = d3d_device->QueryInterface(IID_PPV_ARGS(dxgi_device.put()));
    if (FAILED(hr)) return hr;
    hr = DCompositionCreateDevice(dxgi_device.get(), IID_PPV_ARGS(host->dcomp.put()));
    if (FAILED(hr)) return hr;
    hr = host->dcomp->CreateTargetForHwnd(hwnd, TRUE, host->target.put());
    if (FAILED(hr)) return hr;
    hr = host->dcomp->CreateVisual(host->root.put());
    if (FAILED(hr)) return hr;
    hr = host->target->SetRoot(host->root.get());
    if (FAILED(hr)) return hr;
    // Level 0 (tiled web views and the overlay above them) always exists.
    if (!host_ensure_levels(host.get(), 1)) return E_FAIL;
    host->dcomp->Commit();

    *out_host = host.release();
    return S_OK;
}

void aio_webview_host_destroy(void *raw) noexcept {
    if (!raw) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    for (auto &layer : host->overlays) overlay_release(host, layer);
    if (host->dcomp) host->dcomp->Commit();
    delete host;
}

ID3D11RenderTargetView *aio_webview_host_overlay_begin(void *raw, int layer_index, int width,
                                                       int height) noexcept {
    if (!raw || layer_index < 0) return nullptr;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    if (!host_ensure_levels(host, static_cast<size_t>(layer_index) + 1)) return nullptr;
    auto &layer = host->overlays[static_cast<size_t>(layer_index)];
    if (!overlay_ensure(host, layer, width, height)) return nullptr;
    return layer.rtv.get();
}

void aio_webview_host_overlay_present(void *raw, int layer_index) noexcept {
    if (!raw || layer_index < 0) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    if (static_cast<size_t>(layer_index) >= host->overlays.size()) return;
    auto &layer = host->overlays[static_cast<size_t>(layer_index)];
    if (layer.chain) layer.chain->Present(0, 0);
}

void aio_webview_host_overlay_hide(void *raw, int layer_index) noexcept {
    if (!raw || layer_index < 0) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    if (static_cast<size_t>(layer_index) >= host->overlays.size()) return;
    auto &layer = host->overlays[static_cast<size_t>(layer_index)];
    if (layer.attached && layer.visual) {
        layer.visual->SetContent(nullptr);
        layer.attached = false;
    }
}

// Releases the swap chains of overlays at `count` and above, which the frame no longer uses.
void aio_webview_host_trim(void *raw, int count) noexcept {
    if (!raw) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    for (size_t i = static_cast<size_t>(count > 1 ? count : 1); i < host->overlays.size(); i += 1) {
        if (host->overlays[i].chain) overlay_release(host, host->overlays[i]);
    }
}

void aio_webview_host_commit(void *raw) noexcept {
    if (!raw) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    if (host->dcomp) host->dcomp->Commit();
}

HRESULT aio_webview_env_create(const wchar_t *user_data_dir, HWND wake_hwnd, UINT wake_msg,
                               Accel_Callback accel_cb, void *accel_user, void **out_env) noexcept {
    if (!out_env) return E_INVALIDARG;
    *out_env = nullptr;
    auto env = std::make_unique<Aio_Webview_Env>();
    env->wake_hwnd = wake_hwnd;
    env->wake_msg = wake_msg;
    env->accel_cb = accel_cb;
    env->accel_user = accel_user;

    auto *env_ptr = env.get();
    auto alive = env->alive;
    Com_Ptr<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler> handler;
    *handler.put() = new Env_Completed_Handler(
        [env_ptr, alive](HRESULT hr, ICoreWebView2Environment *created) -> HRESULT {
            if (!alive->load()) return S_OK;
            auto fail = [env_ptr](HRESULT error) {
                env_ptr->failed = true;
                env_ptr->error_hr = error;
                for (auto *v : env_ptr->pending) {
                    v->failed = true;
                    v->state_dirty = true;
                }
                env_ptr->pending.clear();
                env_ptr->wake();
            };
            if (FAILED(hr) || !created) {
                fail(hr);
                return S_OK;
            }
            created->AddRef();
            *env_ptr->env.put() = created;
            if (FAILED(created->QueryInterface(IID_PPV_ARGS(env_ptr->env3.put()))) || !env_ptr->env3) {
                fail(E_NOINTERFACE);
                return S_OK;
            }
            created->QueryInterface(IID_PPV_ARGS(env_ptr->env15.put()));
            env_ptr->ready = true;
            auto queued = std::move(env_ptr->pending);
            env_ptr->pending.clear();
            for (auto *v : queued) start_controller_creation(v);
            env_ptr->wake();
            return S_OK;
        });

    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(nullptr, user_data_dir, nullptr, handler.get());
    if (FAILED(hr)) {
        env->alive->store(false);
        return hr;
    }
    *out_env = env.release();
    return S_OK;
}

void aio_webview_env_destroy(void *raw) noexcept {
    if (!raw) return;
    auto *env = static_cast<Aio_Webview_Env *>(raw);
    env->alive->store(false);
    env->pending.clear();
    delete env;
}

void *aio_webview_create(void *raw_env, void *raw_host, uint32_t pane_id, const wchar_t *initial_url,
                         int color_scheme, double zoom) noexcept {
    if (!raw_env || !raw_host) return nullptr;
    auto *env = static_cast<Aio_Webview_Env *>(raw_env);
    auto *host = static_cast<Aio_Webview_Host *>(raw_host);
    auto v = std::make_unique<Aio_Webview>();
    v->env = env;
    v->host = host;
    v->pane_id = pane_id;
    v->color_scheme = static_cast<COREWEBVIEW2_PREFERRED_COLOR_SCHEME>(color_scheme);
    v->zoom = zoom > 0.0 ? zoom : 1.0;
    if (initial_url && initial_url[0]) {
        v->pending_url = initial_url;
        v->url_utf8 = wide_to_utf8(initial_url);
    }
    auto *ptr = v.release();
    if (env->failed) {
        ptr->failed = true;
        ptr->state_dirty = true;
    } else if (env->ready) {
        start_controller_creation(ptr);
    } else {
        env->pending.push_back(ptr);
    }
    return ptr;
}

void aio_webview_destroy(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    v->alive->store(false);
    if (v->env) {
        auto &p = v->env->pending;
        p.erase(std::remove(p.begin(), p.end(), v), p.end());
    }
    detach_visual(v);
    auto *host = v->visual_host ? v->visual_host : v->host;
    if (v->find) v->find->Stop();
    if (v->comp) v->comp->put_RootVisualTarget(nullptr);
    if (v->controller) v->controller->Close();
    v->clip.reset();
    v->visual.reset();
    if (host && host->dcomp) host->dcomp->Commit();
    delete v;
}

void aio_webview_detach_host(void *raw, HWND fallback_hwnd) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    auto *old_host = v->visual_host;
    detach_visual(v);
    if (v->comp) v->comp->put_RootVisualTarget(nullptr);
    v->clip.reset();
    v->visual.reset();
    v->visual_host = nullptr;
    v->host = nullptr;
    v->visible = false;
    v->applied_bounds_w = -1;
    v->applied_bounds_h = -1;
    v->applied_scale = 0.0f;
    if (v->controller) {
        v->controller->put_IsVisible(FALSE);
        if (fallback_hwnd) {
            v->controller->put_ParentWindow(fallback_hwnd);
        }
    }
    if (old_host && old_host->dcomp) old_host->dcomp->Commit();
}

void aio_webview_set_placement(void *raw, void *raw_host, int visible, int level, int vis_x, int vis_y,
                               int vis_w, int vis_h, float clip_l, float clip_t, float clip_r, float clip_b,
                               int bounds_w, int bounds_h, float radius_bl, float radius_br,
                               float raster_scale) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    auto *host = static_cast<Aio_Webview_Host *>(raw_host);
    bool host_changed = (v->host != host);
    v->host = host;
    v->visible = (visible != 0);
    v->level = level > 0 ? level : 0;
    v->vis_x = vis_x;
    v->vis_y = vis_y;
    v->vis_w = vis_w;
    v->vis_h = vis_h;
    v->clip_l = clip_l;
    v->clip_t = clip_t;
    v->clip_r = clip_r;
    v->clip_b = clip_b;
    v->bounds_w = bounds_w;
    v->bounds_h = bounds_h;
    v->radius_bl = radius_bl;
    v->radius_br = radius_br;
    v->raster_scale = raster_scale;
    if (!v->ready && v->env && v->env->ready && v->host && !v->creating && !v->failed) {
        start_controller_creation(v);
        return;
    }
    if (host_changed && !host) {
        detach_visual(v);
    }
    apply_placement(v);
}

// 0 follows the system, 1 asks pages for their light look, 2 for their dark look.
void aio_webview_set_color_scheme(void *raw, int scheme) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    auto value = static_cast<COREWEBVIEW2_PREFERRED_COLOR_SCHEME>(scheme);
    if (v->color_scheme == value) return;
    v->color_scheme = value;
    apply_color_scheme(v);
}

void aio_webview_set_zoom(void *raw, double zoom) noexcept {
    if (!raw || zoom <= 0.0) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    v->zoom = zoom;
    if (v->controller) v->controller->put_ZoomFactor(zoom);
}

void aio_webview_navigate(void *raw, const wchar_t *url) noexcept {
    if (!raw || !url || !url_allowed(url)) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) {
        v->webview->Navigate(url);
    } else {
        v->pending_url = url;
        v->url_utf8 = wide_to_utf8(url);
    }
}

void aio_webview_go_back(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) v->webview->GoBack();
}

void aio_webview_go_forward(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) v->webview->GoForward();
}

void aio_webview_reload(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->crashed != CRASH_BROWSER) v->crashed = CRASH_NONE;
    if (v->webview) v->webview->Reload();
    v->changed();
}

void aio_webview_stop(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) v->webview->Stop();
}

// Starts or restarts a find for `term`; an empty term ends the session. Edge's own find bar stays hidden:
// the app's find bar shows the count from find_count and find_index.
int aio_webview_find_start(void *raw, const wchar_t *term, int case_sensitive, int whole_word) noexcept {
    if (!raw) return 0;
    auto *v = static_cast<Aio_Webview *>(raw);
    ICoreWebView2Find *find = find_session(v);
    if (!find || !v->env || !v->env->env15) return 0;
    if (!term || !term[0]) {
        find->Stop();
        v->find_count = 0;
        v->find_index = -1;
        v->changed();
        return 1;
    }
    Com_Ptr<ICoreWebView2FindOptions> options;
    if (FAILED(v->env->env15->CreateFindOptions(options.put())) || !options) return 0;
    options->put_FindTerm(term);
    options->put_IsCaseSensitive(case_sensitive ? TRUE : FALSE);
    options->put_ShouldMatchWord(whole_word ? TRUE : FALSE);
    options->put_ShouldHighlightAllMatches(TRUE);
    options->put_SuppressDefaultFindDialog(TRUE);
    auto alive = v->alive;
    HRESULT hr = find->Start(options.get(), make_handler<Find_Started_Handler>([v, alive](HRESULT) -> HRESULT {
                                                if (alive->load()) refresh_find_state(v);
                                                return S_OK;
                                            }).get());
    return SUCCEEDED(hr) ? 1 : 0;
}

void aio_webview_find_step(void *raw, int backward) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (!v->find) return;
    if (backward) {
        v->find->FindPrevious();
    } else {
        v->find->FindNext();
    }
}

void aio_webview_mouse(void *raw, int kind, uint32_t virtual_keys, uint32_t mouse_data, int local_x,
                       int local_y) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (!v->comp || !v->ready) return;
    POINT pt{local_x, local_y};
    v->comp->SendMouseInput(static_cast<COREWEBVIEW2_MOUSE_EVENT_KIND>(kind),
                            static_cast<COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS>(virtual_keys), mouse_data, pt);
}

void aio_webview_focus(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->controller && v->ready) {
        v->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    }
}

void aio_webview_parent_moved(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->controller && v->ready) {
        v->controller->NotifyParentWindowPositionChanged();
    }
}

// Fills `out` with views of the view's strings; they stay valid until the next call that changes the view.
void aio_webview_poll(void *raw, Aio_Webview_Snapshot *out) noexcept {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    out->url = v->url_utf8.c_str();
    out->url_len = static_cast<int>(v->url_utf8.size());
    out->title = v->title_utf8.c_str();
    out->title_len = static_cast<int>(v->title_utf8.size());
    out->new_window_url = v->new_window_url_utf8.c_str();
    out->new_window_url_len = static_cast<int>(v->new_window_url_utf8.size());
    out->favicon = v->favicon.data();
    out->favicon_len = static_cast<int>(v->favicon.size());
    out->favicon_serial = v->favicon_serial;
    if (!v->notes.empty()) {
        const Note &note = v->notes.front();
        out->note_kind = note.kind;
        out->note_detail = note.detail;
        out->note_text = note.text.c_str();
        out->note_text_len = static_cast<int>(note.text.size());
    }
    out->zoom = v->zoom;
    out->cursor_id = v->cursor_id;
    out->find_count = v->find_count;
    out->find_index = v->find_index;
    out->ready = v->ready ? 1 : 0;
    out->failed = v->failed ? 1 : 0;
    out->loading = v->loading ? 1 : 0;
    out->can_back = v->can_back ? 1 : 0;
    out->can_forward = v->can_forward ? 1 : 0;
    out->focused = v->focused ? 1 : 0;
    out->dirty = v->state_dirty ? 1 : 0;
    out->crashed = v->crashed;
    v->state_dirty = false;
}

void aio_webview_clear_new_window(void *raw) noexcept {
    if (!raw) return;
    static_cast<Aio_Webview *>(raw)->new_window_url_utf8.clear();
}

// Drops the note the last poll reported.
void aio_webview_pop_note(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->notes.empty()) return;
    v->notes.pop_front();
    // The next poll reports the note after it.
    if (!v->notes.empty()) v->changed();
}

} // extern "C"

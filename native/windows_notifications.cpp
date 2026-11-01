#include <windows.h>
#include <roapi.h>
#include <shlobj.h>
#include <propkey.h>
#include <propvarutil.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <vector>

// The bridge owns WinRT objects; Odin owns the context and receives clicks on its UI thread.
using namespace winrt;
using namespace winrt::Windows::Data::Xml::Dom;
using namespace winrt::Windows::UI::Notifications;
constexpr wchar_t APP_ID[] = L"AIODev.ProgramStatus";

struct Pending_Toast {
    ToastNotification toast{nullptr};
    ToastNotification::Activated_revoker activated;
    ToastNotification::Dismissed_revoker dismissed;
    ToastNotification::Failed_revoker failed;
    std::shared_ptr<std::atomic_bool> finished;
    void revoke() noexcept {
        activated.revoke();
        dismissed.revoke();
        failed.revoke();
    }
};
struct Notification_Sink {
    std::mutex mutex;
    HWND window;
    explicit Notification_Sink(HWND target) : window(target) {}
    void close() { std::lock_guard lock(mutex); window = nullptr; }
    void post(UINT message, WPARAM value) {
        std::lock_guard lock(mutex);
        if (window && !PostMessageW(window, message, value, 0)) {
            OutputDebugStringW(L"AIODev notification event delivery failed\n");
        }
    }
};
struct Notifications {
    std::shared_ptr<Notification_Sink> window;
    UINT message;
    std::vector<Pending_Toast> pending;
    ~Notifications() {
        if (window) window->close();
        for (auto &item : pending) item.revoke();
    }
};

static std::wstring notification_icon() {
    // IconUri needs an image file, not an executable containing icon resources.
    auto resource = FindResourceW(nullptr, MAKEINTRESOURCEW(2), MAKEINTRESOURCEW(10));
    check_bool(resource != nullptr);
    auto size = SizeofResource(nullptr, resource);
    check_bool(size != 0);
    auto loaded = LoadResource(nullptr, resource);
    check_bool(loaded != nullptr);
    auto bytes = LockResource(loaded);
    if (!bytes) throw_hresult(E_UNEXPECTED);
    PWSTR local = nullptr;
    check_hresult(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local));
    std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owned_local(local, &CoTaskMemFree);
    std::wstring directory(owned_local.get());
    directory += L"\\AIODev";
    if (!CreateDirectoryW(directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        throw_last_error();
    }
    auto path = directory + L"\\notification-icon.png";
    // Readers and other app windows keep using the published image without write conflicts.
    {
        std::ifstream existing(std::filesystem::path(path), std::ios::binary);
        std::vector<char> content(size);
        if (existing.read(content.data(), size) && existing.peek() == std::char_traits<char>::eof() &&
            !existing.bad() && std::memcmp(content.data(), bytes, size) == 0) return path;
    }
    wchar_t temporary[MAX_PATH];
    check_bool(GetTempFileNameW(directory.c_str(), L"aio", 0, temporary) != 0);
    auto remove_temporary = [&] {
        if (!DeleteFileW(temporary)) OutputDebugStringW(L"AIODev temporary notification icon cleanup failed\n");
    };
    auto file = CreateFileW(temporary, GENERIC_WRITE, 0, nullptr,
                            TRUNCATE_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        auto error = GetLastError();
        remove_temporary();
        throw_hresult(HRESULT_FROM_WIN32(error));
    }
    DWORD written = 0;
    auto result = WriteFile(file, bytes, size, &written, nullptr);
    auto error = result ? ERROR_SUCCESS : GetLastError();
    auto closed = CloseHandle(file);
    if (error == ERROR_SUCCESS && !closed) error = GetLastError();
    if (error == ERROR_SUCCESS && written != size) error = ERROR_WRITE_FAULT;
    if (error == ERROR_SUCCESS && !MoveFileExW(temporary, path.c_str(),
                                               MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        error = GetLastError();
    }
    if (error != ERROR_SUCCESS) {
        remove_temporary();
        throw_hresult(HRESULT_FROM_WIN32(error));
    }
    return path;
}

static void register_identity() {
    wchar_t exe[32768];
    auto length = GetModuleFileNameW(nullptr, exe, ARRAYSIZE(exe));
    if (!length || length >= ARRAYSIZE(exe)) throw_hresult(HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER));
    auto icon = notification_icon();
    check_hresult(SetCurrentProcessExplicitAppUserModelID(APP_ID));
    HKEY key = nullptr;
    check_hresult(HRESULT_FROM_WIN32(RegCreateKeyExW(HKEY_CURRENT_USER,
        L"Software\\Classes\\AppUserModelId\\AIODev.ProgramStatus", 0, nullptr, 0,
        KEY_SET_VALUE, nullptr, &key, nullptr)));
    auto name_result = RegSetValueExW(key, L"DisplayName", 0, REG_SZ,
        reinterpret_cast<const BYTE *>(L"AIODev"), sizeof(L"AIODev"));
    auto icon_result = RegSetValueExW(key, L"IconUri", 0, REG_SZ,
        reinterpret_cast<const BYTE *>(icon.c_str()), static_cast<DWORD>((icon.size() + 1) * sizeof(wchar_t)));
    auto close_result = RegCloseKey(key);
    check_hresult(HRESULT_FROM_WIN32(name_result));
    check_hresult(HRESULT_FROM_WIN32(icon_result));
    check_hresult(HRESULT_FROM_WIN32(close_result));
    PWSTR programs = nullptr;
    check_hresult(SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs));
    std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owned_programs(programs, &CoTaskMemFree);
    std::wstring path(owned_programs.get());
    path += L"\\AIODev.lnk";
    auto link = create_instance<IShellLinkW>(CLSID_ShellLink);
    check_hresult(link->SetPath(exe));
    check_hresult(link->SetIconLocation(exe, 0));
    PWSTR profile = nullptr;
    check_hresult(SHGetKnownFolderPath(FOLDERID_Profile, 0, nullptr, &profile));
    std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> owned_profile(profile, &CoTaskMemFree);
    check_hresult(link->SetWorkingDirectory(owned_profile.get()));
    auto properties = link.as<IPropertyStore>();
    PROPVARIANT value{};
    check_hresult(InitPropVariantFromString(APP_ID, &value));
    auto result = properties->SetValue(PKEY_AppUserModel_ID, value);
    check_hresult(PropVariantClear(&value));
    check_hresult(result);
    check_hresult(properties->Commit());
    check_hresult(link.as<IPersistFile>()->Save(path.c_str(), TRUE));
    auto legacy = std::wstring(owned_programs.get()) + L"\\AIODev Notifications.lnk";
    if (GetFileAttributesW(legacy.c_str()) != INVALID_FILE_ATTRIBUTES) {
        auto old_link = create_instance<IShellLinkW>(CLSID_ShellLink);
        if (SUCCEEDED(old_link.as<IPersistFile>()->Load(legacy.c_str(), STGM_READ))) {
            wchar_t target[32768];
            if (SUCCEEDED(old_link->GetPath(target, ARRAYSIZE(target), nullptr, SLGP_RAWPATH)) &&
                _wcsicmp(target, exe) == 0) {
                DeleteFileW(legacy.c_str());
            }
        }
    }
}

extern "C" HRESULT aio_notifications_create(HWND window, UINT message, void **out) noexcept {
    *out = nullptr;
    try {
        check_hresult(RoInitialize(RO_INIT_SINGLETHREADED));
        try {
            register_identity();
            auto state = std::make_unique<Notifications>();
            state->window = std::make_shared<Notification_Sink>(window);
            state->message = message;
            *out = state.release();
        } catch (...) { RoUninitialize(); throw; }
        return S_OK;
    } catch (...) { return to_hresult(); }
}

extern "C" void aio_notifications_destroy(void *state) noexcept {
    if (!state) return;
    delete static_cast<Notifications *>(state);
    RoUninitialize();
}

extern "C" HRESULT aio_notifications_show(
    void *context, const wchar_t *title, const wchar_t *text, UINT token, bool sound,
    const char **operation) noexcept {
    *operation = "prepare";
    try {
        auto &state = *static_cast<Notifications *>(context);
        auto &items = state.pending;
        items.erase(std::remove_if(items.begin(), items.end(), [](auto &item) {
            if (!item.finished->load()) return false;
            item.revoke();
            return true;
        }), items.end());
        // Bound retained activation handlers even if Windows never sends a dismissal.
        if (items.size() >= 128) { items.front().revoke(); items.erase(items.begin()); }
        *operation = "create XML";
        XmlDocument xml;
        xml.LoadXml(L"<toast><visual><binding template='ToastGeneric'><text/><text/>"
                    L"</binding></visual><audio silent='true'/></toast>");
        auto texts = xml.GetElementsByTagName(L"text");
        texts.Item(0).AppendChild(xml.CreateTextNode(title));
        texts.Item(1).AppendChild(xml.CreateTextNode(text));
        if (sound) xml.GetElementsByTagName(L"audio").Item(0).as<XmlElement>().SetAttribute(L"silent", L"false");
        *operation = "create toast";
        Pending_Toast item;
        item.toast = ToastNotification(xml);
        item.finished = std::make_shared<std::atomic_bool>(false);
        auto finished = item.finished;
        auto window = state.window;
        auto message = state.message;
        item.activated = item.toast.Activated(auto_revoke, [window, message, token, finished](auto &&, auto &&) {
            window->post(message, token);
            finished->store(true);
        });
        item.dismissed = item.toast.Dismissed(auto_revoke, [finished](auto &&, ToastDismissedEventArgs const &args) {
            // Timed-out banners remain clickable in Notification Center.
            if (args.Reason() == ToastDismissalReason::UserCanceled) finished->store(true);
        });
        item.failed = item.toast.Failed(auto_revoke, [window, message, finished](auto &&, ToastFailedEventArgs const &args) {
            window->post(message + 1, static_cast<WPARAM>(static_cast<unsigned>(args.ErrorCode())));
            finished->store(true);
        });
        items.push_back(std::move(item));
        *operation = "create notifier";
        auto notifier = ToastNotificationManager::CreateToastNotifier(APP_ID);
        *operation = "show toast";
        notifier.Show(items.back().toast);
        return S_OK;
    } catch (...) { return to_hresult(); }
}

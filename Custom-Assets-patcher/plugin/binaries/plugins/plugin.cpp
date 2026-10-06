// game plugin (binaries/plugins): runs tools/custom-assets-patcher.exe once when Darktide starts, before the game
// reads its bundles, so new or changed assets (and game updates) are patched without a separate step

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdio>
#include <filesystem>
#include <stdexcept>
#include <string>

namespace fs = std::filesystem;
static INIT_ONCE patch_once = INIT_ONCE_STATIC_INIT;
// the patcher exits at once when nothing changed; a full install of many assets takes seconds, so five minutes
// means it hangs: the game then starts with the assets of the last install
static constexpr DWORD PATCHER_TIMEOUT_MS = 5 * 60 * 1000;

static fs::path host_path() {
    wchar_t value[32768];
    DWORD size = GetModuleFileNameW(nullptr, value, static_cast<DWORD>(std::size(value)));
    if (!size || size >= std::size(value)) throw std::runtime_error("couldnt locate darktide.exe");
    return fs::path(std::wstring(value, size));
}

static void log(const fs::path &root, const std::string &message) {
    FILE *file = nullptr;
    _wfopen_s(&file, (root / "tools" / "custom-assets-startup.log").c_str(), L"a");
    if (file) {
        fprintf(file, "pid=%lu %s\n", GetCurrentProcessId(), message.c_str());
        fclose(file);
    }
}

static BOOL CALLBACK run_patcher(PINIT_ONCE, PVOID context, PVOID *) {
    const auto &root = *static_cast<const fs::path *>(context);
    const auto exe = root / "tools" / "custom-assets-patcher.exe";
    std::wstring command = L"\"" + exe.wstring() + L"\" --startup " + std::to_wstring(GetCurrentProcessId());
    STARTUPINFOW info{};
    info.cb = sizeof(info);
    PROCESS_INFORMATION child{};
    log(root, "running custom assets patcher");
    if (!CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                        nullptr, root.c_str(), &info, &child)) {
        log(root, "couldnt start the patcher (windows error " + std::to_string(GetLastError()) + "), starting game anyway");
        return TRUE;
    }
    CloseHandle(child.hThread);
    const DWORD waited = WaitForSingleObject(child.hProcess, PATCHER_TIMEOUT_MS);
    DWORD code = 1;
    if (waited == WAIT_TIMEOUT) {
        TerminateProcess(child.hProcess, 1);
        WaitForSingleObject(child.hProcess, 10000);
        log(root, "patcher took longer than 5 minutes and was stopped, starting game with the last installed assets");
    } else if (waited == WAIT_OBJECT_0 && GetExitCodeProcess(child.hProcess, &code)) {
        log(root, "patcher exit=" + std::to_string(code));
        if (code) log(root, "patcher failed, starting game anyway. check custom-assets-patch.log");
    }
    CloseHandle(child.hProcess);
    return TRUE;
}

extern "C" __declspec(dllexport) void *get_plugin_api(unsigned api_id) {
    if (api_id != 0) return nullptr;
    try {
        const auto host = host_path();
        if (_wcsicmp(host.filename().c_str(), L"Darktide.exe") == 0) {
            auto root = host.parent_path().parent_path();
            if (!InitOnceExecuteOnce(&patch_once, run_patcher, &root, nullptr))
                log(root, "couldnt start automatic patching, starting game anyway");
        }
    } catch (const std::exception &exception) {
        OutputDebugStringA(exception.what());
    }
    return nullptr;
}

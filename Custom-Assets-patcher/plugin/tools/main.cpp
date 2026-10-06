// Custom Assets patcher: installs the cooked assets in mods/<Mod>/Custom/<Folder>/ into Darktide's bundle folder.
// run by the plugin when the game starts, or by CUSTOM_ASSETS_PATCH.bat with the game closed

#include "common.h"
#include "install.h"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <iostream>
#include <string>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>
#include "startup.h"
#endif

namespace {

using namespace ca;

fs::path executable_path() {
#if defined(_WIN32)
    std::wstring buffer(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (!length || length >= buffer.size()) throw PatcherError("could not find the patcher's own path");
    buffer.resize(length);
    return fs::weakly_canonical(fs::path(buffer));
#else
    return fs::weakly_canonical(fs::current_path() / "custom-assets-patcher");
#endif
}

// the game of this install running (other than the one that started us); its files are open then
bool game_is_running(const fs::path &game_root, unsigned long startup_pid) {
#if defined(_WIN32)
    ca::Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
    if (snapshot.get() == INVALID_HANDLE_VALUE) throw PatcherError("could not check whether Darktide.exe is running");
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (!Process32FirstW(snapshot.get(), &entry)) throw PatcherError("could not check whether Darktide.exe is running");
    const fs::path ours = game_root / "binaries" / "Darktide.exe";
    do {
        std::wstring name = entry.szExeFile;
        std::transform(name.begin(), name.end(), name.begin(), [](wchar_t c) { return c >= L'A' && c <= L'Z' ? static_cast<wchar_t>(c + (L'a' - L'A')) : c; });
        if (name != L"darktide.exe" || entry.th32ProcessID == startup_pid) continue;
        ca::Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID));
        std::wstring image(32768, L'\0');
        DWORD length = static_cast<DWORD>(image.size());
        if (!process.get() || !QueryFullProcessImageNameW(process.get(), 0, image.data(), &length)) return true;   // can't tell: assume ours
        image.resize(length);
        std::error_code ec;
        if (fs::exists(ours, ec) && fs::equivalent(image, ours, ec)) return true;
    } while (Process32NextW(snapshot.get(), &entry));
#else
    (void)game_root; (void)startup_pid;
#endif
    return false;
}

class TeeBuffer : public std::streambuf {
public:
    TeeBuffer(std::streambuf *first, std::streambuf *second) : first(first), second(second) {}

protected:
    int overflow(int c) override {
        if (c == traits_type::eof()) return traits_type::not_eof(c);
        const bool a = first->sputc(static_cast<char>(c)) != traits_type::eof();
        const bool b = second->sputc(static_cast<char>(c)) != traits_type::eof();
        return a && b ? c : traits_type::eof();
    }
    int sync() override {
        return first->pubsync() == 0 && second->pubsync() == 0 ? 0 : -1;
    }

private:
    std::streambuf *first;
    std::streambuf *second;
};

int run(unsigned long startup_pid, const InstallOptions &options) {
    const Layout layout = layout_for_executable(executable_path());
#if defined(_WIN32)
    ca::Handle startup_host;
    if (startup_pid) startup_host = ca::validate_startup_parent(layout.game_root, startup_pid);
    ca::PatchLock patch_lock(layout.game_root);
#endif
    // the log is written at the end: a run that found nothing to do adds to it, so the warnings and skipped
    // folders of the last real install stay readable
    std::ostringstream log_text;
    TeeBuffer out_buffer(std::cout.rdbuf(), log_text.rdbuf());
    TeeBuffer err_buffer(std::cerr.rdbuf(), log_text.rdbuf());
    std::streambuf *old_out = std::cout.rdbuf(&out_buffer);
    std::streambuf *old_err = std::cerr.rdbuf(&err_buffer);
    int result = 1;
    bool up_to_date = false;
    try {
        std::cout << "Custom Assets patcher (" << layout.kind << " version)\n";
        if (game_is_running(layout.game_root, startup_pid)) throw PatcherError("Darktide is running. Close the game first.");
        result = install(layout, options, up_to_date);
    } catch (const std::exception &exc) {
        std::cerr << "ERROR: " << exc.what() << "\n";
    }
    std::cout.flush();
    std::cerr.flush();
    std::cout.rdbuf(old_out);
    std::cerr.rdbuf(old_err);
    std::error_code ec;
    fs::create_directories(layout.log.parent_path(), ec);
    std::ofstream log_file(layout.log, up_to_date ? std::ios::app : std::ios::trunc);
    log_file << log_text.str();
    return result;
}

} // namespace

int main(int argc, char **argv) {
    try {
        unsigned long startup_pid = 0;
        InstallOptions options;
        for (int i = 1; i < argc; ++i) {
            const std::string argument = argv[i];
            if (argument == "--help") {
                std::cout << "Custom Assets patcher\n"
                          << "Installs the assets in mods/<Mod>/Custom/<Folder>/. Run it with the game closed\n"
                          << "(the plugin runs it by itself when the game starts).\n"
                          << "--dry-run  check the assets without changing anything\n"
                          << "--force    rebuild even when nothing changed\n";
                return 0;
            } else if (argument == "--dry-run") {
                options.dry_run = true;
            } else if (argument == "--force") {
                options.force = true;
            } else if (argument == "--startup" && !startup_pid && i + 1 < argc) {
                const std::string value = argv[++i];
                if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos) throw PatcherError("invalid startup pid");
                const unsigned long long pid = std::stoull(value);
                if (!pid || pid > 0xffffffffull) throw PatcherError("invalid startup pid");
                startup_pid = static_cast<unsigned long>(pid);
            } else {
                throw PatcherError("unknown argument: " + argument + " (see --help)");
            }
        }
        return run(startup_pid, options);
    } catch (const std::exception &exc) {
        std::cerr << "ERROR: " << exc.what() << "\n";
        return 1;
    }
}

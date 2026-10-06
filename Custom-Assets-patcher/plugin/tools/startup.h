#pragma once

#include <windows.h>
#include <tlhelp32.h>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <utility>

namespace ca {

class Handle {
public:
    explicit Handle(HANDLE value = nullptr) : value_(value) {}
    ~Handle() { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
    Handle(Handle &&other) noexcept : value_(std::exchange(other.value_, nullptr)) {}
    Handle &operator=(Handle &&other) noexcept {
        if (this != &other) {
            if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_);
            value_ = std::exchange(other.value_, nullptr);
        }
        return *this;
    }
    HANDLE get() const { return value_; }
private:
    HANDLE value_;
};

inline std::filesystem::path module_path(HMODULE module = nullptr) {
    std::wstring value(32768, L'\0');
    DWORD count = GetModuleFileNameW(module, value.data(), static_cast<DWORD>(value.size()));
    if (!count || count >= value.size()) throw std::runtime_error("couldnt locate executable or dll");
    value.resize(count);
    return std::filesystem::weakly_canonical(value);
}

inline Handle validate_startup_parent(const std::filesystem::path &game_root, DWORD pid) {
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
    if (snapshot.get() == INVALID_HANDLE_VALUE) throw std::runtime_error("could not check startup parent");
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    bool found = false;
    if (Process32FirstW(snapshot.get(), &entry)) {
        do {
            if (entry.th32ProcessID == GetCurrentProcessId()) {
                found = entry.th32ParentProcessID == pid;
                break;
            }
        } while (Process32NextW(snapshot.get(), &entry));
    }
    if (!found) throw std::runtime_error("startup pid isnt the patchers direct parent");
    Handle parent(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid));
    if (!parent.get() || WaitForSingleObject(parent.get(), 0) != WAIT_TIMEOUT) {
        throw std::runtime_error("startup parent is no longer running");
    }
    std::wstring image(32768, L'\0');
    DWORD count = static_cast<DWORD>(image.size());
    if (!QueryFullProcessImageNameW(parent.get(), 0, image.data(), &count)) {
        throw std::runtime_error("could not identify startup parent");
    }
    image.resize(count);
    if (!std::filesystem::equivalent(image, game_root / "binaries" / "Darktide.exe")) {
        throw std::runtime_error("startup parent isnt this installations darktide.exe");
    }
    return parent;
}

class PatchLock {
public:
    explicit PatchLock(const std::filesystem::path &root) {
        unsigned long long hash = 14695981039346656037ull;
        for (wchar_t ch : root.wstring()) {
            if (ch >= L'A' && ch <= L'Z') ch += L'a' - L'A';
            hash = (hash ^ static_cast<unsigned short>(ch)) * 1099511628211ull;
        }
        const std::wstring name = L"Local\\CustomAssetsPatch-" + std::to_wstring(hash);
        mutex_ = Handle(CreateMutexW(nullptr, FALSE, name.c_str()));
        if (!mutex_.get()) throw std::runtime_error("could not create patch lock");
        DWORD result = WaitForSingleObject(mutex_.get(), 0);
        if (result != WAIT_OBJECT_0 && result != WAIT_ABANDONED) {
            throw std::runtime_error("another custom assets patcher is already running");
        }
    }
    ~PatchLock() { ReleaseMutex(mutex_.get()); }
private:
    Handle mutex_;
};

} // namespace ca

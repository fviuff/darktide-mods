#include "common.h"

#include <algorithm>
#include <fstream>
#include <iomanip>
#include <sstream>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

namespace ca {

std::string lower_ascii(std::string value) {
    for (char &c : value) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c + ('a' - 'A'));
        }
    }

    return value;
}

bool starts_with(const std::string &value, const std::string &prefix) {
    return value.size() >= prefix.size() && value.compare(0, prefix.size(), prefix) == 0;
}

bool ends_with(const std::string &value, const std::string &suffix) {
    return value.size() >= suffix.size() && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string path_text(const fs::path &path) {
#if defined(_WIN32)
    const std::wstring wide = path.wstring();
    if (wide.empty()) {
        return {};
    }

    const int needed = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), out.data(), needed, nullptr, nullptr);
    return out;
#else
    return path.string();
#endif
}
std::string generic_path_text(const fs::path &path) {
    std::string out = path_text(path);
    std::replace(out.begin(), out.end(), '\\', '/');
    return out;
}


u32 read_u32(const Bytes &data, size_t offset, const char *message) {
    if (offset + 4 > data.size()) {
        throw PatcherError(message);
    }

    return static_cast<u32>(data[offset]) |
        (static_cast<u32>(data[offset + 1]) << 8) |
        (static_cast<u32>(data[offset + 2]) << 16) |
        (static_cast<u32>(data[offset + 3]) << 24);
}

u64 read_u64(const Bytes &data, size_t offset, const char *message) {
    if (offset + 8 > data.size()) {
        throw PatcherError(message);
    }

    u64 value = 0;

    for (size_t i = 0; i < 8; ++i) {
        value |= static_cast<u64>(data[offset + i]) << (i * 8);
    }

    return value;
}

u32 read_u32(const u8 *data) {
    return static_cast<u32>(data[0]) |
        (static_cast<u32>(data[1]) << 8) |
        (static_cast<u32>(data[2]) << 16) |
        (static_cast<u32>(data[3]) << 24);
}

void write_u32(Bytes &out, u32 value) {
    out.push_back(static_cast<u8>(value));
    out.push_back(static_cast<u8>(value >> 8));
    out.push_back(static_cast<u8>(value >> 16));
    out.push_back(static_cast<u8>(value >> 24));
}

void write_u64(Bytes &out, u64 value) {
    for (size_t i = 0; i < 8; ++i) {
        out.push_back(static_cast<u8>(value >> (i * 8)));
    }
}

void overwrite_u32(Bytes &out, size_t offset, u32 value) {
    if (offset + 4 > out.size()) {
        throw PatcherError("internal write_u32 offset is out of range");
    }

    out[offset] = static_cast<u8>(value);
    out[offset + 1] = static_cast<u8>(value >> 8);
    out[offset + 2] = static_cast<u8>(value >> 16);
    out[offset + 3] = static_cast<u8>(value >> 24);
}

void append_bytes(Bytes &out, const Bytes &value) {
    out.insert(out.end(), value.begin(), value.end());
}

void append_bytes(Bytes &out, const Hash8 &value) {
    out.insert(out.end(), value.begin(), value.end());
}

Bytes slice_bytes(const Bytes &data, size_t start, size_t end) {
    if (start > end || end > data.size()) {
        throw PatcherError("byte slice is out of range");
    }

    return Bytes(data.begin() + static_cast<std::ptrdiff_t>(start), data.begin() + static_cast<std::ptrdiff_t>(end));
}

Hash8 slice_hash8(const Bytes &data, size_t offset) {
    if (offset + 8 > data.size()) {
        throw PatcherError("truncated 64-bit hash field");
    }

    Hash8 out{};
    std::copy_n(data.begin() + static_cast<std::ptrdiff_t>(offset), 8, out.begin());
    return out;
}

std::string hex_bytes(const u8 *data, size_t count, bool reverse) {
    static const char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(count * 2);

    for (size_t i = 0; i < count; ++i) {
        const size_t index = reverse ? count - i - 1 : i;
        const u8 value = data[index];
        out.push_back(hex[value >> 4]);
        out.push_back(hex[value & 15]);
    }

    return out;
}

std::optional<u8> hex_digit(char c) {
    if (c >= '0' && c <= '9') return static_cast<u8>(c - '0');
    if (c >= 'a' && c <= 'f') return static_cast<u8>(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return static_cast<u8>(c - 'A' + 10);
    return std::nullopt;
}

std::optional<Bytes> parse_hex(const std::string &value) {
    if ((value.size() & 1) != 0) {
        return std::nullopt;
    }

    Bytes out;
    out.reserve(value.size() / 2);

    for (size_t i = 0; i < value.size(); i += 2) {
        const auto hi = hex_digit(value[i]);
        const auto lo = hex_digit(value[i + 1]);

        if (!hi || !lo) {
            return std::nullopt;
        }

        out.push_back(static_cast<u8>((*hi << 4) | *lo));
    }

    return out;
}

Bytes read_file(const fs::path &path) {
    std::ifstream file(path, std::ios::binary);

    if (!file) {
        throw PatcherError("could not read file: " + path_text(path));
    }

    file.seekg(0, std::ios::end);
    const std::streamoff size = file.tellg();

    if (size < 0) {
        throw PatcherError("could not determine file size: " + path_text(path));
    }

    file.seekg(0, std::ios::beg);
    Bytes out(static_cast<size_t>(size));

    if (!out.empty()) {
        file.read(reinterpret_cast<char *>(out.data()), static_cast<std::streamsize>(out.size()));

        if (!file) {
            throw PatcherError("could not read complete file: " + path_text(path));
        }
    }

    return out;
}

std::string read_text_file(const fs::path &path) {
    const Bytes data = read_file(path);
    return std::string(reinterpret_cast<const char *>(data.data()), data.size());
}

bool file_equals_bytes(const fs::path &path, const Bytes &data) {
    std::error_code ec;

    if (!fs::is_regular_file(path, ec) || ec) {
        return false;
    }

    if (fs::file_size(path, ec) != data.size() || ec) {
        return false;
    }

    std::ifstream file(path, std::ios::binary);

    if (!file) {
        return false;
    }

    std::vector<u8> buffer(1024 * 1024);
    size_t offset = 0;

    while (offset < data.size()) {
        const size_t count = std::min(buffer.size(), data.size() - offset);
        file.read(reinterpret_cast<char *>(buffer.data()), static_cast<std::streamsize>(count));

        if (file.gcount() != static_cast<std::streamsize>(count) ||
            !std::equal(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(count), data.begin() + static_cast<std::ptrdiff_t>(offset))) {
            return false;
        }

        offset += count;
    }

    return true;
}

bool files_equal(const fs::path &left, const fs::path &right) {
    std::error_code ec;

    if (!fs::is_regular_file(left, ec) || ec) {
        return false;
    }

    const auto left_size = fs::file_size(left, ec);

    if (ec || !fs::is_regular_file(right, ec) || ec) {
        return false;
    }

    if (left_size != fs::file_size(right, ec) || ec) {
        return false;
    }

    std::ifstream a(left, std::ios::binary);
    std::ifstream b(right, std::ios::binary);

    if (!a || !b) {
        return false;
    }

    std::vector<char> ac(1024 * 1024);
    std::vector<char> bc(1024 * 1024);

    for (;;) {
        a.read(ac.data(), static_cast<std::streamsize>(ac.size()));
        b.read(bc.data(), static_cast<std::streamsize>(bc.size()));
        const std::streamsize an = a.gcount();
        const std::streamsize bn = b.gcount();

        if (an != bn || !std::equal(ac.begin(), ac.begin() + an, bc.begin())) {
            return false;
        }

        if (an == 0) {
            return true;
        }
    }
}

fs::path temp_path_for(const fs::path &destination) {
    static u64 serial = 0;
    ++serial;
    return destination.parent_path() / ("." + path_text(destination.filename()) + "." + std::to_string(serial) + ".tmp");
}

void atomic_write(const fs::path &path, const Bytes &data) {
    fs::create_directories(path.parent_path());
    const fs::path temp = temp_path_for(path);

    try {
        {
            std::ofstream file(temp, std::ios::binary | std::ios::trunc);

            if (!file) {
                throw PatcherError("could not create temporary file: " + path_text(temp));
            }

            if (!data.empty()) {
                file.write(reinterpret_cast<const char *>(data.data()), static_cast<std::streamsize>(data.size()));
            }

            file.flush();

            if (!file) {
                throw PatcherError("could not write temporary file: " + path_text(temp));
            }
        }

#if defined(_WIN32)
        HANDLE handle = CreateFileW(temp.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle != INVALID_HANDLE_VALUE) {
            FlushFileBuffers(handle);
            CloseHandle(handle);
        }

        if (!MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            throw PatcherError("could not replace file: " + path_text(path));
        }
#else
        std::error_code ec;
        fs::remove(path, ec);
        ec.clear();
        fs::rename(temp, path, ec);
        if (ec) {
            throw PatcherError("could not replace file: " + path_text(path) + ": " + ec.message());
        }
#endif
    } catch (...) {
        std::error_code ec;
        fs::remove(temp, ec);
        throw;
    }
}

void atomic_copy(const fs::path &source, const fs::path &destination) {
    atomic_write(destination, read_file(source));
}

u32 crc32_bytes(const u8 *data, size_t size, u32 crc) {
    static u32 table[256]{};
    static bool initialized = false;

    if (!initialized) {
        for (u32 i = 0; i < 256; ++i) {
            u32 value = i;

            for (int bit = 0; bit < 8; ++bit) {
                value = (value >> 1) ^ (0xedb88320u & (0u - (value & 1u)));
            }

            table[i] = value;
        }

        initialized = true;
    }

    crc ^= 0xffffffffu;

    for (size_t i = 0; i < size; ++i) {
        crc = table[(crc ^ data[i]) & 0xffu] ^ (crc >> 8);
    }

    return crc ^ 0xffffffffu;
}

std::string crc32_file(const fs::path &path) {
    std::ifstream file(path, std::ios::binary);

    if (!file) {
        throw PatcherError("could not read file for CRC32: " + path_text(path));
    }

    u32 crc = 0;
    std::vector<u8> buffer(1024 * 1024);

    for (;;) {
        file.read(reinterpret_cast<char *>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
        const size_t count = static_cast<size_t>(file.gcount());

        if (!count) {
            break;
        }

        crc = crc32_bytes(buffer.data(), count, crc);
    }

    std::ostringstream out;
    out << std::hex << std::setfill('0') << std::setw(8) << crc;
    return out.str();
}

u64 murmur64(const u8 *data, size_t size) {
    static constexpr u64 m = 0xc6a4a7935bd1e995ull;
    static constexpr int r = 47;
    u64 h = static_cast<u64>(size) * m;
    size_t pos = 0;

    while (pos + 8 <= size) {
        u64 k = 0;

        for (int i = 0; i < 8; ++i) {
            k |= static_cast<u64>(data[pos + static_cast<size_t>(i)]) << (i * 8);
        }

        k *= m;
        k ^= k >> r;
        k *= m;
        h ^= k;
        h *= m;
        pos += 8;
    }

    if (pos < size) {
        u64 tail = 0;

        for (size_t i = 0; pos + i < size; ++i) {
            tail |= static_cast<u64>(data[pos + i]) << (i * 8);
        }

        h ^= tail;
        h *= m;
    }

    h ^= h >> r;
    h *= m;
    h ^= h >> r;
    return h;
}

std::pair<Hash8, std::string> identity_hash(const std::string &value) {
    u64 numeric = 0;
    bool opaque = false;

    if (value.size() == 21 && value.compare(0, 4, "#ID[") == 0 && value.back() == ']') {
        const std::string hex = value.substr(4, 16);
        const auto parsed = parse_hex(hex);

        if (parsed && parsed->size() == 8) {
            numeric = 0;

            for (u8 byte : *parsed) {
                numeric = (numeric << 8) | byte;
            }

            opaque = true;
        }
    }

    if (!opaque) {
        numeric = murmur64(reinterpret_cast<const u8 *>(value.data()), value.size());
    }

    Hash8 bytes{};

    for (size_t i = 0; i < 8; ++i) {
        bytes[i] = static_cast<u8>(numeric >> (i * 8));
    }

    std::ostringstream out;
    out << std::hex << std::setfill('0') << std::setw(16) << std::nouppercase << numeric;
    return {bytes, out.str()};
}

std::string murmur64_hex(const std::string &value) {
    return identity_hash(value).second;
}

void write_file(const fs::path &path, const Bytes &data) {
    fs::create_directories(path.parent_path());
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) throw PatcherError("could not create file: " + path_text(path));
    if (!data.empty()) file.write(reinterpret_cast<const char *>(data.data()), static_cast<std::streamsize>(data.size()));
    if (!file) throw PatcherError("could not write file: " + path_text(path));
}

} // namespace ca

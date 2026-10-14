#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace ca {

using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using i64 = std::int64_t;
using Bytes = std::vector<u8>;
using Hash8 = std::array<u8, 8>;
namespace fs = std::filesystem;

struct PatcherError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// text
std::string lower_ascii(std::string value);
bool starts_with(const std::string &value, const std::string &prefix);
bool ends_with(const std::string &value, const std::string &suffix);
std::string path_text(const fs::path &path);
std::string generic_path_text(const fs::path &path);

// little-endian bytes
u32 read_u32(const Bytes &data, size_t offset, const char *message = "truncated 32-bit field");
u64 read_u64(const Bytes &data, size_t offset, const char *message = "truncated 64-bit field");
u32 read_u32(const u8 *data);
void write_u32(Bytes &out, u32 value);
void write_u64(Bytes &out, u64 value);
void overwrite_u32(Bytes &out, size_t offset, u32 value);
void append_bytes(Bytes &out, const Bytes &value);
void append_bytes(Bytes &out, const Hash8 &value);
Bytes slice_bytes(const Bytes &data, size_t start, size_t end);
Hash8 slice_hash8(const Bytes &data, size_t offset);
std::string hex_bytes(const u8 *data, size_t count, bool reverse = false);
std::optional<u8> hex_digit(char c);
std::optional<Bytes> parse_hex(const std::string &value);

// files
Bytes read_file(const fs::path &path);
std::string read_text_file(const fs::path &path);
void write_file(const fs::path &path, const Bytes &data);
bool file_equals_bytes(const fs::path &path, const Bytes &data);
bool files_equal(const fs::path &left, const fs::path &right);
void atomic_write(const fs::path &path, const Bytes &data);
void atomic_copy(const fs::path &source, const fs::path &destination);

// hashes
u32 crc32_bytes(const u8 *data, size_t size, u32 crc = 0);
std::string crc32_file(const fs::path &path);
u64 murmur64(const u8 *data, size_t size);
// Stingray resource identity: murmur64 of the name (or the raw value of "#ID[16 hex]"), as little-endian bytes and
// as 16 hex digits
std::pair<Hash8, std::string> identity_hash(const std::string &value);
std::string murmur64_hex(const std::string &value);

} // namespace ca

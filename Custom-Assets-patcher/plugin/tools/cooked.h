#pragma once

// cooked Darktide resources: the 38-byte envelope, material headers, texture bodies and package resources

#include "common.h"

#include <string>
#include <utility>
#include <vector>

namespace ca {

inline constexpr const char *BASE_BUNDLE = "a2bbcc3451758add";          // bundle whose header the patches copy
inline constexpr const char *STORAGE_BASE_BUNDLE = "9ba626afa44a3aa3";  // holds packages/boot_assets
inline constexpr size_t HEADER_BYTES = 268;
inline constexpr size_t INDEX_RECORD_BYTES = 20;
inline constexpr size_t MAX_INDEX_RECORDS = 65536;
inline constexpr size_t PATCH_CHUNK_SIZE = 0x80000;
inline constexpr u64 MAX_PATCH_PAYLOAD = 0xffffffffull;
inline constexpr int PACKAGE_VERSION = 43;
inline constexpr u8 PACKAGE_FOOTER = 1;
inline constexpr size_t MATERIAL_HEADER_BYTES = 68;
inline constexpr size_t MATERIAL_STREAM_PATH_OFFSET = 38;
inline constexpr size_t MATERIAL_STREAM_PATH_BYTES = 30;

struct CookedEnvelope {
    u32 kind = 0;
    u8 unknown1 = 0;
    u32 body_size = 0;
    u32 tail_size = 0;
    Bytes body;
    Bytes tail;
};

struct TextureInfo {
    u32 kind = 0;
    u32 compressed_resident_bytes = 0;
    u32 resident_dds_bytes = 0;
    u32 body_flags = 0;
    u32 streamed_mips = 0;
    u32 width = 0;
    u32 height = 0;
    u32 chunk_count = 0;
    u32 compressed_stream_bytes = 0;
    u32 footer_word = 0;
    std::string stream_name;
};

struct PackageEntry {
    std::string engine_type;
    std::string name;

    std::string typed_key() const {
        return engine_type + std::string(1, '\0') + name;
    }
};

// streams: "data/..." paths owned by an asset, or retail "data/<2 hex>/<16 hex>" ones a material may point at
bool safe_data_stream(const std::string &value);
bool retail_stream(const std::string &value);

CookedEnvelope inspect_cooked_envelope(const Bytes &blob);
std::string stream_name_from_tail(const Bytes &tail);
std::pair<std::string, u64> inspect_material_header(const Bytes &blob);
TextureInfo inspect_texture_body(const Bytes &blob);
Bytes wrap_cooked(const std::string &engine_type, const std::string &name, const Bytes &body);

std::string package_resource_name(const std::string &logical_id);
std::vector<PackageEntry> normalize_entries(std::vector<PackageEntry> entries);
Bytes build_package_blob(const std::string &package_name, std::vector<PackageEntry> entries);
std::vector<std::pair<Hash8, Hash8>> parse_package_blob(const Bytes &blob);

} // namespace ca

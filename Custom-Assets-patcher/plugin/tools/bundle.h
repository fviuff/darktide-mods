#pragma once

// bundles: the patch-bundle writer (one bundle per asset, the boot patch), retail bundle reading

#include "common.h"

#include <map>
#include <optional>
#include <string>
#include <vector>

namespace ca {

class DarktideOodleTextureCodec;

struct ResourceSpec {
    std::string engine_type;
    std::string name;
    fs::path source;
    int mode = 0;
    bool host_unit_mode = false;
    std::optional<fs::path> stream_source;
    bool retail_stream_reference = false;

    std::string typed_key() const {
        return engine_type + std::string(1, '\0') + name;
    }
};

struct HostBundleMetadata {
    Bytes template_identity;
    Bytes type_data;
    int unit_mode = 0;
    u32 file_count = 0;
};

struct ValidatedResource {
    ResourceSpec spec;
    int mode = 0;
    Bytes blob;
    Hash8 type_hash_le{};
    Hash8 name_hash_le{};
    std::string type_hash_hex;
    std::string name_hash_hex;
    std::string stream_name;
};

struct BuildPayload {
    Bytes patch_bytes;
    std::vector<ValidatedResource> resources;
    std::map<std::string, fs::path> stream_sources;
};

HostBundleMetadata read_host_metadata(const fs::path &path);
// checks every resource against its cooked header and writes them into one patch bundle
BuildPayload build_payload(const std::vector<ResourceSpec> &resources, const HostBundleMetadata &metadata);
bool bundle_contains_identity(const fs::path &path, const std::string &engine_type, const std::string &name);
Bytes extract_bundle_resource(const fs::path &path, const std::string &engine_type, const std::string &name,
                              DarktideOodleTextureCodec &codec);
// packages/boot_assets with our packages added, so the game keeps them resident (boot carrier patch_998)
Bytes extend_boot_package(Bytes blob, const std::vector<ResourceSpec> &packages);

} // namespace ca

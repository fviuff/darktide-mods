#pragma once

// finding assets: mods/<Mod>/Custom/<Folder>/ with a compiler build.json, or any folder of cooked resources;
// a folder that cant be used is skipped with its reason; it never stops the others

#include "bundle.h"
#include "json.h"

#include <map>
#include <set>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace ca {

struct ExternalResource {
    std::string engine_type;
    std::string name;
    bool package_member = false;
};

struct AssetSpec {
    std::string logical_id;                  // <Mod>:<Folder>
    std::string owner;
    std::string asset_id;
    std::string kind;
    std::optional<std::string> unit_kind;
    fs::path source_path;
    std::string source_relative;
    std::string source_kind;                 // compiler | folder
    std::string primary_engine_type;
    std::string primary_name;
    std::vector<ResourceSpec> resources;     // the last one is the package
    JsonValue metadata = JsonValue::object_value();
    std::vector<ExternalResource> external_resources;
    std::string package_name;                // content/mods/custom_assets/packages/<murmur64 of the logical id>
    Bytes package_blob;                      // generated, never written into the mod folder
};

struct SkippedAsset {
    std::string folder;                      // mods/<Mod>/Custom/<Folder>
    std::string reason;
};

struct ScanResult {
    std::vector<AssetSpec> assets;
    std::vector<SkippedAsset> skipped;
    std::vector<std::string> warnings;
};

std::pair<Hash8, Hash8> resource_hash_key(const std::string &engine_type, const std::string &name);
// installed: logical ids of the last install; they win over newcomers that carry the same resources
ScanResult scan_assets(const fs::path &game_root, const std::set<std::string> &installed);
// drops assets whose custom dependencies are gone (skipped elsewhere), until nothing changes
void drop_broken_dependents(std::vector<AssetSpec> &assets, std::vector<SkippedAsset> &skipped);
// runtime package member lists: an asset's own resources plus those of the custom assets it uses
std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> runtime_package_definitions(const std::vector<AssetSpec> &assets);
std::string asset_folder_text(const AssetSpec &asset);

} // namespace ca

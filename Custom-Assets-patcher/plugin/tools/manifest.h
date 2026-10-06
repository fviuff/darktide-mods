#pragma once

// the manifest the CustomAssets mod reads (Lua) and its JSON twin for people and tools

#include "assets.h"

#include <map>
#include <string>
#include <utility>
#include <vector>

namespace ca {

JsonValue build_manifest(const fs::path &game_root, const std::vector<AssetSpec> &assets, const BuildPayload &payload,
                         const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &package_definitions,
                         size_t bundle_count, const std::vector<SkippedAsset> &skipped);
Bytes json_bytes(const JsonValue &manifest);
Bytes lua_bytes(const JsonValue &manifest);

} // namespace ca

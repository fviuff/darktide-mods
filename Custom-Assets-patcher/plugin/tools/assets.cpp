#include "assets.h"
#include "cooked.h"

#include <algorithm>
#include <fstream>
#include <iomanip>
#include <queue>
#include <set>
#include <sstream>

namespace ca {
namespace {

// warnings of the folder being read (stale build.json sizes and the like); they never stop an asset
std::vector<std::string> *warnings_sink = nullptr;
void warn(const std::string &message) { if (warnings_sink) warnings_sink->push_back(message); }

const std::vector<std::string> KNOWN_ENGINE_TYPES = {
    "animation", "animation_curves", "bik", "bk2", "blend_set", "bones", "chroma", "common_package",
    "config", "data", "entity", "flow", "font", "ies", "ini", "ivf", "keys", "level", "lua", "material",
    "mod", "mouse_cursor", "navdata", "network_config", "oodle_net", "package", "particles", "physics_properties",
    "render_config", "rt_pipeline", "scene", "shader", "shader_library", "shader_library_group", "shading_environment",
    "shading_environment_mapping", "slug", "slug_album", "state_machine", "strings", "texture", "theme", "tome", "unit",
    "vector_field", "wwise_bank", "wwise_dep", "wwise_event", "wwise_metadata", "wwise_stream",
};

const std::array<const char *, 7> PRIMARY_PRIORITY = {
    "unit", "material", "texture", "animation", "bones", "state_machine", "particles",
};

bool opaque_id(const std::string &value) {
    if (value.size() != 21 || value.compare(0, 4, "#ID[") != 0 || value.back() != ']') {
        return false;
    }

    for (size_t i = 4; i < 20; ++i) {
        if (!hex_digit(value[i])) {
            return false;
        }
    }

    return true;
}

bool safe_engine_type(const std::string &value) {
    if (opaque_id(value)) {
        return true;
    }

    if (value.empty()) {
        return false;
    }

    for (char c : value) {
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-')) {
            return false;
        }
    }

    return true;
}

bool safe_resource_name_chars(const std::string &value) {
    if (value.empty()) {
        return false;
    }

    for (char c : value) {
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '_' || c == '.' || c == '/' || c == '-')) {
            return false;
        }
    }

    return true;
}

bool safe_relative_segments(const std::string &value) {
    size_t start = 0;

    while (start <= value.size()) {
        const size_t end = value.find('/', start);
        const std::string part = value.substr(start, end == std::string::npos ? std::string::npos : end - start);

        if (part.empty() || part == "." || part == "..") {
            return false;
        }

        if (end == std::string::npos) {
            break;
        }

        start = end + 1;
    }

    return true;
}

std::string require_string(const JsonValue *value, const std::string &field) {
    if (!value || value->kind != JsonValue::String || value->string.empty()) {
        throw PatcherError(field + " must be a non-empty string");
    }

    return value->string;
}


std::string validate_id(const std::string &value, const std::string &field) {
    if (value.empty() || value == "." || value == ".." || value.size() > 128) {
        throw PatcherError(field + " must be a usable filename-sized ID");
    }

    for (unsigned char c : value) {
        if (c < 32 || c == '/' || c == '\\' || c == ':' || c == 0) {
            throw PatcherError(field + " may not contain path separators, colon, NUL, or control characters");
        }
    }

    return value;
}

std::string validate_engine_type(const JsonValue *value, const std::string &field) {
    const std::string text = require_string(value, field);

    if (!safe_engine_type(text)) {
        throw PatcherError(field + " is not a valid engine type or #ID[16hex] identity");
    }

    return text;
}

std::string validate_resource_name(std::string text, const std::string &field) {
    if (text.empty()) {
        throw PatcherError(field + " must be a non-empty string");
    }

    std::replace(text.begin(), text.end(), '\\', '/');

    if (opaque_id(text)) {
        return text;
    }

    if (text.front() == '/' || text.find(':') != std::string::npos || text.find('\0') != std::string::npos || !safe_resource_name_chars(text)) {
        throw PatcherError(field + " is not a safe Darktide resource name");
    }

    if (!safe_relative_segments(text)) {
        throw PatcherError(field + " contains an unsafe path segment");
    }

    return text;
}

std::string validate_resource_name(const JsonValue *value, const std::string &field) {
    return validate_resource_name(require_string(value, field), field);
}

fs::path safe_relative(const fs::path &base, std::string text, const std::string &field) {
    if (text.empty()) {
        throw PatcherError(field + " must be a non-empty string");
    }

    std::replace(text.begin(), text.end(), '\\', '/');

    if (text.front() == '/' || text.find(':') != std::string::npos || text.find('\0') != std::string::npos || !safe_relative_segments(text)) {
        throw PatcherError(field + " must be relative to the asset folder");
    }

    fs::path candidate = base;
    size_t start = 0;

    while (start <= text.size()) {
        const size_t end = text.find('/', start);
        candidate /= text.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (end == std::string::npos) break;
        start = end + 1;
    }

    const fs::path root = fs::weakly_canonical(base);
    const fs::path resolved = fs::weakly_canonical(candidate);
    const fs::path relative = resolved.lexically_relative(root);

    if (relative.empty() || starts_with(generic_path_text(relative), "..")) {
        throw PatcherError(field + " escapes the asset folder");
    }

    return resolved;
}

JsonValue read_json(const fs::path &path) {
    try {
        JsonValue value = parse_json(read_text_file(path));

        if (value.kind != JsonValue::Object) {
            throw PatcherError(path_text(path.filename()) + " is not a JSON object");
        }

        return value;
    } catch (const PatcherError &) {
        throw;
    } catch (const std::exception &exc) {
        throw PatcherError(path_text(path.filename()) + " is not valid JSON: " + exc.what());
    }
}

std::pair<std::string, std::string> json_key(const JsonValue *raw, const std::string &field) {
    if (!raw || raw->kind != JsonValue::Object) {
        throw PatcherError(field + " must be an object");
    }

    const JsonValue *type = raw->get("type");
    if (!type) type = raw->get("engine_type");
    return {
        validate_engine_type(type, field + ".type"),
        validate_resource_name(raw->get("name"), field + ".name"),
    };
}

bool eight_hex(const std::string &value) {
    if (value.size() != 8) return false;
    for (char c : value) if (!hex_digit(c)) return false;
    return true;
}

fs::path verify_file_record(const fs::path &base, const JsonValue *raw, const std::string &field, bool allow_missing) {
    if (!raw || raw->kind != JsonValue::Object) {
        throw PatcherError(field + " must be an object");
    }

    const fs::path path = safe_relative(base, require_string(raw->get("path"), field + ".path"), field + ".path");
    const JsonValue *size_value = raw->get("size");
    const JsonValue *crc_value = raw->get("crc32");

    std::error_code ec;

    if (!fs::is_regular_file(path, ec)) {
        if (allow_missing && !fs::exists(path, ec)) {
            return path;
        }
        throw PatcherError(field + ".path does not exist: " + path_text(path));
    }

    const u64 actual_size = fs::file_size(path, ec);

    const bool size_differs = size_value && size_value->kind == JsonValue::Integer && (ec || actual_size != static_cast<u64>(size_value->integer));
    const bool crc_differs = !size_differs && crc_value && crc_value->kind == JsonValue::String && eight_hex(crc_value->string) &&
        lower_ascii(crc32_file(path)) != lower_ascii(crc_value->string);
    if (size_differs || crc_differs) warn(path_text(path.filename()) + " changed since build.json was written; using the file as it is");

    return path;
}

std::vector<std::pair<Hash8, Hash8>> verify_package_identity(const ResourceSpec &package, const fs::path &source, const Bytes *blob = nullptr) {
    try {
        const Bytes payload = blob ? *blob : read_file(package.source);
        const auto entries = parse_package_blob(payload);
        const Hash8 expected_name_hash = identity_hash(package.name).first;

        if (payload.size() < 16 || !std::equal(expected_name_hash.begin(), expected_name_hash.end(), payload.begin() + 8)) {
            throw PatcherError("package header identity does not match " + package.name);
        }

        return entries;
    } catch (const std::exception &exc) {
        throw PatcherError(path_text(source) + ": invalid package resource: " + exc.what());
    }
}

std::vector<PackageEntry> direct_package_entries(const std::vector<ResourceSpec> &resources, const std::vector<ExternalResource> &external_resources) {
    std::vector<PackageEntry> rows;

    for (const auto &resource : resources) {
        if (resource.engine_type != "package") {
            rows.push_back({resource.engine_type, resource.name});
        }
    }

    for (const auto &resource : external_resources) {
        if (resource.package_member) {
            rows.push_back({resource.engine_type, resource.name});
        }
    }

    return normalize_entries(std::move(rows));
}

std::vector<ExternalResource> compiler_external_resources(const JsonValue &build, const fs::path &source) {
    const JsonValue *raw_refs = build.get("external_resources");

    if (!raw_refs) {
        return {};
    }

    if (raw_refs->kind != JsonValue::Array) {
        warn(path_text(source) + ": external_resources is not a list; ignored");
        return {};
    }

    std::map<std::pair<std::string, std::string>, bool> refs;

    for (size_t i = 0; i < raw_refs->array.size(); ++i) {
        const JsonValue &raw = raw_refs->array[i];
        const std::string prefix = path_text(source) + ": external_resources[" + std::to_string(i + 1) + "]";

        if (raw.kind != JsonValue::Object) {
            warn(prefix + " is not an object; ignored");
            continue;
        }

        std::pair<std::string, std::string> key;
        try {
            key = json_key(raw.get("key"), prefix + ".key");
        } catch (const std::exception &exc) {
            warn(std::string(exc.what()) + "; ignored");
            continue;
        }
        bool package_member = false;
        const JsonValue *member = raw.get("package_member");

        if (member) {
            package_member = member->kind == JsonValue::Boolean && member->boolean;
        }

        refs[key] = refs[key] || package_member;
    }

    std::vector<ExternalResource> out;

    for (const auto &item : refs) {
        out.push_back({item.first.first, item.first.second, item.second});
    }

    return out;
}

std::optional<std::string> unit_kind_for(const std::string &kind, const std::vector<ResourceSpec> &resources) {
    if (kind != "unit") {
        return std::nullopt;
    }

    bool animation = false;
    bool bones = false;

    for (const auto &resource : resources) {
        animation = animation || resource.engine_type == "animation";
        bones = bones || resource.engine_type == "bones";
    }

    return animation ? "animated" : bones ? "rigged" : "static";
}

bool known_kind(const std::string &kind) {
    return kind != "package" && std::find(KNOWN_ENGINE_TYPES.begin(), KNOWN_ENGINE_TYPES.end(), kind) != KNOWN_ENGINE_TYPES.end();
}

std::string opaque_hash(const Hash8 &hash) {
    return "#ID[" + hex_bytes(hash.data(), hash.size(), true) + "]";
}

std::string recover_resource_name(const fs::path &asset_dir, const fs::path &path, const Hash8 &name_hash) {
    std::error_code ec;
    const std::string relative = generic_path_text(fs::relative(path, asset_dir, ec));
    std::vector<std::string> candidates;
    candidates.push_back(ec ? generic_path_text(path.filename()) : relative);
    const std::string filename = candidates.front().substr(candidates.front().find_last_of('/') == std::string::npos ? 0 : candidates.front().find_last_of('/') + 1);

    if (filename.find('.') != std::string::npos) {
        const size_t dot = candidates.front().find_last_of('.');
        candidates.push_back(candidates.front().substr(0, dot));
    }

    candidates.push_back(generic_path_text(path.stem()));
    std::set<std::string> seen;

    for (std::string candidate : candidates) {
        std::replace(candidate.begin(), candidate.end(), '\\', '/');
        if (candidate.empty() || !seen.insert(candidate).second) continue;

        try {
            const std::string validated = validate_resource_name(candidate, path_text(path) + ": inferred resource name");
            if (identity_hash(validated).first == name_hash) return validated;
        } catch (...) {
        }
    }

    return opaque_hash(name_hash);
}

struct CookedHeader {
    Hash8 type_hash{};
    Hash8 name_hash{};
    std::string stream_name;
};

std::optional<CookedHeader> read_cooked_header(const fs::path &path) {
    std::error_code ec;
    const u64 size = fs::file_size(path, ec);
    if (ec || size < 16) return std::nullopt;

    std::ifstream file(path, std::ios::binary);
    if (!file) return std::nullopt;
    std::array<u8, 38> prefix{};
    file.read(reinterpret_cast<char *>(prefix.data()), static_cast<std::streamsize>(std::min<u64>(38, size)));
    if (file.gcount() < 16) return std::nullopt;
    Hash8 type_hash{};
    Hash8 name_hash{};
    std::copy_n(prefix.begin(), 8, type_hash.begin());
    std::copy_n(prefix.begin() + 8, 8, name_hash.begin());
    const Hash8 material_type = identity_hash("material").first;

    if (type_hash == material_type && size == MATERIAL_HEADER_BYTES) {
        try {
            const Bytes blob = read_file(path);
            return CookedHeader{type_hash, name_hash, inspect_material_header(blob).first};
        } catch (...) {
            return std::nullopt;
        }
    }

    if (file.gcount() < 38) return std::nullopt;
    if (read_u32(prefix.data() + 16) != 1 || (prefix[28] != 0 && prefix[28] != 1) || prefix[33] != 1) return std::nullopt;
    const u32 body_size = read_u32(prefix.data() + 29);
    const u32 tail_size = read_u32(prefix.data() + 34);
    if (size != 38ull + body_size + tail_size) return std::nullopt;
    Bytes tail;

    if (tail_size) {
        tail.resize(tail_size);
        file.clear();
        file.seekg(static_cast<std::streamoff>(38ull + body_size), std::ios::beg);
        file.read(reinterpret_cast<char *>(tail.data()), static_cast<std::streamsize>(tail.size()));
        if (file.gcount() != static_cast<std::streamsize>(tail.size())) return std::nullopt;
    }

    return CookedHeader{type_hash, name_hash, stream_name_from_tail(tail)};
}

std::vector<fs::path> generic_files(const fs::path &asset_dir) {
    std::vector<fs::path> files;
    const fs::path root = fs::weakly_canonical(asset_dir);

    for (fs::recursive_directory_iterator it(asset_dir), end; it != end; ++it) {
        const fs::path path = it->path();

        if (it->is_symlink()) {
            throw PatcherError(path_text(asset_dir) + ": symlinks are not supported in descriptor-free asset folders: " + path_text(path));
        }

        if (!it->is_regular_file()) continue;
        const fs::path resolved = fs::weakly_canonical(path);
        const std::string relative = generic_path_text(resolved.lexically_relative(root));
        if (relative.empty() || starts_with(relative, "..")) {
            throw PatcherError(path_text(asset_dir) + ": file escapes the asset folder: " + path_text(path));
        }
        files.push_back(path);
    }

    std::sort(files.begin(), files.end(), [](const fs::path &a, const fs::path &b) {
        return lower_ascii(generic_path_text(a)) < lower_ascii(generic_path_text(b));
    });
    return files;
}

std::optional<fs::path> find_owned_stream(
    const fs::path &asset_dir,
    const std::string &stream_name,
    const std::map<std::string, fs::path> &by_relative,
    const std::map<std::string, std::vector<fs::path>> &by_name,
    const fs::path *exclude
) {
    std::string normalized = lower_ascii(stream_name);
    std::replace(normalized.begin(), normalized.end(), '\\', '/');
    while (!normalized.empty() && normalized.front() == '/') normalized.erase(normalized.begin());
    std::vector<std::string> candidates{normalized};
    if (ends_with(normalized, ".stream")) candidates.push_back(normalized.substr(0, normalized.size() - 7));
    else candidates.push_back(normalized + ".stream");

    for (const auto &candidate : candidates) {
        const auto it = by_relative.find(candidate);
        if (it != by_relative.end() && (!exclude || it->second != *exclude)) return it->second;
    }

    std::vector<fs::path> hits;
    for (const auto &candidate : candidates) {
        const std::string name = generic_path_text(fs::path(candidate).filename());
        const auto it = by_name.find(name);
        if (it == by_name.end()) continue;
        for (const auto &path : it->second) {
            if (exclude && path == *exclude) continue;
            if (std::find(hits.begin(), hits.end(), path) == hits.end()) hits.push_back(path);
        }
    }

    if (hits.size() == 1) return hits.front();
    if (hits.size() > 1) throw PatcherError(path_text(asset_dir) + ": stream '" + stream_name + "' is ambiguous; keep the stream at its declared relative path");
    return std::nullopt;
}

} // namespace

std::pair<Hash8, Hash8> resource_hash_key(const std::string &engine_type, const std::string &name) {
    return {identity_hash(engine_type).first, identity_hash(name).first};
}

std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> runtime_package_definitions(const std::vector<AssetSpec> &assets) {
    std::map<std::string, const AssetSpec *> by_id;
    std::map<std::pair<Hash8, Hash8>, std::string> resource_owners;
    for (const auto &asset : assets) {
        by_id[asset.logical_id] = &asset;
        for (const auto &resource : asset.resources) if (resource.engine_type != "package") resource_owners[resource_hash_key(resource.engine_type, resource.name)] = asset.logical_id;
    }

    std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> definitions;

    for (const auto &asset : assets) {
        const auto package_it = std::find_if(asset.resources.begin(), asset.resources.end(), [](const ResourceSpec &r) { return r.engine_type == "package"; });
        if (package_it == asset.resources.end()) throw PatcherError("asset has no package resource: " + asset.logical_id);
        std::queue<std::string> queue;
        queue.push(asset.logical_id);
        std::set<std::string> visited;
        std::set<std::pair<Hash8, Hash8>> members;

        while (!queue.empty()) {
            const std::string logical_id = queue.front();
            queue.pop();
            if (!visited.insert(logical_id).second) continue;
            const AssetSpec &provider = *by_id.at(logical_id);
            for (const auto &resource : provider.resources) if (resource.engine_type != "package") members.insert(resource_hash_key(resource.engine_type, resource.name));
            for (const auto &external : provider.external_resources) {
                if (!external.package_member) continue;
                const auto key = resource_hash_key(external.engine_type, external.name);
                const auto target = resource_owners.find(key);
                if (target != resource_owners.end()) {
                    if (!visited.count(target->second)) queue.push(target->second);
                } else {
                    members.insert(key);
                }
            }
        }

        std::vector<std::pair<Hash8, Hash8>> entries(members.begin(), members.end());
        auto previous = definitions.find(package_it->name);
        if (previous != definitions.end() && previous->second != entries) throw PatcherError("conflicting runtime package definition: " + package_it->name);
        definitions[package_it->name] = std::move(entries);
    }

    return definitions;
}

std::string asset_folder_text(const AssetSpec &asset) {
    return "mods/" + asset.owner + "/Custom/" + asset.asset_id;
}

namespace {

// the primary resource: the first build.json root the folder owns, by kind priority; else the folder's own
// resources by the same priority
std::pair<std::string, std::string> pick_primary(const JsonValue *roots, const std::vector<ResourceSpec> &resources) {
    std::set<std::string> local;
    for (const auto &resource : resources) local.insert(resource.typed_key());
    std::vector<std::pair<std::string, std::string>> candidates;
    if (roots && roots->kind == JsonValue::Array)
        for (const auto &root : roots->array) {
            try {
                const auto key = json_key(&root, "roots");
                if (local.count(key.first + std::string(1, '\0') + key.second)) candidates.push_back(key);
            } catch (const std::exception &) {
            }
        }
    if (candidates.empty())
        for (const auto &resource : resources) candidates.push_back({resource.engine_type, resource.name});
    for (const char *preferred : PRIMARY_PRIORITY)
        for (const auto &key : candidates) if (key.first == preferred) return key;
    return candidates.front();
}

// the package every asset gets: its resources plus the externals it lists as package members. the name depends
// only on the mod and folder names, so it is the same on every install (mods can load it without the API)
void add_package(AssetSpec &asset, std::string package_name) {
    asset.package_name = package_name.empty() ? package_resource_name(asset.logical_id) : std::move(package_name);
    asset.package_blob = build_package_blob(asset.package_name, direct_package_entries(asset.resources, asset.external_resources));
    ResourceSpec package;
    package.engine_type = "package";
    package.name = asset.package_name;
    asset.resources.push_back(std::move(package));   // source: written to the staging folder at install time
}

AssetSpec parse_compiler_asset(const fs::path &custom_root, const std::string &owner, const fs::path &asset_dir, const JsonValue &build) {
    const fs::path build_path = asset_dir / "build.json";
    const JsonValue *target = build.get("target");
    if (target && target->kind == JsonValue::Object && target->get("id") && target->get("id")->kind == JsonValue::String &&
        target->get("id")->string != "darktide")
        throw PatcherError("build.json is for another game (" + target->get("id")->string + ")");
    const JsonValue *schema = build.get("schema");
    if (!schema || schema->kind != JsonValue::Integer || schema->integer != 1)
        warn("build.json schema is not 1; reading it anyway");

    AssetSpec out;
    out.owner = owner;
    out.asset_id = validate_id(path_text(asset_dir.filename()), "asset folder name");
    out.logical_id = owner + ":" + out.asset_id;
    const JsonValue *resources_raw = build.get("resources");
    if (!resources_raw || resources_raw->kind != JsonValue::Array || resources_raw->array.empty())
        throw PatcherError("build.json lists no resources");

    std::set<std::string> local_keys;
    for (size_t i = 0; i < resources_raw->array.size(); ++i) {
        const JsonValue &item = resources_raw->array[i];
        const std::string prefix = "resources[" + std::to_string(i + 1) + "]";
        if (item.kind != JsonValue::Object) throw PatcherError(prefix + " is not an object");
        const auto key = json_key(item.get("key"), prefix + ".key");
        ResourceSpec spec;
        spec.engine_type = key.first;
        spec.name = key.second;
        spec.source = verify_file_record(asset_dir, item.get("file"), prefix + ".file", false);
        const JsonValue *stream = item.get("stream");
        if (stream && stream->kind == JsonValue::Object)
            spec.stream_source = verify_file_record(asset_dir, stream->get("file"), prefix + ".stream.file", false);
        if (spec.engine_type == "material" && !spec.stream_source) {
            try {
                spec.retail_stream_reference = retail_stream(inspect_material_header(read_file(spec.source)).first);
            } catch (const std::exception &) {
            }
        }
        spec.host_unit_mode = spec.engine_type == "unit";
        if (!local_keys.insert(spec.typed_key()).second) {
            warn("build.json lists " + spec.engine_type + "/" + spec.name + " twice; using the first");
            continue;
        }
        out.resources.push_back(std::move(spec));
    }
    out.external_resources = compiler_external_resources(build, build_path);

    std::string package_name;
    if (const JsonValue *package = build.get("package"); package && package->kind == JsonValue::Object) {
        try {
            const auto key = json_key(package->get("key"), "package.key");
            if (key.first == "package") package_name = key.second;
        } catch (const std::exception &) {
            warn("build.json package key can't be read; using the generated package name");
        }
    }
    const auto primary = pick_primary(build.get("roots"), out.resources);
    out.primary_engine_type = primary.first;
    out.primary_name = primary.second;
    out.kind = known_kind(primary.first) ? primary.first : "generic";
    out.unit_kind = unit_kind_for(out.kind, out.resources);
    out.source_path = build_path;
    std::error_code ec;
    out.source_relative = generic_path_text(fs::relative(build_path, custom_root, ec));
    if (ec) out.source_relative = "build.json";
    out.source_kind = "compiler";
    if (const JsonValue *compiler = build.get("compiler")) out.metadata.set("compiler", *compiler);
    if (target) out.metadata.set("target", *target);
    add_package(out, package_name);
    return out;
}

AssetSpec parse_generic_asset(const fs::path &custom_root, const std::string &owner, const fs::path &asset_dir) {
    AssetSpec out;
    out.owner = owner;
    out.asset_id = validate_id(path_text(asset_dir.filename()), "asset folder name");
    out.logical_id = owner + ":" + out.asset_id;
    const auto files = generic_files(asset_dir);
    std::map<std::string, fs::path> by_relative;
    std::map<std::string, std::vector<fs::path>> by_name;
    for (const auto &path : files) {
        std::error_code ec;
        by_relative[lower_ascii(generic_path_text(fs::relative(path, asset_dir, ec)))] = path;
        by_name[lower_ascii(generic_path_text(path.filename()))].push_back(path);
    }
    std::map<Hash8, std::string> known_type_by_hash;
    for (const auto &type : KNOWN_ENGINE_TYPES) known_type_by_hash[identity_hash(type).first] = type;

    std::vector<ResourceSpec> candidates;
    for (const auto &path : files) {
        const auto inspected = read_cooked_header(path);
        if (!inspected) continue;
        const auto known = known_type_by_hash.find(inspected->type_hash);
        const std::string engine_type = known == known_type_by_hash.end() ? opaque_hash(inspected->type_hash) : known->second;
        if (engine_type == "package") continue;   // the patcher makes its own package
        ResourceSpec spec;
        spec.engine_type = engine_type;
        spec.name = recover_resource_name(asset_dir, path, inspected->name_hash);
        spec.source = path;
        spec.host_unit_mode = engine_type == "unit";
        if (!inspected->stream_name.empty()) {
            const std::string &stream = inspected->stream_name;
            if (stream.find('\\') != std::string::npos)
                throw PatcherError(path_text(path.filename()) + " names its stream with backslashes: " + stream);
            if (safe_data_stream(stream)) spec.stream_source = find_owned_stream(asset_dir, stream, by_relative, by_name, &path);
            if (!spec.stream_source && engine_type == "material" && retail_stream(stream)) spec.retail_stream_reference = true;
            else if (!spec.stream_source) throw PatcherError(path_text(path.filename()) + " uses stream " + stream + ", which is not in the folder");
        }
        candidates.push_back(std::move(spec));
    }
    // a stream file can look like a cooked resource; it is not one
    std::set<fs::path> stream_paths;
    for (const auto &resource : candidates) if (resource.stream_source) stream_paths.insert(fs::weakly_canonical(*resource.stream_source));
    std::set<std::string> seen;
    for (auto &resource : candidates) {
        if (stream_paths.count(fs::weakly_canonical(resource.source))) continue;
        if (!seen.insert(resource.typed_key()).second) {
            warn("two files are " + resource.engine_type + "/" + resource.name + "; using the first");
            continue;
        }
        out.resources.push_back(std::move(resource));
    }
    if (out.resources.empty()) throw PatcherError("no Darktide resources found in the folder");

    const auto primary = pick_primary(nullptr, out.resources);
    out.primary_engine_type = primary.first;
    out.primary_name = primary.second;
    out.kind = known_kind(primary.first) ? primary.first : "generic";
    out.unit_kind = unit_kind_for(out.kind, out.resources);
    out.source_path = asset_dir;
    std::error_code ec;
    out.source_relative = generic_path_text(fs::relative(asset_dir, custom_root, ec));
    if (ec) out.source_relative = path_text(asset_dir.filename());
    out.source_kind = "folder";
    out.metadata.set("discovery", JsonValue::string_value("cooked_folder"));
    add_package(out, {});
    return out;
}

bool is_custom_dependency(const ExternalResource &external) {
    return starts_with(external.name, "content/mods/custom_assets/");
}

} // namespace

void drop_broken_dependents(std::vector<AssetSpec> &assets, std::vector<SkippedAsset> &skipped) {
    for (bool changed = true; changed;) {
        changed = false;
        std::set<std::pair<Hash8, Hash8>> provided;
        for (const auto &asset : assets)
            for (const auto &resource : asset.resources) provided.insert(resource_hash_key(resource.engine_type, resource.name));
        for (auto it = assets.begin(); it != assets.end();) {
            const auto missing = std::find_if(it->external_resources.begin(), it->external_resources.end(), [&](const auto &external) {
                return is_custom_dependency(external) && !provided.count(resource_hash_key(external.engine_type, external.name));
            });
            if (missing == it->external_resources.end()) { ++it; continue; }
            skipped.push_back({asset_folder_text(*it), "uses " + missing->engine_type + "/" + missing->name + ", which no installed asset provides"});
            it = assets.erase(it);
            changed = true;
        }
    }
}

ScanResult scan_assets(const fs::path &game_root, const std::set<std::string> &installed) {
    ScanResult result;
    const fs::path mods_root = game_root / "mods";
    std::error_code ec;
    if (!fs::is_directory(mods_root, ec)) throw PatcherError("mods folder not found: " + path_text(mods_root));
    warnings_sink = &result.warnings;
    const auto by_name = [](const fs::path &a, const fs::path &b) { return lower_ascii(path_text(a.filename())) < lower_ascii(path_text(b.filename())); };
    // folders in a folder, by name; one that can't be read is left out
    const auto subfolders = [&](const fs::path &parent) {
        std::vector<fs::path> out;
        std::error_code walk;
        for (fs::directory_iterator next(parent, walk), last; !walk && next != last; next.increment(walk)) {
            std::error_code entry;
            if (next->is_directory(entry)) out.push_back(next->path());
        }
        std::sort(out.begin(), out.end(), by_name);
        return out;
    };
    const std::vector<fs::path> mod_dirs = subfolders(mods_root);

    std::vector<AssetSpec> parsed;
    for (const auto &mod_dir : mod_dirs) {
        const std::string owner = path_text(mod_dir.filename());
        if (lower_ascii(owner) == "customassets" || starts_with(owner, "_")) continue;
        if (!fs::is_regular_file(mod_dir / (owner + ".mod"), ec)) continue;
        const fs::path custom_root = mod_dir / "Custom";
        if (!fs::is_directory(custom_root, ec)) continue;
        for (const auto &asset_dir : subfolders(custom_root)) {
            const std::string folder = "mods/" + owner + "/Custom/" + path_text(asset_dir.filename());
            const size_t first_warning = result.warnings.size();
            try {
                if (fs::is_symlink(asset_dir, ec)) throw PatcherError("linked folders are not read");
                const fs::path build_path = asset_dir / "build.json";
                bool compiler = false;
                JsonValue build;
                if (fs::is_regular_file(build_path, ec)) {
                    build = read_json(build_path);
                    const JsonValue *tool = build.get("compiler");
                    const JsonValue *name = tool && tool->kind == JsonValue::Object ? tool->get("name") : nullptr;
                    compiler = name && name->kind == JsonValue::String && name->string == "DarktideGLBCompiler";
                }
                parsed.push_back(compiler ? parse_compiler_asset(custom_root, owner, asset_dir, build)
                                          : parse_generic_asset(custom_root, owner, asset_dir));
            } catch (const std::exception &exc) {
                result.skipped.push_back({folder, exc.what()});
            }
            for (size_t i = first_warning; i < result.warnings.size(); ++i) result.warnings[i] = folder + ": " + result.warnings[i];
        }
    }
    warnings_sink = nullptr;

    // the same resource (or the same name hash) in two folders: an asset installed last time keeps it, otherwise
    // the first in mod / folder order, so a copy added later never pushes out the original
    std::stable_partition(parsed.begin(), parsed.end(), [&](const AssetSpec &asset) { return installed.count(asset.logical_id) != 0; });
    std::map<std::pair<Hash8, Hash8>, std::string> owners;
    std::map<Hash8, std::string> package_owners;
    for (auto &asset : parsed) {
        std::string clash;
        const auto package_hash = identity_hash(asset.package_name).first;
        if (package_owners.count(package_hash)) clash = "its package name is also used by " + package_owners[package_hash];
        for (const auto &resource : asset.resources) {
            if (!clash.empty() || resource.engine_type == "package") continue;
            const auto found = owners.find(resource_hash_key(resource.engine_type, resource.name));
            if (found != owners.end()) clash = resource.engine_type + "/" + resource.name + " is also in " + found->second;
        }
        if (!clash.empty()) {
            result.skipped.push_back({asset_folder_text(asset), clash});
            continue;
        }
        package_owners[package_hash] = asset_folder_text(asset);
        for (const auto &resource : asset.resources)
            if (resource.engine_type != "package") owners[resource_hash_key(resource.engine_type, resource.name)] = asset_folder_text(asset);
        result.assets.push_back(std::move(asset));
    }
    drop_broken_dependents(result.assets, result.skipped);
    std::sort(result.assets.begin(), result.assets.end(), [](const AssetSpec &a, const AssetSpec &b) {
        return lower_ascii(a.logical_id) < lower_ascii(b.logical_id);
    });
    return result;
}

} // namespace ca

#include "install.h"

#include "assets.h"
#include "bundle.h"
#include "cooked.h"
#include "database.h"
#include "json.h"
#include "manifest.h"
#include "oodle.h"

#include <algorithm>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <sstream>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

namespace ca {
namespace {

constexpr int STATE_SCHEMA = 2;
const std::string GENERATED_PACKAGE_PREFIX = "content/mods/custom_assets/packages/";

// ---- state: which bundles, packages and streams the patcher put into the game, and the input fingerprint

JsonValue empty_state() {
    JsonValue state = JsonValue::object_value();
    state.set("schema", JsonValue::integer_value(STATE_SCHEMA));
    state.set("bundles", JsonValue::array_value());
    state.set("packages", JsonValue::array_value());
    state.set("streams", JsonValue::array_value());
    return state;
}

std::set<std::string> state_strings(const JsonValue &state, const char *key) {
    std::set<std::string> out;
    const JsonValue *value = state.get(key);
    if (!value || value->kind != JsonValue::Array) return out;
    for (const auto &item : value->array) if (item.kind == JsonValue::String) out.insert(item.string);
    return out;
}

// an unreadable or older state file is not fatal: ownership is recovered from bundle_database.data
JsonValue load_state(const fs::path &path) {
    std::error_code ec;
    if (!fs::is_regular_file(path, ec)) return empty_state();
    try {
        JsonValue state = parse_json(read_text_file(path));
        const JsonValue *schema = state.get("schema");
        if (state.kind == JsonValue::Object && schema && schema->kind == JsonValue::Integer && schema->integer == STATE_SCHEMA) {
            // only names the patcher can have written count as ours
            JsonValue clean = empty_state();
            for (const char *key : {"bundles", "packages", "streams"}) {
                JsonValue rows = JsonValue::array_value();
                for (const auto &value : state_strings(state, key)) {
                    bool usable = true;
                    if (std::string(key) == "bundles") {
                        usable = value.size() == 16 && value == lower_ascii(value);
                        for (char c : value) usable = usable && static_cast<bool>(hex_digit(c));
                    } else if (std::string(key) == "streams") {
                        usable = safe_data_stream(value);
                    } else {
                        usable = !value.empty();
                    }
                    if (usable) rows.array.push_back(JsonValue::string_value(value));
                }
                clean.set(key, std::move(rows));
            }
            if (const JsonValue *fingerprint = state.get("fingerprint")) clean.set("fingerprint", *fingerprint);
            if (const JsonValue *sources = state.get("sources")) clean.set("sources", *sources);
            return clean;
        }
    } catch (const std::exception &) {
    }
    std::cout << "The install state could not be read; recovering it from the bundle database.\n";
    return empty_state();
}

JsonValue make_state(const std::vector<AssetSpec> &assets, const BuildPayload &aggregate,
                     const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &definitions,
                     const std::map<std::string, BuildPayload> &bundles) {
    JsonValue state = JsonValue::object_value();
    state.set("schema", JsonValue::integer_value(STATE_SCHEMA));
    state.set("transport", JsonValue::string_value("boot_assets_package_residency"));
    state.set("asset_count", JsonValue::integer_value(static_cast<i64>(assets.size())));
    state.set("resource_count", JsonValue::integer_value(static_cast<i64>(aggregate.resources.size())));
    JsonValue bundle_rows = JsonValue::array_value();
    for (const auto &item : bundles) bundle_rows.array.push_back(JsonValue::string_value(item.first));
    state.set("bundles", std::move(bundle_rows));
    JsonValue package_rows = JsonValue::array_value();
    for (const auto &item : definitions) package_rows.array.push_back(JsonValue::string_value(item.first));
    state.set("packages", std::move(package_rows));
    JsonValue stream_rows = JsonValue::array_value();
    for (const auto &item : aggregate.stream_sources) stream_rows.array.push_back(JsonValue::string_value(item.first));
    state.set("streams", std::move(stream_rows));
    JsonValue sources = JsonValue::array_value();
    for (const auto &asset : assets) {
        JsonValue row = JsonValue::object_value();
        row.set("logical_id", JsonValue::string_value(asset.logical_id));
        row.set("kind", JsonValue::string_value(asset.source_kind));
        row.set("path", JsonValue::string_value("mods/" + asset.owner + "/Custom/" + asset.source_relative));
        sources.array.push_back(std::move(row));
    }
    state.set("sources", std::move(sources));
    return state;
}

// ---- paths in the game's bundle folder

fs::path stream_destination(const fs::path &game_root, const std::string &stream_name) {
    if (!safe_data_stream(stream_name)) throw PatcherError("refusing unsafe stream destination: " + stream_name);
    const fs::path bundle_root = fs::weakly_canonical(game_root / "bundle");
    const fs::path destination = fs::weakly_canonical(bundle_root / fs::path(stream_name));
    const std::string relative = generic_path_text(destination.lexically_relative(bundle_root));
    if (relative.empty() || starts_with(relative, "..")) throw PatcherError("refusing stream destination outside the bundle folder: " + stream_name);
    return destination;
}

fs::path bundle_destination(const fs::path &game_root, const std::string &filename) {
    bundle_hash_le(filename);
    return game_root / "bundle" / filename;
}

fs::path boot_carrier_destination(const fs::path &game_root) {
    return game_root / "bundle" / (std::string(STORAGE_BASE_BUNDLE) + ".patch_998");
}

std::string bundle_name_of(const AssetSpec &asset) {
    return identity_hash(asset.package_name).second;
}

// ---- fingerprint: everything the result depends on; unchanged = nothing to do

std::string fingerprint(const Layout &layout, const JsonValue &state) {
    std::string text = layout.kind;
    const auto stamp = [&](const fs::path &path) {
        std::error_code ec;
        const auto size = fs::file_size(path, ec);
        if (ec) { text += "|-"; return; }
        const auto time = fs::last_write_time(path, ec);
        text += "|" + std::to_string(size) + ":" + std::to_string(ec ? 0 : time.time_since_epoch().count());
    };
    const fs::path bundle_root = layout.game_root / "bundle";
    for (const fs::path &path : {layout.executable, layout.db, layout.format_base, layout.storage_base, bundle_root / (std::string(STORAGE_BASE_BUNDLE) + ".patch_999"),
                                 boot_carrier_destination(layout.game_root), layout.game_root / "binaries" / "oo2core_9_win64.dll",
                                 layout.manifest_lua, layout.manifest_json})
        stamp(path);
    for (const auto &name : state_strings(state, "bundles")) stamp(bundle_root / name);
    for (const auto &name : state_strings(state, "streams")) stamp(bundle_root / fs::path(name));
    std::error_code ec;
    std::vector<fs::path> files;
    for (fs::directory_iterator next(layout.game_root / "mods", ec), last; !ec && next != last; next.increment(ec)) {
        const auto &mod = *next;
        std::error_code entry_ec;
        if (!mod.is_directory(entry_ec)) continue;
        text += "|mod:" + path_text(mod.path().filename()) + (fs::exists(mod.path() / (path_text(mod.path().filename()) + ".mod"), entry_ec) ? "+" : "-");
        const fs::path custom = mod.path() / "Custom";
        if (!fs::is_directory(custom, entry_ec)) continue;
        for (fs::recursive_directory_iterator it(custom, entry_ec), end; !entry_ec && it != end; it.increment(entry_ec)) {
            std::error_code file_ec;
            if (it->is_regular_file(file_ec)) files.push_back(it->path());
        }
    }
    std::sort(files.begin(), files.end());
    for (const auto &path : files) {
        text += "|" + generic_path_text(path.lexically_relative(layout.game_root));
        stamp(path);
    }
    return murmur64_hex(text);
}

// ---- transaction helpers (unchanged from 1.x)

i64 unix_time_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

u64 unix_ns_filetime(i64 value_ns) {
    return static_cast<u64>(value_ns / 100) + 116444736000000000ull;
}

void set_bundle_timestamp(const fs::path &path, u64 filetime) {
#if defined(_WIN32)
    HANDLE handle = CreateFileW(path.c_str(), FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) throw PatcherError("could not set bundle timestamp: " + path_text(path));
    FILETIME value{};
    value.dwLowDateTime = static_cast<DWORD>(filetime);
    value.dwHighDateTime = static_cast<DWORD>(filetime >> 32);
    const BOOL ok = SetFileTime(handle, nullptr, &value, &value);
    CloseHandle(handle);
    if (!ok) throw PatcherError("could not set bundle timestamp: " + path_text(path));
#else
    (void)path; (void)filetime;
#endif
}

struct Snapshot {
    fs::path destination;
    std::optional<fs::path> backup;
};

std::vector<Snapshot> snapshot_paths(const std::vector<fs::path> &paths, const fs::path &backup_root) {
    std::vector<Snapshot> snapshots;
    std::set<fs::path> seen;
    for (const auto &raw : paths) {
        const fs::path destination = fs::absolute(raw).lexically_normal();
        if (!seen.insert(destination).second) continue;
        std::error_code ec;
        if (fs::is_regular_file(destination, ec)) {
            std::ostringstream name;
            name << std::setfill('0') << std::setw(4) << snapshots.size() << ".bak";
            const fs::path backup = backup_root / name.str();
            fs::create_directories(backup.parent_path());
            fs::copy_file(destination, backup, fs::copy_options::overwrite_existing, ec);
            if (ec) throw PatcherError("could not back up " + path_text(destination) + ": " + ec.message());
            snapshots.push_back({destination, backup});
        } else if (fs::exists(destination, ec)) {
            throw PatcherError("refusing to replace a folder: " + path_text(destination));
        } else {
            snapshots.push_back({destination, std::nullopt});
        }
    }
    return snapshots;
}

std::vector<std::string> restore_paths(const std::vector<Snapshot> &snapshots) {
    std::vector<std::string> problems;
    for (auto it = snapshots.rbegin(); it != snapshots.rend(); ++it) {
        try {
            if (!it->backup) {
                std::error_code ec;
                fs::remove(it->destination, ec);
                if (ec) throw PatcherError(ec.message());
            } else {
                atomic_copy(*it->backup, it->destination);
            }
        } catch (const std::exception &exc) {
            problems.push_back(path_text(it->destination) + ": " + exc.what());
        }
    }
    return problems;
}

class TempDirectory {
public:
    TempDirectory() {
        const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
#if defined(_WIN32)
        const u64 pid = GetCurrentProcessId();
#else
        const u64 pid = 0;
#endif
        path = fs::temp_directory_path() / ("custom-assets-build-" + std::to_string(pid) + "-" + std::to_string(stamp));
        fs::create_directories(path);
    }
    ~TempDirectory() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
    fs::path path;
};

// ---- per-asset preparation

struct PreparedAsset {
    AssetSpec asset;          // textures pointing at their recompressed staging copies
    BuildPayload bundle;
};

// raw (kind 0) creator textures get recompressed with the game's Oodle into the staging folder
void prepare_textures(AssetSpec &asset, const fs::path &stage_root, const fs::path &oodle_dll,
                      std::unique_ptr<DarktideOodleTextureCodec> &codec, int &converted) {
    const fs::path target_dir = stage_root / "prepared_textures" / murmur64_hex(asset.logical_id);
    int index = 0;
    for (auto &resource : asset.resources) {
        if (resource.engine_type != "texture") continue;
        ++index;
        if (texture_compressor_kind(resource.source) != 0) continue;
        if (!resource.stream_source) throw PatcherError(path_text(resource.source.filename()) + " is a raw texture without its stream file");
        if (!codec) codec = std::make_unique<DarktideOodleTextureCodec>(oodle_dll);
        const fs::path folder = target_dir / std::to_string(index);
        const fs::path texture_target = folder / resource.source.filename();
        const fs::path stream_target = folder / resource.stream_source->filename();
        transcode_kind0_texture(resource.source, *resource.stream_source, texture_target, stream_target, *codec);
        resource.source = texture_target;
        resource.stream_source = stream_target;
        ++converted;
    }
}

// retail packages/boot_assets plus our packages, in the boot carrier patch (patch_998), so the game keeps them
// resident and knows them at boot
BuildPayload build_boot_carrier(const Layout &layout, std::vector<AssetSpec> &assets, const fs::path &stage_root,
                                const HostBundleMetadata &metadata, DarktideOodleTextureCodec &codec) {
    const fs::path dml_patch = layout.game_root / "bundle" / (std::string(STORAGE_BASE_BUNDLE) + ".patch_999");
    if (!fs::is_regular_file(dml_patch)) throw PatcherError("Darktide Mod Loader's patch file is missing; run the mod loader's toggle first");
    if (bundle_contains_identity(dml_patch, "package", "packages/boot_assets"))
        throw PatcherError("this Darktide Mod Loader version replaces packages/boot_assets, which Custom Assets needs");
    std::vector<ResourceSpec> packages;
    for (auto &asset : assets) {
        auto &package = asset.resources.back();
        package.source = stage_root / "packages" / (murmur64_hex(package.name) + ".package");
        write_file(package.source, asset.package_blob);
        packages.push_back(package);
    }
    const Bytes original = extract_bundle_resource(layout.storage_base, "package", "packages/boot_assets", codec);
    const fs::path boot_path = stage_root / "packages_boot_assets.package";
    write_file(boot_path, extend_boot_package(original, packages));
    ResourceSpec boot;
    boot.engine_type = "package";
    boot.name = "packages/boot_assets";
    boot.source = boot_path;
    packages.push_back(std::move(boot));
    BuildPayload carrier = build_payload(packages, metadata);
    if (!carrier.stream_sources.empty()) throw PatcherError("boot carrier unexpectedly has external streams");
    return carrier;
}

void print_lines(const char *title, const std::vector<std::string> &lines) {
    if (lines.empty()) return;
    std::cout << title << "\n";
    for (const auto &line : lines) std::cout << "  " << line << "\n";
}

} // namespace

Layout layout_for_executable(const fs::path &executable) {
    const fs::path tools = executable.parent_path();
    Layout layout;
    layout.executable = executable;
    const bool bat = lower_ascii(path_text(tools.filename())) == "tools" &&
                     lower_ascii(path_text(tools.parent_path().filename())) == "customassets";
    if (bat) {
        layout.kind = "bat";
        layout.game_root = tools.parent_path().parent_path().parent_path();
        const fs::path generated = tools.parent_path() / "generated";
        layout.manifest_json = generated / "custom_assets_manifest.json";
        layout.manifest_lua = generated / "manifest.lua";
        layout.state = generated / "install_state.json";
        layout.log = generated / "last_patch.log";
        layout.other_state = layout.game_root / "tools" / "custom-assets-state.json";
        layout.other_outputs = {layout.game_root / "tools" / "custom-assets-manifest.lua",
                                layout.game_root / "tools" / "custom-assets-manifest.json", layout.other_state};
    } else {
        layout.kind = "plugin";
        layout.game_root = tools.parent_path();
        layout.manifest_json = tools / "custom-assets-manifest.json";
        layout.manifest_lua = tools / "custom-assets-manifest.lua";
        layout.state = tools / "custom-assets-state.json";
        layout.log = tools / "custom-assets-patch.log";
        const fs::path generated = layout.game_root / "mods" / "CustomAssets" / "generated";
        layout.other_state = generated / "install_state.json";
        layout.other_outputs = {generated / "manifest.lua", generated / "custom_assets_manifest.json", layout.other_state};
    }
    const fs::path bundle_root = layout.game_root / "bundle";
    layout.db = bundle_root / "bundle_database.data";
    layout.format_base = bundle_root / BASE_BUNDLE;
    layout.storage_base = bundle_root / STORAGE_BASE_BUNDLE;
    return layout;
}

int install(const Layout &layout, const InstallOptions &options, bool &up_to_date) {
    up_to_date = false;
    for (const fs::path *path : {&layout.db, &layout.format_base, &layout.storage_base})
        if (!fs::is_regular_file(*path)) throw PatcherError("Darktide bundle file not found: " + path_text(*path) + " (is the patcher in the right folder?)");
    const Bytes db_data = read_file(layout.db);
    if (mod_loader_registration_count(db_data) != 1)
        throw PatcherError("Darktide Mod Loader is not active (its patch is not registered). Run the mod loader's toggle, then start again.");

    const JsonValue old_state = load_state(fs::is_regular_file(layout.state) ? layout.state : layout.other_state);
    if (!options.force && !options.dry_run) {
        const JsonValue *stored = old_state.get("fingerprint");
        if (stored && stored->kind == JsonValue::String && stored->string == fingerprint(layout, old_state) &&
            boot_registration_count(db_data) == 1) {
            std::cout << "Up to date: nothing changed since the last install.\n";
            up_to_date = true;
            return 0;
        }
    }

    std::set<std::string> installed;
    if (const JsonValue *sources = old_state.get("sources"); sources && sources->kind == JsonValue::Array)
        for (const auto &row : sources->array)
            if (const JsonValue *id = row.get("logical_id"); id && id->kind == JsonValue::String) installed.insert(id->string);
    ScanResult scan = scan_assets(layout.game_root, installed);
    std::vector<SkippedAsset> &skipped = scan.skipped;
    TempDirectory stage;
    const HostBundleMetadata metadata = read_host_metadata(layout.format_base);
    const fs::path oodle_dll = layout.game_root / "binaries" / "oo2core_9_win64.dll";
    std::unique_ptr<DarktideOodleTextureCodec> codec;

    // which bundles, packages and streams in the game folder are ours (state, or recognisable in the database)
    std::vector<std::string> candidate_bundles, candidate_packages;
    for (const auto &asset : scan.assets) {
        candidate_bundles.push_back(bundle_name_of(asset));
        candidate_packages.push_back(asset.package_name);
    }
    std::set<std::string> old_bundles = state_strings(old_state, "bundles");
    const std::set<std::string> recovered_bundles = recover_generated_bundle_ownership(db_data, candidate_bundles);
    std::set<std::string> managed_bundles = old_bundles;
    managed_bundles.insert(recovered_bundles.begin(), recovered_bundles.end());
    for (const auto &asset : scan.assets)
        if (starts_with(asset.package_name, GENERATED_PACKAGE_PREFIX)) managed_bundles.insert(bundle_name_of(asset));
    std::set<std::string> managed_packages = state_strings(old_state, "packages");
    const std::set<std::string> recovered_packages = recover_generated_package_ownership(db_data, candidate_packages);
    managed_packages.insert(recovered_packages.begin(), recovered_packages.end());
    for (const auto &name : candidate_packages) if (starts_with(name, GENERATED_PACKAGE_PREFIX)) managed_packages.insert(name);
    const std::set<std::string> old_streams = state_strings(old_state, "streams");

    // build every asset's bundle on its own; an asset that fails, or collides with another asset or with game
    // files that aren't ours, is skipped (and so is anything that needs it)
    std::map<std::string, PreparedAsset> prepared;
    int converted = 0;
    for (bool changed = true; changed;) {
        changed = false;
        std::vector<AssetSpec> kept;
        std::map<std::string, std::pair<fs::path, std::string>> streams;   // stream -> source, asset folder
        for (auto &asset : scan.assets) {
            const std::string folder = asset_folder_text(asset);
            try {
                auto found = prepared.find(asset.logical_id);
                if (found == prepared.end()) {
                    PreparedAsset item{asset, {}};
                    prepare_textures(item.asset, stage.path, oodle_dll, codec, converted);
                    std::vector<ResourceSpec> specs(item.asset.resources.begin(), item.asset.resources.end() - 1);
                    item.bundle = build_payload(specs, metadata);
                    found = prepared.emplace(asset.logical_id, std::move(item)).first;
                }
                const auto &item = found->second;
                // a bundle or package the game already registers that isn't ours (a supplied package name that
                // matches the game's own, say) is left alone. a bundle file nothing registers is a leftover of an
                // interrupted install and gets replaced
                const std::string bundle = bundle_name_of(asset);
                if (!managed_bundles.count(bundle) && bundle_registration_count(db_data, bundle) > 0)
                    throw PatcherError("its bundle " + bundle + " is already registered by something else");
                if (!managed_packages.count(asset.package_name) && package_members(db_data, asset.package_name))
                    throw PatcherError("its package " + asset.package_name + " is already registered by something else");
                for (const auto &[stream, source] : item.bundle.stream_sources) {
                    const auto other = streams.find(stream);
                    if (other != streams.end() && !files_equal(other->second.first, source))
                        throw PatcherError("its stream " + stream + " is also a different file in " + other->second.second);
                    const fs::path destination = stream_destination(layout.game_root, stream);
                    if (fs::is_regular_file(destination) && !old_streams.count(stream) &&
                        !starts_with(asset.package_name, GENERATED_PACKAGE_PREFIX) && !files_equal(destination, source))
                        throw PatcherError("its stream " + stream + " would replace a game file");
                }
                for (const auto &[stream, source] : item.bundle.stream_sources) streams.emplace(stream, std::make_pair(source, folder));
                kept.push_back(asset);
            } catch (const std::exception &exc) {
                skipped.push_back({folder, exc.what()});
                prepared.erase(asset.logical_id);
                changed = true;
            }
        }
        const size_t before = kept.size();
        drop_broken_dependents(kept, skipped);
        if (kept.size() != before) changed = true;
        scan.assets = std::move(kept);
    }
    std::vector<AssetSpec> assets;
    std::map<std::string, BuildPayload> bundles;
    BuildPayload aggregate;
    for (const auto &asset : scan.assets) {
        const auto &item = prepared.at(asset.logical_id);
        assets.push_back(item.asset);
        bundles[bundle_name_of(asset)] = item.bundle;
        for (const auto &resource : item.bundle.resources) aggregate.resources.push_back(resource);
        for (const auto &stream : item.bundle.stream_sources) {
            // an identical file that is already there and isn't ours (a retail stream an asset reuses) is used
            // as it is and never recorded, so removing the asset later doesn't delete a game file
            const fs::path destination = stream_destination(layout.game_root, stream.first);
            if (!old_streams.count(stream.first) && fs::is_regular_file(destination) && files_equal(destination, stream.second)) continue;
            aggregate.stream_sources.insert(stream);
        }
    }
    std::sort(aggregate.resources.begin(), aggregate.resources.end(), [](const ValidatedResource &a, const ValidatedResource &b) {
        return a.type_hash_hex != b.type_hash_hex ? a.type_hash_hex < b.type_hash_hex : a.name_hash_hex < b.name_hash_hex;
    });
    if (converted) std::cout << "Recompressed " << converted << " raw texture(s) with the game's Oodle.\n";

    const auto definitions = runtime_package_definitions(assets);
    if (!codec) codec = std::make_unique<DarktideOodleTextureCodec>(oodle_dll);
    const BuildPayload boot_carrier = build_boot_carrier(layout, assets, stage.path, metadata, *codec);
    const JsonValue manifest = build_manifest(layout.game_root, assets, aggregate, definitions, bundles.size(), skipped);
    JsonValue state = make_state(assets, aggregate, definitions, bundles);

    std::cout << "Found " << assets.size() + skipped.size() << " asset folder(s): " << assets.size() << " ready, "
              << skipped.size() << " skipped; " << aggregate.resources.size() << " resource(s), "
              << aggregate.stream_sources.size() << " stream(s).\n";
    print_lines("Warnings:", scan.warnings);
    std::vector<std::string> skipped_lines;
    for (const auto &item : skipped) skipped_lines.push_back(item.folder + ": " + item.reason);
    print_lines("Skipped:", skipped_lines);

    // ---- what changes in the game folder
    std::map<std::string, fs::path> desired_bundle_paths;
    std::vector<std::string> bundle_names;
    for (const auto &item : bundles) {
        desired_bundle_paths[item.first] = bundle_destination(layout.game_root, item.first);
        bundle_names.push_back(item.first);
    }
    std::set<std::string> changed_bundles;
    for (const auto &item : desired_bundle_paths)
        if (!file_equals_bytes(item.second, bundles.at(item.first).patch_bytes)) changed_bundles.insert(item.first);
    const u64 build_filetime = unix_ns_filetime(unix_time_ns());
    const ReconcileResult bundle_result = reconcile_bundle_registrations(db_data, bundle_names, managed_bundles, changed_bundles, build_filetime);
    const ReconcileResult package_result = reconcile_package_registrations(ensure_boot_registration(bundle_result.data), definitions, managed_packages);
    const Bytes new_db = package_result.data;
    const fs::path boot_path = boot_carrier_destination(layout.game_root);
    const bool changed_boot = !file_equals_bytes(boot_path, boot_carrier.patch_bytes);

    std::map<std::string, fs::path> desired_streams;
    for (const auto &item : aggregate.stream_sources) desired_streams[item.first] = stream_destination(layout.game_root, item.first);
    std::set<std::string> changed_streams;
    for (const auto &item : desired_streams)
        if (!files_equal(item.second, aggregate.stream_sources.at(item.first))) changed_streams.insert(item.first);
    std::vector<fs::path> stale_paths;
    for (const auto &name : old_bundles) if (!bundles.count(name)) stale_paths.push_back(bundle_destination(layout.game_root, name));
    for (const auto &name : old_streams) if (!desired_streams.count(name)) stale_paths.push_back(stream_destination(layout.game_root, name));
    for (const auto &path : layout.other_outputs) if (fs::is_regular_file(path)) stale_paths.push_back(path);
    const Bytes manifest_json = json_bytes(manifest);
    const Bytes manifest_lua = lua_bytes(manifest);

    if (options.dry_run) {
        std::cout << "Dry run: " << changed_bundles.size() << " bundle(s), " << changed_streams.size() << " stream(s) and "
                  << (new_db != db_data ? "the bundle database" : "no database change") << " would be written; nothing was changed.\n";
        return 0;
    }

    std::vector<fs::path> paths_to_write;
    for (const auto &name : changed_bundles) paths_to_write.push_back(desired_bundle_paths.at(name));
    if (changed_boot) paths_to_write.push_back(boot_path);
    for (const auto &name : changed_streams) paths_to_write.push_back(desired_streams.at(name));
    for (const fs::path &path : {layout.manifest_json, layout.manifest_lua, layout.state}) paths_to_write.push_back(path);
    std::vector<fs::path> snapshot_targets = paths_to_write;
    snapshot_targets.insert(snapshot_targets.end(), stale_paths.begin(), stale_paths.end());
    const auto snapshots = snapshot_paths(snapshot_targets, stage.path / "rollback");
    try {
        for (const auto &name : changed_bundles) {
            atomic_write(desired_bundle_paths.at(name), bundles.at(name).patch_bytes);
            set_bundle_timestamp(desired_bundle_paths.at(name), build_filetime);
        }
        if (changed_boot) atomic_write(boot_path, boot_carrier.patch_bytes);
        for (const auto &name : changed_streams) atomic_copy(aggregate.stream_sources.at(name), desired_streams.at(name));
        if (new_db != db_data) atomic_write(layout.db, new_db);
        if (!file_equals_bytes(layout.manifest_json, manifest_json)) atomic_write(layout.manifest_json, manifest_json);
        if (!file_equals_bytes(layout.manifest_lua, manifest_lua)) atomic_write(layout.manifest_lua, manifest_lua);
        for (const auto &path : stale_paths) {
            std::error_code ec;
            if (fs::exists(path, ec) && (!fs::remove(path, ec) || ec)) throw PatcherError("could not remove old file " + path_text(path) + ": " + ec.message());
        }
        state.set("fingerprint", JsonValue::string_value(fingerprint(layout, state)));
        atomic_write(layout.state, json_bytes(state));

        // read everything back
        std::vector<std::string> problems;
        const Bytes db = read_file(layout.db);
        if (db != new_db) problems.push_back("bundle_database.data differs from what was written");
        if (boot_registration_count(db) != 1) problems.push_back("the boot patch is not registered once");
        if (!file_equals_bytes(boot_path, boot_carrier.patch_bytes)) problems.push_back("the boot patch differs");
        for (const auto &item : bundles) {
            if (bundle_registration_count(db, item.first) != 1) problems.push_back("bundle " + item.first + " is not registered once");
            if (!file_equals_bytes(desired_bundle_paths.at(item.first), item.second.patch_bytes)) problems.push_back("bundle " + item.first + " differs");
        }
        for (const auto &item : definitions) {
            const auto actual = package_members(db, item.first);
            if (!actual || *actual != item.second) problems.push_back("package " + item.first + " is registered differently");
        }
        for (const auto &item : aggregate.stream_sources)
            if (!files_equal(desired_streams.at(item.first), item.second)) problems.push_back("stream " + item.first + " differs");
        for (const auto &path : stale_paths) if (fs::exists(path)) problems.push_back("old file still there: " + path_text(path));
        if (!problems.empty()) {
            std::string message = "checking the install failed: ";
            for (size_t i = 0; i < problems.size(); ++i) message += (i ? "; " : "") + problems[i];
            throw PatcherError(message);
        }
    } catch (const std::exception &exc) {
        std::vector<std::string> rollback_problems;
        try {
            if (!file_equals_bytes(layout.db, db_data)) atomic_write(layout.db, db_data);
        } catch (const std::exception &rollback) {
            rollback_problems.push_back(path_text(layout.db) + ": " + rollback.what());
        }
        const auto restore_problems = restore_paths(snapshots);
        rollback_problems.insert(rollback_problems.end(), restore_problems.begin(), restore_problems.end());
        std::string message = std::string("install failed, nothing was changed: ") + exc.what();
        if (!rollback_problems.empty()) {
            message = std::string("install failed: ") + exc.what() + "; putting the old files back failed for: ";
            for (size_t i = 0; i < rollback_problems.size(); ++i) message += (i ? "; " : "") + rollback_problems[i];
        }
        throw PatcherError(message);
    }

    std::cout << "Installed " << bundles.size() << " asset(s).\n";
    if (bundle_result.added || bundle_result.updated || bundle_result.removed)
        std::cout << "Bundles: +" << bundle_result.added << " / ~" << bundle_result.updated << " / -" << bundle_result.removed << "\n";
    if (package_result.added || package_result.updated || package_result.removed)
        std::cout << "Packages: +" << package_result.added << " / ~" << package_result.updated << " / -" << package_result.removed << "\n";
    return 0;
}

} // namespace ca

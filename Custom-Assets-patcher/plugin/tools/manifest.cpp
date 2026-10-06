#include "manifest.h"
#include "cooked.h"

#include <algorithm>
#include <iomanip>
#include <map>
#include <sstream>
#include <tuple>

namespace ca {

static std::string relative_manifest_path(const fs::path &game_root, const fs::path &path) {
    std::error_code ec;
    const fs::path relative = fs::relative(fs::weakly_canonical(path), fs::weakly_canonical(game_root), ec);
    if (ec || relative.empty() || starts_with(generic_path_text(relative), "..")) return "<prepared-staging>/" + generic_path_text(path.filename());
    return generic_path_text(relative);
}

static JsonValue dependency_graph(const std::vector<AssetSpec> &assets) {
    std::map<std::pair<Hash8, Hash8>, std::string> provider_by_hash;
    JsonValue nodes = JsonValue::array_value();

    for (const auto &asset : assets) {
        for (const auto &resource : asset.resources) {
            if (resource.engine_type == "package") continue;
            provider_by_hash[resource_hash_key(resource.engine_type, resource.name)] = asset.logical_id;
            JsonValue row = JsonValue::object_value();
            row.set("engine_type", JsonValue::string_value(resource.engine_type));
            row.set("name", JsonValue::string_value(resource.name));
            row.set("provider", JsonValue::string_value(asset.logical_id));
            nodes.array.push_back(std::move(row));
        }
    }

    struct Edge {
        std::string consumer;
        std::string provider;
        std::string engine_type;
        std::string name;
        bool package_member = false;
        bool resolved = false;
    };

    std::vector<Edge> custom_edges;
    std::vector<Edge> external_refs;
    for (const auto &asset : assets) {
        for (const auto &external : asset.external_resources) {
            Edge edge;
            edge.consumer = asset.logical_id;
            edge.engine_type = external.engine_type;
            edge.name = external.name;
            edge.package_member = external.package_member;
            const auto provider = provider_by_hash.find(resource_hash_key(external.engine_type, external.name));
            if (provider != provider_by_hash.end()) {
                edge.provider = provider->second;
                edge.resolved = true;
                custom_edges.push_back(std::move(edge));
            } else {
                external_refs.push_back(std::move(edge));
            }
        }
    }

    std::sort(nodes.array.begin(), nodes.array.end(), [](const JsonValue &a, const JsonValue &b) {
        const std::string ap = a.get("provider")->string;
        const std::string bp = b.get("provider")->string;
        if (ap != bp) return ap < bp;
        const std::string at = a.get("engine_type")->string;
        const std::string bt = b.get("engine_type")->string;
        if (at != bt) return at < bt;
        return a.get("name")->string < b.get("name")->string;
    });

    auto edge_sort = [](const Edge &a, const Edge &b) {
        return std::tie(a.consumer, a.provider, a.engine_type, a.name) < std::tie(b.consumer, b.provider, b.engine_type, b.name);
    };
    std::sort(custom_edges.begin(), custom_edges.end(), edge_sort);
    std::sort(external_refs.begin(), external_refs.end(), edge_sort);

    auto edge_json = [](const std::vector<Edge> &edges) {
        JsonValue out = JsonValue::array_value();
        for (const auto &edge : edges) {
            JsonValue row = JsonValue::object_value();
            row.set("consumer", JsonValue::string_value(edge.consumer));
            row.set("engine_type", JsonValue::string_value(edge.engine_type));
            row.set("name", JsonValue::string_value(edge.name));
            row.set("package_member", JsonValue::boolean_value(edge.package_member));
            if (edge.resolved) row.set("provider", JsonValue::string_value(edge.provider));
            out.array.push_back(std::move(row));
        }
        return out;
    };

    JsonValue out = JsonValue::object_value();
    out.set("custom_resource_count", JsonValue::integer_value(static_cast<i64>(nodes.array.size())));
    out.set("resolved_custom_edge_count", JsonValue::integer_value(static_cast<i64>(custom_edges.size())));
    out.set("external_reference_count", JsonValue::integer_value(static_cast<i64>(external_refs.size())));
    out.set("custom_resources", std::move(nodes));
    out.set("resolved_custom_edges", edge_json(custom_edges));
    out.set("external_references", edge_json(external_refs));
    return out;
}

JsonValue build_manifest(
    const fs::path &game_root,
    const std::vector<AssetSpec> &assets,
    const BuildPayload &payload,
    const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &package_definitions,
    size_t bundle_count,
    const std::vector<SkippedAsset> &skipped
) {
    std::map<std::string, const ValidatedResource *> validated;
    for (const auto &item : payload.resources) validated[item.spec.typed_key()] = &item;
    JsonValue asset_rows = JsonValue::array_value();

    for (const auto &asset : assets) {
        JsonValue resources = JsonValue::array_value();
        const ResourceSpec *package = nullptr;
        for (const auto &spec : asset.resources) {
            if (spec.engine_type == "package") {
                package = &spec;
                continue;
            }
            const auto found = validated.find(spec.typed_key());
            if (found == validated.end()) throw PatcherError("manifest resource was not validated: " + spec.engine_type + "/" + spec.name);
            const ValidatedResource &item = *found->second;
            JsonValue row = JsonValue::object_value();
            row.set("engine_type", JsonValue::string_value(spec.engine_type));
            row.set("name", JsonValue::string_value(spec.name));
            row.set("mode", JsonValue::integer_value(item.mode));
            row.set("source", JsonValue::string_value(relative_manifest_path(game_root, spec.source)));
            row.set("stream", item.stream_name.empty() ? JsonValue::null() : JsonValue::string_value(item.stream_name));
            if (spec.stream_source) row.set("stream_source", JsonValue::string_value(relative_manifest_path(game_root, *spec.stream_source)));
            if (spec.retail_stream_reference) row.set("retail_stream_reference", JsonValue::boolean_value(true));
            resources.array.push_back(std::move(row));
        }
        if (!package) throw PatcherError("asset has no package resource: " + asset.logical_id);
        JsonValue row = JsonValue::object_value();
        row.set("logical_id", JsonValue::string_value(asset.logical_id));
        row.set("owner", JsonValue::string_value(asset.owner));
        row.set("id", JsonValue::string_value(asset.asset_id));
        row.set("kind", JsonValue::string_value(asset.kind));
        row.set("unit_kind", asset.unit_kind ? JsonValue::string_value(*asset.unit_kind) : JsonValue::null());
        JsonValue source = JsonValue::object_value();
        source.set("kind", JsonValue::string_value(asset.source_kind));
        source.set("path", JsonValue::string_value(asset.source_relative));
        row.set("source", std::move(source));
        row.set("package_name", JsonValue::string_value(package->name));
        const auto definition = package_definitions.find(package->name);
        if (definition == package_definitions.end()) throw PatcherError("missing runtime package definition for " + package->name);
        row.set("package_member_count", JsonValue::integer_value(static_cast<i64>(definition->second.size())));
        JsonValue primary = JsonValue::object_value();
        primary.set("engine_type", JsonValue::string_value(asset.primary_engine_type));
        primary.set("name", JsonValue::string_value(asset.primary_name));
        row.set("primary", std::move(primary));
        row.set("resources", std::move(resources));
        row.set("metadata", asset.metadata);
        asset_rows.array.push_back(std::move(row));
    }

    JsonValue patch = JsonValue::object_value();
    patch.set("mode", JsonValue::string_value("per_asset_registered_bundles_package_registry"));
    patch.set("format_template_bundle", JsonValue::string_value(BASE_BUNDLE));
    patch.set("bundle_registry", JsonValue::string_value("bundle_database.data:v6"));
    patch.set("package_registry", JsonValue::string_value("bundle_database.data:v6"));
    patch.set("resource_count", JsonValue::integer_value(static_cast<i64>(payload.resources.size())));
    patch.set("stream_count", JsonValue::integer_value(static_cast<i64>(payload.stream_sources.size())));
    patch.set("package_count", JsonValue::integer_value(static_cast<i64>(package_definitions.size())));
    patch.set("bundle_count", JsonValue::integer_value(static_cast<i64>(bundle_count)));

    JsonValue manifest = JsonValue::object_value();
    manifest.set("schema", JsonValue::integer_value(2));
    manifest.set("patch", std::move(patch));
    manifest.set("dependency_graph", dependency_graph(assets));
    manifest.set("assets", std::move(asset_rows));
    JsonValue skipped_rows = JsonValue::array_value();
    for (const auto &item : skipped) {
        JsonValue row = JsonValue::object_value();
        row.set("folder", JsonValue::string_value(item.folder));
        row.set("reason", JsonValue::string_value(item.reason));
        skipped_rows.array.push_back(std::move(row));
    }
    manifest.set("skipped", std::move(skipped_rows));
    return manifest;
}

static std::string lua_string(const std::string &value) {
    std::string out = "\"";
    for (unsigned char c : value) {
        switch (c) {
            case '\a': out += "\\a"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\v': out += "\\v"; break;
            case '\\': out += "\\\\"; break;
            case '"': out += "\\\""; break;
            default:
                if (c < 32 || c == 127) {
                    out.push_back('\\');
                    out.push_back(static_cast<char>('0' + (c / 100) % 10));
                    out.push_back(static_cast<char>('0' + (c / 10) % 10));
                    out.push_back(static_cast<char>('0' + c % 10));
                } else {
                    out.push_back(static_cast<char>(c));
                }
                break;
        }
    }
    out.push_back('"');
    return out;
}

static std::string lua_dump(const JsonValue &value, int level = 0) {
    const std::string indent(static_cast<size_t>(level) * 4, ' ');
    const std::string child(static_cast<size_t>(level + 1) * 4, ' ');
    switch (value.kind) {
        case JsonValue::Null: return "nil";
        case JsonValue::Boolean: return value.boolean ? "true" : "false";
        case JsonValue::Integer: return std::to_string(value.integer);
        case JsonValue::Number: {
            std::ostringstream out;
            out << std::setprecision(17) << value.number;
            return out.str();
        }
        case JsonValue::String: return lua_string(value.string);
        case JsonValue::Array: {
            if (value.array.empty()) return "{}";
            std::string out = "{\n";
            for (size_t i = 0; i < value.array.size(); ++i) {
                out += child + lua_dump(value.array[i], level + 1);
                out += i + 1 == value.array.size() ? "\n" : ",\n";
            }
            out += indent + "}";
            return out;
        }
        case JsonValue::Object: {
            bool any = false;
            for (const auto &item : value.object) if (item.second.kind != JsonValue::Null) any = true;
            if (!any) return "{}";
            std::string out = "{\n";
            bool first = true;
            for (const auto &item : value.object) {
                if (item.second.kind == JsonValue::Null) continue;
                if (!first) out += ",\n";
                first = false;
                out += child + "[" + lua_string(item.first) + "] = " + lua_dump(item.second, level + 1);
            }
            out += "\n" + indent + "}";
            return out;
        }
    }
    return "nil";
}

static Bytes string_bytes(const std::string &value) {
    return Bytes(value.begin(), value.end());
}

Bytes json_bytes(const JsonValue &manifest) {
    return string_bytes(json_dump(manifest, 2));
}

Bytes lua_bytes(const JsonValue &manifest) {
    return string_bytes("-- Generated by custom-assets-patcher.exe. Do not edit by hand.\nreturn " + lua_dump(manifest) + "\n");
}

} // namespace ca

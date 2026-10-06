#include "bundle.h"
#include "oodle.h"
#include "cooked.h"

#include <algorithm>
#include <iomanip>
#include <set>
#include <sstream>

namespace ca {

HostBundleMetadata read_host_metadata(const fs::path &path) {
    const Bytes data = read_file(path);

    if (data.size() < HEADER_BYTES) {
        throw PatcherError("base bundle is too small: " + path_text(path));
    }

    const u64 magic = read_u64(data, 0);

    if (magic != 0x00000003f0000007ull && magic != 0x00000003f0000008ull) {
        std::ostringstream out;
        out << "unsupported Darktide bundle magic 0x" << std::hex << std::setw(16) << std::setfill('0') << magic;
        throw PatcherError(out.str());
    }

    const u32 file_count = read_u32(data, 8);

    if (file_count < 1 || file_count > MAX_INDEX_RECORDS) {
        throw PatcherError("implausible base bundle record count: " + std::to_string(file_count));
    }

    if (data.size() < HEADER_BYTES + static_cast<size_t>(file_count) * INDEX_RECORD_BYTES) {
        throw PatcherError("base bundle index is truncated");
    }

    const auto unit_type_raw = parse_hex("3f45a7e90b8da4e0");
    const auto plate_name_raw = parse_hex("4ac9c3abe91254bd");
    int unit_mode = -1;

    for (u32 index = 0; index < file_count; ++index) {
        const size_t pos = HEADER_BYTES + static_cast<size_t>(index) * INDEX_RECORD_BYTES;

        if (std::equal(unit_type_raw->begin(), unit_type_raw->end(), data.begin() + static_cast<std::ptrdiff_t>(pos)) &&
            std::equal(plate_name_raw->begin(), plate_name_raw->end(), data.begin() + static_cast<std::ptrdiff_t>(pos + 8))) {
            unit_mode = static_cast<int>(read_u32(data, pos + 16));
            break;
        }
    }

    if (unit_mode != 0 && unit_mode != 4) {
        throw PatcherError("retail plate_01 UNIT anchor was not found, or its mode is unsupported");
    }

    HostBundleMetadata out;
    out.template_identity = slice_bytes(data, 0, 8);
    out.type_data = slice_bytes(data, 12, 268);
    out.unit_mode = unit_mode;
    out.file_count = file_count;
    return out;
}

static ValidatedResource validate_resource(const ResourceSpec &spec, const HostBundleMetadata &metadata) {
    const Bytes blob = read_file(spec.source);
    std::string stream_name;
    TextureInfo texture_info;

    try {
        if (spec.engine_type == "material") {
            stream_name = inspect_material_header(blob).first;
        } else if (spec.engine_type == "texture") {
            texture_info = inspect_texture_body(blob);
            stream_name = texture_info.stream_name;
        } else {
            stream_name = stream_name_from_tail(inspect_cooked_envelope(blob).tail);
        }
    } catch (const PatcherError &exc) {
        throw PatcherError(path_text(spec.source) + ": invalid Darktide " + spec.engine_type + " resource: " + exc.what());
    }

    const auto type_hash = identity_hash(spec.engine_type);
    const auto name_hash = identity_hash(spec.name);

    if (blob.size() < 16 || !std::equal(type_hash.first.begin(), type_hash.first.end(), blob.begin())) {
        throw PatcherError(path_text(spec.source) + ": header type hash does not match " + spec.engine_type);
    }

    if (!std::equal(name_hash.first.begin(), name_hash.first.end(), blob.begin() + 8)) {
        throw PatcherError(path_text(spec.source) + ": header name hash does not match " + spec.name);
    }

    if (!stream_name.empty()) {
        if (spec.retail_stream_reference) {
            if (spec.engine_type != "material") {
                throw PatcherError(path_text(spec.source) + ": retail stream references are supported only for material resources");
            }

            if (spec.stream_source) {
                throw PatcherError(path_text(spec.source) + ": retail stream reference must not also declare an owned stream file");
            }

            if (!retail_stream(stream_name)) {
                throw PatcherError(path_text(spec.source) + ": retail material stream must use data/<2 hex>/<16 hex>[.stream], got " + stream_name);
            }
        } else {
            if (!safe_data_stream(stream_name)) {
                throw PatcherError(path_text(spec.source) + ": owned external stream must use a safe relative data/... path, got " + stream_name);
            }

            if (!spec.stream_source) {
                throw PatcherError(path_text(spec.source) + ": resource header declares " + stream_name + ", but descriptor has no stream file");
            }

        }
    } else if (spec.stream_source) {
        throw PatcherError(path_text(spec.source) + ": descriptor declares a stream but the cooked header is inline");
    } else if (spec.retail_stream_reference) {
        throw PatcherError(path_text(spec.source) + ": retail_stream_reference requires a material header with an external stream");
    }

    const int mode = spec.host_unit_mode ? metadata.unit_mode : spec.mode;

    if (mode != 0 && mode != 4) {
        throw PatcherError(path_text(spec.source) + ": resolved record mode must be 0 or 4");
    }

    ValidatedResource out;
    out.spec = spec;
    out.mode = mode;
    out.blob = blob;
    out.type_hash_le = type_hash.first;
    out.name_hash_le = name_hash.first;
    out.type_hash_hex = type_hash.second;
    out.name_hash_hex = name_hash.second;
    out.stream_name = stream_name;
    return out;
}

static BuildPayload validate_resources(const std::vector<ResourceSpec> &resources, const HostBundleMetadata &metadata) {
    BuildPayload out;
    std::set<std::string> typed_keys;
    std::set<std::string> header_keys;

    for (const ResourceSpec &spec : resources) {
        ValidatedResource item = validate_resource(spec, metadata);

        if (!typed_keys.insert(spec.typed_key()).second) {
            throw PatcherError("duplicate typed resource identity: " + spec.engine_type + "/" + spec.name);
        }

        const std::string header_key(reinterpret_cast<const char *>(item.type_hash_le.data()), 8);
        const std::string combined = header_key + std::string(reinterpret_cast<const char *>(item.name_hash_le.data()), 8);

        if (!header_keys.insert(combined).second) {
            throw PatcherError("resource header collision: " + spec.engine_type + "/" + spec.name);
        }

        if (!item.stream_name.empty() && spec.stream_source) {
            auto previous = out.stream_sources.find(item.stream_name);

            if (previous != out.stream_sources.end() && fs::weakly_canonical(previous->second) != fs::weakly_canonical(*spec.stream_source)) {
                if (!files_equal(previous->second, *spec.stream_source)) {
                    throw PatcherError("stream collision for " + item.stream_name + ": " + path_text(previous->second) + " vs " + path_text(*spec.stream_source));
                }
            } else {
                out.stream_sources[item.stream_name] = *spec.stream_source;
            }
        }

        out.resources.push_back(std::move(item));
    }

    std::sort(out.resources.begin(), out.resources.end(), [](const ValidatedResource &a, const ValidatedResource &b) {
        if (a.type_hash_hex != b.type_hash_hex) return a.type_hash_hex < b.type_hash_hex;
        return a.name_hash_hex < b.name_hash_hex;
    });

    return out;
}

BuildPayload build_payload(const std::vector<ResourceSpec> &resources, const HostBundleMetadata &metadata) {
    if (resources.size() > MAX_INDEX_RECORDS) {
        throw PatcherError("bundle has " + std::to_string(resources.size()) + " resources; hard limit is " + std::to_string(MAX_INDEX_RECORDS));
    }

    BuildPayload out = validate_resources(resources, metadata);
    u64 payload_size = 0;

    for (const auto &item : out.resources) {
        payload_size += item.blob.size();
    }

    if (payload_size > MAX_PATCH_PAYLOAD) {
        throw PatcherError("bundle cooked payload exceeds the 32-bit single-patch format limit");
    }

    Bytes payload;
    Bytes index;
    payload.reserve(static_cast<size_t>(payload_size));
    index.reserve(out.resources.size() * 20);

    for (const auto &item : out.resources) {
        append_bytes(payload, item.blob);
        append_bytes(index, item.type_hash_le);
        append_bytes(index, item.name_hash_le);
        write_u32(index, static_cast<u32>(item.mode));
    }

    const u32 chunk_count = static_cast<u32>(std::max<u64>(1, (payload.size() + PATCH_CHUNK_SIZE - 1) / PATCH_CHUNK_SIZE));
    Bytes patch;
    append_bytes(patch, metadata.template_identity);
    write_u32(patch, static_cast<u32>(out.resources.size()));
    append_bytes(patch, metadata.type_data);
    append_bytes(patch, index);
    write_u32(patch, chunk_count);

    for (u32 i = 0; i < chunk_count; ++i) {
        write_u32(patch, static_cast<u32>(PATCH_CHUNK_SIZE));
    }

    while ((patch.size() & 15) != 0) patch.push_back(0);
    write_u32(patch, static_cast<u32>(payload.size()));
    write_u32(patch, 0);
    size_t payload_pos = 0;

    for (u32 i = 0; i < chunk_count; ++i) {
        write_u32(patch, static_cast<u32>(PATCH_CHUNK_SIZE));
        while ((patch.size() & 15) != 0) patch.push_back(0);
        const size_t count = std::min(PATCH_CHUNK_SIZE, payload.size() - payload_pos);
        patch.insert(patch.end(), payload.begin() + static_cast<std::ptrdiff_t>(payload_pos), payload.begin() + static_cast<std::ptrdiff_t>(payload_pos + count));
        patch.insert(patch.end(), PATCH_CHUNK_SIZE - count, 0);
        payload_pos += count;
    }

    out.patch_bytes = std::move(patch);
    return out;
}

bool bundle_contains_identity(const fs::path &path, const std::string &engine_type, const std::string &name) {
    const Bytes raw = read_file(path);
    if (raw.size() < HEADER_BYTES) throw PatcherError("bundle header is truncated: " + path_text(path));
    const u32 count = read_u32(raw, 8);
    if (count > MAX_INDEX_RECORDS || HEADER_BYTES + static_cast<size_t>(count) * INDEX_RECORD_BYTES > raw.size()) throw PatcherError("bundle index is invalid: " + path_text(path));
    const Hash8 type_hash = identity_hash(engine_type).first;
    const Hash8 name_hash = identity_hash(name).first;
    for (u32 i = 0; i < count; ++i) {
        const size_t pos = HEADER_BYTES + static_cast<size_t>(i) * INDEX_RECORD_BYTES;
        if (std::equal(type_hash.begin(), type_hash.end(), raw.begin() + static_cast<std::ptrdiff_t>(pos)) &&
            std::equal(name_hash.begin(), name_hash.end(), raw.begin() + static_cast<std::ptrdiff_t>(pos + 8))) return true;
    }
    return false;
}

Bytes extract_bundle_resource(const fs::path &path, const std::string &engine_type, const std::string &name, DarktideOodleTextureCodec &codec) {
    const Bytes raw = read_file(path);
    if (raw.size() < HEADER_BYTES || (read_u64(raw, 0) != 0x00000003f0000008ull && read_u64(raw, 0) != 0x00000003f0000007ull)) throw PatcherError("unsupported retail storage bundle: " + path_text(path));
    const u32 count = read_u32(raw, 8);
    if (!count || count > MAX_INDEX_RECORDS) throw PatcherError("retail storage bundle index count is invalid");
    const size_t index_end = HEADER_BYTES + static_cast<size_t>(count) * INDEX_RECORD_BYTES;
    if (index_end + 4 > raw.size()) throw PatcherError("retail storage bundle index is truncated");
    const u32 chunk_count = read_u32(raw, index_end);
    if (!chunk_count || chunk_count > 0x100000) throw PatcherError("retail storage bundle chunk count is invalid");
    size_t pos = index_end + 4;
    if (static_cast<u64>(pos) + static_cast<u64>(chunk_count) * 4 > raw.size()) throw PatcherError("retail storage bundle chunk summary is truncated");
    std::vector<u32> summary;
    summary.reserve(chunk_count);
    for (u32 i = 0; i < chunk_count; ++i) summary.push_back(read_u32(raw, pos + static_cast<size_t>(i) * 4));
    pos = (pos + static_cast<size_t>(chunk_count) * 4 + 15) & ~static_cast<size_t>(15);
    const u32 logical_size = read_u32(raw, pos);
    if (read_u32(raw, pos + 4) != 0) throw PatcherError("retail storage bundle logical-size sentinel is invalid");
    pos += 8;
    Bytes payload;
    payload.reserve(logical_size);
    for (u32 i = 0; i < chunk_count; ++i) {
        const u32 encoded_size = read_u32(raw, pos);
        if (encoded_size != summary[i]) throw PatcherError("retail storage bundle chunk summary differs from its payload");
        pos = (pos + 4 + 15) & ~static_cast<size_t>(15);
        if (static_cast<u64>(pos) + encoded_size > raw.size()) throw PatcherError("retail storage bundle chunk is truncated");
        const Bytes encoded = slice_bytes(raw, pos, pos + encoded_size);
        pos += encoded_size;
        Bytes decoded = encoded_size == PATCH_CHUNK_SIZE ? encoded : codec.decompress_bundle_chunk(encoded);
        if (i + 1 < chunk_count && decoded.size() != PATCH_CHUNK_SIZE) throw PatcherError("retail storage bundle non-final chunk size is invalid");
        append_bytes(payload, decoded);
    }
    if (payload.size() < logical_size) throw PatcherError("retail storage bundle payload is truncated");
    payload.resize(logical_size);
    const Hash8 type_hash = identity_hash(engine_type).first;
    const Hash8 name_hash = identity_hash(name).first;
    size_t payload_pos = 0;
    std::optional<Bytes> found;
    for (u32 i = 0; i < count; ++i) {
        const size_t index_pos = HEADER_BYTES + static_cast<size_t>(i) * INDEX_RECORD_BYTES;
        if (payload_pos + 38 > payload.size()) throw PatcherError("retail storage bundle resource is truncated");
        if (!std::equal(payload.begin() + static_cast<std::ptrdiff_t>(payload_pos), payload.begin() + static_cast<std::ptrdiff_t>(payload_pos + 16), raw.begin() + static_cast<std::ptrdiff_t>(index_pos))) throw PatcherError("retail storage bundle resource order differs from its index");
        const u64 size = 38ull + read_u32(payload, payload_pos + 29) + read_u32(payload, payload_pos + 34);
        if (size > payload.size() - payload_pos) throw PatcherError("retail storage bundle resource body is truncated");
        if (std::equal(type_hash.begin(), type_hash.end(), raw.begin() + static_cast<std::ptrdiff_t>(index_pos)) &&
            std::equal(name_hash.begin(), name_hash.end(), raw.begin() + static_cast<std::ptrdiff_t>(index_pos + 8))) {
            if (found) throw PatcherError("retail storage bundle contains duplicate " + engine_type + "/" + name);
            found = slice_bytes(payload, payload_pos, payload_pos + static_cast<size_t>(size));
        }
        payload_pos += static_cast<size_t>(size);
    }
    if (payload_pos != payload.size() || !found) throw PatcherError("retail storage bundle does not contain exactly one " + engine_type + "/" + name);
    return *found;
}

static bool package_hash_less(const std::pair<Hash8, Hash8> &a, const std::pair<Hash8, Hash8> &b) {
    if (a.first != b.first) return std::lexicographical_compare(a.first.rbegin(), a.first.rend(), b.first.rbegin(), b.first.rend());
    return std::lexicographical_compare(a.second.rbegin(), a.second.rend(), b.second.rbegin(), b.second.rend());
}

Bytes extend_boot_package(Bytes blob, const std::vector<ResourceSpec> &packages) {
    const Hash8 expected = identity_hash("packages/boot_assets").first;
    if (blob.size() < 47 || !std::equal(expected.begin(), expected.end(), blob.begin() + 8)) throw PatcherError("retail packages/boot_assets identity is invalid");
    auto entries = parse_package_blob(blob);
    if (!std::is_sorted(entries.begin(), entries.end(), package_hash_less)) throw PatcherError("retail packages/boot_assets member order is unsupported");
    std::set<std::pair<Hash8, Hash8>> unique(entries.begin(), entries.end());
    const Hash8 package_type = identity_hash("package").first;
    for (const auto &package : packages) unique.insert({package_type, identity_hash(package.name).first});
    entries.assign(unique.begin(), unique.end());
    std::sort(entries.begin(), entries.end(), package_hash_less);
    Bytes body;
    write_u32(body, PACKAGE_VERSION);
    write_u32(body, static_cast<u32>(entries.size()));
    for (const auto &entry : entries) { append_bytes(body, entry.first); append_bytes(body, entry.second); }
    body.push_back(PACKAGE_FOOTER);
    blob.resize(38);
    overwrite_u32(blob, 29, static_cast<u32>(body.size()));
    overwrite_u32(blob, 34, 0);
    append_bytes(blob, body);
    return blob;
}

} // namespace ca

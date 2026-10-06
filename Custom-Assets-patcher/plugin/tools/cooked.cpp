#include "cooked.h"

#include <algorithm>
#include <map>
#include <regex>

namespace ca {

bool safe_data_stream(const std::string &value) {
    static const std::regex pattern(R"(^data(?:/[A-Za-z0-9_.-]+)+$)");

    if (!std::regex_match(value, pattern)) {
        return false;
    }

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

bool retail_stream(const std::string &value) {
    static const std::regex pattern(R"(^data/[0-9a-f]{2}/[0-9a-f]{16}(?:\.stream)?$)");
    return std::regex_match(lower_ascii(value), pattern);
}


CookedEnvelope inspect_cooked_envelope(const Bytes &blob) {
    if (blob.size() < 38) {
        throw PatcherError("cooked resource is truncated");
    }

    if (read_u32(blob, 16) != 1) {
        throw PatcherError("cooked resource must contain exactly one supported variant");
    }

    const u8 unknown1 = blob[28];
    const u8 unknown2 = blob[33];

    if ((unknown1 != 0 && unknown1 != 1) || unknown2 != 1) {
        throw PatcherError("cooked resource variant markers are unsupported");
    }

    const u32 body_size = read_u32(blob, 29);
    const u32 tail_size = read_u32(blob, 34);
    const u64 expected = 38ull + body_size + tail_size;

    if (blob.size() != expected) {
        throw PatcherError("cooked resource envelope length mismatch: header declares " + std::to_string(expected) + " bytes, got " + std::to_string(blob.size()));
    }

    CookedEnvelope out;
    out.kind = read_u32(blob, 24);
    out.unknown1 = unknown1;
    out.body_size = body_size;
    out.tail_size = tail_size;
    out.body = slice_bytes(blob, 38, 38 + body_size);
    out.tail = slice_bytes(blob, 38 + body_size, static_cast<size_t>(expected));
    return out;
}

std::string stream_name_from_tail(const Bytes &tail) {
    if (tail.empty()) {
        return {};
    }

    std::string value;
    value.reserve(tail.size());

    for (u8 c : tail) {
        if (c > 0x7f) {
            return {};
        }
        value.push_back(static_cast<char>(c));
    }

    return safe_data_stream(value) ? value : std::string();
}

std::pair<std::string, u64> inspect_material_header(const Bytes &blob) {
    const Hash8 material_type = identity_hash("material").first;

    if (blob.size() != MATERIAL_HEADER_BYTES) {
        throw PatcherError("Darktide material header must be 68 bytes, got " + std::to_string(blob.size()));
    }

    if (!std::equal(material_type.begin(), material_type.end(), blob.begin())) {
        throw PatcherError("resource is not a Darktide material header");
    }

    if (read_u32(blob, 16) != 1) {
        throw PatcherError("Darktide material header field unk1 is not 1");
    }

    if (read_u32(blob, 20) != 0 || read_u32(blob, 24) != 0) {
        throw PatcherError("Darktide material header zero fields are malformed");
    }

    if (blob[28] != 1 || read_u32(blob, 29) != 30) {
        throw PatcherError("Darktide material header fixed-string fields are malformed");
    }

    if (read_u32(blob, 33) != 1 || blob[37] != 0) {
        throw PatcherError("Darktide material header trailer fields are malformed");
    }

    size_t length = 0;

    while (length < MATERIAL_STREAM_PATH_BYTES && blob[MATERIAL_STREAM_PATH_OFFSET + length] != 0) {
        if (blob[MATERIAL_STREAM_PATH_OFFSET + length] > 0x7f) {
            throw PatcherError("Darktide material stream path is not ASCII");
        }
        ++length;
    }

    const std::string stream_name(reinterpret_cast<const char *>(blob.data() + MATERIAL_STREAM_PATH_OFFSET), length);

    if (stream_name.empty()) {
        throw PatcherError("Darktide material header stream path is empty");
    }

    return {stream_name, read_u64(blob, 8)};
}

TextureInfo inspect_texture_body(const Bytes &blob) {
    const CookedEnvelope envelope = inspect_cooked_envelope(blob);
    std::string stream_name;
    stream_name.reserve(envelope.tail.size());

    for (u8 c : envelope.tail) {
        if (c > 0x7f) {
            throw PatcherError("cooked texture stream name is not ASCII");
        }
        stream_name.push_back(static_cast<char>(c));
    }

    const Bytes &body = envelope.body;
    TextureInfo out;
    out.stream_name = stream_name;

    if (body.size() < 12) {
        return out;
    }

    out.kind = read_u32(body, 0);
    out.compressed_resident_bytes = read_u32(body, 4);
    out.resident_dds_bytes = read_u32(body, 8);
    size_t pos = 12ull + out.compressed_resident_bytes;

    if (pos + 20 + 128 + 4 > body.size()) {
        return out;
    }

    out.body_flags = read_u32(body, pos + 4);
    out.streamed_mips = read_u32(body, pos + 8);
    out.width = read_u32(body, pos + 12);
    out.height = read_u32(body, pos + 16);
    out.footer_word = read_u32(body, body.size() - 4);
    pos += 20 + 128;

    // textures without streamed mips may end right after a zero meta word, without a chunk table
    const u32 meta_size = read_u32(body, pos);

    if (meta_size < 8 || pos + 4ull + meta_size > body.size()) {
        return out;
    }

    out.chunk_count = read_u32(body, pos + 4);
    pos += 12;

    for (u32 i = 0; i < out.chunk_count && pos + 4 <= body.size(); ++i, pos += 4) {
        out.compressed_stream_bytes = std::max(out.compressed_stream_bytes, read_u32(body, pos));
    }

    return out;
}

std::string package_resource_name(const std::string &logical_id) {
    if (logical_id.empty()) {
        throw PatcherError("logical asset ID must be a non-empty string");
    }

    return "content/mods/custom_assets/packages/" + murmur64_hex(logical_id);
}

std::vector<PackageEntry> normalize_entries(std::vector<PackageEntry> entries) {
    std::map<std::string, PackageEntry> unique;

    for (auto &entry : entries) {
        if (entry.engine_type.empty() || entry.name.empty()) {
            throw PatcherError("package entries require non-empty engine type and resource name");
        }
        unique[entry.typed_key()] = entry;
    }

    entries.clear();
    entries.reserve(unique.size());

    for (auto &item : unique) {
        entries.push_back(std::move(item.second));
    }

    std::sort(entries.begin(), entries.end(), [](const PackageEntry &a, const PackageEntry &b) {
        if (a.engine_type != b.engine_type) return a.engine_type < b.engine_type;
        return a.name < b.name;
    });
    return entries;
}

static Bytes build_package_body(std::vector<PackageEntry> entries) {
    entries = normalize_entries(std::move(entries));
    Bytes out;
    write_u32(out, PACKAGE_VERSION);
    write_u32(out, static_cast<u32>(entries.size()));

    for (const auto &entry : entries) {
        append_bytes(out, identity_hash(entry.engine_type).first);
        append_bytes(out, identity_hash(entry.name).first);
    }

    out.push_back(PACKAGE_FOOTER);
    return out;
}

Bytes wrap_cooked(const std::string &engine_type, const std::string &name, const Bytes &body) {
    Bytes out(38, 0);
    const auto type_hash = identity_hash(engine_type).first;
    const auto name_hash = identity_hash(name).first;
    std::copy(type_hash.begin(), type_hash.end(), out.begin());
    std::copy(name_hash.begin(), name_hash.end(), out.begin() + 8);
    out[16] = 1;
    overwrite_u32(out, 29, static_cast<u32>(body.size()));
    out[33] = 1;
    overwrite_u32(out, 34, 0);
    append_bytes(out, body);
    return out;
}

Bytes build_package_blob(const std::string &package_name, std::vector<PackageEntry> entries) {
    return wrap_cooked("package", package_name, build_package_body(std::move(entries)));
}

std::vector<std::pair<Hash8, Hash8>> parse_package_blob(const Bytes &blob) {
    if (blob.size() < 47) {
        throw PatcherError("package resource is too small");
    }

    const Hash8 package_type = identity_hash("package").first;

    if (!std::equal(package_type.begin(), package_type.end(), blob.begin())) {
        throw PatcherError("resource is not a package");
    }

    if (read_u32(blob, 16) != 1 || blob[33] != 1) {
        throw PatcherError("cooked package must contain exactly one supported variant");
    }

    const u32 body_size = read_u32(blob, 29);
    const u32 stream_size = read_u32(blob, 34);

    if (stream_size != 0) {
        throw PatcherError("native package resource must not declare an external stream name");
    }

    if (blob.size() != 38ull + body_size) {
        throw PatcherError("package resource body size does not match cooked envelope");
    }

    const size_t body = 38;

    if (body_size < 9) {
        throw PatcherError("package body is truncated");
    }

    const u32 version = read_u32(blob, body);
    const u32 count = read_u32(blob, body + 4);

    const u64 expected = 9ull + static_cast<u64>(count) * 16;

    if (body_size != expected) {
        throw PatcherError("package body has " + std::to_string(body_size) + " bytes for " + std::to_string(count) + " entries; expected " + std::to_string(expected));
    }

    if (blob.back() != PACKAGE_FOOTER) {
        throw PatcherError("unsupported package footer");
    }

    std::vector<std::pair<Hash8, Hash8>> entries;
    entries.reserve(count);

    for (u32 i = 0; i < count; ++i) {
        entries.push_back({slice_hash8(blob, body + 8 + static_cast<size_t>(i) * 16), slice_hash8(blob, body + 16 + static_cast<size_t>(i) * 16)});
    }

    return entries;
}

} // namespace ca

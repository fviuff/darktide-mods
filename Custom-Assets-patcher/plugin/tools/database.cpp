#include "database.h"
#include "cooked.h"

#include <algorithm>
#include <map>
#include <set>

namespace ca {

struct DatabaseEntry {
    std::string name;
    std::string stream_name;
    size_t start = 0;
    size_t end = 0;
};

struct BundleRecord {
    size_t start = 0;
    size_t end = 0;
    u32 count = 0;
    std::vector<DatabaseEntry> entries;
};

struct DatabaseBundleRecord {
    Hash8 name_hash_le{};
    u32 count = 0;
    std::vector<DatabaseEntry> entries;
    u64 footer_filetime = 0;
    size_t start = 0;
    size_t end = 0;
    size_t index_start = 0;
    size_t index_end = 0;
    Hash8 index_aux_le{};
};

struct BundleTable {
    size_t records_end = 0;
    size_t index_count_offset = 0;
    size_t index_start = 0;
    size_t package_count_offset = 0;
    std::vector<DatabaseBundleRecord> records;
};

struct PackageDefinitionRecord {
    Hash8 name_hash_le{};
    std::vector<std::pair<Hash8, Hash8>> entries;
    size_t start = 0;
    size_t end = 0;
};

struct PackageTable {
    size_t count_offset = 0;
    size_t end = 0;
    std::vector<PackageDefinitionRecord> records;
};

static void append_string(Bytes &out, const std::string &value) {
    write_u32(out, static_cast<u32>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

static std::pair<std::string, size_t> read_db_string(const Bytes &data, size_t offset) {
    const u32 length = read_u32(data, offset, "bundle database is truncated");
    offset += 4;

    if (length > 4096 || offset + length > data.size()) {
        throw PatcherError("invalid bundle database string");
    }

    const std::string value(reinterpret_cast<const char *>(data.data() + offset), length);
    return {value, offset + length};
}

Hash8 bundle_hash_le(const std::string &bundle_name) {
    if (bundle_name.size() != 16) {
        throw PatcherError("invalid bundle hash name: " + bundle_name);
    }

    auto raw = parse_hex(bundle_name);
    if (!raw || raw->size() != 8 || lower_ascii(bundle_name) != bundle_name) {
        throw PatcherError("invalid bundle hash name: " + bundle_name);
    }

    Hash8 out{};
    for (size_t i = 0; i < 8; ++i) out[i] = (*raw)[7 - i];
    return out;
}

static BundleRecord parse_record(const Bytes &data, const std::string &base_bundle = BASE_BUNDLE) {
    Bytes signature;
    write_u32(signature, 4);
    append_string(signature, base_bundle);
    append_string(signature, base_bundle + ".stream");
    signature.push_back(0);
    auto it = std::search(data.begin(), data.end(), signature.begin(), signature.end());

    if (it == data.end()) {
        throw PatcherError("bundle database record not found: " + base_bundle);
    }

    const size_t sig_pos = static_cast<size_t>(std::distance(data.begin(), it));
    if (sig_pos < 12) throw PatcherError("bundle database hash anchor mismatch: " + base_bundle);
    const size_t start = sig_pos - 12;
    const Hash8 expected = bundle_hash_le(base_bundle);
    if (!std::equal(expected.begin(), expected.end(), data.begin() + static_cast<std::ptrdiff_t>(start))) {
        throw PatcherError("bundle database hash anchor mismatch: " + base_bundle);
    }

    const u32 count = read_u32(data, start + 8, "bundle database is truncated");
    if (count < 1 || count > 1024) throw PatcherError("implausible bundle database record count: " + std::to_string(count));
    size_t pos = start + 12;
    std::vector<DatabaseEntry> entries;

    for (u32 index = 0; index < count; ++index) {
        const size_t entry_start = pos;
        if (index > 0) {
            if (pos + 8 > data.size()) throw PatcherError("bundle database patch entry is truncated");
            pos += 8;
        }
        if (read_u32(data, pos, "bundle database is truncated") != 4) throw PatcherError("bundle database entry constant mismatch");
        pos += 4;
        auto name = read_db_string(data, pos); pos = name.second;
        auto stream = read_db_string(data, pos); pos = stream.second;
        if (pos >= data.size() || data[pos] != 0) throw PatcherError("bundle database entry terminator is missing");
        ++pos;
        if (pos + 20 > data.size()) throw PatcherError("bundle database entry trailer is truncated");
        pos += 20;
        entries.push_back({name.first, stream.first, entry_start, pos});
    }

    return {start, pos, count, std::move(entries)};
}

int boot_registration_count(const Bytes &data) {
    const std::string patch_name = std::string(STORAGE_BASE_BUNDLE) + ".patch_998";
    const std::string stream_name = std::string(STORAGE_BASE_BUNDLE) + ".stream.patch_998";
    int count = 0;
    for (const auto &entry : parse_record(data, STORAGE_BASE_BUNDLE).entries) if (entry.name == patch_name && entry.stream_name == stream_name) ++count;
    return count;
}

Bytes ensure_boot_registration(const Bytes &data) {
    const BundleRecord record = parse_record(data, STORAGE_BASE_BUNDLE);
    const std::string patch_name = std::string(STORAGE_BASE_BUNDLE) + ".patch_998";
    const std::string stream_name = std::string(STORAGE_BASE_BUNDLE) + ".stream.patch_998";
    const std::string dml_name = std::string(STORAGE_BASE_BUNDLE) + ".patch_999";
    size_t dml_pos = data.size();
    size_t boot_pos = data.size();
    int matches = 0;
    for (const auto &entry : record.entries) {
        if (entry.name == dml_name) dml_pos = entry.start;
        if (entry.name == patch_name || entry.stream_name == stream_name) {
            if (entry.name != patch_name || entry.stream_name != stream_name) throw PatcherError("conflicting boot carrier patch registration");
            boot_pos = entry.start;
            ++matches;
        }
    }
    if (dml_pos == data.size() || matches > 1) throw PatcherError("Darktide Mod Loader and boot carrier patch registrations are invalid");
    if (matches == 1) {
        if (boot_pos > dml_pos) throw PatcherError("boot carrier patch must precede Darktide Mod Loader patch_999");
        return data;
    }
    Bytes entry(8, 0);
    write_u32(entry, 4);
    append_string(entry, patch_name);
    append_string(entry, stream_name);
    entry.push_back(0);
    entry.insert(entry.end(), 20, 0);
    Bytes out(data.begin(), data.begin() + static_cast<std::ptrdiff_t>(record.start + 8));
    write_u32(out, record.count + 1);
    out.insert(out.end(), data.begin() + static_cast<std::ptrdiff_t>(record.start + 12), data.begin() + static_cast<std::ptrdiff_t>(dml_pos));
    append_bytes(out, entry);
    out.insert(out.end(), data.begin() + static_cast<std::ptrdiff_t>(dml_pos), data.end());
    if (boot_registration_count(out) != 1) throw PatcherError("could not register boot carrier patch");
    return out;
}

static BundleTable parse_bundle_table(const Bytes &data) {
    if (data.size() < 8) throw PatcherError("bundle database is truncated");
    const u32 version = read_u32(data, 0, "bundle database is truncated");
    const u32 bundle_count = read_u32(data, 4);
    if (bundle_count < 1) throw PatcherError("bundle database contains no bundle records");

    struct Parsed {
        Hash8 name_hash{};
        u32 count = 0;
        std::vector<DatabaseEntry> entries;
        u64 footer = 0;
        size_t start = 0;
        size_t end = 0;
    };

    size_t pos = 8;
    std::vector<Parsed> parsed;
    std::set<Hash8> seen;

    for (u32 record_index = 0; record_index < bundle_count; ++record_index) {
        const size_t start = pos;
        if (pos + 12 > data.size()) throw PatcherError("bundle database bundle record is truncated");
        const Hash8 name_hash = slice_hash8(data, pos); pos += 8;
        if (!seen.insert(name_hash).second) throw PatcherError("duplicate bundle hash in bundle database: " + hex_bytes(name_hash.data(), 8, true));
        const u32 entry_count = read_u32(data, pos); pos += 4;
        if (entry_count < 1 || entry_count > 1024) throw PatcherError("implausible bundle database record count: " + std::to_string(entry_count));
        std::vector<DatabaseEntry> entries;

        for (u32 index = 0; index < entry_count; ++index) {
            const size_t entry_start = pos;
            if (index > 0) {
                if (pos + 8 > data.size()) throw PatcherError("bundle database patch entry is truncated");
                pos += 8;
            }
            if (read_u32(data, pos, "bundle database is truncated") != 4) throw PatcherError("bundle database entry constant mismatch");
            pos += 4;
            auto name = read_db_string(data, pos); pos = name.second;
            auto stream = read_db_string(data, pos); pos = stream.second;
            if (pos >= data.size() || data[pos] != 0) throw PatcherError("bundle database entry terminator is missing");
            ++pos;
            if (pos + 20 > data.size()) throw PatcherError("bundle database entry trailer is truncated");
            pos += 20;
            entries.push_back({name.first, stream.first, entry_start, pos});
        }

        if (pos + 8 > data.size()) throw PatcherError("bundle database bundle record footer is truncated");
        const u64 footer = read_u64(data, pos); pos += 8;
        parsed.push_back({name_hash, entry_count, std::move(entries), footer, start, pos});
    }

    const size_t records_end = pos;
    const size_t index_count_offset = pos;
    const u32 indexed_bundle_count = read_u32(data, pos, "bundle database is truncated"); pos += 4;
    if (indexed_bundle_count != bundle_count) throw PatcherError("bundle database bundle-index count mismatch: " + std::to_string(indexed_bundle_count) + " != " + std::to_string(bundle_count));
    const size_t index_start = pos;
    const u64 index_bytes = static_cast<u64>(indexed_bundle_count) * 16;
    if (pos + index_bytes > data.size()) throw PatcherError("bundle database bundle index is truncated");
    std::vector<DatabaseBundleRecord> records;

    for (u32 index = 0; index < indexed_bundle_count; ++index) {
        const size_t item_start = index_start + static_cast<size_t>(index) * 16;
        const Hash8 index_hash = slice_hash8(data, item_start);
        const Parsed &item = parsed[index];
        if (index_hash != item.name_hash) throw PatcherError("bundle database index hash mismatch for record " + std::to_string(index));
        DatabaseBundleRecord record;
        record.name_hash_le = item.name_hash;
        record.count = item.count;
        record.entries = item.entries;
        record.footer_filetime = item.footer;
        record.start = item.start;
        record.end = item.end;
        record.index_start = item_start;
        record.index_end = item_start + 16;
        record.index_aux_le = slice_hash8(data, item_start + 8);
        records.push_back(std::move(record));
    }

    pos += static_cast<size_t>(index_bytes);
    return {records_end, index_count_offset, index_start, pos, std::move(records)};
}

static PackageTable parse_package_table(const Bytes &data) {
    const BundleTable bundle_table = parse_bundle_table(data);
    size_t pos = bundle_table.package_count_offset;
    const size_t count_offset = pos;
    const u32 package_count = read_u32(data, pos, "bundle database package table is truncated"); pos += 4;
    std::vector<PackageDefinitionRecord> records;
    std::set<Hash8> seen;

    for (u32 i = 0; i < package_count; ++i) {
        const size_t start = pos;
        if (pos + 12 > data.size()) throw PatcherError("bundle database package table is truncated");
        const Hash8 name_hash = slice_hash8(data, pos); pos += 8;
        if (!seen.insert(name_hash).second) throw PatcherError("duplicate package hash in bundle database: " + hex_bytes(name_hash.data(), 8, true));
        const u32 resource_count = read_u32(data, pos); pos += 4;
        const u64 resource_bytes = static_cast<u64>(resource_count) * 16;
        if (pos + resource_bytes > data.size()) throw PatcherError("bundle database package resource list is truncated");
        std::vector<std::pair<Hash8, Hash8>> entries;
        entries.reserve(resource_count);
        for (u32 j = 0; j < resource_count; ++j) {
            entries.push_back({slice_hash8(data, pos + static_cast<size_t>(j) * 16), slice_hash8(data, pos + static_cast<size_t>(j) * 16 + 8)});
        }
        pos += static_cast<size_t>(resource_bytes);
        records.push_back({name_hash, std::move(entries), start, pos});
    }

    if (pos != data.size()) throw PatcherError("bundle database has " + std::to_string(data.size() - pos) + " unexpected trailing byte(s)");
    return {count_offset, pos, std::move(records)};
}

static Bytes generated_bundle_record(const std::string &bundle_name, u64 footer_filetime) {
    Bytes out;
    append_bytes(out, bundle_hash_le(bundle_name));
    write_u32(out, 1);
    write_u32(out, 4);
    append_string(out, bundle_name);
    append_string(out, bundle_name + ".stream");
    out.push_back(0);
    out.insert(out.end(), 20, 0);
    write_u64(out, footer_filetime);
    return out;
}

int bundle_registration_count(const Bytes &data, const std::string &bundle_name) {
    const Hash8 hash = bundle_hash_le(bundle_name);
    int count = 0;
    for (const auto &record : parse_bundle_table(data).records) if (record.name_hash_le == hash) ++count;
    return count;
}

std::set<std::string> recover_generated_bundle_ownership(const Bytes &data, const std::vector<std::string> &desired_bundles) {
    const BundleTable table = parse_bundle_table(data);
    std::set<Hash8> package_hashes;
    for (const auto &record : parse_package_table(data).records) package_hashes.insert(record.name_hash_le);
    std::map<Hash8, DatabaseBundleRecord> existing;
    for (const auto &record : table.records) existing[record.name_hash_le] = record;
    std::set<std::string> recovered;

    for (const auto &bundle_name : desired_bundles) {
        Hash8 hash{};
        try { hash = bundle_hash_le(bundle_name); } catch (...) { continue; }
        const auto it = existing.find(hash);
        if (it == existing.end() || !package_hashes.count(hash)) continue;
        const Bytes expected = generated_bundle_record(bundle_name, it->second.footer_filetime);
        if (slice_bytes(data, it->second.start, it->second.end) != expected) continue;
        if (it->second.index_aux_le != Hash8{}) continue;
        recovered.insert(bundle_name);
    }

    return recovered;
}

std::set<std::string> recover_generated_package_ownership(const Bytes &data, const std::vector<std::string> &desired_packages) {
    std::set<Hash8> existing_hashes;
    for (const auto &record : parse_package_table(data).records) existing_hashes.insert(record.name_hash_le);
    std::map<std::string, std::string> bundle_by_package;
    std::vector<std::string> bundle_names;
    for (const auto &package_name : desired_packages) {
        if (package_name.empty()) continue;
        const std::string bundle = identity_hash(package_name).second;
        bundle_by_package[package_name] = bundle;
        bundle_names.push_back(bundle);
    }
    const std::set<std::string> recovered_bundles = recover_generated_bundle_ownership(data, bundle_names);
    std::set<std::string> recovered;
    for (const auto &item : bundle_by_package) {
        if (existing_hashes.count(identity_hash(item.first).first) && recovered_bundles.count(item.second)) recovered.insert(item.first);
    }
    return recovered;
}


ReconcileResult reconcile_bundle_registrations(
    const Bytes &data,
    const std::vector<std::string> &desired_bundles,
    const std::set<std::string> &managed_bundles,
    const std::set<std::string> &refresh_bundles,
    u64 footer_filetime
) {
    const BundleTable table = parse_bundle_table(data);
    std::map<Hash8, DatabaseBundleRecord> existing;
    for (const auto &record : table.records) existing[record.name_hash_le] = record;
    std::map<Hash8, std::string> desired_by_hash;

    for (const auto &bundle_name : desired_bundles) {
        const Hash8 hash = bundle_hash_le(bundle_name);
        const auto previous = desired_by_hash.find(hash);
        if (previous != desired_by_hash.end() && previous->second != bundle_name) throw PatcherError("generated bundle hash collision: " + previous->second + " and " + bundle_name);
        desired_by_hash[hash] = bundle_name;
    }

    std::set<Hash8> managed_hashes;
    for (const auto &name : managed_bundles) { try { managed_hashes.insert(bundle_hash_le(name)); } catch (...) {} }
    std::set<Hash8> refresh_hashes;
    for (const auto &name : refresh_bundles) { try { refresh_hashes.insert(bundle_hash_le(name)); } catch (...) {} }
    for (const auto &item : desired_by_hash) {
        if (existing.count(item.first) && !managed_hashes.count(item.first)) throw PatcherError("bundle database hash collision for unmanaged generated bundle " + item.second);
    }

    std::vector<Bytes> output_records;
    std::vector<Bytes> output_indices;
    std::set<Hash8> present;
    ReconcileResult result;

    for (const auto &record : table.records) {
        if (managed_hashes.count(record.name_hash_le) && !desired_by_hash.count(record.name_hash_le)) {
            ++result.removed;
            continue;
        }
        const auto desired = desired_by_hash.find(record.name_hash_le);
        if (desired != desired_by_hash.end() && managed_hashes.count(record.name_hash_le)) {
            const Bytes generated = generated_bundle_record(desired->second, footer_filetime);
            const Bytes current_prefix = slice_bytes(data, record.start, record.end - 8);
            const Bytes generated_prefix(generated.begin(), generated.end() - 8);
            const bool structural_match = current_prefix == generated_prefix;
            const bool index_match = record.index_aux_le == Hash8{};
            if (!structural_match || !index_match || refresh_hashes.count(record.name_hash_le)) {
                output_records.push_back(generated);
                Bytes index;
                append_bytes(index, record.name_hash_le);
                index.insert(index.end(), 8, 0);
                output_indices.push_back(std::move(index));
                ++result.updated;
            } else {
                output_records.push_back(slice_bytes(data, record.start, record.end));
                output_indices.push_back(slice_bytes(data, record.index_start, record.index_end));
            }
        } else {
            output_records.push_back(slice_bytes(data, record.start, record.end));
            output_indices.push_back(slice_bytes(data, record.index_start, record.index_end));
        }
        present.insert(record.name_hash_le);
    }

    std::vector<std::pair<std::string, Hash8>> additions;
    for (const auto &item : desired_by_hash) if (!present.count(item.first)) additions.push_back({item.second, item.first});
    std::sort(additions.begin(), additions.end());
    for (const auto &item : additions) {
        output_records.push_back(generated_bundle_record(item.first, footer_filetime));
        Bytes index;
        append_bytes(index, item.second);
        index.insert(index.end(), 8, 0);
        output_indices.push_back(std::move(index));
        ++result.added;
    }

    if (!result.added && !result.updated && !result.removed) {
        result.data = data;
        return result;
    }

    Bytes rebuilt;
    rebuilt.insert(rebuilt.end(), data.begin(), data.begin() + 4);
    write_u32(rebuilt, static_cast<u32>(output_records.size()));
    for (const auto &record : output_records) append_bytes(rebuilt, record);
    write_u32(rebuilt, static_cast<u32>(output_indices.size()));
    for (const auto &index : output_indices) append_bytes(rebuilt, index);
    rebuilt.insert(rebuilt.end(), data.begin() + static_cast<std::ptrdiff_t>(table.package_count_offset), data.end());
    parse_bundle_table(rebuilt);
    parse_package_table(rebuilt);
    result.data = std::move(rebuilt);
    return result;
}

static Bytes package_record_bytes(const std::string &package_name, const std::vector<std::pair<Hash8, Hash8>> &entries) {
    Bytes out;
    append_bytes(out, identity_hash(package_name).first);
    write_u32(out, static_cast<u32>(entries.size()));
    for (const auto &entry : entries) { append_bytes(out, entry.first); append_bytes(out, entry.second); }
    return out;
}

std::optional<std::vector<std::pair<Hash8, Hash8>>> package_members(const Bytes &data, const std::string &package_name) {
    const Hash8 hash = identity_hash(package_name).first;
    for (const auto &record : parse_package_table(data).records) if (record.name_hash_le == hash) return record.entries;
    return std::nullopt;
}

ReconcileResult reconcile_package_registrations(
    const Bytes &data,
    const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &desired,
    const std::set<std::string> &managed_packages
) {
    const PackageTable table = parse_package_table(data);
    std::map<Hash8, PackageDefinitionRecord> existing;
    for (const auto &record : table.records) existing[record.name_hash_le] = record;
    std::map<Hash8, std::pair<std::string, std::vector<std::pair<Hash8, Hash8>>>> desired_by_hash;

    for (const auto &item : desired) {
        if (item.first.empty()) throw PatcherError("package name must be a non-empty string");
        std::set<std::pair<Hash8, Hash8>> seen;
        for (const auto &entry : item.second) {
            if (!seen.insert(entry).second) throw PatcherError("duplicate package member " + hex_bytes(entry.first.data(), 8, true) + "/" + hex_bytes(entry.second.data(), 8, true));
        }
        const Hash8 hash = identity_hash(item.first).first;
        const auto previous = desired_by_hash.find(hash);
        if (previous != desired_by_hash.end() && previous->second.first != item.first) throw PatcherError("generated package hash collision: " + previous->second.first + " and " + item.first);
        desired_by_hash[hash] = item;
    }

    std::set<Hash8> managed_hashes;
    for (const auto &name : managed_packages) if (!name.empty()) managed_hashes.insert(identity_hash(name).first);
    std::set<Hash8> remove_hashes;
    for (const auto &hash : managed_hashes) if (!desired_by_hash.count(hash)) remove_hashes.insert(hash);
    std::set<Hash8> update_hashes;
    for (const auto &item : desired_by_hash) {
        const auto record = existing.find(item.first);
        if (record == existing.end()) continue;
        if (!managed_hashes.count(item.first)) throw PatcherError("bundle database package hash collision for unmanaged package " + item.second.first + " (#ID[" + hex_bytes(item.first.data(), 8, true) + "])");
        if (record->second.entries != item.second.second) update_hashes.insert(item.first);
    }

    std::vector<Bytes> records;
    std::set<Hash8> present;
    ReconcileResult result;
    for (const auto &record : table.records) {
        if (remove_hashes.count(record.name_hash_le)) { ++result.removed; continue; }
        if (update_hashes.count(record.name_hash_le)) {
            const auto &item = desired_by_hash.at(record.name_hash_le);
            records.push_back(package_record_bytes(item.first, item.second));
            ++result.updated;
        } else {
            records.push_back(slice_bytes(data, record.start, record.end));
        }
        present.insert(record.name_hash_le);
    }

    std::vector<std::pair<std::string, Hash8>> additions;
    for (const auto &item : desired_by_hash) if (!present.count(item.first)) additions.push_back({item.second.first, item.first});
    std::sort(additions.begin(), additions.end());
    for (const auto &item : additions) {
        const auto &desired_item = desired_by_hash.at(item.second);
        records.push_back(package_record_bytes(desired_item.first, desired_item.second));
        ++result.added;
    }

    if (!result.added && !result.updated && !result.removed) {
        result.data = data;
        return result;
    }

    Bytes rebuilt(data.begin(), data.begin() + static_cast<std::ptrdiff_t>(table.count_offset));
    write_u32(rebuilt, static_cast<u32>(records.size()));
    for (const auto &record : records) append_bytes(rebuilt, record);
    parse_package_table(rebuilt);
    result.data = std::move(rebuilt);
    return result;
}

// Darktide Mod Loader's patch_999 registration (mods only load with it)
int mod_loader_registration_count(const Bytes &data) {
    const std::string patch_name = std::string(STORAGE_BASE_BUNDLE) + ".patch_999";
    const std::string stream_name = std::string(STORAGE_BASE_BUNDLE) + ".stream.patch_999";
    int count = 0;
    for (const auto &entry : parse_record(data, STORAGE_BASE_BUNDLE).entries) if (entry.name == patch_name && entry.stream_name == stream_name) ++count;
    return count;
}

} // namespace ca

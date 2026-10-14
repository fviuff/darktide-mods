#include "oodle.h"
#include "cooked.h"

#include <tuple>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

namespace ca {


struct Kind0Texture {
    Bytes header;
    Bytes stream_name;
    Bytes resident;
    Bytes tail;
    std::vector<Bytes> chunks;
};

static std::tuple<Bytes, Bytes, Bytes> texture_body_parts(const Bytes &blob) {
    if (blob.size() < 38) throw PatcherError("cooked texture is truncated");
    if (read_u32(blob, 16) != 1 || blob[33] != 1) throw PatcherError("cooked texture must contain exactly one supported variant");
    const u32 body_size = read_u32(blob, 29);
    const u32 stream_name_size = read_u32(blob, 34);
    if (blob.size() != 38ull + body_size + stream_name_size) throw PatcherError("cooked texture envelope length mismatch");
    Bytes header = slice_bytes(blob, 0, 38);
    Bytes body = slice_bytes(blob, 38, 38 + body_size);
    Bytes stream_name = slice_bytes(blob, 38 + body_size, blob.size());
    for (u8 c : stream_name) if (c > 0x7f) throw PatcherError("cooked texture stream name is not ASCII");
    return {std::move(header), std::move(body), std::move(stream_name)};
}

u32 texture_compressor_kind(const fs::path &path) {
    auto [header, body, stream_name] = texture_body_parts(read_file(path));
    (void)header; (void)stream_name;
    if (body.size() < 12) throw PatcherError(path_text(path) + ": texture body is truncated");
    return read_u32(body, 0);
}

static Kind0Texture parse_kind0(const Bytes &blob, const Bytes &stream_blob) {
    auto [header, body, stream_name] = texture_body_parts(blob);
    if (body.size() < 12) throw PatcherError("kind-0 texture body is truncated");
    const u32 kind = read_u32(body, 0);
    const u32 packed_size = read_u32(body, 4);
    const u32 resident_size = read_u32(body, 8);
    if (kind != 0) throw PatcherError("expected texture compressor kind 0, got " + std::to_string(kind));
    if (packed_size != resident_size) throw PatcherError("kind-0 resident payload must be raw (" + std::to_string(packed_size) + " != " + std::to_string(resident_size) + ")");
    const size_t resident_start = 12;
    const size_t resident_end = resident_start + packed_size;
    if (resident_end + 20 + 128 + 12 > body.size()) throw PatcherError("kind-0 texture family is truncated");
    Bytes resident = slice_bytes(body, resident_start, resident_end);
    Bytes tail = slice_bytes(body, resident_end, body.size());
    if (read_u32(tail, 0) != 67) throw PatcherError("kind-0 texture body marker is not 67");
    const size_t meta_pos = 20 + 128;
    const u32 meta_size = read_u32(tail, meta_pos);
    const size_t table_pos = meta_pos + 4;
    const u32 chunk_count = read_u32(tail, table_pos);
    const u16 zero = static_cast<u16>(tail[table_pos + 4] | (static_cast<u16>(tail[table_pos + 5]) << 8));
    const u16 echoed = static_cast<u16>(tail[table_pos + 6] | (static_cast<u16>(tail[table_pos + 7]) << 8));
    const size_t cumulative_pos = table_pos + 8;
    if (zero != 0 || echoed != chunk_count || meta_size != 8 + 4 * chunk_count) throw PatcherError("kind-0 texture chunk metadata is inconsistent");
    const size_t footer_pos = cumulative_pos + static_cast<size_t>(chunk_count) * 4;
    if (footer_pos + 4 != tail.size()) throw PatcherError("kind-0 texture chunk table does not end at the footer");
    std::vector<u32> cumulative;
    for (u32 i = 0; i < chunk_count; ++i) cumulative.push_back(read_u32(tail, cumulative_pos + static_cast<size_t>(i) * 4));
    const u32 expected_stream = cumulative.empty() ? 0 : cumulative.back();
    if (stream_blob.size() != expected_stream) throw PatcherError("kind-0 texture stream length mismatch: table=" + std::to_string(expected_stream) + ", file=" + std::to_string(stream_blob.size()));
    std::vector<Bytes> chunks;
    u32 previous = 0;
    for (u32 end : cumulative) {
        if (end <= previous || end > stream_blob.size()) throw PatcherError("kind-0 texture chunk offsets are invalid");
        chunks.push_back(slice_bytes(stream_blob, previous, end));
        previous = end;
    }
    return {std::move(header), std::move(stream_name), std::move(resident), std::move(tail), std::move(chunks)};
}

void transcode_kind0_texture(
    const fs::path &texture_source,
    const fs::path &stream_source,
    const fs::path &texture_destination,
    const fs::path &stream_destination,
    DarktideOodleTextureCodec &codec
) {
    Kind0Texture texture = parse_kind0(read_file(texture_source), read_file(stream_source));
    const Bytes packed_resident = codec.compress(texture.resident);
    std::vector<Bytes> packed_chunks;
    std::vector<u32> cumulative;
    u64 total = 0;
    for (const auto &raw : texture.chunks) {
        Bytes packed = codec.compress(raw);
        total += packed.size();
        if (total > 0xffffffffull) throw PatcherError("Oodle texture stream exceeds the 32-bit chunk table");
        cumulative.push_back(static_cast<u32>(total));
        packed_chunks.push_back(std::move(packed));
    }
    const size_t meta_pos = 20 + 128;
    const size_t table_pos = meta_pos + 4;
    const u32 chunk_count = read_u32(texture.tail, table_pos);
    const size_t cumulative_pos = table_pos + 8;
    if (chunk_count != cumulative.size()) throw PatcherError("texture chunk count changed during Oodle preparation");
    for (size_t i = 0; i < cumulative.size(); ++i) overwrite_u32(texture.tail, cumulative_pos + i * 4, cumulative[i]);
    Bytes new_body;
    write_u32(new_body, 1);
    write_u32(new_body, static_cast<u32>(packed_resident.size()));
    write_u32(new_body, static_cast<u32>(texture.resident.size()));
    append_bytes(new_body, packed_resident);
    append_bytes(new_body, texture.tail);
    overwrite_u32(texture.header, 29, static_cast<u32>(new_body.size()));
    Bytes texture_blob = texture.header;
    append_bytes(texture_blob, new_body);
    append_bytes(texture_blob, texture.stream_name);
    Bytes stream_blob;
    for (const auto &chunk : packed_chunks) append_bytes(stream_blob, chunk);
    const TextureInfo info = inspect_texture_body(texture_blob);
    if (info.compressed_stream_bytes != stream_blob.size()) throw PatcherError("generated kind-1 texture stream table does not match generated stream size");
    write_file(texture_destination, texture_blob);
    write_file(stream_destination, stream_blob);
}

} // namespace ca

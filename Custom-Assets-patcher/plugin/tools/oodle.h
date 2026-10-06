#pragma once

// Darktide's own Oodle DLL (binaries/oo2core_9_win64.dll): texture recompression and storage bundle chunks

#include "common.h"
#include "cooked.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

namespace ca {

class DarktideOodleTextureCodec {
public:
    explicit DarktideOodleTextureCodec(const fs::path &dll_path) {
#if defined(_WIN32)
        if (!fs::is_regular_file(dll_path)) throw PatcherError("Darktide Oodle DLL not found: " + path_text(dll_path));
        library = LoadLibraryW(dll_path.c_str());
        if (!library) throw PatcherError("could not load Darktide Oodle DLL " + path_text(dll_path));
        compress_fn = reinterpret_cast<CompressFn>(GetProcAddress(library, "OodleLZ_Compress"));
        decompress_fn = reinterpret_cast<DecompressFn>(GetProcAddress(library, "OodleLZ_Decompress"));
        bound_fn = reinterpret_cast<BoundFn>(GetProcAddress(library, "OodleLZ_GetCompressedBufferSizeNeeded"));
        if (!compress_fn || !decompress_fn || !bound_fn) throw PatcherError("Darktide Oodle DLL is missing a required OodleLZ export: " + path_text(dll_path));
        using PrintfFn = void (__cdecl *)(void *);
        auto printf_fn = reinterpret_cast<PrintfFn>(GetProcAddress(library, "OodleCore_Plugins_SetPrintf"));
        if (printf_fn) printf_fn(nullptr);
#else
        (void)dll_path;
        throw PatcherError("Darktide texture preparation requires Windows so the installed Oodle DLL can be loaded");
#endif
    }

    ~DarktideOodleTextureCodec() {
#if defined(_WIN32)
        if (library) FreeLibrary(library);
#endif
    }

    DarktideOodleTextureCodec(const DarktideOodleTextureCodec &) = delete;
    DarktideOodleTextureCodec &operator=(const DarktideOodleTextureCodec &) = delete;

    Bytes compress(const Bytes &data) {
        if (data.empty()) throw PatcherError("cannot Oodle-compress an empty texture payload");
#if defined(_WIN32)
        const size_t capacity = bound_fn(8, static_cast<i64>(data.size()));
        if (!capacity) throw PatcherError("Oodle returned an invalid compressed buffer size");
        Bytes output(capacity);
        const i64 written = compress_fn(8, data.data(), static_cast<i64>(data.size()), output.data(), 4, nullptr, nullptr, nullptr, nullptr, 0);
        if (written <= 0 || static_cast<size_t>(written) > output.size()) throw PatcherError("OodleLZ_Compress failed with result " + std::to_string(written));
        output.resize(static_cast<size_t>(written));
        if (decompress(output, data.size()) != data) throw PatcherError("Oodle texture compression round-trip mismatch");
        return output;
#else
        return {};
#endif
    }

    Bytes decompress(const Bytes &data, size_t output_size) {
#if defined(_WIN32)
        Bytes output(output_size);
        const i64 written = decompress_fn(data.data(), static_cast<i64>(data.size()), output.data(), static_cast<i64>(output_size), 1, 1, 0, nullptr, 0, nullptr, nullptr, nullptr, 0, 3);
        if (written != static_cast<i64>(output_size)) throw PatcherError("OodleLZ_Decompress returned " + std::to_string(written) + ", expected " + std::to_string(output_size));
        return output;
#else
        (void)data; (void)output_size; return {};
#endif
    }

    Bytes decompress_bundle_chunk(const Bytes &data) {
#if defined(_WIN32)
        Bytes output(PATCH_CHUNK_SIZE);
        const i64 written = decompress_fn(data.data(), static_cast<i64>(data.size()), output.data(), static_cast<i64>(output.size()), 1, 0, 0, nullptr, 0, nullptr, nullptr, nullptr, 0, 3);
        if (written <= 0 || static_cast<size_t>(written) > output.size()) throw PatcherError("OodleLZ_Decompress failed while reading the retail storage bundle");
        output.resize(static_cast<size_t>(written));
        return output;
#else
        (void)data; return {};
#endif
    }

private:
#if defined(_WIN32)
    using CompressFn = i64 (__cdecl *)(int, const void *, i64, void *, int, void *, void *, void *, void *, i64);
    using DecompressFn = i64 (__cdecl *)(const void *, i64, void *, i64, int, int, int, void *, i64, void *, void *, void *, i64, int);
    using BoundFn = size_t (__cdecl *)(int, i64);
    HMODULE library = nullptr;
    CompressFn compress_fn = nullptr;
    DecompressFn decompress_fn = nullptr;
    BoundFn bound_fn = nullptr;
#endif
};

u32 texture_compressor_kind(const fs::path &path);
// raw (kind 0) creator textures become Oodle-packed kind 1 with their stream, as the game ships them
void transcode_kind0_texture(const fs::path &texture_source, const fs::path &stream_source,
                             const fs::path &texture_destination, const fs::path &stream_destination,
                             DarktideOodleTextureCodec &codec);

} // namespace ca

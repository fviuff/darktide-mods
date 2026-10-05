// current darktide renderer layout
static constexpr usize DR_RENDER_DEVICE_D3D12_DEVICE = 0x1e8u;
static constexpr usize DR_RENDER_DEVICE_DIRECT_QUEUE = 0x218u;
static constexpr usize DR_RENDER_DEVICE_RESOURCE_CONTEXT = 0x308u;
static constexpr usize DR_RESOURCE_CONTEXT_OWNER = 0x48u;
static constexpr usize DR_RENDER_TARGET_REGISTRY = 0x148u;
static constexpr usize DR_REGISTRY_SLOT_COUNT = 0x08u;
static constexpr usize DR_REGISTRY_ENTRIES = 0x10u;
static constexpr usize DR_REGISTRY_LIVE_COUNT = 0x20u;
static constexpr usize DR_REGISTRY_BUCKET_COUNT = 0x24u;
static constexpr usize DR_REGISTRY_ENTRY_SIZE = 0x18u;
static constexpr usize DR_REGISTRY_ENTRY_KEY = 0x00u;
static constexpr usize DR_REGISTRY_ENTRY_VALUE = 0x08u;
static constexpr usize DR_REGISTRY_ENTRY_NEXT = 0x10u;
static constexpr u32 DR_REGISTRY_FREE_NEXT = 0xfffffffeu;
static constexpr u32 DR_REGISTRY_END_NEXT = 0x7fffffffu;
static constexpr usize DR_DESCRIPTOR_TYPE = 0x00u;
static constexpr usize DR_DESCRIPTOR_HANDLE = 0x04u;
static constexpr usize DR_DESCRIPTOR_NAME_HASH = 0x28u;
static constexpr usize DR_RENDER_DEVICE_SWAP_COUNT = 0x2e0u;
static constexpr usize DR_RENDER_DEVICE_SWAP_RECORDS = 0x2e8u;
static constexpr usize DR_SWAP_RECORD_SIZE = 0x60u;
static constexpr usize DR_SWAP_RECORD_SWAPCHAIN = 0x08u;
static constexpr usize DR_SWAP_RECORD_ACTIVE = 0x10u;
static constexpr usize DR_SWAP_RECORD_CURRENT_INDEX = 0x24u;
static constexpr usize DR_SWAP_RECORD_BUFFER_COUNT = 0x40u;
static constexpr usize DR_RESOURCE_LUT = 0x50u;
static constexpr usize DR_RESOURCE_LUT_COUNT = 0x50u;
static constexpr usize DR_RESOURCE_LUT_ENTRIES = 0x58u;
static constexpr usize DR_RESOURCE_OBJECTS = 0x118u;
static constexpr usize DR_RESOURCE_OBJECT_SIZE = 0x128u;
static constexpr usize DR_RESOURCE_OBJECT_NAME_HASH = 0x28u;
static constexpr usize DR_RESOURCE_OBJECT_STATE = 0x68u;
static constexpr usize DR_RT_CACHE_COUNT = 0xaa8u;
static constexpr usize DR_RT_CACHE_ENTRIES = 0xab0u;
static constexpr usize DR_RT_CACHE_ENTRY_SIZE = 0x70u;
static constexpr usize DR_RT_CACHE_NAME_HASH = 0x28u;
static constexpr usize DR_RT_CACHE_TEXTURE = 0x68u;
static constexpr usize DR_TEXTURE_STATE = 0x68u;
static constexpr usize DR_STATE_RESOURCE = 0x08u;
static constexpr usize DR_STATE_GLOBAL = 0x10u;
static constexpr usize DR_STATE_SUBRESOURCES = 0x18u;
static constexpr usize DR_STATE_SUBRESOURCE_COUNT = 0x20u;
static constexpr u32 DR_FRAME_SLOTS = 3u;
static constexpr u32 DR_DXGI_PRESENT_TEST = 0x1u;
static constexpr u32 DR_D3D12_RESOURCE_STATE_PRESENT = 0u;
static constexpr u32 DR_DXGI_FORMAT_R10G10B10A2_TYPELESS = 23u;
static constexpr u32 DR_DXGI_FORMAT_R10G10B10A2_UNORM = 24u;
static constexpr u32 DR_DXGI_FORMAT_R8G8B8A8_TYPELESS = 27u;
static constexpr u32 DR_DXGI_FORMAT_B8G8R8X8_UNORM = 88u;
static constexpr u32 DR_DXGI_FORMAT_B8G8R8A8_TYPELESS = 90u;
static constexpr u32 DR_DXGI_FORMAT_B8G8R8X8_TYPELESS = 92u;
static constexpr u32 DR_DXGI_FORMAT_B8G8R8X8_UNORM_SRGB = 93u;
static constexpr HRESULT DR_DXGI_ERROR_INVALID_CALL = static_cast<HRESULT>(0x887a0001u);

using DrPresentFn = HRESULT (STDCALL *)(void *, u32, u32);

struct DrFrameSlot {
    void *allocator;
    void *list;
    void *upload;
    u8 *mapped;
    u64 capacity;
    u64 fence_value;
    u64 source_sequence;
    u32 source_slot;
    u32 source_generation;
    u32 source_x;
    u32 source_y;
    u32 source_width;
    u32 source_height;
    u32 source_format;
};

static DrFrameSlot g_dr_frames[DR_FRAME_SLOTS]{};
static void *g_dr_render_device = nullptr;
static void *g_dr_device = nullptr;
static void *g_dr_queue = nullptr;
static void *g_dr_fence = nullptr;
static u64 g_dr_next_fence = 1u;
static volatile u32 g_dr_error_lock = 0u;
static volatile u32 g_dr_target_lock = 0u;
static volatile u32 g_dr_resources_ready = 0u;
static volatile u32 g_dr_hooked = 0u;
static volatile u32 g_dr_requested = 0u;
static volatile u32 g_dr_build_checked = 0u;
static volatile u32 g_dr_build_ok = 0u;
static char g_dr_error[512]{};
static char g_dr_error_snapshot[512]{};

// pointer slot stays for process lifetime
static u8 *g_dr_patch_word_address = nullptr;
static u64 g_dr_patch_original_word = 0u;
static u64 g_dr_patch_installed_word = 0u;
static void **g_dr_hook_pointer_page = nullptr;
static u8 **g_dr_render_device_global = nullptr;
static u8 *g_dr_present_callsite = nullptr;

static void dr_set_error(const char *text) {
    if (!try_lock_u32(&g_dr_error_lock)) {
        return;
    }

    copy_cstr(g_dr_error, sizeof(g_dr_error), text ? text : "");
    unlock_u32(&g_dr_error_lock);
}

static const char *dr_get_error() {
    lock_u32(&g_dr_error_lock);
    copy_cstr(g_dr_error_snapshot, sizeof(g_dr_error_snapshot), g_dr_error);
    unlock_u32(&g_dr_error_lock);
    return g_dr_error_snapshot;
}

static bool dr_bytes_equal(const u8 *p, const u8 *bytes, usize count) {
    if (!readable_range(p, count)) {
        return false;
    }

    for (usize i = 0; i < count; ++i) {
        if (p[i] != bytes[i]) {
            return false;
        }
    }

    return true;
}

static bool dr_section_range(u32 image_size, const u8 *section, u32 *rva, u32 *size, u32 *characteristics) {
    const u32 address = *reinterpret_cast<const u32 *>(section + 12u);
    const u32 virtual_size = *reinterpret_cast<const u32 *>(section + 8u);
    const u32 raw_size = *reinterpret_cast<const u32 *>(section + 16u);
    const u32 extent = virtual_size > raw_size ? virtual_size : raw_size;

    if (!extent || address > image_size || extent > image_size - address) {
        return false;
    }

    *rva = address;
    *size = extent;
    *characteristics = *reinterpret_cast<const u32 *>(section + 36u);
    return true;
}

static bool dr_readable_protection(DWORD protect) {
    if (protect & PAGE_GUARD) {
        return false;
    }

    const DWORD access = protect & 0xffu;
    return access == 0x02u || access == 0x04u || access == 0x08u ||
           access == PAGE_EXECUTE_READ || access == PAGE_EXECUTE_READWRITE ||
           access == PAGE_EXECUTE_WRITECOPY;
}

static bool dr_scan_pattern(const u8 *base, u32 rva, u32 size, const u8 *pattern, const u8 *mask, usize pattern_size, u32 *match, u32 *count) {
    if (pattern_size > size || !pVirtualQuery) {
        return false;
    }

    const usize start = reinterpret_cast<usize>(base + rva);
    const usize finish = start + size;
    usize cursor = start;

    while (cursor < finish) {
        MEMORY_BASIC_INFORMATION_ info{};

        if (pVirtualQuery(reinterpret_cast<void *>(cursor), &info, sizeof(info)) != sizeof(info)) {
            return false;
        }

        const usize region_start = reinterpret_cast<usize>(info.BaseAddress);
        const usize region_end = region_start + info.RegionSize;
        if (info.State != MEM_COMMIT || !dr_readable_protection(info.Protect) || region_end <= cursor) {
            return false;
        }

        cursor = region_end < finish ? region_end : finish;
    }

    const u8 *bytes = base + rva;
    for (usize i = 0; i <= size - pattern_size; ++i) {
        bool equal = true;
        for (usize j = 0; j < pattern_size; ++j) {
            if (mask[j] && bytes[i + j] != pattern[j]) {
                equal = false;
                break;
            }
        }
        if (equal) {
            ++*count;
            *match = rva + static_cast<u32>(i);
        }
    }

    return true;
}

static bool dr_discover_renderer() {
    if (atomic_load_u32(&g_dr_build_checked)) {
        return atomic_load_u32(&g_dr_build_ok) != 0u;
    }

    u8 *base = exe_base();
    if (!base || !readable_range(base, 0x40u) || *reinterpret_cast<u16 *>(base) != 0x5a4du) {
        dr_set_error("Darktide executable header is not readable");
        goto failed;
    }

    {
        const u32 pe_offset = *reinterpret_cast<u32 *>(base + 0x3cu);
        if (pe_offset < 0x40u || pe_offset > 0x100000u || !readable_range(base + pe_offset, 24u) ||
            *reinterpret_cast<u32 *>(base + pe_offset) != 0x4550u) {
            dr_set_error("Darktide PE header is invalid");
            goto failed;
        }

        const u8 *file = base + pe_offset + 4u;
        const u16 machine = *reinterpret_cast<const u16 *>(file);
        const u16 section_count = *reinterpret_cast<const u16 *>(file + 2u);
        const u16 optional_size = *reinterpret_cast<const u16 *>(file + 16u);
        const u8 *optional = file + 20u;
        if (machine != 0x8664u || !section_count || section_count > 96u || optional_size < 64u ||
            !readable_range(optional, optional_size) || *reinterpret_cast<const u16 *>(optional) != 0x20bu) {
            dr_set_error("Darktide executable is not a valid AMD64 PE32+");
            goto failed;
        }

        const u32 image_size = *reinterpret_cast<const u32 *>(optional + 56u);
        const u32 section_offset = pe_offset + 24u + optional_size;
        const u32 section_bytes = static_cast<u32>(section_count) * 40u;
        if (image_size < section_offset || section_offset > image_size || section_bytes > image_size - section_offset ||
            !readable_range(base + section_offset, section_bytes)) {
            dr_set_error("Darktide PE section table is invalid");
            goto failed;
        }

        u32 text_rva = 0u, text_size = 0u, text_characteristics = 0u;
        const u8 *sections = base + section_offset;
        u32 text_count = 0u;
        for (u32 i = 0; i < section_count; ++i) {
            const u8 *section = sections + i * 40u;
            u32 section_rva = 0u, section_size = 0u, characteristics = 0u;
            if (!dr_section_range(image_size, section, &section_rva, &section_size, &characteristics)) {
                dr_set_error("Darktide PE section range is invalid or unreadable");
                goto failed;
            }
            if (section[0] == '.' && section[1] == 't' && section[2] == 'e' && section[3] == 'x' && section[4] == 't') {
                ++text_count;
                text_rva = section_rva;
                text_size = section_size;
                text_characteristics = characteristics;
            }
        }

        if (text_count != 1u || !(text_characteristics & 0x40000000u) || !(text_characteristics & 0x20000000u)) {
            dr_set_error("Darktide .text section is missing or invalid");
            goto failed;
        }

        static const u8 global_pattern[] = {0x48, 0x89, 0x0d, 0, 0, 0, 0, 0x48, 0x8b, 0xd9};
        static const u8 global_mask[] = {1, 1, 1, 0, 0, 0, 0, 1, 1, 1};
        static const u8 execute_site[] = {
            0x48, 0x8b, 0x8e, 0x18, 0x02, 0x00, 0x00, 0x4d, 0x8d, 0x47, 0x10,
            0xba, 0x01, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x01, 0xff, 0x50, 0x50,
        };
        static const u8 present_setup[] = {
            0x49, 0x8b, 0x4c, 0x24, 0x08, 0x8b, 0xd7, 0x40, 0x38, 0xbe, 0xc5, 0x02,
            0x00, 0x00, 0x44, 0x8b, 0xc3, 0x0f, 0x95, 0xc2, 0x48, 0x8b, 0x01, 0xff,
            0x50, 0x40,
        };
        static const u8 exact_mask[sizeof(present_setup)] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
        u32 global_match = 0u, global_matches = 0u, setup_match = 0u, setup_matches = 0u;
        if (!dr_scan_pattern(base, text_rva, text_size, global_pattern, global_mask, sizeof(global_pattern), &global_match, &global_matches) ||
            !dr_scan_pattern(base, text_rva, text_size, present_setup, exact_mask, sizeof(present_setup), &setup_match, &setup_matches) ||
            global_matches != 1u || setup_matches != 1u || setup_match < text_rva ||
            setup_match - text_rva < 0xdeu || setup_match - text_rva > text_size ||
            text_size - (setup_match - text_rva) < 0x1bu) {
            dr_set_error("Darktide renderer signatures are missing or ambiguous");
            goto failed;
        }

        if (!dr_bytes_equal(base + setup_match - 0xdeu, execute_site, sizeof(execute_site))) {
            dr_set_error("Darktide Present execute sequence failed validation");
            goto failed;
        }

        const i32 displacement = *reinterpret_cast<const i32 *>(base + global_match + 3u);
        const i64 global_address = static_cast<i64>(reinterpret_cast<usize>(base + global_match + 7u)) + displacement;
        if (global_address < static_cast<i64>(reinterpret_cast<usize>(base)) ||
            global_address >= static_cast<i64>(reinterpret_cast<usize>(base)) + image_size) {
            dr_set_error("render-device global target is outside the executable image");
            goto failed;
        }
        const u32 target_rva = static_cast<u32>(global_address - reinterpret_cast<usize>(base));
        bool writable_data = false;
        for (u32 i = 0; i < section_count; ++i) {
            const u8 *section = sections + i * 40u;
            u32 section_rva = 0u, section_size = 0u, characteristics = 0u;
            if (!dr_section_range(image_size, section, &section_rva, &section_size, &characteristics)) {
                dr_set_error("Darktide PE section range is invalid or unreadable");
                goto failed;
            }
            if (section_size >= sizeof(void *) && target_rva >= section_rva &&
                target_rva - section_rva <= section_size - sizeof(void *) &&
                (characteristics & 0x80000000u) && !(characteristics & 0x20000000u)) {
                writable_data = true;
            }
        }

        auto **global = reinterpret_cast<u8 **>(global_address);
        if (!writable_data || (reinterpret_cast<usize>(global) & (sizeof(void *) - 1u)) != 0u ||
            !readable_range(global, sizeof(void *))) {
            dr_set_error("render-device global slot failed validation");
            goto failed;
        }

        u8 *callsite = base + setup_match + 0x14u;
        u8 *aligned = callsite - 1u;
        static const u8 patch_bytes[8] = {0xc2, 0x48, 0x8b, 0x01, 0xff, 0x50, 0x40, 0x4c};
        if ((reinterpret_cast<usize>(aligned) & 7ull) != 0u || !dr_bytes_equal(aligned, patch_bytes, sizeof(patch_bytes))) {
            dr_set_error("Present patch site failed alignment or byte validation");
            goto failed;
        }

        g_dr_render_device_global = global;
        g_dr_present_callsite = callsite;
    }

    atomic_store_u32(&g_dr_build_ok, 1u);
    atomic_store_u32(&g_dr_build_checked, 1u);
    return true;

failed:
    atomic_store_u32(&g_dr_build_checked, 1u);
    return false;
}

static bool dr_executable_address(void *p) {
    if (!p || !pVirtualQuery) {
        return false;
    }

    MEMORY_BASIC_INFORMATION_ info{};

    if (pVirtualQuery(p, &info, sizeof(info)) != sizeof(info) ||
        info.State != MEM_COMMIT ||
        (info.Protect & PAGE_GUARD)) {
        return false;
    }

    const DWORD protect = info.Protect & 0xffu;
    return protect == PAGE_EXECUTE ||
           protect == PAGE_EXECUTE_READ ||
           protect == PAGE_EXECUTE_READWRITE ||
           protect == PAGE_EXECUTE_WRITECOPY;
}

static bool dr_read_engine_objects() {
    if (!dr_discover_renderer()) {
        return false;
    }

    auto **global = g_dr_render_device_global;

    if (!readable_range(global, sizeof(void *))) {
        dr_set_error("render-device global is unreadable");
        return false;
    }

    u8 *render_device = *global;

    if (!render_device || !readable_range(render_device, 0x2f0u)) {
        dr_set_error("Darktide render device is not ready");
        return false;
    }

    void *device = *reinterpret_cast<void **>(render_device + DR_RENDER_DEVICE_D3D12_DEVICE);
    void *queue = *reinterpret_cast<void **>(render_device + DR_RENDER_DEVICE_DIRECT_QUEUE);

    if (!device || !queue ||
        !readable_range(device, sizeof(void *)) ||
        !readable_range(queue, sizeof(void *))) {
        dr_set_error("Darktide D3D12 device/queue is unavailable");
        return false;
    }

    void **device_vtable = vtbl(device);
    void **queue_vtable = vtbl(queue);

    if (!device_vtable || !queue_vtable ||
        !readable_range(device_vtable, 39u * sizeof(void *)) ||
        !readable_range(queue_vtable, 19u * sizeof(void *)) ||
        !dr_executable_address(device_vtable[9]) ||
        !dr_executable_address(device_vtable[12]) ||
        !dr_executable_address(device_vtable[27]) ||
        !dr_executable_address(device_vtable[36]) ||
        !dr_executable_address(device_vtable[38]) ||
        !dr_executable_address(queue_vtable[10]) ||
        !dr_executable_address(queue_vtable[14])) {
        dr_set_error("Darktide D3D12 COM interfaces failed validation");
        return false;
    }

    g_dr_render_device = render_device;
    g_dr_device = device;
    g_dr_queue = queue;
    return true;
}

static HRESULT dr_swap_get_buffer(void *swapchain, u32 index, void **out) {
    if (out) {
        *out = nullptr;
    }

    if (!swapchain || !readable_range(swapchain, sizeof(void *))) {
        return DR_DXGI_ERROR_INVALID_CALL;
    }

    void **swap_vtable = vtbl(swapchain);

    if (!swap_vtable ||
        !readable_range(swap_vtable, 10u * sizeof(void *)) ||
        !dr_executable_address(swap_vtable[9])) {
        return DR_DXGI_ERROR_INVALID_CALL;
    }

    using Fn = HRESULT (STDCALL *)(void *, u32, const GUID *, void **);
    return reinterpret_cast<Fn>(swap_vtable[9])(swapchain, index, &IID_ID3D12Resource_, out);
}

static u8 *dr_find_swap_record(void *swapchain) {
    if (!swapchain) {
        return nullptr;
    }

    if (!g_dr_render_device && !dr_read_engine_objects()) {
        return nullptr;
    }

    auto *render_device = static_cast<u8 *>(g_dr_render_device);
    const u32 count = *reinterpret_cast<u32 *>(render_device + DR_RENDER_DEVICE_SWAP_COUNT);
    auto *records = *reinterpret_cast<u8 **>(render_device + DR_RENDER_DEVICE_SWAP_RECORDS);

    if (!count || count > 16u ||
        !records ||
        !readable_range(records, static_cast<usize>(count) * DR_SWAP_RECORD_SIZE)) {
        return nullptr;
    }

    for (u32 i = 0; i < count; ++i) {
        u8 *record = records + static_cast<usize>(i) * DR_SWAP_RECORD_SIZE;

        if (record[DR_SWAP_RECORD_ACTIVE] == 0u) {
            continue;
        }

        if (*reinterpret_cast<void **>(record + DR_SWAP_RECORD_SWAPCHAIN) == swapchain) {
            return record;
        }
    }

    return nullptr;
}

static void dr_release_created_resources() {
    for (u32 i = 0; i < DR_FRAME_SLOTS; ++i) {
        if (g_dr_frames[i].upload) {
            com_release(g_dr_frames[i].upload);
        }

        if (g_dr_frames[i].list) {
            com_release(g_dr_frames[i].list);
        }

        if (g_dr_frames[i].allocator) {
            com_release(g_dr_frames[i].allocator);
        }

        g_dr_frames[i] = {};
    }

    if (g_dr_fence) {
        com_release(g_dr_fence);
        g_dr_fence = nullptr;
    }
}

static bool dr_init_resources() {
    if (atomic_load_u32(&g_dr_resources_ready)) {
        return true;
    }

    if (!g_dr_device || !g_dr_queue) {
        dr_set_error("renderer device/queue not initialized");
        return false;
    }

    for (u32 i = 0; i < DR_FRAME_SLOTS; ++i) {
        if (device_create_allocator(g_dr_device, &g_dr_frames[i].allocator) < 0 || !g_dr_frames[i].allocator) {
            dr_set_error("browser command allocator creation failed");
            dr_release_created_resources();
            return false;
        }

        if (device_create_list(g_dr_device, g_dr_frames[i].allocator, &g_dr_frames[i].list) < 0 || !g_dr_frames[i].list) {
            dr_set_error("browser command list creation failed");
            dr_release_created_resources();
            return false;
        }

        if (list_close(g_dr_frames[i].list) < 0) {
            dr_set_error("browser initial command list close failed");
            dr_release_created_resources();
            return false;
        }
    }

    if (device_create_fence(g_dr_device, 0u, &g_dr_fence) < 0 || !g_dr_fence) {
        dr_set_error("browser fence creation failed");
        dr_release_created_resources();
        return false;
    }

    atomic_store_u32(&g_dr_resources_ready, 1u);
    return true;
}

static bool dr_ensure_upload(DrFrameSlot &slot, u64 bytes) {
    if (slot.upload && slot.mapped && slot.capacity >= bytes) {
        return true;
    }

    if (slot.upload) {
        com_release(slot.upload);
        slot.upload = nullptr;
        slot.mapped = nullptr;
        slot.capacity = 0u;
        slot.source_sequence = 0u;
        slot.source_slot = 0u;
        slot.source_generation = 0u;
        slot.source_x = 0u;
        slot.source_y = 0u;
        slot.source_width = 0u;
        slot.source_height = 0u;
        slot.source_format = 0u;
    }

    if (device_create_upload(g_dr_device, bytes, &slot.upload) < 0 || !slot.upload) {
        dr_set_error("browser upload buffer creation failed");
        return false;
    }

    void *mapped = nullptr;

    if (resource_map(slot.upload, &mapped) < 0 || !mapped) {
        com_release(slot.upload);
        slot.upload = nullptr;
        dr_set_error("browser upload buffer map failed");
        return false;
    }

    slot.mapped = static_cast<u8 *>(mapped);
    slot.capacity = bytes;
    return true;
}

static bool dr_format_supported(u32 format) {
    return format == DR_DXGI_FORMAT_R8G8B8A8_TYPELESS ||
           format == DXGI_FORMAT_R8G8B8A8_UNORM ||
           format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB ||
           format == DR_DXGI_FORMAT_B8G8R8A8_TYPELESS ||
           format == DXGI_FORMAT_B8G8R8A8_UNORM ||
           format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB ||
           format == DR_DXGI_FORMAT_B8G8R8X8_TYPELESS ||
           format == DR_DXGI_FORMAT_B8G8R8X8_UNORM ||
           format == DR_DXGI_FORMAT_B8G8R8X8_UNORM_SRGB ||
           format == DR_DXGI_FORMAT_R10G10B10A2_TYPELESS ||
           format == DR_DXGI_FORMAT_R10G10B10A2_UNORM;
}

static u32 dr_upload_format(u32 format) {
    if (format == DR_DXGI_FORMAT_R8G8B8A8_TYPELESS) {
        return DXGI_FORMAT_R8G8B8A8_UNORM;
    }

    if (format == DR_DXGI_FORMAT_B8G8R8A8_TYPELESS) {
        return DXGI_FORMAT_B8G8R8A8_UNORM;
    }

    if (format == DR_DXGI_FORMAT_B8G8R8X8_TYPELESS) {
        return DR_DXGI_FORMAT_B8G8R8X8_UNORM;
    }

    if (format == DR_DXGI_FORMAT_R10G10B10A2_TYPELESS) {
        return DR_DXGI_FORMAT_R10G10B10A2_UNORM;
    }

    return format;
}

static u32 dr_expand_8_to_10(u32 value) {
    return (value * 1023u + 127u) / 255u;
}

static void dr_convert_row(u8 *dst, const u8 *src, u32 pixels, u32 format) {
    const bool bgra = format == DR_DXGI_FORMAT_B8G8R8A8_TYPELESS ||
                      format == DXGI_FORMAT_B8G8R8A8_UNORM ||
                      format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB ||
                      format == DR_DXGI_FORMAT_B8G8R8X8_TYPELESS ||
                      format == DR_DXGI_FORMAT_B8G8R8X8_UNORM ||
                      format == DR_DXGI_FORMAT_B8G8R8X8_UNORM_SRGB;

    if (bgra) {
        memcpy(dst, src, static_cast<usize>(pixels) * 4u);
        return;
    }

    if (format == DR_DXGI_FORMAT_R10G10B10A2_TYPELESS ||
        format == DR_DXGI_FORMAT_R10G10B10A2_UNORM) {
        auto *out = reinterpret_cast<u32 *>(dst);

        for (u32 x = 0; x < pixels; ++x) {
            const u8 *in = src + static_cast<usize>(x) * 4u;
            const u32 r = dr_expand_8_to_10(in[2]);
            const u32 g = dr_expand_8_to_10(in[1]);
            const u32 b = dr_expand_8_to_10(in[0]);
            const u32 a = (static_cast<u32>(in[3]) * 3u + 127u) / 255u;
            out[x] = r | (g << 10u) | (b << 20u) | (a << 30u);
        }

        return;
    }

    for (u32 x = 0; x < pixels; ++x) {
        const u8 *in = src + static_cast<usize>(x) * 4u;
        u8 *out = dst + static_cast<usize>(x) * 4u;
        out[0] = in[2];
        out[1] = in[1];
        out[2] = in[0];
        out[3] = in[3];
    }
}

static u64 dr_reference_hash(const char *text) {
    static constexpr u64 m = 0xc6a4a7935bd1e995ull;
    static constexpr u32 r = 47u;
    const usize length = slen(text);
    u64 hash = static_cast<u64>(length) * m;
    const u8 *data = reinterpret_cast<const u8 *>(text);
    usize offset = 0u;

    while (offset + 8u <= length) {
        u64 value = 0u;

        for (u32 i = 0; i < 8u; ++i) {
            value |= static_cast<u64>(data[offset + i]) << (i * 8u);
        }

        value *= m;
        value ^= value >> r;
        value *= m;
        hash ^= value;
        hash *= m;
        offset += 8u;
    }

    const usize tail = length - offset;

    if (tail >= 7u) hash ^= static_cast<u64>(data[offset + 6u]) << 48u;
    if (tail >= 6u) hash ^= static_cast<u64>(data[offset + 5u]) << 40u;
    if (tail >= 5u) hash ^= static_cast<u64>(data[offset + 4u]) << 32u;
    if (tail >= 4u) hash ^= static_cast<u64>(data[offset + 3u]) << 24u;
    if (tail >= 3u) hash ^= static_cast<u64>(data[offset + 2u]) << 16u;
    if (tail >= 2u) hash ^= static_cast<u64>(data[offset + 1u]) << 8u;

    if (tail >= 1u) {
        hash ^= static_cast<u64>(data[offset]);
        hash *= m;
    }

    hash ^= hash >> r;
    hash *= m;
    hash ^= hash >> r;
    return hash;
}

static bool dr_browser_visible(BrowserState &browser) {
    return atomic_load_u32(&browser.used) &&
           !atomic_load_u32(&browser.destroy_pending) &&
           atomic_load_u32(&browser.desired_visible) &&
           atomic_load_u32(&browser.ready);
}

static BrowserState *dr_visible_browser() {
    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        BrowserState &browser = g_browsers[i];

        if (dr_browser_visible(browser) && !atomic_load_u32(&browser.render_target_enabled)) {
            return &browser;
        }
    }

    return nullptr;
}

static bool dr_has_visible_browser() {
    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        if (dr_browser_visible(g_browsers[i])) {
            return true;
        }
    }

    return false;
}

struct DrNamedTarget {
    void *resource;
    u32 state;
    u32 subresource;
};

static bool dr_resource_valid(void *resource) {
    if (!resource || !readable_range(resource, sizeof(void *))) {
        return false;
    }

    void **resource_vtable = vtbl(resource);
    return resource_vtable &&
           readable_range(resource_vtable, 11u * sizeof(void *)) &&
           dr_executable_address(resource_vtable[10]);
}

static bool dr_target_from_object(
    const BrowserState &browser,
    u8 *object,
    DrNamedTarget &target,
    bool require_object_name = true) {
    if (!object || !readable_range(object, DR_RESOURCE_OBJECT_SIZE)) {
        return false;
    }

    if (require_object_name &&
        *reinterpret_cast<u64 *>(object + DR_RESOURCE_OBJECT_NAME_HASH) != browser.render_target_hash) {
        return false;
    }

    u8 *state = *reinterpret_cast<u8 **>(object + DR_RESOURCE_OBJECT_STATE);

    if (!state || !readable_range(state, 0x28u)) {
        return false;
    }

    void *resource = *reinterpret_cast<void **>(state + DR_STATE_RESOURCE);

    if (!dr_resource_valid(resource)) {
        return false;
    }

    const D3D12_RESOURCE_DESC desc = resource_desc(resource);
    const u64 required_width = static_cast<u64>(browser.render_target_x) +
                               static_cast<u64>(browser.render_target_width);
    const u64 required_height = static_cast<u64>(browser.render_target_y) +
                                static_cast<u64>(browser.render_target_height);

    if (desc.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D ||
        desc.Width < required_width ||
        static_cast<u64>(desc.Height) < required_height ||
        desc.SampleDesc.Count != 1u ||
        !dr_format_supported(desc.Format)) {
        return false;
    }

    u32 resource_state = *reinterpret_cast<u32 *>(state + DR_STATE_GLOBAL);
    u32 subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    const u32 subresource_count = *reinterpret_cast<u32 *>(state + DR_STATE_SUBRESOURCE_COUNT);

    if (subresource_count) {
        auto *subresource_states = *reinterpret_cast<u32 **>(state + DR_STATE_SUBRESOURCES);

        if (!subresource_states ||
            !readable_range(subresource_states, static_cast<usize>(subresource_count) * sizeof(u32))) {
            return false;
        }

        resource_state = subresource_states[0];
        subresource = 0u;
    }

    target.resource = resource;
    target.state = resource_state;
    target.subresource = subresource;
    return true;
}

static bool dr_context_lut(
    u8 *context,
    u32 &lut_count,
    u8 *&lut_entries,
    u8 *&objects) {
    lut_count = 0u;
    lut_entries = nullptr;
    objects = nullptr;

    if (!context || !readable_range(context + DR_RESOURCE_LUT, 0xd0u)) {
        return false;
    }

    lut_count = *reinterpret_cast<u32 *>(context + DR_RESOURCE_LUT_COUNT);
    lut_entries = *reinterpret_cast<u8 **>(context + DR_RESOURCE_LUT_ENTRIES);
    objects = *reinterpret_cast<u8 **>(context + DR_RESOURCE_OBJECTS);

    return lut_count && lut_count <= 0x400000u && lut_entries && objects &&
           readable_range(lut_entries, static_cast<usize>(lut_count) * 8u);
}

static u8 *dr_object_for_handle(u8 *context, u32 handle) {
    if (handle == 0xffffffffu) {
        return nullptr;
    }

    u32 lut_count = 0u;
    u8 *lut_entries = nullptr;
    u8 *objects = nullptr;

    if (!dr_context_lut(context, lut_count, lut_entries, objects)) {
        return nullptr;
    }

    const u32 handle_index = handle & 0x3fffffu;

    if (handle_index >= lut_count) {
        return nullptr;
    }

    u8 *entry = lut_entries + static_cast<usize>(handle_index) * 8u;
    const i32 object_index = *reinterpret_cast<i32 *>(entry);
    const u32 stored_handle = *reinterpret_cast<u32 *>(entry + 4u);

    if (object_index < 0 || stored_handle != handle || static_cast<u32>(object_index) > 0x3fffffu) {
        return nullptr;
    }

    u8 *object = objects + static_cast<usize>(static_cast<u32>(object_index)) * DR_RESOURCE_OBJECT_SIZE;
    return readable_range(object, DR_RESOURCE_OBJECT_SIZE) ? object : nullptr;
}

static bool dr_registry_layout(
    u8 *render_device,
    u32 &slot_count,
    u32 &live_count,
    u32 &bucket_count,
    u8 *&entries) {
    slot_count = 0u;
    live_count = 0u;
    bucket_count = 0u;
    entries = nullptr;

    if (!render_device || !readable_range(render_device + DR_RENDER_TARGET_REGISTRY, 0x30u)) {
        return false;
    }

    u8 *registry = render_device + DR_RENDER_TARGET_REGISTRY;
    slot_count = *reinterpret_cast<u32 *>(registry + DR_REGISTRY_SLOT_COUNT);
    entries = *reinterpret_cast<u8 **>(registry + DR_REGISTRY_ENTRIES);
    live_count = *reinterpret_cast<u32 *>(registry + DR_REGISTRY_LIVE_COUNT);
    bucket_count = *reinterpret_cast<u32 *>(registry + DR_REGISTRY_BUCKET_COUNT);

    if (!slot_count || slot_count > 0x100000u || !entries || !bucket_count || bucket_count > slot_count) {
        return false;
    }

    return readable_range(entries, static_cast<usize>(slot_count) * DR_REGISTRY_ENTRY_SIZE);
}

static bool dr_find_registry_named_target_at(
    BrowserState &browser,
    u8 *context,
    u8 *render_device,
    DrNamedTarget &target) {
    u32 slot_count = 0u;
    u32 live_count = 0u;
    u32 bucket_count = 0u;
    u8 *entries = nullptr;

    if (!dr_registry_layout(render_device, slot_count, live_count, bucket_count, entries)) {
        return false;
    }

    for (u32 i = 0; i < slot_count; ++i) {
        u8 *entry = entries + static_cast<usize>(i) * DR_REGISTRY_ENTRY_SIZE;
        const u32 next = *reinterpret_cast<u32 *>(entry + DR_REGISTRY_ENTRY_NEXT);

        if (next == DR_REGISTRY_FREE_NEXT) {
            continue;
        }

        u8 *descriptor = *reinterpret_cast<u8 **>(entry + DR_REGISTRY_ENTRY_VALUE);

        if (!descriptor || !readable_range(descriptor, 0x68u)) {
            continue;
        }

        const u32 resource_type = *reinterpret_cast<u32 *>(descriptor + DR_DESCRIPTOR_TYPE) & 0xffffu;

        if (resource_type != 2u && resource_type != 3u) {
            continue;
        }

        const u64 name_hash = *reinterpret_cast<u64 *>(descriptor + DR_DESCRIPTOR_NAME_HASH);

        if (name_hash != browser.render_target_hash) {
            continue;
        }

        const u32 handle = *reinterpret_cast<u32 *>(descriptor + DR_DESCRIPTOR_HANDLE);
        const u32 key = *reinterpret_cast<u32 *>(entry + DR_REGISTRY_ENTRY_KEY);
        u8 *object = dr_object_for_handle(context, handle);

        if (key != handle || !object) {
            continue;
        }

        if (dr_target_from_object(browser, object, target, false)) {
            browser.render_target_handle = handle;
            return true;
        }
    }

    return false;
}

static bool dr_find_registry_named_target(BrowserState &browser, u8 *context, DrNamedTarget &target) {
    if (!context || !readable_range(context + DR_RESOURCE_CONTEXT_OWNER, sizeof(void *))) {
        return false;
    }

    u8 *owner = *reinterpret_cast<u8 **>(context + DR_RESOURCE_CONTEXT_OWNER);

    if (owner && dr_find_registry_named_target_at(browser, context, owner, target)) {
        return true;
    }

    u8 *main_render_device = static_cast<u8 *>(g_dr_render_device);

    return main_render_device && main_render_device != owner &&
           dr_find_registry_named_target_at(browser, context, main_render_device, target);
}

static bool dr_find_primary_named_target(BrowserState &browser, u8 *context, DrNamedTarget &target) {
    u32 lut_count = 0u;
    u8 *lut_entries = nullptr;
    u8 *objects = nullptr;

    if (!dr_context_lut(context, lut_count, lut_entries, objects)) {
        return false;
    }

    if (browser.render_target_handle != 0xffffffffu) {
        u8 *object = dr_object_for_handle(context, browser.render_target_handle);

        if (object && dr_target_from_object(browser, object, target, false)) {
            return true;
        }

        browser.render_target_handle = 0xffffffffu;
    }

    // fallback for alternate resource layout
    for (u32 handle_index = 0; handle_index < lut_count; ++handle_index) {
        u8 *entry = lut_entries + static_cast<usize>(handle_index) * 8u;
        const i32 object_index = *reinterpret_cast<i32 *>(entry);
        const u32 handle = *reinterpret_cast<u32 *>(entry + 4u);

        if (object_index < 0 || (handle & 0x3fffffu) != handle_index) {
            continue;
        }

        const u32 resource_type = (handle >> 26u) & 0x1fu;

        if (resource_type != 2u && resource_type != 3u) {
            continue;
        }

        u8 *object = dr_object_for_handle(context, handle);

        if (!object || *reinterpret_cast<u64 *>(object + DR_RESOURCE_OBJECT_NAME_HASH) != browser.render_target_hash) {
            continue;
        }

        if (dr_target_from_object(browser, object, target, false)) {
            browser.render_target_handle = handle;
            return true;
        }
    }

    return false;
}

static bool dr_find_cached_named_target(const BrowserState &browser, u8 *context, DrNamedTarget &target) {
    if (!context || !readable_range(context + DR_RT_CACHE_COUNT, 16u)) {
        return false;
    }

    const u32 count = *reinterpret_cast<u32 *>(context + DR_RT_CACHE_COUNT);
    u8 *entries = *reinterpret_cast<u8 **>(context + DR_RT_CACHE_ENTRIES);

    if (!count || count > 4096u || !entries ||
        !readable_range(entries, static_cast<usize>(count) * DR_RT_CACHE_ENTRY_SIZE)) {
        return false;
    }

    for (u32 i = 0; i < count; ++i) {
        u8 *entry = entries + static_cast<usize>(i) * DR_RT_CACHE_ENTRY_SIZE;

        if (*reinterpret_cast<u64 *>(entry + DR_RT_CACHE_NAME_HASH) != browser.render_target_hash) {
            continue;
        }

        u8 *object = *reinterpret_cast<u8 **>(entry + DR_RT_CACHE_TEXTURE);

        if (dr_target_from_object(browser, object, target, false)) {
            return true;
        }
    }

    return false;
}

static bool dr_find_named_target(BrowserState &browser, DrNamedTarget &target) {
    target = {};

    if (!browser.render_target_hash || (!g_dr_render_device && !dr_read_engine_objects())) {
        return false;
    }

    auto *render_device = static_cast<u8 *>(g_dr_render_device);
    auto *context_slot = reinterpret_cast<u8 **>(render_device + DR_RENDER_DEVICE_RESOURCE_CONTEXT);

    if (!readable_range(context_slot, sizeof(void *))) {
        return false;
    }

    u8 *context = *context_slot;

    if (!context) {
        return false;
    }

    // resolve named render target through the render device registry
    if (dr_find_registry_named_target(browser, context, target)) {
        return true;
    }

    // fallback resource layouts
    if (dr_find_primary_named_target(browser, context, target)) {
        return true;
    }

    return dr_find_cached_named_target(browser, context, target);
}

static bool dr_copy_rect(
    BrowserState &browser,
    const AcquiredFrame &frame,
    u32 back_width,
    u32 back_height,
    u32 &src_x,
    u32 &src_y,
    u32 &dst_x,
    u32 &dst_y,
    u32 &copy_width,
    u32 &copy_height) {
    i64 target_x = browser.x >= 0
        ? static_cast<i64>(browser.x)
        : (static_cast<i64>(back_width) - static_cast<i64>(frame.width)) / 2;
    i64 target_y = browser.y >= 0
        ? static_cast<i64>(browser.y)
        : (static_cast<i64>(back_height) - static_cast<i64>(frame.height)) / 2;

    src_x = target_x < 0 ? static_cast<u32>(-target_x) : 0u;
    src_y = target_y < 0 ? static_cast<u32>(-target_y) : 0u;
    dst_x = target_x > 0 ? static_cast<u32>(target_x) : 0u;
    dst_y = target_y > 0 ? static_cast<u32>(target_y) : 0u;

    if (src_x >= frame.width || src_y >= frame.height || dst_x >= back_width || dst_y >= back_height) {
        return false;
    }

    copy_width = frame.width - src_x;
    copy_height = frame.height - src_y;

    const u32 remaining_width = back_width - dst_x;
    const u32 remaining_height = back_height - dst_y;

    if (copy_width > remaining_width) {
        copy_width = remaining_width;
    }

    if (copy_height > remaining_height) {
        copy_height = remaining_height;
    }

    return copy_width != 0u && copy_height != 0u;
}

static bool dr_record_copy(void *swapchain) {
    BrowserState *browser = dr_visible_browser();

    if (!browser) {
        return false;
    }

    u8 *record = dr_find_swap_record(swapchain);

    if (!record) {
        dr_set_error("Darktide Present swapchain record not found");
        return false;
    }

    const u32 back_index = *reinterpret_cast<u32 *>(record + DR_SWAP_RECORD_CURRENT_INDEX);
    const u32 back_count = *reinterpret_cast<u32 *>(record + DR_SWAP_RECORD_BUFFER_COUNT);

    if (!back_count || back_count > 3u || back_index >= back_count) {
        dr_set_error("Darktide backbuffer index is invalid");
        return false;
    }

    const u64 completed = g_dr_fence ? fence_completed(g_dr_fence) : 0u;
    DrFrameSlot *slot = nullptr;

    for (u32 i = 0; i < DR_FRAME_SLOTS; ++i) {
        if (!g_dr_frames[i].fence_value || completed >= g_dr_frames[i].fence_value) {
            slot = &g_dr_frames[i];
            break;
        }
    }

    if (!slot) {
        return false;
    }

    AcquiredFrame frame{};

    if (!acquire_frame(*browser, frame)) {
        return false;
    }

    if (!frame.pixels || !frame.width || !frame.height || frame.stride < frame.width * 4u) {
        release_frame(*browser, frame);
        dr_set_error("browser frame metadata is invalid");
        return false;
    }

    void *backbuffer = nullptr;

    if (dr_swap_get_buffer(swapchain, back_index, &backbuffer) < 0 || !backbuffer) {
        release_frame(*browser, frame);
        dr_set_error("IDXGISwapChain::GetBuffer failed");
        return false;
    }

    const D3D12_RESOURCE_DESC desc = resource_desc(backbuffer);

    if (desc.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D ||
        !desc.Width ||
        !desc.Height ||
        desc.Width > 0xffffffffull ||
        desc.SampleDesc.Count != 1u ||
        !dr_format_supported(desc.Format)) {
        com_release(backbuffer);
        release_frame(*browser, frame);
        dr_set_error("unsupported Darktide swapchain format");
        return false;
    }

    u32 src_x = 0u;
    u32 src_y = 0u;
    u32 dst_x = 0u;
    u32 dst_y = 0u;
    u32 copy_width = 0u;
    u32 copy_height = 0u;

    if (!dr_copy_rect(
            *browser,
            frame,
            static_cast<u32>(desc.Width),
            desc.Height,
            src_x,
            src_y,
            dst_x,
            dst_y,
            copy_width,
            copy_height)) {
        com_release(backbuffer);
        release_frame(*browser, frame);
        return false;
    }

    D3D12_RESOURCE_DESC copy_desc = desc;
    copy_desc.Width = copy_width;
    copy_desc.Height = copy_height;
    copy_desc.DepthOrArraySize = 1u;
    copy_desc.MipLevels = 1u;
    // use a typed member for typeless upload footprints
    copy_desc.Format = dr_upload_format(desc.Format);

    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    u32 rows = 0u;
    u64 row_bytes = 0u;
    u64 total = 0u;
    device_footprint(g_dr_device, copy_desc, &footprint, &rows, &row_bytes, &total);

    const u64 expected_row = static_cast<u64>(copy_width) * 4u;

    if (!total || rows != copy_height || row_bytes < expected_row || !dr_ensure_upload(*slot, total)) {
        com_release(backbuffer);
        release_frame(*browser, frame);

        if (!total) {
            dr_set_error("invalid browser copy footprint");
        }

        return false;
    }

    const bool upload_matches = slot->source_sequence == frame.sequence &&
                                slot->source_slot == browser->slot &&
                                slot->source_generation == browser->generation &&
                                slot->source_x == src_x &&
                                slot->source_y == src_y &&
                                slot->source_width == copy_width &&
                                slot->source_height == copy_height &&
                                slot->source_format == desc.Format;

    if (!upload_matches) {
        for (u32 y = 0; y < copy_height; ++y) {
            u8 *dst = slot->mapped + footprint.Offset + static_cast<u64>(y) * footprint.Footprint.RowPitch;
            const u8 *src = frame.pixels +
                            static_cast<u64>(src_y + y) * frame.stride +
                            static_cast<u64>(src_x) * 4u;
            dr_convert_row(dst, src, copy_width, desc.Format);
        }

        slot->source_sequence = frame.sequence;
        slot->source_slot = browser->slot;
        slot->source_generation = browser->generation;
        slot->source_x = src_x;
        slot->source_y = src_y;
        slot->source_width = copy_width;
        slot->source_height = copy_height;
        slot->source_format = desc.Format;
    }

    release_frame(*browser, frame);

    if (allocator_reset(slot->allocator) < 0 || list_reset(slot->list, slot->allocator) < 0) {
        com_release(backbuffer);
        dr_set_error("browser command reset failed");
        return false;
    }

    D3D12_RESOURCE_BARRIER to_copy{};
    to_copy.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    to_copy.Transition = {
        backbuffer,
        D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
        DR_D3D12_RESOURCE_STATE_PRESENT,
        D3D12_RESOURCE_STATE_COPY_DEST,
    };
    list_barrier(slot->list, &to_copy);

    D3D12_TEXTURE_COPY_LOCATION src_location{};
    src_location.pResource = slot->upload;
    src_location.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src_location.PlacedFootprint = footprint;

    D3D12_TEXTURE_COPY_LOCATION dst_location{};
    dst_location.pResource = backbuffer;
    dst_location.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    dst_location.SubresourceIndex = 0u;

    D3D12_BOX box{0u, 0u, 0u, copy_width, copy_height, 1u};
    list_copy_region(slot->list, &dst_location, dst_x, dst_y, &src_location, &box);

    D3D12_RESOURCE_BARRIER to_present{};
    to_present.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    to_present.Transition = {
        backbuffer,
        D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
        D3D12_RESOURCE_STATE_COPY_DEST,
        DR_D3D12_RESOURCE_STATE_PRESENT,
    };
    list_barrier(slot->list, &to_present);

    if (list_close(slot->list) < 0) {
        com_release(backbuffer);
        dr_set_error("browser command list close failed");
        return false;
    }

    queue_execute(g_dr_queue, slot->list);
    const u64 fence_value = g_dr_next_fence++;

    if (queue_signal(g_dr_queue, g_dr_fence, fence_value) < 0) {
        com_release(backbuffer);
        dr_set_error("browser queue signal failed");
        return false;
    }

    slot->fence_value = fence_value;
    com_release(backbuffer);
    dr_set_error("");
    return true;
}

static bool dr_record_target_copy(BrowserState &browser) {
    DrNamedTarget target{};

    if (!dr_find_named_target(browser, target)) {
        dr_set_error("browser render target was not found");
        return false;
    }

    const D3D12_RESOURCE_DESC desc = resource_desc(target.resource);

    if (desc.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D ||
        !desc.Width ||
        !desc.Height ||
        desc.Width > 0xffffffffull ||
        desc.SampleDesc.Count != 1u ||
        !dr_format_supported(desc.Format)) {
        dr_set_error("unsupported browser render target format");
        return false;
    }

    AcquiredFrame frame{};

    if (!acquire_frame(browser, frame)) {
        return false;
    }

    if (!frame.pixels || !frame.width || !frame.height || frame.stride < frame.width * 4u) {
        release_frame(browser, frame);
        dr_set_error("browser frame metadata is invalid");
        return false;
    }

    const i32 target_x = browser.render_target_x;
    const i32 target_y = browser.render_target_y;
    const i32 target_width = browser.render_target_width;
    const i32 target_height = browser.render_target_height;

    if (target_x < 0 || target_y < 0 || target_width <= 0 || target_height <= 0 ||
        static_cast<u64>(target_x) >= desc.Width || static_cast<u32>(target_y) >= desc.Height) {
        release_frame(browser, frame);
        dr_set_error("browser render target rectangle is invalid");
        return false;
    }

    u32 copy_width = frame.width;
    u32 copy_height = frame.height;
    const u32 max_width = static_cast<u32>(target_width);
    const u32 max_height = static_cast<u32>(target_height);
    const u32 remaining_width = static_cast<u32>(desc.Width) - static_cast<u32>(target_x);
    const u32 remaining_height = desc.Height - static_cast<u32>(target_y);

    if (copy_width > max_width) copy_width = max_width;
    if (copy_height > max_height) copy_height = max_height;
    if (copy_width > remaining_width) copy_width = remaining_width;
    if (copy_height > remaining_height) copy_height = remaining_height;

    if (!copy_width || !copy_height) {
        release_frame(browser, frame);
        return false;
    }

    const u64 completed = g_dr_fence ? fence_completed(g_dr_fence) : 0u;
    DrFrameSlot *slot = nullptr;

    for (u32 i = 0; i < DR_FRAME_SLOTS; ++i) {
        if (!g_dr_frames[i].fence_value || completed >= g_dr_frames[i].fence_value) {
            slot = &g_dr_frames[i];
            break;
        }
    }

    if (!slot) {
        release_frame(browser, frame);
        return false;
    }

    D3D12_RESOURCE_DESC copy_desc = desc;
    copy_desc.Width = copy_width;
    copy_desc.Height = copy_height;
    copy_desc.DepthOrArraySize = 1u;
    copy_desc.MipLevels = 1u;
    // use a typed member for typeless upload footprints
    copy_desc.Format = dr_upload_format(desc.Format);

    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    u32 rows = 0u;
    u64 row_bytes = 0u;
    u64 total = 0u;
    device_footprint(g_dr_device, copy_desc, &footprint, &rows, &row_bytes, &total);

    const u64 expected_row = static_cast<u64>(copy_width) * 4u;

    if (!total || rows != copy_height || row_bytes < expected_row || !dr_ensure_upload(*slot, total)) {
        release_frame(browser, frame);

        if (!total) {
            dr_set_error("invalid browser render-target footprint");
        }

        return false;
    }

    const bool upload_matches = slot->source_sequence == frame.sequence &&
                                slot->source_slot == browser.slot &&
                                slot->source_generation == browser.generation &&
                                slot->source_x == 0u &&
                                slot->source_y == 0u &&
                                slot->source_width == copy_width &&
                                slot->source_height == copy_height &&
                                slot->source_format == desc.Format;

    if (!upload_matches) {
        for (u32 y = 0; y < copy_height; ++y) {
            u8 *dst = slot->mapped + footprint.Offset + static_cast<u64>(y) * footprint.Footprint.RowPitch;
            const u8 *src = frame.pixels + static_cast<u64>(y) * frame.stride;
            dr_convert_row(dst, src, copy_width, desc.Format);
        }

        slot->source_sequence = frame.sequence;
        slot->source_slot = browser.slot;
        slot->source_generation = browser.generation;
        slot->source_x = 0u;
        slot->source_y = 0u;
        slot->source_width = copy_width;
        slot->source_height = copy_height;
        slot->source_format = desc.Format;
    }

    release_frame(browser, frame);

    if (allocator_reset(slot->allocator) < 0 || list_reset(slot->list, slot->allocator) < 0) {
        dr_set_error("browser target command reset failed");
        return false;
    }

    if (target.state != D3D12_RESOURCE_STATE_COPY_DEST) {
        D3D12_RESOURCE_BARRIER to_copy{};
        to_copy.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        to_copy.Transition = {
            target.resource,
            target.subresource,
            target.state,
            D3D12_RESOURCE_STATE_COPY_DEST,
        };
        list_barrier(slot->list, &to_copy);
    }

    D3D12_TEXTURE_COPY_LOCATION src_location{};
    src_location.pResource = slot->upload;
    src_location.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src_location.PlacedFootprint = footprint;

    D3D12_TEXTURE_COPY_LOCATION dst_location{};
    dst_location.pResource = target.resource;
    dst_location.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    dst_location.SubresourceIndex = 0u;

    D3D12_BOX box{0u, 0u, 0u, copy_width, copy_height, 1u};
    list_copy_region(
        slot->list,
        &dst_location,
        static_cast<u32>(target_x),
        static_cast<u32>(target_y),
        &src_location,
        &box);

    if (target.state != D3D12_RESOURCE_STATE_COPY_DEST) {
        D3D12_RESOURCE_BARRIER from_copy{};
        from_copy.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        from_copy.Transition = {
            target.resource,
            target.subresource,
            D3D12_RESOURCE_STATE_COPY_DEST,
            target.state,
        };
        list_barrier(slot->list, &from_copy);
    }

    if (list_close(slot->list) < 0) {
        dr_set_error("browser target command list close failed");
        return false;
    }

    queue_execute(g_dr_queue, slot->list);
    const u64 fence_value = g_dr_next_fence++;

    if (queue_signal(g_dr_queue, g_dr_fence, fence_value) < 0) {
        dr_set_error("browser target queue signal failed");
        return false;
    }

    slot->fence_value = fence_value;
    browser.render_target_fence = fence_value;
    atomic_store_u32(&browser.render_target_presented, 1u);
    dr_set_error("");
    return true;
}

static void dr_record_target_copies() {
    lock_u32(&g_dr_target_lock);

    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        BrowserState &browser = g_browsers[i];

        if (dr_browser_visible(browser) && atomic_load_u32(&browser.render_target_enabled)) {
            dr_record_target_copy(browser);
        }
    }

    unlock_u32(&g_dr_target_lock);
}

static void dr_clear_render_target(BrowserState &browser) {
    u64 fence_value = 0u;

    lock_u32(&g_dr_target_lock);
    atomic_store_u32(&browser.render_target_enabled, 0u);
    atomic_store_u32(&browser.render_target_presented, 0u);
    fence_value = browser.render_target_fence;
    browser.render_target_fence = 0u;
    browser.render_target_handle = 0xffffffffu;
    browser.render_target_hash = 0u;
    browser.render_target_x = 0;
    browser.render_target_y = 0;
    browser.render_target_width = 0;
    browser.render_target_height = 0;
    unlock_u32(&g_dr_target_lock);

    if (fence_value && g_dr_fence) {
        while (fence_completed(g_dr_fence) < fence_value) {
        }
    }
}

static HRESULT STDCALL dr_present_call_hook(void *swapchain, u32 sync_interval, u32 flags) {
    if ((flags & DR_DXGI_PRESENT_TEST) == 0u &&
        atomic_load_u32(&g_dr_requested) &&
        atomic_load_u32(&g_dr_resources_ready)) {
        dr_record_target_copies();
        dr_record_copy(swapchain);
    }

    if (!swapchain || !readable_range(swapchain, sizeof(void *))) {
        dr_set_error("Present received invalid swapchain");
        return DR_DXGI_ERROR_INVALID_CALL;
    }

    void **swap_vtable = vtbl(swapchain);

    if (!swap_vtable ||
        !readable_range(swap_vtable, 9u * sizeof(void *)) ||
        !dr_executable_address(swap_vtable[8])) {
        dr_set_error("real IDXGISwapChain::Present entry is invalid");
        return DR_DXGI_ERROR_INVALID_CALL;
    }

    return reinterpret_cast<DrPresentFn>(swap_vtable[8])(swapchain, sync_interval, flags);
}

static bool dr_rel32(void *from_after_instruction, void *to, i32 *out) {
    if (!out) {
        return false;
    }

    const i64 delta = static_cast<i64>(reinterpret_cast<usize>(to)) -
                      static_cast<i64>(reinterpret_cast<usize>(from_after_instruction));

    if (delta < -2147483648ll || delta > 2147483647ll) {
        return false;
    }

    *out = static_cast<i32>(delta);
    return true;
}

static void *dr_alloc_pointer_slot_near(u8 *callsite) {
    if (!pVirtualQuery || !pVirtualAlloc || !callsite) {
        return nullptr;
    }

    const usize center = reinterpret_cast<usize>(callsite + 6u);
    const usize reach = 0x70000000ull;
    const usize low = center > reach ? center - reach : 0x10000ull;
    const usize high = center + reach;
    usize cursor = low;

    while (cursor < high) {
        MEMORY_BASIC_INFORMATION_ info{};

        if (pVirtualQuery(reinterpret_cast<void *>(cursor), &info, sizeof(info)) != sizeof(info)) {
            break;
        }

        const usize region_base = reinterpret_cast<usize>(info.BaseAddress);
        const usize region_end = region_base + info.RegionSize;

        if (info.State == MEM_FREE) {
            usize candidate = region_base < low ? low : region_base;
            candidate = (candidate + 0xffffull) & ~0xffffull;

            if (candidate + 0x1000ull <= region_end && candidate < high) {
                void *page = pVirtualAlloc(
                    reinterpret_cast<void *>(candidate),
                    0x1000u,
                    MEM_RESERVE | MEM_COMMIT,
                    PAGE_READWRITE);

                if (page) {
                    i32 ignored = 0;

                    if (dr_rel32(callsite + 6u, page, &ignored)) {
                        return page;
                    }

                    pVirtualFree(page, 0u, MEM_RELEASE);
                }
            }
        }

        if (region_end <= cursor) {
            break;
        }

        cursor = region_end;
    }

    return nullptr;
}

static bool dr_install_callsite_hook() {
    if (atomic_load_u32(&g_dr_hooked)) {
        return true;
    }

    if (!dr_discover_renderer()) {
        return false;
    }

    if (!pVirtualProtect || !pFlushInstructionCache || !pGetCurrentProcess || !pVirtualAlloc) {
        dr_set_error("Win32 code-patch APIs unavailable");
        return false;
    }

    u8 *callsite = g_dr_present_callsite;
    u8 *aligned = callsite - 1u;

    if ((reinterpret_cast<usize>(aligned) & 7ull) != 0u) {
        dr_set_error("Present patch site is not atomically aligned");
        return false;
    }

    static const u8 expected[8] = {
        0xc2, 0x48, 0x8b, 0x01, 0xff, 0x50, 0x40, 0x4c,
    };

    if (!dr_bytes_equal(aligned, expected, sizeof(expected))) {
        dr_set_error("Darktide Present call site was already modified");
        return false;
    }

    if (!g_dr_hook_pointer_page) {
        g_dr_hook_pointer_page = static_cast<void **>(dr_alloc_pointer_slot_near(callsite));

        if (!g_dr_hook_pointer_page) {
            dr_set_error("could not allocate near Present hook pointer");
            return false;
        }
    }

    g_dr_hook_pointer_page[0] = reinterpret_cast<void *>(&dr_present_call_hook);

    i32 displacement = 0;

    if (!dr_rel32(callsite + 6u, g_dr_hook_pointer_page, &displacement)) {
        dr_set_error("Present hook pointer is outside rel32 range");
        return false;
    }

    u8 patched[8] = {0xc2, 0xff, 0x15, 0, 0, 0, 0, 0x4c};
    memcpy(patched + 3u, &displacement, sizeof(displacement));

    u64 new_word = 0u;
    u64 old_word = 0u;
    memcpy(&new_word, patched, sizeof(new_word));
    memcpy(&old_word, expected, sizeof(old_word));

    DWORD old_protect = 0u;

    if (!pVirtualProtect(aligned, 8u, PAGE_EXECUTE_READWRITE, &old_protect)) {
        dr_set_error("VirtualProtect failed for Present call site");
        return false;
    }

    const u64 seen = static_cast<u64>(_InterlockedCompareExchange64(
        reinterpret_cast<volatile long long *>(aligned),
        static_cast<long long>(new_word),
        static_cast<long long>(old_word)));
    pFlushInstructionCache(pGetCurrentProcess(), aligned, 8u);

    DWORD ignored = 0u;
    pVirtualProtect(aligned, 8u, old_protect, &ignored);

    if (seen != old_word) {
        dr_set_error("Present call site changed during patch");
        return false;
    }

    if (!dr_bytes_equal(aligned, patched, sizeof(patched))) {
        dr_set_error("Present call-site patch verification failed");
        return false;
    }

    g_dr_patch_word_address = aligned;
    g_dr_patch_original_word = old_word;
    g_dr_patch_installed_word = new_word;
    atomic_store_u32(&g_dr_hooked, 1u);
    dr_set_error("");
    return true;
}

static void dr_restore_callsite_hook() {
    if (!atomic_load_u32(&g_dr_hooked) || !g_dr_patch_word_address || !pVirtualProtect) {
        return;
    }

    DWORD old_protect = 0u;

    if (pVirtualProtect(g_dr_patch_word_address, 8u, PAGE_EXECUTE_READWRITE, &old_protect)) {
        _InterlockedCompareExchange64(
            reinterpret_cast<volatile long long *>(g_dr_patch_word_address),
            static_cast<long long>(g_dr_patch_original_word),
            static_cast<long long>(g_dr_patch_installed_word));

        if (pFlushInstructionCache && pGetCurrentProcess) {
            pFlushInstructionCache(pGetCurrentProcess(), g_dr_patch_word_address, 8u);
        }

        DWORD ignored = 0u;
        pVirtualProtect(g_dr_patch_word_address, 8u, old_protect, &ignored);
    }

    atomic_store_u32(&g_dr_hooked, 0u);
}

static void dr_refresh_request() {
    atomic_store_u32(&g_dr_requested, dr_has_visible_browser() ? 1u : 0u);
}

static bool dr_enable() {
    dr_refresh_request();

    if (!atomic_load_u32(&g_dr_requested)) {
        return true;
    }

    if (atomic_load_u32(&g_dr_hooked)) {
        return true;
    }

    if (!dr_read_engine_objects() || !dr_init_resources()) {
        return false;
    }

    return dr_install_callsite_hook();
}

static void dr_shutdown() {
    atomic_store_u32(&g_dr_requested, 0u);
    dr_restore_callsite_hook();

    bool safe_to_release = true;

    if (g_dr_fence && g_dr_queue) {
        const u64 completed = fence_completed(g_dr_fence);

        for (u32 i = 0; i < DR_FRAME_SLOTS; ++i) {
            if (g_dr_frames[i].fence_value && completed < g_dr_frames[i].fence_value) {
                safe_to_release = false;
                break;
            }
        }
    }

    if (safe_to_release) {
        dr_release_created_resources();
    }

    g_dr_fence = nullptr;
    g_dr_render_device = nullptr;
    g_dr_device = nullptr;
    g_dr_queue = nullptr;
    atomic_store_u32(&g_dr_resources_ready, 0u);
}

static bool dr_build_supported() {
    return dr_discover_renderer();
}

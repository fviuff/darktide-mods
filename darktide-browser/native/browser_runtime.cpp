#include <stddef.h>

extern "C" unsigned long long __readgsqword(unsigned long);
extern "C" long _InterlockedCompareExchange(volatile long *, long, long);
extern "C" long long _InterlockedCompareExchange64(volatile long long *, long long, long long);
extern "C" long _InterlockedExchange(volatile long *, long);

using u8 = unsigned char;
using u16 = unsigned short;
using u32 = unsigned int;
using u64 = unsigned long long;
using i32 = int;
using i64 = long long;
using usize = unsigned long long;
using HRESULT = i32;
using ULONG = u32;
using DWORD = u32;
using BOOL = i32;
using HANDLE = void *;
using HMODULE = void *;
using NTSTATUS = i32;
using WCHAR = wchar_t;

#if defined(_MSC_VER)
#define STDCALL __stdcall
#define EXPORT extern "C" __declspec(dllexport)
#else
#define STDCALL __attribute__((stdcall))
#define EXPORT extern "C" __attribute__((dllexport))
#endif

extern "C" void *memset(void *dst, int value, usize count) {
    auto *p = static_cast<u8 *>(dst);

    for (usize i = 0; i < count; ++i) {
        p[i] = static_cast<u8>(value);
    }

    return dst;
}

extern "C" void *memcpy(void *dst, const void *src, usize count) {
    auto *d = static_cast<u8 *>(dst);
    auto *s = static_cast<const u8 *>(src);

    for (usize i = 0; i < count; ++i) {
        d[i] = s[i];
    }

    return dst;
}

extern "C" int _fltused = 0;

struct GUID {
    u32 Data1;
    u16 Data2;
    u16 Data3;
    u8 Data4[8];
};

struct UNICODE_STRING {
    u16 Length;
    u16 MaximumLength;
    WCHAR *Buffer;
};

struct ANSI_STRING {
    u16 Length;
    u16 MaximumLength;
    char *Buffer;
};

struct LIST_ENTRY_ {
    LIST_ENTRY_ *Flink;
    LIST_ENTRY_ *Blink;
};

struct USTRING_ {
    u16 Length;
    u16 MaximumLength;
    WCHAR *Buffer;
};

struct MEMORY_BASIC_INFORMATION_ {
    void *BaseAddress;
    void *AllocationBase;
    DWORD AllocationProtect;
    DWORD padding0;
    usize RegionSize;
    DWORD State;
    DWORD Protect;
    DWORD Type;
    DWORD padding1;
};

static_assert(sizeof(MEMORY_BASIC_INFORMATION_) == 48u);

static constexpr DWORD PAGE_READWRITE = 0x04u;
static constexpr DWORD PAGE_NOACCESS = 0x01u;
static constexpr DWORD PAGE_GUARD = 0x100u;
static constexpr DWORD PAGE_EXECUTE = 0x10u;
static constexpr DWORD PAGE_EXECUTE_READ = 0x20u;
static constexpr DWORD PAGE_EXECUTE_READWRITE = 0x40u;
static constexpr DWORD PAGE_EXECUTE_WRITECOPY = 0x80u;
static constexpr DWORD MEM_COMMIT = 0x1000u;
static constexpr DWORD MEM_RESERVE = 0x2000u;
static constexpr DWORD MEM_FREE = 0x10000u;
static constexpr DWORD MEM_RELEASE = 0x8000u;

using LdrLoadDllFn = NTSTATUS (STDCALL *)(WCHAR *, u32 *, UNICODE_STRING *, HMODULE *);
using LdrGetProcedureAddressFn = NTSTATUS (STDCALL *)(HMODULE, ANSI_STRING *, u16, void **);
using VirtualQueryFn = usize (STDCALL *)(const void *, MEMORY_BASIC_INFORMATION_ *, usize);
using VirtualAllocFn = void *(STDCALL *)(void *, usize, DWORD, DWORD);
using VirtualFreeFn = BOOL (STDCALL *)(void *, usize, DWORD);
using VirtualProtectFn = BOOL (STDCALL *)(void *, usize, DWORD, DWORD *);
using FlushInstructionCacheFn = BOOL (STDCALL *)(HANDLE, const void *, usize);
using GetCurrentProcessFn = HANDLE (STDCALL *)();

static LdrLoadDllFn pLdrLoadDll = nullptr;
static LdrGetProcedureAddressFn pLdrGetProcedureAddress = nullptr;
static VirtualQueryFn pVirtualQuery = nullptr;
static VirtualAllocFn pVirtualAlloc = nullptr;
static VirtualFreeFn pVirtualFree = nullptr;
static VirtualProtectFn pVirtualProtect = nullptr;
static FlushInstructionCacheFn pFlushInstructionCache = nullptr;
static GetCurrentProcessFn pGetCurrentProcess = nullptr;

static usize slen(const char *s) {
    usize n = 0;

    while (s && s[n]) {
        ++n;
    }

    return n;
}

static bool streq(const char *a, const char *b) {
    if (!a || !b) {
        return false;
    }

    while (*a && *b) {
        if (*a++ != *b++) {
            return false;
        }
    }

    return *a == *b;
}

static void copy_chars(char *dst, usize cap, const char *src, usize count) {
    if (!dst || cap == 0) {
        return;
    }

    if (!src) {
        dst[0] = 0;
        return;
    }

    if (count >= cap) {
        count = cap - 1;
    }

    for (usize i = 0; i < count; ++i) {
        dst[i] = src[i];
    }

    dst[count] = 0;
}

static void copy_cstr(char *dst, usize cap, const char *src) {
    copy_chars(dst, cap, src, slen(src));
}

static WCHAR lower_w(WCHAR c) {
    return c >= L'A' && c <= L'Z' ? static_cast<WCHAR>(c + (L'a' - L'A')) : c;
}

static u16 wlen16(const WCHAR *s) {
    u16 n = 0;

    while (s && s[n]) {
        ++n;
    }

    return n;
}

static bool weq_ci_n(const WCHAR *a, const WCHAR *b, u32 n) {
    for (u32 i = 0; i < n; ++i) {
        if (lower_w(a[i]) != lower_w(b[i])) {
            return false;
        }
    }

    return true;
}

#if defined(_M_X64)
#pragma intrinsic(__readgsqword)
static void *read_peb() {
    return reinterpret_cast<void *>(__readgsqword(0x60));
}
#else
#error x64 only
#endif

static HMODULE find_loaded_module(const WCHAR *name) {
    auto *peb = static_cast<u8 *>(read_peb());

    if (!peb) {
        return nullptr;
    }

    auto *ldr = *reinterpret_cast<u8 **>(peb + 0x18);

    if (!ldr) {
        return nullptr;
    }

    auto *head = reinterpret_cast<LIST_ENTRY_ *>(ldr + 0x20);
    auto *current = head->Flink;
    const u16 target_length = wlen16(name);

    while (current && current != head) {
        auto *entry = reinterpret_cast<u8 *>(current) - 0x10;
        void *base = *reinterpret_cast<void **>(entry + 0x30);
        auto *base_name = reinterpret_cast<USTRING_ *>(entry + 0x58);
        const u16 length = static_cast<u16>(base_name->Length / sizeof(WCHAR));

        if (base && base_name->Buffer && length == target_length && weq_ci_n(base_name->Buffer, name, length)) {
            return base;
        }

        current = current->Flink;
    }

    return nullptr;
}

static void *pe_export(HMODULE module, const char *name) {
    if (!module || !name) {
        return nullptr;
    }

    auto *base = static_cast<u8 *>(module);

    if (*reinterpret_cast<u16 *>(base) != 0x5a4d) {
        return nullptr;
    }

    const u32 pe_offset = *reinterpret_cast<u32 *>(base + 0x3c);

    if (*reinterpret_cast<u32 *>(base + pe_offset) != 0x4550) {
        return nullptr;
    }

    u8 *optional = base + pe_offset + 24;

    if (*reinterpret_cast<u16 *>(optional) != 0x20b) {
        return nullptr;
    }

    const u32 export_rva = *reinterpret_cast<u32 *>(optional + 112);
    const u32 export_size = *reinterpret_cast<u32 *>(optional + 116);

    if (!export_rva) {
        return nullptr;
    }

    u8 *exports = base + export_rva;
    const u32 name_count = *reinterpret_cast<u32 *>(exports + 24);
    const u32 functions_rva = *reinterpret_cast<u32 *>(exports + 28);
    const u32 names_rva = *reinterpret_cast<u32 *>(exports + 32);
    const u32 ordinals_rva = *reinterpret_cast<u32 *>(exports + 36);
    auto *names = reinterpret_cast<u32 *>(base + names_rva);
    auto *ordinals = reinterpret_cast<u16 *>(base + ordinals_rva);
    auto *functions = reinterpret_cast<u32 *>(base + functions_rva);

    for (u32 i = 0; i < name_count; ++i) {
        const char *candidate = reinterpret_cast<const char *>(base + names[i]);

        if (!streq(candidate, name)) {
            continue;
        }

        const u32 rva = functions[ordinals[i]];

        if (rva >= export_rva && rva < export_rva + export_size) {
            return nullptr;
        }

        return base + rva;
    }

    return nullptr;
}

static void init_unicode(UNICODE_STRING *value, WCHAR *text) {
    const u16 length = wlen16(text);
    value->Length = static_cast<u16>(length * sizeof(WCHAR));
    value->MaximumLength = static_cast<u16>((length + 1) * sizeof(WCHAR));
    value->Buffer = text;
}

static void init_ansi(ANSI_STRING *value, const char *text) {
    const u16 length = static_cast<u16>(slen(text));
    value->Length = length;
    value->MaximumLength = static_cast<u16>(length + 1);
    value->Buffer = const_cast<char *>(text);
}

static HMODULE load_dll(WCHAR *name) {
    if (!pLdrLoadDll) {
        return nullptr;
    }

    UNICODE_STRING value{};
    init_unicode(&value, name);
    HMODULE module = nullptr;

    return pLdrLoadDll(nullptr, nullptr, &value, &module) >= 0 ? module : nullptr;
}

static void *get_proc(HMODULE module, const char *name) {
    if (!module || !pLdrGetProcedureAddress) {
        return nullptr;
    }

    ANSI_STRING value{};
    init_ansi(&value, name);
    void *proc = nullptr;

    return pLdrGetProcedureAddress(module, &value, 0, &proc) >= 0 ? proc : nullptr;
}

// current win32 api surface
static bool init_win32() {
    HMODULE ntdll = find_loaded_module(L"ntdll.dll");

    if (!ntdll) {
        return false;
    }

    pLdrLoadDll = reinterpret_cast<LdrLoadDllFn>(pe_export(ntdll, "LdrLoadDll"));
    pLdrGetProcedureAddress = reinterpret_cast<LdrGetProcedureAddressFn>(pe_export(ntdll, "LdrGetProcedureAddress"));

    if (!pLdrLoadDll || !pLdrGetProcedureAddress) {
        return false;
    }

    WCHAR kernel_name[] = L"kernel32.dll";
    HMODULE kernel = find_loaded_module(kernel_name);

    if (!kernel) {
        kernel = load_dll(kernel_name);
    }

    if (!kernel) {
        return false;
    }

    pVirtualQuery = reinterpret_cast<VirtualQueryFn>(get_proc(kernel, "VirtualQuery"));
    pVirtualAlloc = reinterpret_cast<VirtualAllocFn>(get_proc(kernel, "VirtualAlloc"));
    pVirtualFree = reinterpret_cast<VirtualFreeFn>(get_proc(kernel, "VirtualFree"));
    pVirtualProtect = reinterpret_cast<VirtualProtectFn>(get_proc(kernel, "VirtualProtect"));
    pFlushInstructionCache = reinterpret_cast<FlushInstructionCacheFn>(get_proc(kernel, "FlushInstructionCache"));
    pGetCurrentProcess = reinterpret_cast<GetCurrentProcessFn>(get_proc(kernel, "GetCurrentProcess"));

    return pVirtualQuery && pVirtualAlloc && pVirtualFree && pVirtualProtect && pFlushInstructionCache && pGetCurrentProcess;
}

static u8 *exe_base() {
    auto *peb = static_cast<u8 *>(read_peb());
    return peb ? *reinterpret_cast<u8 **>(peb + 0x10) : nullptr;
}

#pragma intrinsic(_InterlockedCompareExchange)
#pragma intrinsic(_InterlockedCompareExchange64)
#pragma intrinsic(_InterlockedExchange)

static u32 atomic_load_u32(const volatile u32 *p) {
    return static_cast<u32>(_InterlockedCompareExchange(
        reinterpret_cast<volatile long *>(const_cast<volatile u32 *>(p)), 0, 0));
}

static void atomic_store_u32(volatile u32 *p, u32 value) {
    _InterlockedExchange(reinterpret_cast<volatile long *>(p), static_cast<long>(value));
}

static bool cas_u32(volatile u32 *p, u32 expected, u32 desired) {
    return static_cast<u32>(_InterlockedCompareExchange(
        reinterpret_cast<volatile long *>(p), static_cast<long>(desired), static_cast<long>(expected))) == expected;
}

static bool try_lock_u32(volatile u32 *p) {
    return cas_u32(p, 0u, 1u);
}

static void unlock_u32(volatile u32 *p) {
    atomic_store_u32(p, 0u);
}

static void lock_u32(volatile u32 *p) {
    while (!try_lock_u32(p)) {
    }
}

static bool readable_range(const void *p, usize bytes) {
    if (!p || !bytes || !pVirtualQuery) {
        return false;
    }

    MEMORY_BASIC_INFORMATION_ mbi{};

    if (pVirtualQuery(p, &mbi, sizeof(mbi)) != sizeof(mbi) ||
        mbi.State != MEM_COMMIT ||
        (mbi.Protect & PAGE_GUARD) ||
        (mbi.Protect & 0xffu) == PAGE_NOACCESS) {
        return false;
    }

    const usize address = reinterpret_cast<usize>(p);
    const usize base = reinterpret_cast<usize>(mbi.BaseAddress);
    const usize end = base + mbi.RegionSize;

    return address >= base && address <= end && bytes <= end - address;
}

// d3d12 abi
static void **vtbl(void *object) {
    return object ? *reinterpret_cast<void ***>(object) : nullptr;
}

static ULONG com_release(void *object) {
    if (!object) {
        return 0;
    }

    using Fn = ULONG (STDCALL *)(void *);
    return reinterpret_cast<Fn>(vtbl(object)[2])(object);
}

struct DXGI_SAMPLE_DESC {
    u32 Count;
    u32 Quality;
};

struct D3D12_RESOURCE_DESC {
    u32 Dimension;
    u64 Alignment;
    u64 Width;
    u32 Height;
    u16 DepthOrArraySize;
    u16 MipLevels;
    u32 Format;
    DXGI_SAMPLE_DESC SampleDesc;
    u32 Layout;
    u32 Flags;
};

struct D3D12_HEAP_PROPERTIES {
    u32 Type;
    u32 CPUPageProperty;
    u32 MemoryPoolPreference;
    u32 CreationNodeMask;
    u32 VisibleNodeMask;
};

struct D3D12_RANGE {
    usize Begin;
    usize End;
};

struct D3D12_BOX {
    u32 left;
    u32 top;
    u32 front;
    u32 right;
    u32 bottom;
    u32 back;
};

struct D3D12_SUBRESOURCE_FOOTPRINT {
    u32 Format;
    u32 Width;
    u32 Height;
    u32 Depth;
    u32 RowPitch;
};

struct D3D12_PLACED_SUBRESOURCE_FOOTPRINT {
    u64 Offset;
    D3D12_SUBRESOURCE_FOOTPRINT Footprint;
};

struct D3D12_TEXTURE_COPY_LOCATION {
    void *pResource;
    u32 Type;
    u32 padding;

    union {
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT PlacedFootprint;
        u32 SubresourceIndex;
    };
};

struct D3D12_RESOURCE_TRANSITION_BARRIER {
    void *pResource;
    u32 Subresource;
    u32 StateBefore;
    u32 StateAfter;
};

struct D3D12_RESOURCE_BARRIER {
    u32 Type;
    u32 Flags;

    union {
        D3D12_RESOURCE_TRANSITION_BARRIER Transition;
        u64 padding[3];
    };
};

static_assert(sizeof(D3D12_RESOURCE_DESC) == 56u);
static_assert(sizeof(D3D12_BOX) == 24u);
static_assert(sizeof(D3D12_PLACED_SUBRESOURCE_FOOTPRINT) == 32u);
static_assert(sizeof(D3D12_TEXTURE_COPY_LOCATION) == 48u);
static_assert(sizeof(D3D12_RESOURCE_BARRIER) == 32u);

static constexpr u32 D3D12_COMMAND_LIST_TYPE_DIRECT = 0u;
static constexpr u32 D3D12_HEAP_TYPE_UPLOAD = 2u;
static constexpr u32 D3D12_RESOURCE_DIMENSION_BUFFER = 1u;
static constexpr u32 D3D12_RESOURCE_DIMENSION_TEXTURE2D = 3u;
static constexpr u32 D3D12_TEXTURE_LAYOUT_ROW_MAJOR = 1u;
static constexpr u32 D3D12_RESOURCE_STATE_COPY_DEST = 0x400u;
static constexpr u32 D3D12_RESOURCE_STATE_GENERIC_READ = 0xac3u;
static constexpr u32 D3D12_RESOURCE_BARRIER_TYPE_TRANSITION = 0u;
static constexpr u32 D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES = 0xffffffffu;
static constexpr u32 D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX = 0u;
static constexpr u32 D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT = 1u;
static constexpr u32 DXGI_FORMAT_R8G8B8A8_UNORM = 28u;
static constexpr u32 DXGI_FORMAT_R8G8B8A8_UNORM_SRGB = 29u;
static constexpr u32 DXGI_FORMAT_B8G8R8A8_UNORM = 87u;
static constexpr u32 DXGI_FORMAT_B8G8R8A8_UNORM_SRGB = 91u;

static const GUID IID_ID3D12CommandAllocator_ = {0x6102dee4u, 0xaf59, 0x4b09, {0xb9, 0x99, 0xb4, 0x4d, 0x73, 0xf0, 0x9b, 0x24}};
static const GUID IID_ID3D12GraphicsCommandList_ = {0x5b160d0fu, 0xac1b, 0x4185, {0x8b, 0xa8, 0xb3, 0xae, 0x42, 0xa5, 0xa4, 0x55}};
static const GUID IID_ID3D12Resource_ = {0x696442beu, 0xa72e, 0x4059, {0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad}};
static const GUID IID_ID3D12Fence_ = {0x0a753dcfu, 0xc4d8, 0x4b91, {0xad, 0xf6, 0xbe, 0x5a, 0x60, 0xd9, 0x5a, 0x76}};

static HRESULT device_create_allocator(void *device, void **out) {
    using Fn = HRESULT (STDCALL *)(void *, u32, const GUID *, void **);
    return reinterpret_cast<Fn>(vtbl(device)[9])(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator_, out);
}

static HRESULT device_create_list(void *device, void *allocator, void **out) {
    using Fn = HRESULT (STDCALL *)(void *, u32, u32, void *, void *, const GUID *, void **);
    return reinterpret_cast<Fn>(vtbl(device)[12])(
        device, 0u, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, nullptr, &IID_ID3D12GraphicsCommandList_, out);
}

static HRESULT device_create_fence(void *device, u64 initial, void **out) {
    using Fn = HRESULT (STDCALL *)(void *, u64, u32, const GUID *, void **);
    return reinterpret_cast<Fn>(vtbl(device)[36])(device, initial, 0u, &IID_ID3D12Fence_, out);
}

static HRESULT device_create_upload(void *device, u64 bytes, void **out) {
    D3D12_HEAP_PROPERTIES heap{D3D12_HEAP_TYPE_UPLOAD, 0u, 0u, 1u, 1u};
    D3D12_RESOURCE_DESC desc{};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = bytes;
    desc.Height = 1u;
    desc.DepthOrArraySize = 1u;
    desc.MipLevels = 1u;
    desc.SampleDesc.Count = 1u;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;

    using Fn = HRESULT (STDCALL *)(void *, const D3D12_HEAP_PROPERTIES *, u32, const D3D12_RESOURCE_DESC *, u32, const void *, const GUID *, void **);
    return reinterpret_cast<Fn>(vtbl(device)[27])(
        device, &heap, 0u, &desc, D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, &IID_ID3D12Resource_, out);
}

static void device_footprint(
    void *device,
    const D3D12_RESOURCE_DESC &desc,
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT *footprint,
    u32 *rows,
    u64 *row_bytes,
    u64 *total) {
    using Fn = void (STDCALL *)(void *, const D3D12_RESOURCE_DESC *, u32, u32, u64, D3D12_PLACED_SUBRESOURCE_FOOTPRINT *, u32 *, u64 *, u64 *);
    reinterpret_cast<Fn>(vtbl(device)[38])(device, &desc, 0u, 1u, 0u, footprint, rows, row_bytes, total);
}

static D3D12_RESOURCE_DESC resource_desc(void *resource) {
    D3D12_RESOURCE_DESC desc{};

    // resource desc uses hidden return storage on x64
    using Fn = D3D12_RESOURCE_DESC *(STDCALL *)(void *, D3D12_RESOURCE_DESC *);
    reinterpret_cast<Fn>(vtbl(resource)[10])(resource, &desc);

    return desc;
}

static HRESULT resource_map(void *resource, void **mapped) {
    D3D12_RANGE range{0u, 0u};
    using Fn = HRESULT (STDCALL *)(void *, u32, const D3D12_RANGE *, void **);
    return reinterpret_cast<Fn>(vtbl(resource)[8])(resource, 0u, &range, mapped);
}

static HRESULT allocator_reset(void *allocator) {
    using Fn = HRESULT (STDCALL *)(void *);
    return reinterpret_cast<Fn>(vtbl(allocator)[8])(allocator);
}

static HRESULT list_close(void *list) {
    using Fn = HRESULT (STDCALL *)(void *);
    return reinterpret_cast<Fn>(vtbl(list)[9])(list);
}

static HRESULT list_reset(void *list, void *allocator) {
    using Fn = HRESULT (STDCALL *)(void *, void *, void *);
    return reinterpret_cast<Fn>(vtbl(list)[10])(list, allocator, nullptr);
}

static void list_barrier(void *list, D3D12_RESOURCE_BARRIER *barrier) {
    using Fn = void (STDCALL *)(void *, u32, const D3D12_RESOURCE_BARRIER *);
    reinterpret_cast<Fn>(vtbl(list)[26])(list, 1u, barrier);
}

static void list_copy_region(
    void *list,
    const D3D12_TEXTURE_COPY_LOCATION *dst,
    u32 x,
    u32 y,
    const D3D12_TEXTURE_COPY_LOCATION *src,
    const D3D12_BOX *box) {
    using Fn = void (STDCALL *)(void *, const D3D12_TEXTURE_COPY_LOCATION *, u32, u32, u32, const D3D12_TEXTURE_COPY_LOCATION *, const D3D12_BOX *);
    reinterpret_cast<Fn>(vtbl(list)[16])(list, dst, x, y, 0u, src, box);
}

static void queue_execute(void *queue, void *list) {
    void *lists[1] = {list};
    using Fn = void (STDCALL *)(void *, u32, void *const *);
    reinterpret_cast<Fn>(vtbl(queue)[10])(queue, 1u, lists);
}

static HRESULT queue_signal(void *queue, void *fence, u64 value) {
    using Fn = HRESULT (STDCALL *)(void *, void *, u64);
    return reinterpret_cast<Fn>(vtbl(queue)[14])(queue, fence, value);
}

static u64 fence_completed(void *fence) {
    using Fn = u64 (STDCALL *)(void *);
    return reinterpret_cast<Fn>(vtbl(fence)[8])(fence);
}

static constexpr i32 MAX_BROWSERS = 4;
static constexpr u32 BROWSER_FRAME_SLOTS = 3u;
static constexpr u32 MAX_BROWSER_DIMENSION = 8192u;
static constexpr u64 MAX_BROWSER_PIXELS = 67108864ull;
static constexpr u32 POPUP_SAME_BROWSER = 0u;

struct BrowserFrameSlot {
    volatile u32 state;
    u32 width;
    u32 height;
    u32 stride;
    u64 sequence;
    u8 *pixels;
};

enum BrowserFrameState : u32 {
    FRAME_FREE = 0u,
    FRAME_WRITING = 1u,
    FRAME_READY = 2u,
    FRAME_READING = 3u,
};

struct BrowserState {
    volatile u32 used;
    volatile u32 destroy_pending;
    u32 generation;
    u32 slot;
    i32 width;
    i32 height;
    i32 x;
    i32 y;
    volatile u32 render_target_enabled;
    volatile u32 render_target_presented;
    u32 render_target_handle;
    u32 render_target_padding;
    u64 render_target_hash;
    i32 render_target_x;
    i32 render_target_y;
    i32 render_target_width;
    i32 render_target_height;
    u64 render_target_fence;
    i32 mouse_x;
    i32 mouse_y;
    volatile u32 ready;
    volatile u32 loading;
    volatile u32 desired_visible;
    volatile u32 desired_focus;
    u32 popup_policy;
    char url[2048];
    char title[1024];
    char desired_url[4096];
    volatile u32 error_lock;
    char error[512];
    u32 steam_browser;
    u64 steam_create_call;
    u64 steam_frame_sequence;
    volatile u32 retained_frame_slot_plus_one;
    volatile u32 frame_lock;
    u8 *frame_storage;
    u64 frame_bytes;
    BrowserFrameSlot frames[BROWSER_FRAME_SLOTS];
};

struct AcquiredFrame {
    const u8 *pixels;
    u32 width;
    u32 height;
    u32 stride;
    u64 sequence;
    bool locked;
};

static BrowserState g_browsers[MAX_BROWSERS]{};
static u32 g_generations[MAX_BROWSERS]{};
static volatile u32 g_runtime_started = 0u;
static char g_runtime_error[512]{};
static char g_string_result[4096]{};
static volatile u32 g_string_lock = 0u;

static bool dr_enable();
static void dr_refresh_request();
static u64 dr_reference_hash(const char *text);
static void dr_shutdown();
static bool dr_build_supported();
static const char *dr_get_error();

static void set_runtime_error(const char *text) {
    copy_cstr(g_runtime_error, sizeof(g_runtime_error), text ? text : "");
}

static void set_error(BrowserState *browser, const char *text) {
    if (!browser) {
        return;
    }

    lock_u32(&browser->error_lock);
    copy_cstr(browser->error, sizeof(browser->error), text ? text : "");
    unlock_u32(&browser->error_lock);
}

static bool valid_frame_size(i32 width, i32 height) {
    if (width <= 0 || height <= 0) {
        return false;
    }

    const u64 pixels = static_cast<u64>(width) * static_cast<u64>(height);
    return static_cast<u32>(width) <= MAX_BROWSER_DIMENSION &&
           static_cast<u32>(height) <= MAX_BROWSER_DIMENSION &&
           pixels <= MAX_BROWSER_PIXELS;
}

static bool valid_utf8(const char *text, usize length) {
    if (!text && length) {
        return false;
    }

    usize i = 0;

    while (i < length) {
        const u8 c = static_cast<u8>(text[i]);

        if (c <= 0x7fu) {
            if (c == 0u) {
                return false;
            }

            ++i;
            continue;
        }

        u32 codepoint = 0u;
        usize extra = 0u;

        if (c >= 0xc2u && c <= 0xdfu) {
            codepoint = c & 0x1fu;
            extra = 1u;
        } else if (c >= 0xe0u && c <= 0xefu) {
            codepoint = c & 0x0fu;
            extra = 2u;
        } else if (c >= 0xf0u && c <= 0xf4u) {
            codepoint = c & 0x07u;
            extra = 3u;
        } else {
            return false;
        }

        if (i + extra >= length) {
            return false;
        }

        for (usize j = 1u; j <= extra; ++j) {
            const u8 next = static_cast<u8>(text[i + j]);

            if ((next & 0xc0u) != 0x80u) {
                return false;
            }

            codepoint = (codepoint << 6u) | (next & 0x3fu);
        }

        if ((extra == 1u && codepoint < 0x80u) ||
            (extra == 2u && codepoint < 0x800u) ||
            (extra == 3u && codepoint < 0x10000u) ||
            codepoint > 0x10ffffu ||
            (codepoint >= 0xd800u && codepoint <= 0xdfffu)) {
            return false;
        }

        i += extra + 1u;
    }

    return true;
}

static u64 make_handle(i32 slot, u32 generation) {
    return (static_cast<u64>(generation) << 8u) | static_cast<u64>(slot + 1);
}

static BrowserState *get_browser(u64 handle) {
    if (!handle) {
        return nullptr;
    }

    const u32 slot = static_cast<u32>(handle & 0xffu);
    const u32 generation = static_cast<u32>(handle >> 8u);

    if (!slot || slot > static_cast<u32>(MAX_BROWSERS) || !generation) {
        return nullptr;
    }

    BrowserState &browser = g_browsers[slot - 1u];

    if (!atomic_load_u32(&browser.used) || browser.generation != generation) {
        return nullptr;
    }

    return &browser;
}

static void frame_release(BrowserState &browser) {
    lock_u32(&browser.frame_lock);
    u8 *storage = browser.frame_storage;
    browser.frame_storage = nullptr;
    browser.frame_bytes = 0u;
    atomic_store_u32(&browser.retained_frame_slot_plus_one, 0u);

    for (u32 i = 0; i < BROWSER_FRAME_SLOTS; ++i) {
        browser.frames[i] = {};
    }

    unlock_u32(&browser.frame_lock);

    if (storage && pVirtualFree) {
        pVirtualFree(storage, 0u, MEM_RELEASE);
    }
}

static bool frame_storage_resize(BrowserState &browser, i32 width, i32 height) {
    if (!valid_frame_size(width, height) || !pVirtualAlloc || !pVirtualFree) {
        return false;
    }

    const u64 bytes = static_cast<u64>(width) * static_cast<u64>(height) * 4u;
    const u64 total = bytes * BROWSER_FRAME_SLOTS;
    auto *storage = static_cast<u8 *>(pVirtualAlloc(nullptr, static_cast<usize>(total), MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));

    if (!storage) {
        set_error(&browser, "could not allocate browser frame storage");
        return false;
    }

    lock_u32(&browser.frame_lock);
    u8 *old_storage = browser.frame_storage;
    browser.frame_storage = storage;
    browser.frame_bytes = bytes;
    atomic_store_u32(&browser.retained_frame_slot_plus_one, 0u);

    for (u32 i = 0; i < BROWSER_FRAME_SLOTS; ++i) {
        BrowserFrameSlot &slot = browser.frames[i];
        slot = {};
        slot.pixels = storage + static_cast<u64>(i) * bytes;
        atomic_store_u32(&slot.state, FRAME_FREE);
    }

    unlock_u32(&browser.frame_lock);

    if (old_storage) {
        pVirtualFree(old_storage, 0u, MEM_RELEASE);
    }

    return true;
}

static bool frame_resize(BrowserState &browser, i32 width, i32 height) {
    if (!frame_storage_resize(browser, width, height)) {
        return false;
    }

    browser.width = width;
    browser.height = height;
    return true;
}

static bool frame_publish(BrowserState &browser, const u8 *bgra, u32 width, u32 height) {
    if (!bgra || !valid_frame_size(static_cast<i32>(width), static_cast<i32>(height))) {
        return false;
    }

    const u64 paint_bytes = static_cast<u64>(width) * static_cast<u64>(height) * 4u;

    // grow paint storage when Steam reports a larger frame
    for (;;) {
        lock_u32(&browser.frame_lock);
        const bool enough = browser.frame_storage && paint_bytes <= browser.frame_bytes;
        unlock_u32(&browser.frame_lock);

        if (enough) {
            break;
        }

        if (!frame_storage_resize(browser, static_cast<i32>(width), static_cast<i32>(height))) {
            return false;
        }
    }

    lock_u32(&browser.frame_lock);
    i32 chosen = -1;
    i32 oldest_ready = -1;
    u64 oldest_sequence = ~static_cast<u64>(0u);

    for (u32 i = 0; i < BROWSER_FRAME_SLOTS; ++i) {
        BrowserFrameSlot &candidate = browser.frames[i];
        const u32 state = atomic_load_u32(&candidate.state);

        if (state == FRAME_FREE) {
            chosen = static_cast<i32>(i);
            break;
        }

        if (state == FRAME_READY && candidate.sequence < oldest_sequence) {
            oldest_sequence = candidate.sequence;
            oldest_ready = static_cast<i32>(i);
        }
    }

    // recycle the oldest queued paint when the producer gets ahead
    if (chosen < 0) {
        chosen = oldest_ready;
    }

    if (chosen < 0) {
        // drop this paint if every slot is still in use
        unlock_u32(&browser.frame_lock);
        return true;
    }

    BrowserFrameSlot &slot = browser.frames[static_cast<u32>(chosen)];
    atomic_store_u32(&slot.state, FRAME_WRITING);
    const u32 stride = width * 4u;

    for (u32 y = 0; y < height; ++y) {
        memcpy(slot.pixels + static_cast<u64>(y) * stride, bgra + static_cast<u64>(y) * stride, stride);
    }

    slot.width = width;
    slot.height = height;
    slot.stride = stride;
    slot.sequence = ++browser.steam_frame_sequence;
    atomic_store_u32(&slot.state, FRAME_READY);
    unlock_u32(&browser.frame_lock);
    return true;
}

static bool acquire_frame(BrowserState &browser, AcquiredFrame &frame) {
    if (!try_lock_u32(&browser.frame_lock)) {
        return false;
    }

    i32 chosen = -1;
    u64 newest = 0u;

    for (u32 i = 0; i < BROWSER_FRAME_SLOTS; ++i) {
        BrowserFrameSlot &slot = browser.frames[i];

        if (atomic_load_u32(&slot.state) == FRAME_READY && slot.sequence >= newest) {
            newest = slot.sequence;
            chosen = static_cast<i32>(i);
        }
    }

    const u32 old_plus_one = atomic_load_u32(&browser.retained_frame_slot_plus_one);
    const i32 old_index = old_plus_one > 0u && old_plus_one <= BROWSER_FRAME_SLOTS
        ? static_cast<i32>(old_plus_one - 1u)
        : -1;

    if (chosen >= 0) {
        BrowserFrameSlot &slot = browser.frames[static_cast<u32>(chosen)];

        if (cas_u32(&slot.state, FRAME_READY, FRAME_READING)) {
            if (old_index >= 0 && old_index != chosen) {
                BrowserFrameSlot &old = browser.frames[static_cast<u32>(old_index)];

                if (atomic_load_u32(&old.state) == FRAME_READING) {
                    atomic_store_u32(&old.state, FRAME_FREE);
                }
            }

            for (u32 i = 0; i < BROWSER_FRAME_SLOTS; ++i) {
                if (static_cast<i32>(i) == chosen) {
                    continue;
                }

                BrowserFrameSlot &old = browser.frames[i];

                if (atomic_load_u32(&old.state) == FRAME_READY && old.sequence < slot.sequence) {
                    cas_u32(&old.state, FRAME_READY, FRAME_FREE);
                }
            }

            atomic_store_u32(&browser.retained_frame_slot_plus_one, static_cast<u32>(chosen) + 1u);
        } else {
            chosen = -1;
        }
    }

    if (chosen < 0) {
        const u32 keep = atomic_load_u32(&browser.retained_frame_slot_plus_one);

        if (keep > 0u && keep <= BROWSER_FRAME_SLOTS) {
            const i32 index = static_cast<i32>(keep - 1u);
            BrowserFrameSlot &slot = browser.frames[static_cast<u32>(index)];

            if (atomic_load_u32(&slot.state) == FRAME_READING) {
                chosen = index;
            }
        }
    }

    if (chosen < 0) {
        unlock_u32(&browser.frame_lock);
        return false;
    }

    BrowserFrameSlot &slot = browser.frames[static_cast<u32>(chosen)];
    frame.pixels = slot.pixels;
    frame.width = slot.width;
    frame.height = slot.height;
    frame.stride = slot.stride;
    frame.sequence = slot.sequence;
    frame.locked = true;
    return true;
}

static void release_frame(BrowserState &browser, AcquiredFrame &frame) {
    if (frame.locked) {
        unlock_u32(&browser.frame_lock);
        frame.locked = false;
    }
}

#include "steam_html.inl"
#include "direct_backbuffer.inl"

static void clear_browser(BrowserState &browser) {
    const u32 generation = browser.generation;
    const u32 slot = browser.slot;

    frame_release(browser);
    memset(&browser, 0, sizeof(browser));
    browser.generation = generation;
    browser.slot = slot;
}

static bool ensure_started() {
    if (atomic_load_u32(&g_runtime_started)) {
        return true;
    }

    set_runtime_error("browser runtime is not started");
    return false;
}

static const char *copy_result(const char *value) {
    lock_u32(&g_string_lock);
    copy_cstr(g_string_result, sizeof(g_string_result), value ? value : "");
    unlock_u32(&g_string_lock);
    return g_string_result;
}

EXPORT int BrowserRuntime_Start() {
    if (atomic_load_u32(&g_runtime_started)) {
        return 1;
    }

    if (!init_win32()) {
        set_runtime_error("win32 api initialization failed");
        return 0;
    }

    if (!dr_build_supported()) {
        set_runtime_error(dr_get_error());
        return 0;
    }

    if (!steam_html_ensure()) {
        set_runtime_error(steam_html_error());
        return 0;
    }

    atomic_store_u32(&g_runtime_started, 1u);
    set_runtime_error("");
    return 1;
}

EXPORT void BrowserRuntime_Shutdown() {
    if (!atomic_load_u32(&g_runtime_started)) {
        return;
    }

    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        BrowserState &browser = g_browsers[i];

        if (atomic_load_u32(&browser.used)) {
            atomic_store_u32(&browser.desired_visible, 0u);
            dr_clear_render_target(browser);
        }
    }

    dr_refresh_request();
    steam_html_shutdown_all();
    dr_shutdown();

    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        BrowserState &browser = g_browsers[i];

        if (atomic_load_u32(&browser.used)) {
            clear_browser(browser);
        }
    }

    atomic_store_u32(&g_runtime_started, 0u);
}

EXPORT const char *BrowserRuntime_LastError() {
    return copy_result(g_runtime_error);
}

EXPORT const char *BrowserRuntime_RendererError() {
    return copy_result(dr_get_error());
}


EXPORT u64 BrowserRuntime_Create(i32 width, i32 height) {
    if (!ensure_started() || !valid_frame_size(width, height)) {
        return 0u;
    }

    for (i32 i = 0; i < MAX_BROWSERS; ++i) {
        BrowserState &browser = g_browsers[i];

        if (atomic_load_u32(&browser.used) || atomic_load_u32(&browser.destroy_pending)) {
            continue;
        }

        u32 generation = ++g_generations[i];

        if (!generation) {
            generation = ++g_generations[i];
        }

        memset(&browser, 0, sizeof(browser));
        browser.generation = generation;
        browser.slot = static_cast<u32>(i);
        browser.x = -1;
        browser.y = -1;
        browser.render_target_handle = 0xffffffffu;
        browser.popup_policy = POPUP_SAME_BROWSER;
        atomic_store_u32(&browser.used, 1u);

        if (!frame_resize(browser, width, height)) {
            clear_browser(browser);
            return 0u;
        }

        if (!steam_html_create(browser)) {
            set_runtime_error(browser.error[0] ? browser.error : steam_html_error());
            clear_browser(browser);
            return 0u;
        }

        return make_handle(i, generation);
    }

    set_runtime_error("no free browser slots");
    return 0u;
}

EXPORT int BrowserRuntime_Destroy(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!browser) {
        return 0;
    }

    atomic_store_u32(&browser->desired_visible, 0u);
    dr_clear_render_target(*browser);
    steam_html_destroy(*browser);
    dr_refresh_request();
    clear_browser(*browser);
    return 1;
}

EXPORT int BrowserRuntime_IsReady(u64 handle) {
    return steam_html_browser_ready(get_browser(handle)) ? 1 : 0;
}

EXPORT int BrowserRuntime_IsVisible(u64 handle) {
    BrowserState *browser = get_browser(handle);
    return browser && atomic_load_u32(&browser->desired_visible) ? 1 : 0;
}

EXPORT int BrowserRuntime_IsLoading(u64 handle) {
    BrowserState *browser = get_browser(handle);
    return browser && atomic_load_u32(&browser->loading) ? 1 : 0;
}

EXPORT int BrowserRuntime_IsRenderTargetPresented(u64 handle) {
    BrowserState *browser = get_browser(handle);
    return browser && atomic_load_u32(&browser->render_target_presented) ? 1 : 0;
}

EXPORT const char *BrowserRuntime_GetUrl(u64 handle) {
    BrowserState *browser = get_browser(handle);
    return copy_result(browser ? browser->url : "");
}

EXPORT const char *BrowserRuntime_GetTitle(u64 handle) {
    BrowserState *browser = get_browser(handle);
    return copy_result(browser ? browser->title : "");
}

EXPORT const char *BrowserRuntime_GetError(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!browser) {
        return copy_result("invalid browser handle");
    }

    char error[512]{};
    lock_u32(&browser->error_lock);
    copy_cstr(error, sizeof(error), browser->error);
    unlock_u32(&browser->error_lock);
    return copy_result(error);
}

EXPORT int BrowserRuntime_Navigate(u64 handle, const char *url) {
    BrowserState *browser = get_browser(handle);
    const usize length = slen(url);

    if (!browser || !url || !length || length >= sizeof(browser->desired_url) || !valid_utf8(url, length)) {
        return 0;
    }

    copy_chars(browser->desired_url, sizeof(browser->desired_url), url, length);

    if (steam_html_browser_ready(browser)) {
        g_steam_html_fns.load_url(g_steam_html_iface, browser->steam_browser, browser->desired_url, nullptr);
    }

    return 1;
}

EXPORT int BrowserRuntime_Reload(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    g_steam_html_fns.reload(g_steam_html_iface, browser->steam_browser);
    return 1;
}

EXPORT int BrowserRuntime_Stop(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    g_steam_html_fns.stop_load(g_steam_html_iface, browser->steam_browser);
    return 1;
}

EXPORT int BrowserRuntime_Back(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    g_steam_html_fns.go_back(g_steam_html_iface, browser->steam_browser);
    return 1;
}

EXPORT int BrowserRuntime_Forward(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    g_steam_html_fns.go_forward(g_steam_html_iface, browser->steam_browser);
    return 1;
}

EXPORT int BrowserRuntime_SetSize(u64 handle, i32 width, i32 height) {
    BrowserState *browser = get_browser(handle);

    if (!browser || !valid_frame_size(width, height)) {
        return 0;
    }

    if (browser->width == width && browser->height == height) {
        return 1;
    }

    if (!frame_resize(*browser, width, height)) {
        return 0;
    }

    if (steam_html_browser_ready(browser)) {
        g_steam_html_fns.set_size(g_steam_html_iface, browser->steam_browser, static_cast<u32>(width), static_cast<u32>(height));
    }

    return 1;
}

EXPORT int BrowserRuntime_SetPosition(u64 handle, i32 x, i32 y) {
    BrowserState *browser = get_browser(handle);

    if (!browser) {
        return 0;
    }

    browser->x = x;
    browser->y = y;
    return 1;
}

EXPORT int BrowserRuntime_SetRenderTarget(
    u64 handle,
    const char *reference_name,
    i32 x,
    i32 y,
    i32 width,
    i32 height) {
    BrowserState *browser = get_browser(handle);
    const usize name_length = slen(reference_name);

    if (!browser || !reference_name || !name_length || x < 0 || y < 0 || width <= 0 || height <= 0) {
        return 0;
    }

    dr_clear_render_target(*browser);
    dr_set_error("");

    lock_u32(&g_dr_target_lock);
    browser->render_target_handle = 0xffffffffu;
    browser->render_target_hash = dr_reference_hash(reference_name);
    browser->render_target_x = x;
    browser->render_target_y = y;
    browser->render_target_width = width;
    browser->render_target_height = height;
    browser->render_target_fence = 0u;
    atomic_store_u32(&browser->render_target_presented, 0u);
    atomic_store_u32(&browser->render_target_enabled, 1u);
    unlock_u32(&g_dr_target_lock);

    dr_refresh_request();

    if (atomic_load_u32(&browser->desired_visible) && !dr_enable()) {
        dr_clear_render_target(*browser);
        set_error(browser, dr_get_error());
        return 0;
    }

    return 1;
}

EXPORT int BrowserRuntime_ClearRenderTarget(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!browser) {
        return 0;
    }

    dr_clear_render_target(*browser);
    dr_refresh_request();
    return 1;
}

EXPORT int BrowserRuntime_SetVisible(u64 handle, int visible) {
    BrowserState *browser = get_browser(handle);

    if (!browser) {
        return 0;
    }

    atomic_store_u32(&browser->desired_visible, visible ? 1u : 0u);

    if (steam_html_browser_ready(browser)) {
        g_steam_html_fns.set_background_mode(g_steam_html_iface, browser->steam_browser, !visible);
    }

    dr_refresh_request();

    if (visible && !dr_enable()) {
        set_error(browser, dr_get_error());
        return 0;
    }

    return 1;
}

EXPORT int BrowserRuntime_SetFocus(u64 handle, int focused) {
    BrowserState *browser = get_browser(handle);

    if (!browser) {
        return 0;
    }

    atomic_store_u32(&browser->desired_focus, focused ? 1u : 0u);

    if (steam_html_browser_ready(browser)) {
        g_steam_html_fns.set_key_focus(g_steam_html_iface, browser->steam_browser, focused != 0);
    }

    return 1;
}

EXPORT int BrowserRuntime_ExecuteJavascript(u64 handle, const char *script) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser) || !script || !script[0]) {
        return 0;
    }

    g_steam_html_fns.execute_javascript(g_steam_html_iface, browser->steam_browser, script);
    return 1;
}

EXPORT int BrowserRuntime_MouseMove(u64 handle, i32 x, i32 y) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    browser->mouse_x = x;
    browser->mouse_y = y;
    g_steam_html_fns.mouse_move(g_steam_html_iface, browser->steam_browser, x, y);
    return 1;
}

EXPORT int BrowserRuntime_MouseButton(u64 handle, i32 button, int down, i32 clicks) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser) || button < 0 || button > 2) {
        return 0;
    }

    if (down && clicks >= 2) {
        g_steam_html_fns.mouse_double_click(g_steam_html_iface, browser->steam_browser, button);
    } else if (down) {
        g_steam_html_fns.mouse_down(g_steam_html_iface, browser->steam_browser, button);
    } else {
        g_steam_html_fns.mouse_up(g_steam_html_iface, browser->steam_browser, button);
    }

    return 1;
}

EXPORT int BrowserRuntime_MouseWheel(u64 handle, i32 delta) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    g_steam_html_fns.mouse_wheel(g_steam_html_iface, browser->steam_browser, delta);
    return 1;
}

EXPORT int BrowserRuntime_Key(u64 handle, u32 key, int down, u32 modifiers, int system_key) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    modifiers &= 0x7u;

    if (down) {
        g_steam_html_fns.key_down(g_steam_html_iface, browser->steam_browser, key, modifiers, system_key != 0);
    } else {
        g_steam_html_fns.key_up(g_steam_html_iface, browser->steam_browser, key, modifiers);
    }

    return 1;
}

EXPORT int BrowserRuntime_Char(u64 handle, const char *text, u32 modifiers) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser) || !text) {
        return 0;
    }

    const usize length = slen(text);
    usize offset = 0u;
    modifiers &= 0x7u;

    while (offset < length) {
        const u32 codepoint = steam_utf8_next(text, length, &offset);

        if (codepoint) {
            g_steam_html_fns.key_char(g_steam_html_iface, browser->steam_browser, codepoint, modifiers);
        }
    }

    return 1;
}

EXPORT int BrowserRuntime_CopyToClipboard(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    g_steam_html_fns.copy_to_clipboard(g_steam_html_iface, browser->steam_browser);
    return 1;
}

EXPORT int BrowserRuntime_PasteFromClipboard(u64 handle) {
    BrowserState *browser = get_browser(handle);

    if (!steam_html_browser_ready(browser)) {
        return 0;
    }

    g_steam_html_fns.paste_from_clipboard(g_steam_html_iface, browser->steam_browser);
    return 1;
}

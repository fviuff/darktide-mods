#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <queue>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>
#endif

using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using i64 = std::int64_t;
using Bytes = std::vector<u8>;
using Hash8 = std::array<u8, 8>;
namespace fs = std::filesystem;

static constexpr const char *VERSION = "1.0.0-public";
static constexpr int STATE_SCHEMA = 2;
static constexpr const char *BASE_BUNDLE = "a2bbcc3451758add";
static constexpr const char *STORAGE_BASE_BUNDLE = "9ba626afa44a3aa3";
static constexpr size_t HEADER_BYTES = 268;
static constexpr size_t INDEX_RECORD_BYTES = 20;
static constexpr size_t MAX_INDEX_RECORDS = 65536;
static constexpr size_t PATCH_CHUNK_SIZE = 0x80000;
static constexpr u64 MAX_PATCH_PAYLOAD = 0xffffffffull;
static constexpr int PACKAGE_VERSION = 43;
static constexpr u8 PACKAGE_FOOTER = 1;
static constexpr size_t MATERIAL_HEADER_BYTES = 68;
static constexpr size_t MATERIAL_STREAM_PATH_OFFSET = 38;
static constexpr size_t MATERIAL_STREAM_PATH_BYTES = 30;
static constexpr const char *BUILD_FILENAME = "build.json";
static constexpr const char *GENERIC_PACKAGE_FILENAME = "custom_assets.package";
static constexpr const char *COMPILER_NAME = "DarktideGLBCompiler";
static constexpr int COMPILER_BUILD_SCHEMA = 1;

struct PatcherError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

struct JsonValue {
    enum Kind {
        Null,
        Boolean,
        Integer,
        Number,
        String,
        Array,
        Object,
    };

    Kind kind = Null;
    bool boolean = false;
    long long integer = 0;
    double number = 0.0;
    std::string string;
    std::vector<JsonValue> array;
    std::vector<std::pair<std::string, JsonValue>> object;

    static JsonValue null() {
        return {};
    }

    static JsonValue boolean_value(bool value) {
        JsonValue out;
        out.kind = Boolean;
        out.boolean = value;
        return out;
    }

    static JsonValue integer_value(long long value) {
        JsonValue out;
        out.kind = Integer;
        out.integer = value;
        return out;
    }

    static JsonValue number_value(double value) {
        JsonValue out;
        out.kind = Number;
        out.number = value;
        return out;
    }

    static JsonValue string_value(std::string value) {
        JsonValue out;
        out.kind = String;
        out.string = std::move(value);
        return out;
    }

    static JsonValue array_value() {
        JsonValue out;
        out.kind = Array;
        return out;
    }

    static JsonValue object_value() {
        JsonValue out;
        out.kind = Object;
        return out;
    }

    const JsonValue *get(const std::string &key) const {
        if (kind != Object) {
            return nullptr;
        }

        for (const auto &item : object) {
            if (item.first == key) {
                return &item.second;
            }
        }

        return nullptr;
    }

    JsonValue *get(const std::string &key) {
        if (kind != Object) {
            return nullptr;
        }

        for (auto &item : object) {
            if (item.first == key) {
                return &item.second;
            }
        }

        return nullptr;
    }

    void set(std::string key, JsonValue value) {
        if (kind != Object) {
            kind = Object;
            object.clear();
        }

        for (auto &item : object) {
            if (item.first == key) {
                item.second = std::move(value);
                return;
            }
        }

        object.emplace_back(std::move(key), std::move(value));
    }
};

static bool operator==(const JsonValue &a, const JsonValue &b) {
    if (a.kind != b.kind) {
        return false;
    }

    switch (a.kind) {
        case JsonValue::Null: return true;
        case JsonValue::Boolean: return a.boolean == b.boolean;
        case JsonValue::Integer: return a.integer == b.integer;
        case JsonValue::Number: return a.number == b.number;
        case JsonValue::String: return a.string == b.string;
        case JsonValue::Array: return a.array == b.array;
        case JsonValue::Object: return a.object == b.object;
    }

    return false;
}

class JsonParser {
public:
    explicit JsonParser(const std::string &source) : source(source) {
    }

    JsonValue parse() {
        skip_space();
        JsonValue value = parse_value();
        skip_space();

        if (pos != source.size()) {
            fail("unexpected trailing JSON data");
        }

        return value;
    }

private:
    const std::string &source;
    size_t pos = 0;

    [[noreturn]] void fail(const char *message) const {
        throw std::runtime_error(std::string(message) + " at byte " + std::to_string(pos));
    }

    void skip_space() {
        while (pos < source.size()) {
            const char c = source[pos];

            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') {
                break;
            }

            ++pos;
        }
    }

    bool take(char c) {
        if (pos < source.size() && source[pos] == c) {
            ++pos;
            return true;
        }

        return false;
    }

    void expect(char c) {
        if (!take(c)) {
            fail("unexpected JSON token");
        }
    }

    bool match(const char *text) {
        const size_t length = std::strlen(text);

        if (source.compare(pos, length, text) != 0) {
            return false;
        }

        pos += length;
        return true;
    }

    static void append_utf8(std::string &out, unsigned value) {
        if (value <= 0x7f) {
            out.push_back(static_cast<char>(value));
        } else if (value <= 0x7ff) {
            out.push_back(static_cast<char>(0xc0 | (value >> 6)));
            out.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        } else if (value <= 0xffff) {
            out.push_back(static_cast<char>(0xe0 | (value >> 12)));
            out.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        } else if (value <= 0x10ffff) {
            out.push_back(static_cast<char>(0xf0 | (value >> 18)));
            out.push_back(static_cast<char>(0x80 | ((value >> 12) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
            out.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        } else {
            throw std::runtime_error("invalid Unicode code point");
        }
    }

    unsigned parse_hex4() {
        if (pos + 4 > source.size()) {
            fail("truncated Unicode escape");
        }

        unsigned value = 0;

        for (int i = 0; i < 4; ++i) {
            const char c = source[pos++];
            value <<= 4;

            if (c >= '0' && c <= '9') {
                value |= static_cast<unsigned>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                value |= static_cast<unsigned>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                value |= static_cast<unsigned>(c - 'A' + 10);
            } else {
                fail("invalid Unicode escape");
            }
        }

        return value;
    }

    std::string parse_string() {
        expect('"');
        std::string out;

        while (pos < source.size()) {
            const unsigned char c = static_cast<unsigned char>(source[pos++]);

            if (c == '"') {
                return out;
            }

            if (c < 0x20) {
                fail("control character in JSON string");
            }

            if (c != '\\') {
                out.push_back(static_cast<char>(c));
                continue;
            }

            if (pos >= source.size()) {
                fail("truncated JSON escape");
            }

            const char escaped = source[pos++];

            switch (escaped) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    unsigned value = parse_hex4();

                    if (value >= 0xd800 && value <= 0xdbff) {
                        if (pos + 2 > source.size() || source[pos] != '\\' || source[pos + 1] != 'u') {
                            fail("unpaired UTF-16 surrogate");
                        }

                        pos += 2;
                        const unsigned low = parse_hex4();

                        if (low < 0xdc00 || low > 0xdfff) {
                            fail("invalid UTF-16 surrogate pair");
                        }

                        value = 0x10000 + ((value - 0xd800) << 10) + (low - 0xdc00);
                    } else if (value >= 0xdc00 && value <= 0xdfff) {
                        fail("unpaired UTF-16 surrogate");
                    }

                    append_utf8(out, value);
                    break;
                }
                default: fail("invalid JSON escape");
            }
        }

        fail("unterminated JSON string");
    }

    JsonValue parse_number() {
        const size_t start = pos;
        bool fractional = false;

        take('-');

        if (take('0')) {
        } else {
            if (pos >= source.size() || source[pos] < '1' || source[pos] > '9') {
                fail("invalid JSON number");
            }

            while (pos < source.size() && source[pos] >= '0' && source[pos] <= '9') {
                ++pos;
            }
        }

        if (take('.')) {
            fractional = true;

            if (pos >= source.size() || source[pos] < '0' || source[pos] > '9') {
                fail("invalid JSON number");
            }

            while (pos < source.size() && source[pos] >= '0' && source[pos] <= '9') {
                ++pos;
            }
        }

        if (pos < source.size() && (source[pos] == 'e' || source[pos] == 'E')) {
            fractional = true;
            ++pos;

            if (pos < source.size() && (source[pos] == '+' || source[pos] == '-')) {
                ++pos;
            }

            if (pos >= source.size() || source[pos] < '0' || source[pos] > '9') {
                fail("invalid JSON exponent");
            }

            while (pos < source.size() && source[pos] >= '0' && source[pos] <= '9') {
                ++pos;
            }
        }

        const std::string text = source.substr(start, pos - start);

        if (!fractional) {
            char *end = nullptr;
            errno = 0;
            const long long value = std::strtoll(text.c_str(), &end, 10);

            if (errno == 0 && end && *end == 0) {
                return JsonValue::integer_value(value);
            }
        }

        char *end = nullptr;
        errno = 0;
        const double value = std::strtod(text.c_str(), &end);

        if (errno != 0 || !end || *end != 0 || !std::isfinite(value)) {
            fail("invalid JSON number");
        }

        return JsonValue::number_value(value);
    }

    JsonValue parse_array() {
        expect('[');
        JsonValue out = JsonValue::array_value();
        skip_space();

        if (take(']')) {
            return out;
        }

        for (;;) {
            skip_space();
            out.array.push_back(parse_value());
            skip_space();

            if (take(']')) {
                return out;
            }

            expect(',');
        }
    }

    JsonValue parse_object() {
        expect('{');
        JsonValue out = JsonValue::object_value();
        skip_space();

        if (take('}')) {
            return out;
        }

        for (;;) {
            skip_space();

            if (pos >= source.size() || source[pos] != '"') {
                fail("JSON object key must be a string");
            }

            std::string key = parse_string();
            skip_space();
            expect(':');
            skip_space();
            out.set(std::move(key), parse_value());
            skip_space();

            if (take('}')) {
                return out;
            }

            expect(',');
        }
    }

    JsonValue parse_value() {
        if (pos >= source.size()) {
            fail("unexpected end of JSON");
        }

        switch (source[pos]) {
            case 'n':
                if (match("null")) return JsonValue::null();
                break;
            case 't':
                if (match("true")) return JsonValue::boolean_value(true);
                break;
            case 'f':
                if (match("false")) return JsonValue::boolean_value(false);
                break;
            case '"': return JsonValue::string_value(parse_string());
            case '[': return parse_array();
            case '{': return parse_object();
            default:
                if (source[pos] == '-' || (source[pos] >= '0' && source[pos] <= '9')) {
                    return parse_number();
                }
                break;
        }

        fail("invalid JSON value");
    }
};

static void json_escape(std::string &out, const std::string &value) {
    static const char hex[] = "0123456789abcdef";
    out.push_back('"');

    for (unsigned char c : value) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    out += "\\u00";
                    out.push_back(hex[c >> 4]);
                    out.push_back(hex[c & 15]);
                } else {
                    out.push_back(static_cast<char>(c));
                }
                break;
        }
    }

    out.push_back('"');
}

static void json_dump_value(std::string &out, const JsonValue &value, int level, int indent) {
    switch (value.kind) {
        case JsonValue::Null:
            out += "null";
            return;
        case JsonValue::Boolean:
            out += value.boolean ? "true" : "false";
            return;
        case JsonValue::Integer:
            out += std::to_string(value.integer);
            return;
        case JsonValue::Number: {
            std::ostringstream stream;
            stream << std::setprecision(17) << value.number;
            out += stream.str();
            return;
        }
        case JsonValue::String:
            json_escape(out, value.string);
            return;
        case JsonValue::Array:
            if (value.array.empty()) {
                out += "[]";
                return;
            }

            out += "[\n";

            for (size_t i = 0; i < value.array.size(); ++i) {
                out.append(static_cast<size_t>((level + 1) * indent), ' ');
                json_dump_value(out, value.array[i], level + 1, indent);
                out += i + 1 == value.array.size() ? "\n" : ",\n";
            }

            out.append(static_cast<size_t>(level * indent), ' ');
            out.push_back(']');
            return;
        case JsonValue::Object:
            if (value.object.empty()) {
                out += "{}";
                return;
            }

            out += "{\n";

            for (size_t i = 0; i < value.object.size(); ++i) {
                out.append(static_cast<size_t>((level + 1) * indent), ' ');
                json_escape(out, value.object[i].first);
                out += ": ";
                json_dump_value(out, value.object[i].second, level + 1, indent);
                out += i + 1 == value.object.size() ? "\n" : ",\n";
            }

            out.append(static_cast<size_t>(level * indent), ' ');
            out.push_back('}');
            return;
    }
}

static std::string json_dump(const JsonValue &value, int indent = 2) {
    std::string out;
    json_dump_value(out, value, 0, indent);
    out.push_back('\n');
    return out;
}

static JsonValue parse_json(const std::string &source) {
    return JsonParser(source).parse();
}


static std::string lower_ascii(std::string value) {
    for (char &c : value) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c + ('a' - 'A'));
        }
    }

    return value;
}

static bool starts_with(const std::string &value, const std::string &prefix) {
    return value.size() >= prefix.size() && value.compare(0, prefix.size(), prefix) == 0;
}

static bool ends_with(const std::string &value, const std::string &suffix) {
    return value.size() >= suffix.size() && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

static std::string path_text(const fs::path &path) {
#if defined(_WIN32)
    const std::wstring wide = path.wstring();
    if (wide.empty()) {
        return {};
    }

    const int needed = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), out.data(), needed, nullptr, nullptr);
    return out;
#else
    return path.string();
#endif
}
static std::string generic_path_text(const fs::path &path) {
    std::string out = path_text(path);
    std::replace(out.begin(), out.end(), '\\', '/');
    return out;
}


static u32 read_u32(const Bytes &data, size_t offset, const char *message = "truncated 32-bit field") {
    if (offset + 4 > data.size()) {
        throw PatcherError(message);
    }

    return static_cast<u32>(data[offset]) |
        (static_cast<u32>(data[offset + 1]) << 8) |
        (static_cast<u32>(data[offset + 2]) << 16) |
        (static_cast<u32>(data[offset + 3]) << 24);
}

static u64 read_u64(const Bytes &data, size_t offset, const char *message = "truncated 64-bit field") {
    if (offset + 8 > data.size()) {
        throw PatcherError(message);
    }

    u64 value = 0;

    for (size_t i = 0; i < 8; ++i) {
        value |= static_cast<u64>(data[offset + i]) << (i * 8);
    }

    return value;
}

static u32 read_u32(const u8 *data) {
    return static_cast<u32>(data[0]) |
        (static_cast<u32>(data[1]) << 8) |
        (static_cast<u32>(data[2]) << 16) |
        (static_cast<u32>(data[3]) << 24);
}

static void write_u32(Bytes &out, u32 value) {
    out.push_back(static_cast<u8>(value));
    out.push_back(static_cast<u8>(value >> 8));
    out.push_back(static_cast<u8>(value >> 16));
    out.push_back(static_cast<u8>(value >> 24));
}

static void write_u64(Bytes &out, u64 value) {
    for (size_t i = 0; i < 8; ++i) {
        out.push_back(static_cast<u8>(value >> (i * 8)));
    }
}

static void overwrite_u32(Bytes &out, size_t offset, u32 value) {
    if (offset + 4 > out.size()) {
        throw PatcherError("internal write_u32 offset is out of range");
    }

    out[offset] = static_cast<u8>(value);
    out[offset + 1] = static_cast<u8>(value >> 8);
    out[offset + 2] = static_cast<u8>(value >> 16);
    out[offset + 3] = static_cast<u8>(value >> 24);
}

static void append_bytes(Bytes &out, const Bytes &value) {
    out.insert(out.end(), value.begin(), value.end());
}

static void append_bytes(Bytes &out, const Hash8 &value) {
    out.insert(out.end(), value.begin(), value.end());
}

static Bytes slice_bytes(const Bytes &data, size_t start, size_t end) {
    if (start > end || end > data.size()) {
        throw PatcherError("byte slice is out of range");
    }

    return Bytes(data.begin() + static_cast<std::ptrdiff_t>(start), data.begin() + static_cast<std::ptrdiff_t>(end));
}

static Hash8 slice_hash8(const Bytes &data, size_t offset) {
    if (offset + 8 > data.size()) {
        throw PatcherError("truncated 64-bit hash field");
    }

    Hash8 out{};
    std::copy_n(data.begin() + static_cast<std::ptrdiff_t>(offset), 8, out.begin());
    return out;
}

static std::string hex_bytes(const u8 *data, size_t count, bool reverse = false) {
    static const char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(count * 2);

    for (size_t i = 0; i < count; ++i) {
        const size_t index = reverse ? count - i - 1 : i;
        const u8 value = data[index];
        out.push_back(hex[value >> 4]);
        out.push_back(hex[value & 15]);
    }

    return out;
}

static std::optional<u8> hex_digit(char c) {
    if (c >= '0' && c <= '9') return static_cast<u8>(c - '0');
    if (c >= 'a' && c <= 'f') return static_cast<u8>(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return static_cast<u8>(c - 'A' + 10);
    return std::nullopt;
}

static std::optional<Bytes> parse_hex(const std::string &value) {
    if ((value.size() & 1) != 0) {
        return std::nullopt;
    }

    Bytes out;
    out.reserve(value.size() / 2);

    for (size_t i = 0; i < value.size(); i += 2) {
        const auto hi = hex_digit(value[i]);
        const auto lo = hex_digit(value[i + 1]);

        if (!hi || !lo) {
            return std::nullopt;
        }

        out.push_back(static_cast<u8>((*hi << 4) | *lo));
    }

    return out;
}

static Bytes read_file(const fs::path &path) {
    std::ifstream file(path, std::ios::binary);

    if (!file) {
        throw PatcherError("could not read file: " + path_text(path));
    }

    file.seekg(0, std::ios::end);
    const std::streamoff size = file.tellg();

    if (size < 0) {
        throw PatcherError("could not determine file size: " + path_text(path));
    }

    file.seekg(0, std::ios::beg);
    Bytes out(static_cast<size_t>(size));

    if (!out.empty()) {
        file.read(reinterpret_cast<char *>(out.data()), static_cast<std::streamsize>(out.size()));

        if (!file) {
            throw PatcherError("could not read complete file: " + path_text(path));
        }
    }

    return out;
}

static std::string read_text_file(const fs::path &path) {
    const Bytes data = read_file(path);
    return std::string(reinterpret_cast<const char *>(data.data()), data.size());
}

static bool file_equals_bytes(const fs::path &path, const Bytes &data) {
    std::error_code ec;

    if (!fs::is_regular_file(path, ec) || ec) {
        return false;
    }

    if (fs::file_size(path, ec) != data.size() || ec) {
        return false;
    }

    std::ifstream file(path, std::ios::binary);

    if (!file) {
        return false;
    }

    std::vector<u8> buffer(1024 * 1024);
    size_t offset = 0;

    while (offset < data.size()) {
        const size_t count = std::min(buffer.size(), data.size() - offset);
        file.read(reinterpret_cast<char *>(buffer.data()), static_cast<std::streamsize>(count));

        if (file.gcount() != static_cast<std::streamsize>(count) ||
            !std::equal(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(count), data.begin() + static_cast<std::ptrdiff_t>(offset))) {
            return false;
        }

        offset += count;
    }

    return true;
}

static bool files_equal(const fs::path &left, const fs::path &right) {
    std::error_code ec;

    if (!fs::is_regular_file(left, ec) || ec) {
        return false;
    }

    const auto left_size = fs::file_size(left, ec);

    if (ec || !fs::is_regular_file(right, ec) || ec) {
        return false;
    }

    if (left_size != fs::file_size(right, ec) || ec) {
        return false;
    }

    std::ifstream a(left, std::ios::binary);
    std::ifstream b(right, std::ios::binary);

    if (!a || !b) {
        return false;
    }

    std::vector<char> ac(1024 * 1024);
    std::vector<char> bc(1024 * 1024);

    for (;;) {
        a.read(ac.data(), static_cast<std::streamsize>(ac.size()));
        b.read(bc.data(), static_cast<std::streamsize>(bc.size()));
        const std::streamsize an = a.gcount();
        const std::streamsize bn = b.gcount();

        if (an != bn || !std::equal(ac.begin(), ac.begin() + an, bc.begin())) {
            return false;
        }

        if (an == 0) {
            return true;
        }
    }
}

static fs::path temp_path_for(const fs::path &destination) {
    static u64 serial = 0;
    ++serial;
    return destination.parent_path() / ("." + path_text(destination.filename()) + "." + std::to_string(serial) + ".tmp");
}

static void atomic_write(const fs::path &path, const Bytes &data) {
    fs::create_directories(path.parent_path());
    const fs::path temp = temp_path_for(path);

    try {
        {
            std::ofstream file(temp, std::ios::binary | std::ios::trunc);

            if (!file) {
                throw PatcherError("could not create temporary file: " + path_text(temp));
            }

            if (!data.empty()) {
                file.write(reinterpret_cast<const char *>(data.data()), static_cast<std::streamsize>(data.size()));
            }

            file.flush();

            if (!file) {
                throw PatcherError("could not write temporary file: " + path_text(temp));
            }
        }

#if defined(_WIN32)
        HANDLE handle = CreateFileW(temp.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle != INVALID_HANDLE_VALUE) {
            FlushFileBuffers(handle);
            CloseHandle(handle);
        }

        if (!MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            throw PatcherError("could not replace file: " + path_text(path));
        }
#else
        std::error_code ec;
        fs::remove(path, ec);
        ec.clear();
        fs::rename(temp, path, ec);
        if (ec) {
            throw PatcherError("could not replace file: " + path_text(path) + ": " + ec.message());
        }
#endif
    } catch (...) {
        std::error_code ec;
        fs::remove(temp, ec);
        throw;
    }
}

static void atomic_copy(const fs::path &source, const fs::path &destination) {
    atomic_write(destination, read_file(source));
}

static u32 crc32_bytes(const u8 *data, size_t size, u32 crc = 0) {
    static u32 table[256]{};
    static bool initialized = false;

    if (!initialized) {
        for (u32 i = 0; i < 256; ++i) {
            u32 value = i;

            for (int bit = 0; bit < 8; ++bit) {
                value = (value >> 1) ^ (0xedb88320u & (0u - (value & 1u)));
            }

            table[i] = value;
        }

        initialized = true;
    }

    crc ^= 0xffffffffu;

    for (size_t i = 0; i < size; ++i) {
        crc = table[(crc ^ data[i]) & 0xffu] ^ (crc >> 8);
    }

    return crc ^ 0xffffffffu;
}

static std::string crc32_file(const fs::path &path) {
    std::ifstream file(path, std::ios::binary);

    if (!file) {
        throw PatcherError("could not read file for CRC32: " + path_text(path));
    }

    u32 crc = 0;
    std::vector<u8> buffer(1024 * 1024);

    for (;;) {
        file.read(reinterpret_cast<char *>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
        const size_t count = static_cast<size_t>(file.gcount());

        if (!count) {
            break;
        }

        crc = crc32_bytes(buffer.data(), count, crc);
    }

    std::ostringstream out;
    out << std::hex << std::setfill('0') << std::setw(8) << crc;
    return out.str();
}

static u64 murmur64(const u8 *data, size_t size) {
    static constexpr u64 m = 0xc6a4a7935bd1e995ull;
    static constexpr int r = 47;
    u64 h = static_cast<u64>(size) * m;
    size_t pos = 0;

    while (pos + 8 <= size) {
        u64 k = 0;

        for (int i = 0; i < 8; ++i) {
            k |= static_cast<u64>(data[pos + static_cast<size_t>(i)]) << (i * 8);
        }

        k *= m;
        k ^= k >> r;
        k *= m;
        h ^= k;
        h *= m;
        pos += 8;
    }

    if (pos < size) {
        u64 tail = 0;

        for (size_t i = 0; pos + i < size; ++i) {
            tail |= static_cast<u64>(data[pos + i]) << (i * 8);
        }

        h ^= tail;
        h *= m;
    }

    h ^= h >> r;
    h *= m;
    h ^= h >> r;
    return h;
}

static std::pair<Hash8, std::string> identity_hash(const std::string &value) {
    u64 numeric = 0;
    bool opaque = false;

    if (value.size() == 21 && value.compare(0, 4, "#ID[") == 0 && value.back() == ']') {
        const std::string hex = value.substr(4, 16);
        const auto parsed = parse_hex(hex);

        if (parsed && parsed->size() == 8) {
            numeric = 0;

            for (u8 byte : *parsed) {
                numeric = (numeric << 8) | byte;
            }

            opaque = true;
        }
    }

    if (!opaque) {
        numeric = murmur64(reinterpret_cast<const u8 *>(value.data()), value.size());
    }

    Hash8 bytes{};

    for (size_t i = 0; i < 8; ++i) {
        bytes[i] = static_cast<u8>(numeric >> (i * 8));
    }

    std::ostringstream out;
    out << std::hex << std::setfill('0') << std::setw(16) << std::nouppercase << numeric;
    return {bytes, out.str()};
}

static std::string murmur64_hex(const std::string &value) {
    return identity_hash(value).second;
}

struct ResourceSpec {
    std::string engine_type;
    std::string name;
    fs::path source;
    int mode = 0;
    bool host_unit_mode = false;
    std::optional<fs::path> stream_source;
    bool retail_stream_reference = false;

    std::string typed_key() const {
        return engine_type + std::string(1, '\0') + name;
    }
};

struct ExternalResource {
    std::string engine_type;
    std::string name;
    bool package_member = false;
};

struct AssetSpec {
    std::string logical_id;
    std::string owner;
    std::string asset_id;
    std::string kind;
    std::optional<std::string> unit_kind;
    fs::path source_path;
    std::string source_relative;
    std::string source_kind;
    std::string primary_engine_type;
    std::string primary_name;
    std::vector<ResourceSpec> resources;
    JsonValue metadata = JsonValue::object_value();
    std::vector<ExternalResource> external_resources;
    bool generated_package = false;
};

struct HostBundleMetadata {
    Bytes template_identity;
    Bytes type_data;
    int unit_mode = 0;
    u32 file_count = 0;
};

struct ValidatedResource {
    ResourceSpec spec;
    int mode = 0;
    Bytes blob;
    Hash8 type_hash_le{};
    Hash8 name_hash_le{};
    std::string type_hash_hex;
    std::string name_hash_hex;
    std::string stream_name;
};

struct BuildPayload {
    Bytes patch_bytes;
    std::vector<ValidatedResource> resources;
    std::map<std::string, fs::path> stream_sources;
};

struct TextureInfo {
    u32 kind = 0;
    u32 compressed_resident_bytes = 0;
    u32 resident_dds_bytes = 0;
    u32 body_flags = 0;
    u32 streamed_mips = 0;
    u32 width = 0;
    u32 height = 0;
    u32 chunk_count = 0;
    u32 compressed_stream_bytes = 0;
    u32 footer_word = 0;
    std::string stream_name;
};

static bool safe_data_stream(const std::string &value) {
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

static bool retail_stream(const std::string &value) {
    static const std::regex pattern(R"(^data/[0-9a-f]{2}/[0-9a-f]{16}(?:\.stream)?$)");
    return std::regex_match(lower_ascii(value), pattern);
}

struct CookedEnvelope {
    u32 kind = 0;
    u8 unknown1 = 0;
    u32 body_size = 0;
    u32 tail_size = 0;
    Bytes body;
    Bytes tail;
};

static CookedEnvelope inspect_cooked_envelope(const Bytes &blob) {
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

static std::string stream_name_from_tail(const Bytes &tail) {
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

static std::pair<std::string, u64> inspect_material_header(const Bytes &blob) {
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

static TextureInfo inspect_texture_body(const Bytes &blob) {
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

    if (body.size() < 12) {
        throw PatcherError("texture body is truncated");
    }

    TextureInfo out;
    out.kind = read_u32(body, 0);
    out.compressed_resident_bytes = read_u32(body, 4);
    out.resident_dds_bytes = read_u32(body, 8);
    size_t pos = 12ull + out.compressed_resident_bytes;

    if (out.kind != 1 || pos + 20 + 128 + 12 > body.size()) {
        throw PatcherError("texture body uses an unsupported or truncated family");
    }

    const u32 marker = read_u32(body, pos);
    out.body_flags = read_u32(body, pos + 4);
    out.streamed_mips = read_u32(body, pos + 8);
    out.width = read_u32(body, pos + 12);
    out.height = read_u32(body, pos + 16);
    pos += 20;

    if (marker != 67) {
        throw PatcherError("texture body marker is not 67");
    }

    pos += 128;
    const u32 meta_size = read_u32(body, pos);
    pos += 4;
    out.chunk_count = read_u32(body, pos);
    const u16 zero = static_cast<u16>(body[pos + 4] | (static_cast<u16>(body[pos + 5]) << 8));
    const u16 echoed = static_cast<u16>(body[pos + 6] | (static_cast<u16>(body[pos + 7]) << 8));
    pos += 8;

    if (zero != 0 || echoed != out.chunk_count || meta_size != 8 + 4 * out.chunk_count) {
        throw PatcherError("texture chunk metadata is inconsistent");
    }

    if (pos + 4ull * out.chunk_count + 4 != body.size()) {
        throw PatcherError("texture chunk table does not end at the footer");
    }

    u32 previous = 0;

    for (u32 i = 0; i < out.chunk_count; ++i) {
        const u32 end = read_u32(body, pos + static_cast<size_t>(i) * 4);

        if (end <= previous) {
            throw PatcherError("texture chunk offsets are not strictly increasing");
        }

        previous = end;
    }

    pos += static_cast<size_t>(out.chunk_count) * 4;
    out.compressed_stream_bytes = previous;
    out.footer_word = read_u32(body, pos);
    out.stream_name = stream_name;
    return out;
}

static HostBundleMetadata read_host_metadata(const fs::path &path) {
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

            if (spec.engine_type == "texture") {
                std::error_code ec;
                const u64 actual = fs::file_size(*spec.stream_source, ec);

                if (ec) {
                    throw PatcherError(path_text(spec.source) + ": could not stat texture stream " + path_text(*spec.stream_source));
                }

                if (actual != texture_info.compressed_stream_bytes) {
                    throw PatcherError(path_text(spec.source) + ": texture stream length mismatch: metadata=" + std::to_string(texture_info.compressed_stream_bytes) + ", file=" + std::to_string(actual));
                }
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

static BuildPayload build_payload(const std::vector<ResourceSpec> &resources, const HostBundleMetadata &metadata) {
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

struct PackageEntry {
    std::string engine_type;
    std::string name;

    std::string typed_key() const {
        return engine_type + std::string(1, '\0') + name;
    }
};

static std::string package_resource_name(const std::string &logical_id) {
    if (logical_id.empty()) {
        throw PatcherError("logical asset ID must be a non-empty string");
    }

    return "content/mods/custom_assets/packages/" + murmur64_hex(logical_id);
}

static std::vector<PackageEntry> normalize_entries(std::vector<PackageEntry> entries) {
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

static Bytes wrap_cooked(const std::string &engine_type, const std::string &name, const Bytes &body) {
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

static Bytes build_package_blob(const std::string &package_name, std::vector<PackageEntry> entries) {
    return wrap_cooked("package", package_name, build_package_body(std::move(entries)));
}

static std::vector<std::pair<Hash8, Hash8>> parse_package_blob(const Bytes &blob) {
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

    if (version != PACKAGE_VERSION) {
        throw PatcherError("unsupported package version " + std::to_string(version) + "; expected 43");
    }

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
static const std::vector<std::string> KNOWN_ENGINE_TYPES = {
    "animation", "animation_curves", "bik", "bk2", "blend_set", "bones", "chroma", "common_package",
    "config", "data", "entity", "flow", "font", "ies", "ini", "ivf", "keys", "level", "lua", "material",
    "mod", "mouse_cursor", "navdata", "network_config", "oodle_net", "package", "particles", "physics_properties",
    "render_config", "rt_pipeline", "scene", "shader", "shader_library", "shader_library_group", "shading_environment",
    "shading_environment_mapping", "slug", "slug_album", "state_machine", "strings", "texture", "theme", "tome", "unit",
    "vector_field", "wwise_bank", "wwise_dep", "wwise_event", "wwise_metadata", "wwise_stream",
};

static const std::array<const char *, 7> PRIMARY_PRIORITY = {
    "unit", "material", "texture", "animation", "bones", "state_machine", "particles",
};

static bool opaque_id(const std::string &value) {
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

static bool safe_engine_type(const std::string &value) {
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

static bool safe_resource_name_chars(const std::string &value) {
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

static bool safe_relative_segments(const std::string &value) {
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

static std::string require_string(const JsonValue *value, const std::string &field) {
    if (!value || value->kind != JsonValue::String || value->string.empty()) {
        throw PatcherError(field + " must be a non-empty string");
    }

    return value->string;
}


static std::string validate_id(const std::string &value, const std::string &field) {
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

static std::string validate_engine_type(const JsonValue *value, const std::string &field) {
    const std::string text = require_string(value, field);

    if (!safe_engine_type(text)) {
        throw PatcherError(field + " is not a valid engine type or #ID[16hex] identity");
    }

    return text;
}

static std::string validate_resource_name(std::string text, const std::string &field) {
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

static std::string validate_resource_name(const JsonValue *value, const std::string &field) {
    return validate_resource_name(require_string(value, field), field);
}

static fs::path safe_relative(const fs::path &base, std::string text, const std::string &field) {
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

static JsonValue read_json(const fs::path &path) {
    try {
        JsonValue value = parse_json(read_text_file(path));

        if (value.kind != JsonValue::Object) {
            throw PatcherError("manifest root must be an object: " + path_text(path));
        }

        return value;
    } catch (const PatcherError &) {
        throw;
    } catch (const std::exception &exc) {
        throw PatcherError("invalid JSON in " + path_text(path) + ": " + exc.what());
    }
}

static std::pair<std::string, std::string> json_key(const JsonValue *raw, const std::string &field) {
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

static bool eight_hex(const std::string &value) {
    if (value.size() != 8) return false;
    for (char c : value) if (!hex_digit(c)) return false;
    return true;
}

static fs::path verify_file_record(const fs::path &base, const JsonValue *raw, const std::string &field, bool allow_missing = false) {
    if (!raw || raw->kind != JsonValue::Object) {
        throw PatcherError(field + " must be an object");
    }

    const fs::path path = safe_relative(base, require_string(raw->get("path"), field + ".path"), field + ".path");
    const JsonValue *size_value = raw->get("size");
    const JsonValue *crc_value = raw->get("crc32");

    if (!size_value || size_value->kind != JsonValue::Integer || size_value->integer < 0) {
        throw PatcherError(field + ".size must be a non-negative integer");
    }

    if (!crc_value || crc_value->kind != JsonValue::String || !eight_hex(crc_value->string)) {
        throw PatcherError(field + ".crc32 must be exactly 8 hex characters");
    }

    std::error_code ec;

    if (!fs::is_regular_file(path, ec)) {
        if (allow_missing && !fs::exists(path, ec)) {
            return path;
        }
        throw PatcherError(field + ".path does not exist: " + path_text(path));
    }

    const u64 actual_size = fs::file_size(path, ec);

    if (ec || actual_size != static_cast<u64>(size_value->integer)) {
        throw PatcherError(field + ": size mismatch for " + path_text(path.filename()) + ": expected " + std::to_string(size_value->integer) + ", got " + std::to_string(actual_size));
    }

    const std::string actual_crc = crc32_file(path);

    if (lower_ascii(actual_crc) != lower_ascii(crc_value->string)) {
        throw PatcherError(field + ": CRC32 mismatch for " + path_text(path.filename()) + ": expected " + lower_ascii(crc_value->string) + ", got " + actual_crc);
    }

    return path;
}

static std::vector<std::pair<Hash8, Hash8>> verify_package_identity(const ResourceSpec &package, const fs::path &source, const Bytes *blob = nullptr) {
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

static std::vector<PackageEntry> direct_package_entries(const std::vector<ResourceSpec> &resources, const std::vector<ExternalResource> &external_resources) {
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

static ResourceSpec generated_package_resource(const fs::path &output, const std::string &package_name) {
    ResourceSpec package{"package", package_name, output, 0, false, std::nullopt, false};
    std::error_code ec;

    if (fs::exists(output, ec)) {
        if (!fs::is_regular_file(output, ec)) {
            throw PatcherError("generated package output is not a regular file: " + path_text(output));
        }

        try {
            verify_package_identity(package, output);
        } catch (const std::exception &exc) {
            throw PatcherError("refusing to overwrite reserved generated package path " + path_text(output) + ": " + exc.what());
        }
    }

    return package;
}

static void verify_generated_file_record(const JsonValue *raw, const std::string &field, const Bytes &blob) {
    if (!raw || raw->kind != JsonValue::Object) {
        throw PatcherError(field + " must be an object");
    }

    const JsonValue *size = raw->get("size");
    const JsonValue *crc = raw->get("crc32");

    if (!size || size->kind != JsonValue::Integer || size->integer < 0) {
        throw PatcherError(field + ".size must be a non-negative integer");
    }

    if (!crc || crc->kind != JsonValue::String || !eight_hex(crc->string)) {
        throw PatcherError(field + ".crc32 must be exactly 8 hex characters");
    }

    const u32 actual = crc32_bytes(blob.data(), blob.size());
    std::ostringstream out;
    out << std::hex << std::setfill('0') << std::setw(8) << actual;

    if (blob.size() != static_cast<size_t>(size->integer) || lower_ascii(out.str()) != lower_ascii(crc->string)) {
        throw PatcherError(field + ": deterministic package reconstruction does not match the compiler manifest (size " +
            std::to_string(blob.size()) + "/" + std::to_string(size->integer) + ", crc32 " + out.str() + "/" + lower_ascii(crc->string) + ")");
    }
}

static std::vector<ExternalResource> compiler_external_resources(const JsonValue &build, const fs::path &source) {
    const JsonValue *raw_refs = build.get("external_resources");

    if (!raw_refs) {
        return {};
    }

    if (raw_refs->kind != JsonValue::Array) {
        throw PatcherError(path_text(source) + ": external_resources must be an array");
    }

    std::map<std::pair<std::string, std::string>, bool> refs;

    for (size_t i = 0; i < raw_refs->array.size(); ++i) {
        const JsonValue &raw = raw_refs->array[i];
        const std::string prefix = path_text(source) + ": external_resources[" + std::to_string(i + 1) + "]";

        if (raw.kind != JsonValue::Object) {
            throw PatcherError(prefix + " must be an object");
        }

        const auto key = json_key(raw.get("key"), prefix + ".key");
        bool package_member = false;
        const JsonValue *member = raw.get("package_member");

        if (member) {
            if (member->kind != JsonValue::Boolean) {
                throw PatcherError(prefix + ".package_member must be boolean");
            }
            package_member = member->boolean;
        }

        refs[key] = refs[key] || package_member;
    }

    std::vector<ExternalResource> out;

    for (const auto &item : refs) {
        out.push_back({item.first.first, item.first.second, item.second});
    }

    return out;
}

static std::pair<std::string, std::string> compiler_primary(const JsonValue &build, const std::vector<ResourceSpec> &resources, const fs::path &source) {
    std::set<std::string> local;
    for (const auto &resource : resources) local.insert(resource.typed_key());
    const JsonValue *roots = build.get("roots");

    if (!roots || roots->kind != JsonValue::Array || roots->array.empty()) {
        throw PatcherError(path_text(source) + ": roots must be a non-empty array");
    }

    std::vector<std::pair<std::string, std::string>> parsed;

    for (size_t i = 0; i < roots->array.size(); ++i) {
        const auto key = json_key(&roots->array[i], path_text(source) + ": roots[" + std::to_string(i + 1) + "]");

        if (local.count(key.first + std::string(1, '\0') + key.second) == 0) {
            throw PatcherError(path_text(source) + ": roots[" + std::to_string(i + 1) + "] does not refer to an owned resource");
        }

        parsed.push_back(key);
    }

    for (const char *preferred : PRIMARY_PRIORITY) {
        for (const auto &key : parsed) {
            if (key.first == preferred) {
                return key;
            }
        }
    }

    return parsed.front();
}

static void validate_direct_package_membership(
    const ResourceSpec &package,
    const std::vector<ResourceSpec> &resources,
    const std::vector<ExternalResource> &external_resources,
    const fs::path &source,
    const Bytes *blob = nullptr
) {
    const auto actual = verify_package_identity(package, source, blob);
    std::set<std::pair<Hash8, Hash8>> expected;

    for (const auto &entry : direct_package_entries(resources, external_resources)) {
        expected.insert({identity_hash(entry.engine_type).first, identity_hash(entry.name).first});
    }

    std::set<std::pair<Hash8, Hash8>> actual_set(actual.begin(), actual.end());

    if (actual_set != expected || actual.size() != actual_set.size()) {
        std::vector<std::string> details;
        size_t missing = 0;
        size_t extra = 0;
        for (const auto &item : expected) if (!actual_set.count(item)) ++missing;
        for (const auto &item : actual_set) if (!expected.count(item)) ++extra;
        if (missing) details.push_back(std::to_string(missing) + " missing");
        if (extra) details.push_back(std::to_string(extra) + " extra");
        if (actual.size() != actual_set.size()) details.push_back("duplicate entries");
        std::string joined;
        for (size_t i = 0; i < details.size(); ++i) {
            if (i) joined += ", ";
            joined += details[i];
        }
        throw PatcherError(path_text(source) + ": native package membership does not match build.json (" + joined + ")");
    }
}

static std::optional<std::string> unit_kind_for(const std::string &kind, const std::vector<ResourceSpec> &resources) {
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

static bool known_kind(const std::string &kind) {
    return kind != "package" && std::find(KNOWN_ENGINE_TYPES.begin(), KNOWN_ENGINE_TYPES.end(), kind) != KNOWN_ENGINE_TYPES.end();
}

static AssetSpec parse_compiler_asset(const fs::path &custom_root, const std::string &owner, const fs::path &asset_dir, const JsonValue *provided = nullptr) {
    const fs::path build_path = asset_dir / BUILD_FILENAME;
    const JsonValue build = provided ? *provided : read_json(build_path);
    const JsonValue *schema = build.get("schema");

    if (!schema || schema->kind != JsonValue::Integer || schema->integer != COMPILER_BUILD_SCHEMA) {
        throw PatcherError(path_text(build_path) + ": unsupported compiler build schema");
    }

    const JsonValue *compiler = build.get("compiler");

    if (!compiler || compiler->kind != JsonValue::Object || !compiler->get("name") || compiler->get("name")->kind != JsonValue::String || compiler->get("name")->string != COMPILER_NAME) {
        throw PatcherError(path_text(build_path) + ": compiler.name must be 'DarktideGLBCompiler'");
    }

    const JsonValue *target = build.get("target");

    if (!target || target->kind != JsonValue::Object || !target->get("id") || target->get("id")->kind != JsonValue::String || target->get("id")->string != "darktide") {
        throw PatcherError(path_text(build_path) + ": compiler target must be 'darktide'");
    }

    const std::string asset_id = validate_id(path_text(asset_dir.filename()), path_text(build_path) + ": asset folder name");
    const JsonValue *resources_raw = build.get("resources");

    if (!resources_raw || resources_raw->kind != JsonValue::Array || resources_raw->array.empty()) {
        throw PatcherError(path_text(build_path) + ": resources must be a non-empty array");
    }

    std::vector<ResourceSpec> resources;
    std::set<std::string> local_keys;

    for (size_t i = 0; i < resources_raw->array.size(); ++i) {
        const JsonValue &item = resources_raw->array[i];
        const std::string prefix = path_text(build_path) + ": resources[" + std::to_string(i + 1) + "]";

        if (item.kind != JsonValue::Object) {
            throw PatcherError(prefix + " must be an object");
        }

        const auto key = json_key(item.get("key"), prefix + ".key");
        const fs::path source = verify_file_record(asset_dir, item.get("file"), prefix + ".file");
        std::optional<fs::path> stream_source;
        const JsonValue *stream = item.get("stream");

        if (stream && stream->kind != JsonValue::Null) {
            if (stream->kind != JsonValue::Object) {
                throw PatcherError(prefix + ".stream must be an object or null");
            }
            stream_source = verify_file_record(asset_dir, stream->get("file"), prefix + ".stream.file");
        }

        bool retail_reference = false;

        if (key.first == "material" && !stream_source) {
            try {
                retail_reference = retail_stream(inspect_material_header(read_file(source)).first);
            } catch (...) {
                retail_reference = false;
            }
        }

        ResourceSpec spec;
        spec.engine_type = key.first;
        spec.name = key.second;
        spec.source = source;
        spec.host_unit_mode = key.first == "unit";
        spec.stream_source = stream_source;
        spec.retail_stream_reference = retail_reference;

        if (!local_keys.insert(spec.typed_key()).second) {
            throw PatcherError(path_text(build_path) + ": duplicate resource identity " + spec.engine_type + "/" + spec.name);
        }

        resources.push_back(std::move(spec));
    }

    const std::vector<ExternalResource> external_resources = compiler_external_resources(build, build_path);
    const JsonValue *package_raw = build.get("package");
    bool generated_package = false;
    ResourceSpec package;

    if (!package_raw || package_raw->kind == JsonValue::Null) {
        const std::string package_name = package_resource_name(owner + ":" + asset_id);
        package = generated_package_resource(asset_dir / GENERIC_PACKAGE_FILENAME, package_name);
        const Bytes generated = build_package_blob(package_name, direct_package_entries(resources, external_resources));
        validate_direct_package_membership(package, resources, external_resources, build_path, &generated);
        generated_package = true;
    } else {
        if (package_raw->kind != JsonValue::Object) {
            throw PatcherError(path_text(build_path) + ": package must be an object or null");
        }

        const auto package_key = json_key(package_raw->get("key"), path_text(build_path) + ": package.key");

        if (package_key.first != "package") {
            throw PatcherError(path_text(build_path) + ": package.key.type must be 'package'");
        }

        const JsonValue *package_file = package_raw->get("file");
        const fs::path package_source = verify_file_record(asset_dir, package_file, path_text(build_path) + ": package.file", true);
        package = ResourceSpec{"package", package_key.second, package_source, 0, false, std::nullopt, false};

        std::error_code ec;
        if (fs::is_regular_file(package_source, ec)) {
            validate_direct_package_membership(package, resources, external_resources, build_path);
        } else {
            const Bytes generated = build_package_blob(package.name, direct_package_entries(resources, external_resources));
            verify_generated_file_record(package_file, path_text(build_path) + ": package.file", generated);
            validate_direct_package_membership(package, resources, external_resources, build_path, &generated);
            generated_package = true;
        }
    }

    const auto primary = compiler_primary(build, resources, build_path);
    const std::string kind = known_kind(primary.first) ? primary.first : "generic";
    std::error_code ec;
    std::string source_relative = generic_path_text(fs::relative(build_path, custom_root, ec));
    if (ec) source_relative = path_text(build_path.filename());

    JsonValue metadata = JsonValue::object_value();
    metadata.set("compiler", *compiler);
    metadata.set("target", *target);
    const JsonValue *compiler_asset_id = build.get("asset_id");
    if (compiler_asset_id && compiler_asset_id->kind == JsonValue::String && !compiler_asset_id->string.empty()) {
        metadata.set("compiler_asset_id", *compiler_asset_id);
    }

    resources.push_back(package);
    AssetSpec out;
    out.logical_id = owner + ":" + asset_id;
    out.owner = owner;
    out.asset_id = asset_id;
    out.kind = kind;
    out.unit_kind = unit_kind_for(kind, resources);
    out.source_path = build_path;
    out.source_relative = source_relative;
    out.source_kind = "compiler";
    out.primary_engine_type = primary.first;
    out.primary_name = primary.second;
    out.resources = std::move(resources);
    out.metadata = std::move(metadata);
    out.external_resources = external_resources;
    out.generated_package = generated_package;
    return out;
}

static std::string opaque_hash(const Hash8 &hash) {
    return "#ID[" + hex_bytes(hash.data(), hash.size(), true) + "]";
}

static std::string recover_resource_name(const fs::path &asset_dir, const fs::path &path, const Hash8 &name_hash) {
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

static std::optional<CookedHeader> read_cooked_header(const fs::path &path) {
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

static std::vector<fs::path> generic_files(const fs::path &asset_dir) {
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

static std::optional<fs::path> find_owned_stream(
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

static AssetSpec parse_generic_asset(const fs::path &custom_root, const std::string &owner, const fs::path &asset_dir) {
    const std::string asset_id = validate_id(path_text(asset_dir.filename()), path_text(asset_dir) + ": asset folder name");
    const auto files = generic_files(asset_dir);
    std::map<std::string, fs::path> by_relative;
    std::map<std::string, std::vector<fs::path>> by_name;

    for (const auto &path : files) {
        std::error_code ec;
        const std::string relative = lower_ascii(generic_path_text(fs::relative(path, asset_dir, ec)));
        by_relative[relative] = path;
        by_name[lower_ascii(generic_path_text(path.filename()))].push_back(path);
    }

    std::map<Hash8, std::string> known_type_by_hash;
    for (const auto &type : KNOWN_ENGINE_TYPES) known_type_by_hash[identity_hash(type).first] = type;
    std::vector<ResourceSpec> candidates;
    int ignored_cooked_packages = 0;

    for (const auto &path : files) {
        if (lower_ascii(path_text(path.filename())) == lower_ascii(GENERIC_PACKAGE_FILENAME)) continue;
        const auto inspected = read_cooked_header(path);
        if (!inspected) continue;
        const auto known = known_type_by_hash.find(inspected->type_hash);
        const std::string engine_type = known == known_type_by_hash.end() ? opaque_hash(inspected->type_hash) : known->second;

        if (engine_type == "package") {
            ++ignored_cooked_packages;
            continue;
        }

        const std::string name = recover_resource_name(asset_dir, path, inspected->name_hash);
        std::optional<fs::path> stream_source;
        bool retail_reference = false;

        if (!inspected->stream_name.empty()) {
            const std::string normalized = inspected->stream_name;
            if (normalized.find('\\') != std::string::npos) {
                throw PatcherError(path_text(path) + ": stream names must use forward slashes: " + normalized);
            }
            const bool safe_owned = safe_data_stream(normalized);
            if (safe_owned) stream_source = find_owned_stream(asset_dir, normalized, by_relative, by_name, &path);
            if (!stream_source && engine_type == "material" && retail_stream(normalized)) {
                retail_reference = true;
            } else if (!stream_source) {
                if (!safe_owned) throw PatcherError(path_text(path) + ": external stream '" + normalized + "' is not a safe relative data/... stream");
                throw PatcherError(path_text(path) + ": declares owned stream '" + normalized + "', but no matching file exists in the folder");
            }
        }

        ResourceSpec spec;
        spec.engine_type = engine_type;
        spec.name = name;
        spec.source = path;
        spec.host_unit_mode = engine_type == "unit";
        spec.stream_source = stream_source;
        spec.retail_stream_reference = retail_reference;
        candidates.push_back(std::move(spec));
    }

    std::set<fs::path> stream_paths;
    for (const auto &resource : candidates) if (resource.stream_source) stream_paths.insert(fs::weakly_canonical(*resource.stream_source));
    std::vector<ResourceSpec> resources;
    for (const auto &resource : candidates) if (!stream_paths.count(fs::weakly_canonical(resource.source))) resources.push_back(resource);
    const int ignored_stream_candidates = static_cast<int>(candidates.size() - resources.size());
    std::set<std::string> seen_keys;
    for (const auto &spec : resources) {
        if (!seen_keys.insert(spec.typed_key()).second) throw PatcherError(path_text(asset_dir) + ": duplicate cooked resource identity " + spec.engine_type + "/" + spec.name);
    }
    if (resources.empty()) throw PatcherError(path_text(asset_dir) + ": no Darktide-compatible cooked resources were found");

    const std::string package_name = package_resource_name(owner + ":" + asset_id);
    ResourceSpec package = generated_package_resource(asset_dir / GENERIC_PACKAGE_FILENAME, package_name);
    const Bytes generated = build_package_blob(package_name, direct_package_entries(resources, {}));
    validate_direct_package_membership(package, resources, {}, asset_dir, &generated);
    const ResourceSpec *primary = nullptr;
    for (const char *preferred : PRIMARY_PRIORITY) {
        auto it = std::find_if(resources.begin(), resources.end(), [&](const ResourceSpec &item) { return item.engine_type == preferred; });
        if (it != resources.end()) { primary = &*it; break; }
    }
    if (!primary) primary = &resources.front();
    const std::string primary_type = primary->engine_type;
    const std::string primary_name = primary->name;
    const std::string kind = known_kind(primary_type) ? primary_type : "generic";
    std::error_code ec;
    std::string source_relative = generic_path_text(fs::relative(asset_dir, custom_root, ec));
    if (ec) source_relative = path_text(asset_dir.filename());
    JsonValue metadata = JsonValue::object_value();
    metadata.set("discovery", JsonValue::string_value("cooked_folder"));
    metadata.set("ignored_existing_package_resources", JsonValue::integer_value(ignored_cooked_packages));
    metadata.set("ignored_stream_files_that_look_cooked", JsonValue::integer_value(ignored_stream_candidates));
    resources.push_back(package);

    AssetSpec out;
    out.logical_id = owner + ":" + asset_id;
    out.owner = owner;
    out.asset_id = asset_id;
    out.kind = kind;
    out.unit_kind = unit_kind_for(kind, resources);
    out.source_path = asset_dir;
    out.source_relative = source_relative;
    out.source_kind = "folder";
    out.primary_engine_type = primary_type;
    out.primary_name = primary_name;
    out.resources = std::move(resources);
    out.metadata = std::move(metadata);
    out.generated_package = true;
    return out;
}

static std::pair<Hash8, Hash8> resource_hash_key(const std::string &engine_type, const std::string &name) {
    return {identity_hash(engine_type).first, identity_hash(name).first};
}

static std::map<std::pair<Hash8, Hash8>, std::string> validate_unique_assets(const std::vector<AssetSpec> &assets) {
    std::set<std::string> logical_ids;
    std::map<std::string, std::string> typed_owners;
    std::map<std::pair<Hash8, Hash8>, std::pair<std::string, std::string>> resource_owners;
    std::map<Hash8, std::string> package_owners;

    for (const auto &asset : assets) {
        if (!logical_ids.insert(asset.logical_id).second) throw PatcherError("duplicate logical asset ID: " + asset.logical_id);
        for (const auto &resource : asset.resources) {
            if (resource.engine_type == "package") {
                const Hash8 hash = identity_hash(resource.name).first;
                const auto previous = package_owners.find(hash);
                if (previous != package_owners.end()) throw PatcherError("duplicate package identity " + resource.name + " in " + previous->second + " and " + asset.logical_id);
                package_owners[hash] = asset.logical_id;
                continue;
            }
            const auto typed = typed_owners.find(resource.typed_key());
            if (typed != typed_owners.end()) throw PatcherError("duplicate typed resource identity " + resource.engine_type + "/" + resource.name + " in " + typed->second + " and " + asset.logical_id);
            typed_owners[resource.typed_key()] = asset.logical_id;
            const auto key = resource_hash_key(resource.engine_type, resource.name);
            const auto hashed = resource_owners.find(key);
            if (hashed != resource_owners.end()) throw PatcherError("resource hash collision between " + hashed->second.second + " in " + hashed->second.first + " and " + resource.engine_type + "/" + resource.name + " in " + asset.logical_id);
            resource_owners[key] = {asset.logical_id, resource.typed_key()};
        }
    }

    std::map<std::pair<Hash8, Hash8>, std::string> out;
    for (const auto &item : resource_owners) out[item.first] = item.second.first;
    return out;
}

static std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> runtime_package_definitions(const std::vector<AssetSpec> &assets) {
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

static std::map<fs::path, Bytes> generated_package_outputs(const std::vector<AssetSpec> &assets) {
    std::map<fs::path, Bytes> outputs;

    for (const auto &asset : assets) {
        if (!asset.generated_package) continue;
        const auto package_it = std::find_if(asset.resources.begin(), asset.resources.end(), [](const ResourceSpec &r) { return r.engine_type == "package"; });
        if (package_it == asset.resources.end()) continue;
        const Bytes blob = build_package_blob(package_it->name, direct_package_entries(asset.resources, asset.external_resources));
        const auto previous = outputs.find(package_it->source);
        if (previous != outputs.end() && previous->second != blob) throw PatcherError("conflicting generated package output: " + path_text(package_it->source));
        outputs[package_it->source] = blob;
    }

    return outputs;
}

static std::vector<AssetSpec> scan_cooked_packages(const fs::path &game_root) {
    const fs::path mods_root = game_root / "mods";
    std::error_code ec;
    if (!fs::is_directory(mods_root, ec)) throw PatcherError("mods directory not found: " + path_text(mods_root));
    std::vector<std::pair<std::string, fs::path>> roots;
    std::vector<fs::path> mod_dirs;
    for (const auto &entry : fs::directory_iterator(mods_root)) if (entry.is_directory()) mod_dirs.push_back(entry.path());
    std::sort(mod_dirs.begin(), mod_dirs.end(), [](const fs::path &a, const fs::path &b) { return lower_ascii(path_text(a.filename())) < lower_ascii(path_text(b.filename())); });

    for (const auto &mod_dir : mod_dirs) {
        const std::string owner = path_text(mod_dir.filename());
        if (lower_ascii(owner) == "customassets" || starts_with(owner, "_")) continue;
        if (!fs::is_regular_file(mod_dir / (owner + ".mod"), ec)) continue;
        roots.push_back({owner, mod_dir / "Custom"});
    }

    std::vector<AssetSpec> assets;
    for (const auto &root : roots) {
        if (!fs::is_directory(root.second, ec)) continue;
        std::vector<fs::path> dirs;
        for (const auto &entry : fs::directory_iterator(root.second)) if (entry.is_directory()) dirs.push_back(entry.path());
        std::sort(dirs.begin(), dirs.end(), [](const fs::path &a, const fs::path &b) { return lower_ascii(path_text(a.filename())) < lower_ascii(path_text(b.filename())); });
        for (const auto &asset_dir : dirs) {
            if (fs::is_symlink(asset_dir, ec)) throw PatcherError(path_text(root.second) + ": symlink asset folders are not supported: " + path_text(asset_dir));
            const fs::path build_path = asset_dir / BUILD_FILENAME;
            if (fs::is_regular_file(build_path, ec)) {
                JsonValue raw = read_json(build_path);
                const JsonValue *compiler = raw.get("compiler");
                if (compiler && compiler->kind == JsonValue::Object) {
                    const JsonValue *name = compiler->get("name");
                    if (name && name->kind == JsonValue::String && name->string == COMPILER_NAME) {
                        assets.push_back(parse_compiler_asset(root.second, root.first, asset_dir, &raw));
                        continue;
                    }
                }
            }
            assets.push_back(parse_generic_asset(root.second, root.first, asset_dir));
        }
    }

    const auto resource_owners = validate_unique_assets(assets);
    for (const auto &asset : assets) {
        for (const auto &external : asset.external_resources) {
            const auto key = resource_hash_key(external.engine_type, external.name);
            if (starts_with(external.name, "content/mods/custom_assets/") && !resource_owners.count(key)) {
                throw PatcherError(path_text(asset.source_path) + ": missing custom dependency " + external.engine_type + "/" + external.name);
            }
        }
    }
    runtime_package_definitions(assets);
    std::sort(assets.begin(), assets.end(), [](const AssetSpec &a, const AssetSpec &b) { return lower_ascii(a.logical_id) < lower_ascii(b.logical_id); });
    return assets;
}
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

static Hash8 bundle_hash_le(const std::string &bundle_name) {
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

static int boot_registration_count(const Bytes &data) {
    const std::string patch_name = std::string(STORAGE_BASE_BUNDLE) + ".patch_998";
    const std::string stream_name = std::string(STORAGE_BASE_BUNDLE) + ".stream.patch_998";
    int count = 0;
    for (const auto &entry : parse_record(data, STORAGE_BASE_BUNDLE).entries) if (entry.name == patch_name && entry.stream_name == stream_name) ++count;
    return count;
}

static Bytes ensure_boot_registration(const Bytes &data) {
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
    if (version != 6) throw PatcherError("unsupported bundle database version " + std::to_string(version) + "; expected 6");
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

static int bundle_registration_count(const Bytes &data, const std::string &bundle_name) {
    const Hash8 hash = bundle_hash_le(bundle_name);
    int count = 0;
    for (const auto &record : parse_bundle_table(data).records) if (record.name_hash_le == hash) ++count;
    return count;
}

static std::set<std::string> recover_generated_bundle_ownership(const Bytes &data, const std::vector<std::string> &desired_bundles) {
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

static std::set<std::string> recover_generated_package_ownership(const Bytes &data, const std::vector<std::string> &desired_packages) {
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

struct ReconcileResult {
    Bytes data;
    int added = 0;
    int updated = 0;
    int removed = 0;
};

static ReconcileResult reconcile_bundle_registrations(
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

static std::optional<std::vector<std::pair<Hash8, Hash8>>> package_members(const Bytes &data, const std::string &package_name) {
    const Hash8 hash = identity_hash(package_name).first;
    for (const auto &record : parse_package_table(data).records) if (record.name_hash_le == hash) return record.entries;
    return std::nullopt;
}

static ReconcileResult reconcile_package_registrations(
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
static void write_file(const fs::path &path, const Bytes &data) {
    fs::create_directories(path.parent_path());
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) throw PatcherError("could not create file: " + path_text(path));
    if (!data.empty()) file.write(reinterpret_cast<const char *>(data.data()), static_cast<std::streamsize>(data.size()));
    if (!file) throw PatcherError("could not write file: " + path_text(path));
}

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

static u32 texture_compressor_kind(const fs::path &path) {
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

static void transcode_kind0_texture(
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

static std::vector<AssetSpec> prepare_texture_resources(const fs::path &game_root, const std::vector<AssetSpec> &assets, const fs::path &stage_root) {
    std::vector<AssetSpec> prepared = assets;
    std::unique_ptr<DarktideOodleTextureCodec> codec;
    int converted = 0;

    for (size_t asset_index = 0; asset_index < prepared.size(); ++asset_index) {
        for (size_t resource_index = 0; resource_index < prepared[asset_index].resources.size(); ++resource_index) {
            ResourceSpec &resource = prepared[asset_index].resources[resource_index];
            if (resource.engine_type != "texture") continue;
            const u32 kind = texture_compressor_kind(resource.source);
            if (kind != 0) continue;
            if (!resource.stream_source) throw PatcherError(path_text(resource.source) + ": kind-0 texture staging resource is missing its owned stream");
            if (!codec) codec = std::make_unique<DarktideOodleTextureCodec>(game_root / "binaries" / "oo2core_9_win64.dll");
            std::ostringstream folder;
            folder << std::setfill('0') << std::setw(4) << asset_index << "_" << std::setw(4) << resource_index;
            const fs::path target_dir = stage_root / "prepared_textures" / folder.str();
            const fs::path texture_target = target_dir / resource.source.filename();
            const fs::path stream_target = target_dir / resource.stream_source->filename();
            transcode_kind0_texture(resource.source, *resource.stream_source, texture_target, stream_target, *codec);
            resource.source = texture_target;
            resource.stream_source = stream_target;
            ++converted;
        }
    }

    if (converted) std::cout << "Prepared " << converted << " creator-owned texture resource(s) with Darktide's installed Oodle DLL.\n";
    return prepared;
}

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

static JsonValue build_manifest(
    const fs::path &game_root,
    const std::vector<AssetSpec> &assets,
    const BuildPayload &payload,
    const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &package_definitions,
    size_t bundle_count
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
    manifest.set("custom_assets_version", JsonValue::string_value(VERSION));
    manifest.set("patch", std::move(patch));
    manifest.set("dependency_graph", dependency_graph(assets));
    manifest.set("assets", std::move(asset_rows));
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

static Bytes json_bytes(const JsonValue &manifest) {
    return string_bytes(json_dump(manifest, 2));
}

static Bytes lua_bytes(const JsonValue &manifest) {
    return string_bytes("-- Generated by CUSTOM_ASSETS_PATCH.bat. Do not edit by hand.\nreturn " + lua_dump(manifest) + "\n");
}
struct Layout {
    fs::path mod_root;
    fs::path db;
    fs::path format_base;
    fs::path storage_base;
    fs::path manifest_json;
    fs::path manifest_lua;
    fs::path state;
    fs::path log;
};

static Layout paths(const fs::path &game_root) {
    const fs::path mod_root = game_root / "mods" / "CustomAssets";
    const fs::path bundle_root = game_root / "bundle";
    return {
        mod_root,
        bundle_root / "bundle_database.data",
        bundle_root / BASE_BUNDLE,
        bundle_root / STORAGE_BASE_BUNDLE,
        mod_root / "generated" / "custom_assets_manifest.json",
        mod_root / "generated" / "manifest.lua",
        mod_root / "generated" / "install_state.json",
        mod_root / "generated" / "last_patch.log",
    };
}

static fs::path executable_path() {
#if defined(_WIN32)
    std::wstring buffer(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (!length || length >= buffer.size()) throw PatcherError("could not determine patcher executable path");
    buffer.resize(length);
    return fs::weakly_canonical(fs::path(buffer));
#else
    std::error_code ec;
    fs::path path = fs::read_symlink("/proc/self/exe", ec);
    if (ec) path = fs::current_path() / "mods" / "CustomAssets" / "tools" / "custom-assets-patcher";
    return fs::weakly_canonical(path);
#endif
}

static fs::path infer_game_root() {
    fs::path path = executable_path();
    for (int i = 0; i < 4; ++i) path = path.parent_path();
    return fs::weakly_canonical(path);
}

static Layout require_layout(const fs::path &game_root) {
    Layout layout = paths(game_root);
    for (const fs::path *path : {&layout.db, &layout.format_base, &layout.storage_base}) {
        if (!fs::is_regular_file(*path)) throw PatcherError("required Darktide bundle file not found: " + path_text(*path));
    }
    if (!fs::is_directory(layout.mod_root)) throw PatcherError("CustomAssets mod folder not found: " + path_text(layout.mod_root));
    const std::string patch_name = std::string(STORAGE_BASE_BUNDLE) + ".patch_999";
    const std::string stream_name = std::string(STORAGE_BASE_BUNDLE) + ".stream.patch_999";
    const BundleRecord record = parse_record(read_file(layout.db), STORAGE_BASE_BUNDLE);
    int matches = 0;
    for (const auto &entry : record.entries) if (entry.name == patch_name && entry.stream_name == stream_name) ++matches;
    if (matches != 1) throw PatcherError("Darktide Mod Loader patch_999 is not registered exactly once. Run the normal mod-loader patch before Custom Assets.");
    return layout;
}

static bool game_is_running() {
#if defined(_WIN32)
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) throw PatcherError("could not check whether Darktide.exe is running");
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    bool running = false;
    if (Process32FirstW(snapshot, &entry)) {
        do {
            std::wstring name = entry.szExeFile;
            std::transform(name.begin(), name.end(), name.begin(), [](wchar_t c) { return c >= L'A' && c <= L'Z' ? static_cast<wchar_t>(c + (L'a' - L'A')) : c; });
            if (name == L"darktide.exe") { running = true; break; }
        } while (Process32NextW(snapshot, &entry));
    } else {
        CloseHandle(snapshot);
        throw PatcherError("could not enumerate processes while checking Darktide.exe");
    }
    CloseHandle(snapshot);
    return running;
#else
    return false;
#endif
}

static JsonValue empty_state() {
    JsonValue state = JsonValue::object_value();
    state.set("schema", JsonValue::integer_value(STATE_SCHEMA));
    state.set("bundles", JsonValue::array_value());
    state.set("packages", JsonValue::array_value());
    state.set("streams", JsonValue::array_value());
    return state;
}

static std::vector<std::string> state_strings(const JsonValue &state, const char *key, const fs::path &path) {
    const JsonValue *value = state.get(key);
    if (!value || value->kind != JsonValue::Array) throw PatcherError("installed state " + std::string(key) + " field is invalid: " + path_text(path));
    std::vector<std::string> out;
    for (const auto &item : value->array) {
        if (item.kind != JsonValue::String) throw PatcherError("installed state " + std::string(key) + " field is invalid: " + path_text(path));
        out.push_back(item.string);
    }
    return out;
}

static void validate_state_ownership(const JsonValue &state, const fs::path &path) {
    const auto bundles = state_strings(state, "bundles", path);
    const auto packages = state_strings(state, "packages", path);
    const auto streams = state_strings(state, "streams", path);
    std::set<std::string> bundle_names;
    for (const auto &value : bundles) {
        bool valid = value.size() == 16 && value == lower_ascii(value);
        for (char c : value) valid = valid && static_cast<bool>(hex_digit(c));
        if (!valid) throw PatcherError("installed state contains an invalid managed bundle identity: " + value);
        bundle_names.insert(value);
    }
    std::set<std::string> expected_bundles;
    for (const auto &value : packages) {
        bool valid = !value.empty() && value.size() <= 4096;
        for (unsigned char c : value) valid = valid && c >= 32;
        if (!valid) throw PatcherError("installed state contains an invalid managed package name: " + value);
        expected_bundles.insert(identity_hash(value).second);
    }
    if (bundle_names != expected_bundles) throw PatcherError("installed state bundle ownership does not exactly match its generated package identities");
    for (const auto &value : streams) if (!safe_data_stream(value)) throw PatcherError("installed state contains an invalid managed stream path: " + value);
}

static JsonValue load_state(const fs::path &path) {
    if (!fs::is_regular_file(path)) return empty_state();
    JsonValue state;
    try {
        state = parse_json(read_text_file(path));
    } catch (const std::exception &exc) {
        throw PatcherError("installed state is unreadable: " + path_text(path) + ": " + exc.what());
    }
    const JsonValue *schema = state.get("schema");
    if (state.kind != JsonValue::Object || !schema || schema->kind != JsonValue::Integer || schema->integer != STATE_SCHEMA) {
        throw PatcherError("unsupported install_state.json schema in " + path_text(path) + ". This public build does not migrate pre-public state automatically.");
    }
    validate_state_ownership(state, path);
    return state;
}

static std::vector<ResourceSpec> payload_resources(const std::vector<AssetSpec> &assets) {
    std::vector<ResourceSpec> out;
    for (const auto &asset : assets) for (const auto &resource : asset.resources) if (resource.engine_type != "package") out.push_back(resource);
    return out;
}

static std::map<std::string, BuildPayload> build_asset_bundles(
    const std::vector<AssetSpec> &assets,
    const HostBundleMetadata &metadata,
    const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &definitions
) {
    std::map<std::string, BuildPayload> bundles;
    for (const auto &asset : assets) {
        const auto package = std::find_if(asset.resources.begin(), asset.resources.end(), [](const ResourceSpec &r) { return r.engine_type == "package"; });
        if (package == asset.resources.end()) throw PatcherError("asset has no package resource: " + asset.logical_id);
        if (!definitions.count(package->name)) throw PatcherError("missing runtime package definition for " + package->name);
        std::vector<ResourceSpec> specs;
        for (const auto &resource : asset.resources) if (resource.engine_type != "package") specs.push_back(resource);
        const std::string bundle_name = identity_hash(package->name).second;
        if (bundles.count(bundle_name)) throw PatcherError("generated package bundle collision: " + bundle_name);
        bundles[bundle_name] = build_payload(specs, metadata);
    }
    return bundles;
}

static bool bundle_contains_identity(const fs::path &path, const std::string &engine_type, const std::string &name) {
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

static Bytes extract_bundle_resource(const fs::path &path, const std::string &engine_type, const std::string &name, DarktideOodleTextureCodec &codec) {
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

static Bytes extend_boot_package(Bytes blob, const std::vector<ResourceSpec> &packages) {
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

static BuildPayload build_boot_carrier(const fs::path &game_root, const std::vector<AssetSpec> &assets, const std::map<fs::path, Bytes> &package_outputs, const fs::path &stage_root, const HostBundleMetadata &metadata) {
    const fs::path storage_base = game_root / "bundle" / STORAGE_BASE_BUNDLE;
    const fs::path dml_patch = game_root / "bundle" / (std::string(STORAGE_BASE_BUNDLE) + ".patch_999");
    if (!fs::is_regular_file(dml_patch)) throw PatcherError("Darktide Mod Loader patch_999 file is missing");
    if (bundle_contains_identity(dml_patch, "package", "packages/boot_assets")) throw PatcherError("Darktide Mod Loader patch_999 overrides packages/boot_assets");
    DarktideOodleTextureCodec codec(game_root / "binaries" / "oo2core_9_win64.dll");
    std::vector<ResourceSpec> packages;
    for (const auto &asset : assets) {
        const auto it = std::find_if(asset.resources.begin(), asset.resources.end(), [](const ResourceSpec &r) { return r.engine_type == "package"; });
        if (it == asset.resources.end()) throw PatcherError("asset has no package resource: " + asset.logical_id);
        ResourceSpec package = *it;
        const auto generated = package_outputs.find(package.source);
        if (generated != package_outputs.end()) {
            package.source = stage_root / (murmur64_hex(package.name) + ".package");
            write_file(package.source, generated->second);
        }
        packages.push_back(std::move(package));
    }
    if (packages.empty()) throw PatcherError("boot carrier has no package resources");
    const Bytes original = extract_bundle_resource(storage_base, "package", "packages/boot_assets", codec);
    const Bytes extended = extend_boot_package(original, packages);
    const fs::path boot_path = stage_root / "packages_boot_assets.package";
    write_file(boot_path, extended);
    ResourceSpec boot;
    boot.engine_type = "package";
    boot.name = "packages/boot_assets";
    boot.source = boot_path;
    boot.mode = 0;
    packages.push_back(std::move(boot));
    BuildPayload carrier = build_payload(packages, metadata);
    if (!carrier.stream_sources.empty()) throw PatcherError("boot carrier unexpectedly has external streams");
    return carrier;
}

struct ExpectedBuild {
    Layout layout;
    std::vector<AssetSpec> source_assets;
    std::vector<AssetSpec> assets;
    BuildPayload aggregate;
    std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> definitions;
    std::map<std::string, BuildPayload> bundles;
    BuildPayload boot_carrier;
    JsonValue manifest;
    std::map<fs::path, Bytes> package_outputs;
};

static ExpectedBuild build_expected(const fs::path &game_root, const fs::path &stage_root) {
    ExpectedBuild out;
    out.layout = require_layout(game_root);
    out.source_assets = scan_cooked_packages(game_root);
    out.package_outputs = generated_package_outputs(out.source_assets);
    if (!out.package_outputs.empty()) std::cout << "Will generate/refresh " << out.package_outputs.size() << " folder package(s).\n";
    out.assets = prepare_texture_resources(game_root, out.source_assets, stage_root);
    const HostBundleMetadata metadata = read_host_metadata(out.layout.format_base);
    out.aggregate = validate_resources(payload_resources(out.assets), metadata);
    out.definitions = runtime_package_definitions(out.assets);
    out.bundles = build_asset_bundles(out.assets, metadata, out.definitions);
    out.boot_carrier = build_boot_carrier(game_root, out.assets, out.package_outputs, stage_root, metadata);
    out.manifest = build_manifest(game_root, out.source_assets, out.aggregate, out.definitions, out.bundles.size());
    return out;
}

static fs::path stream_destination(const fs::path &game_root, const std::string &stream_name) {
    if (!safe_data_stream(stream_name)) throw PatcherError("refusing unsafe stream destination: " + stream_name);
    const fs::path bundle_root = fs::weakly_canonical(game_root / "bundle");
    const fs::path destination = fs::weakly_canonical(bundle_root / fs::path(stream_name));
    const std::string relative = generic_path_text(destination.lexically_relative(bundle_root));
    if (relative.empty() || starts_with(relative, "..")) throw PatcherError("refusing stream destination outside bundle root: " + stream_name);
    return destination;
}

static fs::path standalone_bundle_destination(const fs::path &game_root, const std::string &filename) {
    bundle_hash_le(filename);
    return game_root / "bundle" / filename;
}

static fs::path boot_carrier_destination(const fs::path &game_root) {
    return game_root / "bundle" / (std::string(STORAGE_BASE_BUNDLE) + ".patch_998");
}

static JsonValue make_state(
    const std::vector<AssetSpec> &assets,
    const BuildPayload &aggregate,
    const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &definitions,
    const std::map<std::string, BuildPayload> &bundles
) {
    JsonValue state = JsonValue::object_value();
    state.set("schema", JsonValue::integer_value(STATE_SCHEMA));
    state.set("custom_assets_version", JsonValue::string_value(VERSION));
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

static i64 unix_time_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

static u64 unix_ns_filetime(i64 value_ns) {
    return static_cast<u64>(value_ns / 100) + 116444736000000000ull;
}

static void set_bundle_timestamp(const fs::path &path, u64 filetime) {
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

static void print_summary(const std::vector<AssetSpec> &assets, const BuildPayload &aggregate, const std::map<std::string, BuildPayload> &bundles) {
    size_t compiler_count = 0;
    for (const auto &asset : assets) if (asset.source_kind == "compiler") ++compiler_count;
    const size_t folder_count = assets.size() - compiler_count;
    std::cout << "Custom Assets Patcher " << VERSION << "\n";
    std::cout << "Found " << assets.size() << " asset(s): " << compiler_count << " compiler manifest folder(s), "
              << folder_count << " descriptor-free cooked folder(s), " << aggregate.resources.size() << " cooked resource(s), "
              << aggregate.stream_sources.size() << " owned stream(s), " << bundles.size() << " package bundle(s).\n";
}

static void remove_paths_exact(const std::vector<fs::path> &paths_to_remove) {
    for (const auto &path : paths_to_remove) {
        std::error_code ec;
        if (!fs::exists(path, ec)) continue;
        if (!fs::remove(path, ec) || ec) throw PatcherError("could not remove stale managed file " + path_text(path) + ": " + ec.message());
    }
}

struct Snapshot {
    fs::path destination;
    std::optional<fs::path> backup;
};

static std::vector<Snapshot> snapshot_paths(const std::vector<fs::path> &paths_to_write, const fs::path &backup_root) {
    std::vector<Snapshot> snapshots;
    std::set<fs::path> seen;
    for (const auto &raw : paths_to_write) {
        const fs::path destination = fs::absolute(raw).lexically_normal();
        if (!seen.insert(destination).second) continue;
        std::error_code ec;
        if (fs::is_regular_file(destination, ec)) {
            std::ostringstream name;
            name << std::setfill('0') << std::setw(4) << snapshots.size() << ".bak";
            const fs::path backup = backup_root / name.str();
            fs::create_directories(backup.parent_path());
            fs::copy_file(destination, backup, fs::copy_options::overwrite_existing, ec);
            if (ec) throw PatcherError("could not snapshot " + path_text(destination) + ": " + ec.message());
            snapshots.push_back({destination, backup});
        } else if (fs::exists(destination, ec)) {
            throw PatcherError("refusing to replace non-file path: " + path_text(destination));
        } else {
            snapshots.push_back({destination, std::nullopt});
        }
    }
    return snapshots;
}

static std::vector<std::string> restore_paths(const std::vector<Snapshot> &snapshots) {
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

static std::set<std::string> string_set_from_state(const JsonValue &state, const char *key) {
    std::set<std::string> out;
    const JsonValue *value = state.get(key);
    if (!value || value->kind != JsonValue::Array) return out;
    for (const auto &item : value->array) if (item.kind == JsonValue::String) out.insert(item.string);
    return out;
}

static void verify_exact(
    const fs::path &game_root,
    const Layout &layout,
    const BuildPayload &aggregate,
    const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &definitions,
    const std::map<std::string, BuildPayload> &bundles,
    const BuildPayload &boot_carrier,
    const JsonValue &manifest,
    const JsonValue &state,
    const Bytes &expected_db,
    const std::map<fs::path, Bytes> &package_outputs,
    const std::vector<fs::path> &stale_paths
) {
    std::vector<std::string> problems;
    const Bytes db = read_file(layout.db);
    if (db != expected_db) problems.push_back("bundle_database.data does not match the planned transaction");
    if (boot_registration_count(db) != 1) problems.push_back("boot carrier patch registration differs");
    if (!file_equals_bytes(boot_carrier_destination(game_root), boot_carrier.patch_bytes)) problems.push_back("boot carrier patch differs");
    for (const auto &item : bundles) {
        if (bundle_registration_count(db, item.first) != 1) problems.push_back("generated bundle registration differs: " + item.first);
        if (!file_equals_bytes(standalone_bundle_destination(game_root, item.first), item.second.patch_bytes)) problems.push_back("generated bundle differs: bundle/" + item.first);
    }
    for (const auto &item : definitions) {
        const auto actual = package_members(db, item.first);
        if (!actual || *actual != item.second) problems.push_back("package registry differs: " + item.first);
    }
    if (!file_equals_bytes(layout.manifest_json, json_bytes(manifest))) problems.push_back("generated JSON manifest does not match");
    if (!file_equals_bytes(layout.manifest_lua, lua_bytes(manifest))) problems.push_back("generated Lua manifest does not match");
    for (const auto &item : aggregate.stream_sources) if (!files_equal(stream_destination(game_root, item.first), item.second)) problems.push_back("managed stream differs: bundle/" + item.first);
    for (const auto &item : package_outputs) if (!file_equals_bytes(item.first, item.second)) problems.push_back("generated package differs: " + path_text(item.first));
    try {
        if (!(load_state(layout.state) == state)) problems.push_back("install_state.json does not match");
    } catch (...) {
        problems.push_back("install_state.json does not match");
    }
    for (const auto &stale : stale_paths) if (fs::exists(stale)) problems.push_back("stale managed payload still exists: " + path_text(stale));
    if (!problems.empty()) {
        std::string message = "post-install verification failed: ";
        for (size_t i = 0; i < problems.size(); ++i) { if (i) message += "; "; message += problems[i]; }
        throw PatcherError(message);
    }
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

static int write_build(const fs::path &game_root, bool dry_run = false) {
    TempDirectory stage;
    ExpectedBuild build = build_expected(game_root, stage.path);
    const JsonValue state = make_state(build.assets, build.aggregate, build.definitions, build.bundles);
    const JsonValue old_state = load_state(build.layout.state);
    const Bytes db_data = read_file(build.layout.db);
    std::map<std::string, fs::path> desired_bundle_paths;
    std::vector<std::string> bundle_names;
    for (const auto &item : build.bundles) {
        desired_bundle_paths[item.first] = standalone_bundle_destination(game_root, item.first);
        bundle_names.push_back(item.first);
    }
    std::set<std::string> old_bundles = string_set_from_state(old_state, "bundles");
    const std::set<std::string> recovered_bundles = recover_generated_bundle_ownership(db_data, bundle_names);
    std::set<std::string> managed_bundles = old_bundles;
    managed_bundles.insert(recovered_bundles.begin(), recovered_bundles.end());
    std::set<std::string> changed_bundles;
    for (const auto &item : desired_bundle_paths) if (!file_equals_bytes(item.second, build.bundles.at(item.first).patch_bytes)) changed_bundles.insert(item.first);
    for (const auto &item : desired_bundle_paths) if (fs::exists(item.second) && !managed_bundles.count(item.first)) throw PatcherError("refusing to adopt or overwrite unmanaged bundle/" + item.first);

    const i64 build_unix_ns = unix_time_ns();
    const u64 build_filetime = unix_ns_filetime(build_unix_ns);
    ReconcileResult bundle_result = reconcile_bundle_registrations(db_data, bundle_names, managed_bundles, changed_bundles, build_filetime);
    std::set<std::string> old_packages = string_set_from_state(old_state, "packages");
    std::vector<std::string> package_names;
    for (const auto &item : build.definitions) package_names.push_back(item.first);
    const std::set<std::string> recovered_packages = recover_generated_package_ownership(db_data, package_names);
    std::set<std::string> managed_packages = old_packages;
    managed_packages.insert(recovered_packages.begin(), recovered_packages.end());
    ReconcileResult package_result = reconcile_package_registrations(ensure_boot_registration(bundle_result.data), build.definitions, managed_packages);
    const Bytes new_db = package_result.data;
    const fs::path boot_path = boot_carrier_destination(game_root);
    if (fs::exists(boot_path) && boot_registration_count(db_data) != 1) throw PatcherError("refusing to overwrite an unregistered boot carrier patch");
    const bool changed_boot = !file_equals_bytes(boot_path, build.boot_carrier.patch_bytes);

    std::map<std::string, fs::path> desired_streams;
    for (const auto &item : build.aggregate.stream_sources) desired_streams[item.first] = stream_destination(game_root, item.first);
    std::set<std::string> old_streams = string_set_from_state(old_state, "streams");
    std::map<std::string, std::set<std::string>> stream_provider_bundles;
    for (const auto &bundle : build.bundles) for (const auto &stream : bundle.second.stream_sources) stream_provider_bundles[stream.first].insert(bundle.first);
    std::set<std::string> recovered_streams;
    for (const auto &item : desired_streams) {
        if (!fs::is_regular_file(item.second) || !files_equal(item.second, build.aggregate.stream_sources.at(item.first))) continue;
        const auto providers = stream_provider_bundles.find(item.first);
        if (providers == stream_provider_bundles.end()) continue;
        for (const auto &provider : providers->second) if (recovered_bundles.count(provider)) { recovered_streams.insert(item.first); break; }
    }
    std::set<std::string> managed_streams = old_streams;
    managed_streams.insert(recovered_streams.begin(), recovered_streams.end());
    for (const auto &item : desired_streams) if (fs::exists(item.second) && !managed_streams.count(item.first)) throw PatcherError("refusing to adopt or overwrite unmanaged stream bundle/" + item.first);

    std::vector<fs::path> stale_paths;
    for (const auto &name : old_bundles) if (!build.bundles.count(name)) stale_paths.push_back(standalone_bundle_destination(game_root, name));
    for (const auto &name : old_streams) if (!desired_streams.count(name)) stale_paths.push_back(stream_destination(game_root, name));
    const Bytes manifest_json = json_bytes(build.manifest);
    const Bytes manifest_lua = lua_bytes(build.manifest);
    const Bytes state_bytes = json_bytes(state);
    std::set<std::string> changed_streams;
    for (const auto &item : desired_streams) if (!files_equal(item.second, build.aggregate.stream_sources.at(item.first))) changed_streams.insert(item.first);
    std::map<fs::path, Bytes> changed_package_outputs;
    for (const auto &item : build.package_outputs) if (!file_equals_bytes(item.first, item.second)) changed_package_outputs[item.first] = item.second;
    std::vector<fs::path> paths_to_write;
    for (const auto &name : changed_bundles) paths_to_write.push_back(desired_bundle_paths.at(name));
    if (changed_boot) paths_to_write.push_back(boot_path);
    for (const auto &name : changed_streams) paths_to_write.push_back(desired_streams.at(name));
    for (const auto &item : changed_package_outputs) paths_to_write.push_back(item.first);
    if (!file_equals_bytes(build.layout.manifest_json, manifest_json)) paths_to_write.push_back(build.layout.manifest_json);
    if (!file_equals_bytes(build.layout.manifest_lua, manifest_lua)) paths_to_write.push_back(build.layout.manifest_lua);
    if (!file_equals_bytes(build.layout.state, state_bytes)) paths_to_write.push_back(build.layout.state);

    print_summary(build.assets, build.aggregate, build.bundles);
    if (dry_run) {
        std::cout << "SUCCESS: dry run completed. No game bundle/database files were changed.\n";
        return 0;
    }

    std::vector<fs::path> snapshot_targets = paths_to_write;
    snapshot_targets.insert(snapshot_targets.end(), stale_paths.begin(), stale_paths.end());
    const auto snapshots = snapshot_paths(snapshot_targets, stage.path / "rollback");
    try {
        for (const auto &name : changed_bundles) {
            const fs::path destination = desired_bundle_paths.at(name);
            atomic_write(destination, build.bundles.at(name).patch_bytes);
            set_bundle_timestamp(destination, build_filetime);
        }
        if (changed_boot) atomic_write(boot_path, build.boot_carrier.patch_bytes);
        for (const auto &name : changed_streams) atomic_copy(build.aggregate.stream_sources.at(name), desired_streams.at(name));
        for (const auto &item : changed_package_outputs) atomic_write(item.first, item.second);
        if (new_db != db_data) atomic_write(build.layout.db, new_db);
        if (!file_equals_bytes(build.layout.manifest_json, manifest_json)) atomic_write(build.layout.manifest_json, manifest_json);
        if (!file_equals_bytes(build.layout.manifest_lua, manifest_lua)) atomic_write(build.layout.manifest_lua, manifest_lua);
        remove_paths_exact(stale_paths);
        if (!file_equals_bytes(build.layout.state, state_bytes)) atomic_write(build.layout.state, state_bytes);
        verify_exact(game_root, build.layout, build.aggregate, build.definitions, build.bundles, build.boot_carrier, build.manifest, state, new_db, build.package_outputs, stale_paths);
    } catch (const std::exception &exc) {
        std::vector<std::string> rollback_problems;
        try {
            if (!file_equals_bytes(build.layout.db, db_data)) atomic_write(build.layout.db, db_data);
        } catch (const std::exception &rollback) {
            rollback_problems.push_back(path_text(build.layout.db) + ": " + rollback.what());
        }
        const auto restore_problems = restore_paths(snapshots);
        rollback_problems.insert(rollback_problems.end(), restore_problems.begin(), restore_problems.end());
        if (!rollback_problems.empty()) {
            std::string message = std::string("install failed: ") + exc.what() + "; rollback was incomplete: ";
            for (size_t i = 0; i < rollback_problems.size(); ++i) { if (i) message += "; "; message += rollback_problems[i]; }
            throw PatcherError(message);
        }
        throw;
    }

    std::cout << "SUCCESS: installed " << build.bundles.size() << " Custom Assets package bundle(s).\n";
    if (bundle_result.added || bundle_result.updated || bundle_result.removed) std::cout << "Bundle registry: +" << bundle_result.added << " / ~" << bundle_result.updated << " / -" << bundle_result.removed << ".\n";
    if (package_result.added || package_result.updated || package_result.removed) std::cout << "Package registry: +" << package_result.added << " / ~" << package_result.updated << " / -" << package_result.removed << ".\n";
    return 0;
}

class TeeBuffer : public std::streambuf {
public:
    TeeBuffer(std::streambuf *first, std::streambuf *second) : first(first), second(second) {
    }

protected:
    int overflow(int c) override {
        if (c == traits_type::eof()) return traits_type::not_eof(c);
        const bool a = first->sputc(static_cast<char>(c)) != traits_type::eof();
        const bool b = second->sputc(static_cast<char>(c)) != traits_type::eof();
        return a && b ? c : traits_type::eof();
    }

    int sync() override {
        const int a = first->pubsync();
        const int b = second->pubsync();
        return a == 0 && b == 0 ? 0 : -1;
    }

private:
    std::streambuf *first;
    std::streambuf *second;
};

static int patcher_main() {
    const fs::path game_root = infer_game_root();
    const Layout layout = paths(game_root);
    fs::create_directories(layout.log.parent_path());
    std::ofstream log_file(layout.log, std::ios::trunc);
    if (!log_file) throw PatcherError("could not open patch log: " + path_text(layout.log));
    TeeBuffer out_buffer(std::cout.rdbuf(), log_file.rdbuf());
    TeeBuffer err_buffer(std::cerr.rdbuf(), log_file.rdbuf());
    std::streambuf *old_out = std::cout.rdbuf(&out_buffer);
    std::streambuf *old_err = std::cerr.rdbuf(&err_buffer);
    int result = 1;
    try {
        std::cout << "Custom Assets Patcher " << VERSION << "\n";
        if (game_is_running()) throw PatcherError("Darktide.exe is running. Close the game before patching assets.");
        result = write_build(game_root);
    } catch (const std::exception &exc) {
        std::cerr << "ERROR: " << exc.what() << "\n";
        result = 1;
    }
    std::cout.flush();
    std::cerr.flush();
    std::cout.rdbuf(old_out);
    std::cerr.rdbuf(old_err);
    return result;
}

int main() {
    try {
        return patcher_main();
    } catch (const std::exception &exc) {
        std::cerr << "ERROR: " << exc.what() << "\n";
        return 1;
    }
}

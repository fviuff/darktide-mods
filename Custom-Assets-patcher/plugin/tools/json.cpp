#include "json.h"

#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <sstream>

namespace ca {

bool operator==(const JsonValue &a, const JsonValue &b) {
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

std::string json_dump(const JsonValue &value, int indent) {
    std::string out;
    json_dump_value(out, value, 0, indent);
    out.push_back('\n');
    return out;
}

JsonValue parse_json(const std::string &source) {
    return JsonParser(source).parse();
}

} // namespace ca

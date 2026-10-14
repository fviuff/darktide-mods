#pragma once

#include <string>
#include <utility>
#include <vector>

namespace ca {

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

bool operator==(const JsonValue &a, const JsonValue &b);
JsonValue parse_json(const std::string &source);
std::string json_dump(const JsonValue &value, int indent = 2);

} // namespace ca

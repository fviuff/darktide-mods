#pragma once

#include "common.h"

#include <string>
#include <vector>

namespace ca {

// where the patcher sits decides where it writes:
// plugin: <game>/tools/custom-assets-patcher.exe -> <game>/tools/custom-assets-*.{lua,json,log}
// bat:    <game>/mods/CustomAssets/tools/custom-assets-patcher.exe -> <game>/mods/CustomAssets/generated/
struct Layout {
    std::string kind;                 // "plugin" or "bat"
    fs::path executable;
    fs::path game_root;
    fs::path db;
    fs::path format_base;
    fs::path storage_base;
    fs::path manifest_json;
    fs::path manifest_lua;
    fs::path state;
    fs::path log;
    std::vector<fs::path> other_outputs;   // the other layout's manifest and state, removed so the mod reads ours
    fs::path other_state;
};

Layout layout_for_executable(const fs::path &executable);

struct InstallOptions {
    bool dry_run = false;
    bool force = false;               // rebuild even when nothing changed
};

// up_to_date: nothing changed since the last install, so nothing was done
int install(const Layout &layout, const InstallOptions &options, bool &up_to_date);

} // namespace ca

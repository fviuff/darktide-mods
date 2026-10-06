#pragma once

// bundle_database.data: bundle registrations (our per-asset bundles, the boot patch_998) and package definitions

#include "common.h"

#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace ca {

struct ReconcileResult {
    Bytes data;
    int added = 0;
    int updated = 0;
    int removed = 0;
};

int boot_registration_count(const Bytes &data);
Bytes ensure_boot_registration(const Bytes &data);
int mod_loader_registration_count(const Bytes &data);
int bundle_registration_count(const Bytes &data, const std::string &bundle_name);
Hash8 bundle_hash_le(const std::string &bundle_name);
std::set<std::string> recover_generated_bundle_ownership(const Bytes &data, const std::vector<std::string> &desired_bundles);
std::set<std::string> recover_generated_package_ownership(const Bytes &data, const std::vector<std::string> &desired_packages);
ReconcileResult reconcile_bundle_registrations(const Bytes &data, const std::vector<std::string> &desired_bundles,
                                               const std::set<std::string> &managed_bundles,
                                               const std::set<std::string> &refresh_bundles, u64 footer_filetime);
std::optional<std::vector<std::pair<Hash8, Hash8>>> package_members(const Bytes &data, const std::string &package_name);
ReconcileResult reconcile_package_registrations(const Bytes &data,
                                                const std::map<std::string, std::vector<std::pair<Hash8, Hash8>>> &desired,
                                                const std::set<std::string> &managed_packages);

} // namespace ca

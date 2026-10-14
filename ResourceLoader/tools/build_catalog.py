"""generate resource loader everything"""

import argparse
import json
import re
import struct
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "limn-output"
DEFAULT_DICTIONARY = ROOT / "tools/limn/dictionary_hashcat_dt.txt"
DEFAULT_CATALOG = ROOT / "scripts/mods/ResourceLoader/catalog"
DEFAULT_METADATA = ROOT / "catalog_metadata.json"
SCHEMA = 2
ROWS_PER_CHUNK = 4096
SAFE_NAME = re.compile(r"[^a-z0-9_]+")
UNKNOWN_PACKAGE = re.compile(r"^[0-9a-fA-F]{16}$")
KNOWN_TYPES = (
    "animation", "animation_curves", "bik", "bk2", "blend_set", "bones", "chroma",
    "common_package", "config", "data", "entity", "flow", "font", "ies", "ini", "ivf",
    "keys", "level", "lua", "material", "mod", "mouse_cursor", "navdata", "network_config",
    "oodle_net", "package", "particles", "physics_properties", "render_config", "rt_pipeline",
    "scene", "shader", "shader_library", "shader_library_group", "shading_environment",
    "shading_environment_mapping", "slug", "slug_album", "state_machine", "strings", "texture",
    "theme", "tome", "unit", "vector_field", "wwise_bank", "wwise_dep", "wwise_event",
    "wwise_metadata", "wwise_stream",
)


def murmur64(value):
    data = value.encode("utf-8") if isinstance(value, str) else value
    m = 0xC6A4A7935BD1E995
    mask = 0xFFFFFFFFFFFFFFFF
    h = (len(data) * m) & mask
    end = len(data) & ~7
    for offset in range(0, end, 8):
        k = int.from_bytes(data[offset:offset + 8], "little")
        k = (k * m) & mask
        k ^= k >> 47
        k = (k * m) & mask
        h ^= k
        h = (h * m) & mask
    tail = data[end:]
    for i, byte in enumerate(tail):
        h ^= byte << (i * 8)
    if tail:
        h = (h * m) & mask
    h ^= h >> 47
    h = (h * m) & mask
    h ^= h >> 47
    return h & mask


def load_dictionary(path):
    names = {}
    for value in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"@([0-9a-fA-F]{16})=(.*)", value)
        if match:
            names[int(match.group(1), 16)] = match.group(2)
        else:
            names[murmur64(value)] = value
    return names


def read_package(path):
    """read package extracted by limn with --dump-raw."""
    raw = path.read_bytes()
    if len(raw) < 24:
        raise ValueError(f"Invalid raw Limn package: {path}")

    file_ext, _file_name, variant_count, _reserved = struct.unpack_from("<QQII", raw, 0)
    if file_ext != murmur64("package"):
        raise ValueError(f"Not a raw Limn package: {path}")

    offset = 24 + variant_count * 14
    if offset + 9 > len(raw):
        raise ValueError(f"Truncated raw Limn package: {path}")

    version, count = struct.unpack_from("<II", raw, offset)
    if version != 43:
        raise ValueError(f"Unsupported package version {version}: {path}")
    offset += 8

    end = offset + count * 16
    if end + 1 != len(raw) or raw[end] != 1:
        raise ValueError(f"Invalid package payload: {path}")

    return list(struct.iter_unpack("<QQ", raw[offset:end]))


def quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t") + '"'


def file_stem(resource_type):
    if resource_type.startswith("hash:"):
        return "hash_" + resource_type[5:]
    return SAFE_NAME.sub("_", resource_type.lower()).strip("_") or "unknown"


def read_source(source, dictionary):
    hashes_path = source / "hashes.bin"
    if not hashes_path.is_file():
        raise FileNotFoundError(f"Missing Limn hash dump: {hashes_path}")
    if not dictionary.is_file():
        raise FileNotFoundError(f"Missing dictionary: {dictionary}")

    names = load_dictionary(dictionary)
    type_names = {murmur64(name): name for name in KNOWN_TYPES}
    package_files = sorted(source.rglob("*.package"), key=lambda p: p.as_posix())
    if not package_files:
        raise FileNotFoundError(f"No raw Limn package files found under: {source}")

    packages = []
    membership_count = 0
    for path in package_files:
        members = read_package(path)
        membership_count += len(members)
        relative = path.relative_to(source).as_posix()
        package_path = relative[:-len(".package")]
        known_package = not UNKNOWN_PACKAGE.fullmatch(package_path)
        packages.append((package_path if known_package else None, members))

    raw = hashes_path.read_bytes()
    if len(raw) % 16:
        raise ValueError(f"Invalid hashes.bin size: {len(raw)} bytes")
    resources = []
    resource_paths = {}
    for ext_hash, name_hash in struct.iter_unpack("<QQ", raw):
        resource_type = type_names.get(ext_hash, f"hash:{ext_hash:016x}")
        name_hex = f"{name_hash:016x}"
        resource_path = names.get(name_hash)
        resources.append((resource_type, ext_hash, name_hex, resource_path))
        resource_paths[(resource_type, name_hex)] = resource_path

    selected = {}
    for package_path, members in packages:
        if package_path is None:
            continue
        member_count = len(members)
        for ext_hash, name_hash in members:
            resource_type = type_names.get(ext_hash, f"hash:{ext_hash:016x}")
            name_hex = f"{name_hash:016x}"
            key = (resource_type, name_hex)
            if key not in resource_paths:
                continue
            exact = resource_paths[key] is not None and resource_paths[key] == package_path
            candidate = (0 if exact else 1, member_count, package_path)
            previous = selected.get(key)
            if previous is None or candidate < previous:
                selected[key] = candidate

    return resources, selected, membership_count


def write_chunk(path, rows):
    packages = sorted({package for _, _, package in rows if package})
    indices = {package: i for i, package in enumerate(packages, 1)}
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("-- Generated chunk: local packages plus {resource_key, package_index}.\n")
        f.write("return {\n")
        f.write(f"    schema_version = {SCHEMA},\n")
        f.write("    packages = {\n")
        for package in packages:
            f.write(f"        {quote(package)},\n")
        f.write("    },\n    resources = {\n")
        for _, key, package in rows:
            f.write(f"        {{ {quote(key)}, {indices.get(package, 0)} }},\n")
        f.write("    },\n}\n")
    return len(packages), rows[-1][1]


def write_index(path, types, totals, package_count):
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("-- Generated by ResourceLoader/tools/build_catalog.py.\n")
        f.write("-- Type row: {name, engine_type, count, loadable, chunk_routes}.\n")
        f.write("-- Chunk route: {maximum_key, path, count, loadable}.\n")
        f.write("return {\n")
        f.write(f"    schema_version = {SCHEMA},\n")
        f.write(f"    resource_count = {totals['resources']},\n")
        f.write(f"    named_resource_count = {totals['named']},\n")
        f.write(f"    hash_resource_count = {totals['hash_names']},\n")
        f.write(f"    package_loadable_count = {totals['loadable']},\n")
        f.write(f"    no_resolved_package_count = {totals['no_package']},\n")
        f.write(f"    selected_package_count = {package_count},\n")
        f.write(f"    chunk_count = {totals['chunks']},\n")
        f.write("    types = {\n")
        for row in types:
            f.write(
                f"        {{ {quote(row['resource_type'])}, {quote(row['engine_type'])}, "
                f"{row['resource_count']}, {row['loadable_count']}, {{\n"
            )
            for route in row["chunks"]:
                f.write(
                    f"            {{ {quote(route['maximum_key'])}, {quote(route['path'])}, "
                    f"{route['resource_count']}, {route['loadable_count']} }},\n"
                )
            f.write("        } },\n")
        f.write("    },\n    type_index = {\n")
        for row in types:
            f.write(f"        [{quote(row['resource_type'])}] = {row['type_index']},\n")
        f.write("    },\n}\n")


def build(source, dictionary, catalog, metadata, rows_per_chunk):
    if rows_per_chunk < 1:
        raise ValueError("rows_per_chunk must be at least 1")
    source_rows, selected, membership_count = read_source(source, dictionary)
    resources_dir = catalog / "resources"
    resources_dir.mkdir(parents=True, exist_ok=True)
    metadata.parent.mkdir(parents=True, exist_ok=True)
    for path in resources_dir.glob("*.lua"):
        path.unlink()

    by_type = {}
    for resource_type, type_hash, name_hash, resource_path in source_rows:
        by_type.setdefault(resource_type, [type_hash, []])[1].append((name_hash, resource_path))

    totals = Counter()
    types = []
    selected_package_names = set()
    for type_index, resource_type in enumerate(sorted(by_type), 1):
        type_hash, members = by_type[resource_type]
        rows = []
        for name_hash, resource_path in sorted(
            members, key=lambda row: (row[1] if row[1] is not None else f"#ID[{row[0]}]", row[0])
        ):
            selection = selected.get((resource_type, name_hash))
            package = selection[2] if selection else None
            rows.append((name_hash, resource_path or f"#ID[{name_hash}]", package))
            totals["named" if resource_path else "hash_names"] += 1
            totals["exact_packages"] += int(bool(selection and selection[0] == 0))
            if package:
                selected_package_names.add(package)

        stem = file_stem(resource_type)
        chunk_count = (len(rows) + rows_per_chunk - 1) // rows_per_chunk
        routes = []
        loadable = 0
        for chunk_index, offset in enumerate(range(0, len(rows), rows_per_chunk), 1):
            chunk_rows = rows[offset:offset + rows_per_chunk]
            chunk_loadable = sum(package is not None for _, _, package in chunk_rows)
            chunk_stem = stem if chunk_count == 1 else f"{stem}_{chunk_index:03d}"
            local_packages, maximum_key = write_chunk(resources_dir / f"{chunk_stem}.lua", chunk_rows)
            routes.append({
                "maximum_key": maximum_key,
                "path": f"resources/{chunk_stem}",
                "resource_count": len(chunk_rows),
                "loadable_count": chunk_loadable,
            })
            loadable += chunk_loadable
            totals["chunks"] += 1
            totals["chunk_package_entries"] += local_packages

        types.append({
            "type_index": type_index,
            "resource_type": resource_type,
            "engine_type": f"#ID[{type_hash:016x}]" if resource_type.startswith("hash:") else resource_type,
            "resource_count": len(rows),
            "loadable_count": loadable,
            "chunks": routes,
        })
        totals["resources"] += len(rows)
        totals["loadable"] += loadable
        totals["no_package"] += len(rows) - loadable

    write_index(catalog / "index.lua", types, totals, len(selected_package_names))
    result = {
        "schema_version": SCHEMA,
        "rows_per_chunk": rows_per_chunk,
        "source_database": "resource_catalog.sqlite3",
        "index": "scripts/mods/ResourceLoader/catalog/index.lua",
        "type_count": len(types),
        "chunk_count": totals["chunks"],
        "selected_package_count": len(selected_package_names),
        "chunk_package_entries": totals["chunk_package_entries"],
        "source_membership_count": membership_count,
        "hash_names": totals["hash_names"],
        "exact_packages": totals["exact_packages"],
        "named": totals["named"],
        "resources": totals["resources"],
        "loadable": totals["loadable"],
        "no_package": totals["no_package"],
    }
    with metadata.open("w", encoding="utf-8", newline="\r\n") as f:
        f.write(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--dictionary", type=Path, default=DEFAULT_DICTIONARY)
    parser.add_argument("--catalog-dir", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--rows-per-chunk", type=int, default=ROWS_PER_CHUNK)
    args = parser.parse_args()
    print(json.dumps(build(args.source, args.dictionary, args.catalog_dir, args.metadata, args.rows_per_chunk), indent=2))


if __name__ == "__main__":
    main()

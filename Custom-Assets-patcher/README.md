https://www.nexusmods.com/warhammer40kdarktide/mods/1200
# Custom Assets

Puts custom cooked assets (units, materials, textures, animations, particles...) from mods into the game, so mods can load them like the game's own.

## Install

There are two versions

- plugin: download it from Nexus and copy whats inside into the game folder. It patches by itself at startup
- bat: The old version. Copy whats inside into the game folder and run `CUSTOM_ASSETS_PATCH.bat` with game closed

Put `CustomAssets` before mods that use it in `mod_load_order.txt`.

If switching delete the other versions files

## Assets

Put assets in:

```text
mods/<YourMod>/Custom/<AssetName>/
```

Either a folder from the Darktide asset compiler (it has a `build.json`) or any folder of cooked resources.

A folder that can't be installed is skipped, the rest still go in. Ingame `/custom_assets_status` lists the skipped folders and why. The log is `tools/custom-assets-patch.log` (plugin) or `mods/CustomAssets/generated/last_patch.log` (bat).

If two folders have the same resource, the one that was installed first keeps it.

## Without the Lua API

The Lua API is optional. Assets are patched and registered with the game either way, so a mod can load the package itself.

Every asset folder gets its own package:

```text
content/mods/custom_assets/packages/<hash>
```

`<hash>` is the murmur64 of `<YourMod>:<AssetName>` (mod folder and asset folder name) as 16 hex digits, so it stays the same as long as the folder names do. For example `SDKTestBench:sdk_flow` is `content/mods/custom_assets/packages/f921a30adb966ee7`.

The manifest lists every asset with its `package_name`:

```text
tools/custom-assets-manifest.json                       (plugin)
mods/CustomAssets/generated/custom_assets_manifest.json (bat)
```

When you load a package yourself and destroy units that use it, release the package a frame later, not in the same frame. Effects the units started still use it until the next world update. The API does this for you.

# Custom Assets API

Put `CustomAssets` before mods that use it in `mod_load_order.txt`.

```lua
local custom_assets = get_mod("CustomAssets")

if not custom_assets or not custom_assets.is_api_compatible(1) then
    return
end
```

## Find assets

Asset IDs are `<Mod>:<Folder>`.

```lua
local asset, err = custom_assets.get_asset("MyMod:MyAsset")
local all = custom_assets.list_assets()
local mine = custom_assets.list_assets("MyMod")
```

`asset.package_name`, `asset.primary` and `asset.resources` are the useful fields.

## Find resources

```lua
local resource, err = custom_assets.resolve_resource(
    "unit",
    "content/mods/my_mod/my_unit"
)

local all = custom_assets.list_resources()
local textures = custom_assets.list_resources("texture")
local mine = custom_assets.list_resources(nil, "MyMod")
```

Hash-only resources use `#ID[0123456789abcdef]`.

## Load

Load an asset:

```lua
local ticket, err = custom_assets.acquire(mod, "MyMod:MyAsset", function(ticket, asset, err)
    if err then
        mod:error(err)
        return
    end

end)
```

Load the package that owns a resource:

```lua
local ticket, err = custom_assets.acquire_resource(
    mod,
    "unit",
    "content/mods/my_mod/my_unit",
    function(ticket, resource, err)
        if err then
            mod:error(err)
            return
        end

        end
)
```

If you already have a Custom Assets package name:

```lua
local ticket, err = custom_assets.acquire_package(mod, asset.package_name, callback)
```

Callbacks run through `CustomAssets.update`, not inline from PackageManager.
Keep the ticket while you need the package.

Optional load options:

```lua
{
    prioritize = true,
    resident = false,
    reference_name = "MyMod:thing",
}
```

## Release

```lua
custom_assets.release(ticket)
custom_assets.release_owner(mod)
```

Typical cleanup:

```lua
mod.on_unload = function()
    custom_assets.release_owner(mod)
end
```

## Status

```lua
custom_assets.status(ticket)
custom_assets.can_get_resource("unit", "content/mods/my_mod/my_unit")
custom_assets.stats()
```

Ticket states: `pending`, `loaded`, `released`, `failed`, `stale`, `unknown`.

`stats()` also has `skipped_count`, the number of asset folders that couldnt be installed.

## API

```lua
custom_assets.is_api_compatible(version)
custom_assets.get_asset(logical_id)
custom_assets.list_assets(owner)
custom_assets.resolve_resource(engine_type, name)
custom_assets.list_resources(engine_type, owner)
custom_assets.acquire(owner, logical_id, callback, options)
custom_assets.acquire_resource(owner, engine_type, name, callback, options)
custom_assets.acquire_package(owner, package_name, callback, options)
custom_assets.release(ticket)
custom_assets.release_owner(owner)
custom_assets.status(ticket)
custom_assets.can_get_resource(engine_type, name)
custom_assets.stats()
```

# Building

`plugin/` is laid out like the install, with the code where the exe and dll go: `tools/` is the patcher, `binaries/plugins/` the plugin. With Visual Studio's C++ build tools:

```text
cmake -S plugin/tools -B build/tools -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/tools
cmake -S plugin/binaries/plugins -B build/plugins -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/plugins
```

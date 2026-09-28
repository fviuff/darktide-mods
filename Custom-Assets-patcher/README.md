https://www.nexusmods.com/warhammer40kdarktide/mods/1200

# Custom Assets API

You do not need the lua the assets will already be patched in regardless. This is just for utility:

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

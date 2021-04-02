unused_args = false
-- allow_defined_top = true

globals = {
    "minetest",
    "auroras",
}

read_globals = {
    string = {fields = {"split"}},
    table = {fields = {"copy", "getn"}},

    -- Builtin
    "vector",
    "ItemStack",
    "dump",
    "DIR_DELIM",
    "VoxelArea",
    "Settings",
    "PerlinNoise",

    -- MTG
    "default",
    "sfinv",
    "creative",

    -- Mods
    "climate_api",
}

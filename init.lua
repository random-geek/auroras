auroras = {}

--[[
    Various constants and defaults. Will be overridden by settings, if present.
]]

auroras.UPDATE_INTERVAL = 1.5

auroras.TIME_START = 0.82
auroras.TIME_END = 0.18
auroras.TRANSITION_TIME = 0.02

auroras.HEIGHT_MIN = -24.0
auroras.HEIGHT_TRANSITION = 8.0

auroras.HEAT_MIN = 0
auroras.HEAT_MAX = 25
auroras.HUM_MIN = 0
auroras.HUM_MAX = 100
auroras.BIOME_TRANSITION = 5

-- Warning: Changing offset, scale, octaves, or persistance could result in
-- uneven noise!
auroras.NOISE_PARAMS = {
    offset = 0,
    scale = 1,
    spread = {x=800, y=60, z=800},
    octaves = 2,
    persistence = 0.5,
    lacunarity = 4.0,
    flags = "eased",
}

auroras.NOISE_MIN = -0.2
auroras.NOISE_TRANSITION = 0.20

auroras.DAY_NIGHT_RATIO = 0.25

auroras.COLORS = {
    "#14cca1",
    "#22e6b2",
    "#33ffc6",
    "#49f2ac",
    "#5ce673",
    "#82f249",
    "#6fd916",
    "#a0f725",
    "#c3ff19",
    "#a9f73b",
    "#d2f230",
    "#d3e043",
    "#dd564b",
    "#d93648",
    "#b3478e",
}

-- Settings for when using Climate API.
auroras.CLIMATE_API_SKYBOX_PRIORITY = 40
-- Use interval matching Climate API's skybox update frequency.
auroras.CLIMATE_API_UPDATE_INTERVAL = 2.0

-- Default sky colors, see minetest/src/skyparams.h.
auroras.BASE_SKY = {r=0, g=107, b=255}
auroras.BASE_HORIZON = {r=64, g=144, b=255}

-- Default nighttime day-night ratio, see minetest/src/daynightratio.h.
auroras.BASE_DAY_NIGHT_RATIO = 0.175

auroras.SETTING_PREFIX = "auroras_"

--[[
    End of constant definitions
]]

auroras.USE_CLIMATE_API = minetest.get_modpath("climate_api") ~= nil

auroras.player_data = {}
auroras.was_night = false

--[[
    Function definitions
]]

function auroras.get_settings()
    local function get_num(key)
        local val = minetest.settings:get(auroras.SETTING_PREFIX .. key)
        return tonumber(val) -- Will return nil if val is nil.
    end

    local a = auroras

    if a.USE_CLIMATE_API then
        a.UPDATE_INTERVAL = a.CLIMATE_API_UPDATE_INTERVAL
    else
        a.UPDATE_INTERVAL = get_num("update_interval") or a.UPDATE_INTERVAL
    end

    a.HEIGHT_MIN = get_num("height_min") or a.HEIGHT_MIN
    a.HEAT_MIN = get_num("heat_min") or a.HEAT_MIN
    a.HEAT_MAX = get_num("heat_max") or a.HEAT_MAX
    a.HUM_MIN = get_num("heat_min") or a.HUM_MIN
    a.HUM_MAX = get_num("heat_max") or a.HUM_MAX
    a.DAY_NIGHT_RATIO = get_num("day_night_ratio") or a.DAY_NIGHT_RATIO
    a.NOISE_PARAMS.spread.y = get_num("time_spread") or a.NOISE_PARAMS.spread.y
    a.NOISE_MIN = get_num("noise_threshold") or a.NOISE_MIN
    a.BIOME_TRANSITION = get_num("biome_transition") or a.BIOME_TRANSITION
end

function auroras.clamp(x, low, high)
    return math.max(low, math.min(high, x))
end

function auroras.interp_colors(x, y, fac)
    local invFac = 1.0 - fac
    return {
        r = math.floor(x.r * invFac + y.r * fac),
        g = math.floor(x.g * invFac + y.g * fac),
        b = math.floor(x.b * invFac + y.b * fac)
    }
end

function auroras.parse_hex_color(hex)
    if type(hex) == "string" and
            hex:len() == 7 and
            hex:sub(1, 1) == "#" then

        local tab = {
            r = tonumber(hex:sub(2, 3), 16),
            g = tonumber(hex:sub(4, 5), 16),
            b = tonumber(hex:sub(6, 7), 16)
        }

        if tab.r ~= nil and
           tab.g ~= nil and
           tab.b ~= nil then
            return tab
        end
    end

    return nil -- Invalid color
end

function auroras.init_colors()
    -- Wrap in a function so we can return.
    (function()
        local colorList = minetest.settings:get(
                auroras.SETTING_PREFIX .. "colors")

        if colorList ~= nil then
            local colors = {}
            local idx = 0
            -- Split at commas and spaces.
            for hexCol in colorList:gmatch("[^%s%,]+") do
                local tCol = auroras.parse_hex_color(hexCol)

                if tCol == nil then
                    minetest.log("error", "[auroras] Invalid hex color: " ..
                            dump(hexCol) .. ". Using default colors.")
                    return
                else
                    colors[idx] = tCol
                    idx = idx + 1
                end
            end

            if idx < 2 then
                minetest.log("error",
                        "[auroras] At least two colors are required. " ..
                        "Using default colors.")
                return
            end

            auroras.COLOR_LUT = colors
        end
    end)()

    -- Color list from settings was nonexistent or malformed.
    if auroras.COLOR_LUT == nil then
        auroras.COLOR_LUT = {}
        local idx = 0
        for _, hexCol in pairs(auroras.COLORS) do
            local tCol = auroras.parse_hex_color(hexCol)
            if tCol ~= nil then
                auroras.COLOR_LUT[idx] = tCol
                idx = idx + 1
            end
        end
    end
end

function auroras.init_noise()
    local params = auroras.NOISE_PARAMS
    params.seed = os.time()
    auroras.noise = PerlinNoise(params)
end

function auroras.get_noise(pos)
    -- Returns noise based on x/z position and time.
    return auroras.noise:get_3d({
        x = pos.x,
        -- Mod by 2^20 because the noise generator can't handle large numbers.
        y = os.clock() % (2^20),
        z = pos.z
    })
end

function auroras.noise_curve(x)
    -- Map values onto an s-curve similar to a smoothstep function.
    -- Without this, numbers close to 1 almost never appear.
    -- Equivalent to -0.5x^3 + 1.5x
    return (-0.5 * x * x + 1.5) * x
end

function auroras.init_biome_params()
    -- Add biome transition so that strength will still be 1 at the limits.
    auroras.HEAT_MEAN = (auroras.HEAT_MIN + auroras.HEAT_MAX) * 0.5
    auroras.HEAT_SPREAD = (auroras.HEAT_MAX - auroras.HEAT_MIN) * 0.5 +
                           auroras.BIOME_TRANSITION
    auroras.HUM_MEAN = (auroras.HUM_MIN + auroras.HUM_MAX) * 0.5
    auroras.HUM_SPREAD = (auroras.HUM_MAX - auroras.HUM_MIN) * 0.5 +
                          auroras.BIOME_TRANSITION
end

function auroras.get_local_strength(pos)
    -- No auroras underground!
    local heightStrength = auroras.clamp(
            (pos.y - auroras.HEIGHT_MIN) / auroras.HEIGHT_TRANSITION, 0.0, 1.0)

    -- Avoid getting biome data if we don't have to.
    if heightStrength == 0.0 then
        return 0.0
    end

    local bioData = minetest.get_biome_data(pos)

    local heatStrength = auroras.clamp(
        (-math.abs(bioData.heat - auroras.HEAT_MEAN) + auroras.HEAT_SPREAD) /
            auroras.BIOME_TRANSITION,
        0.0, 1.0
    )
    local humStrength = auroras.clamp(
        (-math.abs(bioData.humidity - auroras.HUM_MEAN) + auroras.HUM_SPREAD) /
            auroras.BIOME_TRANSITION,
        0.0, 1.0
    )

    return heightStrength * heatStrength * humStrength
end

function auroras.init_time_params()
    auroras.TIME_MEAN = (auroras.TIME_START + auroras.TIME_END) * 0.5
    auroras.TIME_SPREAD = (auroras.TIME_START - auroras.TIME_END) * 0.5
end

function auroras.get_time_strength()
    local timeOfDay = minetest.get_timeofday()
    return auroras.clamp(
        (math.abs(timeOfDay - auroras.TIME_MEAN) - auroras.TIME_SPREAD) /
            auroras.TRANSITION_TIME,
        0.0, 1.0
    )
end

function auroras.set_day_night_ratio(player, dnr)
    player:override_day_night_ratio(dnr)
end

function auroras.set_sky(player, sky)
    if auroras.USE_CLIMATE_API then
        -- Just save the sky.
        local pName = player:get_player_name()
        auroras.player_data[pName].current_sky = sky
    else
        player:set_sky(sky)
    end
end

function auroras.save_sky(player)
    local params = {player:get_sky()}
    local sky = {
        base_color =    params[1],
        type =          params[2],
        textures =      params[3],
        clouds =        params[4],
        sky_color =     player:get_sky_color()
    }

    auroras.player_data[player:get_player_name()].orig_sky = sky
end

function auroras.restore_sky(player)
    local pName = player:get_player_name()
    if auroras.player_data[pName] == nil or
       auroras.player_data[pName].orig_sky == nil then
        return
    end

    auroras.set_sky(player, auroras.player_data[pName].orig_sky)
    auroras.player_data[pName].orig_sky = nil
end

function auroras.get_base_sky_colors(playerData)
    if auroras.USE_CLIMATE_API or not playerData.orig_sky then
        return auroras.BASE_SKY, auroras.BASE_HORIZON
    else
        local origSkyColor = playerData.orig_sky.sky_color
        return origSkyColor.night_sky or auroras.BASE_SKY,
               origSkyColor.night_horizon or auroras.BASE_HORIZON
    end
end

function auroras.do_update()
    local timeStrength = auroras.get_time_strength()
    local isNight = timeStrength > 0.0

    -- Don't waste time on midday calls.
    if not isNight and not auroras.was_night then
        return
    end

    for _, player in ipairs(minetest.get_connected_players()) do
        local pName = player:get_player_name()

        if auroras.player_data[pName] == nil then
            auroras.player_data[pName] = {
                was_visible = false
            }
        end

        local isVisible = false
        local pos, biomeStrength, noiseVal
        -- Determine if an aurora is visible for this player.
        if isNight then
            pos = player:get_pos()
            biomeStrength = auroras.get_local_strength(pos)
            if biomeStrength > 0.0 then
                noiseVal = auroras.noise_curve(auroras.get_noise(pos))
                isVisible = noiseVal > auroras.NOISE_MIN
            end
        end

        if isVisible then
            -- Save sky before changing anything.
            if not auroras.USE_CLIMATE_API and
                    auroras.player_data[pName].orig_sky == nil then
                auroras.save_sky(player)
            end

            -- Transform noise for more or less aurora time.
            noiseVal = (noiseVal - auroras.NOISE_MIN) / (1 - auroras.NOISE_MIN)

            -- Determine strength of aurora based on time, biome, and natural
            -- fluctuations (noise).
            local noiseStrength = auroras.clamp(
                    noiseVal / auroras.NOISE_TRANSITION, 0.0, 1.0)
            local strength = timeStrength * biomeStrength * noiseStrength

            -- Get aurora color based on strength/noise.
            local fIdx = math.min(noiseVal, 1.0) * #auroras.COLOR_LUT
            local lowIdx = math.floor(fIdx)
            local highIdx = math.ceil(fIdx)
            local fac = fIdx - lowIdx

            local baseSky, baseHorizon =
                    auroras.get_base_sky_colors(auroras.player_data[pName])
            local skyColor = auroras.interp_colors(
                baseSky,
                auroras.interp_colors(
                    auroras.COLOR_LUT[lowIdx],
                    auroras.COLOR_LUT[highIdx],
                    fac
                ),
                strength
            )

            -- Set all sky colors for now, since gamma, etc. affects which is used.
            auroras.set_sky(player, {
                type = "regular",
                sky_color = {
                    night_sky =     skyColor,
                    dawn_sky =      skyColor,
                    day_sky =       skyColor,
                    night_horizon = baseHorizon,
                    dawn_horizon =  baseHorizon,
                    day_horizon =   baseHorizon,
                }
            })

            -- Set day/night ratio to lighten the sky during auroras.
            local dnr = auroras.BASE_DAY_NIGHT_RATIO * (1 - strength) +
                    auroras.DAY_NIGHT_RATIO * strength

            if dnr ~= auroras.player_data[pName].last_dnr then
                auroras.set_day_night_ratio(player, dnr)
                auroras.player_data[pName].last_dnr = dnr
            end
        elseif auroras.player_data[pName].was_visible then
            -- Was visible, but not any more.
            auroras.restore_sky(player)
            auroras.set_day_night_ratio(player, nil)
        end

        auroras.player_data[pName].was_visible = isVisible
    end

    auroras.was_night = isNight
end

function auroras.update()
    auroras.do_update()
    minetest.after(auroras.UPDATE_INTERVAL, auroras.update)
end

function auroras.on_player_leave(player, timed_out)
    auroras.player_data[player:get_player_name()] = nil
end

-- Functions for Climate API support

function auroras.climate_api_is_active(params)
    if params.player then
        local pName = params.player:get_player_name()
        if auroras.player_data[pName] and
                auroras.player_data[pName].was_visible then
            return true
        end
    end
    return false
end

function auroras.climate_api_get_effects(params)
    local data = {}

    if params.player then
        local pName = params.player:get_player_name()
        if auroras.player_data[pName] and
                auroras.player_data[pName].current_sky then
            data["climate_api:skybox"] = {
                sky_data = auroras.player_data[pName].current_sky,
                priority = auroras.CLIMATE_API_SKYBOX_PRIORITY
            }
        end
    end

    return data
end

--[[
    End of function definitions
]]

do
    auroras.get_settings()

    auroras.init_colors()
    auroras.init_noise()
    auroras.init_biome_params()
    auroras.init_time_params()

    -- TODO: Faster switching when player joins, time change, etc?
    minetest.register_on_leaveplayer(auroras.on_player_leave)

    -- If climate_api is enabled, register auroras as a weather.
    if auroras.USE_CLIMATE_API then
        climate_api.register_weather("auroras:aurora",
                auroras.climate_api_is_active,
                auroras.climate_api_get_effects)
    end

    minetest.after(auroras.UPDATE_INTERVAL, auroras.update)
end

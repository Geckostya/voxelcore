-- Debug panel logic ported from C++ create_debug_panel to Lua XML script.
-- Shows performance, world, player and selection info; provides simple time control.
-- All comments in this file are intentionally in English only.

local initialized = false

-- FPS tracking state
local fps = 0
local fpsMin = 0
local fpsMax = 0

-- Network throughput tracking (bytes per second)
local lastTotalDownload = 0
local lastTotalUpload = 0
local netSpeedString = "net: download: - B/s upload: - B/s"

-- Helpers
local function pad2(n)
    n = tonumber(n) or 0
    if n < 10 then return "0"..tostring(n) end
    return tostring(n)
end

local function bool_to_onoff(v)
    if v == nil then return "-" end
    if v then return "on" else return "off" end
end

-- Convert integer to binary string with fixed width
local function to_bin(n, bits)
    n = tonumber(n) or 0
    if bits == nil or bits <= 0 then bits = 1 end
    local s = ""
    for i = bits - 1, 0, -1 do
        local bit = (math.floor(n / (2 ^ i)) % 2)
        s = s .. tostring(bit)
    end
    return s
end

local function update_fps_minmax()
    local dt = time.delta()
    if dt <= 0 then dt = 0.000001 end
    fps = math.floor(1.0 / dt + 0.5)
    if fpsMin == 0 or fps < fpsMin then fpsMin = fps end
    if fpsMax == 0 or fps > fpsMax then fpsMax = fps end
end

local function fmt_vec3(x, y, z)
    if x == nil then return "--, --, --" end
    return string.format("%.2f, %.2f, %.2f", x, y, z)
end

local function safe_caption(blockid)
    -- Expect that the API exists and returns a valid string id
    return block.name(blockid)
end

local function update_player_info()
    local pid = hud.get_player()

    -- Targeted entity
    local eid = player.get_selected_entity(pid)
    if eid and eid ~= 0 and entities.exists(eid) then
        local def = entities.get_def(eid)
        local name = entities.def_name(def)
        document.dbg_target_entity.text = string.format("entity: %s uid: %d", tostring(name or "-"), eid)
    else
        document.dbg_target_entity.text = "entity: -"
    end

    -- Useful flags
    local flags = {}
    if player.is_flight(pid) then table.insert(flags, "flight") end
    if player.is_noclip(pid) then table.insert(flags, "noclip") end
    if player.is_infinite_items(pid) then table.insert(flags, "inf-items") end
    if player.is_instant_destruction(pid) then table.insert(flags, "insta-break") end
    if #flags == 0 then
        document.dbg_flags.text = "flags: -"
    else
        document.dbg_flags.text = "flags: "..table.concat(flags, ", ")
    end
end

local function update_world_and_misc()
    -- Audio counters
    local spk = audio.count_speakers()
    local strm = audio.count_streams()
    document.dbg_audio.text = string.format("audio: speakers: %d streams: %d", spk, strm)

    -- Frustum culling setting
    local frustum = core.get_setting("graphics.frustum-culling")
    document.dbg_frustum.text = "frustum-culling: "..bool_to_onoff(frustum)

    -- Chunks count and visible
    local chunks = world.count_chunks()
    local visibleChunks = render.get_visible_chunks()
    document.dbg_chunks.text = string.format("chunks: %d visible: %d", chunks, visibleChunks)

    -- Players
    local playersCount = 0
    for _ in pairs(player.get_all()) do playersCount = playersCount + 1 end
    local pid = hud.get_player() or 0
    document.dbg_players.text = string.format("players: %d local: %d", playersCount, pid)

    -- Entities (count and next id)
    local entitiesCount = 0
    for _ in pairs(entities.get_all()) do entitiesCount = entitiesCount + 1 end
    local nextId = render.get_entities_next_id()
    document.dbg_entities.text = string.format("entities: %d next: %d", entitiesCount, nextId)

    -- Seed
    local seed = world.get_seed()
    document.dbg_seed.text = "seed: "..tostring(seed)

    -- Time of day (HH:MM)
    local t = world.get_day_time()
    local totalMinutes = math.floor((t % 1.0) * 24 * 60 + 0.5)
    local hour = math.floor(totalMinutes / 60)
    local minute = totalMinutes % 60
    document.dbg_time_label.text = string.format("time: %s:%s", pad2(hour), pad2(minute))
    document.dbg_time_trk.value = t

    -- Mesh/Draw-calls and Particles (render module is guaranteed to exist)
    document.dbg_meshes.text = string.format("meshes: %d", render.get_meshes_count())
    document.dbg_draw_calls.text = string.format("draw-calls: %d", render.get_draw_calls())
    local p = render.get_particles_visible()
    local e = render.get_emitters_alive()
    document.dbg_particles.text = string.format("particles: %d emitters: %d", p, e)

    -- Selection details and block state
    local pid2 = hud.get_player()
    local selx, sely, selz = player.get_selected_block(pid2)
    local sid = nil
    if selx ~= nil then
        sid = block.get(selx, sely, selz)
    end
    if selx ~= nil and sid ~= -1 and sid ~= nil then
        document.dbg_selection_pos.text = string.format("x: %d y: %d z: %d", selx, sely, selz)
        local state = block.get_states(selx, sely, selz)
        local rotation, segment, userbits = block.decompose_state(state)
        document.dbg_block_state.text = string.format(
            "block: %d r:%d s:%s u:%s", sid, rotation[1], to_bin(segment, 3), to_bin(userbits, 8)
        )
        document.dbg_block_name.text = "name: "..safe_caption(sid)
    else
        document.dbg_selection_pos.text = "x: - y: - z: -"
        document.dbg_block_state.text = "block: -"
        document.dbg_block_name.text = "name: -"
    end
end

local function update_network_speed()
    local totalDownload = network.get_total_download()
    local totalUpload = network.get_total_upload()
    local down = totalDownload - (lastTotalDownload or 0)
    local up = totalUpload - (lastTotalUpload or 0)
    lastTotalDownload = totalDownload
    lastTotalUpload = totalUpload
    netSpeedString = string.format("net: download: %d B/s upload: %d B/s", math.max(down, 0), math.max(up, 0))
    document.dbg_net.text = netSpeedString
end

local function setup_teleport_boxes()
    -- Allows entering X/Y/Z and teleport on commit (Enter). Missing axes keep current value.
    local function try_teleport()
        local pid = hud.get_player()
        local px, py, pz = player.get_pos(pid)
        local tx = tonumber(document.dbg_tp_x.text)
        local ty = tonumber(document.dbg_tp_y.text)
        local tz = tonumber(document.dbg_tp_z.text)
        px = tx or px
        py = ty or py
        pz = tz or pz
        player.set_pos(pid, px, py, pz)
    end
    document.dbg_tp_x.consumer = try_teleport
    document.dbg_tp_y.consumer = try_teleport
    document.dbg_tp_z.consumer = try_teleport
end

function on_open()
    if initialized then return end
    initialized = true

    -- Initial placeholders
    document.dbg_fps.text = "FPS: --/--"
    update_player_info()
    update_world_and_misc()
    setup_teleport_boxes()

    -- Update FPS rapidly to capture min/max
    document.root:setInterval(16, function()
        update_fps_minmax()
        update_player_info()
        update_world_and_misc()
    end)

    -- Refresh text periodically
    document.root:setInterval(500, function()
        document.dbg_fps.text = string.format("FPS: %d/%d", fpsMax, fpsMin)
        fpsMin = fps
        fpsMax = fps
    end)

    -- Network speed once per second
    document.root:setInterval(1000, function()
        update_network_speed()
    end)
end

function on_close()
    initialized = false
    fps, fpsMin, fpsMax = 0, 0, 0
    lastTotalDownload, lastTotalUpload = 0, 0
end

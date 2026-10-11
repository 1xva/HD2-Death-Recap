-- HD2-Addon: mods/deathrecap/recap
-- Death Recap 2.1.0
local hd2 = require('mods/skyeshade/hd2runtime')
local mod = hd2.mod('mods/deathrecap/recap')

-- Stingray
local sr = rawget(_G, 'stingray')
if type(sr) ~= 'table' then
    mod:log('DeathRecap: stingray unavailable')
    return {version = '2.1.0'}
end

-- FFI
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or not ffi then
    mod:log('DeathRecap: ffi unavailable')
    return {version = '2.1.0'}
end

pcall(ffi.cdef, [[
    void *GetModuleHandleA(const char *name);
    void *GetCurrentProcess(void);
    int ReadProcessMemory(void *process, const void *address, void *buffer,
                          size_t size, size_t *read_count);
]])

local kernel32 = ffi.load('kernel32')
local process = kernel32.GetCurrentProcess()

local function module_base(name)
    local h = kernel32.GetModuleHandleA(name)
    if h == nil then return nil end
    return tonumber(ffi.cast('uintptr_t', h))
end

local GAME_BASE = module_base('game.dll')
if not GAME_BASE then
    mod:log('DeathRecap: game.dll not found')
    return {version = '2.1.0'}
end

-- Memory
local function read_u32(addr)
    local b = ffi.new('uint32_t[1]')
    local c = ffi.new('size_t[1]')
    if kernel32.ReadProcessMemory(process, ffi.cast('const void *', addr), b, 4, c) == 0 then return nil end
    if tonumber(c[0]) ~= 4 then return nil end
    return tonumber(b[0])
end

local function read_ptr(addr)
    local b = ffi.new('uintptr_t[1]')
    local c = ffi.new('size_t[1]')
    if kernel32.ReadProcessMemory(process, ffi.cast('const void *', addr), b, 8, c) == 0 then return nil end
    if tonumber(c[0]) ~= 8 then return nil end
    local v = tonumber(b[0])
    if v == nil or v == 0 then return nil end
    return v
end

local function read_cstring(addr, max_len)
    local b = ffi.new('char[?]', max_len)
    local c = ffi.new('size_t[1]')
    if kernel32.ReadProcessMemory(process, ffi.cast('const void *', addr), b, max_len, c) == 0 then return nil end
    if tonumber(c[0]) == 0 then return nil end
    local s = ffi.string(b)
    if s == '' then return nil end
    return s
end

-- Roster
local ROSTER_PTR    = 0x347ced8
local ROSTER_SLOTS  = 4
local ROSTER_STRIDE = 0xc0
local NAME_OFFSET   = 8
local NAME_MAX      = 0x78

local function peer_key(lo, hi) return string.format('%08X%08X', hi, lo) end

local function read_roster()
    local out = {}
    local roster = read_ptr(GAME_BASE + ROSTER_PTR)
    if not roster then return out end
    for slot = 0, ROSTER_SLOTS - 1 do
        local rec = roster + slot * ROSTER_STRIDE
        local lo, hi = read_u32(rec), read_u32(rec + 4)
        if lo and hi and (lo ~= 0 or hi ~= 0) then
            local name = read_cstring(rec + NAME_OFFSET, NAME_MAX)
            if name then out[peer_key(lo, hi)] = name end
        end
    end
    return out
end

local name_cache = {}
local function refresh_names()
    local new = read_roster()
    local changed = false
    for k, v in pairs(new) do if name_cache[k] ~= v then changed = true; break end end
    for k in pairs(name_cache) do if not new[k] then changed = true; break end end
    if changed then name_cache = new end
end

-- State
local LOCAL_PEER = nil
local history = {}
local last_death = nil

local function reset()
    history = {}
    last_death = nil
    LOCAL_PEER = nil
end

-- Core
local function add_pvp_damage(e)
    local attacker_name = name_cache[e.attacker_peer] or ('peer:' .. e.attacker_peer)
    history[#history+1] = {
        time = e.time,
        avatar = e.entity_id,
        damage = e.damage,
        health = e.health,
        max_health = e.max_health,
        attacker_name = attacker_name,
    }
    while #history > 20 do table.remove(history, 1) end
end

local function emit_pvp_death(e)
    if #history == 0 then return end

    local recent, total, last_hit = {}, 0, nil
    for _, h in ipairs(history) do
        if h.avatar == e.avatar_id and e.time - h.time >= 0 and e.time - h.time <= 15 then
            recent[#recent+1] = h
            total = total + (h.damage or 0)
            last_hit = h
        end
    end
    if not last_hit then return end

    last_death = {
        killer = last_hit.attacker_name,
        total_damage = total,
        hits = #recent,
        last_hit_damage = last_hit.damage,
        health_before = last_hit.health,
        max_health = last_hit.max_health,
        shown_at = os.clock(),
    }
    history = {}

    mod:log(string.format('DeathRecap: killed by "%s" — %d damage over %d hits',
        last_death.killer, last_death.total_damage, last_death.hits))
end

-- Events
hd2.events.on('mission_started', reset)
hd2.events.on('mission_ended', reset)

hd2.events.on('player_spawned', function(e)
    if e.local_player then
        LOCAL_PEER = e.peer
        refresh_names()
    end
end)

hd2.events.on('player_damaged', function(e)
    if not e.local_player then return end
    if not e.attacker_peer then return end
    if e.local_attacker then return end
    if e.attacker_peer == LOCAL_PEER then return end
    add_pvp_damage(e)
end)

hd2.events.on('player_died', function(e)
    if not e.local_player then return end
    if e.observed ~= 'dead_state' then return end
    emit_pvp_death(e)
end)

-- GUI — white on black
local FONT = 'core/performance_hud/debug'
local MATERIAL = 'core/performance_hud/debug'

local GUI = {
    width      = 520,
    height     = 200,
    offset_y   = 120,
    padding    = 24,
    line_step  = 34,
    bg_color   = {0, 0, 0, 220},
    text_color = {255, 255, 255, 255},
    title_size = 22,
    line_size  = 18,
    show_time  = 10,
}

local gui_handle, gui_world = nil, nil
local text_handles = {}
local current_sig = nil

local function safe_call(fn, ...)
    if fn == nil then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

local function get_viewport()
    local w, h = safe_call(sr.Application.resolution)
    if type(w) == 'number' and w > 0 then return w, h end
    return 1920, 1080
end

local function destroy_gui()
    if gui_handle then
        for _, h in ipairs(text_handles) do
            pcall(function() sr.Gui.destroy_text(gui_handle, h) end)
        end
        text_handles = {}
        pcall(function() sr.World.destroy_gui(gui_world, gui_handle) end)
        gui_handle, gui_world = nil, nil
        current_sig = nil
    end
end

local function ensure_gui()
    if gui_handle then return true end
    local world = safe_call(sr.Application.main_world)
    if world == nil then return false end
    local ok, g = pcall(sr.World.create_screen_gui, world, 'scale', 1, 1)
    if not ok or g == nil then return false end
    gui_handle, gui_world = g, world
    return true
end

local function draw_rect(x, y, z, w, h, c)
    if not gui_handle then return end
    local pos = safe_call(sr.Vector3, x, y, z)
    local size = safe_call(sr.Vector2, w, h)
    local col = safe_call(sr.Color, c[1], c[2], c[3], c[4])
    if not pos or not size or not col then return end
    pcall(sr.Gui.rect, gui_handle, pos, size, col)
end

local function draw_text(text, x, y, size, c)
    if not gui_handle then return end
    local pos = safe_call(sr.Vector2, x, y)
    local col = safe_call(sr.Color, c[1], c[2], c[3], c[4])
    if not pos or not col then return end
    local ok, id = pcall(sr.Gui.text, gui_handle, text, FONT, size, MATERIAL, pos, col)
    if ok and id then text_handles[#text_handles+1] = id end
end

local function draw_panel(s)
    local sw, sh = get_viewport()
    local w, h = GUI.width, GUI.height
    local x = (sw - w) * 0.5
    local y = (sh - h) * 0.5 + GUI.offset_y

    draw_rect(x, y, 100, w, h, GUI.bg_color)

    local px = x + GUI.padding
    local py = y + GUI.padding
    local step = GUI.line_step

    draw_text('KILLED BY:  ' .. tostring(s.killer or '?'),
        px, py, GUI.title_size, GUI.text_color)
    draw_text('Damage:  ' .. tostring(s.total_damage or '?') ..
        ' over ' .. tostring(s.hits or '?') .. ' hits',
        px, py + step, GUI.line_size, GUI.text_color)
    draw_text('Last hit:  ' .. tostring(s.last_hit_damage or '?'),
        px, py + step * 2, GUI.line_size, GUI.text_color)
    draw_text('HP before death:  ' .. tostring(s.health_before or '?') ..
        ' / ' .. tostring(s.max_health or '?'),
        px, py + step * 3, GUI.line_size, GUI.text_color)
end

local function sig_of(s)
    if not s then return 'none' end
    return tostring(s.killer) .. '|' .. tostring(s.total_damage) .. '|' ..
           tostring(s.hits) .. '|' .. tostring(s.last_hit_damage) .. '|' ..
           tostring(s.health_before)
end

local function tick_gui()
    if last_death and (os.clock() - last_death.shown_at) > GUI.show_time then
        last_death = nil
    end
    local sig = sig_of(last_death)
    if sig == current_sig then
        if last_death and not gui_handle then
            if ensure_gui() then draw_panel(last_death) end
        end
        return
    end
    current_sig = sig
    destroy_gui()
    if last_death and ensure_gui() then
        draw_panel(last_death)
    end
end

-- Update hook
local _ENV = _G
if not rawget(_ENV, 'DeathRecapInstalled') then
    rawset(_ENV, 'DeathRecapInstalled', true)
    local original_update = rawget(_ENV, 'update')
    rawset(_ENV, 'update', function(...)
        pcall(tick_gui)
        if type(original_update) == 'function' then return original_update(...) end
    end)
end

refresh_names()
hd2.every(5, refresh_names)

mod:log('DeathRecap 2.1.0 ready')
return {version = '2.1.0'}
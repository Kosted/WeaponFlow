-- Selected flashlight mode on the actual attached entity, read-only.
-- Evidence: analysis/native-flashlight-192554.md; exact build 25480438 only.
-- No game calls, input, or writes. Missing/failed reads never become Off.
local M = { version = "0.1.0" }
local MODES = { [0] = "Auto", [1] = "On", [2] = "Off" }
local PARTS_MANAGER = 0x3326a38
local FLASHLIGHT_MANAGER = 0x3326910
local INVALID_ENTITY = 0x3483c34

-- These are fail-closed read budgets, not assumed inventory/instance counts.
-- Actual index bounds always come from the current native registries.
local MAX_CAPACITY, MAX_HASH_CAPACITY = 262144, 1048576

local function u32(bytes, offset)
    if type(bytes) ~= "string" or #bytes < offset + 4 then error("truncated flashlight read", 0) end
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function hex(bytes)
    return (bytes:gsub(".", function(c) return string.format("%02X", c:byte()) end))
end
local function identity(bytes)
    if type(bytes) ~= "string" or #bytes ~= 24 then error("invalid flashlight entity size", 0) end
    return { resource_hex_le = hex(bytes:sub(1, 8)), eid = u32(bytes, 8),
        native_unit_id = u32(bytes, 12), network_object_id = u32(bytes, 16),
        flags = u32(bytes, 20), bytes_hex = hex(bytes) }
end
local function require_valid(condition, reason)
    if not condition then error(reason, 0) end
end
local function counts(read, manager, capacity_offset, total_offset, active_offset, label)
    local capacity = u32(read(manager + capacity_offset, 4), 0)
    local total = u32(read(manager + total_offset, 4), 0)
    local active = u32(read(manager + active_offset, 4), 0)
    require_valid(capacity >= 1 and capacity <= MAX_CAPACITY and total <= capacity and active <= total,
        label .. " registry count/capacity invalid or beyond read budget")
    return total, capacity, active
end

local function cached_index(value)
    return type(value) == "number" and value >= 0 and value < MAX_CAPACITY and value % 1 == 0
end

local function inspect_current(reader, snapshot, previous)
    if type(reader) ~= "table" or type(reader.transaction) ~= "function" or
       type(reader.guard_active) ~= "function" or
       type(snapshot) ~= "table" or snapshot.active_weapon_verified ~= true then
        return nil, "verified active native weapon snapshot required"
    end
    local weapon = snapshot.active_weapon
    if type(weapon) ~= "table" or type(weapon.entity) ~= "table" or
       type(weapon.bytes) ~= "string" or #weapon.bytes ~= 24 or
       type(weapon.entity.eid) ~= "number" or u32(weapon.bytes, 8) ~= weapon.entity.eid then
        return nil, "active weapon identity bytes unavailable"
    end
    return reader:transaction(function(read, ptr, lookup)
        reader:guard_active(snapshot, read, ptr, lookup)
        local game, eid = reader.game, weapon.entity.eid
        require_valid(type(game) == "number", "native game module unavailable")
        if previous then
            require_valid(previous.game_module == game and previous.avatar_bytes == snapshot.avatar_bytes and
                previous.weapon_eid == eid and previous.weapon_bytes == weapon.bytes,
                "flashlight watch active identity changed")
        end
        local invalid = u32(read(game + INVALID_ENTITY, 4), 0)
        -- Entity +20 bit 0 is not proven to mean alive and may encode authority.
        -- Foreign pickups must not be rejected by an assumed ownership flag.
        require_valid(eid ~= invalid, "active weapon entity is invalid")

        local parts = ptr(game + PARTS_MANAGER)
        local part_total, part_capacity = counts(read, parts, 0x258, 0x264, 0x268, "weapon parts")
        if previous then require_valid(parts == previous.parts_manager, "flashlight watch parts manager changed") end
        local part_index = previous and previous.parts_index or
            lookup(read(parts + 0x278, 20), eid, MAX_HASH_CAPACITY)
        require_valid(part_index ~= nil and part_index < part_total,
            "weapon parts registry entry unavailable")
        local part_entities, part_states = ptr(parts + 0x290), ptr(parts + 0x2a0)
        if previous then
            require_valid(part_entities == previous.parts_entity_array and part_states == previous.parts_state_array,
                "flashlight watch parts storage changed")
        end
        local weapon_pointer = ptr(part_entities + part_index * 8)
        if previous then require_valid(weapon_pointer == previous.parts_entity_pointer,
            "flashlight watch parts entity pointer changed") end
        require_valid(read(weapon_pointer, 24) == weapon.bytes,
            "weapon parts registry identity differs from active weapon")
        local part_address = part_states + part_index * 128
        -- The getter/cycler both use +0x64 specifically, not a nearby module.
        local module_eid = u32(read(part_address + 0x64, 4), 0)
        local result = { weapon_eid = eid, weapon_bytes = weapon.bytes,
            source = "native_attachment_flashlight", parts_manager = parts,
            parts_index = part_index, parts_capacity = part_capacity,
            game_module = game, avatar_bytes = snapshot.avatar_bytes,
            parts_entity_array = part_entities, parts_state_array = part_states,
            parts_entity_pointer = weapon_pointer,
            module_eid = module_eid }
        if previous then require_valid(module_eid == previous.module_eid and module_eid ~= invalid,
            "flashlight watch attachment changed") end
        if module_eid == invalid then
            result.present = false
            result.reason = "current weapon part record explicitly has no flashlight attachment"
            return result
        end

        local lights = ptr(game + FLASHLIGHT_MANAGER)
        local total, capacity = counts(read, lights, 0x08, 0x10, 0x14, "flashlight")
        if previous then require_valid(lights == previous.flashlight_manager,
            "flashlight watch light manager changed") end
        local index = previous and previous.flashlight_index or
            lookup(read(lights + 0x28, 20), module_eid, MAX_HASH_CAPACITY)
        -- Lookup miss can also mean settling/registry change/probe budget. It
        -- is unknown, not proof that the selected mode is Off or absent.
        require_valid(index ~= nil and index < total, "attached flashlight registry entry unavailable")
        local light_entities, light_states = ptr(lights + 0x40), ptr(lights + 0x50)
        if previous then
            require_valid(light_entities == previous.flashlight_entity_array and
                light_states == previous.flashlight_state_array, "flashlight watch light storage changed")
        end
        local module_pointer = ptr(light_entities + index * 8)
        if previous then require_valid(module_pointer == previous.module_entity_pointer,
            "flashlight watch module entity pointer changed") end
        local module_bytes = read(module_pointer, 24)
        if previous then require_valid(module_bytes == previous.module_bytes,
            "flashlight watch module identity changed") end
        local module = identity(module_bytes)
        require_valid(module.eid == module_eid,
            "attached flashlight entity identity mismatch")
        local address = light_states + index * 8 + 4
        if previous then require_valid(address == previous.state_address,
            "flashlight watch state address changed") end
        local selected = u32(read(address, 4), 0)
        require_valid(MODES[selected] ~= nil, "flashlight selected enum outside Auto/On/Off")
        result.present, result.selected, result.selected_name = true, selected, MODES[selected]
        result.offered_values = { 0, 1, 2 }
        result.module_entity, result.module_bytes = module, module_bytes
        result.module_entity_pointer, result.state_address = module_pointer, address
        result.flashlight_manager, result.flashlight_index = lights, index
        result.flashlight_capacity = capacity
        result.flashlight_entity_array, result.flashlight_state_array = light_entities, light_states
        return result
    end, previous and "flashlight watch" or "flashlight inspect")
end

function M.inspect(reader, snapshot)
    return inspect_current(reader, snapshot)
end

function M.watch(reader, snapshot, previous)
    -- Cache only a fully resolved attachment. Absence, relocation, compaction
    -- or read failure requires a fresh inspect; none proves an Off value.
    if type(previous) ~= "table" or previous.present ~= true or
       previous.source ~= "native_attachment_flashlight" or
       not cached_index(previous.parts_index) or not cached_index(previous.flashlight_index) or
       type(previous.module_bytes) ~= "string" or #previous.module_bytes ~= 24 or
       u32(previous.module_bytes, 8) ~= previous.module_eid or
       type(snapshot) ~= "table" or type(snapshot.avatar_bytes) ~= "string" or #snapshot.avatar_bytes ~= 24 then
        return nil, "resolved flashlight watch snapshot required"
    end
    -- The shared transaction verifies the build and repeats every read,
    -- including guard_active's full avatar/weapon chain. Only component hash
    -- walks are skipped. Current counts may grow while our rows stay intact.
    return inspect_current(reader, snapshot, previous)
end

-- Coordinator metadata only. This module never casts/calls this address.
-- Generic cycle also runs native notifications/remembered-function logic;
-- direct local setter 0x74d640 does not provide the same side effects.
M.cycle = { rva = 0x7552d0, function_kind = 5,
    signature_hex = "48895C24204489442418555657415641574883EC30",
    arguments = "RCX=WeaponDataManager, EDX=native weapon EID, R8D=5 (LightMode)",
    return_value = "void/unspecified; determine success from a fresh verified read",
    gates = "exact supported build and code signature; current active identity; present validated attachment; enum 0..2; revalidate identity and selected mode immediately before and after action" }
M.layout = { parts_manager_rva = PARTS_MANAGER, flashlight_manager_rva = FLASHLIGHT_MANAGER,
    invalid_entity_rva = INVALID_ENTITY, selected_mode_offset = 4, state_stride = 8,
    max_capacity_budget = MAX_CAPACITY, max_hash_capacity_budget = MAX_HASH_CAPACITY }
return M

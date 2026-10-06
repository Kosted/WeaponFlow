-- Pure serialization boundary for one fresh, guarded mode inspection.
-- No reads, inputs, callbacks or mode changes. Identity/context validation and
-- persistence belong to the caller. Returning only updates makes a partial
-- merge possible: skipped directions must leave existing preferences intact.
local M = { version = "0.1.0" }
local SIDES = { "left", "right", "up", "down" }
local KNOWN = {
    zeroing = { action = 1, maximum = 10000 },
    rpm = { action = 2, maximum = 100000 },
    firemode = { action = 3, maximum = 8, integer = true },
    laser_guide = { action = 6, maximum = 1, integer = true, zero_valid = true, slots = 2 },
    programmable_ammo = { action = 8, maximum = 350, integer = true, zero_valid = true, slots = 2 },
    secondary_fire = { action = 11, maximum = 1, integer = true, zero_valid = true, slots = 2 },
    binary_10 = { action = 10, maximum = 1, integer = true, zero_valid = true, slots = 2 },
}

local function finite(value)
    return type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function valid_value(value, kind, allow_empty)
    if not finite(value) or value < 0 or value > kind.maximum then return false end
    if kind.integer and value ~= math.floor(value) then return false end
    return value > 0 or kind.zero_valid or allow_empty
end

local function capture_direction(dir)
    if type(dir) ~= "table" then return nil, "direction inspection unavailable" end
    if dir.action_enum == 5 or dir.kind == "flashlight" then
        return nil, "flashlight is not managed by weapon presets"
    end
    if dir.present ~= true then
        return nil, dir.reason or "direction absent on current instance"
    end
    if dir.readable ~= true then
        return nil, dir.reason or "selected value is not reliably readable"
    end
    if dir.capture_supported == false then
        return nil, dir.reason or "selection cannot be represented unambiguously in saved defaults"
    end
    local kind = KNOWN[dir.kind]
    if not kind or dir.action_enum ~= kind.action then
        return nil, "direction kind has no verified selected-value reader"
    end
    local slot_count = kind.slots or 3
    if not finite(dir.slot) or dir.slot ~= math.floor(dir.slot) or
       dir.slot < 0 or dir.slot >= slot_count then
        return nil, "selected native slot is unavailable or invalid"
    end
    if type(dir.slot_values) ~= "table" then
        return nil, "native slot-to-value mapping unavailable"
    end
    -- Preserve the proven native slot count and positions. The public choices
    -- list can omit holes in RPM/optic/fire entries; ammo/guide have two slots.
    for slot = 1, slot_count do
        local value = dir.slot_values[slot]
        if not valid_value(value, kind, true) then
            return nil, "native slot-to-value mapping is invalid"
        end
        if dir.kind == "laser_guide" and value ~= slot - 1 then
            return nil, "laser guide slot-to-state mapping is invalid"
        end
    end
    if not valid_value(dir.current, kind, false) then
        return nil, "selected semantic value is invalid or absent"
    end
    if dir.slot_values[dir.slot + 1] ~= dir.current then
        return nil, "selected native slot and semantic value disagree"
    end
    local offered = false
    if type(dir.choices) == "table" then
        for _, value in ipairs(dir.choices) do
            if value == dir.current then offered = true; break end
        end
    end
    if not offered then return nil, "selected value is not currently offered" end

    -- Saving does not need cycle_supported. A reliable selection with a
    -- non-callable cycle (one choice, holes, duplicates) can be retained for a
    -- later compatible instance. Applying still requires the normal guards.
    -- Store scalars detached from the observation so a delayed single-press
    -- gesture commits the first press's data. Value+kind are the application
    -- target; a slot number alone may mean something else with another optic.
    return { slot = dir.slot + 1, kind = dir.kind, value = dir.current }
end

function M.capture(modes)
    local updates, skips = {}, {}
    local directions = type(modes) == "table" and modes.directions or nil
    for _, side in ipairs(SIDES) do
        local dir = type(directions) == "table" and directions[side] or nil
        local choice, reason = capture_direction(dir)
        if choice then updates[side] = choice else skips[side] = reason end
    end
    return updates, skips
end

local function empty_presets()
    return { { targets = {} }, { targets = {} }, { targets = {} } }
end

local function array_shape(values, count)
    if type(values) ~= "table" then return false end
    local found = 0
    for key in pairs(values) do
        if not finite(key) or key ~= math.floor(key) or key < 1 or key > count then return false end
        found = found + 1
    end
    if found ~= count then return false end
    for index = 1, count do if values[index] == nil then return false end end
    return true
end

local function ordered_slots(dir)
    if dir.capture_supported ~= nil and type(dir.capture_supported) ~= "boolean" then
        return nil, "capture support is not reliably known"
    end
    local kind = KNOWN[dir.kind]
    if not kind or dir.action_enum ~= kind.action then return nil, "unsupported direction kind" end
    local capacity = kind.slots or 3
    if not array_shape(dir.slot_values, capacity) then return nil, "native slot mapping has missing or extra slots" end
    local slots, seen, empty = {}, {}, false
    for index = 1, capacity do
        local value = dir.slot_values[index]
        if not valid_value(value, kind, true) then return nil, "native slot mapping contains an invalid value" end
        if value == 0 and not kind.zero_valid then
            empty = true
        else
            if empty then return nil, "native slot mapping contains a hole" end
            if seen[value] then return nil, "native slot mapping contains duplicate semantic values" end
            seen[value] = true
            slots[#slots + 1] = index
        end
    end
    if not array_shape(dir.choices, #slots) then return nil, "offered choice count disagrees with native slots" end
    local offered = {}
    for index = 1, #slots do
        local value = dir.choices[index]
        if not valid_value(value, kind, false) or not seen[value] or offered[value] then
            return nil, "offered choices disagree with native slots"
        end
        offered[value] = true
    end
    return slots
end

-- Describe a weapon with exactly one managed setting. Native function 5 or
-- the confirmed flashlight kind is excluded regardless of its direction or
-- unreadable/absent attachment.
-- Every other direction, including Down, participates in qualification.
-- Presence is authoritative only when explicitly known. No native work occurs.
function M.single_setting(modes)
    local directions = type(modes) == "table" and modes.directions or nil
    if type(directions) ~= "table" then return nil, "direction inspection unavailable" end
    local count, side = 0, nil
    for _, name in ipairs(SIDES) do
        local dir = directions[name]
        if type(dir) ~= "table" then
            return nil, name .. ": direction presence is not reliably known"
        end
        if dir.action_enum ~= 5 and dir.kind ~= "flashlight" then
            if type(dir.present) ~= "boolean" or dir.presence_unknown then
                return nil, name .. ": direction presence is not reliably known"
            end
            if dir.present then
                count, side = count + 1, name
            end
        end
    end
    if count ~= 1 then
        return { qualified = false, count = count, available_count = count,
            reason = "requires exactly one present non-flashlight direction" }
    end

    local dir = directions[side]
    local current, reason = capture_direction(dir)
    if not current then return nil, side .. ": " .. reason end
    -- These two readers establish fixed two-slot choices independently of
    -- setter readiness. Foreign guidance authority or an ammo dependency can
    -- temporarily prevent application without invalidating a read-only seed.
    -- Other kinds retain their cycle gate (notably zeroing's three-slot rule).
    local deferred_setter = dir.cycle_supported == false and
        (dir.kind == "programmable_ammo" or dir.kind == "laser_guide" or dir.kind == "secondary_fire")
    if dir.cycle_supported ~= true and not deferred_setter then
        return nil, side .. ": " .. (dir.reason or "native cycle is not supported")
    end
    local slots, slot_error = ordered_slots(dir)
    if not slots then return nil, side .. ": " .. slot_error end
    if #slots ~= 2 and #slots ~= 3 then return nil, side .. ": requires two or three distinct selectable values" end

    local choices = {}
    local selected_found = false
    for index, slot in ipairs(slots) do
        -- Copy the observation before selecting an alternate for validation.
        -- Shared maps remain read-only; every output record is detached.
        local alternate = {}
        for key, value in pairs(dir) do alternate[key] = value end
        alternate.slot, alternate.current = slot - 1, dir.slot_values[slot]
        local choice, choice_error = capture_direction(alternate)
        if not choice then return nil, side .. ": " .. choice_error end
        choices[index] = choice
        if slot == current.slot then selected_found = true end
    end
    if not selected_found then return nil, side .. ": selected native slot is not selectable" end
    return { qualified = true, side = side, count = #choices, available_count = count,
        choices = choices, selected = current, reason = "one managed setting with verified native slot order" }
end

-- Plan first-use presets without changing the weapon. The caller owns
-- freshness/identity validation and the atomic initial write. Unknown plans
-- must never be treated as a known ineligible weapon with empty defaults.
function M.seed(modes)
    local plan, reason = M.single_setting(modes)
    if not plan then return nil, reason end
    local presets = empty_presets()
    if not plan.qualified then
        return presets, { qualified = false, count = 0, available_count = plan.available_count,
            reason = plan.reason }
    end
    local position
    for index, choice in ipairs(plan.choices) do if choice.slot == plan.selected.slot then position = index; break end end
    for preset = 1, plan.count do
        local choice = plan.choices[(position + preset - 2) % plan.count + 1]
        presets[preset].targets[plan.side] = { slot = choice.slot, kind = choice.kind, value = choice.value }
    end
    return presets, { qualified = true, side = plan.side, count = plan.count,
        available_count = plan.available_count, reason = "current value followed by native cyclic slot order" }
end

return M

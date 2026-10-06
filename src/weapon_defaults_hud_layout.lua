-- Optional HUD position and displayed-direction preferences only. No weapon
-- mode settings, native memory or input writes.
local M = {}
local MAX_BYTES, MAX_WEAPONS = 65536, 1024
-- Bottom-left GUI coordinates: slightly above and right of screen centre.
local DEFAULT_X, DEFAULT_Y = 0.53, 0.55
local DISPLAYS,DISPLAY_INDEX={"icon","text","both"},{icon=1,text=2,both=3}
local SIDES = {"left", "right", "up", "down", "None"}
local SIDE_INDEX = {left=1,right=2,up=3,down=4,None=5}
local Layout = {}
Layout.__index = Layout

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end
local function valid_profile(value)
  return type(value) == "string" and #value == 17 and value:match("^%d+$") ~= nil
end
local function resource_id(value)
  if type(value) ~= "string" or #value ~= 16 or not value:match("^[0-9a-fA-F]+$") then
    return nil, "HUD weapon resource ID must be exactly 16 hexadecimal characters"
  end
  return value:lower()
end
local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end
local function emit(self, message)
  if self.log then pcall(self.log, message) end
end

local function parse(raw, profile)
  if type(raw) ~= "string" or #raw > MAX_BYTES or raw:find("%z") then
    return nil, "invalid HUD position file size/content"
  end
  local body = raw:gsub("^\239\187\191", "")
  local fields, selections, section, count = {}, {}, nil, 0
  local selected_fields
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1,1) ~= ";" and line:sub(1,1) ~= "#" then
      if line == "[hud]" and not section then section = "hud"
      elseif line:sub(1, 1) == "[" then
        local resource = line:match("^%[weapon:([0-9a-fA-F]+)%]$")
        local id = resource_id(resource)
        if not section or not id or selections[id] then return nil, "invalid or duplicate HUD weapon section" end
        count = count + 1
        if count > MAX_WEAPONS then return nil, "HUD weapon preferences exceed bounded limit" end
        selected_fields = {}
        selections[id] = selected_fields
        section = "weapon"
      else
        local key, value = line:match("^([a-z_]+)%s*=%s*(.-)%s*$")
        local destination = section == "hud" and fields or selected_fields
        if not section or not key or not destination or destination[key] ~= nil
          or (section == "hud" and key ~= "schema" and key ~= "profile_id" and key ~= "x" and key ~= "y"
            and key ~= "hotkey" and key ~= "requires_card" and key ~= "display")
          or (section == "weapon" and key ~= "direction") then
          return nil, "invalid HUD position field or section"
        end
        destination[key] = value
      end
    end
  end
  if fields.schema ~= "1" and fields.schema ~= "2" then return nil, "unsupported HUD position schema" end
  if fields.schema == "1" and (count > 0 or fields.hotkey or fields.requires_card or fields.display) then
    return nil, "schema1 cannot contain HUD weapon preferences or key configuration"
  end
  if fields.profile_id ~= profile then return nil, "HUD position profile ID mismatch" end
  if fields.display and not DISPLAY_INDEX[fields.display] then return nil,"invalid HUD display mode" end
  local result = {selections={},display=fields.display or "both"}
  for _, key in ipairs({"x", "y"}) do
    local token = fields[key]
    local value = type(token) == "string" and token:match("^%d+%.?%d*$") and tonumber(token)
    if not finite(value) or value < 0 or value > 1 then return nil, "invalid normalized HUD " .. key end
    result[key] = value
  end
  for id, values in pairs(selections) do
    if not SIDE_INDEX[values.direction] then return nil, "invalid or missing HUD direction" end
    result.selections[id] = values.direction
  end
  return result
end

local function serialize(self, selections, display)
  local lines = {"[hud]", "schema=2", "profile_id=" .. self.profile_id,
    string.format("x=%.12f", self.x), string.format("y=%.12f", self.y), "display="..display, ""}
  local resources = {}
  for id in pairs(selections) do resources[#resources + 1] = id end
  if #resources > MAX_WEAPONS then return nil, "HUD weapon preferences exceed bounded limit" end
  table.sort(resources)
  for _, id in ipairs(resources) do
    lines[#lines + 1], lines[#lines + 2], lines[#lines + 3] =
      "[weapon:" .. id .. "]", "direction=" .. selections[id], ""
  end
  local data = table.concat(lines, "\r\n")
  if #data > MAX_BYTES then return nil, "HUD settings file exceeds size limit" end
  return data
end

function Layout:set_bounds(rw, rh, boxw, boxh)
  if not finite(rw) or not finite(rh) or not finite(boxw) or not finite(boxh)
    or rw <= 16 or rh <= 16 or boxw < 0 or boxh < 0 or boxw > rw - 16 or boxh > rh - 16 then
    return nil, "invalid HUD bounds or HUD box larger than viewport"
  end
  self.rw, self.rh, self.boxw, self.boxh = rw, rh, boxw, boxh
  -- Keep the saved normalized preference through viewport/layout changes.
  -- position() clamps its display; only a deliberate move changes x/y.
  return true
end

function Layout:position()
  return clamp(self.x * self.rw, 8, self.rw - self.boxw - 8),
    clamp(self.y * self.rh, 8, self.rh - self.boxh - 8)
end

function Layout:_reset_motion()
  self.last_time, self.hold_time, self.dx, self.dy = nil, 0, nil, nil
end

-- Integral of speed: 12 px/s initially, quadratic ramp to 700 after 2s.
-- Integrating intervals makes the travelled distance independent of FPS.
local function distance(seconds)
  local ramp = math.min(seconds, 2)
  return 12 * ramp + (700 - 12) * ramp * ramp * ramp / 12
    + 700 * math.max(0, seconds - 2)
end

function Layout:move(time, intent)
  local dx, dy = type(intent) == "table" and intent.x, type(intent) == "table" and intent.y
  if not finite(time) or not finite(dx) or not finite(dy)
    or dx % 1 ~= 0 or dy % 1 ~= 0 or math.abs(dx) > 1 or math.abs(dy) > 1 then
    self:_reset_motion()
    return false, "invalid HUD movement intent/time"
  end
  if dx == 0 and dy == 0 then self:_reset_motion(); return false end
  if self.last_time == nil or dx ~= self.dx or dy ~= self.dy or time < self.last_time then
    self.last_time, self.hold_time, self.dx, self.dy = time, 0, dx, dy
    return false
  end
  local elapsed = math.min(0.1, time - self.last_time)
  self.last_time = time
  if elapsed <= 0 then return false end
  local next_hold = self.hold_time + elapsed
  local travel = (distance(next_hold) - distance(self.hold_time)) * self.rh / 1080
  self.hold_time = next_hold
  local diagonal = math.sqrt(dx * dx + dy * dy)
  local before_x, before_y = self:position()
  local x = clamp(before_x + travel * dx / diagonal, 8, self.rw - self.boxw - 8)
  local y = clamp(before_y + travel * dy / diagonal, 8, self.rh - self.boxh - 8)
  if x == before_x and y == before_y then return false end
  self.x, self.y, self.dirty = x / self.rw, y / self.rh, true
  return true
end

function Layout:_commit(selections, operation, display)
  display=display or self.display
  local data, serialization_error = serialize(self, selections, display)
  if not data then emit(self, "HUD_ERROR " .. serialization_error); return nil, serialization_error end
  local safe, written, reason = pcall(self.io.atomic_write, self.path, data, self.raw)
  if not safe then reason = tostring(written); written = nil end
  if not written then
    local message = "HUD " .. operation .. " save failed: " .. tostring(reason or "unknown I/O failure")
    if message ~= self.last_error then emit(self, "HUD_ERROR " .. message) end
    self.last_error = message
    return nil, message
  end
  local moved = self.dirty
  self.raw, self.dirty, self.last_error, self.selections = data, false, nil, selections
  self.display=display
  if moved then emit(self, string.format("HUD_POSITION x=%.6f y=%.6f", self.x, self.y)) end
  return true
end

function Layout:cycle_display()
  local next_display=DISPLAYS[DISPLAY_INDEX[self.display]%#DISPLAYS+1]
  local written,why=self:_commit(self.selections,"display",next_display)
  if not written then return nil,why end
  emit(self,"HUD_DISPLAY mode="..next_display)
  return next_display
end

function Layout:finish()
  self:_reset_motion()
  if not self.dirty then return true end
  return self:_commit(self.selections, "position")
end

function Layout:selection(resource)
  local id, reason = resource_id(resource)
  if not id then return nil, reason end
  return self.selections[id]
end

function Layout:set_selection(resource, side)
  local id, reason = resource_id(resource)
  if not id then return nil, reason end
  if not SIDE_INDEX[side] then return nil, "invalid HUD direction" end
  if self.selections[id] == side and not self.dirty then return side end
  local candidate = {}
  for other, value in pairs(self.selections) do candidate[other] = value end
  candidate[id] = side
  local written, error = self:_commit(candidate, "direction")
  if not written then return nil, error end
  emit(self, "HUD_SELECTION resource=" .. id .. " direction=" .. side)
  return side
end

function Layout:cycle_selection(resource, available_sides, initial_side)
  local id, reason = resource_id(resource)
  if not id then return nil, reason end
  -- A missing observation is not an empty weapon. Require an explicit dense
  -- list, and never fall back to all directions when the caller cannot read it.
  if type(available_sides) ~= "table" or getmetatable(available_sides) ~= nil then
    return nil, "HUD available directions must be a plain list"
  end
  local offered, count = {}, 0
  for key, side in next, available_sides do
    if not finite(key) or key % 1 ~= 0 or key < 1 or key > 4
      or type(side) ~= "string" or not SIDE_INDEX[side] or side == "None" then
      return nil, "invalid HUD available direction list"
    end
    if offered[side] then return nil, "duplicate HUD available direction" end
    offered[side], count = true, count + 1
  end
  for key = 1, count do
    if rawget(available_sides, key) == nil then return nil, "HUD available direction list has holes" end
  end
  local current = self.selections[id]
  if current == nil and initial_side ~= nil then
    if not SIDE_INDEX[initial_side] then return nil, "invalid initial HUD direction" end
    current = initial_side
  end
  local index = current and SIDE_INDEX[current] or 0
  -- Persisted choices are untouched during observation, even on an instance
  -- missing that module. Only this explicit press advances past unavailable
  -- directions, following native L/R/U/D order with a final hidden state.
  for offset = 1, #SIDES do
    local side = SIDES[(index + offset - 1) % #SIDES + 1]
    if side == "None" or offered[side] then return self:set_selection(id, side) end
  end
end

function M.new(store, log)
  if type(store) ~= "table" or not valid_profile(store.profile_id) or type(store.path) ~= "string"
    or store.path:find("%z") or not store.path:match("%.[iI][nN][iI]$")
    or type(store.io) ~= "table" or type(store.io.read) ~= "function"
    or type(store.io.atomic_write) ~= "function" or (log ~= nil and type(log) ~= "function") then
    return nil, "invalid HUD layout profile/path/I/O adapter"
  end
  local path = store.path:sub(1, -5) .. "-HUD.ini"
  local self = setmetatable({profile_id=store.profile_id,path=path,io=store.io,log=log,
    x=DEFAULT_X,y=DEFAULT_Y,dirty=false,selections={},display="both"}, Layout)
  self:set_bounds(1920, 1080, 256, 80)
  self:_reset_motion()
  local safe, raw, reason = pcall(self.io.read, path, MAX_BYTES)
  if not safe then reason = tostring(raw); raw = nil end
  if raw == nil then
    if not safe or reason ~= "missing" then
      local message = "HUD position read failed: " .. tostring(reason or "unknown I/O failure")
      emit(self, "HUD_ERROR " .. message)
      return nil, message
    end
  else
    local values, error = parse(raw, self.profile_id)
    if not values then emit(self, "HUD_ERROR " .. error); return nil, error end
    self.x, self.y, self.selections, self.display = values.x, values.y, values.selections, values.display
  end
  self.raw = raw
  return self
end

return M

-- Game-owned WeaponFlow commands through Mod Bindings Menu v2.1.
-- Read the actual card control, numbered save keys and HUD movement locally.
-- Fixed F9/C/V and menu-key double taps are scoped to visible contextual help.
-- Never inject input or identify an equipped weapon from a button press.
local M = {}

local MAX_FILE = 1024 * 1024
local STEAM_KEY = [[Software\Valve\Steam]]
local ACTIVE_KEY = [[Software\Valve\Steam\ActiveProcess]]

-- Steam IDs remain strings. Only the low 32 bits are computed as an exactly
-- representable Lua number, for matching Steam's ActiveUser / userdata folder.
local function account_directory(id)
  if type(id) ~= "string" or not id:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
    return nil
  end
  local n = 0
  for digit in id:gmatch("%d") do n = (n * 10 + tonumber(digit)) % 4294967296 end
  return string.format("%.0f", n)
end

-- Bounded SJSON / VDF parser; no loadstring, eval, or pattern matching across
-- quoted braces. Input overrides may contain empty arrays and comments.
local function parse(body)
  if type(body) ~= "string" or #body > MAX_FILE then return nil, "invalid file size" end
  if body:sub(1, 3) == "\239\187\191" then body = body:sub(4) end
  local i, token, kind, depth = 1, nil, nil, 0
  local function advance()
    while true do
      local _, ending = body:find("^%s+", i)
      if ending then i = ending + 1 end
      if body:sub(i, i + 1) == "//" then
        i = (body:find("\n", i + 2, true) or #body) + 1
      elseif body:sub(i, i + 1) == "/*" then
        local ending_comment = assert(body:find("*/", i + 2, true), "unterminated comment")
        i = ending_comment + 2
      else break end
    end
    local c = body:sub(i, i)
    if c == "" then token, kind = nil, nil; return end
    if c == '"' then
      local parts = {}; i = i + 1
      while i <= #body do
        c = body:sub(i, i); i = i + 1
        if c == '"' then token, kind = table.concat(parts), "string"; return end
        if c == "\\" then
          local escaped = body:sub(i, i); i = i + 1
          local values = {n="\n",r="\r",t="\t",['"']='"',["\\"]="\\",["/"]="/"}
          assert(values[escaped], "unsupported string escape")
          c = values[escaped]
        end
        parts[#parts + 1] = c
      end
      error("unterminated string")
    elseif c:match("[{}%[%]=,]") then
      token, kind, i = c, "punct", i + 1
    else
      local word = body:match("^[^%s{}%[%]=,]+", i)
      assert(word and word ~= "", "invalid token")
      token, kind, i = word, "word", i + #word
    end
  end
  local value
  local function object(closing)
    local out = setmetatable({}, {__kind="object"})
    while token and token ~= closing do
      assert(kind == "string" or kind == "word", "object key expected")
      local key = token; advance()
      assert(out[key] == nil, "duplicate key: " .. key)
      if token == "=" then advance() end
      out[key] = value()
      if token == "," then advance() end
    end
    if closing then assert(token == closing, "unterminated object"); advance() end
    return out
  end
  value = function()
    depth = depth + 1; assert(depth <= 24, "input nesting limit")
    local result
    if token == "{" then advance(); result = object("}")
    elseif token == "[" then
      advance(); result = setmetatable({}, {__kind="array"})
      while token and token ~= "]" do
        result[#result + 1] = value()
        if token == "," then advance() end
      end
      assert(token == "]", "unterminated array"); advance()
    else
      assert(token and kind ~= "punct", "value expected")
      if kind == "string" then result = token
      elseif token == "true" then result = true
      elseif token == "false" then result = false
      else result = assert(tonumber(token), "invalid scalar") end
      advance()
    end
    depth = depth - 1
    return result
  end
  local ok, result = pcall(function() advance(); return object(nil) end)
  if not ok then return nil, tostring(result) end
  return result
end

local function native_adapter()
  local ffi = require("ffi")
  local win, registry, user = ffi.load("kernel32"), ffi.load("advapi32"), ffi.load("user32")
  -- Other addons may declare DWORD as unsigned int rather than unsigned long.
  -- Both have the same Windows ABI, but FFI pointer checks differ. Cast every
  -- imported function to our exact local signature before supplying buffers.
  local function bind(dll, name, result, args)
    local ok, fn = pcall(function() return dll[name] end)
    if not ok then
      ffi.cdef(result .. " __stdcall " .. name .. args .. ";")
      fn = dll[name]
    end
    return ffi.cast(result .. " (__stdcall *)" .. args, fn)
  end
  local get_registry = bind(registry,"RegGetValueW","long",
    "(void *, const unsigned short *, const unsigned short *, unsigned long, unsigned long *, void *, unsigned long *)")
  local get_key = bind(user,"GetAsyncKeyState","short","(int)")
  local map_key = bind(user,"MapVirtualKeyW","unsigned int","(unsigned int, unsigned int)")
  local to_wide = bind(win,"MultiByteToWideChar","int",
    "(unsigned int, unsigned long, const char *, int, unsigned short *, int)")
  local to_utf8 = bind(win,"WideCharToMultiByte","int",
    "(unsigned int, unsigned long, const unsigned short *, int, char *, int, const char *, int *)")
  local open_file = bind(win,"CreateFileW","void *",
    "(const unsigned short *, unsigned long, unsigned long, void *, unsigned long, unsigned long, void *)")
  local file_size = bind(win,"GetFileSizeEx","int","(void *, int64_t *)")
  local read_file = bind(win,"ReadFile","int","(void *, void *, unsigned long, unsigned long *, void *)")
  local close_file = bind(win,"CloseHandle","int","(void *)")
  local last_error = bind(win,"GetLastError","unsigned long","(void)")
  local get_keyboard_state
  local hkcu = ffi.cast("void *", ffi.cast("intptr_t", -2147483647))
  local function wide(s)
    local n = to_wide(65001, 8, s, #s, nil, 0)
    if n <= 0 then error("invalid UTF-8 path") end
    local result = ffi.new("unsigned short[?]", n + 1)
    assert(to_wide(65001, 8, s, #s, result, n) == n)
    return result
  end
  local function utf8(s, n)
    local len = to_utf8(65001, 0, s, n, nil, 0, nil, nil)
    if len <= 0 then return nil end
    local out = ffi.new("char[?]", len)
    if to_utf8(65001, 0, s, n, out, len, nil, nil) ~= len then return nil end
    return ffi.string(out, len)
  end
  return {
    registry_string = function(key, name)
      local buffer, size = ffi.new("unsigned short[4096]"), ffi.new("unsigned long[1]", 8192)
      if get_registry(hkcu, wide(key), wide(name), 2, nil, buffer, size) ~= 0 then return nil end
      return utf8(buffer, tonumber(size[0]) / 2 - 1)
    end,
    registry_dword = function(key, name)
      local buffer, size = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]", 4)
      if get_registry(hkcu, wide(key), wide(name), 16, nil, buffer, size) ~= 0 then return nil end
      return tonumber(buffer[0])
    end,
    read_file = function(path)
      local handle = open_file(wide(path), 0x80000000, 7, nil, 3, 0x80, nil)
      if handle == nil or handle == ffi.cast("void *", ffi.cast("intptr_t", -1)) then
        local code = tonumber(last_error())
        if code == 2 or code == 3 then return nil, "missing" end
        return nil, "file unavailable (Win32 " .. tostring(code) .. ")"
      end
      local ok, body = pcall(function()
        local size = ffi.new("int64_t[1]")
        assert(file_size(handle, size) ~= 0, "file size unavailable")
        local n = tonumber(size[0]); assert(n >= 0 and n <= MAX_FILE, "input file exceeds limit")
        if n == 0 then return "" end
        local buffer, got = ffi.new("char[?]", n), ffi.new("unsigned long[1]")
        assert(read_file(handle, buffer, n, got, nil) ~= 0 and tonumber(got[0]) == n,
          "incomplete file read")
        return ffi.string(buffer, n)
      end)
      close_file(handle)
      if not ok then return nil, tostring(body) end
      return body
    end,
    getenv = os.getenv,
    map_scan = function(scan) return tonumber(map_key(scan, 3)) end,
    key_down = function(vk) return tonumber(get_key(vk)) < 0 end,
    -- Read-only thread-key snapshot. Unlike GetAsyncKeyState this does
    -- not clear its shared legacy pressed bit. It is not proof of physical
    -- input, a game-consumed event, or a completed grenade throw.
    diagnostic_keys = function()
      get_keyboard_state = get_keyboard_state or
        bind(user,"GetKeyboardState","int","(unsigned char *)")
      local buffer = ffi.new("unsigned char[256]")
      if get_keyboard_state(buffer) == 0 then return nil, "thread key state unavailable" end
      local keys = {}
      for vk = 1, 255 do keys[vk] = tonumber(buffer[vk]) >= 128 end
      return keys
    end,
  }
end

local EXTENDED = {
  ["right ctrl"]=true,["right alt"]=true,["up"]=true,["down"]=true,
  ["left"]=true,["right"]=true,["home"]=true,["end"]=true,["page up"]=true,
  ["page down"]=true,["insert"]=true,["delete"]=true,["numpad /"]=true,["numpad enter"]=true,
}
local MOUSE = {MouseButtonLeft=1,MouseButtonRight=2,MouseButtonMiddle=4,MouseButton4=5,MouseButton5=6}
local KEYS = {SPACE=32,TAB=9,ENTER=13,ESCAPE=27,BACKSPACE=8,INSERT=45,DELETE=46,
  HOME=36,END=35,PAGEUP=33,PAGEDOWN=34,UP=38,DOWN=40,LEFT=37,RIGHT=39,
  LSHIFT=160,RSHIFT=161,LCTRL=162,RCTRL=163,LALT=164,RALT=165,CAPSLOCK=20,
  ["LEFTSHIFT"]=160,["RIGHTSHIFT"]=161,["LEFTCTRL"]=162,["RIGHTCTRL"]=163,
  ["LEFTALT"]=164,["RIGHTALT"]=165,
  MINUS=189,EQUALS=187,LEFTBRACKET=219,RIGHTBRACKET=221,BACKSLASH=220,
  SEMICOLON=186,QUOTE=222,COMMA=188,PERIOD=190,SLASH=191,
  GRAVE=192,TILDE=192,BACKTICK=192,GRAVEACCENT=192,OEM3=192,["`"]=192,["~"]=192,
  PAUSE=19,PRINTSCREEN=44,NUMLOCK=144,SCROLLLOCK=145,OEM102=226,
  MOUSE1=1,MOUSE2=2,MOUSE3=4,MOUSE4=5,MOUSE5=6,
  MOUSEBUTTONLEFT=1,MOUSEBUTTONRIGHT=2,MOUSEBUTTONMIDDLE=4,MOUSEBUTTON4=5,MOUSEBUTTON5=6,
  NUMPADMULTIPLY=106,NUMPADADD=107,NUMPADSUBTRACT=109,NUMPADDECIMAL=110,NUMPADDIVIDE=111}
-- Intent only: positive x moves right, positive y moves up. The HUD owns
-- acceleration, coordinate scaling and persistence, not this input reader.
local HUD_ARROWS = {
  {vk=37,name="Left",x=-1,y=0}, {vk=39,name="Right",x=1,y=0},
  {vk=38,name="Up",x=0,y=1}, {vk=40,name="Down",x=0,y=-1},
}
function M.hotkey_vk(name)
  if type(name) ~= "string" then return nil, "hotkey must be a key name" end
  local key = name:upper():gsub("[%s_%-]", "")
  if key:match("^[A-Z0-9]$") then return key:byte() end
  local f = tonumber(key:match("^F(%d+)$"))
  if f and f >= 1 and f <= 24 then return 111 + f end
  local n = tonumber(key:match("^NUMPAD(%d)$"))
  if n then return 96 + n end
  if KEYS[key] then return KEYS[key] end
  return nil, "unsupported hotkey: " .. name
end

-- Display labels for supported native keyboard/mouse buttons and card controls.
local KEY_LABELS = {}
local function label_key(vk, name)
  KEY_LABELS[vk] = name
end
for vk = 48, 57 do label_key(vk, string.char(vk)) end
for vk = 65, 90 do label_key(vk, string.char(vk)) end
for n = 1, 24 do label_key(111 + n, "F" .. n) end
for n = 0, 9 do label_key(96 + n, "Numpad" .. n) end
for _, item in ipairs({{1,"Mouse1"},{2,"Mouse2"},{4,"Mouse3"},{5,"Mouse4"},{6,"Mouse5"},
  {8,"Backspace"},{9,"Tab"},{13,"Enter"},{19,"Pause"},{20,"CapsLock"},{27,"Escape"},
  {32,"Space"},{33,"PageUp"},{34,"PageDown"},{35,"End"},{36,"Home"},{37,"Left"},
  {38,"Up"},{39,"Right"},{40,"Down"},{44,"PrintScreen"},{45,"Insert"},{46,"Delete"},
  {106,"NumpadMultiply"},{107,"NumpadAdd"},{109,"NumpadSubtract"},{110,"NumpadDecimal"},
  {111,"NumpadDivide"},{144,"NumLock"},{145,"ScrollLock"},{160,"LShift"},{161,"RShift"},
  {162,"LCtrl"},{163,"RCtrl"},{164,"LAlt"},{165,"RAlt"},{186,"Semicolon"},
  {187,"Equals"},{188,"Comma"},{189,"Minus"},{190,"Period"},{191,"Slash"},
  {192,"Tilde"},{219,"LeftBracket"},{220,"Backslash"},{221,"RightBracket"},
  {222,"Quote"},{226,"OEM102"}}) do label_key(item[1], item[2]) end

local function group_label(group)
  local labels = {}
  for _, binding in ipairs(group) do
    -- The resolved VK follows the current scan mapping. The config's input
    -- text can still say "r" after that physical binding has moved elsewhere.
    local label = KEY_LABELS[binding.vk]
    if not label then return nil end
    labels[#labels + 1] = label
  end
  if #labels > 0 then return table.concat(labels, " + ") end
end

local function binding_vk(entry, adapter)
  if type(entry) ~= "table" or (entry.input_type and entry.input_type ~= "Button") then return nil end
  if type(entry.input) ~= "string" then return nil end
  if entry.device_type == "Mouse" then return MOUSE[entry.input] end
  if entry.device_type ~= "Keyboard" then return nil end
  local scan = entry.fixed_layout_id
  if scan ~= nil then
    if type(scan) ~= "number" or scan % 1 ~= 0 or scan < 1 or scan > 255 then return nil end
    local extended = scan >= 128 or EXTENDED[entry.input:lower()]
    if scan >= 128 then scan = scan - 128 end
    local vk = adapter.map_scan(scan + (extended and 0xe000 or 0))
    return vk and vk > 0 and vk or nil
  end
  return M.hotkey_vk(entry.input)
end

local function binding_groups(entries, resolve, action)
  local groups, pending, unsupported, chained = {}, {}, 0, false
  for _, entry in ipairs(entries) do
    local vk = resolve(entry)
    if not vk then unsupported = unsupported + 1 end
    pending[#pending + 1] = {vk=vk, name=type(entry)=="table" and entry.input or "invalid",
      trigger=type(entry)=="table" and entry.trigger or nil}
    local combine = type(entry)=="table" and entry.combine or nil
    if combine == "Chain" then chained = true end
    if combine ~= "Overlap" and combine ~= "Chain" then
      local group, valid = {}, not chained and (combine == nil or combine == "None")
      for _, item in ipairs(pending) do
        if not item.vk then valid = false end
        group[#group + 1] = item
      end
      if valid then groups[#groups + 1] = group end
      pending, chained = {}, false
    end
  end
  if #pending > 0 then return nil, "unterminated " .. action .. " overlap" end
  return groups, nil, unsupported
end

local function load_bindings(config, adapter)
  if config.Avatar ~= nil and type(config.Avatar) ~= "table" then return nil, "invalid Avatar block" end
  local avatar = config.Avatar or {}
  local resolved = {}
  local function resolve(entry)
    if type(entry) ~= "table" then return nil end
    if resolved[entry] == nil then resolved[entry] = binding_vk(entry, adapter) or false end
    return resolved[entry] or nil
  end
  local entries, source = avatar.WeaponFunctionOpen, "player_override"
  if entries == nil then
    -- Official default (only when override absent):
    -- https://content.thehelldiversgame.com/help/inputs.md#default-bindings
    entries = {{device_type="Keyboard",input="r",input_type="Button",trigger="LongPress",fixed_layout_id=19}}
    source = "official_default"
  elseif type(entries) ~= "table" or not getmetatable(entries) or getmetatable(entries).__kind ~= "array" then
    return nil, "WeaponFunctionOpen must be an array"
  end
  local groups, group_error, unsupported = binding_groups(entries, resolve, "WeaponFunctionOpen")
  if not groups then return nil, group_error end
  return groups, nil, source, unsupported
end

local function grenade_bindings(config, adapter)
  local action = "ChangeEquipmentQuickGrenade"
  if type(config.Avatar) ~= "table" then return nil, action .. " unavailable" end
  local entries = config.Avatar[action]
  if entries == nil then return nil, action .. " has no explicit binding" end
  if type(entries) ~= "table" or not getmetatable(entries) or getmetatable(entries).__kind ~= "array" then
    return nil, action .. " must be an array"
  end
  local groups, reason = binding_groups(entries, function(entry) return binding_vk(entry, adapter) end, action)
  if not groups then return nil, reason end
  if #groups == 0 then return nil, action .. " has no supported keyboard/mouse binding" end
  local labels, signatures = {}, {}
  for _, group in ipairs(groups) do
    local label = group_label(group)
    if not label then return nil, action .. " binding label unavailable" end
    labels[#labels + 1] = label
    local signature = {}
    for _, binding in ipairs(group) do
      signature[#signature + 1] = tostring(binding.vk) .. ":" .. tostring(binding.trigger)
    end
    signatures[#signatures + 1] = table.concat(signature, "+")
  end
  return groups, nil, table.concat(labels, " / "), table.concat(signatures, "/")
end

-- Check only the known paths for this exact account. Missing override files
-- inherit the documented game defaults; access/read/parse failures never do.
local function read_candidates(adapter, candidates)
  for _, candidate in ipairs(candidates) do
    local body, reason = adapter.read_file(candidate)
    if body ~= nil then return body, candidate end
    if reason ~= "missing" then return nil, candidate, reason or "file unreadable" end
  end
  return "", candidates[1], nil, true
end

local function discover(adapter)
  local path = adapter.registry_string(STEAM_KEY, "SteamPath")
  if type(path) ~= "string" or path == "" then return nil, "SteamPath unavailable" end
  path = path:gsub("/", "\\"):gsub("[\\/]+$", "")
  local active = adapter.registry_dword(ACTIVE_KEY, "ActiveUser")
  if type(active) ~= "number" or active <= 0 or active % 1 ~= 0 then
    return nil, "active Steam account unavailable"
  end
  local login = adapter.read_file(path .. "\\config\\loginusers.vdf")
  local accounts, reason = parse(login)
  if not accounts or type(accounts.users) ~= "table" then
    return nil, "Steam loginusers.vdf unavailable or invalid: " .. tostring(reason)
  end
  local id, matches = nil, 0
  for steamid, entry in pairs(accounts.users) do
    if type(entry) == "table" and account_directory(steamid) == string.format("%.0f", active) then
      id, matches = steamid, matches + 1
    end
  end
  if matches ~= 1 then return nil, "active Steam account ambiguous or missing from loginusers.vdf" end
  local root = path .. "\\userdata\\" .. account_directory(id) .. "\\553850\\"
  local candidates = {root .. "remote\\input_settings.config",root .. "input_settings.config"}
  local appdata = adapter.getenv("APPDATA")
  if appdata and appdata ~= "" then
    candidates[#candidates + 1] = appdata .. "\\Arrowhead\\Helldivers2\\saves\\" .. id .. "_input_settings.config"
  end
  local _, selected = read_candidates(adapter, candidates)
  return {profile_id=id,account_id=active,input_path=selected,candidates=candidates}
end

function M.new(options)
  options = options or {}
  local ok, adapter = pcall(function() return options.adapter or native_adapter() end)
  if not ok then return nil, "Windows input API unavailable: " .. tostring(adapter) end
  local safe, info, err = pcall(discover, adapter)
  if not safe then return nil, "input discovery failed: " .. tostring(info) end
  if not info then return nil, err end
  local self = {profile_id=info.profile_id,input_path=info.input_path,account_id=info.account_id,
    bindings={},next_refresh=0,revision=0,profile_valid=false}
  local bindings_module=options.bindings_module or Bindings
  if type(bindings_module)~="table" then return nil,"WeaponFlow binding records unavailable" end
  local parsed_body, parsed_config
  local extra_keys, previous_foreground = {}, false
  local contextual={keys={},buttons={},taps={}}
  local help_keys={}
  local menu_tap
  local previous_hud_arrows = {}
  local grenade = {next_refresh=0}
  local grenade_enabled = false
  local function input_snapshot(expected_config)
    -- Mutation authorization uses fresh Steam discovery, not the ordinary
    -- two-second read cache. A path/account change cannot be mistaken for
    -- an empty profile or authorize writing the previous player's file.
    local found,why=discover(adapter)
    if not found then return nil,why end
    if found.profile_id~=self.profile_id or found.account_id~=self.account_id then
      return nil,"active Steam profile changed; restart required"
    end
    local body,selected,reason,missing=read_candidates(adapter,found.candidates)
    if body==nil then return nil,"input settings unreadable: "..tostring(reason) end
    if selected~=found.input_path then return nil,"active input settings path changed during discovery" end
    local config,failure=parse(body)
    if not config then return nil,"invalid input config: "..tostring(failure) end
    if expected_config~=nil and (expected_config~=parsed_config or body~=parsed_body) then
      return nil,"input settings changed after default eligibility read"
    end
    local raw=body
    if missing then raw=nil end
    return {path=selected,raw=raw,profile_id=found.profile_id}
  end
  local function validate_input_snapshot(snapshot)
    if type(snapshot)~="table" or snapshot.profile_id~=self.profile_id then
      return nil,"input persistence profile differs"
    end
    local current,why=input_snapshot()
    if not current then return nil,why end
    if current.path~=snapshot.path then return nil,"active input settings path changed" end
    if current.raw~=snapshot.raw then return nil,"input settings changed concurrently" end
    return true
  end
  -- Read-only proof of the active profile/path; never authorizes file writes.
  self.input_snapshot=input_snapshot
  self.validate_input_snapshot=validate_input_snapshot
  local menu_bindings
  self.menu_state=options.menu_state
  local menu_module=options.mod_bindings or ModBindings
  if type(menu_module)=="table" and type(menu_module.new)=="function" then
    local ready,value=pcall(menu_module.new,{read_file=adapter.read_file,getenv=adapter.getenv,
      get_menu=options.get_menu,get_loader=options.get_loader,native_reader=options.native_reader,
      read_binding=options.read_menu_binding,watch_binding=options.watch_menu_binding,
      read_event=options.read_menu_event,
      clear_bindings=options.clear_menu_bindings,get_engine=options.get_engine,
      replace_binding=options.replace_menu_binding,editor_open=options.editor_open,
      profile_id=self.profile_id,
      get_input_snapshot=input_snapshot,validate_input_snapshot=validate_input_snapshot})
    if ready then menu_bindings=value end
  end

  local function refresh_grenade(time)
    grenade.next_refresh = time + 2
    local ok, groups, reason, label, signature = pcall(function()
      if adapter.registry_dword(ACTIVE_KEY, "ActiveUser") ~= self.account_id then
        return nil, "active Steam account changed; restart required"
      end
      local body, _, read_error = read_candidates(adapter, info.candidates)
      if body == nil then return nil, "grenade input settings unreadable: " .. tostring(read_error) end
      if body ~= grenade.body then
        local config, failure = parse(body)
        if not config then return nil, "invalid grenade input config: " .. tostring(failure) end
        grenade.body, grenade.config = body, config
      end
      return grenade_bindings(grenade.config, adapter)
    end)
    if not ok then groups, reason, label, signature = nil, "grenade binding observation failed", nil, nil end
    if signature ~= grenade.signature then grenade.previous = nil end
    grenade.groups, grenade.reason, grenade.label, grenade.signature = groups, reason, label, signature
    if not groups then grenade.previous = nil end
  end

  local function observe_grenade(result, time, foreground)
    result.grenade_pressed = false
    if foreground ~= true then
      grenade.previous, grenade.next_refresh = nil, 0
      result.grenade_reason = "thread key observation requires foreground"
      return
    end
    if time >= grenade.next_refresh then refresh_grenade(time) end
    result.grenade_label, result.grenade_reason = grenade.label, grenade.reason
    if not grenade.groups then return end
    if adapter.diagnostic_keys == nil then
      grenade.previous = nil
      result.grenade_reason = "thread key snapshot API unavailable"
      return
    end
    local ok, keys, reason = pcall(adapter.diagnostic_keys)
    if not ok or type(keys) ~= "table" then
      grenade.previous = nil
      result.grenade_reason = ok and (reason or "thread key snapshot unavailable") or "thread key snapshot failed"
      return
    end
    local current, pressed = {}, false
    for index, group in ipairs(grenade.groups) do
      local all = true
      for _, binding in ipairs(group) do
        if type(keys[binding.vk]) ~= "boolean" then
          grenade.previous = nil
          result.grenade_reason = "incomplete thread key snapshot"
          return
        end
        all = all and keys[binding.vk]
      end
      current[index] = all
      if grenade.previous and all and not grenade.previous[index] then pressed = true end
    end
    if pressed then
      -- Revalidate the active account/file/layout before reporting an edge.
      -- This refresh never changes Save/card readiness, revision or bindings.
      local signature = grenade.signature
      refresh_grenade(time)
      result.grenade_label, result.grenade_reason = grenade.label, grenade.reason
      if not grenade.groups or grenade.signature ~= signature then return end
    end
    grenade.previous = current
    result.grenade_pressed = pressed
  end

  function self:refresh(time)
    self.next_refresh = time + 2
    self.profile_valid = false
    self.input_config_valid = false
    local good, bindings, reason, source, unsupported = pcall(function()
      if adapter.registry_dword(ACTIVE_KEY, "ActiveUser") ~= self.account_id then
        return nil, "active Steam account changed; restart required"
      end
      self.profile_valid = true
      local body, selected, read_error, missing = read_candidates(adapter, info.candidates)
      self.input_path = selected
      if body == nil then return nil, "input settings unreadable: " .. tostring(read_error) end
      -- Still read the current file and account on every refresh / Save edge.
      -- Reuse only the syntax tree for identical bytes, never cached key state
      -- or scan-to-VK results (which may change with the keyboard layout).
      if body ~= parsed_body then
        local config, failure = parse(body)
        if not config then return nil, "invalid input config: " .. tostring(failure) end
        parsed_body, parsed_config = body, config
      end
      self.input_config_valid = true
      local groups, failure, origin, unsupported = load_bindings(parsed_config, adapter)
      if missing and origin == "official_default" then origin = "official_default_missing_file" end
      return groups, failure, origin, unsupported
    end)
    self.revision = self.revision + 1
    self.bindings = good and bindings or {}
    self.bindings = self.bindings or {}
    self.binding_source, self.unsupported_bindings = source, unsupported or 0
    self.reason = not good and ("input refresh failed: " .. tostring(bindings)) or reason
    self.settings_reason = self.reason
    if not self.reason and #self.bindings == 0 then
      self.reason = "WeaponFunctionOpen has no supported keyboard/mouse binding"
    end
    self.card_labels, self.card_label = {}, nil
    if not self.reason then
      local labels, seen, complete = {}, {}, true
      for index, group in ipairs(self.bindings) do
        local label = group_label(group)
        self.card_labels[index] = label
        if not label then complete = false
        elseif not seen[label] then labels[#labels + 1], seen[label] = label, true end
      end
      if complete and #labels > 0 then self.card_label = table.concat(labels, " / ") end
    end
    return self.reason == nil, self.reason
  end

  local function extra_edge(id, name)
    local state = extra_keys[id]
    if not state or state.name ~= name then
      local vk, reason
      if name ~= nil and name ~= "None" and name ~= "NONE" then vk, reason = M.hotkey_vk(name) end
      state = {name=name,vk=vk,reason=reason,down=nil}
      extra_keys[id] = state
    end
    local down = state.vk ~= nil and adapter.key_down(state.vk) or false
    local pressed = state.down ~= nil and down and not state.down
    state.down = down
    return pressed, down, state.vk, state.reason
  end

  local function reload_held()
    for _, group in ipairs(self.bindings) do
      local all = true
      for _, binding in ipairs(group) do
        if not adapter.key_down(binding.vk) then all = false end
      end
      if all then return true end
    end
    return false
  end

  local function discard_contextual()
    contextual={keys={},buttons={},taps={}};menu_tap=nil
    help_keys={}
  end
  local function observe_help_buttons(controls,menu,allowed,card_held)
    local out={}
    local scope=allowed and card_held and menu.available==true and controls.help_open==true
        and controls.help_instance~=nil and
        (tostring(controls.help_instance)..":"..(controls.preset_help_open and "presets" or "property")) or nil
    local opening=menu.save.pressed and not controls.preset_help_open or
        menu.hud.pressed and (not controls.help_open or controls.preset_help_open)
    local snapshot=adapter.keyboard_snapshot or adapter.diagnostic_keys
    if not scope or opening or snapshot==nil then help_keys={};return out end
    local ok,keys=pcall(snapshot)
    if not ok or type(keys)~="table" then help_keys={};return out end
    for vk=1,255 do
      if type(keys[vk])~="boolean" then help_keys={};return out end
    end
    if help_keys.scope~=scope then help_keys={scope=scope} end
    local skip={}
    for _,group in ipairs(self.bindings) do for _,key in ipairs(group) do
      skip[key.vk]=true
      if key.vk==16 then skip[160]=true;skip[161]=true
      elseif key.vk==17 then skip[162]=true;skip[163]=true
      elseif key.vk==18 then skip[164]=true;skip[165]=true end
    end end
    -- Windows exposes both generic and left/right modifier states. Show the
    -- concrete button once, rather than inventing two presses for one key.
    if keys[160] or keys[161] then skip[16]=true end
    if keys[162] or keys[163] then skip[17]=true end
    if keys[164] or keys[165] then skip[18]=true end
    local pressed={}
    if help_keys.previous then
      for vk=1,255 do
        if keys[vk] and not help_keys.previous[vk] and not skip[vk] then
          pressed[#pressed+1]=KEY_LABELS[vk] or Text.hud("input.keyboard",{id=vk})
        end
      end
      -- A mapped controller/wheel button can have a game event without a
      -- Windows keyboard state. Use the accepted action's actual label for
      -- presentation only; never manufacture a command from this observer.
      if #pressed==0 then
        for _,name in ipairs({"save","hud","cycle","reset"}) do
          local action=menu[name]
          if action and action.pressed and type(action.label)=="string" and action.label~="" then
            pressed[#pressed+1]=action.label
          end
        end
      end
    end
    if #pressed>0 then help_keys.label=table.concat(pressed," + ");out.changed=true end
    help_keys.previous=keys;out.label=help_keys.label
    return out
  end
  local function menu_groups(binding)
    local groups,keys,ids={},{},{}
    for _,row in ipairs(binding.bindings or {}) do
      local vk=bindings_module.native_vk(row)
      if not vk then return nil end
      keys[#keys+1]=vk;ids[#ids+1]=row.identity
      if (row.combine or 0)==0 then
        groups[#groups+1]={id=table.concat(ids,"+"),keys=keys,trigger=row.trigger}
        keys,ids={},{}
      end
    end
    if #keys>0 or #groups==0 then return nil end
    return groups
  end
  local function contextual_actions(time,controls,menu,interactive,allowed,card_held,numbers)
    local out={}
    local instance=controls.help_instance
    local valid=interactive and allowed and card_held and menu.available==true and instance~=nil
    if not valid then discard_contextual();return out end
    local save=menu.save
    local groups=save.ready and save.signature and menu_groups(save) or nil
    -- Only an accepted game menu command can seed the opening tap. This does
    -- not execute a system command before the panel has actually been shown.
    local interrupted=menu.hud.pressed or menu.cycle.pressed or menu.reset.pressed or numbers>0
    if interrupted or controls.clear_allowed==false then menu_tap=nil;contextual.taps={} end
    if save.ready and save.signature and save.pressed and not interrupted and controls.clear_allowed~=false and not controls.preset_help_open then
      if not groups then
        menu_tap={instance=instance,signature=save.signature,time=time,id="event"}
      else
        for _,group in ipairs(groups) do
          local down=true
          for _,vk in ipairs(group.keys) do down=down and adapter.key_down(vk)==true end
          if (down or #groups==1) and (group.trigger==0 or group.trigger==4) then
            menu_tap={instance=instance,signature=save.signature,time=time,id=group.id};break
          end
        end
      end
    end
    local scope=controls.help_open==true and
      (tostring(instance)..":"..(controls.preset_help_open and "presets" or "property")) or nil
    if contextual.scope~=scope or contextual.signature~=save.signature then
      contextual={scope=scope,signature=save.signature,keys={},buttons={},taps={}}
      if scope and controls.preset_help_open and menu_tap and menu_tap.instance==instance and
         menu_tap.signature==save.signature and time-menu_tap.time<=0.3 then
        contextual.taps[menu_tap.id]=menu_tap.time
      end
    end
    if not scope then return out end
    menu_tap=nil
    -- Initialize every key from its current state. A key held before opening,
    -- refocusing, changing panels or equipping cannot become a fresh press.
    local function edge(vk)
      local down=adapter.key_down(vk)==true
      local pressed=contextual.keys[vk]==false and down
      contextual.keys[vk]=down
      return pressed
    end
    out.locale_pressed=edge(120) -- F9
    if not controls.preset_help_open and controls.hud_enabled==true then
      out.hud_display_pressed=edge(121) -- F10, property help only.
    end
    if controls.preset_help_open and controls.presets_enabled~=false then
      out.export_pressed=edge(67);out.import_pressed=edge(86)
      if not interrupted and controls.clear_allowed~=false and save.ready and save.signature then
        local function tap(id)
          local previous=contextual.taps[id]
          if previous and time>=previous and time-previous<=0.3 then
            out.clear_pressed=true;contextual.taps={}
          else contextual.taps[id]=time end
        end
        if groups then
          for _,group in ipairs(groups) do
            local down=true
            for _,vk in ipairs(group.keys) do down=down and adapter.key_down(vk)==true end
            if contextual.buttons[group.id]==false and down then tap(group.id) end
            contextual.buttons[group.id]=down
          end
        elseif save.pressed then
          -- Unfamiliar native devices keep their game-evaluated menu events;
          -- never guess a Windows key or block the ordinary menu command.
          tap("event")
        end
      end
    end
    if interrupted or save.pressed or out.clear_pressed then
      out.locale_pressed,out.export_pressed,out.import_pressed,out.hud_display_pressed=false,false,false,false
    end
    if out.export_pressed and out.import_pressed then out.export_pressed,out.import_pressed=false,false end
    if out.locale_pressed or out.export_pressed or out.import_pressed or out.hud_display_pressed then contextual.taps={} end
    if out.clear_pressed and menu_bindings then menu_bindings:consume("save") end
    return out
  end

  function self:ensure_menu_state(time)
    self:refresh(type(time)=="number" and time or 0)
    if not self.profile_valid or self.settings_reason then
      return nil,self.settings_reason or "active Steam profile not validated"
    end
    if type(options.native_reader)~="table" or type(options.native_reader.verify)~="function" then
      return nil,"guarded native reader unavailable"
    end
    local safe,verified,reason=pcall(options.native_reader.verify,options.native_reader)
    if not safe or not verified then return nil,reason or "native verification failed" end
    if not self.menu_state and type(MenuState)=="table" and type(MenuState.open)=="function" then
      local safe,value,why=pcall(MenuState.open,self.profile_id,options.menu_state_options)
      if not safe or not value then return nil,safe and why or value end
      self.menu_state=value
    end
    if self.menu_state then
      local language,why=self.menu_state:language()
      if not language then return nil,why end
      Text.set_language(language)
      return self.menu_state:ensure_file()
    end
    return true

  end

  function self:cancel_events() discard_contextual();if menu_bindings then menu_bindings:cancel() end end
  function self:cycle_language(time,foreground,before_write)
    if type(before_write)~="function" or before_write()~=true then return nil,"language requires visible current help" end
    local ready,why=self:ensure_menu_state(time)
    if not ready or not self.menu_state then return nil,why or "menu language state unavailable" end
    local selected=Text.next_language()
    local ok,reason=self.menu_state:set_language(selected,function()
      self:refresh(time)
      if foreground~=true or not self.profile_valid or self.settings_reason then return nil,"language context changed" end
      local gate=options.input_context or function()return PresetInputGate.context(options.native_reader)end
      local safe,value=pcall(gate)
      return safe and type(value)=="table" and value.allowed==true and before_write()==true
    end)
    if not ok then return nil,reason end
    Text.set_language(selected)
    return selected
  end
  function self:consume_clear() contextual.taps={};menu_tap=nil end
  function self:cancel_weapon_events()
    discard_contextual()
    if menu_bindings then for _,name in ipairs({"save","cycle","hud"}) do menu_bindings:consume(name) end end
  end
  function self:publish_reset_defaults() if menu_bindings then menu_bindings:queue_reset_defaults() end end

  function self:reset_menu_bindings(before_write)
    if not menu_bindings or type(menu_bindings.reset)~="function" then
      return nil,"required mod binding integration unavailable"
    end
    local safe,result,reason=pcall(menu_bindings.reset,menu_bindings,before_write)
    if not safe then return nil,"menu binding reset failed: "..tostring(result) end
    return result,reason
  end

  function self:poll(time, foreground, controls)
    controls = controls or {}
    local presets_enabled = controls.presets_enabled ~= false
    local reset_enabled = controls and (controls.reset_enabled==true or presets_enabled or controls.hud_enabled==true)
    if time>=self.next_refresh then self:refresh(time) end
    local menu={}
    if menu_bindings and controls then
      local safe,value=pcall(menu_bindings.poll,menu_bindings,time,foreground,{
        presets_enabled=presets_enabled,hud_enabled=controls.hud_enabled,reset_enabled=reset_enabled,card_label=self.card_label,
        default_state=self.menu_state,
        resolve_key=function(key)local vk,why=M.hotkey_vk(key);return vk,KEY_LABELS[vk],why end,
        gameplay_allowed=function()
          local gate=options.input_context or function()return PresetInputGate.context(options.native_reader)end
          local ok,value=pcall(gate)
          return foreground==true and ok and type(value)=="table" and value.allowed==true
        end,
        button_label=function(row)
          return KEY_LABELS[bindings_module.native_vk(row)]
        end,
        validate_profile=function()
          self:refresh(time)
          if not self.profile_valid or self.settings_reason then return nil,self.settings_reason or "profile unavailable" end
          return true
        end,
        get_input_config=function()
          self:refresh(time)
          if not self.profile_valid or not self.input_config_valid then
            return nil,self.settings_reason or "current input settings unavailable"
          end
          return parsed_config
        end,
        diagnostics_enabled=controls.diagnostics_enabled,
        refresh_card_label=function() self:refresh(time);return self.card_label end,
})
      if safe and type(value)=="table" then menu=value
      else
        menu.reason="required mod binding integration unavailable"
        -- A failed native reader cannot prove that saved menu keys are
        -- unbound. Keep command edges disabled rather than revive old keys.
        for _,name in ipairs(bindings_module.active_names) do
          if (name=="reset" and reset_enabled) or (name=="hud" and controls.hud_enabled==true)
            or (name~="hud" and name~="reset" and presets_enabled) then
            menu[name]={active=true,ready=false,down=false,pressed=false,vks={},reason=menu.reason}
          end
        end
      end
    end
    local context_ok=foreground==true and self.profile_valid and not self.settings_reason
    if context_ok then
      local gate=options.input_context or function()return PresetInputGate.context(options.native_reader)end
      local ok,value=pcall(gate);context_ok=ok and type(value)=="table" and value.allowed==true
    end
    local event_context={allowed=context_ok,card_held=reload_held(),
      presets_enabled=presets_enabled,hud_enabled=controls and controls.hud_enabled==true,reset_enabled=reset_enabled,
      preset_help_open=controls.preset_help_open==true,
      key_down=function(vk)return adapter.key_down(vk)==true end}
    if menu_bindings and menu.available==true then
      local ok,events=pcall(menu_bindings.events,menu_bindings,time,foreground,event_context)
      if ok and type(events)=="table" then
        for name,value in pairs(events) do menu[name]=value end
      else
        for _,name in ipairs(bindings_module.active_names) do
          menu[name]={active=true,ready=false,down=false,pressed=false,vks={},
            groups={},bindings={},reason="native action read failed"}
        end
      end
    end
    for _,name in ipairs(bindings_module.active_names) do
      if not menu[name] or not menu[name].active then
        menu[name]=bindings_module.describe_native(nil)
        menu[name].ready=false;menu[name].reason="Mod Bindings Menu v2.1 action unavailable"
      end
    end
    local save, cycle, property, reset = menu.save, menu.cycle, menu.hud, menu.reset
    local interactive = foreground == true and previous_foreground
    previous_foreground = foreground == true
    local preset_edges, preset_down = {}, false
    if presets_enabled then
      for index = 1, 3 do
        local top, top_down = extra_edge("digit" .. index, tostring(index))
        local pad, pad_down = extra_edge("numpad" .. index, "Numpad" .. index)
        preset_down = preset_down or top_down or pad_down
        if top or pad then preset_edges[#preset_edges + 1] = index end
      end
    else
      for index = 1, 3 do extra_keys["digit" .. index], extra_keys["numpad" .. index] = nil, nil end
    end
    local hud_arrows, hud_edge = {}, false
    if controls.hud_enabled == true and foreground == true and controls.hud_move_armed == true and not save.down then
      for _, arrow in ipairs(HUD_ARROWS) do
        local down = adapter.key_down(arrow.vk)
        hud_arrows[arrow.vk] = down
        if down and not previous_hud_arrows[arrow.vk] then hud_edge = true end
      end
    end
    previous_hud_arrows = hud_arrows
    if save.pressed or cycle.pressed or property.pressed or reset.pressed or #preset_edges > 0 or hud_edge then
      self:refresh(time)
    end
    local held, held_label = false, nil
    for index, group in ipairs(self.bindings) do
      local all = true
      for _, binding in ipairs(group) do if not adapter.key_down(binding.vk) then all = false end end
      if all then held = true;held_label = held_label or self.card_labels[index] end
    end
    local card_held = foreground == true and held and self.reason == nil
    local function command_reason(binding, card)
      return binding.reason or (card and self.reason or self.settings_reason)
    end
    local function overlaps(a, b)
      for i, x in ipairs(a.bindings or {}) do
        for j, y in ipairs(b.bindings or {}) do
          if a.groups[i] and b.groups[j] and a.groups[i][1] == b.groups[j][1]
            and not bindings_module.disjoint(x, y) then return true end
        end
      end
      return false
    end
    local save_reason = command_reason(save, true)
    local cycle_reason = command_reason(cycle, false)
    local property_reason = command_reason(property, true)
    local reset_reason = command_reason(reset, false)
    local clear_reason = save_reason
    -- These checks protect destructive mod commands from another mod command.
    -- Game-control overlaps are accepted; the game has already evaluated them.
    for _,other in ipairs({save,cycle,property}) do
      if overlaps(reset,other) then reset_reason="reset hotkey overlaps another WeaponFlow command" end
    end
    for _,other in ipairs({cycle,property,reset}) do
      if overlaps(save,other) then clear_reason="menu key overlaps another WeaponFlow command; clear disabled" end
    end
    controls.clear_allowed=clear_reason==nil
    local system=contextual_actions(time,controls,menu,interactive,context_ok,card_held,#preset_edges)
    local shown_keys=observe_help_buttons(controls,menu,interactive and context_ok,card_held)
    if system.locale_pressed or system.export_pressed or system.import_pressed or system.clear_pressed or system.hud_display_pressed then self:refresh(time) end
    local result = {
      pressed=presets_enabled and interactive and save.pressed and not save_reason,
      down=save.down, ready=save_reason==nil, reason=save_reason,
      held_reload=card_held, profile_valid=self.profile_valid,
      binding_source=self.binding_source, binding_revision=self.revision, unsupported_bindings=self.unsupported_bindings,
      presets_enabled=presets_enabled, menu_reason=menu.reason, menu_available=menu.available==true,
      menu_diagnostics=menu.diagnostics, menu_default_events=menu.default_events,
      save_label=save.label, save_trigger=save.trigger_label,
      cycle_label=cycle.label, cycle_trigger=cycle.trigger_label,
      hud_label=property.label, hud_trigger=property.trigger_label,
      reset_label=reset.label, reset_trigger=reset.trigger_label,
      clear_label=save.label, clear_trigger="DoubleTap",
      export_label="C",import_label="V",locale_label="F9",
      contextual_help_open=controls.help_open==true,help_instance=controls.help_instance,
      last_pressed_label=shown_keys.label,last_pressed_changed=shown_keys.changed==true,
      cycle_ready=presets_enabled and cycle_reason==nil, cycle_reason=cycle_reason,
      cycle_pressed=presets_enabled and interactive and cycle.pressed and not cycle_reason,
      hud_select_ready=controls.hud_enabled==true and property_reason==nil, hud_select_reason=property_reason,
      hud_select_pressed=controls.hud_enabled==true and interactive and property.pressed and not property_reason
        and card_held,
      reset_ready=reset_enabled and reset_reason==nil, reset_reason=reset_reason,
      reset_pressed=reset_enabled and interactive and reset.pressed and not reset_reason,
      clear_ready=presets_enabled and clear_reason==nil,clear_reason=presets_enabled and clear_reason or nil,
      clear_pressed=presets_enabled and not clear_reason and system.clear_pressed==true,
      export_pressed=presets_enabled and system.export_pressed==true,
      import_pressed=presets_enabled and system.import_pressed==true,
      locale_pressed=system.locale_pressed==true,
      hud_display_pressed=system.hud_display_pressed==true,
    }
    if self.profile_valid and not self.settings_reason then result.card_label=held_label or self.card_label end
    if controls.hud_enabled == true and controls.hud_move_armed == true and card_held and not save.down and
       not (save.pressed or cycle.pressed or property.pressed or reset.pressed or result.clear_pressed or
            result.export_pressed or result.import_pressed or result.locale_pressed or result.hud_display_pressed) then
      local move, active = {x=0,y=0}, false
      for _, arrow in ipairs(HUD_ARROWS) do
        if hud_arrows[arrow.vk] then
          active=true;move.x,move.y=move.x+arrow.x,move.y+arrow.y
        end
      end
      result.hud_move_active=active
      if active then result.hud_move=move end
    end
    if presets_enabled and interactive and card_held and not save_reason and not result.hud_move_active then
      if #preset_edges == 1 then
        local number=preset_edges[1]
        local function assigned_number(binding)
          -- Reserve the assignment before its evaluated event too: Release,
          -- Hold and DoubleTap must not first save a numbered preset on press.
          if not binding.ready then return false end
          for _,vk in ipairs(binding.vks or {}) do
            if vk==48+number or vk==96+number then return true end
          end
          return false
        end
        -- Number keys are assignable mod hotkeys too. A native command on
        -- that number takes precedence over the contextual numbered capture.
        if not assigned_number(save) and not assigned_number(cycle) and not assigned_number(property) and
           not assigned_number(reset) then
          result.preset_pressed=number
          if save.down then result.save_preset=number end
        end
      elseif #preset_edges > 1 then result.save_reason="multiple preset numbers pressed together" end
    end
    result.save_held=presets_enabled and foreground==true and result.ready and self.profile_valid and save.down
    if controls.diagnostics_enabled == true then
      grenade_enabled=true
      if not pcall(observe_grenade,result,time,foreground) then
        grenade.previous=nil;result.grenade_pressed,result.grenade_reason=false,"grenade observation failed"
      end
    elseif grenade_enabled then grenade,grenade_enabled={next_refresh=0},false end
    self.last_poll=result
    return result
  end
  self:refresh(0)
  return self
end

return M

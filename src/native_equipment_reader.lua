-- Passive native equipment investigation. No callbacks, input, or game writes.
-- Layout provenance: analysis/20260926-native-active-weapon-research.md.
-- This is an independent implementation of published layout facts. Upstream
-- repositories have no declared reuse license; their source is not embedded.
local M = { version = "0.2.3", active_weapon_verified = false }
local GAME_SHA = "2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E"
local EXE_SHA = "F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06"
local ANCHOR_RVA = 0x755f90
local ANCHOR = "\x48\x89\x4c\x24\x08\x53\x55\x56\x57\x41\x57\x48\x83\xec\x20"
local AVATAR_RESOURCE = "\x97\xfa\x4d\x29\x4d\x33\x1c\x4d"
-- The display may be the parent's selected underbarrel entity. These anchors
-- prove the attachment link, native activation and parent/child owner relation;
-- an arbitrary +0/+4 disagreement is still rejected. See native-underbarrel-v161.md.
local ALTERNATE_ANCHORS = {
    {rva=0x78850f,hex="488B0522E5B902498BD548C1E207488B88A00200008B440A64"},
    {rva=0x78859d,hex="458D42014038BC2480000000747441894104"},
    {rva=0x78861f,hex="41894904"},
    {rva=0x78614d,hex="833C88084A8B14CA410F94C0E882210000"},
    {rva=0x755501,hex="8B4CB2048BF981E1FFF3FFFFC1EF0AFFCF83E7018BC7C1E00A0BC8894CB204"},
    {rva=0x755543,hex="85FF7415BE08000000488BCD448BC6E8390A0000"},
    {rva=0x7869c0,hex="807C243000448BD84D8B4A6074254969CBD00100004B8D04B648C1E0044903C1448B540104443B1548D2CF027405448912EBA64969CBD00100004B8D04B648C1E0044903C18B0C01890AEB8D"},
    {rva=0x7883c6,hex="488B1D63E3B902"},
    {rva=0x78842e,hex="488B43388B1C90"},
    {rva=0x78860d,hex="488B051CE1B9028BCA488B4038891C88"},
    {rva=0x78864e,hex="418901488B05D8E0B902448BC2488B48388B05CFB5CF0242890481"},
}
for _,anchor in ipairs(ALTERNATE_ANCHORS) do
    anchor.bytes=anchor.hex:gsub("..",function(pair) return string.char(tonumber(pair,16)) end)
end

local function u32(s, offset)
    if type(s) ~= "string" or offset < 0 or #s < offset + 4 then return nil end
    local a, b, c, d = s:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function pointer(s, offset)
    offset = offset or 0
    local low, high = u32(s, offset), u32(s, offset + 4)
    if not low or not high or high >= 0x8000 then return nil end
    local n = low + high * 4294967296
    -- Canonical byte address, not an aligned uint64 array. In particular,
    -- AvatarManager+F8 points to its inline hash storage at manager+74:
    -- constructor 83AD23/83AD42 deliberately produces a 4-mod-8 address.
    if n < 0x10000 or n % 1 ~= 0 then return nil end
    return n
end
local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end))
end
local function identity(s)
    if type(s) ~= "string" or #s ~= 24 then return nil end
    return { resource_hex_le = hex(s:sub(1, 8)), eid = u32(s, 8),
             native_unit_id = u32(s, 12), network_object_id = u32(s, 16),
             flags = u32(s, 20), bytes_hex = hex(s), bytes = s }
end
local function words(s)
    local out = {}
    for offset = 0, #s - 4, 4 do out[#out + 1] = u32(s, offset) end
    return out
end
local function fail(reason) error(reason, 0) end

-- The only native calls below are Windows module/file-hash/memory READ APIs.
-- All game addresses are passed to ReadProcessMemory, never dereferenced.
function M.windows_adapter()
    local ffi = require("ffi")
    if not ffi.abi("64bit") or ffi.os ~= "Windows" then
        return nil, "requires Windows x64 LuaJIT"
    end
    local kernel, crypto = ffi.load("kernel32"), ffi.load("bcrypt")
    local function bind(dll, name, declaration)
        local ok, fn = pcall(function() return dll[name] end)
        if not ok then ffi.cdef(declaration); fn = dll[name] end
        return fn
    end
    local get_module = bind(kernel, "GetModuleHandleA", "void *GetModuleHandleA(const char *);")
    local get_path = bind(kernel, "GetModuleFileNameA",
        "unsigned long GetModuleFileNameA(void *, char *, unsigned long);")
    local get_process = bind(kernel, "GetCurrentProcess", "void *GetCurrentProcess(void);")
    local read_memory = bind(kernel, "ReadProcessMemory",
        "int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);")
    local open_alg = bind(crypto, "BCryptOpenAlgorithmProvider",
        "long BCryptOpenAlgorithmProvider(void **, const unsigned short *, const unsigned short *, unsigned long);")
    local get_property = bind(crypto, "BCryptGetProperty",
        "long BCryptGetProperty(void *, const unsigned short *, unsigned char *, unsigned long, unsigned long *, unsigned long);")
    local create_hash = bind(crypto, "BCryptCreateHash",
        "long BCryptCreateHash(void *, void **, unsigned char *, unsigned long, unsigned char *, unsigned long, unsigned long);")
    local hash_data = bind(crypto, "BCryptHashData",
        "long BCryptHashData(void *, unsigned char *, unsigned long, unsigned long);")
    local finish_hash = bind(crypto, "BCryptFinishHash",
        "long BCryptFinishHash(void *, unsigned char *, unsigned long, unsigned long);")
    local destroy_hash = bind(crypto, "BCryptDestroyHash", "long BCryptDestroyHash(void *);")
    local close_alg = bind(crypto, "BCryptCloseAlgorithmProvider",
        "long BCryptCloseAlgorithmProvider(void *, unsigned long);")
    local function wide(text)
        local array = ffi.new("unsigned short[?]", #text + 1)
        for i = 1, #text do array[i - 1] = text:byte(i) end
        return array
    end
    local process = get_process()
    local buffer, read_count = ffi.new("unsigned char[65536]"), ffi.new("size_t[1]")
    local api = {}
    function api.read(address, length)
        if type(length) ~= "number" or length < 1 or length > 65536 or length % 1 ~= 0 or
           type(address) ~= "number" or address < 0x10000 or
           address + length >= 0x800000000000 or address % 1 ~= 0 or
           address ~= address then
            return nil
        end
        read_count[0] = 0
        if read_memory(process, ffi.cast("const void *", address), buffer, length, read_count) == 0
           or tonumber(read_count[0]) ~= length then return nil end
        return ffi.string(buffer, length)
    end
    function api.module(name)
        local handle = get_module(name)
        if handle == nil or handle == ffi.NULL then return nil end
        return tonumber(ffi.cast("uintptr_t", handle))
    end
    function api.module_sha256(address)
        local path_buffer = ffi.new("char[32768]")
        local length = tonumber(get_path(ffi.cast("void *", address), path_buffer, 32768))
        if length < 1 or length >= 32768 then return nil, "module path unavailable" end
        local file = io.open(ffi.string(path_buffer, length), "rb")
        if not file then return nil, "module file unavailable" end
        local alg, hash_handle = ffi.new("void *[1]"), ffi.new("void *[1]")
        local object_buffer
        local ok, result = pcall(function()
            if open_alg(alg, wide("SHA256"), nil, 0) ~= 0 then fail("SHA256 provider unavailable") end
            local object_length, returned = ffi.new("unsigned long[1]"), ffi.new("unsigned long[1]")
            if get_property(alg[0], wide("ObjectLength"), ffi.cast("unsigned char *", object_length),
                            4, returned, 0) ~= 0 or tonumber(returned[0]) ~= 4 then
                fail("SHA256 object size unavailable")
            end
            local size = tonumber(object_length[0])
            if size < 1 or size > 1048576 then fail("invalid SHA256 object size") end
            object_buffer = ffi.new("unsigned char[?]", size)
            if create_hash(alg[0], hash_handle, object_buffer, size, nil, 0, 0) ~= 0 then
                fail("SHA256 creation failed")
            end
            while true do
                local chunk, read_error = file:read(65536)
                if not chunk then
                    if read_error then fail("module file read failed: " .. tostring(read_error)) end
                    break
                end
                if hash_data(hash_handle[0], ffi.cast("unsigned char *", chunk), #chunk, 0) ~= 0 then
                    fail("SHA256 update failed")
                end
            end
            local digest = ffi.new("unsigned char[32]")
            if finish_hash(hash_handle[0], digest, 32, 0) ~= 0 then fail("SHA256 finish failed") end
            return hex(ffi.string(digest, 32))
        end)
        file:close()
        if hash_handle[0] ~= nil then destroy_hash(hash_handle[0]) end
        if alg[0] ~= nil then close_alg(alg[0], 0) end
        if not ok then return nil, result end
        return result
    end
    return api
end

-- adapter injection is for captured-memory replay; it does not certify layout.
function M.new(adapter)
    if not adapter then
        local ok, value, reason = pcall(M.windows_adapter)
        if not ok then return nil, tostring(value) end
        if not value then return nil, reason end
        adapter = value
    end
    local reader = { api = adapter, active_weapon_verified = false }
    local rejected_fingerprint
    function reader:verify()
        local game, exe = self.api.module("game.dll"), self.api.module(nil)
        if rejected_fingerprint and
           (rejected_fingerprint.game ~= game or rejected_fingerprint.exe ~= exe) then
            rejected_fingerprint = nil
        end
        if not game or not exe then return nil, "game modules unavailable" end
        if rejected_fingerprint then return nil, rejected_fingerprint.reason end
        if self.game ~= game or self.exe ~= exe or not self.files_verified then
            self.files_verified = false
            local function verify_file(address, expected, label)
                local digest, reason = self.api.module_sha256(address)
                if type(digest) ~= "string" or #digest ~= 64 or not digest:match("^%x+$") then
                    return nil, label .. " SHA256 unavailable: " .. tostring(reason or "invalid digest")
                end
                if digest ~= expected then
                    local failure = "unsupported " .. label .. " SHA256"
                    -- A confirmed unsupported build stays inactive without
                    -- hashing large files every frame. Read/API failures are
                    -- retried, and either module handle changing clears this.
                    rejected_fingerprint = {game=game,exe=exe,reason=failure}
                    return nil, failure
                end
                return true
            end
            local valid, reason = verify_file(game, GAME_SHA, "game.dll")
            if not valid then return nil, reason end
            valid, reason = verify_file(exe, EXE_SHA, "EXE")
            if not valid then return nil, reason end
            self.game, self.exe, self.files_verified = game, exe, true
        end
        if self.api.read(game + ANCHOR_RVA, #ANCHOR) ~= ANCHOR then
            return nil, "runtime code anchor mismatch"
        end
        return true
    end
    local function transaction(self, operation, stage)
        stage = stage or "component"
        local ok, supported, reason = pcall(self.verify, self)
        if not ok then return nil, tostring(supported) end
        if not supported then return nil, reason end
        local guards, read_calls, byte_count = {}, 0, 0
        local function address_text(address)
            return type(address) == "number" and string.format("0x%X", address) or tostring(address)
        end
        local function read(address, size, label)
            read_calls, byte_count = read_calls + 1, byte_count + size
            if read_calls > 512 or byte_count > 65536 then
                fail("snapshot read budget exceeded stage=" .. (label or stage) ..
                     " address=" .. address_text(address) .. " size=" .. tostring(size))
            end
            local data = self.api.read(address, size)
            if type(data) ~= "string" or #data ~= size then
                fail("snapshot memory unavailable stage=" .. (label or stage) ..
                     " address=" .. address_text(address) .. " size=" .. tostring(size))
            end
            guards[#guards + 1] = { address, data, label or stage }
            return data
        end
        local function ptr(address, label)
            local raw = read(address, 8, label)
            local value = pointer(raw)
            if not value then
                fail("snapshot pointer unavailable stage=" .. (label or stage) ..
                     " address=" .. address_text(address) .. " raw=" .. hex(raw))
            end
            return value
        end
        local function lookup(header, key, limit, label)
            local data, capacity = pointer(header), u32(header, 8)
            local empty, multiplier = u32(header, 12), u32(header, 16)
            local function invalid(reason)
                local header_address
                for i = #guards, 1, -1 do
                    if guards[i][2] == header then header_address = guards[i][1]; break end
                end
                fail("invalid native lookup table stage=" .. (label or stage) ..
                     " header_at=" .. address_text(header_address) ..
                     " header=" .. (type(header) == "string" and hex(header) or tostring(header)) ..
                     " data=" .. address_text(data) .. " capacity=" .. tostring(capacity) ..
                     " empty=" .. tostring(empty) .. " multiplier=" .. tostring(multiplier) ..
                     " key=" .. tostring(key) .. " limit=" .. tostring(limit) .. " reason=" .. reason)
            end
            if not data or not capacity or capacity < 1 or capacity > limit then
                invalid(not data and "noncanonical/null table pointer" or
                        (not capacity and "header truncated" or
                         (capacity < 1 and "empty/uninitialized table" or "capacity exceeds bound")))
            end
            local power = capacity
            while power > 1 and power % 2 == 0 do power = power / 2 end
            if power ~= 1 then invalid("capacity is not a power of two") end
            if key == empty then return nil end
            local product = ((key % 65536) * multiplier + math.floor(key / 65536) *
                              (multiplier % 65536) * 65536) % 4294967296
            for attempt = 0, math.min(capacity, 64) - 1 do
                local entry = read(data + ((product + attempt) % capacity) * 8, 8, label)
                if u32(entry, 0) == key then
                    local index = u32(entry, 4)
                    if index ~= 0xffffffff then return index end
                    return nil
                end
                if u32(entry, 0) == empty then return nil end
            end
            if capacity > 64 then
                invalid("probe budget exhausted before absence established")
            end
            return nil
        end
        local success, value = pcall(operation, read, ptr, lookup)
        if not success then return nil, tostring(value) end
        -- Every pointer/header/identity/data read must still describe the same
        -- snapshot; registry compaction or respawn invalidates the whole result.
        for _, guard in ipairs(guards) do
            local reread_ok, reread = pcall(self.api.read, guard[1], #guard[2])
            if not reread_ok or reread ~= guard[2] then
                return nil, "snapshot changed while reading stage=" .. guard[3] ..
                    " address=" .. address_text(guard[1]) .. " size=" .. #guard[2]
            end
        end
        value.read_calls, value.read_bytes = read_calls * 2, byte_count * 2
        return value
    end
    -- Shared bounded transaction for passive native component readers. The
    -- callback must return a table; read/ptr/lookup must not escape the call.
    function reader:transaction(operation, stage)
        if type(operation) ~= "function" then return nil, "transaction callback required" end
        return transaction(self, operation, stage)
    end
    function reader:snapshot()
        return transaction(self, function(read, ptr, lookup)
            local game = self.game
            local mode_manager = ptr(game + 0x33266a0)
            local mode = read(mode_manager, 0x44)
            local mission_type = u32(mode, 0x40)
            if u32(mode, 8) == 0 or mission_type < 1 or mission_type > 7 then fail("not in mission") end
            local player_manager = ptr(game + 0x3326468)
            local counts = read(player_manager + 0x84, 8)
            if u32(counts, 0) < 1 or u32(counts, 0) > 4 or
               u32(counts, 4) < 1 or u32(counts, 4) > 4 then fail("local player unavailable") end
            local player = read(ptr(player_manager + 0xe8), 24)
            if u32(player, 20) % 2 == 0 then fail("local player inactive") end
            local network_id = u32(read(player_manager + 0x3a8, 4), 0)
            if network_id == 0x7fff then fail("local avatar unavailable") end
            local owner = ptr(game + 0x346bf98)
            local index = lookup(read(owner + 0xf22ec8, 20), network_id, 1048576, "local-avatar network-to-entity")
            if not index or index >= 262144 then fail("avatar entity lookup unavailable") end
            local avatar_bytes = read(owner + 0xf32f18 + index * 24, 24)
            local avatar = identity(avatar_bytes)
            if avatar_bytes:sub(1, 8) ~= AVATAR_RESOURCE or avatar.flags % 2 == 0 or
               avatar.network_object_id ~= network_id then
                fail("local avatar identity invalid")
            end
            local avatar_manager = ptr(game + 0x3326d20)
            local avatar_index = lookup(read(avatar_manager + 0xf8, 20), avatar.eid, 64, "local-avatar registry")
            local avatar_count = u32(read(avatar_manager + 0x6c, 4), 0)
            if not avatar_index or avatar_count > 8 or avatar_index >= avatar_count then
                fail("avatar registry mismatch")
            end
            if read(ptr(avatar_manager + 0x110 + avatar_index * 8), 24) ~= avatar_bytes then
                fail("avatar registry identity mismatch")
            end
            local equipment_manager = ptr(game + 0x3326738)
            local equipment_index = lookup(read(equipment_manager + 40, 20), avatar.eid, 8192, "avatar equipment")
            if not equipment_index or equipment_index >= 4096 then fail("equipment row unavailable") end
            local entity_array = ptr(equipment_manager + 64)
            if read(ptr(entity_array + equipment_index * 8), 24) ~= avatar_bytes then
                fail("equipment owner identity mismatch")
            end
            local row_address = ptr(equipment_manager + 80) + equipment_index * 48
            local row = read(row_address, 48)
            return { avatar = avatar, avatar_bytes = avatar_bytes,
                     player_manager = player_manager, player_avatar_network_id = network_id,
                     entity_owner = owner, avatar_address = owner + 0xf32f18 + index * 24,
                     avatar_manager = avatar_manager, avatar_index = avatar_index,
                     equipment_manager = equipment_manager, equipment_index = equipment_index,
                     equipment_row_address = row_address, equipment_words = words(row),
                     equipment_hex = hex(row), backpack_eid = u32(row, 12),
                     active_weapon_eid = nil, active_weapon_verified = false,
                     mode_manager = mode_manager, mission_type = mission_type }
        end, "snapshot")
    end
    local function display_child(self, baseline, active, candidate, require_selected, read, ptr, lookup)
        local game, eid = self.game, active.entity.eid
        local function require_valid(condition, reason)
            if not condition then fail("underbarrel display: " .. reason) end
        end
        local invalid = u32(read(game + 0x3483c34, 4), 0)
        require_valid(type(candidate)=="number" and candidate>0 and candidate<0xffffffff and
            candidate~=invalid and candidate~=eid,"invalid child EID")
        for _,anchor in ipairs(ALTERNATE_ANCHORS) do
            require_valid(read(game+anchor.rva,#anchor.bytes)==anchor.bytes,
                string.format("code anchor mismatch at %X",anchor.rva))
        end
        local wm, wmi = active.weapon_manager, active.weapon_index
        local functions = read(ptr(wm+0x58)+wmi*0x3f0+0x350,16)
        local offered = false
        for offset=0,12,4 do if u32(functions,offset)==11 then offered=true end end
        require_valid(offered,"parent offers no secondary-fire function")
        local state = read(ptr(wm+0x60)+wmi*12,8)
        local mode, selected = u32(state,0), math.floor(u32(state,4)/1024)%4
        require_valid((selected==1 and mode==8) or
            (not require_selected and selected==0 and mode>=1 and mode<=7),"parent secondary state is inconsistent")
        local parts = ptr(game+0x3326a38)
        local capacity = u32(read(parts+0x258,4),0)
        local total, live = u32(read(parts+0x264,4),0),u32(read(parts+0x268,4),0)
        require_valid(capacity>=1 and capacity<=262144 and total<=capacity and live<=total,
            "parts registry count/capacity invalid")
        local pi = lookup(read(parts+0x278,20),eid,1048576,"underbarrel parent parts")
        require_valid(pi~=nil and pi<total,"parent parts entry unavailable")
        require_valid(read(ptr(ptr(parts+0x290)+pi*8),24)==active.bytes,"parts parent identity differs")
        local attachment_address = ptr(parts+0x2a0)+pi*0x80+0x64
        require_valid(u32(read(attachment_address,4),0)==candidate,"alternate is not current parent attachment")
        local owner = ptr(game+0x346bf98)
        local ci = lookup(read(owner+0xf1aeb0,20),candidate,1048576,"underbarrel native child")
        require_valid(ci~=nil and ci<262144,"child native identity unavailable")
        local child_address = owner+0xf32f18+ci*24
        local child_bytes = read(child_address,24)
        require_valid(u32(child_bytes,8)==candidate,"child native identity differs")
        local cwi = lookup(read(wm+0x30,20),candidate,32768,"underbarrel weapon-data child")
        require_valid(cwi~=nil and cwi<16384,"child weapon-data unavailable")
        require_valid(read(ptr(ptr(wm+0x48)+cwi*8),24)==child_bytes,"child weapon-data identity differs")
        -- 788432 reads the parent's avatar association; 78861A assigns that
        -- same avatar to the child. Neither record is an inventory slot.
        local associations = ptr(game+0x3326730)
        local association_header = read(associations+0x18,20)
        local associations_data = ptr(associations+0x38)
        for _,member in ipairs({eid,candidate}) do
            local ai = lookup(association_header,member,1048576,"underbarrel wielder association")
            require_valid(ai~=nil and ai<262144,"wielder association unavailable")
            -- Native disable clears the child's owner at 788665. A stale card
            -- may still show that child, but it must now be explicitly detached.
            local expected = member==candidate and selected==0 and invalid or baseline.avatar.eid
            require_valid(u32(read(associations_data+ai*4,4),0)==expected,
                "parent/child wielder association differs from expected owner")
        end
        return {entity=identity(child_bytes),bytes=child_bytes,entity_address=child_address,
            attachment_address=attachment_address,source="verified_native_secondary_attachment"}
    end
    local function active_selection(self, baseline, read, ptr, lookup)
        -- The actual mode-card action at 1826A0C -> 182708E reads hand zero
        -- from this row, then passes that EID to native mode cycle 7552D0.
        -- Constructor 53FBD0 proves count+18, owner entities+48 and rows+60.
        -- This is not the equipment inventory and does not use key intentions.
        if type(baseline) ~= "table" or type(baseline.avatar_bytes) ~= "string" or
           #baseline.avatar_bytes ~= 24 then fail("local avatar snapshot required") end
        local mode_manager = ptr(self.game + 0x33266a0)
        local mode = read(mode_manager, 0x44)
        local mission_type = u32(mode, 0x40)
        if u32(mode, 8) == 0 or mission_type < 1 or mission_type > 7 then fail("not in mission") end
        if mode_manager ~= baseline.mode_manager or mission_type ~= baseline.mission_type then
            fail("mission context changed")
        end
        local pm = ptr(self.game + 0x3326468)
        if pm ~= baseline.player_manager or
           u32(read(pm + 0x3a8, 4), 0) ~= baseline.player_avatar_network_id then
            fail("local avatar reference changed")
        end
        local counts = read(pm + 0x84, 8)
        if u32(counts, 0) < 1 or u32(counts, 0) > 4 or
           u32(counts, 4) < 1 or u32(counts, 4) > 4 then fail("local player unavailable") end
        if u32(read(ptr(pm + 0xe8), 24), 20) % 2 == 0 then fail("local player unavailable") end
        local owner = ptr(self.game + 0x346bf98)
        local ai = lookup(read(owner + 0xf22ec8, 20), baseline.player_avatar_network_id, 1048576, "active local-avatar identity")
        if not ai or ai >= 262144 or
           read(owner + 0xf32f18 + ai * 24, 24) ~= baseline.avatar_bytes then
            fail("local avatar identity changed")
        end
        -- The same mode-card path rejects avatar state >=2 at 18267EB.
        -- Constructor 53DC10 proves this registry's count/owner/row layout.
        -- Do not assign a guessed health/death enum meaning to this value.
        local card_manager = ptr(self.game + 0x3326688)
        local card_header = read(card_manager + 0x101c, 0x44)
        local ci = lookup(read(card_manager + 0x1030, 20), baseline.avatar.eid, 65536, "mode-card avatar state")
        local card_count = u32(card_header, 0)
        if not ci or card_count > 32768 or ci >= card_count then
            fail("mode-card avatar state unavailable")
        end
        local card_owner_address = ptr(card_manager + 0x1048) + ci * 8
        local card_owner_pointer = ptr(card_owner_address)
        if read(card_owner_pointer, 24) ~= baseline.avatar_bytes then
            fail("mode-card avatar identity mismatch")
        end
        local card_state_address = ptr(card_manager + 0x1058) + ci * 0x1b8 + 0x19c
        local card_state = u32(read(card_state_address, 4), 0)
        if card_state >= 2 then fail("mode-card avatar state blocks action: " .. card_state) end
        local wielder = ptr(self.game + 0x3326420)
        local manager_globals = read(self.game + 0x3326420, 0x50)
        if pointer(manager_globals, 0) ~= wielder or pointer(manager_globals, 0x48) ~= pm then
            fail("manager globals changed")
        end
        local wielder_header = read(wielder + 0x18, 0x50)
        local wi = lookup(read(wielder + 0x30, 20), baseline.avatar.eid, 8192, "active avatar wielder")
        local count = u32(read(wielder + 0x18, 4), 0)
        if not wi or count > 4096 or wi >= count then fail("avatar wielder row unavailable") end
        local owner_pointer_address = ptr(wielder + 0x48) + wi * 8
        local entity_pointer = ptr(owner_pointer_address)
        if read(entity_pointer, 24) ~= baseline.avatar_bytes then fail("wielder owner identity mismatch") end
        local row_address = ptr(wielder + 0x60) + wi * 0x1d0
        local selection = read(row_address, 8)
        local eid, display_alternate = u32(selection, 0), u32(selection, 4)
        local invalid = u32(read(self.game + 0x3483c34, 4), 0)
        if eid == invalid or eid == 0xffffffff or eid == 0 then
            fail(string.format("no active native weapon avatar=%s row=0x%X eid=%s alternate=%s invalid=%s pair=%s",
                tostring(baseline.avatar.eid), row_address, tostring(eid),
                tostring(display_alternate), tostring(invalid), hex(selection)))
        end
        local index = lookup(read(owner + 0xf1aeb0, 20), eid, 1048576, "active native-entity identity")
        if not index or index >= 262144 then fail("active native entity unavailable") end
        local entity_address = owner + 0xf32f18 + index * 24
        local bytes = read(entity_address, 24)
        local entity = identity(bytes)
        if entity.eid ~= eid or entity.network_object_id >= 0x7fff then
            fail("active native entity identity mismatch")
        end
        -- Bit zero means local ownership, not liveness. A foreign pickup may
        -- retain remote ownership, so it is deliberately not required here.
        local wm = ptr(self.game + 0x3326ce0)
        local wmi = lookup(read(wm + 0x30, 20), eid, 32768, "active weapon-data")
        if not wmi then
            fail(string.format("active weapon-data lookup absent avatar=%s manager=0x%X eid=%s alternate=%s pair=%s index=nil expected=%s actual=not-read",
                tostring(baseline.avatar.eid), wm, tostring(eid), tostring(display_alternate),
                hex(selection), hex(bytes)))
        end
        if wmi >= 16384 then
            fail(string.format("active weapon-data index out of bounds avatar=%s manager=0x%X eid=%s alternate=%s pair=%s index=%s limit=16384 expected=%s actual=not-read",
                tostring(baseline.avatar.eid), wm, tostring(eid), tostring(display_alternate),
                hex(selection), tostring(wmi), hex(bytes)))
        end
        local weapon_data_entity_address = ptr(ptr(wm + 0x48) + wmi * 8)
        local weapon_data_entity_bytes = read(weapon_data_entity_address, 24)
        if weapon_data_entity_bytes ~= bytes then
            fail(string.format("active weapon-data identity mismatch avatar=%s manager=0x%X eid=%s alternate=%s pair=%s index=%s entity_at=0x%X expected=%s actual=%s",
                tostring(baseline.avatar.eid), wm, tostring(eid), tostring(display_alternate),
                hex(selection), tostring(wmi), weapon_data_entity_address,
                hex(bytes), hex(weapon_data_entity_bytes)))
        end
        local attach = ptr(self.game + 0x3326dc0)
        local hi = lookup(read(attach + 0x20, 20), eid, 8192, "active weapon holder")
        if not hi or hi >= 4096 then fail("active weapon holder unavailable") end
        local holder = u32(read(ptr(attach + 0x40) + hi * 48 + 4, 4), 0)
        if holder ~= baseline.avatar.eid then fail("active weapon is not attached to local avatar") end
        local result = { entity = entity, bytes = bytes, entity_address = entity_address,
                 native_holder_eid = holder, wielder_manager = wielder, wielder_index = wi,
                 wielder_row_address = row_address, wielder_selection_bytes = selection,
                 manager_globals_bytes = manager_globals, wielder_header_bytes = wielder_header,
                 wielder_owner_pointer_address = owner_pointer_address,
                 wielder_owner_entity_pointer = entity_pointer,
                 card_manager = card_manager, card_index = ci, card_header_bytes = card_header,
                 card_owner_pointer_address = card_owner_address,
                 card_owner_entity_pointer = card_owner_pointer,
                 card_state_address = card_state_address, card_avatar_state = card_state,
                 display_alternate_eid = display_alternate, display_eid = eid, weapon_manager = wm,
                 weapon_index = wmi, holder_manager = attach, holder_index = hi,
                 source = "native_wielder_hand0; mode-card action 1826A0C->182708E" }
        if display_alternate ~= invalid and display_alternate ~= eid then
            result.display_child = display_child(self,baseline,result,display_alternate,true,read,ptr,lookup)
            result.display_eid = display_alternate
        end
        return result
    end
    -- Returns a fresh snapshot augmented with the actual mode-action entity.
    -- Passing a prior snapshot additionally requires that character identity
    -- still matches; a new weapon on the same character is returned normally.
    function reader:active_weapon(baseline)
        local current, reason = self:snapshot()
        if not current then return nil, reason end
        if baseline and baseline.avatar_bytes ~= current.avatar_bytes then
            return nil, "local avatar changed"
        end
        local calls, bytes = current.read_calls, current.read_bytes
        local result, failure = transaction(self, function(read, ptr, lookup)
            current.active_weapon = active_selection(self, current, read, ptr, lookup)
            current.active_weapon_eid = current.active_weapon.entity.eid
            current.active_weapon_verified = true
            return current
        end, "active-weapon")
        if result then
            result.read_calls, result.read_bytes = result.read_calls + calls, result.read_bytes + bytes
        end
        return result, failure
    end
    -- Small change detector only. It never authorizes a write/native action;
    -- guard_active/active_weapon must run again before those. No enumeration,
    -- hashes, or new lookup walk during stable frames: fourteen copied reads,
    -- including the mission and native mode-card avatar-state gates.
    function reader:watch(snapshot, selection_cursor)
        local reads, bytes = 0, 0
        local witness
        local function checked(address, size)
            reads, bytes = reads + 1, bytes + size
            local data = self.api.read(address, size)
            if type(data) ~= "string" or #data ~= size then fail("watch read unavailable") end
            return data
        end
        local ok, unchanged = pcall(function()
            local active = snapshot and snapshot.active_weapon
            if not active or not snapshot.active_weapon_verified then fail("watch snapshot unavailable") end
            local expected_selection = selection_cursor or active.wielder_selection_bytes
            if type(expected_selection) ~= "string" or #expected_selection ~= 8 then
                fail("watch selection cursor must be eight bytes")
            end
            if self.api.module("game.dll") ~= self.game or self.api.module(nil) ~= self.exe then
                fail("watch modules changed")
            end
            local function mission_gate()
                if pointer(checked(self.game + 0x33266a0, 8), 0) ~= snapshot.mode_manager then
                    fail("watch mission manager changed")
                end
                local mode = checked(snapshot.mode_manager, 0x44)
                local mission_type = u32(mode, 0x40)
                if u32(mode, 8) == 0 or mission_type < 1 or mission_type > 7 or
                   mission_type ~= snapshot.mission_type then fail("watch mission ended/changed") end
            end
            local function card_avatar_gate()
                if pointer(checked(self.game + 0x3326688, 8), 0) ~= active.card_manager then
                    fail("watch mode-card avatar manager changed")
                end
                local header = checked(active.card_manager + 0x101c, 0x44)
                -- Total registry counts include unrelated actors and changed
                -- repeatedly in the live mission while our avatar stayed put.
                -- Only storage addresses, our index bound, and its actual
                -- owner identify this cached row. Compaction still fails the
                -- owner-pointer/full-identity guards immediately below.
                local count = u32(header, 0)
                if count > 32768 or count <= active.card_index or
                   pointer(header, 0x2c) ~= pointer(active.card_header_bytes, 0x2c) or
                   pointer(header, 0x3c) ~= pointer(active.card_header_bytes, 0x3c) then
                    fail("watch mode-card avatar storage/index changed")
                end
                if pointer(checked(active.card_owner_pointer_address, 8), 0) ~= active.card_owner_entity_pointer or
                   checked(active.card_owner_entity_pointer, 24) ~= snapshot.avatar_bytes then
                    fail("watch mode-card avatar owner changed")
                end
                local state = u32(checked(active.card_state_address, 4), 0)
                if state >= 2 then fail("watch mode-card avatar state blocks action: " .. state) end
            end
            local function wielder_storage_gate()
                local header = checked(active.wielder_manager + 0x18, 0x50)
                local count = u32(header, 0)
                if count > 4096 or count <= active.wielder_index or
                   pointer(header, 0x30) ~= pointer(active.wielder_header_bytes, 0x30) or
                   pointer(header, 0x48) ~= pointer(active.wielder_header_bytes, 0x48) then
                    fail("watch wielder storage/index changed")
                end
            end
            local function display_child_gate()
                local child=active.display_child
                if child and checked(child.entity_address,24)~=child.bytes then
                    fail("watch display child identity changed")
                end
            end
            mission_gate()
            card_avatar_gate()
            if checked(self.game + 0x3326420, 0x50) ~= active.manager_globals_bytes then
                fail("watch manager globals changed")
            end
            if u32(checked(snapshot.player_manager + 0x3a8, 4), 0) ~= snapshot.player_avatar_network_id then
                fail("watch local avatar changed")
            end
            wielder_storage_gate()
            if pointer(checked(active.wielder_owner_pointer_address, 8), 0) ~= active.wielder_owner_entity_pointer then
                fail("watch wielder owner changed")
            end
            local selected = checked(active.wielder_row_address, 8)
            if checked(active.wielder_owner_entity_pointer, 24) ~= snapshot.avatar_bytes then
                fail("watch avatar identity changed")
            end
            if checked(active.entity_address, 24) ~= active.bytes then fail("watch weapon identity changed") end
            display_child_gate()
            if selected ~= expected_selection then
                -- A->B->A may finish before a full B snapshot can validate its
                -- attachment. A stable changed native action EID is still an
                -- observed hand departure, not necessarily a weapon equip.
                -- The coordinator separately classifies utilities and empty
                -- hands using native inventory membership. A supplied cursor
                -- watches that temporary selection without replacing the last
                -- fully verified weapon identity. Repeat the lightweight identity
                -- chain before reporting that evidence; +4-only changes do
                -- not count, and no control input participates in the serial.
                mission_gate()
                card_avatar_gate()
                wielder_storage_gate()
                if checked(self.game + 0x3326420, 0x50) ~= active.manager_globals_bytes or
                   u32(checked(snapshot.player_manager + 0x3a8, 4), 0) ~= snapshot.player_avatar_network_id or
                   pointer(checked(active.wielder_owner_pointer_address, 8), 0) ~= active.wielder_owner_entity_pointer or
                   checked(active.wielder_row_address, 8) ~= selected or
                   checked(active.wielder_owner_entity_pointer, 24) ~= snapshot.avatar_bytes or
                   checked(active.entity_address, 24) ~= active.bytes then
                    fail("watch selection changed during identity recheck")
                end
                display_child_gate()
                local before, after = u32(expected_selection, 0), u32(selected, 0)
                if before ~= after then
                    witness = { authoritative_selection_change = true,
                        observed_eid = after, previous_eid = before,
                        observed_selection_bytes = selected,
                        source = "stable native wielder hand0; complete identity chain repeated" }
                end
                return false
            end
            return true
        end)
        local metrics = { read_calls = reads, read_bytes = bytes }
        if ok then
            if witness then
                for key, value in pairs(witness) do metrics[key] = value end
            end
            if unchanged then return true, nil, metrics end
            return false, "watch selected weapon changed", metrics
        end
        return false, tostring(unchanged), metrics
    end
    -- Call inside reader:transaction before reading/changing an active weapon.
    -- Re-resolves the pointer chain and requires the same avatar, full entity,
    -- and current/display pair. Manager compaction is checked by the transaction.
    function reader:guard_active(snapshot, read, ptr, lookup)
        if not snapshot or not snapshot.active_weapon_verified or not snapshot.active_weapon then
            fail("verified active weapon snapshot required")
        end
        local fresh = active_selection(self, snapshot, read, ptr, lookup)
        if fresh.bytes ~= snapshot.active_weapon.bytes or
           fresh.wielder_selection_bytes ~= snapshot.active_weapon.wielder_selection_bytes then
            fail("active weapon changed")
        end
        local before_child, after_child = snapshot.active_weapon.display_child, fresh.display_child
        if (before_child and before_child.bytes) ~= (after_child and after_child.bytes) then
            fail("active weapon display child identity changed")
        end
        return fresh
    end
    -- Only the card dirty-byte path uses this to recognize a previously shown
    -- child after its parent was switched back. It does not authorize controls
    -- or mode calls against a stale displayed entity.
    function reader:guard_display_child(snapshot,active,candidate,read,ptr,lookup)
        if not snapshot or not snapshot.active_weapon or not active or
           active.bytes~=snapshot.active_weapon.bytes then fail("verified display parent required") end
        return display_child(self,snapshot,active,candidate,false,read,ptr,lookup)
    end
    -- Caller must supply a native weapon EID tied to an independently confirmed
    -- selection. This method does not label an inventory member active.
    function reader:weapon_state(eid, avatar_bytes)
        if type(eid) ~= "number" or eid < 1 or eid >= 0xffffffff or eid % 1 ~= 0 or
           type(avatar_bytes) ~= "string" or #avatar_bytes ~= 24 then
            return nil, "verified native EID and avatar identity required"
        end
        local current, why = self:snapshot()
        if not current then return nil, why end
        if current.avatar_bytes ~= avatar_bytes then return nil, "local avatar changed" end
        return transaction(self, function(read, ptr, lookup)
            local player_manager = ptr(self.game + 0x3326468)
            if player_manager ~= current.player_manager or
               u32(read(player_manager + 0x3a8, 4), 0) ~= current.player_avatar_network_id then
                fail("local avatar reference changed")
            end
            local equipment = ptr(self.game + 0x3326738)
            if equipment ~= current.equipment_manager then fail("equipment registry changed") end
            local equipment_index = lookup(read(equipment + 40, 20), u32(avatar_bytes, 8), 8192, "legacy avatar equipment")
            if not equipment_index or equipment_index >= 4096 or
               read(ptr(ptr(equipment + 64) + equipment_index * 8), 24) ~= avatar_bytes then
                fail("equipment avatar changed")
            end
            local manager = ptr(self.game + 0x3326ce0)
            local index = lookup(read(manager + 48, 20), eid, 32768, "legacy weapon-data")
            if not index or index >= 16384 then fail("weapon state lookup unavailable") end
            local entity_bytes = read(ptr(ptr(manager + 72) + index * 8), 24)
            local entity = identity(entity_bytes)
            if entity.eid ~= eid then fail("weapon identity mismatch") end
            local attach = ptr(self.game + 0x3326dc0)
            local attachment_index = lookup(read(attach + 32, 20), eid, 8192, "legacy weapon holder")
            if not attachment_index or attachment_index >= 4096 then fail("weapon holder unavailable") end
            local holder = u32(read(ptr(attach + 64) + attachment_index * 48 + 4, 4), 0)
            if holder ~= u32(avatar_bytes, 8) then fail("weapon holder differs from local avatar") end
            local state_bytes = read(ptr(manager + 96) + index * 12, 12)
            return { entity = entity, native_holder_eid = holder,
                     fire_mode_raw = u32(state_bytes, 0), state_words = words(state_bytes),
                     state_hex = hex(state_bytes), active_weapon_verified = false }
        end, "legacy weapon-state")
    end
    return reader
end

M.fingerprints = { game_sha256 = GAME_SHA, exe_sha256 = EXE_SHA,
                   anchor_rva = ANCHOR_RVA, anchor_hex = hex(ANCHOR) }
M.alternate_anchors = ALTERNATE_ANCHORS
return M

-- Refresh the existing weapon card after a normal native mode cycle.
-- This module never changes modes, inventory, input bindings, or game code.
-- The one permitted mutation is the exact card dirty byte written by the
-- ordinary UI action at 18271E4. Provenance: analysis/native-ui-cache-v041.md.
local M = {version="0.1.1"}
local UI_GLOBAL = 0x346d538
local UI_CONTEXT_GLOBAL = 0x3326340
local UI_CONTEXT_KIND = 0xac21c
local CARD_OFFSET = 0x257f78
local FLAGS_OFFSET = 0xbcd0
local ANCHORS = {
    {rva=0xaa0630, hex="488B0D01CF9C024881C1787F2500"}, -- global -> card
    {rva=0x1826999, hex="3B98D4BC0000750D80B8D1BC0000000F84D0000000"}, -- cache/dirty gate
    {rva=0x1826a6e, hex="41C687D1BC000000"}, -- card refresh clears dirty
    {rva=0x18271df, hex="4C8B7C244041C687D1BC000001"}, -- normal action marks dirty
    {rva=0x182897c, hex="C681D0BC000000"}, -- opening only clears hidden
    {rva=0x12f0be8, hex="4C8B1551570302418B821CC20A00"}, -- UI context selector
    {rva=0x12f0c12, hex="83F8047519488D8F40E32400"}, -- kind4 constructs this HUD
}
local function unhex(value)
    return (value:gsub("..",function(pair) return string.char(tonumber(pair,16)) end))
end
for _,anchor in ipairs(ANCHORS) do anchor.bytes=unhex(anchor.hex) end
local function u32(bytes,offset)
    local a,b,c,d=bytes:byte(offset+1,offset+4)
    return a+b*256+c*65536+d*16777216
end
local function hex(value)
    return (value:gsub(".",function(c) return string.format("%02X",c:byte()) end))
end
local function check(value,message)
    if not value then error(message,0) end
end

-- Read-only. All fields belong to the exact currently rooted UI object.
-- Returns a table with status:
--   needs_invalidation: same selected/displayed weapon, clean cached card;
--   already_dirty: its next normal card update will refresh it;
--   different_cached_weapon: next normal update refreshes on EID mismatch;
-- or nil, reason when identity/layout/code could not be established.
-- Neither hidden cards nor already dirty cards are treated as an error.
local function inspect(reader,snapshot,allow_previous_display)
    if type(reader)~="table" or type(reader.verify)~="function" then
        return nil,"native UI requires a verified reader"
    end
    local verified,reason=reader:verify()
    if not verified then return nil,reason end
    return reader:transaction(function(read,ptr,lookup)
        local active=reader:guard_active(snapshot,read,ptr,lookup)
        for _,anchor in ipairs(ANCHORS) do
            check(read(reader.game+anchor.rva,#anchor.bytes)==anchor.bytes,
                  string.format("native UI code anchor mismatch at %X",anchor.rva))
        end
        local context=ptr(reader.game+UI_CONTEXT_GLOBAL)
        check(u32(read(context+UI_CONTEXT_KIND,4),0)==4,
              "native weapon-card UI context is not the verified constructor kind 4")
        local root=ptr(reader.game+UI_GLOBAL)
        local card=root+CARD_OFFSET
        local fields=read(card+FLAGS_OFFSET,12)
        local hidden,dirty=fields:byte(1,2)
        check(hidden<=1 and dirty<=1,"native UI hidden/dirty bytes outside native boolean range")
        local cached,display=u32(fields,4),u32(fields,8)
        local expected_display=active.display_eid or active.entity.eid
        local result={root=root,card=card,address=card+FLAGS_OFFSET+1,context=context,context_kind=4,
            hidden=hidden==1,dirty=dirty==1,cached_eid=cached,display_eid=display,
            active_eid=active.entity.eid,expected_display_eid=expected_display,fields=fields,fields_hex=hex(fields),
            weapon_bytes=active.bytes,weapon_entity_address=active.entity_address,
            game_base=reader.game,root_global_address=reader.game+UI_GLOBAL}
        if cached~=active.entity.eid then
            result.status="different_cached_weapon"
            result.reason="normal card update already refreshes when weapon EID differs"
        else
            -- Controls need the actual current display. Only invalidation may
            -- accept the other member of this proven parent/attachment pair:
            -- kind11 changes +4 without changing the cached parent +BCD4.
            local accepted=display==expected_display
            local rejection
            if not accepted and allow_previous_display then
                if display==active.entity.eid and active.display_child and
                   active.display_child.entity.eid==expected_display then
                    accepted=true
                elseif expected_display==active.entity.eid and
                       type(reader.guard_display_child)=="function" then
                    local ok,child=pcall(reader.guard_display_child,reader,snapshot,active,display,read,ptr,lookup)
                    accepted=ok and child~=nil
                    if not accepted then rejection=tostring(child) end
                end
                if accepted then result.previous_display=true end
            end
            check(accepted,"native UI cached/action display identity differs" ..
                (rejection and (": "..rejection) or ""))
            result.status=dirty==1 and "already_dirty" or "needs_invalidation"
        end
        return result
    end,"native-weapon-ui")
end
function M.inspect(reader,snapshot)
    return inspect(reader,snapshot,false)
end

local write_one
local function own_process_writer()
    local ffi=require("ffi")
    check(ffi.os=="Windows" and ffi.abi("64bit"),"native UI requires Windows x64")
    local kernel=ffi.load("kernel32")
    local function bind(name,declaration)
        local ok,value=pcall(function() return kernel[name] end)
        if not ok then ffi.cdef(declaration); value=kernel[name] end
        return value
    end
    local get_process=bind("GetCurrentProcess","void *GetCurrentProcess(void);")
    local write_memory=bind("WriteProcessMemory",
        "int WriteProcessMemory(void *, void *, const void *, size_t, size_t *);")
    -- Keep the ABI exact even if another addon declared the Windows API first.
    write_memory=ffi.cast("int (*)(void *, void *, const void *, size_t, size_t *)",write_memory)
    local process=get_process()
    local one=ffi.new("unsigned char[1]",1)
    local written=ffi.new("size_t[1]")
    return function(address)
        written[0]=0
        local ok=write_memory(process,ffi.cast("void *",address),one,1,written)
        return ok~=0 and tonumber(written[0])==1
    end
end

-- Runtime only, inside the game's normal update callback after an accepted
-- native cycle. Never run this from an external live read-only tracer.
-- Returns status=invalidated/already_dirty/different_cached_weapon, or nil,
-- reason. A UI failure must be logged, never replay the mode cycle to fix it.
function M.invalidate(reader,snapshot)
    local captured,reason=inspect(reader,snapshot,true)
    if not captured then return nil,reason end
    if captured.status~="needs_invalidation" then return captured end
    -- Another complete guarded transaction immediately precedes the one-byte
    -- write. It must agree with the first object, current weapon, and all card
    -- fields. The native reader repeats every read before accepting it.
    local current,failure=inspect(reader,snapshot,true)
    if not current then return nil,failure end
    if current.status~="needs_invalidation" then return current end
    if current.game_base~=captured.game_base or current.context~=captured.context or current.root~=captured.root or
       current.card~=captured.card or current.fields~=captured.fields or
       current.weapon_bytes~=captured.weapon_bytes then
        return nil,"native UI changed before dirty-byte invalidation"
    end
    if not write_one then
        local ok,writer=pcall(own_process_writer)
        if not ok then return nil,tostring(writer) end
        write_one=writer
    end
    -- Final copies occur after Windows writer initialization. No stored UI
    -- pointer is reused across calls or after a changed character/selection.
    local final,final_reason=inspect(reader,snapshot,true)
    if not final then return nil,final_reason end
    if final.status~="needs_invalidation" then return final end
    if final.context~=current.context or final.root~=current.root or final.card~=current.card or
       final.fields~=current.fields or final.weapon_bytes~=current.weapon_bytes then
        return nil,"native UI changed immediately before dirty-byte invalidation"
    end
    if not write_one(final.address) then return nil,"native UI one-byte write failed; no mode replay" end
    -- Do not silently retry on an uncertain result. The UI itself may consume
    -- the dirty byte during its normal update; report what was observed.
    local after,after_reason=inspect(reader,snapshot,true)
    if not after then return nil,"native UI write sent; readback unavailable: "..tostring(after_reason) end
    if after.context~=final.context or after.root~=final.root or after.card~=final.card or after.cached_eid~=final.cached_eid or
       after.display_eid~=final.display_eid or after.weapon_bytes~=final.weapon_bytes then
        return nil,"native UI write sent; object changed during readback"
    end
    if not after.dirty then return nil,"native UI write sent; dirty readback was cleared, no repeat" end
    after.status="invalidated"
    return after
end

M.layout={ui_global_rva=UI_GLOBAL,card_offset=CARD_OFFSET,flags_offset=FLAGS_OFFSET,
    context_global_rva=UI_CONTEXT_GLOBAL,context_kind_offset=UI_CONTEXT_KIND,required_context_kind=4,
    dirty_offset=FLAGS_OFFSET+1,cached_eid_offset=FLAGS_OFFSET+4,display_eid_offset=FLAGS_OFFSET+8,
    requires_vtable=false,object_kind="plain embedded UI aggregate initialized by 1823910 -> 1446840"}
M.anchors=ANCHORS
return M

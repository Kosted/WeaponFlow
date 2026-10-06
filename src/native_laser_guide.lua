-- Read the current instance's selected laser-guidance switch (function kind 6).
-- Capture/build provenance: analysis/native-laser-guide-192554.md.
-- Read-only: no game calls, writes, synthetic inputs, or assumed initial mode.
local M = {version="0.1.0"}
local WEAPON_MANAGER, LASER_MANAGER = 0x3326ce0, 0x3326960
local OWNER, INVALID_ENTITY = 0x346bf98, 0x3483c34
local SIDES = {"left","right","up","down"}
local MAX_INDEX, MAX_HASH = 262144, 1048576 -- read budgets, not weapon counts
local ANCHORS = {
    {rva=0x755642,hex="4C8B351713BD02"}, -- generic cycle's actual manager
    {rva=0x75568d,hex="8BD3498BCEE889B326003401498BCE0FB6F0440FB6C6E838B42600"},
    {rva=0x9c0aba,hex="498B42600FB60401"}, -- getter: one byte at state[index]
    {rva=0x9c0bda,hex="F645140174AD488B436045383C0674A345883C06BAD23BD2F8"},
    {rva=0x5013c8,hex="448B41084983C00249C1E0064D03C3"}, -- definition index/stride
}
local function unhex(s)
    return (s:gsub("..",function(pair) return string.char(tonumber(pair,16)) end))
end
for _,anchor in ipairs(ANCHORS) do anchor.bytes=unhex(anchor.hex) end
local function check(value,reason) if not value then error(reason,0) end return value end
local function u32(s,o)
    check(type(s)=="string" and #s>=o+4,"truncated laser-guidance read")
    local a,b,c,d=s:byte(o+1,o+4)
    return a+b*256+c*65536+d*16777216
end
local function index_for(read,ptr,lookup,manager,eid,label)
    -- Creation/removal 531E40/531ED0/531FA0 and allocator 9C1A50 prove:
    -- capacity+10; total+18; active-prefix+1C; EID map+30; entity pointers+48.
    local capacity=u32(read(manager+0x10,4),0)
    local total=u32(read(manager+0x18,4),0)
    local active=u32(read(manager+0x1c,4),0)
    check(capacity>=1 and capacity<=MAX_INDEX and total<=capacity and active<=total,
        label.." registry count/capacity outside bounds")
    local index=lookup(read(manager+0x30,20),eid,MAX_HASH,label)
    check(index~=nil and index>=0 and index<total,label.." registry entry unavailable")
    return index,ptr(ptr(manager+0x48)+index*8)
end
local function definition_for(read,ptr,game,weapon)
    -- Exact 501350 resource lookup: eight full 64-bit hash buckets, followed
    -- by records stride64. There is no instance-override branch in this getter.
    local registry=ptr(ptr(game+OWNER)+0xf129a8)
    local buckets=read(registry,128)
    local key=weapon.bytes:sub(1,8)
    local first=key:byte(1)%8 -- exact resource64 modulo8, no double truncation
    for attempt=0,7 do
        local offset=((first+attempt)%8)*16
        local candidate=buckets:sub(offset+1,offset+8)
        if candidate==key then
            local index=u32(buckets,offset+8)
            check(index<8,"laser definition record outside native registry bound")
            local address=registry+128+index*64
            -- Setter always dereferences +10/+14 for On/Off events, even if
            -- authority is absent. Verify both without calling those events.
            local events=read(address+0x10,8)
            return address,u32(events,0),u32(events,4)
        end
        if candidate==string.rep("\0",8) then break end
    end
    error("laser guidance resource definition unavailable",0)
end

function M.inspect(reader,snapshot,expected_modes)
    if type(reader)~="table" or type(reader.transaction)~="function" or
       type(reader.guard_active)~="function" or type(snapshot)~="table" or
       snapshot.active_weapon_verified~=true then
        return nil,"verified active native weapon snapshot required"
    end
    return reader:transaction(function(read,ptr,lookup)
        local weapon=reader:guard_active(snapshot,read,ptr,lookup)
        check(type(weapon)=="table" and type(weapon.entity)=="table" and
            type(weapon.bytes)=="string" and #weapon.bytes==24,
            "active native weapon identity unavailable")
        local game,eid=reader.game,weapon.entity.eid
        check(type(game)=="number" and type(eid)=="number" and u32(weapon.bytes,8)==eid,
            "active native weapon identity inconsistent")
        check(eid~=u32(read(game+INVALID_ENTITY,4),0),"active native weapon is invalid")
        for _,anchor in ipairs(ANCHORS) do
            check(read(game+anchor.rva,#anchor.bytes)==anchor.bytes,
                string.format("laser guidance code anchor mismatch at %X",anchor.rva))
        end
        local wm=ptr(game+WEAPON_MANAGER)
        local wi=lookup(read(wm+0x30,20),eid,MAX_HASH,"weapon functions")
        check(wi~=nil and wi>=0 and wi<MAX_INDEX,"weapon function entry unavailable")
        check(read(ptr(ptr(wm+0x48)+wi*8),24)==weapon.bytes,
            "weapon function registry identity differs from active weapon")
        local function_bytes=read(ptr(wm+0x58)+wi*0x3f0+0x350,16)
        local result={weapon_eid=eid,weapon_bytes=weapon.bytes,
            functions={},function_bytes=function_bytes,directions={},
            source="native_selected_laser_guidance",live_verified=false}
        local offered=false
        for i,side in ipairs(SIDES) do
            result.functions[side]=u32(function_bytes,(i-1)*4)
            if expected_modes~=nil then
                check(type(expected_modes)=="table" and type(expected_modes.functions)=="table" and
                    expected_modes.functions[side]==result.functions[side],
                    "laser guidance capability changed since weapon mode snapshot")
            end
            if result.functions[side]==6 then offered=true end
        end
        if expected_modes~=nil then
            check(expected_modes.weapon_eid==eid and expected_modes.weapon_bytes==weapon.bytes,
                "laser guidance weapon identity changed since mode snapshot")
        end
        if not offered then return result end

        local manager=ptr(game+LASER_MANAGER)
        local index,entity_pointer=index_for(read,ptr,lookup,manager,eid,"laser guidance")
        check(read(entity_pointer,24)==weapon.bytes,
            "laser guidance registry identity differs from active weapon")
        local address=ptr(manager+0x60)+index
        local selected=read(address,1):byte(1)
        check(selected==0 or selected==1,"laser guidance selected byte is not a boolean")
        -- Foreign-owned components remain readable and saveable. The setter
        -- itself requires authority bit0 before changing/publishing this byte.
        local authority=u32(weapon.bytes,20)%2==1
        local ok,definition,on_event,off_event=pcall(definition_for,read,ptr,game,weapon)
        local supported=authority and ok
        local reason
        if not authority then reason="native laser setter requires current entity authority"
        elseif not ok then reason=tostring(definition) end
        result.laser_manager,result.laser_index=manager,index
        result.state_address,result.selected=address,selected
        result.entity_address,result.authority=entity_pointer,authority
        if ok then
            result.definition_address,result.on_event,result.off_event=definition,on_event,off_event
        else result.definition_reason=tostring(definition) end
        -- All offered kind-6 directions use this same native Boolean. Flat
        -- fields support the coordinator's common optional-direction merger.
        result.action_enum,result.kind,result.present,result.readable=6,"laser_guide",true,true
        result.current,result.slot=selected,selected
        result.choices,result.slot_values={0,1},{0,1}
        result.cycle_supported,result.cycle_pending,result.reason=supported,not authority,reason
        for _,side in ipairs(SIDES) do
            if result.functions[side]==6 then
                result.directions[side]={action_enum=6,kind="laser_guide",present=true,
                    readable=true,current=selected,slot=selected,choices={0,1},slot_values={0,1},
                    cycle_supported=supported,reason=reason,authority=authority,
                    cycle_pending=not authority,
                    state_address=address,source=result.source}
            end
        end
        return result
    end,"native-laser-guide")
end

M.anchors=ANCHORS
M.cycle={rva=0x7552d0,function_kind=6,
    signature_hex="48895C24204489442418555657415641574883EC30",
    arguments="RCX=WeaponDataManager, EDX=native weapon EID, R8D=6 (LaserGuide)",
    result="unspecified; fresh guarded boolean readback required"}
M.layout={manager_rva=LASER_MANAGER,map_offset=0x30,entities_offset=0x48,
    states_offset=0x60,state_stride=1,definition_registry_offset=0xf129a8,
    definition_buckets=8,definition_stride=64}
return M

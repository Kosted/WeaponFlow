-- Current programmable-ammunition choice (function kind 8), read-only.
-- Exact captured build: analysis/native-additional-functions-192554.md.
-- The stored value is the current instance's projectile enum, not an assumed
-- HE/Flak label. Ammunition choices are fixed per weapon type, not modules.
local M = { version = "0.1.0" }
local WEAPON_MANAGER, PROJECTILE_MANAGER, OWNER = 0x3326ce0, 0x33266d8, 0x346bf98
local MAX_HASH, MAX_INDEX = 1048576, 262144 -- read budgets, not inventory limits
local SIDES = { "left", "right", "up", "down" }

local function check(value, reason) if not value then error(reason, 0) end return value end
local function u32(s, o)
    check(type(s)=="string" and #s>=o+4,"truncated programmable ammunition read")
    local a,b,c,d=s:byte(o+1,o+4)
    return a+b*256+c*65536+d*16777216
end
local function resource_mod(s,n)
    local value=0
    for i=8,1,-1 do value=(value*256+s:byte(i))%n end
    return value
end

-- Getter, cycle arithmetic, menu offered-count/projectiles, and both native
-- definition layouts. NativeReader owns the full file hash/build gate.
M.anchors = {
    {rva=0x755ef8,bytes="\x48\x8b\x43\x60\x4b\x8d\x0c\x49\x8b\x44\x88\x04\xc1\xe8\x02\xeb\x31"},
    {rva=0x755731,bytes="\xc1\xee\x02\xff\xce\x83\xe6\x01"},
    {rva=0x759fe4,bytes="\x83\xfe\x02\x0f\x83\xa0\xfc\xff\xff"},
    {rva=0x75a064,bytes="\x85\xf6\x75\x0d\x8b\x00\x49\x89\x04\x24\x8b\xc6\xe9\x1d\xfc\xff\xff\x8b\x80\x40\x02\x00\x00\x49\x89\x04\x24\x8b\xc6\xe9\x0c\xfc\xff\xff"},
    {rva=0x5151aa,bytes="\x8b\x41\x04\x83\xf8\xff\x74\x13\x48\x69\xc0\x68\x02\x00\x00\x49\x03\x83\xd0\x00\x00\x00"},
    {rva=0x514c1f,bytes="\x4c\x8b\x90\x80\x2e\xf1\x00"},
    {rva=0x514c8e,bytes="\x8b\x48\x08\x48\x69\xc1\x68\x02\x00\x00\x48\x05\xe0\x21\x00\x00\x49\x03\xc2\xc3"},
}

local function definition_address(read,ptr,lookup,game,pm,weapon)
    -- Native 515100 resolves an EID override before the resource fallback.
    local header=read(pm+0x90,20)
    local index
    if u32(header,8)>0 then index=lookup(header,weapon.entity.eid,MAX_HASH) end
    if index~=nil then
        check(index<MAX_INDEX,"projectile definition index exceeds bounded read budget")
        return ptr(pm+0xd0)+index*0x268,"instance_override"
    end
    -- Native 514C10: full 64-bit resource hash, 542 16-byte buckets, followed
    -- by 0x268-byte definitions. Never use a lossy Lua number for the hash.
    local registry=ptr(ptr(game+OWNER)+0xf12e80)
    local buckets=read(registry,0x21e0)
    local first=resource_mod(weapon.bytes,0x21e)
    for attempt=0,0x21d do
        local offset=((first+attempt)%0x21e)*16
        local hash=buckets:sub(offset+1,offset+8)
        if hash==weapon.bytes:sub(1,8) then
            local record=u32(buckets,offset+8)
            check(record<0x21e,"projectile resource definition index outside registry bound")
            return registry+0x21e0+record*0x268,"native_resource_fallback"
        end
        if hash==string.rep("\0",8) then break end
    end
    error("projectile definition absent from current instance and resource registries",0)
end

-- Kind 8's native cycle unconditionally dereferences WeaponData definition
-- +4B4 before toggling its mask. Reading the selected projectile does not need
-- this field, but a callable cycle must validate this additional precondition.
local function cycle_dependencies(read,ptr,lookup,game,manager,weapon)
    local header=read(manager+0x70,20)
    local index,definition,origin
    if u32(header,8)>0 then index=lookup(header,weapon.entity.eid,MAX_HASH) end
    if index~=nil then
        check(index<MAX_INDEX,"weapon definition index exceeds bounded read budget")
        definition,origin=ptr(manager+0xb0)+index*0x4d0,"instance_override"
    else
        local registry=ptr(ptr(game+OWNER)+0xf12bd8)
        local buckets=read(registry,0x2da0)
        local first=resource_mod(weapon.bytes,0x2da)
        for attempt=0,0x2d9 do
            local offset=((first+attempt)%0x2da)*16
            local hash=buckets:sub(offset+1,offset+8)
            if hash==weapon.bytes:sub(1,8) then
                local record=u32(buckets,offset+8)
                check(record<0x2da,"weapon resource definition index outside registry bound")
                definition,origin=registry+0x2da0+record*0x4d0,"native_resource_fallback"
                break
            end
            if hash==string.rep("\0",8) then break end
        end
    end
    check(definition~=nil,"weapon definition unavailable for programmable ammunition cycle")
    local event=u32(read(definition+0x4b4,4),0)
    local result={weapon_definition_address=definition,weapon_definition_source=origin,
        cycle_animation_event=event}
    if event~=0 then
        -- 808810 skips absent event components; it never indexes an absent row.
        local em=ptr(game+0x3326de8)
        local event_header=read(em+0x48,20)
        local event_index
        if u32(event_header,8)>0 then event_index=lookup(event_header,weapon.entity.eid,MAX_HASH) end
        if event_index~=nil then
            check(event_index<MAX_INDEX,"animation event component index exceeds bounded read budget")
            check(read(ptr(ptr(em+0x60)+event_index*8),24)==weapon.bytes,
                "animation event component identity differs from active weapon")
            result.animation_component_present=true
        else result.animation_component_present=false end
    end
    return result
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
            "active programmable ammunition identity invalid")
        for _,anchor in ipairs(M.anchors) do
            check(read(game+anchor.rva,#anchor.bytes)==anchor.bytes,
                string.format("programmable ammunition code anchor differs at %X",anchor.rva))
        end
        local manager=ptr(game+WEAPON_MANAGER)
        local index=lookup(read(manager+0x30,20),eid,MAX_HASH)
        check(index~=nil and index<MAX_INDEX,"programmable weapon state index unavailable")
        check(read(ptr(ptr(manager+0x48)+index*8),24)==weapon.bytes,
            "programmable weapon registry identity differs from active weapon")
        local function_bytes=read(ptr(manager+0x58)+index*0x3f0+0x350,16)
        local result={kind="programmable_ammo",action_enum=8,present=false,readable=false,
            choices={},slot_values={},cycle_supported=false,capture_supported=false,functions={},function_bytes=function_bytes,
            weapon_manager=manager,weapon_eid=eid,weapon_bytes=weapon.bytes,
            source="native_current_instance_projectile_definition"}
        for i,side in ipairs(SIDES) do
            local action=u32(function_bytes,(i-1)*4)
            result.functions[side]=action
            if expected_modes~=nil then
                check(type(expected_modes)=="table" and type(expected_modes.functions)=="table" and
                    expected_modes.functions[side]==action,"programmable weapon function layout changed between reads")
            end
            if action==8 then result.present=true end
        end
        if not result.present then
            result.reason="current instance offers no programmable ammunition direction"
            return result
        end
        local mask=u32(read(ptr(manager+0x60)+index*12+4,4),0)
        local slot=math.floor(mask/4)%4
        check(slot<2,"programmable ammunition selected slot outside native binary choices")
        local pm=ptr(game+PROJECTILE_MANAGER)
        local pi=lookup(read(pm+0x50,20),eid,MAX_HASH)
        check(pi~=nil and pi<MAX_INDEX,"programmable projectile component unavailable")
        check(read(ptr(ptr(pm+0x68)+pi*8),24)==weapon.bytes,
            "programmable projectile component identity differs from active weapon")
        local definition,origin=definition_address(read,ptr,lookup,game,pm,weapon)
        local first=u32(read(definition,4),0)
        local second=u32(read(definition+0x240,4),0)
        -- Native menu 75A376 validates projectile type < 0x15F. Enum zero is
        -- representable; it is not the settings file's explicit None marker.
        check(first<0x15f and second<0x15f,"programmable projectile enum outside supported native menu range")
        result.mask_raw,result.slot=mask,slot
        result.choices,result.slot_values={first,second},{first,second}
        result.current=result.slot_values[slot+1]
        result.readable=true
        result.capture_supported=first~=second
        local safe,dependencies=pcall(cycle_dependencies,read,ptr,lookup,game,manager,weapon)
        result.cycle_supported=result.capture_supported and safe
        if safe then
            for field,value in pairs(dependencies) do result[field]=value end
        else result.cycle_guard_error=tostring(dependencies) end
        if not result.capture_supported then result.reason="programmable ammunition choices have duplicate semantic values"
        elseif not safe then result.reason="programmable ammunition cycle dependency unavailable: "..tostring(dependencies) end
        result.projectile_manager,result.projectile_index=pm,pi
        result.definition_address,result.definition_source=definition,origin
        return result
    end,"native-programmable-ammo")
end

M.layout={weapon_manager_rva=WEAPON_MANAGER,projectile_manager_rva=PROJECTILE_MANAGER,
    projectile_override_map=0x90,projectile_override_definitions=0xd0,definition_stride=0x268,
    resource_registry_owner_offset=0xf12e80,resource_bucket_count=0x21e,
    resource_definition_offset=0x21e0,primary_projectile_offset=0,alternate_projectile_offset=0x240,
    mask_shift=2,native_slot_count=2,max_projectile_enum_exclusive=0x15f}
return M

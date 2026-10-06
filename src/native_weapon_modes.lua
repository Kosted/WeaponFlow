-- Actual per-instance weapon functions and selected values, read-only.
-- Evidence: analysis/native-mode-handlers-192554.md. Exact build gate is owned
-- by native_equipment_reader. This module does not call game functions.
local M = { version = "0.1.0" }
local WEAPON_MANAGER, PROJECTILE_MANAGER, OWNER = 0x3326ce0, 0x33266d8, 0x346bf98
local SIDES = { "left", "right", "up", "down" }
local KINDS = { [1]="zeroing", [2]="rpm", [3]="firemode", [4]="magazine",
    [5]="flashlight", [6]="laser_guide", [7]="muzzle_velocity", [8]="programmable_ammo",
    [9]="laser_prism", [10]="binary_10", [11]="secondary_fire", [12]="unknown_12" }
local MAX_HASH, MAX_INDEX = 1048576, 262144 -- bounded read budgets, not instance limits
-- Function 10 has two native slots. Its meaning/icons come from the current
-- weapon's resource definition, not a weapon-name or input-key table.
-- Evidence: analysis/native-additional-functions-192554.md and the C4 session.
M.binary10_anchors={
    {rva=0x755f1a,bytes="\x48\x8b\x43\x60\x4b\x8d\x0c\x49\x8b\x44\x88\x04\xc1\xe8\x08\xeb\x0f"},
    {rva=0x75a086,bytes="\x83\xfe\x02\x0f\x83\xfe\xfb\xff\xff\x49\x8b\x06\x49\x89\x04\x24\x8b\xc6\xe9\xf5\xfb\xff\xff"},
    {rva=0x50e2c5,bytes="\x48\x8b\x05\xcc\xdc\xf5\x02\x44\x8b\xc1\x4c\x8b\x90\xd0\x2c\xf1\x00"},
    {rva=0x50e339,bytes="\x8b\x48\x08\x48\x6b\xc1\x58\x48\x05\x20\x01\x00\x00\x49\x03\xc2\xc3"},
    {rva=0x75a447,bytes="\x48\x8b\x8c\x24\x60\x01\x00\x00\xe8\x6c\x3e\xdb\xff\x8b\xcb\x83\xe1\x01\x48\x8d\x0c\x89\x48\x8b\x44\xc8\x18\x49\x89\x03"},
    {rva=0x75581f,bytes="\x48\x8b\x55\x60\x44\x8b\xc8\x4f\x8d\x04\x49\x42\x8b\x4c\x82\x04\x8b\xf1\xc1\xee\x08\x81\xe1\xff\xfc\xff\xff\xff\xce\x83\xe6\x01\x8b\xc6\xc1\xe0\x08\x0b\xc8\x42\x89\x4c\x82\x04\x4d\x8d\x40\x01\x48\x8b\x45\x60\x4e\x8d\x04\x80\x48\x8b\x45\x48\xba\x65\x61\xf8\x31\x4a\x8b\x0c\xc8\x8b\x49\x10\xe8\x74\x3f\x88\x00"},
}

local function check(value, why) if not value then error(why, 0) end return value end
local function u32(s, o)
    check(type(s)=="string" and #s>=o+4, "truncated native mode read")
    local a,b,c,d=s:byte(o+1,o+4)
    return a+b*256+c*65536+d*16777216
end
local function float32(s,o)
    local n=u32(s,o)
    local sign=n>=2147483648 and -1 or 1
    local exponent=math.floor(n/8388608)%256
    local fraction=n%8388608
    check(exponent~=255, "non-finite native mode value")
    if exponent==0 then return sign*fraction*2^-149 end
    return sign*(1+fraction/8388608)*2^(exponent-127)
end
local function bits(n,shift) return math.floor(n/2^shift)%4 end
local function resource_mod(s,modulus)
    local result=0
    for i=8,1,-1 do result=(result*256+s:byte(i))%modulus end
    return result
end
local function hex64(bytes)
    local out={}
    for index=8,1,-1 do out[#out+1]=string.format("%02x",bytes:byte(index)) end
    return table.concat(out)
end
local function binary10_definition(read,ptr,game,weapon)
    local registry=ptr(ptr(game+OWNER)+0xf12cd0)
    local buckets=read(registry,0x120)
    local first=resource_mod(weapon.bytes,18)
    for attempt=0,17 do
        local offset=((first+attempt)%18)*16
        local key=buckets:sub(offset+1,offset+8)
        if key==weapon.bytes:sub(1,8) then
            local index=u32(buckets,offset+8)
            check(index<18,"binary function resource index outside registry bound")
            local address=registry+0x120+index*0x58
            return address,read(address,0x58)
        end
        if key==string.rep("\0",8) then break end
    end
    error("binary function definition absent from current resource registry",0)
end
local function instance_definition(read,ptr,lookup,game,manager,weapon)
    local header=read(manager+0x70,20)
    local index
    if u32(header,8)>0 then index=lookup(header,weapon.entity.eid,MAX_HASH) end
    if index~=nil then
        check(index<MAX_INDEX,"weapon definition index exceeds bounded read budget")
        return ptr(manager+0xb0)+index*0x4d0,"instance_override"
    end
    -- Exact native fallback 509570: 730 resource buckets, stride16, then
    -- definitions stride0x4d0. Compare all 64 resource bits as bytes.
    local root=ptr(game+OWNER)
    local registry=ptr(root+0xf12bd8)
    local buckets=read(registry,0x2da0)
    local first=resource_mod(weapon.bytes,0x2da)
    for attempt=0,0x2d9 do
        local offset=((first+attempt)%0x2da)*16
        local key=buckets:sub(offset+1,offset+8)
        if key==weapon.bytes:sub(1,8) then
            local record=u32(buckets,offset+8)
            check(record<0x2da,"resource definition index outside registry bound")
            return registry+0x2da0+record*0x4d0,"native_resource_fallback"
        end
        if key==string.rep("\0",8) then break end
    end
    error("weapon definition absent in instance and resource registries",0)
end

function M.inspect(reader,snapshot)
    if type(reader)~="table" or type(reader.transaction)~="function" or
       type(reader.guard_active)~="function" or type(snapshot)~="table" or
       snapshot.active_weapon_verified~=true then
        return nil,"verified active native weapon snapshot required"
    end
    return reader:transaction(function(read,ptr,lookup)
        local weapon=reader:guard_active(snapshot,read,ptr,lookup)
        check(type(weapon)=="table" and type(weapon.bytes)=="string" and #weapon.bytes==24,
            "active native weapon identity unavailable")
        local game,eid=reader.game,weapon.entity.eid
        local manager=ptr(game+WEAPON_MANAGER)
        local index=lookup(read(manager+0x30,20),eid,MAX_HASH)
        check(index~=nil and index<MAX_INDEX,"weapon state index unavailable or beyond read budget")
        check(read(ptr(ptr(manager+0x48)+index*8),24)==weapon.bytes,
            "weapon state registry identity differs from active weapon")
        local runtime=ptr(manager+0x58)+index*0x3f0
        local functions=read(runtime+0x350,16)
        local state=read(ptr(manager+0x60)+index*12,12)
        local mode,mask=u32(state,0),u32(state,4)
        local result={weapon_manager=manager,weapon_eid=eid,weapon_bytes=weapon.bytes,
            functions={},directions={},
            fire_mode_raw=mode,mask_raw=mask,live_verified=false,
            source="native_current_instance_weapon_data"}
        -- Definition reads are not prerequisites for RPM or flashlight. Resolve
        -- once if a direction needs it, remembering failures within this event.
        local definition_attempted,definition,definition_error=false,nil,nil
        local function definition_address()
            if not definition_attempted then
                definition_attempted=true
                local ok,address,source=pcall(instance_definition,read,ptr,lookup,game,manager,weapon)
                if ok then
                    definition=address
                    result.definition_address,result.definition_source=address,source
                else definition_error=tostring(address) end
            end
            check(definition~=nil,definition_error or "current instance definition unavailable")
            return definition
        end
        for i,side in ipairs(SIDES) do
            local action=u32(functions,(i-1)*4)
            result.functions[side]=action
            local dir={action_enum=action,present=action~=0,readable=false,
                kind=KINDS[action] or (action==0 and "absent" or "unknown"),choices={},cycle_supported=false}
            result.directions[side]=dir
            local function inspect_direction()
                if action==0 then
                    dir.reason="current instance offers no function in this direction"
                elseif action==3 then
                    check(mode<=8,"selected fire mode outside known native enum")
                    local fire=read(definition_address()+0x90,12)
                    local slots,contiguous={},true
                    local seen_zero=false
                    for slot=0,2 do
                        local value=u32(fire,slot*4)
                        check(value<=8,"offered fire mode outside known native enum")
                        slots[slot+1]=value
                        if value==0 then seen_zero=true else
                            if seen_zero then contiguous=false end
                            dir.choices[#dir.choices+1]=value
                        end
                    end
                    -- Preserve native positions separately from compressed
                    -- choices; Save Defaults records the actual selected slot.
                    dir.slot_values=slots
                    dir.slot=bits(mask,12)
                    dir.safety_override=bits(mask,10)
                    if dir.slot<3 and slots[dir.slot+1]==mode and mode~=0 and dir.safety_override==0 then
                        dir.current,dir.readable=mode,true
                        dir.cycle_supported=contiguous and #dir.choices>1
                        if not dir.cycle_supported then dir.reason="function has no verified contiguous selectable cycle" end
                    else
                        -- Kind11 selects the alternate firing path (enum8).
                        -- The ordinary fire-slot bits are retained for returning
                        -- to the main weapon, not a currently selected firemode.
                        dir.inactive=dir.safety_override==1 and mode==8
                        dir.reason=dir.inactive and "ordinary fire mode inactive during secondary fire" or
                            "selected fire enum and slot disagree or safety override is active"
                    end
                elseif action==1 then
                    local scope=read(definition_address()+0x154,12)
                    local slots,all_positive={},true
                    for slot=0,2 do
                        local value=float32(scope,slot*4)
                        check(value>=0 and value<=10000,"zeroing distance outside bounded supported range")
                        slots[slot+1]=value
                        if value>0 then dir.choices[#dir.choices+1]=value else all_positive=false end
                    end
                    dir.slot_values=slots
                    dir.slot=bits(mask,4)
                    if dir.slot<3 and slots[dir.slot+1]>0 then
                        dir.current,dir.readable=slots[dir.slot+1],true
                        -- Native cycle advances all three slots, including zero.
                        -- Do not expose a callable cycle with a missing middle slot.
                        dir.cycle_supported=all_positive and #dir.choices>1
                        if not dir.cycle_supported then dir.reason="native zeroing cycle includes unavailable slots" end
                    else dir.reason="zeroing selected slot is absent in current definition" end
                elseif action==2 then
                    local pm=ptr(game+PROJECTILE_MANAGER)
                    local pi=lookup(read(pm+0x50,20),eid,MAX_HASH)
                    check(pi~=nil and pi<MAX_INDEX,"projectile RPM entry unavailable or beyond read budget")
                    check(read(ptr(ptr(pm+0x68)+pi*8),24)==weapon.bytes,"RPM registry identity mismatch")
                    local rpm=read(ptr(pm+0x70)+pi*32+0x10,16)
                    local slots={}
                    for slot=0,2 do
                        local value=float32(rpm,slot*4)
                        check(value>=0 and value<=100000,"RPM outside bounded supported range")
                        slots[slot+1]=value
                        if value>0 then dir.choices[#dir.choices+1]=value end
                    end
                    dir.slot_values=slots
                    dir.slot=u32(rpm,12)
                    dir.effective_rpm=float32(read(ptr(pm+0x80)+pi*12+4,4),0)
                    if dir.slot<3 and slots[dir.slot+1]>0 then
                        dir.current,dir.readable=slots[dir.slot+1],true
                        dir.cycle_supported=#dir.choices>1
                    else dir.reason="RPM selected slot is not offered" end
                elseif action==5 then
                    dir.reason="read current attached light through native_flashlight_state.inspect"
                elseif action==6 then
                    dir.reason="read current guidance switch through native_laser_guide.inspect"
                elseif action==8 then
                    dir.reason="read current projectile choices through native_programmable_ammo.inspect"
                elseif action==10 then
                    for _,anchor in ipairs(M.binary10_anchors) do
                        check(read(game+anchor.rva,#anchor.bytes)==anchor.bytes,
                            "binary function native code anchor differs")
                    end
                    local slot=bits(mask,8)
                    check(slot<2,"binary function selected slot outside offered choices")
                    local address,bytes=binary10_definition(read,ptr,game,weapon)
                    dir.slot,dir.current=slot,slot
                    dir.choices,dir.slot_values={0,1},{0,1}
                    dir.icon_hashes={[0]=hex64(bytes:sub(0x19,0x20)),[1]=hex64(bytes:sub(0x41,0x48))}
                    dir.definition_address,dir.module_bytes=address,bytes
                    check(read(address,0x58)==bytes,"binary function definition changed during inspection")
                    dir.readable,dir.capture_supported,dir.cycle_supported=true,true,true
                elseif action==11 then
                    dir.reason="read current secondary fire through native_secondary_fire.inspect"
                else
                    dir.reason="function is offered but its semantic choices are not yet implemented"
                end
            end
            local readable,reason=pcall(inspect_direction)
            if not readable then
                -- Discard partially decoded values. A failed direction is not
                -- Off, slot zero, nor evidence that another direction failed.
                result.directions[side]={action_enum=action,present=action~=0,
                    kind=dir.kind,readable=false,choices={},cycle_supported=false,
                    reason=tostring(reason)}
            elseif dir.cycle_supported then
                local seen={}
                for _,value in ipairs(dir.choices) do
                    if seen[value] then
                        dir.cycle_supported=false
                        dir.reason="duplicate offered values make a value-only cycle ambiguous"
                        break
                    end
                    seen[value]=true
                end
            end
        end
        if result.functions.left==10 or result.functions.right==10 or
           result.functions.up==10 or result.functions.down==10 then
            check(read(runtime+0x350,16)==functions,"weapon functions changed during binary inspection")
            check(read(ptr(manager+0x60)+index*12,12)==state,"weapon state changed during binary inspection")
            reader:guard_active(snapshot,read,ptr,lookup)
        end
        return result
    end)
end

-- Metadata only. A coordinator must freshly validate the active identity,
-- this exact offered function, readable current value, chosen offered value,
-- cycle_supported, and code signature before any eventual normal game action.
M.cycle={rva=0x7552d0,signature_hex="48895C24204489442418555657415641574883EC30",
    c_signature="void (__fastcall *)(void *, unsigned int, unsigned int)",
    arguments="RCX=WeaponDataManager, EDX=native weapon EID, R8D=WeaponFunctionType",
    result="unspecified; read the selected value again after the action"}
M.function_kinds=KINDS
M.layout={weapon_manager_rva=WEAPON_MANAGER,projectile_manager_rva=PROJECTILE_MANAGER,
    state_stride=12,runtime_stride=0x3f0,function_array_offset=0x350,
    definition_stride=0x4d0,definition_fire_modes_offset=0x90,definition_scope_zeroing_offset=0x154}
return M

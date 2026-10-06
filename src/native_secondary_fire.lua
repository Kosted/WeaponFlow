-- Selected primary/secondary firing system (native function 11), read-only.
-- Evidence: analysis/native-secondary-fire-192554.md. This is not Railgun
-- safety or muzzle velocity. NativeReader owns build and active-identity gates.
local M = {version="0.1.1"}
local WEAPON_MANAGER, OWNER = 0x3326ce0, 0x346bf98
local MAX_HASH, MAX_INDEX = 1048576, 262144 -- read budgets, not instance counts
local SIDES = {"left","right","up","down"}
local function check(value,reason) if not value then error(reason,0) end return value end
local function u32(s,o)
    check(type(s)=="string" and #s>=o+4,"truncated secondary-fire read")
    local a,b,c,d=s:byte(o+1,o+4);return a+b*256+c*65536+d*16777216
end
local function resource_mod(s,n)
    local v=0;for i=8,1,-1 do v=(v*256+s:byte(i))%n end;return v
end
local function hex64(s)
    local out={};for i=8,1,-1 do out[#out+1]=string.format("%02x",s:byte(i)) end
    return table.concat(out)
end
local function unhex(s)
    return (s:gsub("..",function(pair)return string.char(tonumber(pair,16))end))
end
M.anchors={
    {rva=0x755ed9,hex="488B43604B8D0C498B448804C1E80AEB50"},
    {rva=0x755f3a,hex="83E003"},
    {rva=0x75a086,hex="83FE020F83FEFBFFFF498B06498904248BC6E9F5FBFFFF"},
    {rva=0x7554f6,hex="488B5560448BC84B8D34498B4CB2048BF981E1FFF3FFFFC1EF0AFFCF83E7018BC7C1E00A0BC8894CB204"},
    {rva=0x755541,hex="8BD385FF7415BE08000000488BCD448BC6E8390A0000E9C9030000488B4560448B44B00441C1E80C4183E003E87E120000448BC08BD3488BCD8BF0E80F0A0000"},
    {rva=0x75543b,hex="41F7C6000C0000741541B80B0000008BD3488BCDE87CFEFFFFE9CC040000"},
    {rva=0x75680d,hex="488BC8E82B32DBFF85DB742283EB01741183FB0175E28B8098000000"},
    {rva=0x509ada,hex="8B410483F8FF74134869C0D0040000490383B0000000"},
    {rva=0x50957f,hex="4C8B90D82BF100"},
    {rva=0x5095ee,hex="8B48084869C1D00400004805A02D00004903C2C3"},
}
M.presentation_anchors={
    {rva=0x75a331,hex="488B8C2460010000E832F2DAFF85DB7516488B80A0000000498903498BC34881C4300100005BC3488B80A8000000498903498BC34881C4300100005BC3"},
    {rva=0x182934f,hex="498BCEE81902CEFE488BCF85F6750B8B90B0000000E9F70000008B90B4000000E9EC000000"},
}
for _,list in ipairs({M.anchors,M.presentation_anchors}) do
    for _,anchor in ipairs(list) do anchor.bytes=unhex(anchor.hex) end
end
local function anchors(read,game,list)
    for _,anchor in ipairs(list) do
        check(read(game+anchor.rva,#anchor.bytes)==anchor.bytes,
            string.format("secondary-fire code anchor differs at %X",anchor.rva))
    end
end
local function resource_definition(read,ptr,game,weapon)
    -- Native UI uses 509570(resource64), deliberately not 509A40(entity).
    -- Full-width resource comparison and modulo avoid Lua hash truncation.
    local registry=ptr(ptr(game+OWNER)+0xf12bd8)
    local buckets=read(registry,0x2da0)
    local key=weapon.bytes:sub(1,8)
    check(key~=string.rep("\0",8),"secondary-fire resource is empty")
    local first=resource_mod(key,0x2da)
    for attempt=0,0x2d9 do
        local offset=((first+attempt)%0x2da)*16
        local candidate=buckets:sub(offset+1,offset+8)
        if candidate==key then
            local index=u32(buckets,offset+8)
            check(index<0x2da,"secondary-fire resource definition index outside native bound")
            return registry+0x2da0+index*0x4d0
        end
        if candidate==string.rep("\0",8) then break end
    end
    error("secondary-fire resource definition unavailable",0)
end
local function cycle_definition(read,ptr,lookup,manager,weapon,base)
    -- Leaving secondary mode resolves the retained ordinary fire slot through
    -- 7567F0 -> 509A40: the current instance override precedes resource fallback.
    local header=read(manager+0x70,20)
    local index
    if u32(header,8)>0 then index=lookup(header,weapon.entity.eid,MAX_HASH,"secondary-fire definition") end
    if index~=nil then
        check(index>=0 and index<MAX_INDEX,"secondary-fire override index exceeds read budget")
        return ptr(manager+0xb0)+index*0x4d0,"instance_override"
    end
    return base(),"native_resource_fallback"
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
            type(weapon.bytes)=="string" and #weapon.bytes==24,"secondary-fire active identity unavailable")
        local game,eid=reader.game,weapon.entity.eid
        check(type(game)=="number" and type(eid)=="number" and u32(weapon.bytes,8)==eid,
            "secondary-fire active identity inconsistent")
        anchors(read,game,M.anchors)
        local manager=ptr(game+WEAPON_MANAGER)
        local index=lookup(read(manager+0x30,20),eid,MAX_HASH,"secondary-fire weapon")
        check(index~=nil and index>=0 and index<MAX_INDEX,"secondary-fire weapon state entry unavailable")
        check(read(ptr(ptr(manager+0x48)+index*8),24)==weapon.bytes,
            "secondary-fire weapon registry identity mismatch")
        local functions=read(ptr(manager+0x58)+index*0x3f0+0x350,16)
        local result={kind="secondary_fire",action_enum=11,present=false,readable=false,
            choices={},slot_values={},cycle_supported=false,capture_supported=false,
            functions={},function_bytes=functions,weapon_eid=eid,weapon_bytes=weapon.bytes,
            weapon_manager=manager,source="native_selected_secondary_fire",live_verified=false}
        if expected_modes~=nil then
            check(type(expected_modes)=="table" and type(expected_modes.functions)=="table" and
                expected_modes.weapon_eid==eid and expected_modes.weapon_bytes==weapon.bytes,
                "secondary-fire modes belong to another weapon")
        end
        for i,side in ipairs(SIDES) do
            local action=u32(functions,(i-1)*4)
            result.functions[side]=action
            if expected_modes~=nil then
                check(expected_modes.functions[side]==action,"secondary-fire function layout changed")
            end
            if action==11 then result.present=true end
        end
        if not result.present then
            result.reason="current instance offers no secondary-fire direction"
            return result
        end
        local state_address=ptr(manager+0x60)+index*12
        local state=read(state_address,12)
        local mode,mask=u32(state,0),u32(state,4)
        if expected_modes~=nil then
            check(expected_modes.mask_raw==nil or expected_modes.mask_raw==mask,
                "secondary-fire mask changed since mode snapshot")
            check(expected_modes.fire_mode_raw==nil or expected_modes.fire_mode_raw==mode,
                "secondary-fire enum changed since mode snapshot")
        end
        local selected=math.floor(mask/1024)%4
        check(selected<2,"secondary-fire selected slot outside binary choices")
        check(mode>=1 and mode<=8 and ((selected==1)==(mode==8)),
            "secondary-fire selected mask and fire enum disagree")
        result.slot,result.current,result.mask_raw,result.fire_mode_raw=selected,selected,mask,mode
        result.state_address=state_address
        result.choices,result.slot_values={0,1},{0,1}
        result.readable,result.capture_supported=true,true

        local attempted,definition,definition_error=false,nil,nil
        local function base()
            if not attempted then
                attempted=true
                local ok,value=pcall(resource_definition,read,ptr,game,weapon)
                if ok then definition=value else definition_error=tostring(value) end
            end
            return check(definition,definition_error or "secondary-fire base definition unavailable")
        end
        local primary_choices_valid=false
        local supported,why=pcall(function()
            local address,origin=cycle_definition(read,ptr,lookup,manager,weapon,base)
            local fire=read(address+0x90,12)
            local ordinary_slot=math.floor(mask/4096)%4
            check(ordinary_slot<3,"secondary-fire retained ordinary slot outside native choices")
            local value=u32(fire,ordinary_slot*4)
            for i=0,2 do check(u32(fire,i*4)<=7,"secondary-fire ordinary choice outside supported native enum") end
            check(value>=1 and value<=7,"secondary-fire retained ordinary slot is unavailable")
            check(selected==1 or value==mode,"secondary-fire ordinary selected enum and slot disagree")
            result.cycle_definition_address,result.cycle_definition_source=address,origin
            result.ordinary_slot,result.ordinary_fire_mode=ordinary_slot,value
            -- A kind-3 request while secondary is active returns to this exact
            -- retained choice instead of advancing the ordinary slot. Keep it
            -- separate from current/readable: enum 8 is still the actual mode.
            local seen,ended,valid={},false,true
            for slot=0,2 do
                local choice=u32(fire,slot*4)
                if choice==0 then ended=true
                elseif ended or seen[choice] then valid=false
                else seen[choice]=true end
            end
            primary_choices_valid=valid
        end)
        result.cycle_supported=supported
        if not supported then
            result.cycle_guard_error=tostring(why)
            result.reason="secondary-fire cycle dependency unavailable: "..tostring(why)
        end
        if supported and selected==1 and primary_choices_valid then
            for _,side in ipairs(SIDES) do
                if result.functions[side]==3 then
                    -- 75543B..755454 calls kind 11 and skips the ordinary-cycle
                    -- body. The coordinator must freshly validate this offered
                    -- kind-3 direction and read back the primary transition.
                    result.primary_activation={action_enum=3,before=8,
                        next_value=result.ordinary_fire_mode,ordinary_slot=result.ordinary_slot}
                    break
                end
            end
        end
        -- Presentation failure does not invent a label or erase a reliably
        -- readable binary selection. Every successful read is still rechecked
        -- by the enclosing NativeReader transaction before anything returns.
        local shown,problem=pcall(function()
            anchors(read,game,M.presentation_anchors)
            local address=base()
            local bytes=read(address+0xa0,24)
            result.icon_hashes={[0]=hex64(bytes:sub(1,8)),[1]=hex64(bytes:sub(9,16))}
            result.label_keys={[0]=u32(bytes,16),[1]=u32(bytes,20)}
            result.definition_address,result.definition_source=address,"native_resource_fallback"
        end)
        if not shown then result.label_error=tostring(problem) end
        return result
    end,"native-secondary-fire")
end
M.cycle={rva=0x7552d0,function_kind=11,
    signature_hex="48895C24204489442418555657415641574883EC30",
    arguments="RCX=WeaponDataManager, EDX=native parent weapon EID, R8D=11",
    result="unspecified; guarded parent bit10/fire-enum readback required"}
M.layout={weapon_manager_rva=WEAPON_MANAGER,state_stride=12,mask_shift=10,
    native_slot_count=2,definition_stride=0x4d0,resource_registry_owner_offset=0xf12bd8,
    resource_bucket_count=0x2da,resource_definition_offset=0x2da0,
    primary_icon_offset=0xa0,secondary_icon_offset=0xa8,
    primary_label_offset=0xb0,secondary_label_offset=0xb4}
return M

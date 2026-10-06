-- Read the game's icon selection; never invokes a native game function.
-- Exact captured build and routes: analysis/native-hud-icons-192554.md.
local M = {version="0.3.0"}
local SIDES={"left","right","up","down"}
local MAX_HASH,MAX_INDEX=1048576,262144
local RPM_ICONS={"52bbfc5a70359393","c7546fc9c7b6db4e","f03c671b15d01a6b"}
local ZEROING_ICONS={"6be28cced767bb52","46271d0b4ce4136c","a2ab43e85546f79a"}
local LIGHT_ICONS={"b3fa2dbb309b3fa4","8c37e52e722473d9","e109fa5ca9246b55"}
local GUIDE_ICONS={"a9f9bf81827c51e5","c1028550c62fc4fa"}
local FIRE_ICONS={[1]="6115051c9558c50e",[2]="3efff09cd12fb89a",[3]="131742904d846798",
    [4]="16413ee2e6725687",[5]="3efff09cd12fb89a",[6]="131742904d846798",[7]="ad2ec8830fa5a193"}
local BINARY10_CAPTIONS={
    ["38adabc6a32af014"]="mode.c4_deploy",
    ["55374383474193f8"]="mode.c4_detonate",
}
function M.binary10_caption(hash)
    return BINARY10_CAPTIONS[hash] or "mode.choice"
end
local function check(value,why) if not value then error(why,0) end return value end
local function u32(s,o)
    check(type(s)=="string" and #s>=o+4,"truncated HUD icon read")
    local a,b,c,d=s:byte(o+1,o+4); return a+b*256+c*65536+d*16777216
end
local function f32(s,o)
    local n=u32(s,o); local sign=n>=2147483648 and -1 or 1
    local e=math.floor(n/8388608)%256; local f=n%8388608
    check(e~=255,"non-finite HUD RPM")
    if e==0 then return sign*f*2^-149 end
    return sign*(1+f/8388608)*2^(e-127)
end
local function hex64(s)
    check(type(s)=="string" and #s==8,"invalid icon resource hash")
    local out={}; for i=8,1,-1 do out[#out+1]=string.format("%02x",s:byte(i)) end
    return table.concat(out)
end
local function resource_mod(s,n)
    local v=0; for i=8,1,-1 do v=(v*256+s:byte(i))%n end; return v
end
M.anchors={
    -- Getter branches plus full icon dispatch/formatter establish field meanings.
    -- Full additional formatter branches, used for an explicitly chosen direction.
    {rva=0x75a102,bytes="\x45\x85\xc9\x75\x19\x48\xb8\x52\xbb\x67\xd7\xce\x8c\xe2\x6b\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x83\xfb\x01\x75\x19\x48\xb8\x6c\x13\xe4\x4c\x0b\x1d\x27\x46\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x48\xb8\x9a\xf7\x46\x55\xe8\x43\xab\xa2\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3"},
    {rva=0x75a201,bytes="\x45\x85\xc9\x75\x19\x48\xb8\xe5\x51\x7c\x82\x81\xbf\xf9\xa9\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x48\xb8\xfa\xc4\x2f\xc6\x50\x85\x02\xc1\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3"},
    {rva=0x75a238,bytes="\x45\x85\xc9\x75\x19\x48\xb8\xa4\x3f\x9b\x30\xbb\x2d\xfa\xb3\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x83\xfb\x01\x75\x19\x48\xb8\xd9\x73\x24\x72\x2e\xe5\x37\x8c\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x48\xb8\x55\x6b\x24\xa9\x5c\xfa\x09\xe1\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3"},
    {rva=0x75a28d,bytes="\x83\xfb\x01\x0f\x84\x82\x00\x00\x00\x83\xfb\x02\x74\x64\x83\xfb\x03\x74\x46\x83\xfb\x04\x75\x19\x48\xb8\x87\x56\x72\xe6\xe2\x3e\x41\x16\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x83\xfb\x05\x74\x3c\x83\xfb\x06\x74\x1e\x83\xfb\x07\x75\x4b\x48\xb8\x93\xa1\xa5\x0f\x83\xc8\x2e\xad\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x48\xb8\x98\x67\x84\x4d\x90\x42\x17\x13\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x48\xb8\x9a\xb8\x2f\xd1\x9c\xf0\xff\x3e\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3\x48\xb8\x0e\xc5\x58\x95\x1c\x05\x15\x61\x48\x89\x02\x49\x8b\xc3\x48\x81\xc4\x30\x01\x00\x00\x5b\xc3"},
    {rva=0x755ef8,bytes="\x48\x8b\x43\x60\x4b\x8d\x0c\x49\x8b\x44\x88\x04\xc1\xe8\x02\xeb\x31"},
    {rva=0x75a157,bytes="\x45\x85\xc9\x75\x19\x48\xb8\x93\x93\x35\x70\x5a\xfc\xbb\x52\x48\x89\x02\x49\x8b\xc3"},
    {rva=0x75a36e,bytes="\x48\x8b\x84\x24\x60\x01\x00\x00\x48\x3d\x5f\x01\x00\x00\x0f\x83\x1f\x01\x00\x00\x85\xc0\x75\x09\x48\x8d\x05\xd3\xd1\x06\x03\xeb\x0a"},
    {rva=0x75a38f,bytes="\x8b\xc0\x48\x8b\x84\xc1\x70\x76\x7c\x03"},
    {rva=0x75a409,bytes="\x48\x8b\x44\x24\x30\x49\x89\x03"},
    {rva=0x5151aa,bytes="\x8b\x41\x04\x83\xf8\xff\x74\x13\x48\x69\xc0\x68\x02\x00\x00\x49\x03\x83\xd0\x00\x00\x00"},
    {rva=0x514c1f,bytes="\x4c\x8b\x90\x80\x2e\xf1\x00"},
    {rva=0x514c8e,bytes="\x8b\x48\x08\x48\x69\xc1\x68\x02\x00\x00\x48\x05\xe0\x21\x00\x00\x49\x03\xc2\xc3"},
}
-- The card's ammunition formatter copies the same 0x110-byte projectile
-- record then localizes uint32 at +0x0C. These anchors are checked only for
-- text; a failed label read must not discard an independently valid icon.
M.label_anchors={
    {rva=0x1829374,bytes="\x49\x81\xfe\x5f\x01\x00\x00\x0f\x83\xe4\x00\x00\x00\x45\x85\xf6\x75\x09\x48\x8d\x05\xd3\xe1\xf9\x01\xeb\x0b\x41\x8b\xc6\x48\x8b\x84\xc1\x70\x76\x7c\x03\x48\x8d\x4c\x24\x48\xba\x02\x00\x00\x00"},
    {rva=0x1829403,bytes="\x0f\x10\x00\x0f\x11\x01\x48\x8b\x54\x24\x50\x48\xc1\xea\x20\xeb\x49"},
    {rva=0x182945d,bytes="\x48\x8b\xcf\xe8\x2b\x2b\xc1\xff"},
}
local function projectile_definition(read,ptr,lookup,game,pm,weapon)
    local header=read(pm+0x90,20)
    local index
    if u32(header,8)>0 then index=lookup(header,weapon.entity.eid,MAX_HASH) end
    if index~=nil then
        check(index<MAX_INDEX,"HUD projectile override exceeds bounded index")
        return ptr(pm+0xd0)+index*0x268
    end
    local registry=ptr(ptr(game+0x346bf98)+0xf12e80)
    local buckets=read(registry,0x21e0)
    local first=resource_mod(weapon.bytes,0x21e)
    for attempt=0,0x21d do
        local offset=((first+attempt)%0x21e)*16
        local hash=buckets:sub(offset+1,offset+8)
        if hash==weapon.bytes:sub(1,8) then
            local index2=u32(buckets,offset+8)
            check(index2<0x21e,"HUD projectile resource index outside registry")
            return registry+0x21e0+index2*0x268
        end
        if hash==string.rep("\0",8) then break end
    end
    error("HUD projectile definition unavailable",0)
end

local function valid_context(reader,snapshot,modes)
    return type(reader)=="table" and type(reader.transaction)=="function" and
       type(reader.guard_active)=="function" and type(snapshot)=="table" and
       snapshot.active_weapon_verified==true and type(modes)=="table" and
       type(modes.functions)=="table" and type(modes.directions)=="table"
end
local function active_context(reader,snapshot,modes,read,ptr,lookup)
    local weapon=reader:guard_active(snapshot,read,ptr,lookup)
    check(type(weapon)=="table" and type(weapon.entity)=="table" and
        type(weapon.bytes)=="string" and #weapon.bytes==24,"HUD active identity unavailable")
    check(modes.weapon_bytes==weapon.bytes,"HUD modes belong to another weapon")
    local game,eid=reader.game,weapon.entity.eid
    check(type(game)=="number" and type(eid)=="number" and u32(weapon.bytes,8)==eid,
        "HUD native identity invalid")
    for _,anchor in ipairs(M.anchors) do
        check(read(game+anchor.rva,#anchor.bytes)==anchor.bytes,
            string.format("HUD icon code anchor differs at %X",anchor.rva))
    end
    local wm=ptr(game+0x3326ce0)
    local wi=lookup(read(wm+0x30,20),eid,MAX_HASH)
    check(wi~=nil and wi<MAX_INDEX,"HUD weapon state unavailable")
    check(read(ptr(ptr(wm+0x48)+wi*8),24)==weapon.bytes,"HUD weapon registry identity mismatch")
    local address=ptr(wm+0x58)+wi*0x3f0+0x350
    local functions=read(address,16)
    for i,side in ipairs(SIDES) do
        check(u32(functions,(i-1)*4)==modes.functions[side],"HUD function layout changed")
    end
    return weapon,game,eid,wm,wi,address,functions
end
local function projectile_component(read,ptr,lookup,game,weapon)
    local manager=ptr(game+0x33266d8)
    local index=lookup(read(manager+0x50,20),weapon.entity.eid,MAX_HASH)
    check(index~=nil and index<MAX_INDEX,"HUD projectile component unavailable")
    check(read(ptr(ptr(manager+0x68)+index*8),24)==weapon.bytes,"HUD projectile identity mismatch")
    return manager,index
end
local function projectile_record(ptr,game,enum)
    check(type(enum)=="number" and enum%1==0 and enum>=0 and enum<0x15f,
        "HUD ammunition enum outside supported range")
    return enum==0 and game+0x37c7560 or ptr(game+0x37c7670+enum*8)
end
local function label_anchors(read,game)
    for _,anchor in ipairs(M.label_anchors) do
        check(read(game+anchor.rva,#anchor.bytes)==anchor.bytes,"HUD ammunition text code anchor differs")
    end
end
local function projectile_label(read,address,labels)
    local id=u32(read(address+0x0c,4),0)
    return id,labels.get(id)
end

-- Labels for saved ammunition choices, limited to the two choices offered by
-- this actual instance. No caller-supplied enum can index the projectile table.
-- Unknown localization IDs remain absent; invalid native reads reject the map.
function M.ammo_labels(reader,snapshot,modes,labels)
    if not valid_context(reader,snapshot,modes) then
        return nil,"verified active snapshot and current modes required"
    end
    if type(labels)~="table" or type(labels.get)~="function" then
        return nil,"HUD ammunition label lookup unavailable"
    end
    return reader:transaction(function(read,ptr,lookup)
        local weapon,game,eid,wm,wi,function_address,functions=active_context(reader,snapshot,modes,read,ptr,lookup)
        local choices
        for _,side in ipairs(SIDES) do
            local dir=modes.directions[side]
            if modes.functions[side]==8 then
                check(type(dir)=="table" and dir.present==true and dir.readable==true and
                    dir.kind=="programmable_ammo" and type(dir.choices)=="table",
                    "HUD ammunition choices unavailable")
                for index in pairs(dir.choices) do
                    check(index==1 or index==2,"HUD ammunition choices must contain exactly two slots")
                end
                local first,second=dir.choices[1],dir.choices[2]
                for _,enum in ipairs({first,second}) do
                    check(type(enum)=="number" and enum%1==0 and enum>=0 and enum<0x15f,
                        "HUD ammunition choices contain an invalid enum")
                end
                check(first~=nil and second~=nil and first~=second,"HUD ammunition choices unavailable or duplicated")
                check(not choices or (choices[1]==first and choices[2]==second),"HUD ammunition directions disagree")
                choices={first,second}
            elseif type(dir)=="table" then
                check(dir.kind~="programmable_ammo","HUD ammunition direction layout changed")
            end
        end
        local result={}
        if choices then
            label_anchors(read,game)
            local manager=projectile_component(read,ptr,lookup,game,weapon)
            local definition=projectile_definition(read,ptr,lookup,game,manager,weapon)
            local function check_choices()
                check(u32(read(definition,4),0)==choices[1] and
                    u32(read(definition+0x240,4),0)==choices[2],"HUD ammunition offered choices changed")
            end
            check_choices()
            local records,keys={},{}
            for index,enum in ipairs(choices) do
                local address=projectile_record(ptr,game,enum)
                local id,label=projectile_label(read,address,labels)
                records[index],keys[index]=address,id
                if type(label)=="string" and label~="" then result[enum]=label end
            end
            -- A callback or concurrent native change must not mix definitions,
            -- localization records or function layouts into one panel update.
            local final_manager=projectile_component(read,ptr,lookup,game,weapon)
            check(final_manager==manager and
                projectile_definition(read,ptr,lookup,game,manager,weapon)==definition,
                "HUD ammunition definition changed")
            check_choices()
            for index,enum in ipairs(choices) do
                check(projectile_record(ptr,game,enum)==records[index] and
                    u32(read(records[index]+0x0c,4),0)==keys[index],"HUD ammunition label record changed")
            end
        end
        check(read(function_address,16)==functions,"HUD function layout changed during label read")
        reader:guard_active(snapshot,read,ptr,lookup)
        return result
    end,"native-weapon-ammo-labels")
end

local CHOICE_KINDS={[1]="zeroing",[2]="rpm",[3]="firemode",[6]="laser_guide",
    [8]="programmable_ammo",[10]="binary_10",[11]="secondary_fire"}
local function valid_hash(value)
    return type(value)=="string" and #value==16 and value:match("^%x+$") and
        value~="0000000000000000" and value:lower() or nil
end
local function dense(array,count,label)
    check(type(array)=="table",label.." unavailable")
    for index in pairs(array) do
        check(type(index)=="number" and index%1==0 and index>=1 and index<=count,
            label.." contains unexpected slots")
    end
    for index=1,count do check(array[index]~=nil,label.." has missing slots") end
end
local function choice_map(dir,slots,action,icon)
    local kind=CHOICE_KINDS[action]
    check(type(dir)=="table" and dir.present==true and dir.action_enum==action and dir.kind==kind,
        "HUD saved-choice direction metadata changed")
    local count=(action==6 or action==8 or action==10 or action==11) and 2 or 3
    dense(slots,count,"HUD native choice slots")
    dense(dir.slot_values,count,"HUD captured choice slots")
    local zero_valid=action==6 or action==8 or action==10 or action==11
    local offered,seen,result={},{},{}
    for index=1,count do
        local value=slots[index]
        local maximum=action==1 and 10000 or (action==2 and 100000 or (action==3 and 8 or (action==8 and 350 or 1)))
        check(type(value)=="number" and value==value and value>=0 and value<=maximum and
            ((action==1 or action==2) or value%1==0),"HUD native choice value invalid")
        check(dir.slot_values[index]==value,"HUD saved-choice native slots changed")
        if zero_valid or value>0 then
            offered[#offered+1]=value
            local hash=valid_hash(icon(value,index))
            -- A semantic value occurring in two different native slots has no
            -- unique slot icon. Do not arbitrarily use the first or last one.
            if seen[value] then result[value]=nil
            elseif hash then result[value]={hash_hex=hash,slot=index-1,kind=kind} end
            seen[value]=true
        end
    end
    dense(dir.choices,#offered,"HUD captured offered choices")
    for index,value in ipairs(offered) do
        check(dir.choices[index]==value,"HUD saved-choice offered values changed")
    end
    return result
end
local function same_choice_map(first,second)
    for value,choice in pairs(first) do
        local other=second[value]
        if not other or choice.hash_hex~=other.hash_hex or choice.slot~=other.slot or choice.kind~=other.kind then return false end
    end
    for value in pairs(second) do if not first[value] then return false end end
    return true
end

-- All currently offered icons for a saved preset, keyed by semantic value.
-- Saved slot numbers and arbitrary external projectile enums are not inputs.
-- Firemode/Zeroing use a fresh WeaponModes reader; secondary fire uses its
-- native definition reader. Both are repeated before accepting the map.
-- Unknown mappings are omitted; a hard native/identity failure rejects all.
-- This never reads labels, writes memory, or invokes a native game function.
function M.choice_icons(reader,snapshot,modes,helpers)
    if not valid_context(reader,snapshot,modes) then
        return nil,"verified active snapshot and current modes required"
    end
    helpers=type(helpers)=="table" and helpers or {}
    return reader:transaction(function(read,ptr,lookup)
        local weapon,game,eid,wm,wi,function_address,functions=active_context(reader,snapshot,modes,read,ptr,lookup)
        local helper_results,checks,result={},{},{}
        local function helper_read(name)
            local helper=helpers[name]
            check(type(helper)=="table" and type(helper.inspect)=="function",
                "HUD saved-choice helper unavailable: "..name)
            local fresh,why=helper.inspect(reader,snapshot,modes)
            check(type(fresh)=="table",why or ("HUD saved-choice "..name.." read failed"))
            check(fresh.weapon_bytes==weapon.bytes and type(fresh.functions)=="table",
                "HUD saved-choice helper identity unavailable or changed")
            for _,side in ipairs(SIDES) do
                check(fresh.functions[side]==modes.functions[side],"HUD saved-choice helper functions changed")
            end
            return fresh
        end
        local function cached_helper(name)
            if not helper_results[name] then helper_results[name]=helper_read(name) end
            return helper_results[name]
        end
        local function mode_icons(dir,fresh,side,action)
            local current=fresh.directions and fresh.directions[side]
            check(type(current)=="table" and current.present==true and current.action_enum==action and
                current.kind==CHOICE_KINDS[action],"HUD saved-choice current direction changed")
            if current.slot_values==nil and current.readable==false then
                check(dir.slot_values==nil and dir.readable==false,"HUD saved-choice availability changed")
                return {}
            end
            return choice_map(dir,current.slot_values,action,function(value,index)
                if action==3 then return FIRE_ICONS[value] end
                if action==10 then
                    check(current.readable==true and current.module_bytes==dir.module_bytes,
                        "HUD binary function definition changed")
                    return current.icon_hashes and current.icon_hashes[value]
                end
                return ZEROING_ICONS[index]
            end)
        end
        local function ammo_icons(dir)
            local manager,index=projectile_component(read,ptr,lookup,game,weapon)
            local definition=projectile_definition(read,ptr,lookup,game,manager,weapon)
            local slots={u32(read(definition,4),0),u32(read(definition+0x240,4),0)}
            -- First validate the offered enum pair against the captured current
            -- instance. Only then may those native enums index projectile data.
            check(slots[1]~=slots[2],"HUD ammunition offered choices duplicated")
            local icons,records={},{}
            choice_map(dir,slots,8,function() return nil end)
            for native_slot,enum in ipairs(slots) do
                local address=projectile_record(ptr,game,enum)
                records[native_slot]=address
                icons[native_slot]=hex64(read(address+0x10,8))
            end
            return choice_map(dir,slots,8,function(_,index2) return icons[index2] end),
                {manager,index,definition,records[1],records[2],icons[1],icons[2]}
        end
        local function rpm_icons(dir)
            local manager,index=projectile_component(read,ptr,lookup,game,weapon)
            local address=ptr(manager+0x70)+index*32+0x10
            local bytes=read(address,12)
            local slots={f32(bytes,0),f32(bytes,4),f32(bytes,8)}
            return choice_map(dir,slots,2,function(_,native_slot) return RPM_ICONS[native_slot] end),
                {manager,index,address,bytes}
        end
        local function secondary_icons(dir,fresh)
            check(fresh.present==true and fresh.readable==true and fresh.action_enum==11 and
                fresh.kind=="secondary_fire","HUD saved-choice secondary direction unavailable")
            dense(fresh.choices,2,"HUD secondary offered choices")
            check(fresh.choices[1]==0 and fresh.choices[2]==1 and
                type(fresh.slot_values)=="table" and fresh.slot_values[1]==0 and fresh.slot_values[2]==1,
                "HUD secondary offered choices changed")
            return choice_map(dir,fresh.slot_values,11,function(value)
                return fresh.icon_hashes and fresh.icon_hashes[value]
            end)
        end
        for _,side in ipairs(SIDES) do
            local action,dir=modes.functions[side],modes.directions[side]
            if CHOICE_KINDS[action] then
                check(type(dir)=="table" and dir.present==true and dir.action_enum==action and
                    dir.kind==CHOICE_KINDS[action],"HUD saved-choice direction metadata changed")
                if action==1 or action==3 or action==10 then
                    result[side]=mode_icons(dir,cached_helper("weapon_modes"),side,action)
                    checks[#checks+1]=function()
                        return mode_icons(dir,helper_results.weapon_modes,side,action)
                    end
                elseif action==11 then
                    result[side]=secondary_icons(dir,cached_helper("secondary_fire"))
                    checks[#checks+1]=function() return secondary_icons(dir,helper_results.secondary_fire) end
                elseif action==6 then
                    result[side]=choice_map(dir,{0,1},6,function(value) return GUIDE_ICONS[value+1] end)
                    checks[#checks+1]=function() return result[side] end
                else
                    local getter=action==8 and ammo_icons or rpm_icons
                    local map,proof=getter(dir)
                    result[side]=map
                    checks[#checks+1]=function()
                        local fresh_map,fresh_proof=getter(dir)
                        for index,value in ipairs(proof) do
                            check(fresh_proof[index]==value,"HUD saved-choice native definition/record changed")
                        end
                        return fresh_map
                    end
                end
                -- Keep the side with its verification closure without relying
                -- on unspecified table iteration order or a previous selection.
                checks[#checks]={side=side,run=checks[#checks]}
            end
        end
        for name in pairs(helper_results) do helper_results[name]=helper_read(name) end
        for _,verify in ipairs(checks) do
            check(same_choice_map(result[verify.side],verify.run()),"HUD saved-choice icon mapping changed")
        end
        check(read(function_address,16)==functions,"HUD function layout changed during saved-choice read")
        reader:guard_active(snapshot,read,ptr,lookup)
        return result
    end,"native-weapon-choice-icons")
end

-- `modes` is the coordinator's current merged mode inspection. The actual
-- selected value is checked again here before its icon is accepted. Read
-- failures affect only their direction; a global identity failure returns nil.
function M.inspect(reader,snapshot,modes,helpers,selected_side)
    if not valid_context(reader,snapshot,modes) then
        return nil,"verified active snapshot and current modes required"
    end
    if selected_side~=nil and selected_side~="left" and selected_side~="right" and
       selected_side~="up" and selected_side~="down" then
        return nil,"HUD selected direction invalid"
    end
    helpers=type(helpers)=="table" and helpers or {}
    return reader:transaction(function(read,ptr,lookup)
        local weapon,game,eid,wm,wi=active_context(reader,snapshot,modes,read,ptr,lookup)
        local state=ptr(wm+0x60)+wi*12
        local mode,mask=u32(read(state,4),0),u32(read(state+4,4),0)
        local result={directions={},weapon_bytes=weapon.bytes}
        local pm,pi
        local function cached_projectile_component()
            if pm then return pm,pi end
            local manager,index=projectile_component(read,ptr,lookup,game,weapon)
            pm,pi=manager,index
            return pm,pi
        end
        for _,side in ipairs(SIDES) do
            local dir=modes.directions[side]
            if (selected_side==nil or selected_side==side) and type(dir)=="table" and dir.present and dir.readable then
                local ok,value=pcall(function()
                    local action=modes.functions[side]
                    local function helper_read(name)
                        local helper=helpers[name]
                        check(type(helper)=="table" and type(helper.inspect)=="function",
                            "HUD revalidation helper unavailable: "..name)
                        local fresh,why=helper.inspect(reader,snapshot,modes)
                        check(type(fresh)=="table",why or ("HUD "..name.." revalidation failed"))
                        check(fresh.weapon_bytes==weapon.bytes,"HUD helper weapon identity changed")
                        if fresh.functions then
                            for _,direction in ipairs(SIDES) do
                                check(fresh.functions[direction]==modes.functions[direction],
                                    "HUD helper function layout changed")
                            end
                        end
                        return fresh
                    end
                    if action==3 and (selected_side~=nil or dir.current==5 or dir.current==6) then
                        check(mode==dir.current and math.floor(mask/1024)%4==0,
                            "HUD fire mode changed or safety override active")
                        check(math.floor(mask/4096)%4==dir.slot,"HUD fire mode slot changed")
                        check(FIRE_ICONS[mode]~=nil,"HUD fire mode enum has no verified icon mapping")
                        return {kind=mode==5 and "safe" or (mode==6 and "unsafe" or "firemode"),
                            current=mode,slot=dir.slot,hash_hex=FIRE_ICONS[mode]}
                    elseif action==10 then
                        local fresh=helper_read("weapon_modes")
                        local current=fresh.directions and fresh.directions[side]
                        check(current and current.present and current.readable and current.kind=="binary_10" and
                            current.action_enum==10 and current.current==dir.current and current.slot==dir.slot and
                            current.module_bytes==dir.module_bytes and math.floor(mask/256)%4==dir.slot,
                            "HUD binary function selection/definition changed")
                        local hash=current.icon_hashes and current.icon_hashes[current.current]
                        return {kind="binary_10",current=current.current,slot=current.slot,hash_hex=hash,
                            label_message=M.binary10_caption(hash)}
                    elseif action==8 then
                        local manager=cached_projectile_component()
                        local slot=math.floor(mask/4)%4
                        check(slot<2 and slot==dir.slot,"HUD ammunition slot changed or invalid")
                        local definition=projectile_definition(read,ptr,lookup,game,manager,weapon)
                        local enum=u32(read(definition+slot*0x240,4),0)
                        check(enum<0x15f and enum==dir.current,"HUD ammunition value changed or invalid")
                        local record=projectile_record(ptr,game,enum)
                        local hash=hex64(read(record+0x10,8))
                        check(hash~="0000000000000000","HUD ammunition icon unavailable")
                        local value={kind="programmable_ammo",current=enum,slot=slot,hash_hex=hash}
                        if type(helpers.labels)=="table" and type(helpers.labels.get)=="function" then
                            local label_ok,label_key,label=pcall(function()
                                label_anchors(read,game)
                                return projectile_label(read,record,helpers.labels)
                            end)
                            if label_ok then
                                value.label_key,value.label=label_key,label
                                if not label then value.label_reason="HUD ammunition label unavailable: "..tostring(label_key) end
                            else value.label_reason=tostring(label_key) end
                        end
                        return value
                    elseif action==2 then
                        local manager,index=cached_projectile_component()
                        local rpm=read(ptr(manager+0x70)+index*32+0x10,16)
                        local slot=u32(rpm,12)
                        check(slot<3 and slot==dir.slot,"HUD RPM slot changed or invalid")
                        local current=f32(rpm,slot*4)
                        check(current>0 and current<=100000 and current==dir.current,"HUD RPM value changed or invalid")
                        return {kind="rpm",current=current,slot=slot,hash_hex=RPM_ICONS[slot+1]}
                    elseif selected_side~=nil and action==1 then
                        local fresh=helper_read("weapon_modes")
                        local selected=fresh.directions and fresh.directions[side]
                        check(selected and selected.present and selected.readable and selected.kind=="zeroing" and
                            selected.current==dir.current and selected.slot==dir.slot,"HUD zeroing value/slot changed or unreadable")
                        check(type(selected.slot)=="number" and selected.slot>=0 and selected.slot<3 and
                            selected.slot%1==0 and type(selected.current)=="number" and selected.current>0,
                            "HUD zeroing value/slot invalid")
                        return {kind="zeroing",current=selected.current,slot=selected.slot,
                            hash_hex=ZEROING_ICONS[selected.slot+1]}
                    elseif selected_side~=nil and action==5 then
                        local fresh=helper_read("flashlight")
                        check(fresh.present and fresh.selected==dir.current and
                            type(fresh.module_bytes)=="string" and fresh.module_bytes==dir.module_bytes,
                            "HUD flashlight module/value changed or unavailable")
                        check(fresh.selected==0 or fresh.selected==1 or fresh.selected==2,"HUD flashlight enum invalid")
                        return {kind="flashlight",current=fresh.selected,slot=fresh.selected,
                            hash_hex=LIGHT_ICONS[fresh.selected+1]}
                    elseif selected_side~=nil and action==6 then
                        local fresh=helper_read("laser_guide")
                        check(fresh.present and fresh.readable and fresh.current==dir.current,
                            "HUD laser-guidance value changed or unavailable")
                        check(fresh.current==0 or fresh.current==1,"HUD laser-guidance enum invalid")
                        return {kind="laser_guide",current=fresh.current,slot=fresh.current,
                            hash_hex=GUIDE_ICONS[fresh.current+1]}
                    elseif selected_side~=nil and action==11 then
                        local fresh=helper_read("secondary_fire")
                        check(fresh.present and fresh.readable and fresh.current==dir.current and fresh.slot==dir.slot,
                            "HUD secondary firing mode changed or unavailable")
                        local hash=fresh.icon_hashes and fresh.icon_hashes[fresh.current]
                        local value={kind="secondary_fire",current=fresh.current,slot=fresh.slot,hash_hex=hash}
                        if type(helpers.labels)=="table" and type(helpers.labels.get)=="function" then
                            local id=fresh.label_keys and fresh.label_keys[fresh.current]
                            if id then value.label=helpers.labels.get(id) end
                        end
                        return value
                    end
                end)
                if ok then result.directions[side]=value
                else result.directions[side]={reason=tostring(value)} end
            end
        end
        reader:guard_active(snapshot,read,ptr,lookup)
        return result
    end,"native-weapon-hud-icons")
end
return M

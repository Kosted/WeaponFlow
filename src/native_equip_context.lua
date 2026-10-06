-- Passive classification of the actual hand-zero selection. Inventory is used
-- only to classify that observed EID, never to infer which weapon is active.
-- Captured native switch: 797CA9..797CF4, table 797D78; drop: 9AE85C.
local M={version="0.1.0"}
local MAIN={"primary","sidearm","support"}
local SLOT_OFFSETS={primary=0,sidearm=4,support=8,backpack=12,grenade=16}
local function check(v,why) if not v then error(why,0) end return v end
local function u32(s,o)
    check(type(s)=="string" and #s>=o+4,"equip context truncated read")
    local a,b,c,d=s:byte(o+1,o+4);return a+b*256+c*65536+d*16777216
end
local function hex(s) return (s:gsub(".",function(c)return string.format("%02X",c:byte())end)) end
local function same(read,address,expected,label)
    check(read(address,#expected,label)==expected,"equip context "..label.." changed")
end
local function invalid(eid,a,b) return eid==0 or eid==0xffffffff or eid==a or eid==b end
M.anchors={
    {rva=0x797ca9,bytes="\x48\x8d\x14\x40\x48\xc1\xe2\x04\x41\x8d\x46\xff\x49\x03\x51\x50\x83\xf8\x05\x77\xe7\x4c\x8d\x05\x3b\x83\x86\xff\x41\x8b\x8c\x80\x78\x7d\x79\x00\x49\x03\xc8\xff\xe1\x8b\x02\xe9\x69\xff\xff\xff\x8b\x42\x04\xe9\x61\xff\xff\xff\x8b\x42\x08\xe9\x59\xff\xff\xff\x8b\x42\x0c\xe9\x51\xff\xff\xff\x8b\x42\x10"},
    {rva=0x797d78,bytes="\xd2\x7c\x79\x00\xd9\x7c\x79\x00\xe1\x7c\x79\x00\xf1\x7c\x79\x00\xf1\x7c\x79\x00\xe9\x7c\x79\x00"},
    {rva=0x9ae85c,bytes="\x8b\x05\xea\x53\xad\x02\x89\x47\x08"},
}

function M.inspect(reader,baseline,expected_selection_bytes)
    if type(reader)~="table" or type(reader.snapshot)~="function" or
       type(reader.transaction)~="function" or type(baseline)~="table" or
       type(baseline.avatar_bytes)~="string" or #baseline.avatar_bytes~=24 then
        return nil,"equip context requires native reader and baseline avatar"
    end
    if expected_selection_bytes~=nil and (type(expected_selection_bytes)~="string" or #expected_selection_bytes~=8) then
        return nil,"equip context expected selection must be eight bytes"
    end
    local fresh,why=reader:snapshot()
    if not fresh then return nil,why end
    if fresh.avatar_bytes~=baseline.avatar_bytes or fresh.mode_manager~=baseline.mode_manager or
       fresh.mission_type~=baseline.mission_type then return nil,"equip context avatar/mission changed" end
    return reader:transaction(function(read,ptr,lookup)
        local game=reader.game
        for _,a in ipairs(M.anchors) do same(read,game+a.rva,a.bytes,"native slot anchor") end
        local guards={}
        local function remember(address,size,label)
            local bytes=read(address,size,label)
            guards[#guards+1]={address=address,bytes=bytes,label=label}
            return bytes
        end
        local function remember_ptr(address,label)
            local value=ptr(address,label);remember(address,8,label);return value
        end
        local mode=remember_ptr(game+0x33266a0,"mission manager")
        check(mode==fresh.mode_manager,"equip context mission manager changed")
        -- Mission status is checked semantically in watch; do not compare its
        -- entire 0x44-byte row, whose unrelated fields may change in play.
        local mode_bytes=read(mode,0x44,"mission state")
        check(u32(mode_bytes,8)~=0 and u32(mode_bytes,0x40)==fresh.mission_type,
            "equip context mission changed")
        local player=remember_ptr(game+0x3326468,"player manager")
        check(player==fresh.player_manager,"equip context player manager changed")
        check(u32(remember(player+0x3a8,4,"player avatar reference"),0)==fresh.player_avatar_network_id,
            "equip context avatar reference changed")
        local counts=read(player+0x84,8,"player counts")
        check(u32(counts,0)>=1 and u32(counts,0)<=4 and u32(counts,4)>=1 and u32(counts,4)<=4,
            "equip context local player unavailable")
        local player_entity=remember_ptr(player+0xe8,"local player entity")
        check(u32(read(player_entity,24,"local player state"),20)%2==1,
            "equip context local player inactive")
        local owner=remember_ptr(game+0x346bf98,"entity owner")
        local ai=lookup(read(owner+0xf22ec8,20,"avatar entity map"),fresh.player_avatar_network_id,1048576,"equip avatar")
        check(ai~=nil and ai<262144,"equip context avatar entity unavailable")
        check(remember(owner+0xf32f18+ai*24,24,"avatar identity")==fresh.avatar_bytes,
            "equip context avatar identity changed")

        local em=remember_ptr(game+0x3326738,"equipment manager")
        local header=remember(em+0x28,20,"equipment map storage")
        local ei=lookup(header,fresh.avatar.eid,8192,"equip inventory owner")
        check(ei~=nil and ei<4096,"equip context inventory row unavailable")
        local entities=remember_ptr(em+0x40,"equipment entity array")
        local rows=remember_ptr(em+0x50,"equipment row array")
        local entity_pointer=remember_ptr(entities+ei*8,"equipment owner pointer")
        check(remember(entity_pointer,24,"equipment owner identity")==fresh.avatar_bytes,
            "equip context inventory owner changed")
        local row_address=rows+ei*48
        local row=read(row_address,48,"equipment row")
        -- Active-slot enum/counts/throwable bookkeeping can change during a
        -- utility action. Only retained primary/sidearm/support membership
        -- participates in the cheap continuity watch.
        guards[#guards+1]={address=row_address,bytes=row:sub(1,12),label="main equipment slots"}
        local wm=ptr(game+0x3326420,"wielder manager")
        local wi=lookup(read(wm+0x30,20,"wielder map"),fresh.avatar.eid,8192,"equip wielder")
        local wc=u32(read(wm+0x18,4,"wielder count"),0)
        check(wi~=nil and wc<=4096 and wi<wc,"equip context wielder row unavailable")
        check(read(ptr(ptr(wm+0x48,"wielder owners")+wi*8,"wielder owner"),24,"wielder identity")==fresh.avatar_bytes,
            "equip context wielder owner changed")
        local selection_address=ptr(wm+0x60,"wielder rows")+wi*0x1d0
        local selection=read(selection_address,8,"hand-zero selection")
        check(not expected_selection_bytes or selection==expected_selection_bytes,
            "equip context selection changed since observation")
        local eid,alternate=u32(selection,0),u32(selection,4)
        local invalid_eid=u32(remember(game+0x3483c34,4,"native invalid entity"),0)
        local inventory_invalid=u32(remember(game+0x3483c4c,4,"inventory invalid entity"),0)
        local slots={}
        for name,offset in pairs(SLOT_OFFSETS) do slots[name]=u32(row,offset) end
        local previous=baseline.active_weapon and baseline.active_weapon.entity and baseline.active_weapon.entity.eid
        local previous_in_main=false
        local candidate_kind,candidate_slot="unknown",nil
        if invalid(eid,invalid_eid,inventory_invalid) then candidate_kind="empty"
        else
            for _,name in ipairs(MAIN) do if slots[name]==eid then candidate_kind,candidate_slot="weapon",name;break end end
            if not candidate_slot then
                if slots.grenade==eid then candidate_kind,candidate_slot="utility","grenade"
                elseif slots.backpack==eid then candidate_kind,candidate_slot="utility","backpack" end
            end
            if candidate_kind=="weapon" and (slots.grenade==eid or slots.backpack==eid) then
                candidate_kind,candidate_slot="unknown",nil
            end
        end
        for _,name in ipairs(MAIN) do
            if previous and not invalid(previous,invalid_eid,inventory_invalid) and slots[name]==previous then previous_in_main=true end
        end
        local candidate_entity,candidate_reason
        if candidate_kind~="empty" then
            local ci=lookup(read(owner+0xf1aeb0,20,"selected entity map"),eid,1048576,"equip selected entity")
            if ci~=nil then
                check(ci<262144,"equip context selected entity index out of bounds")
                local raw=read(owner+0xf32f18+ci*24,24,"selected entity identity")
                check(u32(raw,8)==eid and u32(raw,16)<0x7fff,"equip context selected entity identity mismatch")
                candidate_entity={eid=eid,bytes=raw,resource_hex_le=hex(raw:sub(1,8)),
                    native_unit_id=u32(raw,12),network_object_id=u32(raw,16),flags=u32(raw,20)}
            else
                candidate_reason="selected entity absent from native registry"
                if candidate_kind=="weapon" then candidate_kind="unknown" end
            end
        end
        return {avatar=fresh.avatar,avatar_bytes=fresh.avatar_bytes,selection_eid=eid,
            selection_bytes=selection,selection_address=selection_address,display_alternate_eid=alternate,
            native_invalid_eid=invalid_eid,inventory_invalid_eid=inventory_invalid,
            candidate_kind=candidate_kind,candidate_slot=candidate_slot,candidate_entity=candidate_entity,
            candidate_reason=candidate_reason,previous_eid=previous,previous_in_main=previous_in_main,
            slots=slots,equipment_manager=em,equipment_index=ei,equipment_row_address=row_address,
            equipment_row_bytes=row,mode_manager=fresh.mode_manager,mission_type=fresh.mission_type,
            _watch_guards=guards,_game=game,_player_entity=player_entity,_player_manager=player,
            source="actual native hand-zero EID classified by current primary/sidearm/support inventory slots"}
    end,"equip-context")
end

-- Stable utility/empty phase: bounded copied reads, no table walk, no WeaponData
-- requirement. Changed inventory requires fresh inspect; failure is not removal.
function M.watch(reader,context)
    if type(reader)~="table" or type(reader.transaction)~="function" or
       type(context)~="table" or type(context._watch_guards)~="table" then
        return false,"equip context watch snapshot unavailable"
    end
    local result,why=reader:transaction(function(read)
        check(reader.game==context._game,"equip context game module changed")
        for _,guard in ipairs(context._watch_guards) do same(read,guard.address,guard.bytes,guard.label) end
        local mode=read(context.mode_manager,0x44,"mission state")
        check(u32(mode,8)~=0 and u32(mode,0x40)==context.mission_type,"equip context mission ended/changed")
        local counts=read(context._player_manager+0x84,8,"player counts")
        check(u32(counts,0)>=1 and u32(counts,0)<=4 and u32(counts,4)>=1 and u32(counts,4)<=4,
            "equip context local player unavailable")
        check(u32(read(context._player_entity,24,"local player state"),20)%2==1,"equip context local player inactive")
        return {unchanged=true}
    end,"equip-context-watch")
    if not result then return false,why end
    return true,nil,{read_calls=result.read_calls,read_bytes=result.read_bytes}
end
return M

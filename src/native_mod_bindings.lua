-- Read-only native mod-binding metadata. No input, native calls or writes.
-- Independently implemented from published MBM 2.1 layout facts and the
-- original 25480438 code capture; upstream implementation is not embedded.
local M={version="0.1.0"}
local OWNER_RVA,MAP_OFFSET=0x347cf18,686800
local CAPACITY,BUCKET_SIZE,ENTRY_SIZE,MAX_ENTRIES=256,328,20,16
local ADDRESS_LIMIT=0x800000000000
local MAX_ACTION={[9]=11,[10]=17,[11]=3,[12]=1}
local ANCHORS={
    {rva=0x185f5d6,hex="488B053BD9C101"}, -- input owner global
    {rva=0x12fa3b8,hex="448B8ED87A0A0033D2440FB7C08BC3C1E010440BC0458BD0418D79FF440FAF96E07A0A00"}, -- map capacity/code/multiplier
    {rva=0x12fa3e1,hex="4C8B9ED07A0A000F1F840000000000428D0C128BC74823C84C69E9480100004D03EB45394500"}, -- data, linear probe, 328-byte stride
    {rva=0x12fa7a3,hex="488D0480410F10548508458B6C851848897D8066410F7ED60F1155B0"}, -- 20-byte records at bucket+8
    {rva=0x12fa7c4,hex="418BC6448974246CC1E808458BD6440FB6D841C1EA140F1155084181FBFF000000"}, -- device index and packed input ID
    {rva=0x12fa81c,hex="418BCEBA0100000083E10FD3E223961C7C0A00"}, -- low nibble device type
    {rva=0x12fa890,hex="418BC6F3440F11AD90010000C1E804450F28DD83E00F"}, -- input kind nibble
    {rva=0x12fa8c7,hex="83F8040F8441110000"}, -- kind4 button branch
    {rva=0x12fbb1a,hex="418BC648C1E8080FB6C04869C832010000418BD648C1EA144803CAF30F10B48ED0690D00"}, -- button sample uses flags>>20, not word+4
    {rva=0x12fc19f,hex="418B7808498BE8"}, -- actual trigger at record+8
    {rva=0x12fc1e6,hex="83FF080F87BD020000488D150A3ED0FE8B8CBA30C52F014803CAFFE1"}, -- button trigger range0..8
    {rva=0x12fbdc0,hex="8D42FF8BC8488D0480410F10448508660F73D80866480F7EC048C1E82083F801"}, -- previous record+12 combines mappings
    {rva=0x12fbe80,hex="8BC1488D14804539749514"}, -- only terminal combine0 contributes independently
}
for _,anchor in ipairs(ANCHORS) do
    anchor.bytes=(anchor.hex:gsub("..",function(pair)return string.char(tonumber(pair,16))end))
end
local function check(value,message) if not value then error(message,0) end end
local function u32(bytes,offset)
    local a,b,c,d=bytes:byte(offset+1,offset+4)
    return a+b*256+c*65536+d*16777216
end
local function pointer(bytes)
    local low,high=u32(bytes,0),u32(bytes,4)
    if high>=0x8000 then return nil end
    local value=low+high*4294967296
    return value>=0x10000 and value or nil
end
local function hex(bytes)
    return (bytes:gsub(".",function(value)return string.format("%02X",value:byte())end))
end
local function range(address,size)
    return type(address)=="number" and address==address and address%1==0 and address>=0x10000 and
        address<ADDRESS_LIMIT and size>0 and address+size<ADDRESS_LIMIT
end
local function decode(raw)
    local flags=u32(raw,0)
    local entry={raw=raw,flags=flags,device=flags%16,input_kind=math.floor(flags/16)%16,
        device_index=math.floor(flags/256)%256,button_id=math.floor(flags/1048576),
        trigger_flags=math.floor(flags/65536)%16,trigger=u32(raw,8),combine=u32(raw,12),
        auxiliary_id=raw:byte(5)+raw:byte(6)*256,threshold_bits=u32(raw,16)}
    -- Classification is descriptive only. The command path accepts the
    -- game's evaluated action for all mappings, including axes/chords/devices.
    -- Unknown entries must never be treated as unbound or independent keys.
    local reason
    if entry.device~=3 and entry.device~=4 then reason="unsupported native input device"
    elseif entry.input_kind~=4 then reason="native mapping is not a button"
    elseif entry.device_index~=255 then reason="specific native device index is unsupported"
    elseif entry.button_id==4095 then reason="native input ID is unset"
    elseif entry.trigger>8 then reason="unsupported native button trigger"
    elseif entry.trigger~=entry.trigger_flags then reason="native trigger copies disagree"
    elseif entry.combine~=0 then reason="native mapping is part of a combined input" end
    entry.simple_button=reason==nil;entry.unsupported_reason=reason
    return entry
end
local function snapshot(code,group,action,bytes,owner,owner_bytes,header,buckets,bucket,game)
    check(u32(bytes,0)==code,"native mod-binding bucket code changed")
    local count=u32(bytes,4)
    check(count<=MAX_ENTRIES,"native mod-binding mapping count exceeds 16")
    check(#bytes>=8+count*ENTRY_SIZE,"native mod-binding records truncated")
    local mappings,composite={},false
    for index=0,count-1 do
        local entry=decode(bytes:sub(9+index*ENTRY_SIZE,8+(index+1)*ENTRY_SIZE))
        mappings[#mappings+1]=entry
        if entry.combine~=0 then composite=true end
    end
    if composite then
        -- A terminal combine0 can still depend on its preceding modifier.
        -- Keep the complete native records; never simulate their triggers.
        for _,entry in ipairs(mappings) do
            entry.simple_button=false
            entry.unsupported_reason="native combined input requires complete chord decoding"
        end
    end
    local used=bytes:sub(1,8+count*ENTRY_SIZE)
    return {code=code,group=group,action=action,count=count,unbound=count==0,
        mappings=mappings,composite=composite,signature=hex(used),used_bytes=used,
        owner=owner,owner_bytes=owner_bytes,table_header=header,buckets=buckets,bucket=bucket,game=game}
end

-- code is group*65536+action from MBM's persistent assignment to this addon.
-- Missing code/table, failed reads and changed data return nil,reason; only
-- an existing verified bucket with count0 is unbound. No weapon/mission gate.
function M.inspect(reader,code)
    if type(code)~="number" or code~=code or code%1~=0 or code<0 or code>0xffffffff then
        return nil,"invalid native mod-binding code"
    end
    local group,action=math.floor(code/65536),code%65536
    if not MAX_ACTION[group] or action>MAX_ACTION[group] then
        return nil,"native mod-binding code is outside the supported dormant actions"
    end
    if type(reader)~="table" or type(reader.verify)~="function" or type(reader.transaction)~="function" then
        return nil,"native mod bindings require the verified native reader"
    end
    return reader:transaction(function(read)
        local function checked(address,size,label)
            check(range(address,size),"native mod-binding address outside user range: "..label)
            return read(address,size,label)
        end
        for _,anchor in ipairs(ANCHORS) do
            check(checked(reader.game+anchor.rva,#anchor.bytes,"mod-binding code anchor")==anchor.bytes,
                string.format("native mod-binding code anchor mismatch at %X",anchor.rva))
        end
        local owner_bytes=checked(reader.game+OWNER_RVA,8,"mod-binding owner")
        local owner=pointer(owner_bytes)
        check(owner,"native mod-binding owner pointer unavailable")
        local header=checked(owner+MAP_OFFSET,20,"mod-binding table header")
        local buckets,capacity=pointer(header),u32(header,8)
        check(buckets,"native mod-binding buckets pointer unavailable")
        check(capacity==CAPACITY,"native mod-binding table capacity is not 256")
        check(range(buckets,CAPACITY*BUCKET_SIZE),"native mod-binding table exceeds user address range")
        -- Native12FA3D4/12FA3F0 probes (code*multiplier+i)&255. Reduction
        -- before multiplication preserves exact arithmetic in Lua numbers.
        local start=((code%CAPACITY)*(u32(header,16)%CAPACITY))%CAPACITY
        local bucket,probes
        for offset=0,CAPACITY-1 do
            local address=buckets+((start+offset)%CAPACITY)*BUCKET_SIZE
            if u32(checked(address,4,"mod-binding bucket code"),0)==code then
                bucket,probes=address,offset+1;break
            end
        end
        check(bucket,"native mod-binding action bucket unavailable")
        local bytes=checked(bucket,BUCKET_SIZE,"mod-binding bucket snapshot")
        local result=snapshot(code,group,action,bytes,owner,owner_bytes,header,buckets,bucket,reader.game)
        result.probes=probes
        return result
    end,"native-mod-bindings")
end

-- Between full inspections, observe only this registered action's live mapping
-- metadata. The NativeReader transaction still verifies the module/build and
-- rereads every pointer/header/used record. A moved bucket or failed read is
-- unknown, never unbound; the caller can reacquire it through inspect(). Full
-- code anchors and hash lookup are rechecked before accepting an action edge.
function M.watch(reader,previous,include_event)
    if type(reader)~="table" or type(reader.transaction)~="function" or type(previous)~="table" or
       type(previous.code)~="number" or previous.code%1~=0 or previous.code<0 or previous.code>0xffffffff or
       type(previous.owner_bytes)~="string" or #previous.owner_bytes~=8 or
       type(previous.table_header)~="string" or #previous.table_header~=20 or
       type(previous.used_bytes)~="string" or #previous.used_bytes<8 then
        return nil,"native mod-binding watch requires a verified snapshot"
    end
    local code=previous.code
    local group,action=math.floor(code/65536),code%65536
    if not MAX_ACTION[group] or action>MAX_ACTION[group] then return nil,"invalid watched mod-binding code" end
    return reader:transaction(function(read)
        check(reader.game==previous.game,"native mod-binding module changed")
        local owner=pointer(previous.owner_bytes)
        local buckets=pointer(previous.table_header)
        check(owner and owner==previous.owner and buckets and buckets==previous.buckets,
            "native mod-binding cached pointers disagree")
        check(u32(previous.table_header,8)==CAPACITY,"native mod-binding cached capacity changed")
        check(range(buckets,CAPACITY*BUCKET_SIZE) and range(previous.bucket,BUCKET_SIZE) and
            previous.bucket>=buckets and previous.bucket<buckets+CAPACITY*BUCKET_SIZE and
            (previous.bucket-buckets)%BUCKET_SIZE==0,"native mod-binding cached bucket outside table")
        check(u32(previous.used_bytes,0)==code,"native mod-binding cached code disagrees")
        check(read(reader.game+OWNER_RVA,8,"watched mod-binding owner")==previous.owner_bytes,
            "native mod-binding owner changed")
        check(range(owner+MAP_OFFSET,20),"native mod-binding watched header outside user range")
        check(read(owner+MAP_OFFSET,20,"watched mod-binding table header")==previous.table_header,
            "native mod-binding table changed")
        local prefix=read(previous.bucket,8,"watched mod-binding bucket identity")
        check(u32(prefix,0)==code,"native mod-binding watched bucket moved")
        local count=u32(prefix,4)
        check(count<=MAX_ENTRIES,"native mod-binding mapping count exceeds 16")
        local bytes=prefix
        if count>0 then
            bytes=read(previous.bucket,8+count*ENTRY_SIZE,"watched mod-binding used records")
            check(bytes:sub(1,8)==prefix,"native mod-binding count changed while watching")
        end
        local result=snapshot(code,group,action,bytes,owner,previous.owner_bytes,previous.table_header,
            buckets,previous.bucket,reader.game)
        if include_event then
            -- Same game-evaluated state as MBM2.1 is_down(), without its
            -- inherited-mapping sweep. No trigger is evaluated by this read.
            local address=owner+808+32*(97*group+action)
            check(range(address,1),"native game action outside user range")
            result.game_event=read(address,1,"native game action state")~="\0"
        end
        return result
    end,"watch-native-mod-bindings")
end
function M.event(reader,previous) return M.watch(reader,previous,true) end
-- The dependency's bindings page is native screen26. Only edits observed
-- inside this screen (plus its closing observation) may update our own file.
function M.menu_open(reader)
    if type(reader)~="table" or type(reader.transaction)~="function" then return nil,"native menu reader unavailable" end
    local state,why=reader:transaction(function(read)
        local ui=pointer(read(reader.game+0x347ce28,8,"bindings UI root"))
        check(ui,"bindings UI root unavailable")
        local stack=read(ui+0x429c,24,"bindings screen stack")
        local depth=u32(stack,20)
        check(depth<=5,"bindings screen stack depth invalid")
        if depth==0 then return {open=false} end
        return {open=u32(stack,4*(depth-1))==26}
    end,"binding-editor-context")
    if not state then return nil,why end
    return state.open
end
M.anchors=ANCHORS
M.layout={owner_rva=OWNER_RVA,map_offset=MAP_OFFSET,header_size=20,capacity=CAPACITY,
    bucket_size=BUCKET_SIZE,mapping_offset=8,mapping_size=ENTRY_SIZE,max_mappings=MAX_ENTRIES,
    keyboard_device=3,mouse_device=4,button_kind=4,any_device_index=255,unset_input_id=4095}
return M

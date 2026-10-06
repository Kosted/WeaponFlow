-- Initialize only this addon's verified, unbound keyboard actions.
-- Native parser/serializer proof: analysis/native-mod-binding-defaults.md.
-- No default-map changes, no guessed config order, no direct file writes.
local M={version="0.2.1"}
local OWNER_RVA,MAP_OFFSET,DEFAULTS_OFFSET=0x347cf18,686800,686968
local ANCHORS={
    -- Native bindings row uses the first unused record as its empty fallback.
    {rva=0x17f9174,hex="3973040F8691000000"},
    {rva=0x17f920e,hex="8B5304488D0C95020000004803CA0F10048B8B448B104C8D348B89953C5F0000"},
    {rva=0x585b80,hex="83F90C771D4C8D0574A4A7FF8BC1418B9480A85B58004903D0FFE248C1E9208BC1C3B8FFFFFFFFC39B5B58009B5B58009B5B58009B5B58009B5B58009B5B58009B5B58009B5B58009B5B58009B5B58009B5B58009B5B58009B5B5800"},
    {rva=0xafd0d0,hex="4D8B09488BD9418BE9498BC9C1E5104D8BF84C8BF2E8968AA8FF448B431033D2448B5B18440FB7D0440BD5"},
    {rva=0xafff56,hex="488B05AB638202488D15A4537501488B8828010000488B4130498BCEFFD084C0488D158B537501488B0584638202488B8828010000740E488B41704533C0498BCEFFD0EB0C488B8140010000498BCEFFD0488BF048C7453009000000488D056F6B75014C8BC64C8D4D304889442420488BD7488BCBE8F0D0FFFF488D05F95C7501C74534010000004C8D4D3048894424204C8BC6488BD7488BCBE8CBD0FFFF4C8D4D30C74534020000004C8BC64C89642420488BD7488BCBE8ADD0FFFF488D051E527501C74534030000004C8D4D3048894424204C8BC6488BD7488BCBE888D0FFFF488D052D5C7501C74534040000004C8D4D3048894424204C8BC6488BD7488BCBE863D0FFFF488D05E05B7501C74534050000004C8D4D3048894424204C8BC6488BD7488BCBE83ED0FFFF488D0517527501C74534060000004C8D4D3048894424204C8BC6488BD7488BCBE819D0FFFF488D055A6A7501C74534070000004C8D4D3048894424204C8BC6488BD7488BCBE8F4CFFFFF488D05456A7501C74534080000004C8D4D3048894424204C8BC6488BD7488BCBE8CFCFFFFF488D05586A7501C74534090000004C8D4D3048894424204C8BC6488BD7488BCBE8AACFFFFFC745340A000000488D053C6A75014C8BC64C8D4D304889442420488BD7488BCBE885CFFFFF488D05EE697501C745340B0000004C8D4D3048894424204C8BC6488BD7488BCBE860CFFFFF488B05A1618202488D1572517501488B8828010000488B4130498BCEFFD084C0488D1559517501488B057A618202488B8828010000740E488B41704533C0498BCEFFD0EB0C488B8140010000498BCEFFD0488BF048C745300A000000488D05756975014C8BC64C8D4D304889442420488BD7488BCBE8E6CEFFFF488D05CF697501C74534010000004C8D4D3048894424204C8BC6488BD7488BCBE8C1CEFFFF488D05C2697501C74534020000004C8D4D3048894424204C8BC6488BD7488BCBE89CCEFFFF488D053D697501C74534030000004C8D4D3048894424204C8BC6488BD7488BCBE877CEFFFF488D0538697501C74534040000004C8D4D3048894424204C8BC6488BD7488BCBE852CEFFFF488D05BB697501C74534050000004C8D4D3048894424204C8BC6488BD7488BCBE82DCEFFFF488D05BE697501C74534060000004C8D4D3048894424204C8BC6488BD7488BCBE808CEFFFF488D0521697501C74534070000004C8D4D3048894424204C8BC6488BD7488BCBE8E3CDFFFF488D0524697501C74534080000004C8D4D3048894424204C8BC6488BD7488BCBE8BECDFFFF488D05BF697501C74534090000004C8D4D3048894424204C8BC6488BD7488BCBE899CDFFFF488D05BA697501C745340A0000004C8D4D3048894424204C8BC6488BD7488BCBE874CDFFFF488D052D697501C745340B0000004C8D4D3048894424204C8BC6488BD7488BCBE84FCDFFFF488D0530697501C745340C0000004C8D4D3048894424204C8BC6488BD7488BCBE82ACDFFFF488D05AB697501C745340D0000004C8D4D3048894424204C8BC6488BD7488BCBE805CDFFFF488D05A6697501C745340E0000004C8D4D3048894424204C8BC6488BD7488BCBE8E0CCFFFF488D0529697501C745340F0000004C8D4D3048894424204C8BC6488BD7488BCBE8BBCCFFFF488D051C697501C74534100000004C8D4D3048894424204C8BC6488BD7488BCBE896CCFFFF488D057F697501C74534110000004C8D4D3048894424204C8BC6488BD7488BCBE871CCFFFF488B05B25E8202488D15934E7501488B8828010000488B4130498BCEFFD084C0488D157A4E7501488B058B5E8202488B8828010000740E488B41704533C0498BCEFFD0EB0C488B8140010000498BCEFFD0488BF048C745300B000000488D05166975014C8BC64C8D4D304889442420488BD7488BCBE8F7CBFFFF488D05A8687501C74534010000004C8D4D3048894424204C8BC6488BD7488BCBE8D2CBFFFF488D059B687501C74534020000004C8D4D3048894424204C8BC6488BD7488BCBE8ADCBFFFF488D05FE687501C74534030000004C8D4D3048894424204C8BC6488BD7488BCBE888CBFFFF488B05C95D8202488D15E24D7501488B8828010000488B4130498BCEFFD084C0488D15C94D7501488B05A25D8202488B8828010000740E488B41704533C0498BCEFFD0EB0C488B8140010000498BCEFFD0488BF048C745300C000000488D05015775014C8BC64C8D4D304889442420488BD7488BCBE80ECBFFFF488D05EF5E7501C74534010000004C8D4D3048894424204C8BC6488BD7488BCBE8E9CAFFFF"},
    {rva=0xaffca5,hex="4C8D2594557501"},
    {rva=0xae5c9e,hex="488B05FB7A99028BD3488B8CFE800000004C8B80D000000041FFD083F8FF75118B05EC7A9902FFC73BF872C7B8FFFFFFFF488B7424386683C031488B6C2430488B5C24404883C4205FC3"},
    {rva=0xaba84f,hex="83F904753C0FB7C2488D35A25754FF448B8486F0D163024585C075110FB7C283E831488B6C24404883C4205EC3"},
    {rva=0xaba2e6,hex="8B049E83F803740583F8087528488B05A6349C028D57CF488B8CDE800000004C8B80B000000041FFD04885C0"},
    {rva=0xaf2352,hex="418BC6418BCEC1E808458BCEC1E9044183E10F440FB6C083E10F0FB7D6E80C84FCFF4181E6FFFF0F008BD8C1E314410BDE8BCB895C243881E10000F0"},
    {rva=0xaf2421,hex="8302488D15664076010F57D2488B8828010000488B8188000000498BCFFFD0488B05C13E83024C8D"},
}
local NAMES={
    [589824]={section=0x2255308,action=0x2256b28},
    [589825]={section=0x2255308,action=0x2255cd0},
    [589826]={section=0x2255308,action=0x2255240},
    [589827]={section=0x2255308,action=0x2255238},
    [589828]={section=0x2255308,action=0x2255c6c},
    [589829]={section=0x2255308,action=0x2255c44},
    [589830]={section=0x2255308,action=0x22552a0},
    [589831]={section=0x2255308,action=0x2256b08},
    [589832]={section=0x2255308,action=0x2256b18},
    [589833]={section=0x2255308,action=0x2256b50},
    [589834]={section=0x2255308,action=0x2256b60},
    [589835]={section=0x2255308,action=0x2256b30},
    [655360]={section=0x22552e0,action=0x2256b38},
    [655361]={section=0x22552e0,action=0x2256bb0},
    [655362]={section=0x22552e0,action=0x2256bc8},
    [655363]={section=0x22552e0,action=0x2256b68},
    [655364]={section=0x22552e0,action=0x2256b88},
    [655365]={section=0x22552e0,action=0x2256c30},
    [655366]={section=0x22552e0,action=0x2256c58},
    [655367]={section=0x22552e0,action=0x2256be0},
    [655368]={section=0x22552e0,action=0x2256c08},
    [655369]={section=0x22552e0,action=0x2256cc8},
    [655370]={section=0x22552e0,action=0x2256ce8},
    [655371]={section=0x22552e0,action=0x2256c80},
    [655372]={section=0x22552e0,action=0x2256ca8},
    [655373]={section=0x22552e0,action=0x2256d48},
    [655374]={section=0x22552e0,action=0x2256d68},
    [655375]={section=0x22552e0,action=0x2256d10},
    [655376]={section=0x22552e0,action=0x2256d28},
    [655377]={section=0x22552e0,action=0x2256db0},
    [720896]={section=0x22552f0,action=0x2256dc8},
    [720897]={section=0x22552f0,action=0x2256d78},
    [720898]={section=0x22552f0,action=0x2256d90},
    [720899]={section=0x22552f0,action=0x2256e18},
    [786432]={section=0x2255328,action=0x2255c9c},
    [786433]={section=0x2255328,action=0x22564a8},
}
for _,anchor in ipairs(ANCHORS) do
    anchor.bytes=(anchor.hex:gsub("..",function(v)return string.char(tonumber(v,16))end))
end
local function check(v,message) if not v then error(message,0) end end
local function u32(s,o)
    local a,b,c,d=s:byte(o+1,o+4);return a+b*256+c*65536+d*16777216
end
local function pack32(n)
    return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)
end
local function pointer(s)
    local low,high=u32(s,0),u32(s,4)
    check(high<0x8000,"default-binding pointer outside user range")
    local p=low+high*4294967296
    check(p>=0x10000,"default-binding pointer unavailable");return p
end
local function equal_mapping(a,b) return a:sub(1,6)==b:sub(1,6) and a:sub(9)==b:sub(9) end
local function names(reader,code,before,full,record,expected_unused,expected_count,reset_target)
    local entry=NAMES[code]
    if not entry then return nil,"default binding code outside supported dormant actions" end
    return reader:transaction(function(read)
        for _,anchor in ipairs(ANCHORS) do
            check(read(reader.game+anchor.rva,#anchor.bytes,"binding-default code anchor")==anchor.bytes,
                string.format("binding-default code anchor mismatch at %X",anchor.rva))
        end
        local function cstring(rva)
            local body=""
            for offset=0,112,16 do
                local part=read(reader.game+rva+offset,16,"binding serializer name")
                local stop=part:find("\0",1,true)
                if stop then
                    body=body..part:sub(1,stop-1)
                    check(body:match("^[A-Za-z][A-Za-z0-9_]*$") and #body<=127,
                        "binding serializer name is not an identifier")
                    return body
                end
                body=body..part
            end
            error("unterminated binding serializer name",0)
        end
        local result={code=code,section=cstring(entry.section),action=cstring(entry.action)}
        if not full then return result end
        check(reader.game==before.game,"default-binding game module changed")
        check(read(reader.game+OWNER_RVA,8,"default-binding owner")==before.owner_bytes,
            "default-binding owner changed")
        check(read(before.owner+MAP_OFFSET,20,"default-binding map")==before.table_header,
            "default-binding live map changed")
        local target=read(before.bucket,reset_target and 328 or math.max(28,#before.used_bytes),"default-binding target")
        check(u32(target,0)==code and u32(target,4)==(expected_count or 0),"default-binding target count changed")
        if expected_unused then check(target:sub(9,28)==expected_unused,"default-binding staged record changed") end
        result.target=target
        if record then
        -- MBM removes a mapping identical to a shipped default (padding is
        -- immaterial). Refuse that combination; never modify its defaults map.
        local header=read(before.owner+DEFAULTS_OFFSET,20,"default-binding shipped map")
        local buckets=pointer(header)
        check(u32(header,8)==256,"default-binding shipped map capacity changed")
        local start=((code%256)*(u32(header,16)%256))%256
        local shipped
        for probe=0,255 do
            local at=buckets+((start+probe)%256)*328
            if u32(read(at,4,"default-binding shipped code"),0)==code then
                shipped=read(at,328,"default-binding shipped record");break
            end
        end
        check(shipped,"default-binding shipped action missing")
        check(u32(shipped,0)==code,"default-binding shipped code changed")
        local count=u32(shipped,4)
        check(count<=16,"default-binding shipped count invalid")
        result.inherited=false
        for index=0,count-1 do
            if equal_mapping(shipped:sub(9+index*20,28+index*20),record) then result.inherited=true end
        end
        -- The native parser's kind4 enum table must classify this engine key
        -- as ordinary keyboard input before aux=button_id+0x31 is usable.
        if u32(record,0)%16==3 then
            local aux=record:byte(5)+record:byte(6)*256
            check(u32(read(reader.game+0x263d1f0+aux*4,4,"keyboard semantic input kind"),0)==0,
                "default-binding keyboard enum is not an ordinary key")
        end
        else
            -- The native menu reads record[count] when no device mapping is
            -- found (17F920E), even with count zero. A reset must clear the
            -- entire owned payload, including unused records, and guard it
            -- against concurrent edits just as strictly as active mappings.
            if type(reset_target)=="string" then
                check(#reset_target==328 and target==reset_target,"binding reset records changed")
            else
                local expected=pack32(code)..pack32(expected_count or 0)..before.used_bytes:sub(9)
                check(target:sub(1,#expected)==expected,"binding reset records changed")
            end
        end
        return result
    end,"native-binding-default-proof")
end
function M.resolve(reader,code)
    if type(reader)~="table" or type(reader.transaction)~="function" then return nil,"verified native reader required" end
    return names(reader,code)
end
-- MBM's ready() can become true before its inherited-key sweep runs. Those
-- developer bindings are not player assignments and must not finalize the
-- addon's first-use markers. Observe their removal; never sweep them here.
function M.initial_state(reader,before)
    if type(before)~="table" then return nil,"initial binding snapshot unavailable" end
    local info,why=M.resolve(reader,before.code)
    if not info then return nil,why end
    return reader:transaction(function(read)
        check(reader.game==before.game,"initial binding module changed")
        check(read(reader.game+OWNER_RVA,8,"initial binding owner")==before.owner_bytes,"initial binding owner changed")
        check(read(before.owner+MAP_OFFSET,20,"initial binding live map")==before.table_header,"initial binding map changed")
        check(read(before.bucket,#before.used_bytes,"initial binding live records")==before.used_bytes,"initial binding records changed")
        local header=read(before.owner+DEFAULTS_OFFSET,20,"initial binding shipped map")
        local buckets=pointer(header)
        check(u32(header,8)==256,"initial binding shipped capacity changed")
        local start=((before.code%256)*(u32(header,16)%256))%256
        local shipped
        for probe=0,255 do
            local at=buckets+((start+probe)%256)*328
            if u32(read(at,4,"initial shipped action code"),0)==before.code then
                shipped=read(at,328,"initial shipped records");break
            end
        end
        check(shipped and u32(shipped,4)<=16,"initial shipped action unavailable")
        local inherited=0
        for _,entry in ipairs(before.mappings) do
            for index=0,u32(shipped,4)-1 do
                if equal_mapping(entry.raw,shipped:sub(9+index*20,28+index*20)) then
                    inherited=inherited+1;break
                end
            end
        end
        info.inherited_count=inherited
        return info
    end,"native-initial-binding-state")
end
local function native_io(expected_game)
    local ffi=require("ffi")
    check(ffi.os=="Windows" and ffi.abi("64bit"),"binding defaults require Windows x64")
    local kernel=ffi.load("kernel32")
    local function bind(name,declaration)
        local ok,value=pcall(function()return kernel[name]end)
        if not ok then ffi.cdef(declaration);value=kernel[name] end
        return value
    end
    local process=bind("GetCurrentProcess","void *GetCurrentProcess(void);")()
    local module=bind("GetModuleHandleA","void *GetModuleHandleA(const char *);")
    check(tonumber(ffi.cast("uintptr_t",module("game.dll")))==expected_game,
        "binding mutation requires this process's verified game.dll")
    local write=bind("WriteProcessMemory","int WriteProcessMemory(void *,void *,const void *,size_t,size_t *);")
    write=ffi.cast("int (*)(void *,void *,const void *,size_t,size_t *)",write)
    local written=ffi.new("size_t[1]")
    return function(address,bytes)
        written[0]=0
        return write(process,ffi.cast("void *",address),bytes,#bytes,written)~=0 and tonumber(written[0])==#bytes
    end
end
local function same(a,b)
    return a.section==b.section and a.action==b.action and a.target==b.target
end
function M.encode_buttons(code,rows,engine)
    local ok,bytes,entries=pcall(function()
        local normalized,why=Bindings.normalize(rows);check(normalized,why)
        engine=engine or rawget(_G,"stingray") or _G
        local ffi=require("ffi")
        local records,entries={},{}
        local aliases={lctrl="left ctrl",rctrl="right ctrl",lshift="left shift",rshift="right shift",
            lalt="left alt",ralt="right alt",pageup="page up",pagedown="page down",capslock="caps lock",
            numlock="num lock",scrolllock="scroll lock",printscreen="print screen",leftbracket="left bracket",rightbracket="right bracket"}
        local mouse={{"left","MouseButtonLeft"},{"right","MouseButtonRight"},{"middle","MouseButtonMiddle"},
            {"extra_1","MouseButton4"},{"extra_2","MouseButton5"}}
        for _,row in ipairs(normalized) do
            local key=row.key:lower():gsub("[%s_%-]","")
            local mouse_index=tonumber(key:match("^mouse([1-5])$"))
            local device=mouse_index and 4 or 3
            local api=engine[device==4 and "Mouse" or "Keyboard"]
            check(type(api)=="table" and type(api.button_id)=="function" and type(api.button_name)=="function","button-name API unavailable")
            local name=mouse_index and mouse[mouse_index][1] or aliases[key] or row.key:lower()
            local id=api.button_id(name)
            check(type(id)=="number" and id%1==0 and id>=(mouse_index and 0 or 1) and id<=255,"unsupported engine button name: "..name)
            local round=api.button_name(id)
            check(type(round)=="string" and round:lower()==name and api.button_id(round)==id,"engine button roundtrip failed")
            -- AE5680's verified hash branches map MouseButtonLeft/Right/Middle/4/5
            -- to semantic IDs 32..36. Keyboard fallback adds 49 to its engine ID.
            if mouse_index then check(id==mouse_index-1,"mouse engine button order changed") end
            local auxiliary=mouse_index and 31+mouse_index or id+49
            local flags=0xff40+device+row.trigger*65536+id*1048576
            local f=ffi.new("float[1]",row.threshold)
            records[#records+1]=pack32(flags)..string.char(auxiliary%256,math.floor(auxiliary/256)).."\0\0"..
                pack32(row.trigger)..pack32(0)..ffi.string(f,4)
            entries[#entries+1]={device_type=mouse_index and "Mouse" or "Keyboard",input=mouse_index and mouse[mouse_index][2] or round,
                trigger=Bindings.triggers[row.trigger+1],threshold=tonumber(f[0])}
        end
        return pack32(code)..pack32(#records)..table.concat(records)..string.rep("\0",(16-#records)*20),entries
    end)
    if ok then return bytes,entries end;return nil,bytes
end
function M.new(options)
    options=options or {}
    local self={clear_uncertain={},write=options.write,prepare_publication=options.prepare_publication,
        bindings=options.bindings or NativeModBindings}
    -- Change only verified owned native action buckets; no file transaction.
    local function change_many(reader,codes,before_write,replacements,expected_signature)
        self.mutation_started=false
        if type(codes)~="table" or #codes<1 or #codes>4 then return nil,"binding reset requires current owned action codes" end
        if type(before_write)~="function" then return nil,"binding reset preparation callback required" end
        if type(self.bindings)~="table" or type(self.bindings.inspect)~="function" then return nil,"native binding reader unavailable" end
        local seen,items={},{}
        local key_count=0
        for key in pairs(codes) do
            if type(key)~="number" or key%1~=0 or key<1 or key>#codes then return nil,"binding reset codes must be a dense array" end
            key_count=key_count+1
        end
        if key_count~=#codes then return nil,"binding reset codes must be a dense array" end
        for _,code in ipairs(codes) do
            if not NAMES[code] or seen[code] then return nil,"binding reset code invalid or duplicated" end
            if self.clear_uncertain[code] then
                self.mutation_started=true;return nil,"binding reset outcome uncertain; no mutation replay"
            end
            seen[code]=true
            local before,reason=self.bindings.inspect(reader,code)
            if not before then return nil,reason end
            if expected_signature and before.signature~=expected_signature then return nil,"binding changed before synchronization" end
            local current,failure=names(reader,code,before,true,nil,nil,before.count,true)
            if not current then return nil,failure end
            if replacements then
                local bytes=replacements[code].bytes
                for index=0,u32(bytes,4)-1 do
                    local entry=bytes:sub(9+index*20,28+index*20)
                    -- Do not publish a row that the dependency immediately
                    -- removes as an inherited developer default.
                    local proof,error_text=names(reader,code,before,true,entry,nil,before.count,true)
                    if not proof then return nil,error_text end
                    if proof.inherited then return nil,"menu filters this exact inherited binding" end
                end
            end
            items[#items+1]={before=before,proof=current,code=code,
                cleared=replacements and replacements[code].bytes or (pack32(code)..string.rep("\0",324))}
        end
        if not self.write then
            local ready,writer=pcall(native_io,reader.game)
            if not ready then return nil,tostring(writer) end
            self.write=writer
        end
        local changes={}
        for _,item in ipairs(items) do
            changes[#changes+1]={code=item.code,section=item.proof.section,action=item.proof.action,
                entries=replacements and replacements[item.code].entries}
        end
        if type(self.prepare_publication)~="function" then return nil,"native publication guard unavailable" end
        local ok,plan,why=pcall(self.prepare_publication,changes)
        if not ok then return nil,"native publication preparation failed: "..tostring(plan) end
        if type(plan)~="table" or type(plan.validate)~="function" then return nil,why or "native publication guard invalid" end
        local function guarded()
            local ok,valid,why=pcall(plan.validate)
            if ok and valid==true then return true end
            return nil,"native publication ownership/context changed: "..tostring(ok and why or valid)
        end
        local ready,prepared,preparation_reason=pcall(before_write)
        if not ready or prepared~=true then
            return nil,"binding reset preparation failed: "..tostring(ready and preparation_reason or prepared)
        end
        local valid,why=guarded();if not valid then return nil,why end
        for _,item in ipairs(items) do
            local final,reason=names(reader,item.code,item.before,true,nil,nil,item.before.count,item.proof.target)
            if not final or not same(item.proof,final) then return nil,"binding reset context changed: "..tostring(reason) end
            item.proof=final
        end
        local written={}
        -- Roll back only our exact cleared bucket. A partial/foreign payload
        -- is uncertain and must never be overwritten by an older snapshot.
        local function rollback(reason)
            local valid,why=guarded()
            if not valid then return nil,reason.."; rollback uncertain: "..tostring(why) end
            local restored=true
            for index=#written,1,-1 do
                local valid,why=guarded()
                if not valid then return nil,reason.."; rollback uncertain: "..tostring(why) end
                local item=written[index];local before=item.before
                local now=self.bindings.inspect(reader,item.code)
                local unchanged=now and now.owner==before.owner and now.bucket==before.bucket and
                    now.table_header==before.table_header
                local current=unchanged and names(reader,item.code,now,true,nil,nil,now.count,true)
                if current and current.target==item.proof.target then
                    -- A failed write may have left the complete old value.
                elseif current and current.target==item.cleared then
                    local valid=names(reader,item.code,before,true,nil,nil,u32(item.cleared,4),item.cleared)
                    local ok,result=false,false
                    if valid then ok,result=pcall(self.write,before.bucket+4,item.proof.target:sub(5)) end
                    local after=ok and result==true and names(reader,item.code,before,true,nil,nil,before.count,item.proof.target)
                    if not after then restored=false end
                else restored=false end
            end
            -- Even a confirmed rollback does not automatically replay a user
            -- request. Keep this instance blocked after uncertain write APIs.
            return nil,reason..(restored and "; original owned mappings restored" or "; rollback uncertain")
        end
        for _,item in ipairs(items) do self.clear_uncertain[item.code]=true end
        for _,item in ipairs(items) do
            if item.proof.target~=item.cleared then
                local valid,why=guarded();if not valid then return rollback(why) end
                local current,reason=names(reader,item.code,item.before,true,nil,nil,item.before.count,item.proof.target)
                if not current or not same(item.proof,current) then return rollback("binding reset context changed: "..tostring(reason)) end
                written[#written+1]=item -- include a potentially partial write
                self.mutation_started=true
                local ok,wrote=pcall(self.write,item.before.bucket+4,item.cleared:sub(5))
                if not ok or wrote~=true then return rollback("binding reset payload write uncertain") end
            end
        end
        for _,item in ipairs(items) do
            local after,reason=self.bindings.inspect(reader,item.code)
            if not after or after.owner~=item.before.owner or after.bucket~=item.before.bucket or after.count~=u32(item.cleared,4) then
                return rollback("binding reset readback uncertain: "..tostring(reason))
            end
            local current,failure=names(reader,item.code,item.before,true,nil,nil,u32(item.cleared,4),item.cleared)
            if not current then return rollback("binding reset persistence context changed: "..tostring(failure)) end
        end
        local valid,why=guarded();if not valid then return rollback(why) end
        for _,item in ipairs(items) do
            local final,reason=names(reader,item.code,item.before,true,nil,nil,u32(item.cleared,4),item.cleared)
            if not final then
                return rollback("bindings changed during publication: "..tostring(reason))
            end
        end
        local entries={}
        for _,item in ipairs(items) do
            self.clear_uncertain[item.code]=nil
            entries[#entries+1]={code=item.code,section=item.proof.section,action=item.proof.action,
                status=replacements and "synchronized" or (item.proof.target==item.cleared and "unset" or "cleared"),
                persisted=false,native_only=true,payload_cleared=u32(item.cleared,4)==0}
        end
        return {status="cleared",changed=#written,entries=entries,persisted=false,native_only=true,payload_cleared=true}
    end
    function self:clear_many(reader,codes,before_write)
        return change_many(reader,codes,before_write)
    end
    function self:replace(reader,code,rows,before_write,expected_signature)
        local not_written={native_attempted=false}
        local bytes,entries=M.encode_buttons(code,rows,options.engine)
        if not bytes then return nil,entries,not_written end
        local validated,why=reader:transaction(function(read)
            for index,row in ipairs(rows) do
                local entry=bytes:sub(9+(index-1)*20,28+(index-1)*20)
                local aux=entry:byte(5)+entry:byte(6)*256
                if u32(entry,0)%16==3 then
                    check(u32(read(reader.game+0x263d1f0+aux*4,4,"binding keyboard enum"),0)==0,
                        "binding enum is not an ordinary key")
                end
            end
            return {valid=true}
        end,"binding-encoder-kind")
        if not validated then return nil,why,not_written end
        local result,why=change_many(reader,{code},before_write,{[code]={bytes=bytes,entries=entries}},expected_signature)
        if result then result.status="synchronized";result.payload_cleared=#rows==0 end
        if not result and not self.mutation_started then self.clear_uncertain[code]=nil end
        return result,why,{native_attempted=self.mutation_started==true}
    end
    function self:clear(reader,code,before_write)
        local result,reason=self:clear_many(reader,{code},before_write)
        if not result then return nil,reason end
        return result.entries[1]
    end
    return self
end
M.anchors,M.names=ANCHORS,NAMES
M.layout={defaults_offset=DEFAULTS_OFFSET,keyboard_enum_table=0x263d1f0}
return M

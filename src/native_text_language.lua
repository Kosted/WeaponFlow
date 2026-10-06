-- Read-only Text Language setting. Layout is published in installed MBM2.1
-- (bingus_text GAME); the existing NativeReader verifies the game build and
-- rereads every observed byte. No localization hooks, calls or registry writes.
local M={}
local SETTINGS,TABLE,INDEX,COUNT=0x3326340,0x37c5650,705500+212,15
local ALIASES={us="en",["en-us"]="en",uk="en-GB",gb="en-GB",jp="ja",kr="ko",br="pt-BR",
    mx="es-419",cn="zh-Hans",zh="zh-Hans",zhs="zh-Hans",tw="zh-Hant",zht="zh-Hant",
    ["es-es"]="es",["es-mx"]="es-419",["zh-cn"]="zh-Hans",["zh-tw"]="zh-Hant",
    bp="pt-BR",ms="es-419",tc="zh-Hant",sc="zh-Hans",
    cz="cs",gr="el",ua="uk"}
local function u32(bytes)
    local a,b,c,d=bytes:byte(1,4);return a+b*256+c*65536+d*16777216
end
local function pointer(bytes)
    local high=u32(bytes:sub(5))
    local value=u32(bytes)+high*4294967296
    if high>=0x8000 or value<0x10000 then error("language pointer unavailable",0) end
    return value
end
function M.read(reader)
    if type(reader)~="table" or type(reader.transaction)~="function" then return nil,"native language reader unavailable" end
    return reader:transaction(function(read)
        local settings=pointer(read(reader.game+SETTINGS,8,"text language settings"))
        local index=u32(read(settings+INDEX,4,"text language index"))
        if index>=COUNT then error("text language index outside table",0) end
        local record=pointer(read(reader.game+TABLE+8*index,8,"text language record"))
        local text=pointer(read(record+8,8,"text language code pointer"))
        local code=read(text,16,"text language code"):match("^(%a[%a%-]*)%z")
        if not code or #code>12 then error("text language code invalid",0) end
        return {tag=ALIASES[code:lower()] or code,code=code}
    end,"native-text-language")
end
return M

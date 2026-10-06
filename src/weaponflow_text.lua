-- Presentation only. Uses MBM's shared language/translation-pack registry;
-- never writes that registry, settings, bindings or weapon data.
local M={generation=0}
local english=EnglishText.strings
local override="auto"
local font
local language_provider,observed
local cache,stamp={},nil
local bundled={}
local acceptable
local catalog_revision,inventory_stamp=0,nil
local inventory_languages,inventory_known

-- Strict UTF-8, including overlong/surrogate/out-of-range rejection. Offsets
-- remain byte offsets so existing key highlight ranges stay unambiguous.
function M.characters(text)
    local at=1
    return function()
        if at>#text then return nil end
        local start=at
        local a=text:byte(at)
        local size=a<128 and 1 or a>=194 and a<=223 and 2 or
            a>=224 and a<=239 and 3 or a>=240 and a<=244 and 4
        if not size or at+size-1>#text then error("invalid UTF-8",0) end
        for n=1,size-1 do
            local b=text:byte(at+n)
            if b<128 or b>191 then error("invalid UTF-8",0) end
        end
        local b=text:byte(at+1)
        if size==3 and (a==224 and b<160 or a==237 and b>=160) or
           size==4 and (a==240 and b<144 or a==244 and b>=144) then error("invalid UTF-8",0) end
        at=at+size
        return start,text:sub(start,at-1)
    end
end
function M.valid(text,limit)
    if type(text)~="string" or #text>(limit or 4096) or text:find("[%z\1-\31\127]") then return false end
    local ok=pcall(function()for _ in M.characters(text) do end end)
    return ok
end
function M.upper(text)
    -- ASCII capitals preserve the established UI. Other scripts keep their
    -- exact Unicode characters; catalogs can provide either case.
    return (text:gsub("[a-z]",string.upper))
end
function M.clean(text,limit)
    if not M.valid(text,limit) then return nil end
    text=M.upper(text):gsub("%s+"," "):match("^%s*(.-)%s*$")
    return text~="" and text or nil
end
local function tag(value)
    if type(value)~="string" or #value>32 or not value:match("^[%a][%w%-]*$") then return nil end
    return value:lower()
end
function M.set_language(value)
    value=tag(value or "auto")
    if not value then return nil,"invalid language tag" end
    override=value;stamp=nil
    return true
end
function M.configure(options)
    options=options or {}
    if options.font then font=options.font;stamp=nil end
    if options.language_provider then language_provider=options.language_provider end
    if options.language then return M.set_language(options.language) end
    return true
end
function M.read_language()
    if not language_provider then return end
    local ok,value=pcall(language_provider)
    observed=ok and type(value)=="table" and tag(value.tag) or nil
end
function M.available_languages()
    local registry=rawget(_G,"BingusTranslations")
    local identity=tostring(registry)..":"..tostring(type(registry)=="table" and registry.serial or 0)..":"..catalog_revision
    if inventory_stamp==identity then return inventory_languages,inventory_known end
    local known={en=true}
    for language in pairs(bundled) do known[language]=true end
    for _,pack in ipairs(type(registry)=="table" and registry.packs or {}) do
        local language=type(pack)=="table" and tag(pack.language)
        local strings=type(pack)=="table" and type(pack.mods)=="table" and pack.mods.weaponflow
        if language and type(strings)=="table" then
            for key,value in pairs(strings) do
                if english[key] and acceptable(value,english[key]) then known[language]=true;break end
            end
        end
    end
    local rest={}
    for language in pairs(known) do if language~="en" and language~="auto" then rest[#rest+1]=language end end
    table.sort(rest)
    local languages={"auto","en"}
    for _,language in ipairs(rest) do languages[#languages+1]=language end
    inventory_stamp,inventory_languages,inventory_known=identity,languages,known
    return languages,known
end
function M.selected_language() return override end
function M.next_language()
    local languages=M.available_languages()
    for index,language in ipairs(languages) do
        if language==override then return languages[index%#languages+1] end
    end
    return "auto"
end
function M.language()
    local registry=rawget(_G,"BingusTranslations")
    local automatic=language_provider and observed or (not language_provider and type(registry)=="table" and tag(registry.game_language))
    local selected=override~="auto" and override or automatic or "en"
    local _,known=M.available_languages()
    if known[selected] then return selected end
    local base=selected:match("^([^-]+)")
    return base and known[base] and base or "en"
end
local function placeholders(text)
    local names={}
    for name in text:gmatch("{([%a_][%w_]*)}") do names[#names+1]=name end
    table.sort(names);return table.concat(names,",")
end
acceptable=function(text,source)
    return M.valid(text,1024) and placeholders(text)==placeholders(source)
end
function M.register(language,strings)
    language=tag(language)
    if not language or language=="en" or type(strings)~="table" then return nil,"invalid locale catalog" end
    local copy={}
    for key,text in pairs(strings) do
        local native=type(key)=="string" and key:match("^game%.%x%x%x%x%x%x%x%x$")
        if not (english[key] and acceptable(text,english[key]) or
                native and M.valid(text,1024) and placeholders(text)=="") then
            return nil,"invalid translation: "..tostring(key)
        end
        copy[key]=text
    end
    bundled[language]=copy;stamp=nil;catalog_revision=catalog_revision+1
    return true
end
local function refresh()
    local registry=rawget(_G,"BingusTranslations")
    local language=M.language()
    local serial=type(registry)=="table" and registry.serial or 0
    local current=language..":"..tostring(serial)..":"..tostring(registry)
    if current~=stamp then cache={};stamp=current;M.generation=M.generation+1 end
    return language,registry
end
local function template(key,source)
    local language,registry=refresh()
    if cache[key] then return cache[key] end
    source=source or english[key]
    if not source then error("unknown WeaponFlow text: "..tostring(key),0) end
    local text=source
    local base=language:match("^([^-]+)") or language
    for _,wanted in ipairs(base==language and {language} or {base,language}) do
        local own=bundled[wanted]
        local candidate=own and own[key]
        if candidate and acceptable(candidate,source) then text=candidate end
        for _,pack in ipairs(type(registry)=="table" and registry.packs or {}) do
            if type(pack)=="table" and tag(pack.language)==wanted and type(pack.mods)=="table" then
                local translations=pack.mods.weaponflow
                candidate=type(translations)=="table" and translations[key]
                if candidate and acceptable(candidate,source) then text=candidate end
            end
        end
    end
    cache[key]=text
    return text
end
local function format(text,values)
    return (text:gsub("{([%a_][%w_]*)}",function(name)
        local value=values and values[name]
        return value~=nil and tostring(value) or ("{"..name.."}")
    end))
end
function M.supports(text,selected_font)
    selected_font=selected_font or font
    if not selected_font then return true end
    if not M.valid(text) then return false end
    for _,ch in M.characters(M.upper(text)) do if not selected_font.glyphs[ch] then return false end end
    return true
end
function M.text(key,values) return format(template(key),values) end
function M.has(key) return english[key]~=nil end
function M.hud(key,values)
    local text=M.upper(M.text(key,values))
    -- A translation without matching font coverage keeps the English line.
    -- This has no effect on gameplay or command availability.
    if not M.supports(text) then text=M.upper(format(english[key],values)) end
    return text
end
function M.native(key,source)
    if not source then return nil end
    local text=M.upper(template(string.format("game.%08X",key),source))
    return M.supports(text) and text or source
end
function M.parts(key,values,accents)
    local selected=template(key)
    if not M.supports(M.upper(format(selected,values))) then selected=english[key] end
    local parts,at={},1
    while true do
        local first,last,name=selected:find("{([%a_][%w_]*)}",at)
        local plain=selected:sub(at,first and first-1 or #selected)
        if plain~="" then parts[#parts+1]={M.upper(plain)} end
        if not first then break end
        parts[#parts+1]={tostring(values[name] or ""),accents and accents[name]==true,name=name}
        at=last+1
    end
    return parts
end
return M

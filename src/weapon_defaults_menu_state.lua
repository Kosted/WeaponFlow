-- Persistent one-time native default markers for the required menu.
-- No hotkey assignments, game input writes or preset-file access.
local M={}
local Store=DefaultsStore
local MAX_BYTES=4096
local NAMES={"save","cycle","hud","reset"}
local KNOWN={save=true,cycle=true,hud=true,reset=true}
-- Accept retired markers on read; omit them on the next own-file mutation.
local RETIRED={clear=true,export=true,import=true,locale=true}
local State={}
State.__index=State

local function empty()
    return {save=false,cycle=false,hud=false,reset=false}
end

local function parse(raw,profile)
    if type(raw)~="string" or #raw>MAX_BYTES or raw:find("%z") then
        return nil,"invalid menu marker file size/content"
    end
    local fields,section={},false
    raw=raw:gsub("^\239\187\191","")
    for line in (raw.."\n"):gmatch("([^\n]*)\n") do
        line=line:match("^%s*(.-)%s*$")
        if line~="" and line:sub(1,1)~=";" and line:sub(1,1)~="#" then
            if line=="[menu]" and not section then section=true
            else
                local key,value=line:match("^([a-z_]+)%s*=%s*(.-)%s*$")
                if not section or not key or fields[key]~=nil or
                   (not KNOWN[key] and not RETIRED[key] and key~="schema" and key~="profile_id" and key~="reset_hotkey" and key~="fresh_start" and key~="bind" and key~="language") then
                    return nil,"invalid or duplicate menu marker field/section"
                end
                fields[key]=value
            end
        end
    end
    if fields.schema~="1" then return nil,"unsupported menu marker schema" end
    if fields.profile_id~=profile then return nil,"menu marker profile ID mismatch" end
    local result={}
    if fields.language~=nil then
        if #fields.language>32 or not fields.language:match("^[%a][%w%-]*$") then return nil,"invalid menu language" end
        result._language=fields.language:lower()
    end
    for _,name in ipairs(NAMES) do
        if fields[name]~="true" and fields[name]~="false" and fields[name]~="pending" then
            return nil,"invalid or missing menu marker: "..name
        end
        result[name]=fields[name]=="pending" and "pending" or fields[name]=="true"
    end
    return result
end

local function serialize(profile,values)
    local lines={"[menu]","schema=1","profile_id="..profile}
    for _,name in ipairs(NAMES) do lines[#lines+1]=name.."="..tostring(values[name]) end
    if values._language then lines[#lines+1]="language="..values._language end
    lines[#lines+1]=""
    return table.concat(lines,"\r\n")
end

function State:_read()
    local safe,raw,reason=pcall(self.io.read,self.path,MAX_BYTES)
    if not safe then return nil,"menu marker read failed: "..tostring(raw) end
    if raw==nil then
        if reason=="missing" then return empty(),nil end
        return nil,"menu marker read failed: "..tostring(reason or "unknown I/O failure")
    end
    local values,why=parse(raw,self.profile_id)
    if not values then return nil,why end
    return values,raw
end

function State:contains(name)
    if type(name)~="string" or not KNOWN[name] then return nil,"unknown menu marker name" end
    local values,raw_or_reason=self:_read()
    if not values then return nil,raw_or_reason end
    -- A process ending during publication must never replay an uncertain
    -- native mutation at the next startup.
    return values[name]~=false
end
function State:language()
    local values,why=self:_read()
    if not values then return nil,why end
    return values._language or "auto"
end
function State:set_language(language,before_write)
    if type(language)~="string" or #language>32 or not language:match("^[%a][%w%-]*$") then
        return nil,"invalid menu language"
    end
    local values,raw=self:_read()
    if not values then return nil,raw end
    language=language:lower()
    if (values._language or "auto")==language then return true,false end
    if type(before_write)~="function" then return nil,"language publication guard required" end
    local safe,allowed,why=pcall(before_write)
    if not safe or allowed~=true then return nil,safe and why or allowed end
    values._language=language
    local ok,written,reason=pcall(self.io.atomic_write,self.path,serialize(self.profile_id,values),raw)
    if not ok or written~=true then return nil,"menu language write failed: "..tostring(ok and reason or written) end
    return true,true
end

function State:ensure_file()
    local values,raw_or_reason=self:_read()
    if not values then return nil,raw_or_reason end
    if raw_or_reason~=nil then return true,false end
    local safe,written,reason=pcall(self.io.atomic_write,self.path,serialize(self.profile_id,values),nil)
    if not safe then return nil,"menu marker write failed: "..tostring(written) end
    if written~=true then return nil,"menu marker write failed: "..tostring(reason or "unknown I/O failure") end
    return true,true
end

function State:mark(name)
    if type(name)~="string" or not KNOWN[name] then return nil,"unknown menu marker name" end
    local values,raw_or_reason=self:_read()
    if not values then return nil,raw_or_reason end
    if values[name]==true then return true,false end
    values[name]=true
    local candidate=serialize(self.profile_id,values)
    local safe,written,reason=pcall(self.io.atomic_write,self.path,candidate,raw_or_reason)
    if not safe then return nil,"menu marker write failed: "..tostring(written) end
    if written~=true then return nil,"menu marker write failed: "..tostring(reason or "unknown I/O failure") end
    return true,true
end

local function pending(self,name,cancel)
    if not KNOWN[name] then return nil,"unknown menu marker name" end
    local values,raw=self:_read()
    if not values then return nil,raw end
    if cancel then
        if values[name]~="pending" then return nil,"default reservation changed" end
        values[name]=false
    else
        if values[name]~=false then return nil,"default already handled or reserved" end
        values[name]="pending"
    end
    local ok,written,why=pcall(self.io.atomic_write,self.path,serialize(self.profile_id,values),raw)
    if not ok or written~=true then return nil,"menu marker write failed: "..tostring(ok and why or written) end
    return true
end

-- Reserve only inside the fully guarded publisher. Cancel is permitted only
-- when it positively reports that no native write was attempted.
function State:begin(name) return pending(self,name,false) end
function State:cancel(name) return pending(self,name,true) end

function M.open(profile_id,options)
    if type(Store)~="table" or type(Store.context)~="function" then
        return nil,"menu marker settings context unavailable"
    end
    if options~=nil and type(options)~="table" then return nil,"invalid menu marker options" end
    local safe,context,reason=pcall(Store.context,profile_id,options)
    if not safe then return nil,"menu marker context failed: "..tostring(context) end
    if not context then return nil,reason end
    if type(context.path)~="string" or context.path=="" or context.path:find("%z") or
       context.profile_id~=profile_id or type(context.io)~="table" or
       type(context.io.read)~="function" or type(context.io.atomic_write)~="function" then
        return nil,"invalid menu marker settings context"
    end
    local directory=context.path:match("^(.*[/\\])") or ""
    local self=setmetatable({profile_id=profile_id,path=directory..profile_id.."-Menu.ini",io=context.io},State)
    local values,why=self:_read()
    if not values then return nil,why end
    return self
end

return M

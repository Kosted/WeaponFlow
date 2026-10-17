-- Persistent one-time native default markers for the required menu.
-- No hotkey assignments, game input writes or preset-file access.
local M={}
local Store=DefaultsStore
local MAX_BYTES=4096
local NAMES={"save","cycle","hud","reset"}
local KNOWN={save=true,cycle=true,hud=true,reset=true}
local INTRO={presets=true,hud=true,swap=true}
local INTRO_FIELDS={"intro_presets","intro_hud","intro_swap","first_run"}
-- Accept retired markers on read; omit them on the next own-file mutation.
local RETIRED={clear=true,export=true,import=true,locale=true,language=true}
local State={}
State.__index=State

local function empty()
    return {save=false,cycle=false,hud=false,reset=false,
        intro_presets=false,intro_hud=false,intro_swap=false,first_run=true}
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
                   (not KNOWN[key] and not RETIRED[key] and not (key:sub(1,6)=="intro_" and INTRO[key:sub(7)]) and key~="first_run" and key~="schema" and key~="profile_id" and key~="reset_hotkey" and key~="fresh_start" and key~="bind") then
                    return nil,"invalid or duplicate menu marker field/section"
                end
                fields[key]=value
            end
        end
    end
    if fields.schema~="1" then return nil,"unsupported menu marker schema" end
    if fields.profile_id~=profile then return nil,"menu marker profile ID mismatch" end
    local result={}
    for _,name in ipairs(NAMES) do
        if fields[name]~="true" and fields[name]~="false" and fields[name]~="pending" then
            return nil,"invalid or missing menu marker: "..name
        end
        result[name]=fields[name]=="pending" and "pending" or fields[name]=="true"
    end
    for name in pairs(INTRO) do
        local field="intro_"..name
        if fields[field]~=nil and fields[field]~="true" and fields[field]~="false" then
            return nil,"invalid onboarding field: "..field
        end
        result[field]=fields[field]=="true"
    end
    result.first_run=not (result.intro_presets and result.intro_hud and result.intro_swap)
    if fields.first_run~=nil and fields.first_run~=tostring(result.first_run) then
        return nil,"invalid onboarding completion state"
    end
    return result
end

local function serialize(profile,values)
    local lines={"[menu]","schema=1","profile_id="..profile}
    for _,name in ipairs(NAMES) do lines[#lines+1]=name.."="..tostring(values[name]) end
    for _,name in ipairs(INTRO_FIELDS) do lines[#lines+1]=name.."="..tostring(values[name]) end
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

function State:onboarding()
    local values,why=self:_read()
    if not values then return nil,why end
    return {first_run=values.first_run,presets=values.intro_presets,hud=values.intro_hud,swap=values.intro_swap}
end

function State:complete_step(name)
    if not INTRO[name] then return nil,"unknown onboarding step" end
    local values,raw=self:_read()
    if not values then return nil,raw end
    if not values["intro_"..name] then
        values["intro_"..name]=true
        values.first_run=not (values.intro_presets and values.intro_hud and values.intro_swap)
        local ok,written,why=pcall(self.io.atomic_write,self.path,serialize(self.profile_id,values),raw)
        if not ok or written~=true then return nil,"onboarding write failed: "..tostring(ok and why or written) end
    end
    return {first_run=values.first_run,presets=values.intro_presets,hud=values.intro_hud,swap=values.intro_swap}
end

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

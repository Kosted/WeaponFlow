-- Persistent player choices. No game calls or mode changes occur here.
-- Values in left/right/up/down are native, ONE-based slot numbers; None is
-- deliberately distinct from slot zero. Kind/value metadata preserves the
-- selected meaning when a later instance has different modules or ordering.
local M = {version="0.3.1"}
local SIDES = {"left", "right", "up", "down"}
local SIDE = {left=true, right=true, up=true, down=true}
local MAX_BYTES = 1024 * 1024
local FLASHLIGHT_NAMES = {[0]="Auto",[1]="On",[2]="Off"}
local FLASHLIGHT_VALUES = {Auto=0,On=1,Off=2}
local Store = {}
Store.__index = Store

local function trim(s) return s:match("^%s*(.-)%s*$") end
local function clone(v)
    if type(v) ~= "table" then return v end
    local r = {}; for k,x in pairs(v) do r[k] = clone(x) end; return r
end
local function resource_id(s)
    if type(s) ~= "string" or #s ~= 16 or not s:match("^%x+$") then
        return nil, "weapon resource ID must be exactly 16 hexadecimal characters"
    end
    return s:upper()
end
local function valid_profile(s)
    return type(s)=="string" and #s==17 and s:match("^[1-9]%d+$")~=nil
end
local function preset_number(value)
    if value==nil then return 1 end
    if type(value)~="number" or value~=math.floor(value) or value<1 or value>3 then
        return nil,"preset must be an integer from 1 to 3"
    end
    return value
end
local function empty_weapon()
    return {presets={{targets={}},{targets={}},{targets={}}}}
end
local function number(s)
    if type(s)~="string" or not s:match("^[%+%-]?[%d%.]+[eE]?[%+%-]?%d*$") then return nil end
    local n=tonumber(s)
    if not n or n~=n or n==math.huge or n==-math.huge or math.abs(n)>1e9 then return nil end
    return n
end
local function record(r)
    if type(r)~="table" then return nil,"direction record must be a table" end
    for k in pairs(r) do
        if k~="slot" and k~="kind" and k~="value" then return nil,"unknown direction metadata: "..tostring(k) end
    end
    if type(r.slot)~="number" or r.slot~=math.floor(r.slot) or r.slot<1 or r.slot>65535 then
        return nil,"slot must be a one-based integer"
    end
    if type(r.kind)~="string" or #r.kind>48 or not r.kind:match("^[a-z][a-z0-9_]*$") then
        return nil,"invalid direction kind"
    end
    if type(r.value)~="number" or r.value~=r.value or math.abs(r.value)>1e9 then
        return nil,"direction value must be finite and within bounds"
    end
    return {slot=r.slot,kind=r.kind,value=r.value}
end

local function same_record(a,b)
    return a and b and a.slot==b.slot and a.kind==b.kind and a.value==b.value
end
local function save_plan(plan,updates)
    if plan==nil then return nil end
    if type(plan)~="table" or plan.qualified~=true or not SIDE[plan.side] or
       (plan.count~=2 and plan.count~=3) or type(plan.choices)~="table" or
       (plan.available_count~=nil and plan.available_count~=1) then
        return nil,"invalid single-setting save plan"
    end
    for side in pairs(updates) do
        if side~=plan.side then return nil,"single-setting plan has multiple save directions" end
    end
    local selected,err=record(plan.selected)
    if not selected or selected.kind=="flashlight" or not same_record(selected,updates[plan.side]) then
        return nil,"single-setting selected record does not match save: "..tostring(err or "record mismatch")
    end
    for index in pairs(plan.choices) do
        if type(index)~="number" or index~=math.floor(index) or index<1 or index>plan.count then
            return nil,"single-setting choices must be a dense array"
        end
    end
    local choices,seen,found={},{},false
    for index=1,plan.count do
        local choice,reason=record(plan.choices[index])
        if not choice or choice.slot~=index or choice.kind~=selected.kind or seen[choice.value] then
            return nil,"single-setting choices require distinct values in native slot order: "..tostring(reason or "choice mismatch")
        end
        choices[index]=choice;seen[choice.value]=true
        if same_record(choice,selected) then found=true end
    end
    if not found then return nil,"single-setting selected record is not offered" end
    return {side=plan.side,count=plan.count,choices=choices,selected=selected}
end

local function parse(data, profile_id, reject_light)
    if type(data)~="string" or #data>MAX_BYTES then return nil,"settings file exceeds size limit" end
    if data:sub(1,3)=="\239\187\191" then data=data:sub(4) end
    if data:find("[%z\1-\8\11\12\14-\31]") then return nil,"settings file contains control bytes" end
    local sections, current = {}, nil
    local line_no=0
    for raw in (data.."\n"):gmatch("([^\n]*)\n") do
        line_no=line_no+1
        if #raw>2048 then return nil,"settings line too long at "..line_no end
        local line=trim(raw)
        if line~="" and not line:match("^[;#]") then
            local section=line:match("^%[([^%]]+)%]$")
            if section then
                if section~="settings" then
                    local id,preset=section:match("^weapon:(%x+):preset:([1-3])$")
                    if not id then id=section:match("^weapon:(%x+)$") end
                    id=id and resource_id(id)
                    if not id then return nil,"unknown settings section at line "..line_no end
                    section="weapon:"..id..(preset and ":preset:"..preset or "")
                end
                if sections[section] then return nil,"duplicate section: "..section end
                current={};sections[section]=current
            else
                local k,v=line:match("^([a-z_]+)%s*=%s*(.-)$")
                if not current or not k then return nil,"invalid settings syntax at line "..line_no end
                if current[k]~=nil then return nil,"duplicate key at line "..line_no end
                current[k]=trim(v)
            end
        end
    end
    local settings=sections.settings
    if not settings then return nil,"missing [settings] section" end
    local schema=tonumber(settings.schema)
    if settings.schema~="1" and settings.schema~="2" and settings.schema~="3" then return nil,"unsupported settings schema" end
    for k in pairs(settings) do
        if k~="schema" and k~="profile_id" and k~="hotkey" and k~="double_tap_ms" and
           not (schema>=2 and (k=="bind_hotkey" or k=="cycle_hotkey")) and
           not (schema==3 and k=="flashlight_mode") then
            return nil,"unknown settings key: "..k
        end
    end
    if settings.profile_id~=profile_id then return nil,"settings profile ID mismatch" end
    local flashlight_mode="None"
    if schema==3 then
        flashlight_mode=settings.flashlight_mode
        if flashlight_mode~="None" and FLASHLIGHT_VALUES[flashlight_mode]==nil then
            return nil,"flashlight_mode must be None, Auto, On or Off"
        end
    end
    local result={schema=schema,profile_id=profile_id,flashlight_mode=flashlight_mode,weapons={}}
    local seen={}
    for section,fields in pairs(sections) do
        if section~="settings" then
            local id,preset=section:match("^weapon:(%x+):preset:([1-3])$")
            if schema==1 then
                if id then return nil,"preset section requires schema 2 or 3: "..section end
                id=section:sub(8);preset=1
            elseif not id then return nil,"schema 2 or 3 requires numbered preset sections: "..section end
            preset=tonumber(preset)
            for k in pairs(fields) do
                local s=k:match("^(.-)_kind$") or k:match("^(.-)_value$")
                if not SIDE[k] and not (s and SIDE[s]) then return nil,"unknown weapon key: "..k end
            end
            local entry={targets={}}
            for _,side in ipairs(SIDES) do
                local value=fields[side]
                if value==nil then return nil,"missing "..side.." in "..section end
                if value~="None" then
                    local r,err=record({slot=number(value),kind=fields[side.."_kind"],value=number(fields[side.."_value"])})
                    if not r then return nil,section.." "..side..": "..err end
                    if reject_light and r.kind=="flashlight" then return nil,"flashlight is not a preset" end
                    -- Flashlight is profile-wide in schema 3. Never expose old
                    -- per-weapon light targets, or infer a global preference
                    -- from whichever legacy weapon happens to be parsed first.
                    if r.kind~="flashlight" then entry.targets[side]=r end
                end
                -- When edited to None, stale known metadata is harmless and
                -- ignored; the next save removes it. None always disables it.
            end
            if not result.weapons[id] then result.weapons[id]=empty_weapon();seen[id]={} end
            result.weapons[id].presets[preset]=entry
            seen[id][preset]=true
        end
    end
    if schema>=2 then
        for id,presets in pairs(seen) do
            for preset=1,3 do
                if not presets[preset] then return nil,"missing preset "..preset.." for weapon:"..id end
            end
        end
    end
    return result
end

local function serialize(config)
    local lines={
        "; Weapon Defaults presets. Preset 1 is applied on real weapon equip.",
        "; None means leave this direction unchanged. Empty presets are skipped when cycling.",
        "; Slot numbers are one-based native slots, with kind/value for module-safe matching.",
        "; Changes are loaded on game start. Saving merges only available, readable directions.",
        "[settings]", "schema=3", "profile_id="..config.profile_id,
        "flashlight_mode="..config.flashlight_mode, "",
    }
    local ids={};for id in pairs(config.weapons) do ids[#ids+1]=id end;table.sort(ids)
    for _,id in ipairs(ids) do
        for preset=1,3 do
            lines[#lines+1]="[weapon:"..id..":preset:"..preset.."]"
            local targets=config.weapons[id].presets[preset].targets
            for _,side in ipairs(SIDES) do
                local r=targets[side]
                if r and r.kind=="flashlight" then r=nil end
                lines[#lines+1]=side.."="..(r and tostring(r.slot) or "None")
                if r then
                    lines[#lines+1]=side.."_kind="..r.kind
                    lines[#lines+1]=side.."_value="..string.format("%.17g",r.value)
                end
            end
            lines[#lines+1]=""
        end
    end
    local data=table.concat(lines,"\r\n")
    if #data>MAX_BYTES then return nil,"settings file exceeds size limit" end
    return data
end

-- Portable account presets only: no Steam ID, controls, HUD or flashlight.
-- This bounded data parser is also the entry point for a future bundled seed.
local SHARE_HEADER="WEAPONFLOW-PRESETS/1"
local SHARE_PROFILE="76561198000000000"
function M.decode_presets(data)
    if type(data)~="string" or #data>MAX_BYTES then return nil,"invalid preset transfer size" end
    data=data:gsub("^\239\187\191","")
    local header,body=data:match("^([^\r\n]+)\r?\n(.*)$")
    if header~=SHARE_HEADER then return nil,"unknown preset transfer format/version" end
    -- The normal profile parser validates duplicate sections, all three
    -- presets, resource hashes, slots, semantic values and unknown fields.
    local wrapped="[settings]\nschema=3\nprofile_id="..SHARE_PROFILE.."\nflashlight_mode=None\n"..body
    local config,why=parse(wrapped,SHARE_PROFILE,true)
    if not config then return nil,why end
    return config.weapons
end
function M.encode_presets(weapons)
    local safe,data,why=pcall(serialize,{schema=3,profile_id=SHARE_PROFILE,flashlight_mode="None",weapons=weapons})
    if not safe or not data then return nil,safe and why or data end
    local first=data:find("[weapon:",1,true)
    local share=SHARE_HEADER.."\r\n"..(first and data:sub(first) or "")
    local checked,why=M.decode_presets(share)
    if not checked then return nil,why end
    return share
end
function M.seed_settings(profile,data)
    if not valid_profile(profile) then return nil,"invalid seed profile" end
    local weapons,why=M.decode_presets(data);if not weapons then return nil,why end
    return serialize({schema=3,profile_id=profile,flashlight_mode="None",weapons=weapons})
end

-- The default adapter uses wide-character Windows file APIs throughout. The
-- injected adapter used by tests has read(path,max), atomic_write(path,data,
-- expected_previous, optional_migration), and optional default_directory().
-- Migration is {profile_id=SteamID64,schema=1|2}; a legacy profile string still
-- means schema 1. Preserve the exact original in .schema1.bak/.schema2.bak
-- before replacement; valid existing migration backups are never overwritten.
-- Missing reads return
-- nil,"missing"; all other failures must return a distinct reason.
local function windows_io()
    local ok,ffi=pcall(require,"ffi")
    if not ok or ffi.os~="Windows" then return nil,"Windows file API unavailable" end
    local declarations={
        "unsigned long __stdcall GetEnvironmentVariableW(const wchar_t*, wchar_t*, unsigned long);",
        "int __stdcall MultiByteToWideChar(unsigned int,unsigned long,const char*,int,wchar_t*,int);",
        "int __stdcall WideCharToMultiByte(unsigned int,unsigned long,const wchar_t*,int,char*,int,const char*,int*);",
        "void* __stdcall CreateFileW(const wchar_t*,unsigned long,unsigned long,void*,unsigned long,unsigned long,void*);",
        "int __stdcall ReadFile(void*,void*,unsigned long,unsigned long*,void*);",
        "int __stdcall WriteFile(void*,const void*,unsigned long,unsigned long*,void*);",
        "int __stdcall GetFileSizeEx(void*,int64_t*);",
        "int __stdcall FlushFileBuffers(void*);",
        "int __stdcall CloseHandle(void*);",
        "int __stdcall CreateDirectoryW(const wchar_t*,void*);",
        "int __stdcall MoveFileExW(const wchar_t*,const wchar_t*,unsigned long);",
        "int __stdcall DeleteFileW(const wchar_t*);",
        "unsigned long __stdcall GetLastError(void);",
        "unsigned long __stdcall GetCurrentProcessId(void);",
    }
    local C={}
    for _,decl in ipairs(declarations) do
        -- Other addons can have already declared the same Win32 ABI with
        -- distinct LuaJIT pointer types (DWORD=uint32_t vs unsigned long,
        -- wchar_t vs unsigned short). Cast the symbol to THIS exact prototype
        -- so our own buffers never depend on whichever declaration ran first.
        pcall(ffi.cdef,decl)
        local result,name,args=decl:match("^(.-)__stdcall%s+([%w_]+)(%b());$")
        if not result then return nil,"invalid local Windows API declaration" end
        local bound,fn=pcall(function()
            return ffi.cast(result.."(__stdcall *)"..args,ffi.C[name])
        end)
        if not bound then return nil,"Windows file API unavailable: "..name end
        C[name]=fn
    end
    local invalid=ffi.cast("void*",-1)
    local serial=0
    local function wide(s)
        if type(s)~="string" or s:find("%z") then return nil,"invalid filename" end
        local n=C.MultiByteToWideChar(65001,8,s,#s,nil,0)
        if n<=0 then return nil,"filename is not valid UTF-8" end
        local b=ffi.new("wchar_t[?]",n+1)
        if C.MultiByteToWideChar(65001,8,s,#s,b,n)~=n then return nil,"filename conversion failed" end
        return b
    end
    local function error_text(stage) return stage.." (Win32 "..tonumber(C.GetLastError())..")" end
    local function read(path,max)
        local w,err=wide(path);if not w then return nil,err end
        local h=C.CreateFileW(w,0x80000000,7,nil,3,0x80,nil)
        if h==invalid then
            local code=tonumber(C.GetLastError())
            if code==2 or code==3 then return nil,"missing" end
            return nil,"read open failed (Win32 "..code..")"
        end
        local size=ffi.new("int64_t[1]")
        if C.GetFileSizeEx(h,size)==0 then local e=error_text("file size failed");C.CloseHandle(h);return nil,e end
        local n=tonumber(size[0])
        if n<0 or n>max then C.CloseHandle(h);return nil,"settings file exceeds size limit" end
        local b=ffi.new("uint8_t[?]",math.max(n,1));local count=ffi.new("unsigned long[1]")
        local success=C.ReadFile(h,b,n,count,nil)
        local e=success==0 and error_text("read failed") or nil
        C.CloseHandle(h)
        if e then return nil,e end
        if tonumber(count[0])~=n then return nil,"short settings read" end
        return ffi.string(b,n)
    end
    local function mkdirs(path)
        -- Only parent directories are created, never guessed fallback roots.
        local parent=path:match("^(.*)[/\\][^/\\]+$")
        if not parent then return nil,"settings path has no parent directory" end
        parent=parent:gsub("/","\\")
        local prefix,rest=parent:match("^(%a:\\)(.*)$")
        if not prefix then prefix,rest=parent:match("^(\\\\[^\\]+\\[^\\]+\\?)(.*)$") end
        if not prefix then return nil,"settings path must be absolute" end
        for component in rest:gmatch("[^\\]+") do
            if component=="." or component==".." then return nil,"settings path contains relative components" end
            if prefix:sub(-1)~="\\" then prefix=prefix.."\\" end
            prefix=prefix..component
            local w,err=wide(prefix);if not w then return nil,err end
            if C.CreateDirectoryW(w,nil)==0 and tonumber(C.GetLastError())~=183 then
                return nil,error_text("create settings directory failed")
            end
        end
        return true
    end
    local function write_new(path,data)
        local w,err=wide(path);if not w then return nil,err end
        local h=C.CreateFileW(w,0x40000000,0,nil,1,0x80,nil)
        if h==invalid then return nil,error_text("temporary file creation failed") end
        local count=ffi.new("unsigned long[1]")
        local success=C.WriteFile(h,data,#data,count,nil)
        local e=success==0 and error_text("temporary file write failed") or nil
        if not e and tonumber(count[0])~=#data then e="short settings write" end
        if not e and C.FlushFileBuffers(h)==0 then e=error_text("settings flush failed") end
        C.CloseHandle(h)
        if e then C.DeleteFileW(w);return nil,e end
        return true
    end
    local function move(from,to,replace)
        local a,e=wide(from);if not a then return nil,e end
        local b,e2=wide(to);if not b then return nil,e2 end
        if C.MoveFileExW(a,b,replace==false and 8 or 9)==0 then return nil,error_text("atomic settings replacement failed") end
        return true
    end
    local api={read=read}
    function api.default_directory()
        local env=assert(wide("LOCALAPPDATA"))
        local n=C.GetEnvironmentVariableW(env,nil,0)
        if n==0 then return nil,"LOCALAPPDATA is unavailable" end
        local b=ffi.new("wchar_t[?]",n)
        local count=C.GetEnvironmentVariableW(env,b,n)
        if count==0 or count>=n then return nil,"LOCALAPPDATA changed while reading" end
        local len=C.WideCharToMultiByte(65001,0,b,count,nil,0,nil,nil)
        if len<=0 then return nil,"LOCALAPPDATA conversion failed" end
        local utf=ffi.new("char[?]",len)
        if C.WideCharToMultiByte(65001,0,b,count,utf,len,nil,nil)~=len then return nil,"LOCALAPPDATA conversion failed" end
        return ffi.string(utf,len).."\\CowboyBingus\\Helldivers2\\WeaponDefaults"
    end
    function api.atomic_write(path,data,expected,migration)
        if type(migration)=="string" then migration={profile_id=migration,schema=1} end
        if migration~=nil and (type(migration)~="table" or not valid_profile(migration.profile_id) or
            (migration.schema~=1 and migration.schema~=2)) then
            return nil,"invalid settings migration request"
        end
        local made,err=mkdirs(path);if not made then return nil,err end
        local lockpath=path..".lock";local lockwide,e=wide(lockpath);if not lockwide then return nil,e end
        local lock=C.CreateFileW(lockwide,0xC0000000,0,nil,4,0x80,nil)
        if lock==invalid then return nil,error_text("settings writer lock unavailable") end
        serial=serial+1
        local temp=path..".tmp-"..tonumber(C.GetCurrentProcessId()).."-"..serial
        local backup_temp=temp..".bak"
        local migration_schema=migration and migration.schema
        local migration_suffix=migration_schema and (".schema"..migration_schema) or ".migration"
        local migration_temp=temp..migration_suffix
        local migration_backup=path..migration_suffix..".bak"
        local function legacy_backup_status()
            local old,re=read(migration_backup,MAX_BYTES)
            if old==nil then
                if re=="missing" then return false end
                return nil,re
            end
            local config,pe=parse(old,migration.profile_id)
            if not config or config.schema~=migration_schema then
                return nil,"existing schema"..migration_schema.." backup is invalid: "..
                    tostring(pe or ("not schema "..migration_schema))
            end
            return true
        end
        local function perform()
            local current,re=read(path,MAX_BYTES)
            if current==nil and re~="missing" then return nil,re end
            if current~=expected then return nil,"settings changed concurrently; retry save" end
            if migration then
                local source,pe=parse(current,migration.profile_id)
                if not source or source.schema~=migration_schema then
                    return nil,"invalid schema"..migration_schema.." migration source: "..tostring(pe)
                end
                local exists,le=legacy_backup_status()
                if exists==nil then return nil,le end
                if not exists then
                    local backed,be=write_new(migration_temp,current);if not backed then return nil,be end
                    local moved,me=move(migration_temp,migration_backup,false)
                    if not moved then
                        -- A concurrently created valid backup is retained. An
                        -- invalid one or unrelated move failure blocks migration.
                        local found,fe=legacy_backup_status()
                        if not found then return nil,fe or me end
                    end
                end
            end
            local good,we=write_new(temp,data);if not good then return nil,we end
            if current~=nil then
                local backed,be=write_new(backup_temp,current);if not backed then return nil,be end
                local moved,me=move(backup_temp,path..".bak");if not moved then return nil,me end
            end
            return move(temp,path)
        end
        local safe,success,reason=pcall(perform)
        local tw=wide(temp);if tw then C.DeleteFileW(tw) end
        local bw=wide(backup_temp);if bw then C.DeleteFileW(bw) end
        local mw=wide(migration_temp);if mw then C.DeleteFileW(mw) end
        C.CloseHandle(lock)
        -- The empty lock file remains, avoiding a delete/open race between writers.
        if not safe then return nil,"settings write failed: "..tostring(success) end
        return success,reason
    end
    return api
end

local function defaults(profile_id)
    return {schema=3,profile_id=profile_id,flashlight_mode="None",weapons={}}
end
function Store:_settings(config)
    self.flashlight_mode=config.flashlight_mode
    self.migration_pending=config.schema<3
end
function Store:reload()
    local safe,data,reason=pcall(self.io.read,self.path,MAX_BYTES)
    if not safe then return nil,"settings read failed: "..tostring(data) end
    local config
    if data==nil then
        if reason~="missing" then return nil,reason or "settings read failed" end
        -- A file removed after we loaded it is not an empty replacement profile.
        if self.raw~=nil then return nil,"settings file disappeared; refusing to recreate it" end
        config=defaults(self.profile_id)
    elseif self.config and data==self.raw then
        -- Still read the file at every reload boundary so external edits and
        -- read errors remain observable. Identical bytes need no fresh parse.
        self:_settings(self.config)
        return true
    else
        config,reason=parse(data,self.profile_id)
        if not config then return nil,reason end
    end
    self.config=config;self.raw=data
    self:_settings(config)
    return true
end
function Store:get(resource,preset)
    local id,reason=resource_id(resource);if not id then return nil,reason end
    local index,err=preset_number(preset);if not index then return nil,err end
    local entry=self.config.weapons[id]
    if not entry then return nil,"not_found" end
    return clone(entry.presets[index])
end
function Store:get_presets(resource)
    local id,reason=resource_id(resource);if not id then return nil,reason end
    local entry=self.config.weapons[id]
    if not entry then return nil,"not_found" end
    return clone(entry.presets)
end
function Store:get_flashlight()
    return FLASHLIGHT_VALUES[self.config.flashlight_mode]
end
function Store:_commit(candidate)
    -- Legacy schemas are converted in memory on read. Only a successful
    -- mutation publishes schema 3 and backs up the exact original bytes.
    local migration=self.migration_pending and {profile_id=self.profile_id,schema=self.config.schema} or nil
    candidate.schema=3
    local data,se=serialize(candidate);if not data then return nil,se end
    if data==self.raw then return true end
    local safe,written,we=pcall(self.io.atomic_write,self.path,data,self.raw,migration)
    if not safe then return nil,"settings write failed: "..tostring(written) end
    if not written then return nil,we or "settings write failed" end
    self.config=candidate;self.raw=data
    self:_settings(candidate)
    return true
end
function Store:export_presets()
    local fresh,why=self:reload();if not fresh then return nil,why end
    return M.encode_presets(self.config.weapons)
end
function Store:import_presets(data,before_write,only_missing)
    -- Parse FIRST. Invalid clipboard data does not even reload or mutate this
    -- store, reserve a file, make backups or invoke the publication guard.
    local weapons,why=M.decode_presets(data)
    if not weapons then return nil,why end
    if type(before_write)~="function" then return nil,"preset import publication guard required" end
    local fresh,why=self:reload();if not fresh then return nil,why end
    if only_missing and self.raw~=nil then return true,{installed=false} end
    local candidate=clone(self.config);candidate.weapons=weapons
    local safe,allowed,why=pcall(before_write)
    if not safe or allowed~=true then return nil,safe and why or allowed end
    local ok,why=self:_commit(candidate);if not ok then return nil,why end
    local count=0;for _ in pairs(weapons) do count=count+1 end
    return true,{weapons=count,installed=true}
end
function Store:set_flashlight(value)
    local mode=value==nil and "None" or FLASHLIGHT_NAMES[value]
    if not mode then return nil,"flashlight mode must be 0 (Auto), 1 (On), 2 (Off) or nil (None)" end
    local fresh,err=self:reload();if not fresh then return nil,err end
    if self.config.flashlight_mode==mode and not self.migration_pending then return true end
    local candidate=clone(self.config);candidate.flashlight_mode=mode
    return self:_commit(candidate)
end
function Store:_mutate(resource,fn)
    local id,reason=resource_id(resource);if not id then return nil,reason end
    local fresh,err=self:reload();if not fresh then return nil,err end
    -- Known records retain the no-copy fast path after the one-time migration.
    -- A known legacy record must still persist its converted schema on ensure.
    if not fn and self.config.weapons[id] and not self.migration_pending then return true end
    local candidate=clone(self.config)
    local entry=candidate.weapons[id]
    if not entry then entry=empty_weapon();candidate.weapons[id]=entry end
    if fn then
        local accepted,why=fn(entry);if not accepted then return nil,why end
    end
    return self:_commit(candidate)
end
function Store:ensure(resource)
    return self:_mutate(resource)
end
function Store:initialize(resource,presets)
    local id,reason=resource_id(resource);if not id then return nil,reason end
    if type(presets)~="table" then return nil,"initial presets must be a table" end
    for index in pairs(presets) do
        local valid=preset_number(index)
        if not valid then return nil,"initial presets require exactly indices 1 to 3" end
    end
    local checked={}
    for index=1,3 do
        local preset=presets[index]
        if type(preset)~="table" or type(preset.targets)~="table" then
            return nil,"initial preset "..index.." must contain targets"
        end
        for key in pairs(preset) do
            if key~="targets" then return nil,"unknown initial preset metadata: "..tostring(key) end
        end
        checked[index]={targets={}}
        for side,r in pairs(preset.targets) do
            if not SIDE[side] then return nil,"unknown initial direction: "..tostring(side) end
            local validated,err=record(r)
            if not validated then return nil,"initial preset "..index.." "..side..": "..err end
            if validated.kind~="flashlight" then checked[index].targets[side]=validated end
        end
    end
    -- Decide against fresh disk state, never a prior get/not_found result.
    -- Empty and explicitly cleared records are existing player choices too.
    local fresh,err=self:reload();if not fresh then return nil,err end
    if self.config.weapons[id] then
        if self.migration_pending then
            local migrated,why=self:_commit(clone(self.config));if not migrated then return nil,why end
        end
        return true,false
    end
    local candidate=clone(self.config)
    candidate.weapons[id]={presets=checked}
    -- Publish all three together. The normal byte guard also lets a competing
    -- save/clear win between reload and commit; a failed create is not retried.
    local written,why=self:_commit(candidate);if not written then return nil,why end
    return true,true
end
function Store:merge(resource,updates,preset,plan)
    local index,err=preset_number(preset);if not index then return nil,err end
    if type(updates)~="table" then return nil,"save updates must be a table" end
    local checked={}
    for side,r in pairs(updates) do
        if not SIDE[side] then return nil,"unknown save direction: "..tostring(side) end
        local validated,err=record(r);if not validated then return nil,side..": "..err end
        if validated.kind~="flashlight" then checked[side]=validated end
    end
    local normalized,plan_error=save_plan(plan,checked)
    if plan_error then return nil,plan_error end
    if normalized and normalized.count==2 and index==3 then
        return nil,"a single setting with two choices supports only presets 1 and 2"
    end
    local info
    local written,reason=self:_mutate(resource,function(entry)
        for side,r in pairs(checked) do entry.presets[index].targets[side]=clone(r) end
        if normalized then
            info={cleared={}}
            local side,selected=normalized.side,normalized.selected
            if normalized.count==2 then
                -- Only an explicit save normalizes these records. Observing
                -- a simpler module configuration must not delete dormant 3.
                local complement=index==1 and 2 or 1
                local other=normalized.choices[selected.slot==1 and 2 or 1]
                entry.presets[complement].targets[side]=clone(other)
                entry.presets[3].targets={}
                info.complement=complement;info.cleared[1]=3
            else
                for other=1,3 do
                    local saved=entry.presets[other].targets[side]
                    if other~=index and saved and saved.kind==selected.kind and saved.value==selected.value then
                        entry.presets[other].targets={}
                        info.cleared[#info.cleared+1]=other
                    end
                end
            end
        end
        return true
    end)
    if not written then return nil,reason end
    return true,info
end
function Store:clear(resource,preset)
    local index,err=preset_number(preset);if not index then return nil,err end
    return self:_mutate(resource,function(entry) entry.presets[index].targets={};return true end)
end
function Store:clear_all(resource)
    return self:_mutate(resource,function(entry) entry.presets=empty_weapon().presets;return true end)
end
-- Path/I/O context only. HUD-only installs must not open, create, reload or
-- migrate the disabled presets file, even if it is corrupt or inaccessible.
function M.context(profile_id,options)
    if not valid_profile(profile_id) then return nil,"active SteamID64 must be a 17-digit decimal string" end
    options=options or {}
    local api,err=options.io
    if not api then api,err=windows_io();if not api then return nil,err end end
    if type(api.read)~="function" or type(api.atomic_write)~="function" then return nil,"invalid settings I/O adapter" end
    local path=options.path
    if not path then
        local directory=options.directory
        if not directory then
            if type(api.default_directory)~="function" then return nil,"settings directory unavailable" end
            directory,err=api.default_directory();if not directory then return nil,err end
        end
        path=directory.."\\"..profile_id..".ini"
    end
    if type(path)~="string" or path=="" or path:find("%z") then return nil,"invalid settings path" end
    return {profile_id=profile_id,path=path,io=api}
end
function M.open(profile_id,options)
    local context,err=M.context(profile_id,options)
    if not context then return nil,err end
    local store=setmetatable(context,Store)
    local loaded,reason=store:reload();if not loaded then return nil,reason end
    return store
end

return M

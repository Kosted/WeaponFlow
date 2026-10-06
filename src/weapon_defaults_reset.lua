-- Reset only this profile's WeaponFlow files. No native calls or input access.
-- The coordinator backs up first, clears its own native menu actions, then
-- commits these files. File/native operations are not one atomic transaction.
local M={}
local Store=DefaultsStore
local Plan={}
Plan.__index=Plan
local serial=0

local function read(io,path,max)
    local safe,raw,why=pcall(io.read,path,max)
    if not safe then return nil,"read failed: "..tostring(raw),false end
    if raw==nil then
        if why=="missing" then return nil,nil,true end
        return nil,"read failed: "..tostring(why or "unknown I/O failure"),false
    end
    if type(raw)~="string" or #raw>max then return nil,"invalid reset file size/content",false end
    return raw,nil,true
end

local function write(io,path,data,expected)
    local safe,ok,why=pcall(io.atomic_write,path,data,expected)
    if not safe then return nil,"write failed: "..tostring(ok) end
    if ok~=true then return nil,"write failed: "..tostring(why or "unknown I/O failure") end
    return true
end

local function owned(raw,profile)
    if raw==nil then return true end
    local found=false
    for line in (raw.."\n"):gmatch("([^\n]*)\n") do
        local value=line:match("^%s*profile_id%s*=%s*(.-)%s*$")
        if value then
            if found or value~=profile then return nil,"reset source has foreign or duplicate profile identity" end
            found=true
        end
    end
    if not found then return nil,"reset source profile identity is unavailable" end
    return true
end

local function defaults(profile)
    local preset_data,why
    if type(DefaultPresets)=="string" then preset_data,why=Store.seed_settings(profile,DefaultPresets)
        if not preset_data then return nil,why end
    end
    local files={
        {name="presets",suffix=".ini",max=1024*1024,data=preset_data or table.concat({
            "[settings]","schema=3","profile_id="..profile,"flashlight_mode=None",""},"\r\n")},
        {name="hud",suffix="-HUD.ini",max=65536,data=table.concat({
            "[hud]","schema=2","profile_id="..profile,
            "x=0.530000000000","y=0.550000000000",""},"\r\n")},
        {name="menu",suffix="-Menu.ini",max=4096,data=table.concat({
            "[menu]","schema=1","profile_id="..profile,
            "save=false","cycle=false","hud=false","reset=false",""},"\r\n")},
    }
    return files
end

function Plan:_verify(completed)
    for index,file in ipairs(self.files) do
        local expected=index<=(completed or 0) and file.data or file.raw
        local raw,why,ok=read(self.io,file.path,file.max)
        if not ok then return nil,why..": "..file.name end
        if raw~=expected then return nil,"reset file changed concurrently: "..file.name end
    end
    return true
end

function Plan:backup()
    if self.failed then return nil,self.failed,self.failure end
    if self.backed_up then return true,self.backup_directory end
    local current,reason=self:_verify(0)
    if not current then return nil,reason end
    local manifest={"[reset]","schema=1","profile_id="..self.profile_id,
        "created_utc="..self.timestamp,""}
    for _,file in ipairs(self.files) do
        manifest[#manifest+1]="[file:"..file.name.."]"
        manifest[#manifest+1]="path="..file.path
        manifest[#manifest+1]="present="..tostring(file.raw~=nil)
        manifest[#manifest+1]="bytes="..tostring(file.raw and #file.raw or 0)
        manifest[#manifest+1]=""
        if file.raw~=nil then
            local path=self.backup_directory.."/"..self.profile_id..file.suffix
            local ok,why=write(self.io,path,file.raw,nil)
            if ok then
                local copied,err,readable=read(self.io,path,file.max)
                if not readable or copied~=file.raw then ok,why=nil,err or "backup readback mismatch" end
            end
            if not ok then
                self.failed="reset backup failed: "..file.name..": "..tostring(why)
                self.failure={backup_directory=self.backup_directory,active_files_written=0,partial=false}
                return nil,self.failed,self.failure
            end
        end
    end
    local body=table.concat(manifest,"\r\n")
    local path=self.backup_directory.."/manifest.ini"
    local ok,why=write(self.io,path,body,nil)
    if ok then
        local copied,err,readable=read(self.io,path,16384)
        if not readable or copied~=body then ok,why=nil,err or "backup manifest readback mismatch" end
    end
    if not ok then
        self.failed="reset backup manifest failed: "..tostring(why)
        self.failure={backup_directory=self.backup_directory,active_files_written=0,partial=false}
        return nil,self.failed,self.failure
    end
    self.backed_up=true
    return true,self.backup_directory
end

function Plan:_rollback(attempted,reason)
    local detail={backup_directory=self.backup_directory,active_files_attempted=attempted,
        partial=false,rollback={},missing_originals_retained={}}
    for index=attempted,1,-1 do
        local file=self.files[index]
        local raw,why,ok=read(self.io,file.path,file.max)
        local status
        if not ok then status="unreadable: "..tostring(why);detail.partial=true
        elseif raw==file.raw then status="original retained"
        elseif raw~=file.data then status="external change retained";detail.partial=true
        elseif file.raw==nil then
            -- Existing I/O intentionally has no deletion API. Preserve the valid
            -- fresh file and report that absence could not be restored.
            status="fresh default retained; original was missing";detail.partial=true
            detail.missing_originals_retained[#detail.missing_originals_retained+1]=file.path
        else
            local restored,error=write(self.io,file.path,file.raw,file.data)
            if restored then
                local check,read_error,readable=read(self.io,file.path,file.max)
                if not readable or check~=file.raw then restored,error=nil,read_error or "rollback readback mismatch" end
            end
            if restored then status="original restored"
            else status="rollback failed: "..tostring(error);detail.partial=true end
        end
        detail.rollback[file.name]=status
    end
    self.failed="reset file commit failed: "..tostring(reason)
    self.failure=detail
    return nil,self.failed,detail
end

function Plan:commit()
    if self.committed then return true,self.result end
    if self.failed then return nil,self.failed,self.failure end
    local backed,why,detail=self:backup()
    if not backed then return nil,why,detail end
    local changed=0
    for index,file in ipairs(self.files) do
        local current,reason=self:_verify(index-1)
        if not current then return self:_rollback(index-1,reason) end
        if file.raw~=file.data then
            local ok,error=write(self.io,file.path,file.data,file.raw)
            if not ok then return self:_rollback(index,error) end
            changed=changed+1
        end
    end
    local current,reason=self:_verify(#self.files)
    if not current then return self:_rollback(#self.files,reason) end
    self.committed=true
    self.result={backup_directory=self.backup_directory,files_written=changed,
        profile_id=self.profile_id,partial=false}
    return true,self.result
end

function M.prepare(profile_id,options)
    if type(Store)~="table" or type(Store.context)~="function" then return nil,"reset settings context unavailable" end
    if options~=nil and type(options)~="table" then return nil,"invalid reset options" end
    options=options or {}
    local safe,context,reason=pcall(Store.context,profile_id,options)
    if not safe then return nil,"reset context failed: "..tostring(context) end
    if not context then return nil,reason end
    local directory=type(context.path)=="string" and
        context.path:match("^(.*[/\\])"..profile_id.."%.[iI][nN][iI]$")
    if not directory or context.profile_id~=profile_id or type(context.io)~="table" or
       type(context.io.read)~="function" or type(context.io.atomic_write)~="function" then
        return nil,"reset requires the exact profile settings path/context"
    end
    local timestamp=options.timestamp or os.date("!%Y%m%dT%H%M%SZ")
    if type(timestamp)~="string" or #timestamp>40 or not timestamp:match("^[0-9A-Za-z_%-]+$") then
        return nil,"invalid reset backup timestamp"
    end
    serial=serial+1
    local files,why=defaults(profile_id);if not files then return nil,why end
    local plan=setmetatable({profile_id=profile_id,io=context.io,files=files,timestamp=timestamp,
        backup_directory=directory.."Backups/reset-"..profile_id.."-"..timestamp.."-"..serial},Plan)
    for _,file in ipairs(plan.files) do
        file.path=directory..profile_id..file.suffix
        local raw,why,readable=read(plan.io,file.path,file.max)
        if not readable then return nil,why..": "..file.name end
        local valid,error=owned(raw,profile_id)
        if not valid then return nil,error..": "..file.name end
        file.raw=raw
    end
    return plan
end

return M

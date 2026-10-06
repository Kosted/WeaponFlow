-- Pure addon registration. BSL loads all discovered entries synchronously;
-- the single runtime starts after the first forwarded update returns.
local M={}
local KEY="ConstantinWeaponDefaultsBootstrap"
local DIAGNOSTICS_KEY="ConstantinWeaponDefaultsDiagnostics"
local function diagnostics_requested()
    local request=rawget(_G,DIAGNOSTICS_KEY)
    if type(request)~="table" or rawget(request,"api")~=1 or rawget(request,"enabled")~=true then return false end
    local version=rawget(request,"version")
    -- Compatibility is the request API, not the companion/main release pair.
    -- Raw reads keep malformed request metatables outside startup execution.
    return type(version)=="string" and #version<=32 and version:match("^%d+%.%d+%.%d+$")~=nil
end
local function report(reason)
    local output=rawget(_G,"print")
    if type(output)=="function" then pcall(output,"[WeaponDefaultsBootstrap] "..reason) end
end
local function refuse(state,reason)
    if state and not state.started then
        state.invalid=reason;state.status="inactive";state.factory=nil
    end
    report(reason)
    return nil,reason
end
function M.register(config)
    local state=rawget(_G,KEY)
    if state~=nil and (type(state)~="table" or state.api~=1) then
        return refuse(nil,"incompatible startup registry")
    end
    if type(config)~="table" or type(config.version)~="string" or
       not config.version:match("^%d+%.%d+%.%d+$") or
       (config.flavor~="release" and config.flavor~="diagnostic") or
       config.feature~="weaponflow" or type(config.factory)~="function" then
        return refuse(state,"invalid feature registration")
    end
    if state then
        if state.invalid then return nil,state.invalid end
        if state.version~=config.version or state.flavor~=config.flavor then
            return refuse(state,"mixed versions or release/diagnostic payloads; deploy one package")
        end
        if state.shutdown then return refuse(state,"feature registration after shutdown") end
        return state -- Duplicate discovery never creates another runtime.
    else
        state={api=1,version=config.version,flavor=config.flavor,
            factory=config.factory,status="collecting",started=false,shutdown=false}
        rawset(_G,KEY,state)
        local previous_update=rawget(_G,"update")
        local previous_shutdown=rawget(_G,"shutdown")
        if type(previous_update)~="function" or type(previous_shutdown)~="function" then
            return refuse(state,"engine update/shutdown callbacks unavailable")
        end
        local function after_update(...)
            if not state.started and not state.shutdown and not state.invalid then
                -- Seal first: failure or re-entry must never retry native init.
                state.started=true;state.status="starting"
                local factory=state.factory;state.factory=nil
                local selected={presets=true,hud=true,diagnostics=diagnostics_requested()}
                state.selected=selected
                local ok,result=pcall(factory,selected)
                if ok then state.runtime=result;state.status="started"
                else state.status="failed";state.invalid=tostring(result);report(state.invalid) end
            end
            -- Preserve the preceding callback's full tuple, including nils.
            return ...
        end
        rawset(_G,"update",function(...) return after_update(previous_update(...)) end)
        rawset(_G,"shutdown",function(...)
            state.shutdown=true;state.status="shutdown";state.factory=nil
            return previous_shutdown(...)
        end)
    end
    return state
end
M.key=KEY
return M

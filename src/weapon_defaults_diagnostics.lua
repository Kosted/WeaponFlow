-- Stable, inert diagnostics request. The main addon's bootstrap snapshots this
-- once after synchronous BSL discovery. No engine hooks or gameplay work live
-- here, and this companion does nothing by itself beyond publishing the flag.
local KEY="ConstantinWeaponDefaultsDiagnostics"
local request=rawget(_G,KEY)
if request~=nil then
    local version=type(request)=="table" and rawget(request,"version") or nil
    if type(request)~="table" or rawget(request,"api")~=1 or rawget(request,"enabled")~=true or
       type(version)~="string" or #version>32 or not version:match("^%d+%.%d+%.%d+$") then
        return nil,"incompatible diagnostics request; existing state left unchanged"
    end
    return request
end
request={api=1,enabled=true,version="1.0.0"}
rawset(_G,KEY,request)
return request

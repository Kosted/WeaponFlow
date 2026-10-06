-- Native game binding descriptions and one-time default records.
-- No controls file reads, synchronization or trigger recognition.
local M={active_names={"save","cycle","hud","reset"}}
local TRIGGERS={"Press","Release","Hold","LongPress","Tap","DoubleTap","LongHold","LongRelease","RepeatInterval"}
local ffi=require("ffi")
local function check(v,s) if not v then error(s,0) end end
function M.normalize(value)
    local ok,result=pcall(function()
        check(type(value)=="table" and #value<=16,"binding must contain at most 16 buttons")
        local out={};local count=0
        for k in pairs(value) do count=count+1;check(type(k)=="number" and k%1==0 and k>=1 and k<=#value,"invalid binding array") end
        check(count==#value,"sparse binding array")
        for _,row in ipairs(value) do
            check(type(row)=="table","invalid binding record")
            check(type(row.key)=="string" and #row.key<=48 and row.key:match("^[%w_ %-%+]+$") and row.key:upper()~="NONE","invalid button name")
            local trigger=row.trigger or 0;local threshold=row.threshold or 0
            check(type(trigger)=="number" and trigger%1==0 and TRIGGERS[trigger+1],"unsupported button trigger")
            check(type(threshold)=="number" and threshold==threshold and threshold>=0 and threshold<=60,"invalid button threshold")
            local f32=ffi.new("float[1]",threshold)
            out[#out+1]={key=row.key:upper():gsub("[%s_%-]",""),trigger=trigger,threshold=tonumber(f32[0])}
        end
        return out
    end)
    if ok then return result end;return nil,result
end
function M.encode(rows)
    local normalized,why=M.normalize(rows);if not normalized then return nil,why end
    if #normalized==0 then return "None" end
    local values={}
    for _,v in ipairs(normalized) do
        values[#values+1]=v.key.."@"..TRIGGERS[v.trigger+1].."@"..string.format("%.9g",v.threshold)
    end
    return table.concat(values,"|")
end
function M.single(key)
    if key==nil or key:upper()=="NONE" then return {} end
    return {{key=key,trigger=0,threshold=0}}
end
function M.defaults()
    return {save=M.single("P"),cycle={},hud=M.single("H"),reset={}}
end
M.triggers=TRIGGERS
-- The verified Windows native button layout, independent of button names.
-- Keyboard IDs are virtual-key codes; mouse IDs0..4 are the five buttons.
function M.native_vk(row)
    if type(row)~="table" or type(row.button_id)~="number" or row.button_id%1~=0 then return nil end
    if row.input_kind~=nil and row.input_kind~=4 then return nil end
    if row.device==3 and row.button_id>=1 and row.button_id<=255 then return row.button_id end
    if row.device==4 then return ({[0]=1,[1]=2,[2]=4,[3]=5,[4]=6})[row.button_id] end
end
local function safe_label(value)
    return type(value)=="string" and value~="" and #value<=48 and not value:find("[^ -~]")
end
-- Only verified numeric native records decide command readiness. A label
-- provider may be absent, fail, or return an unfamiliar name without disabling
-- the action or changing its identity/release guards.
function M.describe_native(rows,label_provider)
    local out={active=true,ready=false,pressed=false,down=false,vks={},groups={},bindings=rows or {}}
    if not rows then out.reason="WeaponFlow bindings unavailable";return out end
    if #rows==0 then out.reason="hotkey is unbound";return out end
    local labels,triggers,seen,group={},{},{},{}
    for i,row in ipairs(rows) do
        local ok,label=false,nil
        if type(label_provider)=="function" then ok,label=pcall(label_provider,row) end
        if not ok or not safe_label(label) then
            label=Text.text(row.device==3 and "input.keyboard" or row.device==4 and "input.mouse" or "input.unknown",{id=row.button_id})
        end
        labels[#labels+1]=(i>1 and ((rows[i-1].combine or 0)~=0 and " + " or " / ") or "")..label
        triggers[i]=TRIGGERS[row.trigger+1] or Text.text("input.trigger",{id=row.trigger})
        group[#group+1]=row.identity
        if (row.combine or 0)==0 then
            -- One complete chord is one conflict identity. Shared modifiers
            -- alone are not overlapping WeaponFlow commands.
            out.groups[i]={table.concat(group," + ")};group={}
        end
        if row.vk and not seen[row.vk] then seen[row.vk]=true;out.vks[#out.vks+1]=row.vk end
    end
    out.label=table.concat(labels);out.trigger_label=table.concat(triggers," / ")
    out.vk=#out.vks==1 and out.vks[1] or nil;out.ready=true
    return out
end
-- Initial defaults and explicit Reset compare verified IDs, never captions.
-- The defaults publisher still owns all normalization and native write guards.
function M.matches_native_defaults(rows,defaults,resolve_key)
    if not rows or #rows~=#defaults then return false end
    for i,expected in ipairs(defaults) do
        local ok,vk=pcall(resolve_key,expected.key)
        local actual=rows[i]
        local threshold=tonumber(ffi.new("float[1]",expected.threshold or 0)[0])
        if not ok or actual.device~=3 or actual.button_id~=vk or
           actual.input_kind~=nil and actual.input_kind~=4 or
           actual.device_index~=nil and actual.device_index~=255 or
           (actual.combine or 0)~=0 or
           actual.trigger~=(expected.trigger or 0) or actual.threshold~=threshold then return false end
    end
    return true
end
function M.disjoint(a,b)
    if not a or not b then return false end
    local function short_long(x,y)
        return x.trigger==4 and (y.trigger==3 or y.trigger==6 or y.trigger==7) and
            type(x.threshold)=="number" and type(y.threshold)=="number" and x.threshold<=y.threshold
    end
    return short_long(a,b) or short_long(b,a)
end
return M

-- One profile-wide flashlight preference. Native access and atomic file I/O
-- are supplied by the coordinator. Own cycle readbacks never become choices.
local M={}
local Controller={};Controller.__index=Controller
local function valid(value)
    return type(value)=="number" and value==math.floor(value) and value>=0 and value<=2
end
function M.new(options)
    assert(type(options)=="table" and type(options.read)=="function" and
        type(options.load)=="function" and type(options.save)=="function" and
        type(options.apply)=="function", "flashlight controller callbacks required")
    return setmetatable({options=options,next_write=0},Controller)
end
function Controller:log(event,detail)
    if self.options.log then pcall(self.options.log,event.." "..detail) end
end
function Controller:equip(identity,sequence,time)
    self.current={identity=identity,sequence=sequence,deadline=time+8,ready=time+0.10,
        restoring=true,attempts=0,next_read=0,next_load=0}
end
function Controller:reset(discard_pending)
    self.current=nil
    -- Ordinary mission/context loss cannot erase a known unsaved preference.
    -- The caller must explicitly discard it when the active profile changes
    -- or becomes invalid, so a later profile cannot inherit the pending write.
    if discard_pending then self.pending=nil;self.next_write=0 end
end
function Controller:pause()
    local current=self.current
    if current then
        -- Utilities are not equips. Do not restore a default on their return.
        -- Retain an issued action until its result can be read safely.
        current.restoring=false
    end
end
function Controller:problem(current,message)
    if message~=current.problem then
        self:log("LIGHT_WAIT","equip="..current.sequence.." reason="..tostring(message))
        current.problem=message
    end
end
function Controller:unreadable_action(current,time)
    if current.awaiting and time>current.awaiting.deadline then
        current.blocked=true;current.restoring=false
        self:log("LIGHT_STOP","equip="..current.sequence.." reason=action result unreadable; learning suspended for this equip")
    end
end
function Controller:persist(current,time)
    if self.pending==nil or time<self.next_write then return end
    self.next_write=time+0.25
    local ok,why=self.options.save(self.pending)
    if not ok then self:problem(current,"save: "..tostring(why));return end
    current.target=self.pending;self.pending=nil;current.problem=nil
    -- Only failed writes need backoff. A fresh, verified player choice should
    -- reach disk immediately even when the previous choice was just saved.
    self.next_write=time
    self:log("LIGHT_SAVED","equip="..current.sequence.." mode="..current.target)
end
function Controller:step(snapshot,identity,time,can_apply)
    local current=self.current
    if not current or current.identity~=identity or current.blocked then return end
    if not current.loaded then
        if time<current.next_load then return end
        current.next_load=time+0.25
        local value,why=self.options.load()
        if why or (value~=nil and not valid(value)) then
            self:problem(current,"profile: "..tostring(why or "invalid global mode"));return
        end
        -- Never replace a previously observed, unsaved choice with a new
        -- weapon's initial mode or an older on-disk value. A successful profile
        -- read is still required before retrying that write or applying it.
        current.target=self.pending~=nil and self.pending or value;current.loaded=true
    end
    if time<current.next_read then return end
    local observed,why=self.options.read(snapshot,current.sample)
    if not observed or why then
        current.sample=nil;current.next_read=time+0.10
        self:problem(current,"read: "..tostring(why))
        self:unreadable_action(current,time)
        self:persist(current,time)
        return
    end
    if type(observed)=="table" and observed.present==false then
        current.sample=nil;current.next_read=time+1
        if current.awaiting then
            current.blocked=true;current.restoring=false
            self:log("LIGHT_STOP","equip="..current.sequence.." reason=module disappeared during action")
        end
        self:persist(current,time)
        return
    end
    if type(observed)~="table" or observed.present~=true or not valid(observed.selected) or
       type(observed.module_bytes)~="string" then
        current.sample=nil;current.next_read=time+0.10
        self:problem(current,"invalid flashlight observation")
        self:unreadable_action(current,time)
        self:persist(current,time);return
    end
    current.sample=observed;current.next_read=time;current.problem=nil
    local value=observed.selected
    if current.module and current.module~=observed.module_bytes then
        -- A new attachment's initial mode is not a manual change of the old
        -- attachment. An outstanding action on the old module is uncertain.
        if current.awaiting then
            current.blocked=true;current.restoring=false
            self:log("LIGHT_STOP","equip="..current.sequence.." reason=module changed during action")
            return
        end
        current.seen=nil
    end
    current.module=observed.module_bytes
    if current.seen==nil then
        current.seen=value
        if current.target==nil and self.pending==nil then
            -- First reliable mode establishes a neutral starting preference.
            -- Legacy per-weapon presets are deliberately not used to guess it.
            self.pending=value;current.restoring=false
        end
    elseif current.awaiting then
        local expected=current.awaiting
        if value==expected.next_value then
            current.seen=value;current.awaiting=nil
            self:log("LIGHT_VERIFIED","equip="..current.sequence.." mode="..value)
        elseif value==expected.before then
            if time<=expected.deadline then return end
            current.blocked=true;current.restoring=false
            self:log("LIGHT_STOP","equip="..current.sequence.." reason=no verified transition; no repeat")
            return
        else
            -- A third value cannot be the single issued cycle's result.
            -- Preserve the newly observed choice and stop the restoration.
            current.awaiting=nil;current.restoring=false;current.seen=value;self.pending=value
        end
    elseif value~=current.seen then
        current.seen=value;self.pending=value;current.restoring=false
    end
    self:persist(current,time)
    if self.pending~=nil or not current.restoring then return end
    if value==current.target then current.restoring=false;return end
    if time>current.deadline then
        current.restoring=false
        self:log("LIGHT_SKIP","equip="..current.sequence.." reason=restoration deadline")
        return
    end
    if can_apply~=true or time<current.ready then return end
    if current.attempts>=2 then
        current.restoring=false
        self:log("LIGHT_STOP","equip="..current.sequence.." reason=cycle bound exhausted")
        return
    end
    local next_value=(value+1)%3
    local called,error_text=self.options.apply(snapshot,observed,next_value,current.sequence)
    if not called then
        current.ready=time+0.10
        self:problem(current,"apply: "..tostring(error_text));return
    end
    current.attempts=current.attempts+1;current.ready=time+0.06
    current.awaiting={before=value,next_value=next_value,deadline=time+0.50}
    self:log("LIGHT_CYCLE","equip="..current.sequence.." before="..value.." next="..next_value.." target="..current.target)
end
return M

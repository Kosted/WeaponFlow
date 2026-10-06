-- Required Mod Bindings Menu v2.1. The game owns assignments and triggers.
-- Ordinary startup/remaps are read-only; no controls file is imported or saved.
-- Owned writes are limited to one-time initial defaults and explicit Reset.
local M={version="0.6.0"}
function M.available(menu)
    return type(menu)=="table" and menu.api==1 and type(menu.version)=="number" and menu.version>=3 and
        type(menu.register_binding)=="function" and type(menu.ready)=="function" and type(menu.is_down)=="function"
end
local IDS={save="constantin.weaponflow.presets",
    cycle="constantin.weaponflow.cycle",hud="constantin.weaponflow.hud",reset="constantin.weaponflow.reset"}
local ORDER=Bindings.active_names
M.ids=IDS
local MAX_ASSIGNMENTS=256*1024

function M.parse_assignments(text)
    if type(text)~="string" or #text>MAX_ASSIGNMENTS then return nil,"invalid menu assignments file" end
    local found,codes={},{}
    for line in (text.."\n"):gmatch("([^\r\n]*)[\r\n]") do
        if line~="" then
            local id,group,action=line:match("^([^\t]+)\t(%d+)\t(%d+)$")
            if not id then return nil,"malformed menu assignments record" end
            group,action=tonumber(group),tonumber(action)
            if group>65535 or action>65535 or found[id] then return nil,"ambiguous menu assignments record" end
            local code=group*65536+action
            if codes[code] then return nil,"duplicate menu native action assignment" end
            found[id]={group=group,action=action,code=code};codes[code]=id
        end
    end
    return found
end

local function label_card(value)
    if type(value)~="string" or value=="" or #value>32 or value:find("[%c]") then return Text.text("menu.card") end
    return value
end

function M.new(options)
    options=options or {}
    local get_menu=options.get_menu or function() return rawget(_G,"ModBindingsMenu") end
    local get_loader=options.get_loader or function() return rawget(_G,"CowboyBingusModLoader") end
    local getenv=options.getenv or os.getenv
    local read_file=options.read_file
    local get_engine=options.get_engine or function() return rawget(_G,"stingray") end
    local read_binding=options.read_binding or function(code)
        if type(NativeModBindings)~="table" or type(NativeModBindings.inspect)~="function" or
           type(options.native_reader)~="table" then return nil,"guarded menu binding reader unavailable" end
        return NativeModBindings.inspect(options.native_reader,code)
    end
    -- Writes validate profile/ownership without touching any game input file.
    local prepare_publication
    local clear_bindings,replace_binding=options.clear_bindings,options.replace_binding
    if (not clear_bindings or not replace_binding) and type(NativeModBindingDefaults)=="table" and
       type(NativeModBindingDefaults.new)=="function" and type(options.native_reader)=="table" then
        local initialized,initializer=pcall(NativeModBindingDefaults.new,{
            prepare_publication=function(changes,config)
                if not prepare_publication then return nil,"owned binding publication unavailable" end
                return prepare_publication(changes,config)
            end,engine=options.engine})
        if initialized and type(initializer)=="table" then
            clear_bindings=clear_bindings or function(codes,before_write)
                return initializer:clear_many(options.native_reader,codes,before_write)
            end
            replace_binding=replace_binding or function(code,rows,before_write,signature)
                return initializer:replace(options.native_reader,code,rows,before_write,signature)
            end
        end
    end
    local watch_binding=options.watch_binding
    if not watch_binding and type(NativeModBindings)=="table" and type(NativeModBindings.watch)=="function" and
       type(options.native_reader)=="table" then
        watch_binding=function(previous) return NativeModBindings.watch(options.native_reader,previous) end
    end
    local read_event=options.read_event
    if not read_event and type(NativeModBindings)=="table" and type(NativeModBindings.event)=="function" and
       type(options.native_reader)=="table" then
        read_event=function(previous) return NativeModBindings.event(options.native_reader,previous) end
    end
    local editor_open=options.editor_open or function() return NativeModBindings.menu_open(options.native_reader) end
    local resolve_action=options.resolve_action or function(code,raw)
        if raw then return NativeModBindingDefaults.initial_state(options.native_reader,raw) end
        return NativeModBindingDefaults.resolve(options.native_reader,code)
    end
    local self={records={},next_assignments=0,next_registration=0,card_label="weapon card",pending_publication={}}
    function self:queue_reset_defaults()
        for _,action in ipairs(ORDER) do self.pending_publication[action]=true end
        self.next_editor_poll=0
    end
    function self:consume(name)
        local record=self.records[name]
        if record then
            record.event=nil
            record.idle_released=nil
            local delay=0
            for _,row in ipairs(record.binding_rows or {}) do if row.trigger==5 then delay=math.max(delay,row.threshold) end end
            record.suppressed_until=(self.last_event_time or 0)+delay
        end
    end
    function self:cancel()
        for _,name in ipairs(ORDER) do self:consume(name) end
    end
    local function wanted(name,context)
        if name=="reset" then return context.reset_enabled==true or context.hud_enabled==true or context.presets_enabled~=false end
        return name=="hud" and context.hud_enabled==true or name~="hud" and context.presets_enabled~=false
    end
    local function label(name)
        Text.read_language()
        -- The bindings page can open immediately after a card-control remap,
        -- before the next coordinator tick refreshes its ordinary cache.
        if type(self.refresh_card_label)=="function" then
            local ok,value=pcall(self.refresh_card_label)
            self.card_label=label_card(ok and value or nil)
        end
        return Text.text("menu."..name,{card=self.card_label})
    end
    local function assignments(time,force)
        if not force and time<self.next_assignments then return end
        self.next_assignments=time+2
        local loaded,loader=pcall(get_loader)
        if not loaded then loader=nil end
        local dir=type(loader)=="table" and loader.log_directory or nil
        if type(dir)~="string" or dir=="" then
            local base=getenv("LOCALAPPDATA")
            dir=type(base)=="string" and base.."/CowboyBingus/Helldivers2" or nil
        end
        if not dir or type(read_file)~="function" then
            self.assignments,self.assignments_error=nil,"menu assignments path/read API unavailable";return
        end
        local ok,text,reason=pcall(read_file,dir:gsub("[/\\]+$","").."/ModBindingsMenu.assignments")
        if not ok then text,reason=nil,"menu assignments read failed" end
        if text==nil then self.assignments,self.assignments_error=nil,reason or "menu assignments unavailable";return end
        self.assignments,self.assignments_error=M.parse_assignments(text)
    end
    prepare_publication=function(changes,config)
        if type(options.get_input_snapshot)~="function" or type(options.validate_input_snapshot)~="function" then
            return nil,"read-only input context validation unavailable"
        end
        if type(changes)~="table" or #changes<1 or #changes>#ORDER then return nil,"invalid owned binding change count" end
        local identities,seen={},{}
        assignments(0,true)
        if not self.assignments then return nil,self.assignments_error or "menu ownership unavailable" end
        local count=0
        for index,change in pairs(changes) do
            count=count+1
            if type(index)~="number" or index%1~=0 or index<1 or index>#changes or type(change)~="table" or
               type(change.code)~="number" or seen[change.code] then
                return nil,"invalid or duplicate owned binding change"
            end
            local owned
            for _,name in ipairs(ORDER) do
                local current=self.assignments[IDS[name]]
                if current and current.code==change.code then owned=IDS[name];break end
            end
            if not owned then return nil,"binding change is not owned by WeaponFlow" end
            seen[change.code]=true;identities[owned]=change.code
        end
        if count~=#changes then return nil,"binding changes must be a dense list" end
        local read,snapshot,why=pcall(options.get_input_snapshot,config)
        if not read then return nil,"input snapshot failed: "..tostring(snapshot) end
        if type(snapshot)~="table" or snapshot.profile_id~=options.profile_id then
            return nil,why or "input snapshot profile differs"
        end
        local function validate()
            -- Resolve the actual active account/path and the sidecar again at
            -- every native write/readback/rollback. Old ownership never gives
            -- permission to change an action reassigned to another addon.
            local safe,valid,reason=pcall(options.validate_input_snapshot,snapshot)
            if not safe or valid~=true then return nil,safe and reason or valid end
            assignments(0,true)
            if not self.assignments then return nil,self.assignments_error or "menu ownership unavailable" end
            for id,code in pairs(identities) do
                local actual=self.assignments[id]
                if not actual or actual.code~=code then return nil,"WeaponFlow binding ownership changed" end
            end
            return true
        end
        local valid,reason=validate()
        if not valid then return nil,reason end
        return {validate=validate}
    end
    local function resolve_native(raw)
        if type(raw)~="table" or type(raw.count)~="number" or type(raw.signature)~="string" then
            return nil,"invalid guarded menu binding result"
        end
        if raw.count==0 and raw.unbound==true then return {unbound=true,signature=raw.signature,binding_rows={}} end
        if type(raw.mappings)~="table" or raw.count<1 or raw.count>16 or #raw.mappings~=raw.count then
            return nil,"invalid guarded menu mapping count"
        end
        local rows={};local ffi=require("ffi")
        for _,mapping in ipairs(raw.mappings) do
            local vk=Bindings.native_vk(mapping)
            if type(mapping.trigger)~="number" or mapping.trigger%1~=0 or
               mapping.trigger<0 or mapping.trigger>0xffffffff then
                return nil,"invalid native trigger record"
            end
            if type(mapping.threshold_bits)~="number" or mapping.threshold_bits%1~=0 or
               mapping.threshold_bits<0 or mapping.threshold_bits>0xffffffff then return nil,"native trigger threshold unreadable" end
            local bits=ffi.new("uint32_t[1]",mapping.threshold_bits)
            local threshold=tonumber(ffi.cast("float *",bits)[0])
            if threshold~=threshold or threshold==math.huge or threshold==-math.huge then
                return nil,"invalid native trigger threshold"
            end
            rows[#rows+1]={device=mapping.device,button_id=mapping.button_id,vk=vk,
                input_kind=mapping.input_kind,device_index=mapping.device_index,combine=mapping.combine,
                identity=table.concat({tostring(mapping.device),tostring(mapping.device_index or 255),
                    tostring(mapping.input_kind or 4),tostring(mapping.button_id)},":"),
                trigger=mapping.trigger,threshold=threshold}
        end
        return {signature=raw.signature,binding_rows=rows}
    end
    local function in_device_range(api,kind,id)
        local count=type(api)=="table" and api[kind=="button" and "num_buttons" or "num_axes"]
        if type(count)~="function" then return false end
        local ok,value=pcall(count)
        return ok and type(value)=="number" and id>=0 and id<value and value<=4096
    end
    local function button_label(row,context)
        -- Presentation is best effort. Neither name API nor caption codecs
        -- participate in numeric mapping validation or action readiness.
        if type(context.button_label)=="function" then
            local ok,label=pcall(context.button_label,row)
            if ok and type(label)=="string" and label~="" and #label<=48 and not label:find("[%c]") then return label end
        end
        local safe,engine=pcall(get_engine)
        local device=row.device==3 and "Keyboard" or row.device==4 and "Mouse"
        local api=safe and type(engine)=="table" and engine[device]
        if type(api)=="table" and (row.input_kind==nil or row.input_kind==4) and type(api.button_name)=="function" and
           (Bindings.native_vk(row) or in_device_range(api,"button",row.button_id)) then
            local ok,label=pcall(api.button_name,row.button_id)
            if ok then return label end
        elseif type(api)=="table" and type(api.axis_name)=="function" and in_device_range(api,"axis",row.button_id) then
            local ok,label=pcall(api.axis_name,row.button_id)
            if ok then return label end
        end
    end
    local function physical_down(binding,context)
        -- Optional release/arming observation only: the game event below is
        -- the sole command trigger. Unknown inputs still use that event.
        for _,vk in ipairs(binding.vks) do if context.key_down(vk)==true then return true end end
        local safe,engine=pcall(get_engine)
        if not safe or type(engine)~="table" then return false end
        for _,row in ipairs(binding.bindings) do
            local name=row.device==3 and "Keyboard" or row.device==4 and "Mouse"
            local api=name and engine[name]
            if not row.vk and (row.input_kind==nil or row.input_kind==4) and
               type(api)=="table" and type(api.button)=="function" and in_device_range(api,"button",row.button_id) then
                local ok,value=pcall(api.button,row.button_id)
                if ok and type(value)=="number" and value>0 then return true end
            end
        end
        return false
    end

    local function describe(record,context)
        if not record.raw then return nil,record.read_error or "native mapping unreadable" end
        local resolved,why=resolve_native(record.raw)
        if not resolved then return nil,why end
        local description=Bindings.describe_native(resolved.binding_rows,function(row)return button_label(row,context)end)
        if record.observed~=record.raw.signature then record.event=nil;record.idle_released=nil end
        record.observed=record.raw.signature
        record.binding_rows=resolved.binding_rows
        record.description=description
        return description
    end
    local function initialize(name,record,context,result,time)
        local requested=self.pending_publication[name]==true
        local marker=context.default_state
        local rows=Bindings.defaults()[name]
        if not requested then
            -- A per-profile one-time marker protects deliberate unbinding.
            if not marker or #rows==0 then return true end
            local handled,why=marker:contains(name)
            if handled==nil then return nil,why end
            if handled then return true end
        end
        if type(context.gameplay_allowed)~="function" or context.gameplay_allowed()~=true then return true end
        if not record.raw or not record.description then return true end
        if not requested then
            local info,why=resolve_action(record.code,record.raw)
            if not info then return nil,why or "native action identity unavailable" end
            if (info.inherited_count or 0)>0 then return true end
            local config,why=context.get_input_config()
            if not config then return nil,why end
            local section=config[info.section]
            local explicit=type(section)=="table" and section[info.action]~=nil
            local previous=record.config_before_registration and record.config_before_registration[info.section]
            previous=type(previous)=="table" and previous[info.action]
            local preexisting_empty=record.new_assignment==true and not record.editor_observed and
                type(previous)=="table" and next(previous)==nil and
                type(section)=="table" and type(section[info.action])=="table" and next(section[info.action])==nil
            -- Preserve every loaded player mapping, including explicit None.
            -- An empty dormant action saved by MBM before this ID was first
            -- registered is not a WeaponFlow user override. Reused/unknown
            -- ownership and every nonempty/custom override still win.
            if explicit and not preexisting_empty or record.raw.count>0 then return marker:mark(name) end
        end
        if Bindings.matches_native_defaults(record.binding_rows,rows,context.resolve_key) then
            if marker then local marked,why=marker:mark(name);if not marked then return nil,why end end
            self.pending_publication[name]=nil;return true
        end
        if record.failed then return nil,record.failed end
        if type(replace_binding)~="function" then return nil,"owned default publisher unavailable" end
        local reserved=false
        local ok,outcome,why,detail=pcall(replace_binding,record.code,rows,function()
            if context.gameplay_allowed()~=true then return nil,"gameplay context changed before default publication" end
            local valid,why=context.validate_profile()
            if valid~=true then return nil,why end
            if not requested then
                if not marker or type(marker.begin)~="function" then return nil,"default reservation unavailable" end
                local marked,why=marker:begin(name)
                if not marked then return nil,why end
                reserved=true
            end
            return true
        end,record.raw.signature)
        if not ok or not outcome then
            if ok and type(detail)=="table" and detail.native_attempted==false then
                if reserved then
                    local cancelled,error_text=marker:cancel(name)
                    if not cancelled then record.failed=error_text;return nil,error_text end
                end
                -- Safe preflight/context failures have written no native data.
                -- Leave initialization pending for a later valid frame.
                return nil,why
            end
            -- Do not replay an uncertain one-time request. Native writer guards
            -- the complete owned payload and rolls back only its exact bytes.
            record.failed=tostring(ok and why or outcome)
            self.pending_publication[name]=nil
            return nil,record.failed
        end
        self.pending_publication[name]=nil
        record.raw,record.read_error=read_binding(record.code)
        local fresh,why=describe(record,context)
        if not fresh or not Bindings.matches_native_defaults(record.binding_rows,rows,context.resolve_key) then
            record.failed=why or "owned defaults readback differs";return nil,record.failed
        end
        if marker then
            local marked,why=marker:mark(name)
            if not marked then record.failed=why;return nil,why end
        end
        result.default_events=result.default_events or {}
        result.default_events[#result.default_events+1]=name.." default "..Bindings.encode(rows)
        return true
    end
    local function diagnose(result,name,record,binding,context)
        if context.diagnostics_enabled~=true then return end
        local why=binding.active and not binding.ready and binding.reason or binding.edge_ignored
        if not why then return end
        local raw=record.raw
        local identity=tostring(record.code)..":"..tostring(raw and raw.signature)..":"..tostring(why)
        if record.diagnostic_identity==identity then return end
        record.diagnostic_identity=identity
        record.diagnostic_count=(record.diagnostic_count or 0)+1
        if record.diagnostic_count>16 then return end
        local fields={"action="..name,"code="..tostring(record.code),"reason="..tostring(why)}
        if raw then
            fields[#fields+1]="count="..tostring(raw.count)
            for index,mapping in ipairs(raw.mappings or {}) do
                if index>16 then break end
                local bytes=type(mapping.raw)=="string" and mapping.raw:sub(1,20) or ""
                bytes=bytes:gsub(".",function(char)return string.format("%02X",char:byte())end)
                fields[#fields+1]=string.format("map%d={flags=%s,device=%s,kind=%s,index=%s,button=%s,trigger=%s,trigger_copy=%s,combine=%s,bytes=%s}",
                    index,tostring(mapping.flags),tostring(mapping.device),tostring(mapping.input_kind),
                    tostring(mapping.device_index),tostring(mapping.button_id),tostring(mapping.trigger),
                    tostring(mapping.trigger_flags),tostring(mapping.combine),bytes)
            end
        end
        result.diagnostics=result.diagnostics or {}
        result.diagnostics[#result.diagnostics+1]=table.concat(fields," ")
    end
    function self:poll(time,foreground,context)
        context=context or {}
        self.context=context
        self.card_label=label_card(context.card_label)
        self.refresh_card_label=context.refresh_card_label
        local result={}
        local good,menu=pcall(get_menu)
        if not good or not M.available(menu) then
            self.records={};self.menu=nil;self.cached=nil
            result.reason="Mod Bindings Menu v2.1 is required";return result
        end
        if menu~=self.menu then
            self.menu,self.records=menu,{}
            self.next_registration,self.next_assignments,self.next_editor_poll=0,0,0
            self.cached=nil
        end
        local open,value=pcall(editor_open)
        local editing=open and type(value)=="boolean" and value or nil
        if self.cached and time<(self.next_editor_poll or 0) and self.was_editing==editing then
            local copy={};for k,v in pairs(self.cached) do copy[k]=v end;return copy
        end
        local force=false
        if time>=self.next_registration then
            self.next_registration=time+2
            -- Capture ownership before registering: MBM registration can
            -- create/reassign the persistent native action immediately.
            local registering=false
            for _,name in ipairs(ORDER) do if not self.records[name] then registering=true;break end end
            if registering then assignments(time,true) end
            local previous=self.assignments
            local missing=self.assignments_error=="missing"
            local config
            if registering and type(context.get_input_config)=="function" then
                local ok,value=pcall(context.get_input_config)
                if ok and type(value)=="table" then config=value end
            end
            for _,name in ipairs(ORDER) do
                if not self.records[name] then
                    local row_label=function() return label(name) end
                    local ok,registered,why=pcall(menu.register_binding,IDS[name],row_label,nil,{category="WeaponFlow"})
                    if ok and registered==true then
                        self.records[name]={label=row_label,next_read=0,
                            new_assignment=missing or previous~=nil and previous[IDS[name]]==nil,
                            config_before_registration=config,editor_observed=editing==true}
                        force=true
                    else result.registration_error=tostring(ok and why or registered) end
                end
            end
        end
        assignments(time,force)
        local safe,ready=pcall(menu.ready)
        ready=safe and ready==true
        for _,name in ipairs(ORDER) do
            local record=self.records[name]
            if record and editing==true then record.editor_observed=true end
            if record and (wanted(name,context) or self.pending_publication[name]) then
                local assignment=self.assignments and self.assignments[IDS[name]]
                local reason
                if not assignment then reason=self.assignments_error or "menu action assignment is unknown"
                elseif not ready then reason="native actions are loading"
                else
                    if assignment.code~=record.code then
                        record.raw,record.observed,record.event,record.idle_released=nil,nil,nil,nil
                        record.code=assignment.code;record.next_read=0
                    end
                    local ok,raw,why
                    if record.raw and time<record.next_read and type(watch_binding)=="function" then
                        ok,raw,why=pcall(watch_binding,record.raw)
                    end
                    if not ok or not raw then
                        ok,raw,why=pcall(read_binding,assignment.code);record.next_read=time+0.5
                    end
                    record.raw,record.read_error=ok and raw or nil,ok and why or "guarded native mapping read failed"
                    local description;description,reason=describe(record,context)
                    if description then
                        local initialized,error_text=initialize(name,record,context,result,time)
                        if not initialized then
                            -- A marker/default write failure does not disable
                            -- an independently valid assignment already in game.
                            if record.default_error~=error_text then
                                result.default_events=result.default_events or {}
                                result.default_events[#result.default_events+1]=name.." default skipped: "..tostring(error_text)
                            end
                            record.default_error=error_text
                        end
                    end
                end
                record.read_error=reason
                local binding={active=true,ready=not reason,reason=reason}
                diagnose(result,name,record,binding,context)
                result[name]=binding
            end
        end
        result.available=true
        local statuses={}
        for _,name in ipairs(ORDER) do
            local binding=result[name]
            if binding then statuses[#statuses+1]=name.."="..(binding.ready and "game mapping" or tostring(binding.reason)) end
        end
        result.reason="Mod Bindings Menu v2.1: "..table.concat(statuses,"; ")
        self.next_editor_poll=time+0.1;self.was_editing=editing;self.cached={}
        for k,v in pairs(result) do if k~="default_events" and k~="diagnostics" then self.cached[k]=v end end
        return result
    end
    -- Metadata is cached separately. Only eligible game actions are queried
    -- each frame; descriptions and persisted mappings change on the slow path.
    function self:events(time,foreground,context)
        self.last_event_time=time
        local out={}
        local ok,menu=pcall(get_menu)
        local available=ok and M.available(menu) and menu==self.menu
        local ready=false
        if available then local safe,value=pcall(menu.ready);ready=safe and value==true end
        for _,name in ipairs(ORDER) do
            local record=self.records[name]
            local description=record and record.description or Bindings.describe_native(nil)
            local binding={}
            for key,value in pairs(description) do binding[key]=value end
            out[name]=binding
            local needs_card=name=="save" or name=="hud"
            local enabled=(name=="hud" and context.hud_enabled==true) or
                (name=="reset" and context.reset_enabled==true) or
                (name~="hud" and name~="reset" and context.presets_enabled==true)
            local assignment=self.assignments and self.assignments[IDS[name]]
            local observed=record and assignment and assignment.code==record.code and record.raw and not record.read_error
            if not enabled then
                binding.ready=false;binding.reason="feature disabled"
                binding.vks={};binding.groups={};binding.bindings={}
                if record then record.event=nil;record.idle_released=nil end
            elseif not available or not ready or not observed then
                binding.ready=false
                binding.reason=not available and "Mod Bindings Menu v2.1 is required" or
                    (record and record.read_error or "native game mappings are loading")
                if record then record.event=nil;record.idle_released=nil end
            elseif binding.ready then
                local physical=physical_down(binding,context)
                local allowed=foreground==true and context.allowed==true
                local eligible=not needs_card or context.card_held==true
                if not allowed or not eligible then
                    record.event=nil
                    -- A released button in uninterrupted gameplay may arm the
                    -- first card action. Context/focus loss discards that fact.
                    record.idle_released=allowed and not physical
                else
                    local safe,raw=false,nil
                    if type(read_event)=="function" then safe,raw=pcall(read_event,record.raw) end
                    if safe and raw and raw.signature==record.observed and type(raw.game_event)=="boolean" then
                        binding.signature=record.observed
                        local down=raw.game_event
                        local state=record.event
                        if not state then
                            state={down=not record.idle_released and down or false,
                                armed=record.idle_released==true or not physical and not down}
                            record.event=state;record.idle_released=nil
                        end
                        if not state.armed then
                            if not physical and not down then state.armed=true end
                        elseif time>=(record.suppressed_until or 0) then
                            binding.pressed=down and not state.down
                            binding.down=down
                        end
                        state.down=down
                    else
                        self.next_editor_poll=0;record.event=nil;record.idle_released=nil
                        binding.ready=false;binding.reason="game action or binding changed; reread pending"
                    end
                end
            end
        end
        return out
    end

    function self:reset(before_write)
        local ok,menu=pcall(get_menu)
        if not ok or not M.available(menu) then return nil,"Mod Bindings Menu v2.1 is required" end
        if type(before_write)~="function" then return nil,"reset backup callback required" end
        assignments(0,true)
        if not self.assignments then
            if self.assignments_error=="missing" then
                local ok,backed,why=pcall(before_write)
                if ok and backed==true then return {status="cleared",actions=0} end
                return nil,ok and why or backed
            end
            return nil,self.assignments_error or "menu assignments unavailable for reset"
        end
        local codes={}
        for _,name in ipairs(ORDER) do
            local value=self.assignments[IDS[name]]
            if value then codes[#codes+1]=value.code end
        end
        if #codes==0 then
            local ok,backed,why=pcall(before_write)
            if ok and backed==true then return {status="cleared",actions=0} end
            return nil,ok and why or backed
        end
        if type(clear_bindings)~="function" then return nil,"native menu binding reset unavailable" end
        return clear_bindings(codes,before_write)
    end
    return self
end
return M

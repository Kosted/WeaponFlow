-- Weapon Defaults: one gameplay implementation for release and diagnostics.
-- Native readers and persistence/input helpers are embedded by the builder.
if rawget(_G, "ConstantinWeaponModesTrial") then return rawget(_G, "ConstantinWeaponModesTrial") end
local build=assert(BuildConfig,"WeaponFlow build configuration required")
local diagnostics=build.diagnostics==true
local presets_enabled=build.presets~=false
local state = {version=build.version, flavor=build.flavor, status="starting", equips=0, actions=0}
rawset(_G, "ConstantinWeaponModesTrial", state)
local loader = rawget(_G, "CowboyBingusModLoader")
local previous_update = rawget(_G, "update")
local previous_shutdown = rawget(_G, "shutdown")
local session_log, latest_log
local release_log_bytes=0
local RELEASE_LOG_LIMIT=128*1024
local log_clock,started_at
local RELEASE_EVENTS={READY=true,INACTIVE=true,ERROR=true,SETTINGS_UNAVAILABLE=true,
    SETTINGS_FAILED=true,SAVED=true,CLEARED=true,SAVE_SKIP=true,SAVE_EMPTY=true,
    SAVE_FAILED=true,CLEAR_FAILED=true,SAVE_IGNORED=true,
    SAVE_INPUT=true,STOP=true,DEFER=true,SKIP=true,UI_UNAVAILABLE=true,WAIT=true,
    PRESET=true,PRESET_SKIP=true,
    HUD_READY=true,HUD_ERROR=true,HUD_SKIP=true,HUD_POSITION=true,HUD_SELECTION=true,
    SHUTDOWN_BEGIN=true,HUD_SHUTDOWN=true,SHUTDOWN_END=true,SHUTDOWN_ERROR=true,
    AUTO_PRESETS=true,AUTO_PRESETS_SKIP=true,AUTO_PRESETS_WAIT=true,AUTO_PRESETS_FAILED=true,
    PRESET_NORMALIZED=true,PRESET_RULE_SKIP=true,LIGHT_SAVED=true,LIGHT_WAIT=true,LIGHT_STOP=true,LIGHT_SKIP=true,LIGHT_ERROR=true,
    HELP_READY=true,HELP_ERROR=true,RESET=true,RESET_FAILED=true,RESET_SKIP=true,MOD_SETTINGS=true,
    MOD_BINDINGS=true,CLEAR_SKIP=true}
local function open_log(name)
    if not loader or type(loader.open_log)~="function" then return nil end
    local ok,file=pcall(loader.open_log,name)
    if ok then return file end
end
local function log(message)
    if not diagnostics and not RELEASE_EVENTS[message:match("^[A-Z_]+") or ""] then return end
    local stamp=log_clock and string.format(" t=%.3f",log_clock()-started_at) or ""
    local line = "[WeaponDefaultsNative] " .. message .. stamp
    -- Release keeps one bounded latest log; diagnostics preserve full separate
    -- sessions and the traditional latest file for development. No idle flush.
    if not diagnostics and release_log_bytes+#line+1>RELEASE_LOG_LIMIT then
        if latest_log then pcall(function() latest_log:close() end) end
        latest_log=open_log("WeaponDefaults.log")
        release_log_bytes=0
    end
    if diagnostics or not latest_log then print(line) end
    local function write(file)
        if file then pcall(function() file:write(line,"\n"); file:flush() end) end
    end
    write(session_log);write(latest_log)
    if not diagnostics then release_log_bytes=release_log_bytes+#line+1 end
end
local ffi = require("ffi")
local kernel, user32 = ffi.load("kernel32"), ffi.load("user32")
local function bind(library,name,declaration)
    local ok,value=pcall(function() return library[name] end)
    if not ok then ffi.cdef(declaration); value=library[name] end
    return value
end
local tick=bind(kernel,"GetTickCount64","unsigned long long GetTickCount64(void);")
local get_pid=bind(kernel,"GetCurrentProcessId","unsigned long GetCurrentProcessId(void);")
local get_foreground=bind(user32,"GetForegroundWindow","void *GetForegroundWindow(void);")
local get_window_pid=bind(user32,"GetWindowThreadProcessId","unsigned long GetWindowThreadProcessId(void *, unsigned long *);")
-- Other addons may declare DWORD as uint32_t (unsigned int). On Windows x64
-- both are 32 bits; use our exact pointer signature for our own output buffer.
get_window_pid=ffi.cast("unsigned long (*)(void *, unsigned long *)",get_window_pid)
local pid=tonumber(get_pid())
local pid_buffer=ffi.new("unsigned long[1]")
local function now() return tonumber(tick())/1000 end
log_clock,started_at=now,now()
local function foreground()
    pid_buffer[0]=0; get_window_pid(get_foreground(),pid_buffer)
    return tonumber(pid_buffer[0])==pid
end
if diagnostics then
    session_log=open_log("WeaponDefaultsNative-"..os.date("%Y%m%d-%H%M%S").."-"..pid..".log")
    latest_log=open_log("WeaponDefaultsNative.log")
else
    latest_log=open_log("WeaponDefaults.log")
end
if not loader or tonumber(loader.api)~=1 or type(previous_update)~="function" then
    log("INACTIVE: BSL API 1 and update callback required"); return state
end
if type(ModBindings)~="table" or not ModBindings.available(rawget(_G,"ModBindingsMenu")) then
    state.status="inactive: Mod Bindings Menu v2.1 required"
    log("INACTIVE: Mod Bindings Menu v2.1 required; enable its addon in Arsenal")
    if session_log then pcall(function() session_log:close() end);session_log=nil end
    if latest_log then pcall(function() latest_log:close() end);latest_log=nil end
    return state
end
Text.configure({font=HudFont})
local presented_labels={get=function(key) return Text.native(key,HudLabels.get(key)) end}
if rawget(_G,"ConstantinWeaponDefaultsVerified") or rawget(_G,"ConstantinRailgunDefaultUnsafe") then
    log("INACTIVE: another project setter is loaded; disable older Trial/standalone addons"); return state
end
local reader,reason=NativeReader.new()
if not reader then log("INACTIVE: "..tostring(reason)); return state end
Text.configure({language_provider=function() return NativeTextLanguage.read(reader) end})
local text_next_language=0
local function unhex(text)
    return (text:gsub("..",function(pair) return string.char(tonumber(pair,16)) end))
end
assert(WeaponModes.cycle.signature_hex==Flashlight.cycle.signature_hex,"native cycle signatures disagree")
local cycle_signature=unhex(WeaponModes.cycle.signature_hex)
local cycle_fn,cycle_base
local function invoke_cycle(snapshot,modes,direction)
    if not presets_enabled then return nil,"presets disabled in Arsenal" end
    local valid,why=reader:verify()
    if not valid then return nil,why end
    if reader.api.read(reader.game+WeaponModes.cycle.rva,#cycle_signature)~=cycle_signature then
        return nil,"native cycle code signature mismatch"
    end
    local checked,error_text=reader:transaction(function(read,ptr,lookup)
        local active=reader:guard_active(snapshot,read,ptr,lookup)
        if active.weapon_manager~=modes.weapon_manager or active.entity.eid~=modes.weapon_eid then
            error("mode manager/active object changed before cycle",0)
        end
        return {ok=true}
    end, "before-native-cycle")
    if not checked then return nil,error_text end
    if cycle_base~=reader.game then
        cycle_fn=ffi.cast("void (__fastcall *)(void *, unsigned int, unsigned int)",
                          reader.game+WeaponModes.cycle.rva)
        cycle_base=reader.game
    end
    -- The game's own general weapon-function action changes the actual modes.
    -- UI cache invalidation below mirrors the UI caller's separate dirty flag.
    cycle_fn(ffi.cast("void *",modes.weapon_manager),modes.weapon_eid,direction.action_enum)
    return true
end

local input,store,hud_profile
local initialized,result,failure=pcall(DefaultsInput.new,{native_reader=reader})
if initialized then input=result else failure=result end
if not input then log("SETTINGS_UNAVAILABLE input/profile discovery: "..tostring(failure))
elseif presets_enabled then
    local opened,value,why=pcall(DefaultsStore.open,input.profile_id)
    if opened then store=value else why=value end
    if not store then log("SETTINGS_UNAVAILABLE "..tostring(why))
    else
        if type(DefaultPresets)=="string" then
            local installed,error_text=store:import_presets(DefaultPresets,function()
                input:refresh(now())
                return input.profile_valid==true and input.profile_id==store.profile_id and not input.settings_reason
            end,true)
            if not installed then log("SETTINGS_UNAVAILABLE bundled presets: "..tostring(error_text));store=nil end
        end
    end
    if store then
        state.settings_path=store.path
        log("SETTINGS path="..store.path.." input="..tostring(input.input_path))
    end
end
if input and build.hud then
    if store then hud_profile=store
    else
        local opened,value,why=pcall(DefaultsStore.context,input.profile_id)
        if opened then hud_profile=value else why=value end
        if not hud_profile then log("HUD_ERROR profile context: "..tostring(why)) end
    end
end
local settings=store or hud_profile
local presets_active=presets_enabled and store~=nil
local hud,hud_layout,hud_problem,hud_frame_valid,hud_move_frame
local hud_next_read,hud_identity,hud_last_allowed=0,nil,false
local hud_direction_problem={}
local help,help_problem,help_frame_valid,help_latch,help_latch_kind,help_identity,help_kind
local help_next_read,help_content_valid=0,false
local presets_transfer=PresetsTransfer.new()
if settings and (presets_active or build.hud) and type(previous_shutdown)=="function" then
    local ok,value,why=pcall(HelpHud.new,{font=HudFont,icons=WeaponHudIcons,log=log})
    if ok then help=value else why=value end
    log(help and "HELP_READY fixed contextual text panels" or ("HELP_ERROR initialization: "..tostring(why)))
end
local function help_call(method,...)
    if not help then return end
    local ok,value,why=pcall(help[method],help,...)
    if not ok then
        log("HELP_ERROR disabled after presentation failure: "..tostring(value))
        pcall(help.hide,help);help=nil
        return nil,"presentation failed"
    end
    if why and why~=help_problem then log("HELP_ERROR "..tostring(why));help_problem=why end
    return value,why
end
if build.hud and hud_profile then
    local ok,value,why=pcall(function()
        if type(previous_shutdown)~="function" then return nil,"engine shutdown callback unavailable" end
        local layout,err=HudLayout.new(hud_profile,log)
        if not layout then return nil,err end
        hud_layout=layout
        return WeaponHud.new({layout=layout,icons=WeaponHudIcons,font=HudFont,log=log,display=layout.display})
    end)
    if ok then hud=value else why=value end
    log(hud and ("HUD_READY card+HUD binding opens help; later presses select property/hidden; "..
        "card+arrows moves indicator while property help is open; display="..hud.display) or
        ("HUD_ERROR initialization: "..tostring(why)))
end
local function hud_call(method,...)
    if not hud then return end
    local ok,value,why=pcall(hud[method],hud,...)
    if not ok then
        log("HUD_ERROR disabled after presentation failure: "..tostring(value))
        pcall(hud.hide,hud);hud=nil
        return nil,"presentation failed: "..tostring(value)
    elseif why then
        if why~=hud_problem then log("HUD_ERROR "..tostring(why));hud_problem=why end
        if method=="render" then pcall(hud.hide,hud) end
    end
    return value,why
end
local SIDES={"left","right","up","down"}
local function equal(a,b) return type(a)=="number" and type(b)=="number" and math.abs(a-b)<0.001 end
local function member(values,value)
    for i,v in ipairs(values or {}) do if equal(v,value) then return i end end
end
local function same_choices(first,second)
    if #first~=#second then return false end
    for i,value in ipairs(first) do if not equal(value,second[i]) then return false end end
    return true
end
local function key(snapshot)
    return snapshot.avatar_bytes:sub(1,20)..snapshot.active_weapon.bytes:sub(1,20)
end
local function display_eid(snapshot)
    return snapshot.active_weapon.display_eid or snapshot.active_weapon.entity.eid
end
local function inspect(snapshot,targets,hud_only,include_light)
    local modes,why=WeaponModes.inspect(reader,snapshot)
    if not modes then return nil,why end
    local extra={}
    local needs_primary=false
    if not hud_only then
        for _,side in ipairs(SIDES) do
            local dir=modes.directions[side]
            if (not targets or targets[side]) and dir and dir.present and dir.kind=="firemode" and
               dir.action_enum==3 and dir.inactive then needs_primary=true end
        end
    end
    for _,side in ipairs(SIDES) do
        local dir=modes.directions[side]
        local wanted=(not targets or targets[side]~=nil) and
            (not hud_only or hud_only==side or (hud_only==true and dir and dir.action_enum==8))
        if needs_primary and dir and dir.action_enum==11 then wanted=true end
        if wanted and dir and (dir.action_enum==6 or dir.action_enum==8 or dir.action_enum==11) and dir.present then
            local action=dir.action_enum
            if not extra[action] then
                local helper=action==8 and ProgrammableAmmo or (action==11 and SecondaryFire or LaserGuide)
                local value,reason=helper.inspect(reader,snapshot,modes)
                if value then
                    for _,name in ipairs(SIDES) do
                        if not value.functions or value.functions[name]~=modes.functions[name] then
                            value,reason=nil,"weapon functions changed between direction inspections"
                            break
                        end
                    end
                end
                extra[action]={value=value,reason=reason}
            end
            local value=extra[action].value
            if value then
                for name,field in pairs(value) do
                    if name~="functions" and name~="function_bytes" and name~="directions" then dir[name]=field end
                end
                dir.reason=value.reason
            else
                dir.readable,dir.cycle_supported=false,false
                dir.reason=extra[action].reason or "native setting state unavailable"
            end
        elseif include_light and wanted and dir and dir.action_enum==5 and dir.present then
            local light,light_error=Flashlight.inspect(reader,snapshot)
            if light and light.present then
                dir.kind,dir.current,dir.choices="flashlight",light.selected,light.offered_values
                dir.readable,dir.cycle_supported,dir.reason=true,true,nil
                dir.slot,dir.slot_values=light.selected,light.offered_values
                dir.module_bytes=light.module_bytes
                dir.module_eid=light.module_entity.eid
            else
                dir.readable,dir.cycle_supported=false,false
                if light and light.present==false then dir.present=false
                else dir.presence_unknown=true end
                dir.reason=light_error or (light and light.reason) or "flashlight state unavailable"
            end
        end
    end
    -- The normal kind3 action returns from secondary fire before cycling any
    -- ordinary slot. Keep the selected ordinary value unreadable, but expose
    -- this separately verified transition for applying an existing Firemode.
    -- This does not create a saved secondary selector or change None fields.
    if needs_primary and extra[11] and extra[11].value then
        local secondary=extra[11].value
        local activation=secondary.primary_activation
        local selector_side
        for _,side in ipairs(SIDES) do
            if modes.functions[side]==11 then
                if selector_side then selector_side=nil;break end
                selector_side=side
            end
        end
        if selector_side and secondary.present and secondary.readable and secondary.current==1 and
           secondary.cycle_supported and activation and activation.action_enum==3 and activation.before==8 then
            for _,side in ipairs(SIDES) do
                local dir=modes.directions[side]
                if dir and dir.present and dir.action_enum==3 and dir.kind=="firemode" and dir.inactive and
                   dir.slot==activation.ordinary_slot and dir.slot_values and
                   dir.slot_values[dir.slot+1]==activation.next_value and member(dir.choices,activation.next_value) then
                    dir.primary_activation={action_enum=3,before=8,next_value=activation.next_value,
                        ordinary_slot=activation.ordinary_slot,selector_side=selector_side}
                end
            end
        end
    end
    return modes
end
local function saved_secondary(modes,targets)
    local found
    for _,side in ipairs(SIDES) do
        local dir,target=modes.directions[side],targets and targets[side]
        if target and target.kind=="secondary_fire" and dir and dir.present and
           dir.kind=="secondary_fire" and dir.action_enum==11 then
            if target.value==1 then return 1 end
            found=target.value
        end
    end
    return found
end
local function primary_activation(modes,targets,side)
    local dir=modes.directions[side]
    local target=targets and targets[side]
    -- An explicit selector follows its own existing action/readback path.
    -- Never use Firemode to retry or override an uncertain selector action.
    if saved_secondary(modes,targets)~=nil or not target or target.kind~="firemode" or
       not dir or dir.kind~="firemode" or dir.action_enum~=3 or not dir.present or not dir.inactive or
       not member(dir.choices,target.value) then return nil end
    return dir.primary_activation
end
local function readback_matches(dir,expected)
    return dir and dir.readable and dir.action_enum==expected.action and
        dir.module_bytes==expected.module_bytes and equal(dir.current,expected.next_value) and
        (not expected.primary_activation or (dir.safety_override==0 and dir.slot==expected.ordinary_slot))
end
local function describe(modes)
    local result={}
    for _,side in ipairs(SIDES) do
        local dir=modes.directions[side]
        local choices={}
        for _,value in ipairs(dir and dir.choices or {}) do choices[#choices+1]=tostring(value) end
        result[#result+1]=side.."={type="..tostring(dir and dir.action_enum)..
            ",value="..tostring(dir and dir.current)..",choices="..table.concat(choices,"/")..
            ",native_slot="..tostring(dir and dir.slot)..
            ",effective_rpm="..tostring(dir and dir.effective_rpm)..
            ",reason="..tostring(dir and dir.reason).."}"
    end
    return table.concat(result," ")
end
local baseline,last_key,job,transition_seen,after_pass,hand_context
local light_controller
local preset_cursor,pending_preset=1,nil
local temporary_departure,last_context_problem
local grenade_input_status,grenade_input_sequence=nil,0
local function observe_grenade_input(controls)
    if not diagnostics or not controls then return end
    if controls.grenade_reason or controls.grenade_label then
        local status=tostring(controls.grenade_label).."|"..tostring(controls.grenade_reason)
        if status~=grenade_input_status then
            grenade_input_status=status
            log("GRENADE_INPUT_STATUS binding="..tostring(controls.grenade_label)..
                " source=thread_key_state observation_only=true reason="..tostring(controls.grenade_reason))
        end
    end
    if controls.grenade_pressed then
        grenade_input_sequence=grenade_input_sequence+1
        -- This is only the message-queue key state. Existing HAND/UTILITY_RETURN
        -- and CALLED events provide native observations after this timestamp;
        -- neither a key edge nor absence of a HAND row proves a completed throw.
        log("GRENADE_INPUT sequence="..grenade_input_sequence.." binding="..tostring(controls.grenade_label)..
            " source=thread_key_state observation_only=true last_observed_native="..
            tostring(hand_context and hand_context.selection_eid).." last_observed_category="..
            tostring(hand_context and hand_context.candidate_kind).." pending_mode_job="..
            tostring(job and job.cause).." actions_total="..state.actions)
    end
end
local next_resolve,next_job=0,0
local last_problem
local last_watch_problem
local next_problem_log=0
local function problem(message)
    if last_problem~=message then
        if diagnostics then log("WAIT "..tostring(message));last_problem=message
        elseif message=="not in mission" or message=="game modules unavailable" then last_problem=message
        elseif now()>=next_problem_log then
            log("WAIT "..tostring(message));next_problem_log=now()+5;last_problem=message
        end
    end
end
local function application_job(snapshot,time,preset,profile,cause)
    after_pass=nil
    if not presets_active then job=nil;return end
    if not diagnostics and (not profile or not next(profile.targets)) then job=nil;return end
    -- Secondary fire changes whether ordinary Firemode is active. Resolve the
    -- saved selector first regardless of which card direction contains it.
    local order={}
    for _,secondary in ipairs({true,false}) do
        for _,side in ipairs(SIDES) do
            local target=profile and profile.targets[side]
            if (target~=nil and target.kind=="secondary_fire")==secondary then order[#order+1]=side end
        end
    end
    job={key=key(snapshot),profile=profile,preset=preset,cause=cause,started=time,deadline=time+8,order=order,
         ready=time+(cause=="equip" and 0.10 or 0),side_index=1,attempts={},primary_attempted={},done={},retry={},
         problems={},seq=state.equips}
end
local function start_job(snapshot,time)
    help_latch=nil;help_latch_kind=nil;help_identity=nil;help_next_read=0
    after_pass=nil
    if job then log("CANCEL equip="..job.seq.." reason=actual active identity changed") end
    state.equips=state.equips+1
    preset_cursor,pending_preset=1,nil
    state.preset=1
    if light_controller then light_controller:equip(key(snapshot),state.equips,time) end
    local e=snapshot.active_weapon.entity
    local profile
    if presets_active then
        local loaded,why=store:reload()
        if loaded then
            -- Unknown weapons are registered with None. Initial preferences
            -- come from the portable bundled pack, never observed mode order.
            local ensured,err=store:ensure(e.resource_hex_le)
            if not ensured then why=err else profile,why=store:get(e.resource_hex_le,1) end
        end
        if not loaded or why then
            log("SETTINGS_FAILED ensure resourceLE="..e.resource_hex_le.." reason="..tostring(why))
        end
    end
    if diagnostics then log(string.format("EQUIP #%d native=%s network=%s resourceLE=%s profile=%s reads=%s bytes=%s",
        state.equips,tostring(e.eid),tostring(e.network_object_id),e.resource_hex_le,
        profile and "player file" or "settings unavailable",tostring(snapshot.read_calls),tostring(snapshot.read_bytes))) end
    application_job(snapshot,time,1,profile,"equip")
end
local function preset_input_allowed(snapshot)
    local result,why=PresetInputGate.inspect(reader,snapshot)
    if not result or not result.allowed then return nil,why or (result and result.reason) or "gameplay input unavailable" end
    return true
end
local function preset_limit(modes)
    local plan,why=DefaultsCapture.single_setting(modes)
    if not plan then return nil,why end
    return plan.qualified and plan.count==2 and 2 or 3,plan
end
local function present_help_impl(snapshot,time,controls)
    if not help or not controls or not controls.held_reload then return end
    local identity=key(snapshot)
    local kind=help_latch==identity and
        ((presets_active and help_latch_kind=="presets" and "presets") or
         (hud and help_latch_kind=="property" and "property")) or nil
    if not kind then help_kind=nil;help_content_valid=false;help_next_read=0;return end
    local allowed=preset_input_allowed(snapshot)
    if not allowed then help_latch=nil;help_latch_kind=nil;return end
    local card=WeaponUI.inspect(reader,snapshot)
    if not card or card.hidden or card.cached_eid~=snapshot.active_weapon.entity.eid or
       card.display_eid~=display_eid(snapshot) then help_latch=nil;help_latch_kind=nil;return end
    if help_identity~=identity or help_kind~=kind then
        help_identity,help_kind,help_next_read=identity,kind,0
        help_content_valid=false
    end
    if controls.save_preset or controls.hud_select_pressed or controls.pressed or controls.last_pressed_changed then help_next_read=0 end
    if time>=help_next_read then
        help_next_read=time+0.10
        help_content_valid=false
        local modes,why=inspect(snapshot)
        if not modes then return end
        local ammo={}
        for _,side in ipairs(SIDES) do
            local dir=modes.directions[side]
            if dir and dir.present and dir.kind=="programmable_ammo" then
                local labels,why=NativeHudIcons.ammo_labels(reader,snapshot,modes,presented_labels)
                -- Missing localization is a valid partial map; nil is a hard
                -- native transaction/identity failure and invalidates this frame.
                if not labels then
                    if help_problem~=why then log("HELP_ERROR ammunition labels: "..tostring(why));help_problem=why end
                    return
                end
                ammo=labels;break
            end
        end
        for _,side in ipairs(SIDES) do
            local dir=modes.directions[side]
            if dir and dir.present and dir.kind=="secondary_fire" and dir.label_keys then
                ammo.secondary_fire={}
                for value=0,1 do
                    local id=dir.label_keys[value]
                    if id then ammo.secondary_fire[value]=presented_labels.get(id) end
                end
                break
            end
        end
        for _,side in ipairs(SIDES) do
            local dir=modes.directions[side]
            if dir and dir.present and dir.readable and dir.kind=="binary_10" then
                ammo.binary_10={}
                for value=0,1 do
                    ammo.binary_10[value]=Text.hud(NativeHudIcons.binary10_caption(dir.icon_hashes and dir.icon_hashes[value]),
                        {value=value+1})
                end
                break
            end
        end
        local lines
        if kind=="presets" then
            local limit,limit_error=preset_limit(modes)
            if not limit then
                if help_problem~=limit_error then log("HELP_ERROR preset capabilities: "..tostring(limit_error));help_problem=limit_error end
                return
            end
            local presets,err=store:get_presets(snapshot.active_weapon.entity.resource_hex_le)
            if not presets and err~="not_found" then return end
            local choices,choice_error=NativeHudIcons.choice_icons(reader,snapshot,modes,
                {weapon_modes=WeaponModes,secondary_fire=SecondaryFire})
            if not choices then
                if help_problem~=choice_error then log("HELP_ERROR preset icons: "..tostring(choice_error));help_problem=choice_error end
                return
            end
            lines=HelpModel.presets(presets,modes,ammo,controls,limit,choices)
        else
            local selected,err=hud_call("selection",snapshot.active_weapon.entity.resource_hex_le)
            if err then return end
            controls.hud_display=hud.display
            lines=HelpModel.property(modes,ammo,selected,controls)
        end
        local ready=help_call("set",lines)
        if not ready then return end
        help_content_valid=true
    end
    if not help_content_valid then return end
    help_frame_valid=true
    local _,why=help_call("render",time)
    if why then help_frame_valid=false end
end
local function present_help(snapshot,time,controls)
    local ok,why=pcall(present_help_impl,snapshot,time,controls)
    if not ok then
        if help_problem~=why then log("HELP_ERROR "..tostring(why));help_problem=why end
        help_frame_valid=false
    end
end
local function present_hud_impl(snapshot,time)
    if not hud then return end
    hud_frame_valid=true
    local identity=key(snapshot)
    if identity~=hud_identity then
        hud_identity=identity;hud_next_read=0;hud_last_allowed=false;hud_call("hide")
    end
    if time>=hud_next_read then
        hud_next_read=time+0.10
        local allowed,why=preset_input_allowed(snapshot)
        hud_last_allowed=allowed==true
        if not allowed then hud_call("hide");return end
        local selected,selection_error=hud_call("selection",snapshot.active_weapon.entity.resource_hex_le)
        if selection_error then hud_call("hide");return end
        if selected=="None" then
            hud_call("set",{directions={}},{directions={}},selected)
            hud_call("render",time);return
        end
        local modes,error_text=inspect(snapshot,nil,selected or true)
        if not modes then
            hud_call("hide")
            if hud_problem~=error_text then log("HUD_SKIP "..tostring(error_text));hud_problem=error_text end
            return
        end
        if selected and modes.directions[selected] and modes.directions[selected].action_enum==5 then
            hud_call("set",{directions={}},{directions={}},selected)
            hud_call("render",time);return
        end
        local icons,icon_error=NativeHudIcons.inspect(reader,snapshot,modes,
            {weapon_modes=WeaponModes,laser_guide=LaserGuide,secondary_fire=SecondaryFire,
             labels=hud.display~="icon" and presented_labels or nil},selected)
        if not icons then
            hud_call("hide")
            if hud_problem~=icon_error then log("HUD_SKIP "..tostring(icon_error));hud_problem=icon_error end
            return
        end
        for _,side in ipairs(SIDES) do
            local direction=icons.directions[side]
            local why=direction and direction.reason
            if why and hud_direction_problem[side]~=why then
                log("HUD_SKIP side="..side.." reason="..why)
            end
            hud_direction_problem[side]=why
        end
        hud_call("set",modes,icons,selected)
    end
    if hud_last_allowed then hud_call("render",time) end
end
local function present_hud(snapshot,time)
    local ok,why=pcall(present_hud_impl,snapshot,time)
    if not ok then
        log("HUD_ERROR disabled after presentation read failure: "..tostring(why))
        hud_call("hide");hud=nil
    end
end
local function invalidate_card(snapshot,seq,side,refresh_selection)
    if refresh_selection then
        local fresh,why=reader:active_weapon()
        if not fresh or key(fresh)~=key(snapshot) then
            log("UI_UNAVAILABLE equip="..seq.." side="..side.." reason="..tostring(why or "weapon changed after secondary-fire cycle"))
            return
        end
        snapshot=fresh
    end
    local ok,result,why=pcall(WeaponUI.invalidate,reader,snapshot)
    if not ok then why,result=tostring(result),nil end
    if result then
        if diagnostics then log("UI equip="..seq.." side="..side.." status="..result.status..
            " hidden="..tostring(result.hidden).." dirty="..tostring(result.dirty)..
            " cached="..result.cached_eid.." display="..result.display_eid) end
    else
        -- UI failures never replay the successful mode cycle or stop unrelated
        -- directions. The current game modes still receive their own readback.
        log("UI_UNAVAILABLE equip="..seq.." side="..side.." reason="..tostring(why))
    end
end
local function rebuild_light_controller()
    if light_controller then light_controller:reset(true) end
    light_controller=nil
    if not presets_active then return end
    light_controller=GlobalFlashlight.new({
        log=log,
        load=function()
            local ok,why=store:reload()
            if not ok then return nil,why end
            return store:get_flashlight()
        end,
        save=function(value) return store:set_flashlight(value) end,
        read=function(snapshot,previous)
            if previous and previous.present and type(Flashlight.watch)=="function" then
                local value=Flashlight.watch(reader,snapshot,previous)
                if value then return value end
            end
            return Flashlight.inspect(reader,snapshot)
        end,
        apply=function(snapshot,observed,next_value,sequence)
            -- A cached observation never authorizes a call. Resolve the real
            -- function and attachment again immediately before the native path.
            local modes,why=WeaponModes.inspect(reader,snapshot)
            if not modes then return nil,why end
            local side
            for _,name in ipairs(SIDES) do
                local dir=modes.directions[name]
                if dir and dir.present and dir.action_enum==5 and modes.functions[name]==5 then
                    if side then return nil,"multiple flashlight functions" end
                    side=name
                end
            end
            if not side then return nil,"current weapon has no flashlight function" end
            local fresh,error_text=Flashlight.inspect(reader,snapshot)
            if not fresh or not fresh.present then return nil,error_text or "flashlight absent" end
            if fresh.module_bytes~=observed.module_bytes or fresh.selected~=observed.selected or
               (fresh.selected+1)%3~=next_value then return nil,"flashlight changed before action" end
            local called,call_error=invoke_cycle(snapshot,modes,{action_enum=5})
            if not called then return nil,call_error end
            state.actions=state.actions+1
            pcall(invalidate_card,snapshot,sequence,side)
            return true
        end,
    })
end
rebuild_light_controller()
local function step_light(snapshot,time,active_window)
    if not light_controller then return end
    local ok,why=pcall(light_controller.step,light_controller,snapshot,key(snapshot),time,active_window)
    if not ok then
        -- Do not let an uncertain flashlight action affect other directions,
        -- or learn a late result as a new player preference.
        light_controller:reset(true);light_controller=nil
        log("LIGHT_ERROR disabled for this session: "..tostring(why))
    end
end
local function observe_after_pass(snapshot,time)
    if not diagnostics then return end
    if not after_pass then return end
    if key(snapshot)~=after_pass.key or time>after_pass.deadline then after_pass=nil; return end
    if time<after_pass.next then return end
    local modes,why=inspect(snapshot,nil,nil,true)
    log("POST equip="..after_pass.seq.." preset="..after_pass.preset.." native="..snapshot.active_weapon.entity.eid..
        " elapsed="..string.format("%.3f",time-after_pass.finished)..
        " observation_only=true "..(modes and describe(modes) or ("unreadable="..tostring(why))))
    after_pass.remaining=after_pass.remaining-1
    after_pass.next=time+0.50
    if after_pass.remaining==0 then after_pass=nil end
end
local function step_job(snapshot,time)
    if not presets_active then job=nil;pending_preset=nil;return end
    if not job or time<job.ready or time<next_job or not foreground() then return end
    next_job=time+0.06
    if key(snapshot)~=job.key then job=nil;pending_preset=nil;return end
    if job.cause=="preset" then
        local allowed,why=preset_input_allowed(snapshot)
        if not allowed then log("PRESET_SKIP reason="..tostring(why));job=nil;pending_preset=nil;return end
    end
    if time>job.deadline then log("STOP equip="..job.seq.." reason=read/verification deadline");job=nil;pending_preset=nil;return end
    local modes,why=inspect(snapshot,not diagnostics and job.profile and job.profile.targets or nil)
    if not modes then problem("mode read: "..tostring(why)); return end
    if diagnostics and not job.logged then
        log("STATE equip="..job.seq.." preset="..job.preset.." cause="..job.cause.." "..describe(modes));job.logged=true
    end
    if not job.profile then job=nil; return end
    local readback_failed=false
    if job.awaiting then
        local expected=job.awaiting
        local dir=modes.directions[expected.side]
        if not dir or not dir.readable then
            if time<expected.deadline then return end
            log("STOP equip="..job.seq.." side="..expected.side.." reason=action outcome unreadable; no repeat")
            job.done[expected.side]=true
            job.awaiting=nil
            readback_failed=true
        elseif dir.action_enum~=expected.action or dir.module_bytes~=expected.module_bytes then
            log("STOP side="..expected.side.." reason=module/function changed during action")
            job.done[expected.side]=true; job.awaiting=nil
            readback_failed=true
        elseif readback_matches(dir,expected) then
            if diagnostics then log("VERIFIED equip="..job.seq.." preset="..job.preset.." side="..expected.side.." native="..modes.weapon_eid..
                " before="..expected.before.." after="..dir.current) end
            job.awaiting=nil
        elseif time<expected.deadline and equal(dir.current,expected.before) then return
        else
            log("STOP equip="..job.seq.." side="..expected.side.." expected="..expected.next_value..
                " actual="..tostring(dir.current).." reason=unexpected/no transition")
            job.done[expected.side]=true; job.awaiting=nil
            readback_failed=true
        end
    end
    -- A new request waits for the already-issued native action's readback.
    -- An uncertain outcome cancels the queued replacement instead of retrying.
    if job.halt_after_readback and not job.awaiting then
        if readback_failed then pending_preset=nil end
        job=nil;return
    end
    while job.side_index<=#job.order do
        local side=job.order[job.side_index]
        local target=job.profile.targets[side]
        local dir=modes.directions[side]
        local activation=primary_activation(modes,job.profile.targets,side)
        local secondary_pending=false
        if target and target.kind=="firemode" then
            for _,other in ipairs(job.order) do
                local selector=job.profile.targets[other]
                if selector and selector.kind=="secondary_fire" and not job.done[other] then secondary_pending=true end
            end
        end
        local skip
        if job.done[side] then skip="finished"
        elseif job.retry[side] and time<job.retry[side] then skip="deferred"
        elseif not target then skip="None: no saved default"
        elseif not dir or not dir.present then skip="setting absent on current instance"
        elseif dir.kind~=target.kind then skip="offered function differs from saved setting"
        elseif secondary_pending then skip="deferred"
        elseif target.kind=="firemode" and saved_secondary(modes,job.profile.targets)==1 then
            skip="ordinary fire mode inactive in the saved secondary preset"
        elseif dir.inactive and not member(dir.choices,target.value) then skip="saved value not offered by current modules"
        elseif dir.inactive and saved_secondary(modes,job.profile.targets)~=nil then
            skip="ordinary fire mode inactive after saved selector action"
        elseif dir.inactive and job.primary_attempted[side] then skip="primary activation already attempted; no repeat"
        elseif dir.inactive and not activation then
            local issue="primary activation dependency unavailable"
            if job.problems[side]~=issue then
                log("DEFER equip="..job.seq.." side="..side.." reason="..issue);job.problems[side]=issue
            end
            job.retry[side]=time+0.25;skip="deferred"
        elseif activation then -- Separate native return; ordinary slot does not advance.
        elseif not dir.readable then
            local issue=tostring(dir.reason)
            if job.problems[side]~=issue then
                log("DEFER equip="..job.seq.." side="..side.." reason="..issue); job.problems[side]=issue
            end
            job.retry[side]=time+0.25; skip="deferred"
        elseif not member(dir.choices,target.value) then skip="saved value not offered by current modules"
        elseif equal(dir.current,target.value) then skip="already target "..target.value
        elseif dir.cycle_pending then
            local issue=tostring(dir.reason or "native action not yet ready")
            if job.problems[side]~=issue then
                log("DEFER equip="..job.seq.." side="..side.." reason="..issue); job.problems[side]=issue
            end
            job.retry[side]=time+0.25; skip="deferred"
        elseif not dir.cycle_supported then skip=dir.reason or "cycle not verified for these choices"
        end
        if skip then
            if target and skip~="finished" and skip~="deferred" and
               (diagnostics or skip~="already target "..target.value) then
                log("SKIP equip="..job.seq.." side="..side.." reason="..skip)
            end
            if skip~="deferred" then job.done[side]=true end
            job.side_index=job.side_index+1
        else
            local index=not activation and member(dir.choices,dir.current)
            local attempts=job.attempts[side] or 0
            if not activation and (not index or attempts>=#dir.choices-1) then
                log("STOP equip="..job.seq.." side="..side.." reason=current value/cycle bound invalid")
                job.done[side]=true; job.side_index=job.side_index+1; return
            end
            -- Fresh re-read immediately before every call; do not act on values
            -- remembered from the preceding frame or another instance.
            local fresh,failure=inspect(snapshot,not diagnostics and job.profile.targets or nil)
            if not fresh then problem("before cycle: "..tostring(failure)); return end
            local current=fresh.directions[side]
            local fresh_activation=activation and primary_activation(fresh,job.profile.targets,side)
            if not current or (activation and not fresh_activation) or (not activation and not current.readable) then
                job.retry[side]=time+0.25; job.side_index=job.side_index+1; return
            end
            local transition_matches=activation and fresh_activation.before==activation.before and
                fresh_activation.next_value==activation.next_value and fresh_activation.ordinary_slot==activation.ordinary_slot and
                fresh_activation.selector_side==activation.selector_side
            if (activation and not transition_matches) or
               (not activation and (not current.cycle_supported or not equal(current.current,dir.current))) or
               current.action_enum~=dir.action_enum or current.module_bytes~=dir.module_bytes or
               not same_choices(current.choices,dir.choices) then
                log("STOP equip="..job.seq.." side="..side.." reason=setting changed before action")
                job.done[side]=true; job.side_index=job.side_index+1; return
            end
            local before=activation and activation.before or dir.current
            local expected=activation and activation.next_value or dir.choices[index%#dir.choices+1]
            if diagnostics then log("CYCLE equip="..job.seq.." preset="..job.preset.." native="..fresh.weapon_eid.." side="..side..
                " action="..dir.action_enum.." before="..before.." next="..expected.." target="..target.value..
                (activation and " primary_activation=true" or "")) end
            local called,call_error=invoke_cycle(snapshot,fresh,current)
            if not called then log("STOP reason="..tostring(call_error));job=nil;pending_preset=nil;return end
            if diagnostics then log("CALLED equip="..job.seq.." preset="..job.preset.." native="..fresh.weapon_eid.." side="..side.." action="..current.action_enum) end
            invalidate_card(snapshot,job.seq,side,current.action_enum==11 or activation~=nil)
            state.actions=state.actions+1
            if activation then job.primary_attempted[side]=true else job.attempts[side]=attempts+1 end
            job.awaiting={side=side,before=before,next_value=expected,action=dir.action_enum,
                          primary_activation=activation~=nil,ordinary_slot=activation and activation.ordinary_slot,
                          module_bytes=dir.module_bytes,deadline=time+0.50}
            return
        end
    end
    for _,side in ipairs(SIDES) do
        if job.profile.targets[side] and not job.done[side] then
            job.side_index=1; next_job=time+0.15; return
        end
    end
    if diagnostics then log("END equip="..job.seq.." preset="..job.preset.." native="..modes.weapon_eid.." application pass finished; see per-direction results") end
    -- Three bounded read-only observations distinguish an immediate VERIFIED
    -- from a later value change. They never reapply a mode or infer its cause.
    if diagnostics then
        after_pass={key=job.key,seq=job.seq,preset=job.preset,finished=time,next=time+0.25,
                    deadline=time+2,remaining=3}
    end
    job=nil
end
local function cancel_weapon_commands()
    if input and type(input.cancel_weapon_events)=="function" then input:cancel_weapon_events() end
    pending_preset=nil
end
local menu_state_ready,menu_state_next,menu_state_problem=false,0,nil
local function ensure_menu_file(time)
    if menu_state_ready or time<menu_state_next or not input or type(input.ensure_menu_state)~="function" then return end
    menu_state_next=time+2
    local safe,ok,why=pcall(input.ensure_menu_state,input,time)
    if safe and ok then
        menu_state_ready=true
        if input.menu_state then state.menu_settings_path=input.menu_state.path end
    else
        local message=tostring(safe and why or ok)
        if message~=menu_state_problem then log("MOD_SETTINGS unavailable: "..message);menu_state_problem=message end
    end
end
local function cancel_reset_work()
    -- The accepted command discards queued edits and unsaved observations.
    -- In particular, hiding a moving HUD must not write its old position into
    -- the freshly reset sidecar at the end of this frame.
    cancel_weapon_commands()
    baseline,last_key,job,transition_seen,after_pass,hand_context=nil,nil,nil,nil,nil,nil
    temporary_departure=nil;pending_preset=nil;preset_cursor=1
    help_latch,help_latch_kind,help_identity,help_kind=nil,nil,nil,nil
    help_next_read,help_content_valid=0,false
    help_call("hide")
    if light_controller then light_controller:reset(true) end
    if hud then hud_call("cancel_move");hud_call("hide") end
    hud_identity,hud_last_allowed,hud_next_read=nil,false,0
    hud_frame_valid,hud_move_frame,help_frame_valid=false,false,false
end
local function reload_after_reset(profile)
    -- Committed files invalidate every old settings/presentation object, even
    -- when the next profile read or HUD construction fails. Detach first so
    -- no later update or shutdown can persist/display the previous layout.
    local old_hud=hud
    hud,hud_layout,input,store,hud_profile,settings=nil,nil,nil,nil,nil,nil
    presets_active=false;light_controller=nil
    state.settings_path,state.menu_settings_path=nil,nil
    if old_hud then
        local safe,closed,shutdown_error=pcall(old_hud.shutdown,old_hud)
        if not safe or not closed then error(shutdown_error or "previous HUD cleanup failed",0) end
    end
    local fresh_input,input_error=DefaultsInput.new({native_reader=reader})
    if not fresh_input or fresh_input.profile_id~=profile then
        input,settings,store,hud_profile=nil,nil,nil,nil;presets_active=false
        error(input_error or "active profile changed during reset",0)
    end
    input=fresh_input;store,hud_profile,settings=nil,nil,nil;presets_active=false
    input:publish_reset_defaults()
    menu_state_ready,menu_state_next,menu_state_problem=false,0,nil
    if presets_enabled then
        store,input_error=DefaultsStore.open(profile)
        if not store then error(input_error or "reset preset settings unreadable",0) end
        state.settings_path=store.path;presets_active=true
    end
    if build.hud then
        hud_profile=store
        if not hud_profile then hud_profile,input_error=DefaultsStore.context(profile) end
        if not hud_profile then error(input_error or "reset HUD context unavailable",0) end
    end
    settings=store or hud_profile
    rebuild_light_controller()
    hud_direction_problem={};hud_problem=nil;help_problem=nil
    next_resolve,next_job=0,0;last_problem,last_watch_problem,last_context_problem=nil,nil,nil
    if build.hud and hud_profile then
        hud_layout,input_error=HudLayout.new(hud_profile,log)
        if not hud_layout then error(input_error or "reset HUD settings unreadable",0) end
        hud,input_error=WeaponHud.new({layout=hud_layout,icons=WeaponHudIcons,font=HudFont,log=log,
            display=hud_layout.display})
        if not hud then error(input_error or "reset HUD initialization failed",0) end
    end
    if not help and settings and (presets_active or build.hud) and type(previous_shutdown)=="function" then
        help,input_error=HelpHud.new({font=HudFont,icons=WeaponHudIcons,log=log})
        if not help then log("HELP_ERROR reset initialization: "..tostring(input_error)) end
    end
    state.input_problem,state.menu_input_problem,state.cycle_problem,state.hud_select_problem=nil,nil,nil,nil
    state.status="ready"
end
local function reset_mod(time,controls)
    if not controls or not controls.reset_pressed or controls.reset_ready==false then return false end
    if not foreground() or controls.profile_valid==false then return false end
    local safe,allowed,why=pcall(PresetInputGate.context,reader)
    if not safe then why=allowed;allowed=nil end
    if not allowed or not allowed.allowed then
        log("RESET_SKIP reason="..tostring(why or (allowed and allowed.reason) or "gameplay input unavailable"))
        return true
    end
    local profile=input.profile_id
    local phase,native_cleared,backup="cancel pending work",false,nil
    local ok,error_text=xpcall(function()
        cancel_reset_work()
        phase="prepare"
        local plan,prepare_error=ModReset.prepare(profile)
        if not plan then error(prepare_error,0) end
        phase="native bindings"
        local cleared,clear_error=input:reset_menu_bindings(function()
            if not foreground() then return nil,"game lost foreground before reset" end
            if type(input.refresh)=="function" then
                input:refresh(time)
                if input.profile_valid==false or input.settings_reason then
                    return nil,input.settings_reason or "active Steam profile not validated"
                end
            end
            local gate,gate_error=PresetInputGate.context(reader)
            if not gate or not gate.allowed then return nil,gate_error or (gate and gate.reason) or "gameplay input unavailable" end
            local saved,path=plan:backup()
            if saved then backup=path;native_cleared="unknown" end
            return saved,path
        end)
        if not cleared then error(clear_error or "menu binding reset failed",0) end
        native_cleared=true
        phase="files"
        local committed,detail,failure_detail=plan:commit()
        if not committed then
            error(tostring(detail).." partial_files="..tostring(failure_detail and failure_detail.partial),0)
        end
        backup=detail and detail.backup_directory or backup
        phase="reload"
        reload_after_reset(profile)
        log("RESET completed profile="..profile.." backup="..tostring(backup)..
            " native_actions="..tostring(cleared.actions or (cleared.entries and #cleared.entries) or 0)..
            " native_changed="..tostring(cleared.changed or 0)..
            " native_payloads_cleared="..tostring(cleared.payload_cleared==true)..
            " game_input_file_written="..tostring(cleared.persisted==true)..
            " native_only="..tostring(cleared.native_only==true))
    end,function(error)
        return type(debug)=="table" and type(debug.traceback)=="function" and debug.traceback(tostring(error),2) or tostring(error)
    end)
    if not ok then
        log("RESET_FAILED phase="..phase.." native_cleared="..tostring(native_cleared)..
            " backup="..tostring(backup).." reason="..tostring(error_text))
    end
    return true
end
local function suspend_application()
    after_pass=nil
    pending_preset=nil
    if job and job.awaiting then job.halt_after_readback=true else job=nil end
end
local function save_preset(snapshot,index)
    suspend_application()
    local modes,why=inspect(snapshot)
    if not modes then log("SAVE_FAILED preset="..index.." reason="..tostring(why));return end
    -- Do not capture the old side of a native action still waiting for readback.
    if job and job.awaiting then
        local expected=job.awaiting
        local dir=modes.directions[expected.side]
        if not readback_matches(dir,expected) then
            suspend_application()
            log("SAVE_FAILED preset="..index.." reason=previous native action not yet verified; press the save chord again")
            return
        end
    end
    job=nil;pending_preset=nil;after_pass=nil
    local updates,skips=DefaultsCapture.capture(modes)
    local resource=snapshot.active_weapon.entity.resource_hex_le
    for _,side in ipairs(SIDES) do
        if skips[side] then log("SAVE_SKIP resourceLE="..resource.." preset="..index.." side="..side..
            " previous_preserved=true reason="..skips[side]) end
    end
    if not next(updates) then log("SAVE_EMPTY resourceLE="..resource.." preset="..index.." previous settings preserved");return end
    local plan,plan_error=DefaultsCapture.single_setting(modes)
    if not plan then log("PRESET_RULE_SKIP resourceLE="..resource.." reason="..tostring(plan_error)) end
    if index==3 and (not plan or (plan.qualified and plan.count==2)) then
        log("SAVE_SKIP preset=3 reason="..(plan and "this weapon offers only presets 1 and 2" or "preset availability unreadable"))
        return
    end
    local saved,error_text=store:merge(resource,updates,index,plan and plan.qualified and plan or nil)
    if not saved then log("SAVE_FAILED preset="..index.." reason="..tostring(error_text));return end
    preset_cursor=index;state.preset=index
    if type(error_text)=="table" then
        log("PRESET_NORMALIZED resourceLE="..resource.." saved="..index..
            " complement="..tostring(error_text.complement).." cleared="..table.concat(error_text.cleared or {},","))
    end
    for _,side in ipairs(SIDES) do
        local value=updates[side]
        if value then log("SAVED resourceLE="..resource.." preset="..index.." side="..side..
            " slot="..value.slot.." kind="..value.kind.." value="..value.value) end
    end
end
local function request_preset(snapshot,time)
    local allowed,why=preset_input_allowed(snapshot)
    if not allowed then log("PRESET_SKIP reason="..tostring(why));return end
    local modes,mode_error=inspect(snapshot)
    local limit,limit_error
    if modes then limit,limit_error=preset_limit(modes) end
    if not limit then log("PRESET_SKIP reason="..tostring(mode_error or limit_error));return end
    local loaded,error_text=store:reload()
    if not loaded then log("SETTINGS_FAILED reason="..tostring(error_text));return end
    local presets,problem_text=store:get_presets(snapshot.active_weapon.entity.resource_hex_le)
    if not presets then log("PRESET_SKIP reason="..tostring(problem_text));return end
    local wanted
    local cursor=preset_cursor<=limit and preset_cursor or 0
    for offset=1,limit do
        local index=(cursor-1+offset)%limit+1
        if presets[index] and next(presets[index].targets) then wanted=index;break end
    end
    if not wanted then log("PRESET_SKIP reason=all three presets empty");return end
    cancel_weapon_commands()
    preset_cursor=wanted;state.preset=wanted
    after_pass=nil
    pending_preset={key=key(snapshot),index=wanted,profile=presets[wanted]}
    if job and job.awaiting then job.halt_after_readback=true else job=nil end
    log("PRESET requested="..wanted.." native="..snapshot.active_weapon.entity.eid)
end
local function drive_pending_preset(snapshot,time)
    if not pending_preset or job then return end
    local pending=pending_preset
    pending_preset=nil
    if pending.key~=key(snapshot) then return end
    local allowed,why=preset_input_allowed(snapshot)
    if not allowed then log("PRESET_SKIP reason="..tostring(why));return end
    application_job(snapshot,time,pending.index,pending.profile,"preset")
end
local function contextual_command_allowed(snapshot,controls,kind)
    if not controls or not controls.contextual_help_open or controls.help_instance~=key(snapshot) or
       not help_content_valid or not foreground() or not controls.held_reload or
       help_latch~=key(snapshot) or (kind and help_latch_kind~=kind) then return false end
    input:refresh(now())
    if input.profile_valid~=true or input.settings_reason then return false end
    local fresh=reader:active_weapon()
    if not fresh or key(fresh)~=key(snapshot) or not preset_input_allowed(fresh) then return false end
    local card=WeaponUI.inspect(reader,fresh)
    return card~=nil and not card.hidden and card.cached_eid==fresh.active_weapon.entity.eid and card.display_eid==display_eid(fresh)
end
local function change_contextual_language(snapshot,time,controls)
    if not controls or not controls.locale_pressed then return end
    local safe,selected,why=pcall(input.cycle_language,input,time,foreground(),function()
        return contextual_command_allowed(snapshot,controls)
    end)
    if safe and selected then
        -- Language selection is presentation only. Rebuild both HUDs during
        -- this frame instead of waiting for their ordinary 10 Hz refresh.
        hud_next_read,help_next_read=0,0
    elseif diagnostics then pcall(log,"LANGUAGE_SKIP reason="..tostring(safe and why or selected)) end
end
local function change_hud_display(snapshot,controls)
    if not controls or not controls.hud_display_pressed or not hud or not hud_layout or
       not contextual_command_allowed(snapshot,controls,"property") then return end
    local selected,why=hud_call("cycle_display")
    if selected then hud_next_read,help_next_read=0,0
    elseif diagnostics then pcall(log,"HUD_DISPLAY_SKIP reason="..tostring(why)) end
end
local function transfer_account_presets(snapshot,controls)
    if not controls or not (controls.export_pressed or controls.import_pressed) then return end
    local function guard()
        return presets_active and store~=nil and input.profile_id==store.profile_id and
            contextual_command_allowed(snapshot,controls,"presets")
    end
    local safe,outcome,detail=pcall(presets_transfer.run,presets_transfer,store,controls,guard)
    if not safe or not outcome then
        if diagnostics then pcall(log,"PRESETS_TRANSFER_SKIPPED reason="..tostring(safe and detail or outcome)) end
        return
    end
    if outcome=="imported" then
        -- A successful import edits preferences only. Do not apply a mode
        -- until a subsequent real equip or explicit preset swap.
        pending_preset,after_pass=nil,nil
        if job and job.awaiting then job.halt_after_readback=true else job=nil end
        preset_cursor,state.preset=1,1
        help_next_read=0
    end
    if diagnostics then pcall(log,"PRESETS_TRANSFER "..outcome) end
end
local function select_hud_direction(snapshot,controls)
    local fresh,why=reader:active_weapon()
    if not fresh or key(fresh)~=key(snapshot) then
        help_latch=nil;help_latch_kind=nil
        log("HUD_SKIP reason=current active instance not validated: "..tostring(why));return
    end
    local allowed,gate_error=preset_input_allowed(fresh)
    if not allowed then
        help_latch=nil;help_latch_kind=nil
        log("HUD_SKIP reason="..tostring(gate_error));return
    end
    -- Opening and changing this panel both require the real held/open card.
    local card,card_error=WeaponUI.inspect(reader,fresh)
    if not controls.held_reload or not card or card.hidden or
       card.cached_eid~=fresh.active_weapon.entity.eid or card.display_eid~=display_eid(fresh) then
        help_latch=nil;help_latch_kind=nil
        log("HUD_SKIP reason=weapon card must be open and current: "..tostring(card_error));return
    end
    local already_open=help_latch==key(fresh) and help_latch_kind=="property"
    help_latch=key(fresh);help_latch_kind="property";help_next_read=0
    -- The first accepted H opens help without touching the display preference.
    -- Later H edges for this same open panel select the next offered property.
    if not already_open then
        if diagnostics then pcall(log,"HUD_OPEN resourceLE="..fresh.active_weapon.entity.resource_hex_le..
            " native="..fresh.active_weapon.entity.eid.." preference_unchanged=true") end
        return
    end
    -- Display preferences cannot change modes, cancel a pending native
    -- application or mutate weapon presets. A hidden selection is persistent.
    local modes,mode_error=inspect(fresh)
    if not modes then log("HUD_SKIP direction selection: "..tostring(mode_error));return end
    local available={}
    for _,side in ipairs(SIDES) do
        local direction=modes.directions[side]
        if not direction or (direction.action_enum~=5 and direction.kind~="flashlight" and
            (type(direction.present)~="boolean" or direction.presence_unknown)) then
            log("HUD_SKIP direction selection: availability unknown for "..side);return
        end
        if direction.present and direction.action_enum~=5 and direction.kind~="flashlight" then available[#available+1]=side end
    end
    local selected=hud_call("cycle_selection",fresh.active_weapon.entity.resource_hex_le,available)
    if selected then
        hud_next_read=0;help_next_read=0
    end
end
local function save_controls_impl(snapshot,time,controls)
    if not controls then return end
    -- Only a previously accepted P press for this exact equipped instance can
    -- arm a released-P number. Native card/input checks still run before save.
    if presets_active and controls.held_reload and controls.ready~=false and
       help_latch==key(snapshot) and help_latch_kind=="presets" then
        controls.save_preset=controls.save_preset or controls.preset_pressed
    end
    local pressed=presets_active and controls.ready~=false and controls.pressed and controls.held_reload
    local clearing=presets_active and controls.clear_ready~=false and controls.clear_pressed and controls.held_reload
    local moving=hud and controls.hud_move_active and controls.held_reload and
        not controls.down and not controls.save_held and not controls.pressed and
        help_latch==key(snapshot) and help_latch_kind=="property"
    local selecting=hud and controls.hud_select_pressed
    local preset_editing=presets_active and (pressed or clearing or controls.save_preset)
    local editing=preset_editing or moving
    local cycling=presets_active and controls.cycle_pressed
    if not editing and not selecting and not cycling then return end
    if selecting and not preset_editing and not cycling then
        -- Even validation of a presentation command is isolated from the
        -- existing weapon-mode coordinator, including unexpected API errors.
        local ok,why=pcall(select_hud_direction,snapshot,controls)
        if not ok then log("HUD_ERROR direction selection failed: "..tostring(why)) end
        return
    end
    local fresh,why=reader:active_weapon()
    if not fresh or key(fresh)~=key(snapshot) then
        help_latch=nil;help_latch_kind=nil
        cancel_weapon_commands()
        log("SAVE_IGNORED reason=current active instance not validated");return
    end
    local allowed,gate_error=preset_input_allowed(fresh)
    if not allowed then
        help_latch=nil;help_latch_kind=nil
        cancel_weapon_commands()
        log("PRESET_SKIP reason="..tostring(gate_error));return
    end
    if editing then
        local card,card_error=WeaponUI.inspect(reader,fresh)
        if not controls.held_reload or not card or card.hidden or
           card.cached_eid~=fresh.active_weapon.entity.eid or card.display_eid~=display_eid(fresh) then
            help_latch=nil;help_latch_kind=nil
            cancel_weapon_commands()
            log("SAVE_IGNORED reason=weapon card must be open and current: "..tostring(card_error));return
        end
        if moving then
            -- Moving the indicator is presentation only. It must not suspend
            -- an equip job, consume a preset request or synthesize a P gesture.
            hud_move_frame=true
            hud_call("move",time,controls.hud_move)
            return
        end
        if not presets_active then return end
        if pressed then
            help_latch=key(fresh);help_latch_kind="presets";help_next_read=0
        end
        if controls.save_preset and controls.ready~=false then
            -- A numbered chord is a save, not a bare P tap toward deletion.
            -- Fast P+1 then P+2 must never become an accidental clear-all.
            if type(input.consume_clear)=="function" then input:consume_clear() end
            save_preset(fresh,controls.save_preset)
            return
        end
        if pressed or clearing then
            suspend_application()
            if clearing then
                suspend_application()
                local ok,error_text=store:clear_all(fresh.active_weapon.entity.resource_hex_le)
                if ok then preset_cursor=1;state.preset=1 end
                log((ok and "CLEARED" or "CLEAR_FAILED").." resourceLE="..fresh.active_weapon.entity.resource_hex_le..
                    " presets=1,2,3 cleared; global_flashlight_preserved=true"..(ok and "" or " reason="..tostring(error_text)))
                return
            end
        end
        return
    end
    if cycling and controls.cycle_ready~=false then request_preset(fresh,time) end
end
local function save_controls(snapshot,time,controls)
    if hud and controls and controls.hud_move_active then
        local ok,why=pcall(save_controls_impl,snapshot,time,controls)
        if not ok then
            log("HUD_ERROR positioning failed: "..tostring(why))
            hud_move_frame=false;hud_call("hide")
        end
    else save_controls_impl(snapshot,time,controls) end
end
local function context_matches(context,snapshot)
    return context and context.candidate_kind=="weapon" and context.candidate_entity and
        context.avatar_bytes==snapshot.avatar_bytes and
        context.candidate_entity.bytes==snapshot.active_weapon.bytes
end
local function temporary_context(context)
    if not context then return false end
    if context.candidate_kind=="empty" or context.candidate_kind=="utility" then return true end
    -- A registered hand item outside all three weapon slots may have its own
    -- WeaponData (some throwables do). Stable membership is enough to leave
    -- it alone; no need to resolve its modes every frame. Unknown main-slot
    -- entities still retry because they may be a briefly unready real weapon.
    local slots=context.slots
    return context.candidate_kind=="unknown" and context.candidate_entity and slots and
        slots.primary~=context.selection_eid and slots.sidearm~=context.selection_eid and
        slots.support~=context.selection_eid
end
local function observe_hand(reference,expected_pair)
    local context,why=EquipContext.inspect(reader,reference,expected_pair)
    if not context then
        if last_context_problem~=why then
            if diagnostics then log("HAND_UNAVAILABLE reason="..tostring(why)) end
            last_context_problem=why
        end
        hand_context=nil
        return nil,why
    end
    last_context_problem=nil
    local previous=hand_context
    hand_context=context
    if diagnostics and (not previous or previous.selection_bytes~=context.selection_bytes or
       previous.candidate_kind~=context.candidate_kind or previous.previous_in_main~=context.previous_in_main) then
        log("HAND previous="..reference.active_weapon.entity.eid.." observed="..context.selection_eid..
            " category="..context.candidate_kind.." slot="..tostring(context.candidate_slot)..
            " previous_retained="..tostring(context.previous_in_main))
    end
    -- Inventory only classifies an actually observed hand EID. Empty hands,
    -- grenade/stim objects and unknown registry entries are never weapon
    -- switch evidence. No time window or control press can create an equip.
    if baseline and reference==baseline then
        local departed=context.selection_eid~=baseline.active_weapon.entity.eid
        local real_departure=not context.previous_in_main or
            (context.candidate_kind=="weapon" and departed)
        if diagnostics and real_departure and not transition_seen then
            log("WEAPON_DEPARTURE previous="..baseline.active_weapon.entity.eid..
                " observed="..context.selection_eid.." reason="..
                (context.previous_in_main and "another main weapon selected" or "previous weapon left inventory"))
        end
        transition_seen=transition_seen or real_departure
        if departed or real_departure then
            help_latch=nil;help_latch_kind=nil
            if light_controller then light_controller:pause() end
            temporary_departure=true
            cancel_weapon_commands()
            after_pass=nil
            if job then log("CANCEL equip="..job.seq.." reason=native hand departure");job=nil end
        end
    end
    return context
end
local function step()
    local time=now()
    if time>=text_next_language then Text.read_language();text_next_language=time+2 end
    local active_window=foreground()
    hud_frame_valid,hud_move_frame=false,false
    local previous_help_visible=help_frame_valid
    help_frame_valid=false
    local controls
    if input then
        controls=input:poll(time,active_window,{presets_enabled=presets_active,hud_enabled=hud~=nil,
            reset_enabled=presets_enabled or build.hud,
            help_instance=baseline and key(baseline),
            help_open=previous_help_visible and baseline~=nil and help_latch==key(baseline),
            preset_help_open=previous_help_visible and baseline~=nil and help_latch==key(baseline) and help_latch_kind=="presets",
            hud_move_armed=hud~=nil and baseline~=nil and help_latch==key(baseline) and help_latch_kind=="property",
            diagnostics_enabled=diagnostics})
        -- Optional observation (including a broken console) must never stop
        -- the coordinator. Do not report a sink failure into the same sink.
        if diagnostics then pcall(observe_grenade_input,controls) end
        if not active_window or not controls.held_reload or controls.profile_valid==false or
           (help_latch_kind=="presets" and controls.ready==false) then
            help_latch=nil;help_latch_kind=nil;help_next_read=0
        end
        if controls.reason and controls.reason~=state.input_problem then log("SAVE_INPUT "..controls.reason) end
        state.input_problem=controls.reason
        if controls.menu_reason~=state.menu_input_problem then
            if controls.menu_reason then log("MOD_BINDINGS "..tostring(controls.menu_reason)) end
            state.menu_input_problem=controls.menu_reason
        end
        if controls.menu_default_events then
            for index,message in ipairs(controls.menu_default_events) do
                if index>8 then break end
                pcall(log,"MOD_BINDINGS_DEFAULT "..tostring(message))
            end
        end
        if diagnostics and controls.menu_diagnostics then
            for index,message in ipairs(controls.menu_diagnostics) do
                if index>8 then break end
                pcall(log,"MOD_BINDINGS_MAP "..tostring(message))
            end
        end
        if controls.save_reason then log("SAVE_INPUT "..controls.save_reason) end
        if presets_active and controls.cycle_label and controls.cycle_reason and controls.cycle_reason~=state.cycle_problem then
            log("PRESET_SKIP reason="..controls.cycle_reason)
        end
        state.cycle_problem=controls.cycle_reason
        if controls.clear_reason and controls.clear_reason~=state.clear_problem then log("CLEAR_SKIP "..controls.clear_reason) end
        state.clear_problem=controls.clear_reason
        if controls.hud_select_reason and controls.hud_select_reason~=state.hud_select_problem then
            log("HUD_SKIP "..controls.hud_select_reason)
        end
        state.hud_select_problem=controls.hud_select_reason
        if controls.profile_valid==false then
            if light_controller then light_controller:reset(true) end
            cancel_weapon_commands()
            if job then log("CANCEL equip="..job.seq.." reason=active Steam profile not validated") end
            baseline,last_key,job,transition_seen,after_pass,hand_context=nil,nil,nil,nil,nil,nil
            temporary_departure=nil
            return
        end
        if reset_mod(time,controls) then return end
        ensure_menu_file(time)
    end
    if not active_window then
        cancel_weapon_commands();controls=nil
        if job and job.cause=="preset" then
            log("PRESET_SKIP reason=game lost foreground");job=nil
        end
    end
    if baseline then
        local unchanged,why,metrics=reader:watch(baseline,hand_context and hand_context.selection_bytes)
        if unchanged then last_watch_problem=nil
        elseif last_watch_problem~=why then
            if diagnostics then log("WATCH previous="..baseline.active_weapon.entity.eid.." reason="..tostring(why)) end
            last_watch_problem=why
        end
        if metrics and metrics.authoritative_selection_change then
            help_latch=nil;help_latch_kind=nil
            if light_controller then light_controller:pause() end
            -- A certain hand change cancels work even when its inventory
            -- classification fails. Only observe_hand may turn it into a
            -- real weapon departure; cancellation itself never does so.
            temporary_departure=true
            cancel_weapon_commands()
            after_pass=nil
            if job then log("CANCEL equip="..job.seq.." reason=verified native hand change");job=nil end
        end
        local same_weapon=context_matches(hand_context,baseline)
        local context_stable=hand_context~=nil
        -- While a utility is held, detect actual loss/drop of the retained
        -- weapon even if the hand selection itself stays unchanged. Ordinary
        -- stable weapon frames retain the established small native watch.
        if unchanged and hand_context and not same_weapon then
            context_stable=EquipContext.watch(reader,hand_context)
        end
        if not unchanged or not context_stable or
           (hand_context and hand_context.candidate_kind=="unknown" and not temporary_context(hand_context)) then
            observe_hand(baseline,metrics and metrics.observed_selection_bytes)
            -- A refreshed classification is not a substitute for the native
            -- watch's gameplay-state gates. The full resolver runs below.
            same_weapon=context_matches(hand_context,baseline)
        end
        -- The hand cursor can already contain a new display child while its
        -- full snapshot is still settling. It must not make an old parent/
        -- display snapshot look usable forever after a single failed resolve.
        local pair_matches=same_weapon and hand_context.selection_bytes==baseline.active_weapon.wielder_selection_bytes
        if unchanged and same_weapon and pair_matches and not transition_seen then
            if temporary_departure then
                if diagnostics then log("UTILITY_RETURN weapon="..baseline.active_weapon.entity.eid.." preserve_manual=true") end
                temporary_departure=nil
            end
            step_light(baseline,time,active_window)
            change_contextual_language(baseline,time,controls)
            change_hud_display(baseline,controls)
            transfer_account_presets(baseline,controls)
            save_controls(baseline,time,controls)
            drive_pending_preset(baseline,time)
            if job then step_job(baseline,time) end
            drive_pending_preset(baseline,time)
            observe_after_pass(baseline,time)
            if active_window then present_help(baseline,time,controls) end
            if active_window then present_hud(baseline,time) end
            return
        end
        if unchanged and temporary_context(hand_context) then return end
        -- Classification is observed before this resolver's throttle, so a
        -- brief real A->B->A still latches B even before B has WeaponData or a
        -- ready holder. An unknown read cannot latch a departure.
    end
    if time<next_resolve then return end
    next_resolve=time+0.015
    local snapshot,why=reader:active_weapon()
    if not snapshot then
        help_latch=nil;help_latch_kind=nil
        problem(why)
        if why=="not in mission" then
            if light_controller then light_controller:reset() end
            cancel_weapon_commands()
            baseline,last_key,job,transition_seen,after_pass,hand_context=nil,nil,nil,nil,nil,nil
            temporary_departure=nil
            next_resolve=time+0.25
        elseif tostring(why):find("mode-card avatar state blocks action",1,true) or
               why=="local player unavailable" or why=="game modules unavailable" then
            cancel_weapon_commands()
            next_resolve=time+0.10
        end
        return
    end
    local context,context_error=EquipContext.inspect(reader,snapshot,
        snapshot.active_weapon.wielder_selection_bytes)
    if not context or not context_matches(context,snapshot) then
        help_latch=nil;help_latch_kind=nil
        problem(context_error or "selected item is not a verified main weapon")
        return
    end
    last_problem=nil
    local changed=key(snapshot)~=last_key or transition_seen
    baseline=snapshot
    hand_context=context
    if changed then
        cancel_weapon_commands()
        last_key=key(snapshot); transition_seen=false; start_job(snapshot,time)
    elseif diagnostics and temporary_departure then
        log("UTILITY_RETURN weapon="..snapshot.active_weapon.entity.eid.." preserve_manual=true")
    end
    temporary_departure=nil
    step_light(snapshot,time,active_window)
    change_contextual_language(snapshot,time,controls)
    change_hud_display(snapshot,controls)
    transfer_account_presets(snapshot,controls)
    save_controls(snapshot,time,controls)
    drive_pending_preset(snapshot,time)
    step_job(snapshot,time)
    drive_pending_preset(snapshot,time)
    observe_after_pass(snapshot,time)
    if active_window then present_help(snapshot,time,controls) end
    if active_window then present_hud(snapshot,time) end
end
local stopped=false
local function after_update(...)
    if not stopped then
        local ok,why=pcall(step)
        if not ok then stopped=true; state.status="stopped"; log("ERROR automatic actions stopped: "..tostring(why)) end
        if hud then
            if not hud_move_frame then hud_call("finish_move") end
            if not hud_frame_valid or not ok then hud_call("hide") end
        end
        if help and (not help_frame_valid or not ok) then help_call("hide");help_content_valid=false end
    end
    return ...
end
rawset(_G,"update",function(...) return after_update(previous_update(...)) end)
local shutdown_started=false
if type(previous_shutdown)=="function" then
    rawset(_G,"shutdown",function(...)
        if not shutdown_started then
            -- Stop before the engine or another addon starts tearing down its
            -- objects. Even a reentrant update must not touch native modes/GUI.
            shutdown_started=true;stopped=true;state.status="shutdown"
            local ok,why=pcall(function()
                -- A broken console/file/timestamp must never skip GUI cleanup.
                local function report(message) pcall(log,message) end
                report("SHUTDOWN_BEGIN equips="..state.equips.." actions="..state.actions)
                local cleanup_ok=true
                job,pending_preset,after_pass,baseline,hand_context=nil,nil,nil,nil,nil
                if light_controller then light_controller:reset(true) end
                if input then pcall(input.cancel_events,input) end
                if help then
                    local closing=help;help=nil
                    local closed,value,error_text=pcall(closing.shutdown,closing)
                    if not closed or not value or error_text then
                        cleanup_ok=false;report("SHUTDOWN_ERROR contextual HUD cleanup: "..tostring(error_text or value))
                    end
                end
                if hud then
                    local closing=hud;hud=nil
                    local closed,result,reason=pcall(closing.shutdown,closing)
                    if not closed then
                        cleanup_ok=false
                        report("SHUTDOWN_ERROR HUD cleanup exception: "..tostring(result))
                    elseif not result or reason then
                        cleanup_ok=false
                        report("SHUTDOWN_ERROR HUD cleanup: "..tostring(reason))
                    else
                        report("HUD_SHUTDOWN gui="..result.status..
                            (result.position_error and (" position_error="..result.position_error) or ""))
                    end
                else report("HUD_SHUTDOWN gui=inactive") end
                report("SHUTDOWN_END addon_cleanup="..tostring(cleanup_ok).." forwarding_previous=true")
            end)
            if not ok then pcall(log,"SHUTDOWN_ERROR "..tostring(why)) end
            local function close(file)
                if file then pcall(function() file:flush() end);pcall(function() file:close() end) end
            end
            close(session_log);close(latest_log);session_log,latest_log=nil,nil
        end
        -- Forward unchanged, including nil-valued results and any original
        -- exception. No engine/world access is made after this callback.
        return previous_shutdown(...)
    end)
end
state.status="watching native equipment"
log("READY Weapon Defaults v"..state.version.." flavor="..state.flavor.." presets="..tostring(presets_enabled).." hud="..tostring(build.hud==true).." local_time="..os.date("%Y-%m-%d %H:%M:%S"))
if diagnostics then
    log("SESSION pid="..pid.."; UI dirty invalidation; 3 bounded read-only POST samples per completed equip")
    log("EQUIP_POLICY actual main weapon selection or inventory loss; retained weapon utility returns preserve manual modes")
    if presets_enabled then
        log("SAVE_DEFAULTS hold the configured weapon-card control; use the MODS Preset menu action then 1/2/3; Clear presets and Swap presets use their own MODS assignments")
    end
end
return state

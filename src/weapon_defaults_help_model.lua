-- Read-only text for the contextual panels. No input, file or native access.
local M={}
local SIDES={"left","right","up","down"}
local FIRE={[1]="auto",[2]="semi",[3]="burst",[4]="volley",[5]="safe",[6]="unsafe",[7]="total"}
local function tr(key,values) return Text.hud(key,values) end
local function plain(value)
    return Text.clean(value,160)
end
local function is_light(dir)
    return type(dir)=="table" and (dir.action_enum==5 or dir.kind=="flashlight")
end
local function label(kind,value,ammo)
    if type(value)~="number" or value~=value then return nil end
    if kind=="firemode" then return FIRE[value] and tr("mode."..FIRE[value])
    elseif kind=="rpm" and value>0 and value<=100000 then return tr("mode.rpm",{value=math.floor(value+0.5)})
    elseif kind=="zeroing" and value>0 and value<=10000 then return tr("mode.scope",{value=math.floor(value+0.5)})
    elseif kind=="laser_guide" then return value==0 and tr("mode.guidance_off") or value==1 and tr("mode.guidance_on") or nil
    elseif kind=="programmable_ammo" then return ammo and plain(ammo[value])
    elseif kind=="secondary_fire" then return ammo and ammo.secondary_fire and plain(ammo.secondary_fire[value])
    elseif kind=="binary_10" and (value==0 or value==1) then
        return (ammo and ammo.binary_10 and plain(ammo.binary_10[value])) or tr("mode.choice",{value=value+1}) end
end
local function binding(value)
    if value==nil or value=="None" or value=="NONE" then return tr("state.empty") end
    return plain(value) or tr("state.empty")
end
local function text_run(runs,value,accent)
    if value~="" then runs[#runs+1]={kind="text",text=value,accent=accent} end
end
local function icon_run(kind,value,name,hash,unavailable)
    if type(hash)~="string" or #hash~=16 or not hash:match("^%x+$") or hash=="0000000000000000" then return nil end
    local caption
    if kind=="rpm" then caption=tostring(math.floor(value+0.5))
    elseif kind=="zeroing" then caption=tr("mode.scope",{value=math.floor(value+0.5)}) end
    return {kind="icon",hash=hash:lower(),text=name,caption=caption,unavailable=unavailable==true}
end
local function key_runs(runs,value)
    if value==tr("state.empty") then text_run(runs,value);return end
    -- Delimiters belong to input's binding-group formatter. Named punctuation
    -- such as Slash and NumpadDivide is a single physical key, not a separator.
    local from=1
    while true do
        local first,last=value:find(" [+/] ",from)
        local key=value:sub(from,first and first-1 or #value)
        if key~="" then runs[#runs+1]={kind="key",text=key} end
        if not first then break end
        text_run(runs,value:sub(first,last));from=last+1
    end
end
-- Keep the numeric entries as ordinary text for existing callers. Optional
-- byte ranges identify actual control labels; never match letters in words.
local function add_line(lines,parts)
    local text,ranges,runs="",{},{}
    for _,part in ipairs(parts) do
        local value,accent=part[1],part[2]
        local first=#text+1
        text=text..value
        if (accent or part.accent) and value~=tr("state.empty") and value~="" then ranges[#ranges+1]={first,#text} end
        if accent then key_runs(runs,value) else text_run(runs,value,part.accent) end
    end
    lines[#lines+1]=text
    if #ranges>0 then lines.highlights[#lines]=ranges end
    lines.runs=lines.runs or {};lines.runs[#lines]=runs
end
local function add_template(lines,key,values,accents)
    add_line(lines,Text.parts(key,values,accents))
end
local function trigger(value)
    return Text.trigger(value) or tr("state.unavailable")
end
local function display_options(lines,selected,compact)
    if selected~="icon" and selected~="text" then selected="both" end
    local parts=Text.parts("help.display",{icon=tr("display.icon"),text=tr("display.text"),both=tr("display.both")})
    if compact then table.insert(parts,1,{"F10",true});table.insert(parts,2,{" "}) end
    add_line(lines,parts)
    local runs,ranges,at={},{},1
    for _,part in ipairs(parts) do
        local active=part.name==selected
        if part[2] then key_runs(runs,part[1]) else text_run(runs,part[1],active) end
        if active then ranges[#ranges+1]={at,at+#part[1]-1} end
        at=at+#part[1]
    end
    lines.runs[#lines],lines.highlights[#lines]=runs,ranges
    if not compact then add_template(lines,"help.display_change",{key="F10"},{key=true}) end
end
local function offered(dir,target,modes,targets)
    if not dir or dir.present~=true or dir.presence_unknown or dir.kind~=target.kind then return false end
    local found=false
    for _,value in ipairs(dir.choices or {}) do if value==target.value then found=true;break end end
    if not found then return false end
    if target.kind=="firemode" then
        -- Availability describes the destination preset. An explicit secondary
        -- target keeps ordinary fire dormant even if the weapon is primary now.
        local directions=modes and modes.directions or {}
        for _,side in ipairs(SIDES) do
            local selector=directions[side]
            local saved=targets and targets[side]
            if selector and selector.present==true and selector.action_enum==11 and
               selector.kind=="secondary_fire" and saved and saved.kind=="secondary_fire" and saved.value==1 then
                return false
            end
        end
        if dir.inactive then
            -- This is a verified native action-3 return, not a fabricated Left
            -- preference. None remains untouched; the caller supplies the proof.
            local activation=dir.primary_activation
            if type(activation)~="table" or dir.action_enum~=3 or activation.action_enum~=3 or
               activation.before~=8 or type(activation.next_value)~="number" or
               activation.next_value%1~=0 or activation.next_value<1 or activation.next_value>7 then return false end
            local selector=directions[activation.selector_side]
            if not selector or selector.present~=true or selector.presence_unknown or
               selector.action_enum~=11 or selector.kind~="secondary_fire" or selector.readable~=true or
               selector.current~=1 or selector.cycle_supported~=true then return false end
            local retained_offered=false
            for _,value in ipairs(dir.choices or {}) do
                if value==activation.next_value then retained_offered=true;break end
            end
            return retained_offered
        end
    end
    return not dir.inactive
end
function M.preset_text(preset,modes,ammo)
    local fields={}
    for _,side in ipairs(SIDES) do
        local target=preset and preset.targets and preset.targets[side]
        if target and not is_light(target) then
            local text=label(target.kind,target.value,ammo) or tr("state.unavailable")
            if text~=tr("state.unavailable") and not offered(modes and modes.directions and modes.directions[side],target,modes,preset.targets) then
                text=text.." ("..tr("state.unavailable")..")"
            end
            fields[#fields+1]=text
        end
    end
    return #fields>0 and table.concat(fields,", ") or tr("state.empty")
end
-- Icons are resolved for the saved semantic value among this instance's
-- offered choices, never from its currently selected slot or a guessed type.
function M.preset_runs(preset,modes,ammo,icons)
    local runs,count={},0
    for _,side in ipairs(SIDES) do
        local target=preset and preset.targets and preset.targets[side]
        if target and not is_light(target) then
            if count>0 then text_run(runs," + ") end
            count=count+1
            local dir=modes and modes.directions and modes.directions[side]
            local available=offered(dir,target,modes,preset.targets)
            local name=label(target.kind,target.value,ammo) or tr("state.unavailable")
            local choice=icons and icons[side] and icons[side][target.value]
            local hash=choice and choice.kind==target.kind and choice.hash_hex
            local symbol=icon_run(target.kind,target.value,name,hash,not available)
            if symbol then runs[#runs+1]=symbol else text_run(runs,name) end
            if not available and name~=tr("state.unavailable") then text_run(runs," ("..tr("state.unavailable")..")") end
        end
    end
    if count==0 then text_run(runs,tr("state.empty")) end
    return runs
end
function M.presets(presets,modes,ammo,controls,limit,icons,geometry)
    controls=controls or {}
    local card=binding(controls.card_label)
    local lines={highlights={}}
    for index=1,limit==2 and 2 or 3 do
        if geometry then
            local preset=presets and presets[index]
            local missing={}
            local count=0
            for _,side in ipairs(SIDES) do
                local target=preset and preset.targets and preset.targets[side]
                if target and not is_light(target) then
                    count=count+1
                    local dir=modes and modes.directions and modes.directions[side]
                    local visible=false
                    for _,cell in ipairs(geometry.directions and geometry.directions[side] or {}) do
                        if cell.value==target.value and offered(dir,target,modes,preset.targets) then visible=true;break end
                    end
                    if not visible then
                        local text=label(target.kind,target.value,ammo) or tr("state.unavailable")
                        if text~=tr("state.unavailable") and not offered(dir,target,modes,preset.targets) then
                            text=text.." ("..tr("state.unavailable")..")"
                        end
                        missing[#missing+1]=text
                    end
                end
            end
            local status=count==0 and (" ("..tr("state.empty")..")") or
                (#missing>0 and (" | "..table.concat(missing,", ")) or "")
            add_template(lines,"help.preset_edit",{index=index,key=tostring(index),
                default=index==1 and tr("state.default") or "",status=status},{key=true})
        else
            local parts=Text.parts("help.preset",{index=index,preset=M.preset_text(presets and presets[index],modes,ammo),
                default=index==1 and tr("state.default") or "",key=tostring(index)},{key=true})
            add_line(lines,parts)
            local runs={}
            for _,part in ipairs(parts) do
                if part.name=="preset" then
                    for _,run in ipairs(M.preset_runs(presets and presets[index],modes,ammo,icons)) do runs[#runs+1]=run end
                elseif part[2] then key_runs(runs,part[1])
                else text_run(runs,part[1]) end
            end
            lines.runs[#lines]=runs
        end
    end
    lines[#lines+1]=""
    add_template(lines,"help.clear",{card=card,trigger=trigger(controls.clear_trigger),key=binding(controls.clear_label)},
        {card=true,key=true})
    local assigned=controls.cycle_label~=nil and controls.cycle_label~="None" and controls.cycle_label~="NONE"
        and controls.cycle_label~=""
    add_template(lines,"help.swap",{trigger=assigned and (trigger(controls.cycle_trigger).." ") or "",
        key=assigned and binding(controls.cycle_label) or tr("state.assign_swap")},{key=assigned})
    if controls.export_label or controls.import_label then
        add_template(lines,"help.transfer",{copy=binding(controls.export_label),paste=binding(controls.import_label)},
            {copy=true,paste=true})
    end
    return lines
end
function M.onboarding(progress,controls)
    local lines={highlights={}}
    add_template(lines,"intro.title",{})
    lines[#lines+1]=""
    for _,name in ipairs({"presets","hud","swap"}) do
        local key=name=="presets" and controls.save_label or name=="hud" and controls.hud_label
        local done=progress[name]==true
        local parts=done and {{"["},{"X",accent=true},{"] "}} or {{"[ ] "}}
        local values,accents,message
        if name~="swap" and key and key~="None" and key~="" then
            message="intro."..name
            values={card=binding(controls.card_label),trigger=trigger(name=="presets" and controls.save_trigger or controls.hud_trigger),key=binding(key)}
            accents={card=true,key=true}
        else
            message="intro.swap"
            values={action=tr("menu."..(name=="presets" and "save" or name=="hud" and "hud" or "cycle"),
                {card=binding(controls.card_label)})}
        end
        for _,part in ipairs(Text.parts(message,values,accents)) do parts[#parts+1]=part end
        add_line(lines,parts)
    end
    lines[#lines+1]=""
    add_template(lines,"help.settings",{})
    return lines
end
function M.auto_side(modes)
    for _,side in ipairs(SIDES) do
        local dir=modes and modes.directions and modes.directions[side]
        if dir and dir.present and dir.readable and not is_light(dir) and
           (dir.kind=="rpm" or dir.kind=="programmable_ammo" or dir.kind=="binary_10" or
            (dir.kind=="firemode" and (dir.current==5 or dir.current==6))) then return side end
    end
end
function M.wheel_marks(presets,modes,selected,limit,geometry,kind)
    local marks={}
    if kind=="property" and selected==nil then selected=M.auto_side(modes) end
    for _,side in ipairs(SIDES) do
        local dir=modes and modes.directions and modes.directions[side]
        if dir and not is_light(dir) then
            for _,cell in ipairs(geometry and geometry.directions and geometry.directions[side] or {}) do
                local labels={}
                if kind=="presets" then
                    for index=1,limit==2 and 2 or 3 do
                        local preset=presets and presets[index]
                        local target=preset and preset.targets and preset.targets[side]
                        if target and target.value==cell.value and offered(dir,target,modes,preset.targets) then
                            labels[#labels+1]="P"..index
                        end
                    end
                elseif selected==side and dir.readable and not dir.inactive and dir.current==cell.value then
                    labels[1]="HUD"
                end
                if #labels>0 then marks[#marks+1]={x=cell.x,y=cell.y,w=cell.w,h=cell.h,side=side,label=table.concat(labels," / ")} end
            end
        end
    end
    return marks
end
function M.property(modes,ammo,selected,controls,native,geometry)
    controls=controls or {}
    if geometry then
        local lines={highlights={}}
        display_options(lines,controls.hud_display,true)
        add_template(lines,"help.property_edit",{trigger=trigger(controls.hud_trigger),key=binding(controls.hud_label)},
            {key=true})
        return lines
    end
    local directions=modes and modes.directions or {}
    if selected==nil then selected=M.auto_side(modes) end
    local current=directions[selected]
    if not current or not current.present or is_light(current) then selected=nil end
    local current_text=selected and (current.readable and not current.presence_unknown and not current.inactive and
        label(current.kind,current.current,ammo) or nil) or nil
    local value_icon
    local icon=native and native.directions and native.directions[selected]
    if current_text and icon and not icon.reason and icon.current==current.current and
       (icon.kind==current.kind or (current.kind=="firemode" and
        ((icon.kind=="safe" and current.current==5) or (icon.kind=="unsafe" and current.current==6)))) then
        value_icon=icon_run(current.kind,current.current,current_text,icon.hash_hex)
    end
    local others={}
    for _,side in ipairs(SIDES) do
        local dir=directions[side]
        if dir and dir.present and not dir.presence_unknown and not is_light(dir) and side~=selected then
            others[#others+1]=(dir.readable and label(dir.kind,dir.current,ammo)) or tr("state.unavailable")
        end
    end
    if selected then others[#others+1]=tr("state.hide") end
    local lines={highlights={}}
    local parts=Text.parts("help.property",{value=selected and (current_text or tr("state.unavailable")) or tr("state.hide")})
    add_line(lines,parts)
    if value_icon then
        local runs={}
        for _,part in ipairs(parts) do
            if part.name=="value" then runs[#runs+1]=value_icon else text_run(runs,part[1]) end
        end
        lines.runs[#lines]=runs
    end
    add_template(lines,"help.others",{values=#others>0 and table.concat(others,", ") or tr("state.empty")})
    display_options(lines,controls.hud_display)
    add_template(lines,"help.change",{card=binding(controls.card_label),trigger=trigger(controls.hud_trigger),
        key=binding(controls.hud_label)},{card=true,key=true})
    add_template(lines,"help.move",{card=binding(controls.card_label),up=tr("key.up"),down=tr("key.down"),left=tr("key.left"),right=tr("key.right")},
        {card=true,up=true,down=true,left=true,right=true})
    return lines
end
return M

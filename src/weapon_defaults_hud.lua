-- Optional presentation only. Selection and mode values come from the guarded
-- native readers; neither GUI worlds nor input presses identify a weapon.
local M={}
local SIDES={"left","right","up","down"}
local function valid_rpm(value)
 return type(value)=="number" and value==value and value>0 and value<100000
end
local function display_mode(value)
 return (value=="icon" or value=="text") and value or "both"
end
local function native_label(value)
 -- The guarded reader resolves a native localization key. Never turn a
 -- projectile enum, icon hash or asset filename into a player-facing label.
 return Text.clean(value,192)
end
local function semantic_label(n)
 if n.kind=="safe" and n.current==5 then return Text.hud("mode.safe")
 elseif n.kind=="unsafe" and n.current==6 then return Text.hud("mode.unsafe")
 elseif n.kind=="zeroing" and valid_rpm(n.current) then return Text.hud("mode.scope",{value=math.floor(n.current+0.5)})
 elseif n.kind=="laser_guide" then return n.current==0 and Text.hud("mode.off") or n.current==1 and Text.hud("mode.on") or nil
 elseif n.kind=="firemode" then
  -- Native card formatter 18292D9..182934A plus the installed English
  -- localization table 18056969d61dbfe9, not legacy enum/asset names.
  local name=({[1]="auto",[2]="semi",[3]="burst",[4]="volley",[5]="safe",[6]="unsafe",[7]="total"})[n.current]
  return name and Text.hud("mode."..name)
 elseif n.kind=="binary_10" and (n.current==0 or n.current==1) then
  return Text.hud(n.label_message or "mode.choice",{value=n.current+1})
 elseif n.kind=="programmable_ammo" or n.kind=="secondary_fire" then return native_label(n.label) end
end
function M.entries(modes,native,icons,selected,display)
 local out,unknown={},{}
 display=display_mode(display)
 local function unavailable(n,sprite,label)
  if display~="text" and not sprite then
   local hash=n.hash_hex or "unavailable"
   unknown[#unknown+1]={key="icon:"..hash,reason="icon unavailable",hash=hash}
  end
  if display~="icon" and not label then
   local reason=n.kind=="programmable_ammo" and n.label_reason or nil
   if type(reason)~="string" or reason=="" then reason="text label unavailable for "..n.kind end
   unknown[#unknown+1]={key="label:"..n.kind..":"..tostring(n.current)..":"..reason,reason=reason}
  end
 end
 if selected=="None" then return out,unknown end
 for _,side in ipairs(SIDES) do
  local d=modes and modes.directions[side]
  local n=native and native.directions[side]
  local chosen=false
  -- Flashlight is no longer a HUD option. A legacy choice stays stored and
  -- hidden until the player selects another direction; never replace it here.
  if (not selected or selected==side) and d and d.present and d.readable and
     d.action_enum~=5 and d.kind~="flashlight" and (not n or n.kind~="flashlight") then
   if d.kind=="rpm" and valid_rpm(d.current) and n and n.kind=="rpm" and n.current==d.current then
    chosen=true
    local sprite=display~="text" and icons.get(n.hash_hex) or nil
    local label=display~="icon" and Text.hud("mode.rpm",{value=math.floor(d.current+0.5)}) or nil
    unavailable(n,sprite,label)
    if sprite or label then
     out[#out+1]={kind="rpm",value=d.current,text=label,side=side,hash=n.hash_hex,sprite=sprite}
    end
   elseif n and n.current==d.current and (n.kind=="safe" or n.kind=="unsafe" or n.kind=="programmable_ammo" or n.kind=="binary_10"
     or (selected and (n.kind=="firemode" or n.kind=="zeroing" or n.kind=="laser_guide" or n.kind=="secondary_fire"))) then
    chosen=true
    local sprite=display~="text" and icons.get(n.hash_hex) or nil
    local label=display~="icon" and semantic_label(n) or nil
    unavailable(n,sprite,label)
    if sprite or label then
     out[#out+1]={kind=n.kind,value=n.current,hash=n.hash_hex,sprite=sprite,side=side,text=label}
    end
   end
   -- One selected stat per weapon. Before the first explicit selection retain
   -- the original automatic safety/ammunition/RPM preference, in side order.
   -- A readable chosen stat stays chosen when its presentation is unknown;
   -- do not silently show some other direction instead.
   if chosen then break end
  end
 end
 return out,unknown
end
function M.new(options)
 local sr=rawget(_G,"stingray") or {}
 local api=options.api or {App=sr.Application,World=sr.World,Gui=sr.Gui,Vector2=sr.Vector2,Color=sr.Color}
 if not api.App or not api.World or not api.Gui or not api.Vector2 or not api.Color or
    type(api.App.worlds)~="function" or type(api.World.num_units)~="function" or
    type(api.World.create_screen_gui)~="function" or type(api.World.destroy_gui)~="function" or
    type(api.Gui.rect)~="function" or type(api.Gui.render_resolution)~="function" then
  return nil,"screen GUI API unavailable"
 end
 local font=options.font
 if type(font)~="table" or type(font.glyphs)~="table" or type(font.height)~="number" or font.height<=0 then
  return nil,"HUD label font unavailable"
 end
 local function font_supports(value)
  if type(value)~="string" or value=="" then return false end
  if not Text.valid(value) then return false end
  for _,ch in Text.characters(value) do if not font.glyphs[ch] then return false end end
  return true
 end
 local self={layout=options.layout,icons=options.icons,display=display_mode(options.display),log=options.log or function()end,
  entries={},unknown={},gui=nil,owner=nil,shown=nil,next_render=0,next_size=0,preview=false,
  width=1920,height=1080}
 local function worlds()
  local ok,list=pcall(api.App.worlds)
  if not ok or type(list)~="table" or #list>64 then return {},"render worlds unavailable" end
  return list
 end
 local function alive(owner,list)
  for _,value in ipairs(list) do if value==owner then return true end end
  return false
 end
 function self:_drop()
  -- Never pass a GUI's old world back to the engine after it disappeared.
  local gui,owner=self.gui,self.owner
  self.gui,self.owner,self.shown,self.painted=nil,nil,nil,nil
  if not gui then return {status="no_gui"} end
  local list,why=worlds()
  if why then return {status="owner_unavailable"},why end
  if not owner or not alive(owner,list) then return {status="owner_gone"} end
  local ok,error_text=pcall(api.World.destroy_gui,owner,gui)
  if not ok then return nil,"GUI destruction failed: "..tostring(error_text) end
  return {status="destroyed"}
 end
 function self:_ensure()
  if self.closed then return nil,"HUD shut down" end
  local list=worlds()
  local best,count=nil,-1
  for _,world in ipairs(list) do
   local ok,n=pcall(api.World.num_units,world)
   if ok and type(n)=="number" and n>count then best,count=world,n end
  end
  if not best then return nil,"render world unavailable" end
  if self.gui and self.owner==best then return true end
  if self.gui then self:_drop() end
  self.gui,self.owner,self.shown,self.painted=nil,nil,nil,nil
  local ok,gui=pcall(api.World.create_screen_gui,best)
  if not ok or not gui then return nil,"screen GUI creation failed" end
  self.gui,self.owner=gui,best
  return true
 end
 function self:selection(resource)
  return self.layout:selection(resource)
 end
 function self:cycle_selection(resource,available_sides,initial_side)
  local selected,why=self.layout:cycle_selection(resource,available_sides,initial_side)
  if selected then self.entries={};self:_drop() end
  return selected,why
 end
 function self:set(modes,native,selected)
  local entries,unknown=M.entries(modes,native,self.icons,selected,self.display)
  self.entries={}
  for _,entry in ipairs(entries) do
   if entry.text and not font_supports(entry.text) then
    local key="label:"..entry.text
    if not self.unknown[key] then self.unknown[key]=true;self.log("HUD_SKIP label font cannot display full mode name") end
    entry.text=nil
   end
   if entry.sprite or entry.text then self.entries[#self.entries+1]=entry end
  end
  for _,issue in ipairs(unknown) do
   if not self.unknown[issue.key] then
    self.unknown[issue.key]=true
    self.log("HUD_SKIP reason="..issue.reason..(issue.hash and (" icon="..issue.hash) or "").." display="..self.display)
   end
  end
 end
 function self:finish_move()
  self.preview=false
  if not self.moving then return true end
  self.moving=false
  return self.layout:finish()
 end
 function self:cycle_display()
  local selected,why=self.layout:cycle_display()
  if selected then
   self.display=selected;self.entries={};self.next_render=0;self.next_size=0;self:_drop()
  end
  return selected,why
 end
 function self:cancel_move()
  -- An accepted full reset discards the in-progress movement gesture before
  -- backing up files. Its coordinator will reopen the layout after the reset;
  -- hiding/shutting down this renderer must not commit the old dirty layout.
  self.preview,self.moving=false,false
  return true
 end
 function self:hide()
  self:finish_move();self.entries={};self:_drop()
 end
 function self:shutdown()
  if self.closed then return {status="already_closed"} end
  self.closed=true
  -- Position persistence is isolated so an I/O failure cannot skip cleanup.
  local ok,saved,why=pcall(self.finish_move,self)
  self.entries={};self.preview=false
  local dropped,drop_error=self:_drop()
  if not dropped then return nil,drop_error end
  if not ok or not saved then dropped.position_error=tostring(ok and why or saved) end
  return dropped,drop_error
 end
 function self:move(time,intent)
  if self.closed then return false,"HUD shut down" end
  self.preview,self.moving=true,true
  return self.layout:move(time,intent)
 end
 local function rect(gui,x,y,w,h,colour)
  return api.Gui.rect(gui,api.Vector2(x,y),api.Vector2(w,h),colour)
 end
 local function text_metrics(value)
  if type(value)~="string" or value=="" then return nil end
  local pen,left,right=0,math.huge,-math.huge
  local top,bottom=math.huge,-math.huge
  for _,ch in Text.characters(value) do
   local g=font.glyphs[ch]
   -- Omitting an unknown character could silently change a mode's name.
   if not g then return nil end
   if g.width>0 then left=math.min(left,pen+g.bearing);right=math.max(right,pen+g.bearing+g.width) end
   for _,run in ipairs(g.r) do top=math.min(top,run[1]);bottom=math.max(bottom,run[1]+(run[5] or 1)) end
   pen=pen+g.advance
  end
  if right<=left then return nil end
  if bottom<=top then return nil end
  return right-left,left,top,bottom
 end
 local function text(gui,value,cx,y,height,max_width)
  -- Baked antialiased glyph coverage uses the same proven rectangle API as
  -- stock icons. No runtime font resource, material or texture is requested.
  -- Engine Color values may be frame-temporary; cache only within this draw.
  local text_colours={}
  local cell=height/font.height
  local width,left,_,bottom=text_metrics(value)
  if not width then return end
  if width*cell>max_width then cell=max_width/width end
  local x=cx-width*cell/2-left*cell
  for _,ch in Text.characters(value) do
   local glyph=font.glyphs[ch]
   if glyph then
    for _,run in ipairs(glyph.r) do
     local alpha=run[4]
     local colour=text_colours[alpha]
     if not colour then
      colour=api.Color(math.floor(alpha*235/255+0.5),240,240,226);text_colours[alpha]=colour
     end
     local h=run[5] or 1
     rect(gui,x+(glyph.bearing+run[2])*cell,y+(bottom-run[1]-h)*cell,run[3]*cell,h*cell,colour)
    end
    x=x+glyph.advance*cell
   end
  end
 end
 local function label_lines(value,height,max_width)
  if not text_metrics(value) then return {} end
  local lines,current={},""
  for word in value:gmatch("%S+") do
   local candidate=current=="" and word or (current.." "..word)
   local width=text_metrics(candidate)*height/font.height
   if current~="" and width>max_width and #lines<2 then
    lines[#lines+1]=current;current=word
   else current=candidate end
  end
  if current~="" then lines[#lines+1]=current end
  return lines
 end
 function self:render(time)
  if self.closed then return end
  if time<self.next_render then return end
  self.next_render=time+1/30
  if #self.entries==0 and not self.preview then self:_drop();return end
  local x,y=self.layout:position()
  local parts={tostring(math.floor(x)),tostring(math.floor(y)),tostring(self.preview),self.display}
  for _,e in ipairs(self.entries) do parts[#parts+1]=e.kind..":"..tostring(e.value)..":"..tostring(e.hash)..":"..tostring(e.text) end
  local signature=table.concat(parts,"|")
  if signature==self.shown and time<self.next_size then return end
  local ready,why=self:_ensure();if not ready then return nil,why end
  local rw,rh=api.Gui.render_resolution(self.gui)
  if type(rw)~="number" or type(rh)~="number" or rw<320 or rh<240 or rw>32768 or rh>32768 then
   return nil,"invalid render resolution"
  end
  local scale=math.min(rw/1920,rh/1080)
  local size,gap,pad=64*scale,8*scale,6*scale
  local plan,total_width,content_height={},0,0
  for _,entry in ipairs(self.entries) do
   local height=(entry.sprite and (entry.kind=="safe" or entry.kind=="unsafe") and 11 or entry.sprite and 14 or 18)*scale
   local lines=label_lines(entry.text,height,160*scale)
   if entry.sprite or #lines>0 then
    local width,label_height,line_y=size,0,{}
    for index=#lines,1,-1 do
     local line_width,_,top,bottom=text_metrics(lines[index])
     local cell=math.min(height/font.height,160*scale/line_width)
     width=math.max(width,math.min(160*scale,line_width*height/font.height))
     line_y[index]=label_height
     label_height=label_height+(bottom-top)*cell+(index>1 and 2*scale or 0)
    end
    local icon_offset=entry.sprite and (self.display=="icon" and 0 or math.max(16*scale,label_height+3*scale)) or 0
    local h=entry.sprite and size+icon_offset or label_height
    plan[#plan+1]={entry=entry,width=width,height=height,lines=lines,line_y=line_y,icon_offset=icon_offset,x=total_width}
    total_width=total_width+width+gap;content_height=math.max(content_height,h)
   end
  end
  if #plan==0 and not self.preview then self:_drop();return end
  if #plan==0 then total_width,content_height=size+gap,80*scale end
  local bw,bh=total_width+2*pad,content_height+2*pad
  local bounded,bounds_error=self.layout:set_bounds(rw,rh,bw,bh)
  if not bounded then return nil,bounds_error end
  x,y=self.layout:position()
  parts[1],parts[2]=tostring(math.floor(x)),tostring(math.floor(y))
  self.next_size=time+0.5
  signature=table.concat(parts,"|").."|"..rw.."x"..rh
  -- The observed working API uses persistent rectangles. Rebuild only when
  -- content/position/resolution changes, capped at 30 Hz during repositioning.
  if signature==self.painted then return end
  if self.shown then self:_drop();ready,why=self:_ensure();if not ready then return nil,why end end
  if #plan==0 then text(self.gui,"HUD",x+bw/2,y+bh/2-6*scale,12*scale,size) end
  for _,item in ipairs(plan) do
   local entry=item.entry
   local px=x+pad+item.x
   if entry.sprite then
    local sprite=entry.sprite
    local icon_x=px+(item.width-size)/2
    local function runs(rows,grid,alpha,dark)
     local cell=size/grid
     for _,run in ipairs(rows or {}) do
      local h=run[5] or 1
      rect(self.gui,icon_x+run[2]*cell,y+pad+item.icon_offset+(grid-run[1]-h)*cell,
       run[3]*cell,h*cell,
       api.Color(alpha[run[4]],dark and 0 or 240,dark and 0 or 240,dark and 0 or 226))
     end
    end
    runs(sprite.s,sprite.sg or sprite.g,self.icons.shadow_alpha,true)
    runs(sprite.r,sprite.g,self.icons.band_alpha,false)
   end
   for index,line in ipairs(item.lines) do
    text(self.gui,line,px+item.width/2,y+pad+item.line_y[index],item.height,item.width)
   end
  end
  self.shown=table.concat(parts,"|");self.painted=signature
  return true
 end
 return self
end
return M

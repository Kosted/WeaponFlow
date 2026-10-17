-- Contextual text presentation only. The caller owns the context and wording.
-- Uses the same proven persistent Gui.rect path as the optional mode HUD.
local M={}
local TEXT_SCALE=0.9
local function finite(value)
 return type(value)=="number" and value==value and value>-math.huge and value<math.huge
end
function M.new(options)
 options=options or {}
 local sr=rawget(_G,"stingray") or {}
 local api=options.api or {App=sr.Application,World=sr.World,Gui=sr.Gui,Vector2=sr.Vector2,Vector3=sr.Vector3,Color=sr.Color}
 if not api.App or not api.World or not api.Gui or not api.Vector2 or not api.Vector3 or not api.Color or
    type(api.App.worlds)~="function" or type(api.World.num_units)~="function" or
    type(api.World.create_screen_gui)~="function" or type(api.World.destroy_gui)~="function" or
    type(api.Gui.rect)~="function" or type(api.Gui.render_resolution)~="function" then
  return nil,"help screen GUI API unavailable"
 end
 local font=options.font
 if type(font)~="table" or type(font.glyphs)~="table" or not finite(font.height) or font.height<=0 then
  return nil,"help HUD font unavailable"
 end
 local self={paragraphs={},accents={},runs={},content="",next_render=0,next_viewport=0,icon_cache={},marks={},overlay_signature=""}
 local function report(message)
  if options.log then pcall(options.log,"HELP_HUD_SKIP "..message) end
 end
 local function worlds()
  local ok,list=pcall(api.App.worlds)
  if not ok or type(list)~="table" or #list>64 then return nil,"render worlds unavailable" end
  return list
 end
 local function alive(owner,list)
  for _,world in ipairs(list) do if world==owner then return true end end
  return false
 end
 function self:_drop()
  local gui,owner=self.gui,self.owner
  -- Clear first: shutdown or a failed engine call must not reuse old handles.
  self.gui,self.owner,self.painted=nil,nil,nil
  if not gui then return {status="no_gui"} end
  local list,why=worlds()
  if not list then return {status="owner_unavailable"},why end
  if not owner or not alive(owner,list) then return {status="owner_gone"} end
  local ok,err=pcall(api.World.destroy_gui,owner,gui)
  if not ok then return nil,"help GUI destruction failed: "..tostring(err) end
  return {status="destroyed"}
 end
 function self:_ensure()
  if self.closed then return nil,"help HUD shut down" end
  local list,why=worlds()
  if not list then self:_drop();return nil,why end
  -- Fixed UI world, independent of camera scene size and unit counts.
  local best=list[2]
  if not best then self:_drop();return nil,"screen UI world unavailable" end
  local ok,n=pcall(api.World.num_units,best)
  if not ok or not finite(n) or n<0 then self:_drop();return nil,"screen UI world unreadable" end
  if self.gui and self.owner==best then return true end
  if self.gui then self:_drop() end
  local ok,gui=pcall(api.World.create_screen_gui,best)
  if not ok or not gui then return nil,"help screen GUI creation failed" end
  self.gui,self.owner,self.painted=gui,best,nil
  return true
 end
 local function metrics(value,face)
  face=face or font
  local pen,left,right,top,bottom=0,math.huge,-math.huge,math.huge,-math.huge
  for _,ch in Text.characters(value) do
   local glyph=face.glyphs[ch]
   if not glyph then return nil end
   if glyph.width>0 then
    left=math.min(left,pen+glyph.bearing);right=math.max(right,pen+glyph.bearing+glyph.width)
   end
   for _,run in ipairs(glyph.r) do top=math.min(top,run[1]);bottom=math.max(bottom,run[1]+(run[5] or 1)) end
   pen=pen+glyph.advance
  end
  if right<=left or bottom<=top then return nil end
  return {width=right-left,left=left,top=top,bottom=bottom}
 end
 function self:hide()
  self.paragraphs={};self.accents={};self.runs={};self.content="";self.next_render=0
  self.marks,self.indicator,self.overlay_signature={},nil,""
  return self:_drop()
 end
 function self:set_overlay(marks,indicator)
  local copied,signature={},{}
  local function box(value)
   if type(value)~="table" then return nil end
   for _,key in ipairs({"x","y","w","h"}) do
    if not finite(value[key]) or value[key]<0 or value[key]>32768 then return nil end
   end
   if value.w==0 or value.h==0 then return nil end
   return {x=value.x,y=value.y,w=value.w,h=value.h}
  end
  if type(marks)~="table" or #marks>18 then return nil,"invalid wheel marks" end
  for _,value in ipairs(marks) do
   local row=box(value)
   local label=Text.clean(value.label,64)
   if not row or not label then return nil,"invalid wheel mark" end
   row.label=label;row.horizontal=value.side=="left" or value.side=="right";copied[#copied+1]=row
   signature[#signature+1]=table.concat({row.x,row.y,row.w,row.h,label,tostring(row.horizontal)},":")
  end
  local hud
  if indicator then
   hud=box(indicator)
   if not hud then return nil,"invalid HUD editor bounds" end
   hud.hidden=indicator.hidden==true;hud.key=Text.clean(indicator.key,160)
   hud.trigger=Text.valid(indicator.trigger,64) and indicator.trigger or nil
   signature[#signature+1]=table.concat({hud.x,hud.y,hud.w,hud.h,tostring(hud.hidden),hud.key or "",hud.trigger or ""},":")
  end
  local current=table.concat(signature,"|")
  if self.overlay_signature~=current then self.next_render=0 end
  self.marks,self.indicator,self.overlay_signature=copied,hud,current
  return true
 end
 function self:set(lines)
  if self.closed then return nil,"help HUD shut down" end
  local function reject(why)
   self:hide()
   if self.problem~=why then self.problem=why;report(why) end
   return nil,why
  end
  if type(lines)~="table" then return reject("help paragraphs unavailable") end
  local count=0
  for index in pairs(lines) do
   if index~="highlights" and index~="runs" then
    if not finite(index) or index%1~=0 or index<1 or index>24 then return reject("invalid help paragraph list") end
    count=count+1
   end
  end
  local highlights=lines.highlights
  if highlights==nil then highlights={} end
  if type(highlights)~="table" then return reject("invalid help highlights") end
  for index in pairs(highlights) do
   if not finite(index) or index%1~=0 or index<1 or index>count then return reject("invalid help highlight paragraph") end
  end
  local source_runs=lines.runs
  if source_runs==nil then source_runs={} end
  if type(source_runs)~="table" then return reject("invalid help runs") end
  for index in pairs(source_runs) do
   if not finite(index) or index%1~=0 or index<1 or index>count then return reject("invalid help run paragraph") end
  end
  local function token_text(value,limit,trim)
   if type(value)~="string" or #value>limit then return nil end
   if not Text.valid(value,limit) then return nil end
   value=Text.upper(value):gsub("%s+"," ")
   if trim then value=value:match("^%s*(.-)%s*$") end
   for _,ch in Text.characters(value) do if not font.glyphs[ch] then return nil end end
   return value
  end
  local paragraphs,accents,runs,total,run_total,run_signature={},{},{},0,0,{}
  for index=1,count do
   local value=lines[index]
   if not Text.valid(value,1024) then return reject("invalid help paragraph") end
   total=total+#value
   if total>4096 then return reject("help text exceeds display budget") end
   local ranges=highlights[index]
   if ranges==nil then ranges={} end
   if type(ranges)~="table" then return reject("invalid help highlight ranges") end
   local range_count=0
   for key in pairs(ranges) do
    if not finite(key) or key%1~=0 or key<1 or key>24 then return reject("invalid help highlight ranges") end
    range_count=range_count+1
   end
   local marked,last={},0
   for i=1,range_count do
    local range=ranges[i]
    if type(range)~="table" or not finite(range[1]) or not finite(range[2]) or
       range[1]%1~=0 or range[2]%1~=0 or range[1]<=last or range[2]<range[1] or range[2]>#value then
     return reject("invalid help highlight range")
    end
    for position=range[1],range[2] do marked[position]=true end
    last=range[2]
   end
   -- Normalize while retaining the original byte-to-accent relationship.
   -- Collapsed or leading spaces cannot shift a highlighted key into a word.
   local chars,mask,space,space_accent={},{},false,false
   for position,character in Text.characters(value) do
    local ch=Text.upper(character)
    if ch:match("%s") then
     if #chars>0 then space=true;space_accent=space_accent or marked[position]==true end
    else
     if not font.glyphs[ch] then return reject("font cannot display full help text") end
     if space then chars[#chars+1]=" ";mask[#mask+1]=space_accent and "1" or "0" end
     chars[#chars+1]=ch;mask[#mask+1]=string.rep(marked[position] and "1" or "0",#ch)
     space,space_accent=false,false
    end
   end
   value=table.concat(chars)
   local row_runs=source_runs[index]
   local copied,signature={},{ }
   if row_runs~=nil then
    if type(row_runs)~="table" then return reject("invalid help run list") end
    local n=0
    for key in pairs(row_runs) do
     if not finite(key) or key%1~=0 or key<1 or key>64 then return reject("invalid help run list") end
     n=n+1
    end
    for i=1,n do
     local token=row_runs[i]
     if type(token)~="table" then return reject("invalid help token") end
     for key in pairs(token) do
      if key~="kind" and key~="text" and key~="hash" and key~="caption" and key~="unavailable" and key~="accent" then
       return reject("invalid help token field")
      end
     end
     local kind=token.kind
     if kind~="text" and kind~="key" and kind~="icon" then return reject("invalid help token kind") end
     local text=token_text(token.text,kind=="text" and 512 or 160,kind~="text")
     if not text or (kind~="text" and text=="") then return reject("invalid help token text") end
     local hash=token.hash
     if hash~=nil and (kind~="icon" or type(hash)~="string" or #hash~=16 or hash:find("[^%x]")) then
      return reject("invalid help icon hash")
     end
     if hash then hash=hash:lower() end
     local caption=token.caption
     if caption~=nil then
      caption=kind=="icon" and token_text(caption,64,true) or nil
      if not caption then return reject("invalid help icon caption") end
      if caption=="" then caption=nil end
     end
     if token.unavailable~=nil and (kind~="icon" or type(token.unavailable)~="boolean") then
      return reject("invalid help icon availability")
     end
     if token.accent~=nil and (kind~="text" or type(token.accent)~="boolean") then
      return reject("invalid help text accent")
     end
     run_total=run_total+#text+#(caption or "")
     if run_total>4096 then return reject("help tokens exceed display budget") end
     copied[#copied+1]={kind=kind,text=text,hash=hash,caption=caption,unavailable=token.unavailable==true,accent=token.accent==true}
     -- Length prefixes make a binding containing punctuation unambiguous.
     signature[#signature+1]=kind..#text..":"..text..(hash or "-")..#(caption or "")..":"..
         (caption or "")..(token.unavailable and "!" or ".")..(token.accent and "*" or ".")
    end
   end
   -- Empty interior paragraphs are deliberate blank lines. Trim only the
   -- outer blanks so the last visible ink stays at the bottom anchor.
   if value~="" or #paragraphs>0 then
    paragraphs[#paragraphs+1]=value;accents[#accents+1]=table.concat(mask)
    runs[#paragraphs]=#copied>0 and copied or false
    run_signature[#paragraphs]=table.concat(signature,"|")
   end
  end
  while paragraphs[#paragraphs]=="" do table.remove(paragraphs);table.remove(accents);table.remove(runs);table.remove(run_signature) end
  local content=#paragraphs>0 and table.concat(paragraphs,"\n").."\0"..table.concat(accents,"\n")..
      "\0"..table.concat(run_signature,"\n") or ""
  self.problem=nil
  if content==self.content then return true end
  self.paragraphs,self.accents,self.runs,self.content=paragraphs,accents,runs,content
  self.next_render=0
  if content=="" then self:_drop() end
  return true
 end
 local function wrap(value,accent,cell,width,face)
  local result,current,current_mask={},{},{}
  local function flush()
   if #current>0 then
    result[#result+1]={text=table.concat(current),accent=table.concat(current_mask)}
    current,current_mask={},{}
   end
  end
  local function fits(text)
   local measured=metrics(text,face)
   return measured and measured.width*cell<=width
  end
  for start,word in value:gmatch("()(%S+)") do
   local mask=accent:sub(start,start+#word-1)
   local candidate=#current==0 and word or table.concat(current).." "..word
   if fits(candidate) then
    if #current>0 then current[#current+1]=" ";current_mask[#current_mask+1]=accent:sub(start-1,start-1) end
    current[#current+1]=word;current_mask[#current_mask+1]=mask
   else
    flush()
    -- A long unbroken localized name must wrap too, rather than clip or
    -- stretch the block beyond the viewport.
    for index,ch in Text.characters(word) do
     if #current>0 and not fits(table.concat(current)..ch) then flush() end
     current[#current+1]=ch;current_mask[#current_mask+1]=mask:sub(index,index+#ch-1)
    end
   end
  end
  flush()
  return result
 end
 local function icon(hash)
  if not hash or type(options.icons)~="table" or type(options.icons.get)~="function" then return nil end
  if self.icon_cache[hash]~=nil then return self.icon_cache[hash] or nil end
  local ok,sprite=pcall(options.icons.get,hash)
  local box
  if ok and type(sprite)=="table" and finite(sprite.g) and sprite.g>=1 and sprite.g<=1024 and
     type(sprite.r)=="table" and #sprite.r>0 and #sprite.r<=16384 then
   box={sprite=sprite,left=math.huge,top=math.huge,right=-math.huge,bottom=-math.huge}
   for _,run in ipairs(sprite.r) do
    if type(run)~="table" then box=nil;break end
    local y,x,w,alpha,h=run[1],run[2],run[3],run[4],run[5] or 1
    if not finite(x) or not finite(y) or not finite(w) or not finite(h) or not finite(alpha) or
       x<0 or y<0 or w<=0 or h<=0 or x+w>sprite.g or y+h>sprite.g or alpha<1 or alpha>255 then
     box=nil;break
    end
    box.left=math.min(box.left,x);box.top=math.min(box.top,y)
    box.right=math.max(box.right,x+w);box.bottom=math.max(box.bottom,y+h)
   end
  end
  self.icon_cache[hash]=box or false
  return box
 end
 local function rich_plan(tokens,height,width,scale,face)
  face=face or font
  local rows,items,used,row_height={},{},0,0
  local ascent,descent=0,0
  local baseline=face.baseline or face.height
  local space=face.glyphs[" "].advance*height/face.height
  local pending_space=false
  local function flush()
   if #items>0 then
    row_height=math.max(row_height,ascent+descent)
    rows[#rows+1]={items=items,width=used,height=row_height,
        text_baseline=(row_height-ascent-descent)/2+ascent}
   end
   items,used,row_height,pending_space={},0,0,false
   ascent,descent=0,0
  end
  local function add(item)
   local gap=#items>0 and pending_space and space or 0
   if used+gap+item.width>width and #items>0 then flush();gap=0 end
   if item.width>width then return nil,"help token exceeds available width" end
   item.x=used+gap;items[#items+1]=item;used=item.x+item.width
   row_height=math.max(row_height,item.height);pending_space=false
   if item.kind=="text" then
    ascent=math.max(ascent,(baseline-item.metrics.top)*item.cell)
    descent=math.max(descent,(item.metrics.bottom-baseline)*item.cell)
   end
   return true
  end
  local function text(value,accent)
   if value:match("^%s") then pending_space=true end
   for start,word,after in value:gmatch("()(%S+)()") do
    if start>1 and value:sub(start-1,start-1)==" " then pending_space=true end
    local measure=metrics(word,face)
    if not measure then return nil,"help token cannot be measured" end
    local cell=height/face.height
    local parts=measure.width*cell<=width and {{text=word}} or wrap(word,string.rep("0",#word),cell,width,face)
    for index,part in ipairs(parts) do
     if index>1 then flush() end
     local m=metrics(part.text,face)
     local ok,why=add({kind="text",face=face,text=part.text,accent=string.rep(accent and "1" or "0",#part.text),metrics=m,
        cell=cell,width=m.width*cell,height=(m.bottom-m.top)*cell})
     if not ok then return nil,why end
    end
    if after<=#value and value:sub(after,after)==" " then pending_space=true end
   end
   return true
  end
  local function labelled(kind,value,cap,padding_x,padding_y)
   local cell=cap/face.height
   local lines=wrap(value,string.rep(kind=="key" and "1" or "0",#value),cell,width-2*padding_x,face)
   local result={kind=kind,rows={},width=0,height=2*padding_y,cell=cell,pad_x=padding_x,pad_y=padding_y}
   for index,line in ipairs(lines) do
    local m=metrics(line.text,face)
    if not m then return nil end
    if index>1 then result.height=result.height+3*scale end
    result.rows[#result.rows+1]={face=face,text=line.text,accent=line.accent,metrics=m,offset=result.height-padding_y}
    result.height=result.height+(m.bottom-m.top)*cell
    result.width=math.max(result.width,m.width*cell+2*padding_x)
   end
   return result
  end
  for _,token in ipairs(tokens) do
   local ok,why
   if token.kind=="text" then ok,why=text(token.text,token.accent)
   elseif token.kind=="key" then
    -- A key is a single layout object. Exceptionally long labels can wrap
    -- inside its face without shrinking or truncating the actual binding.
    local key=labelled("key",token.text,16*TEXT_SCALE*scale,6*scale,5*scale)
    if not key then return nil,"help key cannot be measured" end
    key.width=math.max(key.width,26*scale)
    ok,why=add(key)
   else
    local box=icon(token.hash)
    if box then
     local cell=30*scale/(box.bottom-box.top)
     local item={kind="icon",box=box,cell=cell,width=(box.right-box.left)*cell,
         height=30*scale,icon_height=30*scale,captions={},unavailable=token.unavailable}
     local captions={}
     if token.caption then captions[#captions+1]=token.caption end
     for _,caption in ipairs(captions) do
      local label=labelled("caption",caption,14*TEXT_SCALE*scale,0,0)
      if not label then return nil,"help icon caption cannot be measured" end
      label.offset=item.height+3*scale
      item.captions[#item.captions+1]=label
      item.height=label.offset+label.height;item.width=math.max(item.width,label.width)
     end
     if item.width<=width then ok,why=add(item)
     else box=nil end
    end
    if not box then
     ok,why=text(token.text)
    end
   end
   if not ok then return nil,why end
  end
  flush()
  return rows
 end
 local function plan(height,width,scale)
  local rows,separators,used,max_width={},{},0,0
  local cell=height/font.height
  for paragraph,value in ipairs(self.paragraphs) do
   if value=="" then
    if #rows>0 and paragraph<#self.paragraphs then separators[#separators+1]=used+height/2 end
    used=used+height
   else
    if #rows>0 then used=used+12*scale end
    local face=options.onboarding and paragraph==1 and font.heading or font
    local cap=options.onboarding and paragraph==1 and height*1.12 or height
    if self.runs[paragraph] then
     local rich,why=rich_plan(self.runs[paragraph],cap,width,scale,face)
     if not rich then return nil,why end
     for index,row in ipairs(rich) do
      if index>1 then used=used+4*scale end
      row.offset=used;rows[#rows+1]=row;used=used+row.height
      max_width=math.max(max_width,row.width)
     end
    else
     for index,line in ipairs(wrap(value,self.accents[paragraph],cell,width)) do
      if index>1 then used=used+4*scale end
      local measure=metrics(line.text)
      if not measure then return nil,"help line cannot be measured" end
      rows[#rows+1]={text=line.text,accent=line.accent,metrics=measure,offset=used}
      max_width=math.max(max_width,measure.width*cell)
      used=used+(measure.bottom-measure.top)*cell
     end
    end
   end
  end
  return {rows=rows,separators=separators,height=used,width=max_width,cell=cell,cap_height=height}
 end
 local function paint(gui,row,x,top,cell,colours)
  local m=row.metrics
  local face=row.face or font
  local pen=x-m.left*cell
  for index,ch in Text.characters(row.text) do
   local accented=row.accent:sub(index,index)=="1"
   local glyph=face.glyphs[ch]
   local filtered=face.pixels and face.pixels(glyph,cell)
   for _,run in ipairs(filtered or glyph.r) do
    local alpha=run[4]
    local key=alpha+(accented and 256 or 0)
    local colour=colours[key]
    if not colour then
     colour=api.Color(math.floor(alpha*245/255+0.5),accented and 255 or 240,accented and 220 or 240,accented and 90 or 226)
     colours[key]=colour
    end
    local h=run[5] or 1
    local px,py,w,ph
    if filtered then
     px,py=math.floor(pen+glyph.bearing*cell+run[2]+0.5),math.floor(top+m.top*cell-run[1]-h+0.5)
     w,ph=run[3],h
    else px,py,w,ph=pen+(glyph.bearing+run[2])*cell,top-(run[1]-m.top+h)*cell,run[3]*cell,h*cell end
    api.Gui.rect(gui,api.Vector3(px,py,1022),api.Vector2(w,ph),colour)
   end
   pen=pen+glyph.advance*cell
  end
 end
 local function paint_label(gui,item,x,top,colours)
  for _,row in ipairs(item.rows) do
   paint(gui,row,x+(item.width-row.metrics.width*item.cell)/2,top-row.offset,item.cell,colours)
  end
 end
 local function paint_rich(gui,row,x,top,scale,colours)
  for _,item in ipairs(row.items) do
   local px,pt=x+item.x,top-(row.height-item.height)/2
   if item.kind=="text" then
    -- All words share the row's baseline. Ink bounds still include accents,
    -- punctuation and descenders without moving neighboring words.
    local face=item.face or font
    pt=top-row.text_baseline+((face.baseline or face.height)-item.metrics.top)*item.cell
    paint(gui,item,px,pt,item.cell,colours)
   elseif item.kind=="key" then
    -- Procedural keycaps work for every supported binding name, including
    -- remapped mouse labels and modifier combinations; no keyboard allowlist.
    local border=scale
    api.Gui.rect(gui,api.Vector3(px,pt-item.height,1022),api.Vector2(item.width,item.height),api.Color(235,142,142,130))
    api.Gui.rect(gui,api.Vector3(px+border,pt-item.height+border,1022),
        api.Vector2(item.width-2*border,item.height-2*border),api.Color(245,30,34,35))
    paint_label(gui,item,px,pt,colours)
   else
    local box=item.box
    local ix=px+(item.width-(box.right-box.left)*item.cell)/2
    for _,run in ipairs(box.sprite.r) do
     local alpha=math.floor(run[4]*(item.unavailable and 120 or 245)/255+0.5)
     local key=alpha+512
     local colour=colours[key]
     if not colour then colour=api.Color(alpha,240,240,226);colours[key]=colour end
     local h=run[5] or 1
     api.Gui.rect(gui,api.Vector3(ix+(run[2]-box.left)*item.cell,pt-(run[1]-box.top+h)*item.cell,1022),
         api.Vector2(run[3]*item.cell,h*item.cell),colour)
    end
    for _,caption in ipairs(item.captions) do
     paint_label(gui,caption,px+(item.width-caption.width)/2,pt-caption.offset,colours)
    end
   end
  end
 end
 local function paint_panel(x,top,layout,scale,pad_x,pad_y)
  local left,bottom=x-pad_x,top-layout.height-pad_y
  local width,height=layout.width+2*pad_x,layout.height+2*pad_y
  local function rect(px,py,w,h,colour)
   local right,upper=math.floor(px+w+0.5),math.floor(py+h+0.5)
   px,py=math.floor(px+0.5),math.floor(py+0.5)
   if right>px and upper>py then
    api.Gui.rect(self.gui,api.Vector3(px,py,1022),api.Vector2(right-px,upper-py),colour)
   end
  end
  local stroke=math.max(1,math.floor(scale+0.5))
  local cut=math.min(math.max(3,math.floor(6*scale+0.5)),math.floor(height/3))
  local function shade(t)
   return api.Color(232,math.floor(12+16*t+0.5),math.floor(14+16*t+0.5),math.floor(12+16*t+0.5))
  end
  -- Dive Ready's charcoal surface and clipped right corners, using only
  -- the existing retained rectangles; no texture or extra GUI is needed.
  rect(left+3*scale,bottom-3*scale,width,height,api.Color(75,0,0,0))
  for i=0,11 do
   local y=cut+(height-2*cut)*i/12
   rect(left,bottom+y,width,(height-2*cut)/12,shade((y+(height-2*cut)/24)/height))
  end
  for i=0,cut-1 do
   rect(left,bottom+i,width-cut+i+1,1,shade((i+0.5)/height))
   rect(left,bottom+height-i-1,width-cut+i+1,1,shade(1-(i+0.5)/height))
  end
  local edge=api.Color(225,113,119,111)
  rect(left,bottom,width-cut,stroke,edge);rect(left,bottom+height-stroke,width-cut,stroke,edge)
  rect(left,bottom,stroke,height,edge);rect(left+width-stroke,bottom+cut,stroke,height-2*cut,edge)
  for i=0,cut-1 do
   rect(left+width-cut+i-stroke,bottom+i,stroke+1,1,edge)
   rect(left+width-cut+i-stroke,bottom+height-i-1,stroke+1,1,edge)
  end
  rect(left+stroke,bottom+height-2*stroke,math.min(84*scale,width/4),2*stroke,api.Color(255,255,233,0))
  for _,offset in ipairs(layout.separators) do
   rect(x,top-offset,layout.width,stroke,api.Color(140,83,90,82))
  end
 end
 local function paint_overlay(rw,rh,scale,colours,phase)
  local yellow=api.Color(phase==0 and 245 or 145,255,215,65)
  local arrow_colour=api.Color(245,255,215,65)
  local shadow=api.Color(190,8,10,10)
  local function rect(x,y,w,h,colour)
   local right,top=math.min(rw-1,x+w),math.min(rh-1,y+h)
   x,y=math.max(1,x),math.max(1,y)
   if right>x and top>y then api.Gui.rect(self.gui,api.Vector3(x,y,1022),api.Vector2(right-x,top-y),colour) end
  end
  local function frame(b)
   local pad=4*scale
   local x,y,w,h=b.x-pad,b.y-pad,b.w+2*pad,b.h+2*pad
   if b.horizontal then w,h=h,w end
   local function bracket_rect(px,py,pw,ph,colour)
    if b.horizontal then rect(x+py-y,y+px-x,ph,pw,colour)
    else rect(px,py,pw,ph,colour) end
   end
   local stroke,radius,arm=2*scale,math.min(6*scale,w/6,h/6),math.min(12*scale,w*0.14)
   local function corner(cx,cy,sx,sy,r,t,opacity)
    self.corner_masks=self.corner_masks or {}
    local key=string.format("%.3f:%.3f",r,t)
    local mask=self.corner_masks[key]
    if not mask then
     mask={}
     local function coverage(v) return math.max(0,math.min(1,v)) end
     for py=0,math.ceil(r)-1 do
      for px=0,math.ceil(r)-1 do
       local distance=math.sqrt((px+0.5)^2+(py+0.5)^2)
       local alpha=math.floor(255*(coverage(r+0.5-distance)-coverage(r-t+0.5-distance))+0.5)
       if alpha>0 then mask[#mask+1]={px,py,alpha} end
      end
     end
     self.corner_masks[key]=mask
    end
    local colours={}
    for _,pixel in ipairs(mask) do
     local alpha=math.floor(pixel[3]*opacity/255+0.5)
     local colour=colours[alpha]
     if not colour then
      colour=opacity==190 and api.Color(alpha,8,10,10) or api.Color(alpha,255,215,65)
      colours[alpha]=colour
     end
     bracket_rect(cx+(sx<0 and -pixel[1]-1 or pixel[1]),cy+(sy<0 and -pixel[2]-1 or pixel[2]),1,1,colour)
    end
   end
   for _,left in ipairs({true,false}) do
    local edge=left and x or x+w-stroke
    bracket_rect(edge-scale,y+radius,stroke+2*scale,h-2*radius,shadow)
    bracket_rect(edge,y+radius,stroke,h-2*radius,yellow)
    local start=left and x+radius or x+w-arm
    bracket_rect(start,y-scale,arm-radius,stroke+2*scale,shadow)
    bracket_rect(start,y+h-stroke-scale,arm-radius,stroke+2*scale,shadow)
    bracket_rect(start,y,arm-radius,stroke,yellow);bracket_rect(start,y+h-stroke,arm-radius,stroke,yellow)
    local cx=left and x+radius or x+w-radius
    for _,top in ipairs({true,false}) do
     local cy=top and y+h-radius or y+radius
     corner(cx,cy,left and -1 or 1,top and 1 or -1,radius+scale,stroke+2*scale,190)
     corner(cx,cy,left and -1 or 1,top and 1 or -1,radius,stroke,phase==0 and 245 or 145)
    end
   end
  end
  local function badge_plan(value,key)
   local tokens={}
   if type(value)=="table" then
    for _,part in ipairs(value) do
     if part[2] then
      local from=1
      while true do
       local first,last=part[1]:find(" [+/] ",from)
       tokens[#tokens+1]={kind="key",text=part[1]:sub(from,first and first-1 or #part[1])}
       if not first then break end
       tokens[#tokens+1]={kind="text",text=part[1]:sub(first,last)};from=last+1
      end
     else tokens[#tokens+1]={kind="text",text=part[1],accent=true} end
    end
   elseif key then
    local from=1
    while true do
     local first,last=value:find(" [+/] ",from)
     tokens[#tokens+1]={kind="key",text=value:sub(from,first and first-1 or #value)}
     if not first then break end
     tokens[#tokens+1]={kind="text",text=value:sub(first,last)};from=last+1
    end
   else tokens[1]={kind="text",text=value,accent=true} end
   local rows=rich_plan(tokens,12.6*scale,math.min(320*scale,rw-16*scale),scale)
   if not rows then return end
   local width,height=0,0
   for _,row in ipairs(rows) do width=math.max(width,row.width);height=height+row.height+2*scale end
   return {rows=rows,width=width,height=height}
  end
  local function paint_badge(plan,cx,cy,inside)
   if not plan then return false end
   local width,height=plan.width,plan.height
   local x,top=cx-width/2,cy+height/2
   if (inside==true or inside=="horizontal") and (x<6*scale or x+width>rw-6*scale) then return false end
   if (inside==true or inside=="vertical") and (top>rh-6*scale or top-height<6*scale) then return false end
   x=math.max(6*scale,math.min(rw-width-6*scale,x))
   top=math.max(height+6*scale,math.min(rh-6*scale,top))
   rect(x-3*scale,top-height-2*scale,width+6*scale,height+4*scale,api.Color(220,12,15,16))
   for _,row in ipairs(plan.rows) do paint_rich(self.gui,row,x,top,scale,colours);top=top-row.height-2*scale end
   return true
  end
  local function badge(value,cx,cy,key,inside)
   return paint_badge(badge_plan(value,key),cx,cy,inside)
  end
  for _,mark in ipairs(self.marks) do
   frame(mark);badge(mark.label,mark.x+mark.w/2,mark.y+mark.h+14*scale)
  end
  local b=self.indicator
  if not b then return end
  frame(b)
  if not b.hidden then badge("HUD",b.x+b.w/2,b.y+b.h+13*scale) end
  local function arrow(x,y,dx,dy)
   if dy~=0 then
    rect(x-scale,y-5*scale,2*scale,10*scale,arrow_colour)
    for i=0,4 do rect(x-i*scale,y+dy*(5-i)*scale,(2*i+1)*scale,scale,arrow_colour) end
   else
    rect(x-5*scale,y-scale,10*scale,2*scale,arrow_colour)
    for i=0,4 do rect(x+dx*(5-i)*scale,y-i*scale,scale,(2*i+1)*scale,arrow_colour) end
   end
  end
  local cx,cy=b.x+b.w/2,b.y+b.h/2
  if badge(Text.hud("key.up"),cx,b.y+b.h+62*scale,true,"vertical") then arrow(cx,b.y+b.h+36*scale,0,1) end
  if badge(Text.hud("key.down"),cx,b.y-42*scale,true,"vertical") then arrow(cx,b.y-16*scale,0,-1) end
  local left,right=badge_plan(Text.hud("key.left"),true),badge_plan(Text.hud("key.right"),true)
  if left and paint_badge(left,b.x-30*scale-left.width/2,cy,"horizontal") then arrow(b.x-16*scale,cy,-1,0) end
  if right and paint_badge(right,b.x+b.w+30*scale+right.width/2,cy,"horizontal") then arrow(b.x+b.w+16*scale,cy,1,0) end
  if b.hidden then
   local parts
   if b.key then
    parts=Text.parts("help.reveal",{key=b.key,trigger=Text.trigger(b.trigger) or Text.hud("state.unavailable")},{key=true})
   else parts={{Text.hud("state.unavailable")}} end
   local hint=badge_plan(parts)
   if hint then
    local x=b.x+b.w+16*scale+hint.width/2
    if x+hint.width/2>rw-6*scale then x=b.x-16*scale-hint.width/2 end
    paint_badge(hint,x,b.y+b.h+20*scale)
   end
  end
 end
 function self:render(time)
  if self.closed then return end
  if not finite(time) then return nil,"invalid help render time" end
  if time<self.next_render then return end
  self.next_render=time+1/30
  if self.content=="" then self:_drop();return end
  local phase=(#self.marks>0 or self.indicator) and math.floor(time/0.6)%2 or 0
  local content=self.content.."\0"..self.overlay_signature..":"..phase
  if self.painted and self.painted_content==content and time<self.next_viewport then return end
  local ready,why=self:_ensure();if not ready then return nil,why end
  local rw,rh=api.Gui.render_resolution(self.gui)
  if not finite(rw) or not finite(rh) or rw<320 or rh<240 or rw>32768 or rh>32768 then
   self:_drop();return nil,"invalid help render resolution"
  end
  self.next_viewport=time+0.5
  local signature=content.."|"..rw.."x"..rh
  if self.painted==signature then return end
  local scale=math.min(rw/1920,rh/1080)
  local margin=24*scale
  local pad_x,pad_y=14*scale,10*scale
  local x=math.max(margin,rw*0.52)
  if options.onboarding then x=margin end
  local width=math.min(rw*0.42,rw-x-margin-pad_x)
  local available=rh*0.42-margin
  local height=18*TEXT_SCALE*scale
  local layout,layout_error=plan(height,width,scale)
  if not layout then self:_drop();return nil,layout_error end
  -- Normally 16.2px cap height at 1080p. Dense valid paragraphs may shrink to
  -- 12px; if that still cannot fit, refuse instead of drawing offscreen.
  while layout.height>available and height>12*scale do
   height=math.max(12*scale,height-1*scale)
   layout,layout_error=plan(height,width,scale)
   if not layout then self:_drop();return nil,layout_error end
  end
  if layout.height>available then self:_drop();return nil,"help text exceeds available viewport" end
  -- Anchor the last visible line near the bottom. Extra lines and explicit
  -- spacers grow upward rather than moving the controls away from that edge.
  local top=margin+layout.height
  if options.onboarding then top=math.max(top,rh*0.72) end
  if self.painted then
   self:_drop();ready,why=self:_ensure();if not ready then return nil,why end
  end
  -- Color/vector temporaries are local to this draw, never retained in Lua.
  local colours={}
  paint_panel(x,top,layout,scale,pad_x,pad_y)
  for _,row in ipairs(layout.rows) do
   if row.items then paint_rich(self.gui,row,x,top-row.offset,scale,colours)
   else paint(self.gui,row,x,top-row.offset,layout.cell,colours) end
  end
  paint_overlay(rw,rh,scale,colours,phase)
  self.painted,self.painted_content=signature,content
  return true
 end
 function self:shutdown()
  if self.closed then return {status="already_closed"} end
  self.closed=true;self.paragraphs={};self.accents={};self.runs={};self.content=""
  self.marks,self.indicator,self.overlay_signature={},nil,""
  return self:_drop()
 end
 return self
end
return M

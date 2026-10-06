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
 local api=options.api or {App=sr.Application,World=sr.World,Gui=sr.Gui,Vector2=sr.Vector2,Color=sr.Color}
 if not api.App or not api.World or not api.Gui or not api.Vector2 or not api.Color or
    type(api.App.worlds)~="function" or type(api.World.num_units)~="function" or
    type(api.World.create_screen_gui)~="function" or type(api.World.destroy_gui)~="function" or
    type(api.Gui.rect)~="function" or type(api.Gui.render_resolution)~="function" then
  return nil,"help screen GUI API unavailable"
 end
 local font=options.font
 if type(font)~="table" or type(font.glyphs)~="table" or not finite(font.height) or font.height<=0 then
  return nil,"help HUD font unavailable"
 end
 local self={paragraphs={},accents={},runs={},content="",next_render=0,next_viewport=0,icon_cache={}}
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
  local best,count=nil,-1
  for _,world in ipairs(list) do
   local ok,n=pcall(api.World.num_units,world)
   if ok and finite(n) and n>=0 and n>count then best,count=world,n end
  end
  if not best then self:_drop();return nil,"render world unavailable" end
  if self.gui and self.owner==best then return true end
  if self.gui then self:_drop() end
  local ok,gui=pcall(api.World.create_screen_gui,best)
  if not ok or not gui then return nil,"help screen GUI creation failed" end
  self.gui,self.owner,self.painted=gui,best,nil
  return true
 end
 local function metrics(value)
  local pen,left,right,top,bottom=0,math.huge,-math.huge,math.huge,-math.huge
  for _,ch in Text.characters(value) do
   local glyph=font.glyphs[ch]
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
  return self:_drop()
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
 local function wrap(value,accent,cell,width)
  local result,current,current_mask={},{},{}
  local function flush()
   if #current>0 then
    result[#result+1]={text=table.concat(current),accent=table.concat(current_mask)}
    current,current_mask={},{}
   end
  end
  local function fits(text)
   local measured=metrics(text)
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
 local function rich_plan(tokens,height,width,scale)
  local rows,items,used,row_height={},{},0,0
  local ascent,descent=0,0
  local baseline=font.baseline or font.height
  local space=font.glyphs[" "].advance*height/font.height
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
    local measure=metrics(word)
    if not measure then return nil,"help token cannot be measured" end
    local cell=height/font.height
    local parts=measure.width*cell<=width and {{text=word}} or wrap(word,string.rep("0",#word),cell,width)
    for index,part in ipairs(parts) do
     if index>1 then flush() end
     local m=metrics(part.text)
     local ok,why=add({kind="text",text=part.text,accent=string.rep(accent and "1" or "0",#part.text),metrics=m,
        cell=cell,width=m.width*cell,height=(m.bottom-m.top)*cell})
     if not ok then return nil,why end
    end
    if after<=#value and value:sub(after,after)==" " then pending_space=true end
   end
   return true
  end
  local function labelled(kind,value,cap,padding_x,padding_y)
   local cell=cap/font.height
   local lines=wrap(value,string.rep(kind=="key" and "1" or "0",#value),cell,width-2*padding_x)
   local result={kind=kind,rows={},width=0,height=2*padding_y,cell=cell,pad_x=padding_x,pad_y=padding_y}
   for index,line in ipairs(lines) do
    local m=metrics(line.text)
    if not m then return nil end
    if index>1 then result.height=result.height+3*scale end
    result.rows[#result.rows+1]={text=line.text,accent=line.accent,metrics=m,offset=result.height-padding_y}
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
  local rows,used,max_width={},0,0
  local cell=height/font.height
  for paragraph,value in ipairs(self.paragraphs) do
   if value=="" then used=used+height
   else
    if #rows>0 then used=used+12*scale end
    if self.runs[paragraph] then
     local rich,why=rich_plan(self.runs[paragraph],height,width,scale)
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
  return {rows=rows,height=used,width=max_width,cell=cell,cap_height=height}
 end
 local function paint(gui,row,x,top,cell,colours)
  local m=row.metrics
  local pen=x-m.left*cell
  for index,ch in Text.characters(row.text) do
   local accented=row.accent:sub(index,index)=="1"
   local glyph=font.glyphs[ch]
   for _,run in ipairs(glyph.r) do
    local alpha=run[4]
    local key=alpha+(accented and 256 or 0)
    local colour=colours[key]
    if not colour then
     colour=api.Color(math.floor(alpha*245/255+0.5),accented and 255 or 240,accented and 220 or 240,accented and 90 or 226)
     colours[key]=colour
    end
    local h=run[5] or 1
    api.Gui.rect(gui,api.Vector2(pen+(glyph.bearing+run[2])*cell,top-(run[1]-m.top+h)*cell),
        api.Vector2(run[3]*cell,h*cell),colour)
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
    pt=top-row.text_baseline+((font.baseline or font.height)-item.metrics.top)*item.cell
    paint(gui,item,px,pt,item.cell,colours)
   elseif item.kind=="key" then
    -- Procedural keycaps work for every supported binding name, including
    -- remapped mouse labels and modifier combinations; no keyboard allowlist.
    local border=scale
    api.Gui.rect(gui,api.Vector2(px,pt-item.height),api.Vector2(item.width,item.height),api.Color(235,142,142,130))
    api.Gui.rect(gui,api.Vector2(px+border,pt-item.height+border),
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
     api.Gui.rect(gui,api.Vector2(ix+(run[2]-box.left)*item.cell,pt-(run[1]-box.top+h)*item.cell),
         api.Vector2(run[3]*item.cell,h*item.cell),colour)
    end
    for _,caption in ipairs(item.captions) do
     paint_label(gui,caption,px+(item.width-caption.width)/2,pt-caption.offset,colours)
    end
   end
  end
 end
 function self:render(time)
  if self.closed then return end
  if not finite(time) then return nil,"invalid help render time" end
  if time<self.next_render then return end
  self.next_render=time+1/30
  if self.content=="" then self:_drop();return end
  if self.painted and self.painted_content==self.content and time<self.next_viewport then return end
  local ready,why=self:_ensure();if not ready then return nil,why end
  local rw,rh=api.Gui.render_resolution(self.gui)
  if not finite(rw) or not finite(rh) or rw<320 or rh<240 or rw>32768 or rh>32768 then
   self:_drop();return nil,"invalid help render resolution"
  end
  self.next_viewport=time+0.5
  local signature=self.content.."|"..rw.."x"..rh
  if self.painted==signature then return end
  local scale=math.min(rw/1920,rh/1080)
  local margin=24*scale
  local pad_x,pad_y=14*scale,10*scale
  local x=math.max(margin,rw*0.52)
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
  if self.painted then
   self:_drop();ready,why=self:_ensure();if not ready then return nil,why end
  end
  -- Color/vector temporaries are local to this draw, never retained in Lua.
  local colours={}
  api.Gui.rect(self.gui,api.Vector2(x-pad_x,margin-pad_y),
      api.Vector2(layout.width+2*pad_x,layout.height+2*pad_y),api.Color(160,10,13,15))
  for _,row in ipairs(layout.rows) do
   if row.items then paint_rich(self.gui,row,x,top-row.offset,scale,colours)
   else paint(self.gui,row,x,top-row.offset,layout.cell,colours) end
  end
  self.painted,self.painted_content=signature,self.content
  return true
 end
 function self:shutdown()
  if self.closed then return {status="already_closed"} end
  self.closed=true;self.paragraphs={};self.accents={};self.runs={};self.content=""
  return self:_drop()
 end
 return self
end
return M

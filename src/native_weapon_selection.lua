-- Direct final selection for the non-adjacent choice of a three-slot setting.
-- Ports the captured cycle's state/publication tail without visiting a mode.
-- Evidence: analysis/direct-modes-200-20261016/; called only by the coordinator.
local M={}
local KINDS={[1]="zeroing",[2]="rpm",[3]="firemode"}
local SIDES={left=1,right=2,up=3,down=4}
local function check(value,why) if not value then error(why,0) end return value end
local function u32(s,o)
 check(type(s)=="string" and #s>=o+4,"truncated direct-selection preimage")
 local a,b,c,d=s:byte(o+1,o+4);return a+b*256+c*65536+d*16777216
end
local function pack(value)
 return string.char(value%256,math.floor(value/256)%256,math.floor(value/65536)%256,math.floor(value/16777216)%256)
end
local function unhex(value)
 return (value:gsub("..",function(pair)return string.char(tonumber(pair,16))end))
end
M.anchors={
 {rva=0x75537e,hex="4c8b4560448bd0b8abaaaaaa4f8d0c52438b4c88044d8d49018bf183e1cfc1ee0483e603ffc6f7e6d1ea8d0452ba6561f8312bf08bc6c1e0040bc843890c88488b45604e8d0488488b45484a8b0cd08b4910e80b448800"},
 {rva=0x755459,hex="418bf68bcbc1ee0c83e603e8d74888004885c0742c488bc8e8ca45dbff39b890000000400f95c783b894000000008d4f010f44cf83b898000000008d79010f44f933d28d4601f7f74181e6ffcfffff8bc28bfac1e00cba6561f831440bf0478974a504488b45484c8b45604983c0044a8b0cf84f8d04a08b4910e808438800448bc78bd3e80e130000448bc08bd3488bcd8bf0e89f0a0000"},
 {rva=0x6179ed,hex="8b4f1c83c104f7e1d1ea8d04522bc8448bc18bc14489471c"},
 {rva=0x617aad,hex="488b8380000000488d0c76488d4901baa2c2bc4cf30f113488488b83800000004c8d0488488b4368488b0cf08b4910e8ff1c9c008b471c"},
 {rva=0x755f90,hex="48894c24085355565741574883ec204c89642458"},
 {rva=0x755990,hex="4c894424185341554883ec483b157ee2d202458be98bda4c8bd9"},
 {rva=0xfd97e0,hex="48896c241856415641574883ec30488b05a32749024d8bf0"},
}
for _,anchor in ipairs(M.anchors) do anchor.bytes=unhex(anchor.hex) end

local function target_slot(dir,value)
 check(type(dir)=="table" and dir.present==true and dir.readable==true and not dir.inactive and
  dir.cycle_supported==true and KINDS[dir.action_enum]==dir.kind,"direct setting is not readable/selectable")
 check(type(dir.slot_values)=="table" and #dir.slot_values==3 and type(dir.choices)=="table" and
  #dir.choices==3,"direct selection requires three confirmed choices")
 check(type(dir.slot)=="number" and dir.slot%1==0 and dir.slot>=0 and dir.slot<3 and
  dir.slot_values[dir.slot+1]==dir.current,"direct current slot disagrees with its value")
 local seen,target={}
 for index,choice in ipairs(dir.slot_values) do
  check(type(choice)=="number" and choice>0 and choice==dir.choices[index] and not seen[choice],
   "direct choices are not unique native slots")
  seen[choice]=true
  if type(value)=="number" and math.abs(choice-value)<0.001 then
   check(target==nil,"direct saved value matches multiple native choices")
   target=index-1
  end
 end
 check(target~=nil and target~=dir.slot and target~=(dir.slot+1)%3,
  "direct selection is only for a confirmed non-adjacent target")
 return target
end

local function native_api(game)
 local ffi=require("ffi")
 check(ffi.os=="Windows" and ffi.abi("64bit"),"direct selection requires Windows x64")
 local kernel=ffi.load("kernel32")
 local function bind(name,declaration)
  local ok,value=pcall(function()return kernel[name]end)
  if not ok then ffi.cdef(declaration);value=kernel[name] end
  local result,args=declaration:match("^(.-)"..name.."(%b());$")
  return ffi.cast(result.." (__stdcall *)"..args,value)
 end
 local process=bind("GetCurrentProcess","void *GetCurrentProcess(void);")()
 local write=bind("WriteProcessMemory","int WriteProcessMemory(void *, void *, const void *, size_t, size_t *);")
 local count=ffi.new("size_t[1]")
 local publish=ffi.cast("void (__fastcall *)(unsigned int, unsigned int, const void *)",game+0xfd97e0)
 local fire=ffi.cast("void (__fastcall *)(void *, unsigned int, unsigned int)",game+0x755f90)
 local remember=ffi.cast("void (__fastcall *)(void *, unsigned int, const unsigned int *, unsigned int)",game+0x755990)
 return {
  write=function(address,bytes)
   check(#bytes==4,"direct write must be exactly one native dword")
   count[0]=0
   local ok=write(process,ffi.cast("void *",address),bytes,4,count)
   return ok~=0 and tonumber(count[0])==4
  end,
  publish=function(network,field,address)publish(network,field,ffi.cast("const void *",address))end,
  fire=function(manager,eid,value)fire(ffi.cast("void *",manager),eid,value)end,
  remember=function(manager,eid,action,value)
   remember(ffi.cast("void *",manager),eid,ffi.new("unsigned int[1]",action),value)
  end,
 }
end

function M.new(options)
 check(type(options)=="table" and type(options.modes)=="table" and type(options.modes.inspect)=="function",
  "direct selection requires the guarded weapon reader")
 local self={}
 function self:apply(reader,snapshot,side,value,expected)
  local attempted=false
  local ok,result=pcall(function()
   check(SIDES[side] and type(expected)=="table","direct selection context unavailable")
   local valid,why=reader:verify();check(valid,why or "unsupported native build")
   -- Bind the writer first. No stale pointer may survive its initialization.
   if not self.api or self.game~=reader.game then
    self.api=options.api or native_api(reader.game);self.game=reader.game
   end
   local fresh,failure=options.modes.inspect(reader,snapshot)
   check(fresh,failure or "direct native inspection unavailable")
   local dir=fresh.directions[side]
   local slot=target_slot(dir,value)
   local previous=expected.directions and expected.directions[side]
   check(previous and fresh.weapon_bytes==expected.weapon_bytes and fresh.weapon_eid==expected.weapon_eid and
    fresh.weapon_manager==expected.weapon_manager and fresh.state_bytes==expected.state_bytes and
    fresh.functions_bytes==expected.functions_bytes and dir.action_enum==previous.action_enum and
    dir.current==previous.current and dir.slot==previous.slot and dir.choice_address==previous.choice_address and
    dir.choice_bytes==previous.choice_bytes and dir.rate_bytes==previous.rate_bytes,
    "direct setting changed before action")
   local plan,plan_error=reader:transaction(function(read,ptr,lookup)
    local active=reader:guard_active(snapshot,read,ptr,lookup)
    check(active.bytes==fresh.weapon_bytes and active.entity.eid==fresh.weapon_eid,
     "direct active weapon identity changed")
    for _,anchor in ipairs(M.anchors) do
     check(read(reader.game+anchor.rva,#anchor.bytes)==anchor.bytes,"direct native code signature mismatch")
    end
    local manager=ptr(reader.game+0x3326ce0)
    check(manager==fresh.weapon_manager,"direct weapon manager changed")
    local index=lookup(read(manager+0x30,20),fresh.weapon_eid,1048576)
    check(index~=nil and index>=0 and index<262144,"direct weapon registry index unavailable")
    check(read(ptr(ptr(manager+0x48)+index*8),24)==fresh.weapon_bytes,"direct weapon registry identity changed")
    local address=ptr(manager+0x60)+index*12
    local runtime=ptr(manager+0x58)+index*0x3f0
    check(address==fresh.state_address and read(address,12)==fresh.state_bytes and
     runtime==fresh.runtime_address and read(runtime+0x350,16)==fresh.functions_bytes and
     u32(fresh.functions_bytes,(SIDES[side]-1)*4)==dir.action_enum,"direct state/function preimage changed")
    check(read(dir.choice_address,#dir.choice_bytes)==dir.choice_bytes,"direct offered values changed")
    if dir.action_enum~=2 then
     local definition=options.modes.definition_address(read,ptr,lookup,reader.game,manager,active)
     check(definition==fresh.definition_address and
      dir.choice_address==definition+(dir.action_enum==1 and 0x154 or 0x90),"direct instance definition changed")
    end
    local p={writes={},network=u32(fresh.weapon_bytes,16),manager=manager,eid=fresh.weapon_eid,
     action=dir.action_enum,slot=slot,result=dir.action_enum==3 and dir.slot_values[slot+1] or slot}
    if dir.action_enum==2 then
     local pm=ptr(reader.game+0x33266d8)
     local pi=lookup(read(pm+0x50,20),fresh.weapon_eid,1048576)
     check(pm==dir.rpm_manager and pi==dir.rpm_index and pi~=nil and pi>=0 and pi<262144,
      "direct RPM registry changed")
     check(read(ptr(ptr(pm+0x68)+pi*8),24)==fresh.weapon_bytes and
      ptr(pm+0x70)+pi*32+0x10==dir.choice_address and ptr(pm+0x80)+pi*12+4==dir.rate_address and
      read(dir.rate_address,4)==dir.rate_bytes,"direct RPM storage/identity changed")
     p.writes={{address=dir.choice_address+12,before=dir.choice_bytes:sub(13,16),after=pack(slot)},
      {address=dir.rate_address,before=dir.rate_bytes,after=dir.choice_bytes:sub(slot*4+1,slot*4+4)}}
     -- shortcut: omit the cycler's optional RPM sound; add feedback if requested.
     p.field,p.publish_address=0x4cbcc2a2,dir.rate_address
    else
     local shift=dir.action_enum==1 and 4 or 12
     local mask=u32(fresh.state_bytes,4)
     check(math.floor(mask/2^shift)%4==dir.slot,"direct mask slot changed")
     p.writes={{address=address+4,before=fresh.state_bytes:sub(5,8),after=pack(mask+(slot-dir.slot)*2^shift)}}
     p.field,p.publish_address=0x31f86165,address+4
    end
    return p
   end,"before-direct-weapon-selection")
   check(plan,plan_error or "direct preimage unavailable")
   for _,write in ipairs(plan.writes) do
    check(reader.api.read(write.address,4)==write.before,"direct write preimage changed")
   end
   -- No yield or intermediate mode. Only this target's final dwords are
   -- written, then the same native field publisher and remembered-setting tail.
   for _,write in ipairs(plan.writes) do
    attempted=true
    check(self.api.write(write.address,write.after),"direct dword write failed; outcome uncertain, no replay")
    check(reader.api.read(write.address,4)==write.after,"direct dword readback failed; no replay")
   end
   self.api.publish(plan.network,plan.field,plan.publish_address)
   if plan.action==3 then self.api.fire(plan.manager,plan.eid,plan.result) end
   self.api.remember(plan.manager,plan.eid,plan.action,plan.result)
   return {slot=slot,value=dir.slot_values[slot+1]}
  end)
  if not ok then return nil,tostring(result),attempted end
  return result
 end
 return self
end
return M

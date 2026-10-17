-- Copied game notifications and completion checks for accepted native updates.
-- Quiet gameplay drains only owned memory. No code-page or Windows hooks.
local M={abi=1}
local function check(value,why)if not value then error(why,0)end return value end
local function pack(value)
 return string.char(value%256,math.floor(value/256)%256,math.floor(value/65536)%256,math.floor(value/16777216)%256)
end
local function u32(s,o)local a,b,c,d=s:byte(o+1,o+4);return a+b*256+c*65536+d*16777216 end
local function unhex(s)return(s:gsub('..',function(pair)return string.char(tonumber(pair,16))end))end

local function windows_api(payload)
 local ffi=require('ffi')
 check(ffi.os=='Windows' and ffi.abi('64bit'),'native events require Windows x64')
 check(type(payload)=='table' and payload.abi==1 and type(payload.sha256)=='string' and
  #payload.sha256==64 and payload.sha256:match('^[0-9a-f]+$') and type(payload.hex)=='string',
  'bundled native observer unavailable')
 local bytes=unhex(payload.hex)
 check(#bytes>1024 and #bytes<1048576 and bytes:sub(1,2)=='MZ','invalid bundled native observer')
 local kernel=ffi.load('kernel32')
 local function bind(name,result,args)
  local ok,value=pcall(function()return kernel[name]end)
  if not ok then ffi.cdef(result..' __stdcall '..name..args..';');value=kernel[name]end
  return ffi.cast(result..' (__stdcall *)'..args,value)
 end
 local get_env=bind('GetEnvironmentVariableW','unsigned long','(const unsigned short *, unsigned short *, unsigned long)')
 local to_wide=bind('MultiByteToWideChar','int','(unsigned int, unsigned long, const char *, int, unsigned short *, int)')
 local to_utf8=bind('WideCharToMultiByte','int','(unsigned int, unsigned long, const unsigned short *, int, char *, int, const char *, int *)')
 local mkdir=bind('CreateDirectoryW','int','(const unsigned short *, void *)')
 local attributes=bind('GetFileAttributesW','unsigned long','(const unsigned short *)')
 local create=bind('CreateFileW','void *','(const unsigned short *, unsigned long, unsigned long, void *, unsigned long, unsigned long, void *)')
 local close=bind('CloseHandle','int','(void *)')
 local size=bind('GetFileSizeEx','int','(void *, long long *)')
 local read=bind('ReadFile','int','(void *, void *, unsigned long, unsigned long *, void *)')
 local write=bind('WriteFile','int','(void *, const void *, unsigned long, unsigned long *, void *)')
 local flush=bind('FlushFileBuffers','int','(void *)')
 local move=bind('MoveFileExW','int','(const unsigned short *, const unsigned short *, unsigned long)')
 local remove=bind('DeleteFileW','int','(const unsigned short *)')
 local pid=bind('GetCurrentProcessId','unsigned long','(void)')
 local tick=bind('GetTickCount64','unsigned long long','(void)')
 local load=bind('LoadLibraryExW','void *','(const unsigned short *, void *, unsigned long)')
 local proc=bind('GetProcAddress','void *','(void *, const char *)')
 local invalid=ffi.cast('void *',-1)
 local function wide(text)
  local n=to_wide(65001,8,text,#text,nil,0);check(n>0,'invalid UTF-8 native runtime path')
  local out=ffi.new('unsigned short[?]',n+1)
  check(to_wide(65001,8,text,#text,out,n)==n,'native runtime path conversion failed');return out
 end
 local buffer=ffi.new('unsigned short[32768]')
 local n=get_env(wide('LOCALAPPDATA'),buffer,32768)
 check(n>0 and n<32768,'LOCALAPPDATA unavailable')
 local count=to_utf8(65001,0,buffer,n,nil,0,nil,nil)
 check(count>0,'LOCALAPPDATA conversion failed')
 local utf8=ffi.new('char[?]',count)
 check(to_utf8(65001,0,buffer,n,utf8,count,nil,nil)==count,'LOCALAPPDATA conversion failed')
 local root=ffi.string(utf8,count):gsub('[\\/]+$','')
 check(root:match('^%a:[\\/]') or root:sub(1,2)=='\\\\','LOCALAPPDATA must be absolute')
 for _,part in ipairs({'CowboyBingus','Helldivers2','WeaponFlowRuntime'})do
  root=root..'\\'..part
  if mkdir(wide(root),nil)==0 then
   local value=tonumber(attributes(wide(root)))
   check(value~=0xffffffff and math.floor(value/16)%2==1,'native runtime directory unavailable')
  end
 end
 local path=root..'\\WeaponFlowEvents-'..payload.sha256..'.dll'
 local function exact()
  -- Hold a non-writable/non-renamable read handle through LoadLibraryExW.
  local file=create(wide(path),0x80000000,1,nil,3,0x80,nil)
  if file==invalid then return nil end
  local length=ffi.new('long long[1]');local got=ffi.new('unsigned long[1]')
  local data=ffi.new('unsigned char[?]',#bytes)
  local ok=size(file,length)~=0 and tonumber(length[0])==#bytes and
   read(file,data,#bytes,got,nil)~=0 and tonumber(got[0])==#bytes and ffi.string(data,#bytes)==bytes
  if not ok then close(file);return nil,'native runtime file differs from bundled bytes'end
  return file
 end
 local file,why=exact()
 if not file then
  check(not why,why)
  local temporary=path..'.tmp-'..tonumber(pid())..'-'..tonumber(tick())
  local staged=create(wide(temporary),0x40000000,0,nil,1,0x80,nil)
  check(staged~=invalid,'cannot stage bundled native runtime')
  local wrote=ffi.new('unsigned long[1]')
  local ok=write(staged,bytes,#bytes,wrote,nil)~=0 and tonumber(wrote[0])==#bytes and flush(staged)~=0
  close(staged)
  if not ok then remove(wide(temporary));error('cannot write bundled native runtime',0)end
  local published=move(wide(temporary),wide(path),8)~=0
  if not published then remove(wide(temporary))end
  file,why=exact();check(file,why or 'cannot publish bundled native runtime')
 end
 -- Only the own validated binary and Windows system DLLs are eligible.
 local module=load(wide(path),nil,0x900)
 close(file);check(module~=nil,'cannot load bundled native runtime')
 -- HMODULE stays resident until process exit, including failed initialization.
 local function exported(name,signature)
  local address=proc(module,name);check(address~=nil,'native runtime export missing: '..name)
  return ffi.cast(signature,address)
 end
 if not pcall(ffi.typeof,'wf_native_event_v1')then
  ffi.cdef[[typedef struct wf_native_event_v1 {
   unsigned long long sequence;
   unsigned int kind, action, flags, before_eid, eid, alternate;
   unsigned int slots[3], before_holder, holder, before_light, light;
   unsigned char avatar[24], weapon[24], module[24];
  } wf_native_event_v1;]]
 end
 local abi=exported('WF_EventsABI','unsigned int (*)(void)')
 local event_size=exported('WF_EventSize','unsigned int (*)(void)')
 check(abi()==1 and event_size()==ffi.sizeof('wf_native_event_v1'),'native observer ABI mismatch')
 local install=exported('WF_Init','int (*)(uintptr_t)')
 local init_info=exported('WF_InitInfo','unsigned int (*)(unsigned int)')
 local drain=exported('WF_Drain','int (*)(wf_native_event_v1 *, unsigned int)')
 local matches=exported('WF_CodeMatches','int (*)(unsigned int, const void *, unsigned int)')
 local track=exported('WF_Tracked','void (*)(unsigned int, unsigned int, unsigned int)')
 local own=exported('WF_Own','void (*)(int)')
 local shutdown=exported('WF_Shutdown','int (*)(void)')
 local events=ffi.new('wf_native_event_v1[512]')
 return {
  path=path,
  install=function(base)
   local code=tonumber(install(base))
   local stages={'module','image','code anchors','game API ownership','writable game data',
    'own origin','publish game API','ready'}
   local stage,slot,status,win=tonumber(init_info(0)),tonumber(init_info(1)),tonumber(init_info(2)),tonumber(init_info(3))
   return code==1,'native observer initialization: '..code..' stage='..tostring(stages[stage] or stage)..
    ' slot='..(slot==0xffffffff and 'batch' or tostring(slot))..' status='..status..' win32='..win..
    ' backend=game-api-notifications'
  end,
  matches=function(rva,expected)return matches(rva,expected,#expected)~=0 end,
  track=function(avatar,weapon,display)track(avatar,weapon,display)end,
  own=function(value)own(value and 1 or 0)end,
  shutdown=function()return shutdown()~=0 end,
  drain=function()
   local count=tonumber(drain(events,512))
   if count<0 then
    local reasons={[-1]='overflow',[-2]='game callback ownership changed',
     [-3]='native decoder thread differs from game coordinator',[-4]='notification drain thread changed'}
    return nil,'native event queue failed: '..count..' '..tostring(reasons[count] or 'invalid native state')
   end
   local rows={}
   for i=0,count-1 do
    local e=events[i]
    rows[#rows+1]={sequence=tonumber(e.sequence),kind=tonumber(e.kind),action=tonumber(e.action),
     flags=tonumber(e.flags),before_eid=tonumber(e.before_eid),eid=tonumber(e.eid),alternate=tonumber(e.alternate),
     slots={tonumber(e.slots[0]),tonumber(e.slots[1]),tonumber(e.slots[2])},
     before_holder=tonumber(e.before_holder),holder=tonumber(e.holder),
     before_light=tonumber(e.before_light),light=tonumber(e.light),
     avatar_bytes=ffi.string(e.avatar,24),weapon_bytes=ffi.string(e.weapon,24),module_bytes=ffi.string(e.module,24)}
   end
   return rows
  end,
 }
end

function M.new(reader,options)
 options=options or {}
 local ok,result=pcall(function()
  check(type(reader)=='table' and type(reader.verify)=='function','native event reader required')
  local valid,why=reader:verify();check(valid,why or 'unsupported native event build')
  local api=options.api or windows_api(options.payload)
  local installed,error_text=api.install(reader.game)
  if not installed then pcall(api.shutdown);error(error_text or 'native observer unavailable',0)end
  local self={api=api,last_sequence=0,active=true,path=api.path}
  function self:drain()
   if not self.active then return nil,'native observer stopped'end
   local rows,why=api.drain();if not rows then return nil,why end
   for _,e in ipairs(rows)do
    if type(e.sequence)~='number' or e.sequence~=self.last_sequence+1 or
       type(e.kind)~='number' or e.kind<1 or e.kind>7 or e.kind%1~=0 then
     return nil,'native notification sequence or kind invalid'
    end
    self.last_sequence=e.sequence
    if e.kind==1 then
     check(type(e.avatar_bytes)=='string' and #e.avatar_bytes==24 and
      type(e.weapon_bytes)=='string' and #e.weapon_bytes==24 and type(e.slots)=='table',
      'invalid copied native hand observation')
     e.selection_bytes=pack(e.eid)..pack(e.alternate)
     e.observed=e.flags%2==1
     e.main=math.floor(e.flags/2)%2==1
     e.empty=math.floor(e.flags/4)%2==1
     if e.main and (u32(e.weapon_bytes,8)~=e.eid or
       (e.slots[1]~=e.eid and e.slots[2]~=e.eid and e.slots[3]~=e.eid))then
      return nil,'native main weapon notification identity invalid'
     end
    end
    e.own=math.floor((e.flags or 0)/8)%2==1
    e.changed=math.floor((e.flags or 0)/16)%2==1
    e.replicated=math.floor((e.flags or 0)/32)%2==1
   end
   return rows
  end
  function self:track(snapshot)
   if not snapshot then api.track(0,0,0);return end
   api.track(u32(snapshot.avatar_bytes,8),snapshot.active_weapon.entity.eid,
    snapshot.active_weapon.display_eid or snapshot.active_weapon.entity.eid)
  end
  function self:matches(rva,bytes)return self.active and api.matches(rva,bytes)end
  function self:own_call(operation,...)
   api.own(true)
   local function capture(...)return{n=select('#',...),...}end
   local values=capture(pcall(operation,...));api.own(false)
   if not values[1]then error(values[2],0)end
   return unpack(values,2,values.n)
  end
  function self:shutdown()
   if self.closed then return self.closed_ok end
   self.closed=true;self.active=false;self.closed_ok=api.shutdown();return self.closed_ok
  end
  return self
 end)
 if not ok then return nil,tostring(result)end
 return result
end
return M

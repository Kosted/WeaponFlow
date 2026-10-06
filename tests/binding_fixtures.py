"""Public MBM integration with synthetic native metadata; no game input sent."""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime
from input_fixtures import Fixture as InputFixture
from text_fixtures import load_text

SOURCE = (Path(__file__).resolve().parents[1] / "src/weaponflow_mod_bindings.lua").read_text(encoding="utf-8")


class Fixture:
    def __init__(self, integrated=False):
        self.input = InputFixture() if integrated else None
        self.lua = self.input.lua if integrated else LuaRuntime(unpack_returned_tuples=True)
        load_text(self.lua)
        self.lua.globals().Bindings=self.lua.execute((Path(__file__).resolve().parents[1]/"src/weaponflow_game_controls.lua").read_text(encoding="utf-8"))
        self.module = self.lua.execute(SOURCE)
        self.lua.globals().module = self.module
        self.lua.execute(r'''state={version=3,down={},rows={},reads=0,raw={},card="R",assignment_error=false}
state.watch_reads=0
local names={[1]="save",[3]="cycle",[4]="hud",[5]="reset"}
for i,name in pairs(names) do
 state.raw[i]={count=0,unbound=true,mappings={},signature="empty"}
end
state.assignments=""
for i,name in pairs(names) do state.assignments=state.assignments..module.ids[name].."\t10\t"..(i-1).."\n" end
state.menu={api=1,version=3,
 ready=function()return not state.failed end,
 register_binding=function(id,label,unused,options) state.rows[id]={label=label,category=options.category};return true end,
 is_down=function(id) if state.failed then return nil end return state.down[id]==true end}
state.engine={Keyboard={button_name=function(id)return string.char(id):lower()end},
 Mouse={button_name=function(id)return ({[0]="left",[1]="right",[2]="middle",[3]="extra_1",[4]="extra_2"})[id]end}}
state.options={
 get_menu=function() if state.missing then return nil end state.menu.version=state.version;return state.menu end,
 get_loader=function()return {log_directory="X:/Logs"}end,
 get_engine=function()return state.engine end,
 read_file=function(path) if state.assignment_error then return nil,"access denied" end return state.assignments end,
 read_binding=function(code) state.reads=state.reads+1;local raw=state.raw[code%65536+1];if raw then raw.code=code end;return raw,state.read_error end,
 watch_binding=function(previous) state.watch_reads=state.watch_reads+1
  if state.watch_error then return nil,state.watch_error end
  local raw=state.raw[previous.code%65536+1];if raw then raw.code=previous.code end;return raw,state.read_error end}
state.context={presets_enabled=true,hud_enabled=true,card_label="R",
 refresh_card_label=function()return state.card end,
 resolve_entries=function(entries)
 local vks,groups,labels={},{},{}
 for _,entry in ipairs(entries) do
 local key=string.byte(entry.input:upper())
 vks[#vks+1]=key;groups[#groups+1]={key};labels[#labels+1]=entry.input:upper()
 end
 return {vks=vks,groups=groups,vk=#vks==1 and vks[1] or nil,label=table.concat(labels," / ")} end}
function assign(index,key,device)
 state.raw[index]={count=1,unbound=false,signature=tostring(key)..":"..tostring(device),
 mappings={{simple_button=true,input_kind=4,device=device or 3,button_id=key,trigger=0,combine=0}}}
end
''')
        self.state = self.lua.globals().state
        self.obj = self.module.new(self.state.options)
        if integrated:
            self.lua.globals().python_read_file = self.input.adapter.read_file
            self.input.adapter.read_file = self.lua.eval("function(path)return python_read_file(path)end")
            opts = self.lua.table_from({"adapter":self.input.adapter,"mod_bindings":self.module,
                "get_menu":self.state.options.get_menu,"get_loader":self.state.options.get_loader,
                "get_engine":self.state.options.get_engine,"read_menu_binding":self.state.options.read_binding,
                "watch_menu_binding":self.state.options.watch_binding})
            self.input.files["X:/Logs/ModBindingsMenu.assignments"] = self.state.assignments
            self.input.obj = self.input.module.new(opts)

    def poll(self, time=0, foreground=True):
        return self.obj.poll(self.obj,time,foreground,self.state.context)

    def assign(self,index,key,device=3):
        self.lua.globals().assign(index,key,device)

    def signal(self,name,down):
        self.state.down[self.module.ids[name]]=down

    def ipoll(self,time=0,**controls):
        return self.input.poll(time,controls={"hud_enabled":True,**controls})

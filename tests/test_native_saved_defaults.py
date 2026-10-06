"""Coordinator and command boundaries only; these do not simulate live HD2.

Native ammo/laser actions are stubs that update only this fixture's values;
other native calls fail. This checks orchestration, not live game semantics.
File semantics and Windows backend are in test_weapon_defaults_store.py.
"""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime
from text_fixtures import load_text

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
local env={time=0,foreground=true,held=false,pressed=false,ready=true,
    card_open=true,eid=10,slot=1,ammo_slot=1,guide=1,
    ensures=0,saves=0,clears=0,cycles=0,logs={},files={},opens=0,mode_reads=0,ammo_reads=0}
local function ordinary_slots()
 return env.single_fire and {1,0,0} or (env.three_fire and {1,2,3} or {2,3,0})
end
function print(text) env.logs[#env.logs+1]=text end
local fakeffi={}
local api={
 GetTickCount64=function() return env.time*1000 end,
 GetCurrentProcessId=function() return 99 end,
 GetForegroundWindow=function() return 1 end,
 GetWindowThreadProcessId=function(_,out) out[0]=env.foreground and 99 or 20 end,
}
function fakeffi.load() return api end
function fakeffi.new() return {[0]=0} end
function fakeffi.cast(ctype,value)
 if ctype:find('__fastcall',1,true) then
  return function(_,_,action)
   env.cycles=env.cycles+1
   env.actions=env.actions or {};env.actions[#env.actions+1]=action
   if env.no_transition then return end
   if action==8 then env.ammo_slot=1-env.ammo_slot
   elseif action==6 then env.guide=1-env.guide
   elseif action==11 then env.secondary_slot=1-(env.secondary_slot or 0)
   elseif action==3 then
    if env.secondary and env.secondary_slot==1 then
     env.secondary_slot=0 -- Native kind3 returns before advancing the ordinary slot.
     if env.wrong_return_slot then env.slot=(env.slot+1)%2 end
    else
     local count=0;for _,v in ipairs(ordinary_slots()) do if v>0 then count=count+1 end end
     env.slot=(env.slot+1)%count
    end
   elseif action==5 then env.light_value=((env.light_value or 0)+1)%3
   else error('unexpected native mode call') end
  end
 end
 return value
end
package.loaded.ffi=fakeffi
CowboyBingusModLoader={api=1,open_log=function(name)
 if env.log_open_fail then return nil end
 env.opens=env.opens+1;env.files[name]=''
 return {write=function(_,line,newline)
   if env.log_write_fail then error('fixture disk error') end
   env.files[name]=env.files[name]..line..(newline or '')
  end,flush=function() end,close=function() env.log_closes=(env.log_closes or 0)+1 end}
end}
function update() end
function shutdown(...)
 env.stock_shutdowns=(env.stock_shutdowns or 0)+1
 env.stock_saw_hud_shutdown=env.hud_shutdowns
 env.stock_saw_log_closes=env.log_closes
 if env.shutdown_update then update() end
 if env.stock_shutdown_throw then error('fixture original shutdown exception') end
 return ...
end
local resource='361EFAD956A1F180'
local function display() return env.secondary and env.secondary_slot==1 and env.eid+20 or env.eid end
local function pair(eid) return string.char(eid,0,0,0,display()==eid and 0 or display(),0,0,0) end
local function snapshot()
 return {avatar_bytes=string.rep(env.avatar or 'A',24),active_weapon={
  wielder_selection_bytes=pair(env.eid),display_eid=display(),
  bytes=string.rep(string.char(env.eid),24),entity={eid=env.eid,network_object_id=env.eid,
  resource_hex_le=resource}},read_calls=1,read_bytes=24}
end
local reader={game=0,api={read=function() return string.char(0x41) end}}
function reader:active_weapon()
 env.active_reads=(env.active_reads or 0)+1
 if env.active_read_throw then error('fixture active identity exception') end
 if env.reader_failure then return nil,env.reader_failure end
 if env.blocked then return nil,'local player unavailable' end
 if env.not_ready or env.eid==0 then return nil,'component not ready' end
 return snapshot()
end
function reader:watch(old,cursor)
 if env.reader_failure then return false,env.reader_failure,{} end
 if env.blocked then return false,'local player unavailable',{} end
 if old.avatar_bytes~=snapshot().avatar_bytes then return false,'avatar changed',{} end
 local old_eid=cursor and cursor:byte(1) or old.active_weapon.entity.eid
 local same=old_eid==env.eid
 return same and (cursor or old.active_weapon.wielder_selection_bytes)==pair(env.eid),'selection changed',{authoritative_selection_change=not same,
  previous_eid=old_eid,observed_eid=env.eid,observed_selection_bytes=not same and pair(env.eid) or nil}
end
function reader:verify() return true end
function reader:guard_active() return {weapon_manager=1,entity={eid=env.eid}} end
function reader:transaction(fn) return fn() end
local NativeReader={new=function() return reader end}
local EquipContext={}
function EquipContext.inspect(_,old,expected)
 if env.blocked or env.context_fail or old.avatar_bytes~=snapshot().avatar_bytes then return nil,'fixture context unavailable' end
 if expected and expected~=pair(env.eid) then return nil,'fixture selection changed' end
 local kind=env.eid==0 and 'empty' or (env.utility and 'utility' or 'weapon')
 if env.unknown then kind='unknown' end
 return {avatar_bytes=snapshot().avatar_bytes,selection_eid=env.eid,selection_bytes=pair(env.eid),
  candidate_kind=kind,candidate_slot=kind=='weapon' and 'primary' or 'grenade',
  candidate_entity=not env.unknown and {eid=env.eid,bytes=snapshot().active_weapon.bytes} or nil,
  previous_in_main=not env.removed,removed=env.removed,inventory_revision=env.inventory_revision}
end
function EquipContext.watch(_,context)
 return not env.context_fail and context.removed==env.removed and context.inventory_revision==env.inventory_revision
end
local WeaponModes={cycle={signature_hex='41',rva=1}}
local function functions()
 if env.reverse_secondary then return {left=3,right=11,up=env.scope and 1 or 0,down=0} end
 return {left=env.ammo and 8 or (env.laser and 6 or (env.secondary and 11 or 0)),right=env.no_right and 0 or 3,
  up=env.scope and 1 or 0,down=env.flashlight and 5 or 0}
end
function WeaponModes.inspect()
 env.mode_reads=env.mode_reads+1
 if env.mode_failure then return nil,'fixture mode unavailable' end
 local choices=ordinary_slots()
 local offered={};for _,v in ipairs(choices) do if v>0 then offered[#offered+1]=v end end
 local inactive=env.secondary and env.secondary_slot==1
 local result={weapon_manager=1,weapon_eid=env.eid,functions=functions(),
  fire_mode_raw=inactive and 8 or choices[env.slot+1],mask_raw=(inactive and 1024 or 0)+env.slot*4096,directions={
  left={action_enum=functions().left,present=env.ammo or env.laser or env.secondary or false,
  kind=env.secondary and 'secondary_fire' or nil,readable=false,reason='stub unreadable base reader'},right={action_enum=functions().right,
  present=not env.no_right,readable=not env.right_unreadable and not (env.secondary and env.secondary_slot==1),
  inactive=inactive,cycle_supported=not inactive and #offered>1,kind='firemode',
  safety_override=inactive and 1 or 0,
  presence_unknown=env.right_presence_unknown,
  slot=env.slot,current=not inactive and choices[env.slot+1] or nil,slot_values=choices,choices=offered},
  up={action_enum=functions().up,present=env.scope or false,readable=true,cycle_supported=true,
   kind='zeroing',slot=2,current=150,slot_values={25,75,150},choices={25,75,150}},
  down={action_enum=functions().down,present=env.flashlight or false,readable=false,kind='flashlight'}}}
 if env.reverse_secondary then
  result.directions.left,result.directions.right=result.directions.right,result.directions.left
  result.directions.left.action_enum,result.directions.right.action_enum=3,11
 end
 return result
end
local Flashlight={cycle={signature_hex='41'},inspect=function()
 env.light_reads=(env.light_reads or 0)+1
 if env.light_failure then return nil,'fixture flashlight unavailable' end
 return {present=env.flashlight==true and not env.light_absent,selected=env.light_value or 0,offered_values={0,1,2},
  module_bytes=env.light_module or 'light',module_entity={eid=77}}
end}
local WeaponUI={inspect=function()
 if env.card_throw then error('fixture card validation exception') end
 return {hidden=not env.card_open,cached_eid=env.card_eid or env.eid,display_eid=env.card_display or env.card_eid or display()}
end,invalidate=function(_,observed)
 env.invalidated_display=observed.active_weapon.display_eid
 return {status='already_dirty',hidden=false,dirty=true,cached_eid=env.eid,display_eid=env.eid}
end}
local ProgrammableAmmo={inspect=function()
 env.ammo_reads=env.ammo_reads+1
 local f=functions()
 if env.helper_mismatch then f.up=1 end
 local choices=env.ammo_missing and {102,103} or {101,325}
 return {functions=f,kind='programmable_ammo',action_enum=8,present=true,readable=true,
 cycle_supported=true,slot=env.ammo_slot,current=choices[env.ammo_slot+1],choices=choices,slot_values=choices}
end}
local SecondaryFire={inspect=function()
 env.secondary_reads=(env.secondary_reads or 0)+1
 if env.secondary_failure or (env.secondary_failure_at and env.secondary_reads>=env.secondary_failure_at) then
  return nil,'fixture secondary reader unavailable'
 end
 local result={functions=functions(),kind='secondary_fire',action_enum=11,present=true,readable=true,
 cycle_supported=not env.secondary_cycle_unavailable,slot=env.secondary_slot or 0,current=env.secondary_slot or 0,
 choices={0,1},slot_values={0,1},label_keys={[0]=17,[1]=18}}
 if env.secondary_slot==1 and result.cycle_supported and not env.activation_unverified then
  result.primary_activation={action_enum=3,before=8,next_value=ordinary_slots()[env.slot+1],ordinary_slot=env.slot}
 end
 return result
end}
HudLabels={get=function(id) return ({[17]='12MM',[18]='FLAMETHROWER'})[id] end}
local LaserGuide={inspect=function()
 return {functions=functions(),kind='laser_guide',action_enum=6,present=true,readable=true,
 cycle_supported=not env.authority_pending,cycle_pending=env.authority_pending,
 reason=env.authority_pending and 'waiting for native authority' or nil,
 slot=env.guide,current=env.guide,choices={0,1},slot_values={0,1}}
end}
local input={profile_id='76561198000000000',input_path='fixture'}
function input:poll(_,_,controls) env.poll_presets=controls.presets_enabled;env.poll_diagnostics=controls.diagnostics_enabled;
 env.poll_hud_move_armed=controls.hud_move_armed;
 return {pressed=env.pressed,held_reload=env.held,down=env.down,
 grenade_pressed=env.grenade_pressed,grenade_label=env.grenade_label,grenade_reason=env.grenade_reason,
 save_held=env.save_held,card_label=env.card_label or 'R',save_label=env.save_label or 'P',
 hud_label=env.hud_label or 'H',cycle_label=env.cycle_label or 'F8',
 ready=env.ready,reason=env.ready and nil or 'input unavailable',profile_valid=not env.invalid_profile,
 reset_pressed=env.reset_pressed,reset_ready=env.reset_ready,
 clear_pressed=env.clear_pressed,clear_ready=env.clear_ready,
 save_preset=env.save_preset,preset_pressed=env.preset_pressed,cycle_pressed=env.cycle_pressed,cycle_ready=env.cycle_ready,
 hud_move_active=env.hud_move_active,hud_move=env.hud_move,hud_move_reason=env.hud_move_reason,
 hud_select_pressed=env.hud_select_pressed,hud_display_pressed=env.hud_display_pressed,menu_diagnostics=env.menu_diagnostics,
 locale_pressed=env.locale_pressed,contextual_help_open=controls.help_open,help_instance=controls.help_instance,
 export_label='C',import_label='V',locale_label='F9'} end
function input:refresh() self.profile_valid=not env.invalid_profile end
function input:cycle_language(_,_,guard)
 if guard()~=true then return nil,'fixture contextual guard rejected' end
 local selected=Text.next_language();Text.set_language(selected);return selected
end
function input:publish_reset_defaults() env.reset_defaults=true end
function input:consume_clear() env.consumed_clear=(env.consumed_clear or 0)+1 end
function input:ensure_menu_state() env.menu_ensures=(env.menu_ensures or 0)+1;return true end
function input:reset_menu_bindings(before_write)
 env.reset_binding_attempts=(env.reset_binding_attempts or 0)+1
 local backed,why=before_write();if not backed then return nil,why end
 if env.reset_native_failure then return nil,'fixture native clear failure' end
 env.reset_native_clears=(env.reset_native_clears or 0)+1
 return {status='cleared',actions=env.no_menu and 0 or 4}
end
local DefaultsInput={new=function()
 env.input_opens=(env.input_opens or 0)+1
 if env.reset_reload_failure then return nil,'fixture input reload failure' end
 return input
end}
local store={path='fixture.ini',targets={}}
store.presets={{targets=store.targets},{targets={}},{targets={}}}
function store:ensure()
 env.ensures=env.ensures+1
 if env.store_unknown then
  env.store_unknown=false;self.targets={};self.presets={{targets=self.targets},{targets={}},{targets={}}}
 end
 if env.clear_during_ensure then self:clear_all();env.clear_during_ensure=false end
 return true
end
function store:reload() return not env.store_failure,'fixture store failure' end
function store:get(_,index)
 if env.store_unknown then return nil,'not_found' end
 return self.presets[index or 1]
end
function store:get_presets()
 if env.store_unknown then return nil,'not_found' end
 return self.presets
end
function store:merge(_,updates,index,plan)
 if env.store_failure then return nil,'fixture store failure' end
 env.store_unknown=false
 env.saves=env.saves+1
 env.save_plan=plan
 for side,v in pairs(updates) do self.presets[index or 1].targets[side]=v end
 return true
end
function store:clear_all()
 if env.store_failure then return nil,'fixture store failure' end
 env.clears=env.clears+1;env.store_unknown=false;self.targets={}
 self.presets={{targets=self.targets},{targets={}},{targets={}}};return true
end
local DefaultsStore={open=function()
 env.store_opens=(env.store_opens or 0)+1
 if env.hud_reset_committed and env.reset_store_failure then return nil,'fixture reset store reopen failure' end
 if env.store_open_failure then return nil,'fixture corrupt preset file' end
 return store
end,context=function()
 env.store_contexts=(env.store_contexts or 0)+1
 if env.hud_reset_committed and env.reset_context_failure then return nil,'fixture reset HUD context failure' end
 return {profile_id=input.profile_id,path='fixture.ini'}
end}
local PresetInputGate={inspect=function()
 if env.gate_failure then return nil,'fixture unavailable' end
 return {allowed=not env.menu,reason=env.menu and 'fixture menu/chat' or nil}
end}
function PresetInputGate.context()
 env.reset_gate_reads=(env.reset_gate_reads or 0)+1
 if env.gate_failure then return nil,'fixture unavailable' end
 return {allowed=not env.menu,reason=env.menu and 'fixture menu/chat' or nil}
end
ModReset={prepare=function(profile)
 env.reset_prepares=(env.reset_prepares or 0)+1;env.reset_profile=profile
 if env.reset_prepare_failure then return nil,'fixture prepare failure' end
 local plan={}
 function plan:backup()
  env.reset_backups=(env.reset_backups or 0)+1
  if env.reset_backup_failure then return nil,'fixture backup failure' end
  return true,'fixture-backup'
 end
 function plan:commit()
  env.reset_commits=(env.reset_commits or 0)+1
  if env.reset_commit_failure then return nil,'fixture file commit failure',{partial=true} end
  store.targets={};store.presets={{targets=store.targets},{targets={}},{targets={}}}
  env.global_light=nil;env.hud_selection=nil;env.store_open_failure=false
  env.hud_reset_committed=true
  return true,{backup_directory='fixture-backup',files_written=3,profile_id=profile}
 end
 return plan
end}
local HudLayout={new=function()
 if env.hud_reset_committed and env.reset_layout_failure then return nil,'fixture reset layout failure' end
 env.hud_layout={display=env.hud_reset_committed and 'both' or env.saved_hud_display or 'both'};return env.hud_layout
end}
local WeaponHudIcons={}
local NativeHudIcons={inspect=function()
 env.hud_reads=(env.hud_reads or 0)+1
 if env.hud_read_throw then error('fixture HUD reader failure') end
 return {directions={}}
end,ammo_labels=function()
 env.help_ammo_reads=(env.help_ammo_reads or 0)+1
 if env.help_ammo_failure then return nil,'fixture hard native label failure' end
 if env.help_ammo_throw then error('fixture hard native label exception') end
 return {[101]='ARMOR PIERCING',[325]='FLAK'} end,
 choice_icons=function(_,_,modes,helpers)
  env.help_icon_reads=(env.help_icon_reads or 0)+1
  assert(helpers.weapon_modes==WeaponModes and helpers.secondary_fire==SecondaryFire)
  if env.help_icon_failure then return nil,'fixture hard native choice icon failure' end
  if env.help_icon_throw then error('fixture choice icon exception') end
  return {right={[2]={kind='firemode',hash_hex='3efff09cd12fb89a',slot=0},
                 [3]={kind='firemode',hash_hex='131742904d846798',slot=1}}}
 end}
local hud={}
function hud:cycle_display()
 if env.hud_display_failure then return nil,'fixture HUD settings disk failure' end
 self.display=({both='icon',icon='text',text='both'})[self.display]
 env.hud_display,env.saved_hud_display=self.display,self.display
 env.hud_display_changes=(env.hud_display_changes or 0)+1
 return self.display
end
function hud:selection(resource) return env.hud_selection end
function hud:cycle_selection(resource,available)
 if env.hud_selection_fail then return nil,'fixture HUD settings disk failure' end
 env.hud_selections=(env.hud_selections or 0)+1;env.hud_selected_resource=resource
 env.hud_available=available
 local next_side='None'
 local order={left=1,right=2,up=3,down=4,None=0}
 for _,side in ipairs(available) do
  if order[side]>(order[env.hud_selection] or 0) then next_side=side;break end
 end
 env.hud_selection=next_side
 return env.hud_selection
end
function store:get_flashlight() return env.global_light end
function store:set_flashlight(value)
 if env.store_failure then return nil,'fixture store failure' end
 env.global_light=value;env.light_saves=(env.light_saves or 0)+1;return true
end
function hud:set(_,_,selected) env.hud_sets=(env.hud_sets or 0)+1;env.hud_presented_selection=selected end
function hud:render()
 if env.hud_render_throw then error('fixture render failure') end
 if env.hud_render_unavailable then return nil,'fixture viewport unavailable' end
 env.hud_renders=(env.hud_renders or 0)+1
end
function hud:hide() env.hud_hidden=true end
function hud:cancel_move() env.hud_moving=false;env.hud_cancel_moves=(env.hud_cancel_moves or 0)+1;return true end
function hud:finish_move()
 if env.hud_moving then env.hud_finishes=(env.hud_finishes or 0)+1;env.hud_moving=false end
end
function hud:move()
 if env.hud_move_throw then error('fixture position exception') end
 env.hud_moves=(env.hud_moves or 0)+1;env.hud_moving=true
end
function hud:shutdown()
 env.hud_shutdowns=(env.hud_shutdowns or 0)+1
 if env.hud_shutdown_throw then error('fixture HUD cleanup exception') end
 if env.hud_shutdown_fail then return nil,'fixture GUI destroy failed' end
 return {status='destroyed'}
end
local WeaponHud={new=function(options) hud.display=options.display;env.hud_display=options.display;return hud end}
local HelpHud={new=function(options) env.help_has_icons=options.icons==WeaponHudIcons;return {
 set=function(_,lines) if env.help_set_throw then error('fixture help failure') end;env.help_lines=lines;return true end,
 render=function() env.help_visible=true;return true end,
 hide=function() env.help_visible=false end,
 shutdown=function() env.help_visible=false;env.help_shutdowns=(env.help_shutdowns or 0)+1;return {status='destroyed'} end,
} end}
return env,store,NativeReader,WeaponModes,Flashlight,WeaponUI,DefaultsInput,DefaultsStore,ProgrammableAmmo,LaserGuide,EquipContext,PresetInputGate,WeaponHudIcons,NativeHudIcons,WeaponHud,HudLayout,HelpHud,SecondaryFire
'''


class CoordinatorSave(unittest.TestCase):
    diagnostics = True

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        load_text(self.lua)
        self.lua.globals().PresetsTransfer=self.lua.execute((ROOT/'src/weaponflow_presets_transfer.lua').read_text())
        self.lua.globals().BuildConfig = self.lua.table_from({
            'version': '1.6.3', 'diagnostics': self.diagnostics,'hud':getattr(self,'hud_enabled',False),
            'presets':getattr(self,'presets_enabled',True),
            'flavor': 'diagnostic' if self.diagnostics else 'release',
        })
        self.lua.execute('ModBindings={available=function()return true end};ModBindingsMenu={}')
        values = self.lua.execute(HARNESS)
        self.env, self.store, *modules = values
        self.env.saved_hud_display=getattr(self,'hud_display','both')
        if getattr(self, 'real_store', False):
            actual = self.lua.execute((ROOT / 'src/weapon_defaults_store.lua').read_text())
            self.disk = self.lua.table_from({'writes': 0})
            adapter = self.lua.eval('''function(disk) return {
                read=function() if disk.data==nil then return nil,'missing' end; return disk.data end,
                atomic_write=function(_,data,expected)
                    if disk.fail then return nil,'fixture disk failure' end
                    assert(expected==disk.data,'stale writer');disk.data=data;disk.writes=disk.writes+1;return true
                end} end''')(self.disk)
            self.store = actual.open('76561198000000000', self.lua.table_from({'path': 'fixture.ini', 'io': adapter}))
            modules[5] = self.lua.eval('function(store) return {open=function() return store end} end')(self.store)
        if getattr(self,'store_open_failure',False): self.env.store_open_failure=True
        capture = self.lua.execute((ROOT / 'src/weapon_defaults_capture.lua').read_text())
        global_light = self.lua.execute((ROOT / 'src/weapon_defaults_flashlight.lua').read_text())
        help_model = self.lua.execute((ROOT / 'src/weapon_defaults_help_model.lua').read_text())
        coordinator = (ROOT / 'src/native_weapon_defaults.lua').read_text()
        wrapper = self.lua.eval('function(NativeReader,WeaponModes,Flashlight,WeaponUI,'
                                'DefaultsInput,DefaultsStore,ProgrammableAmmo,LaserGuide,EquipContext,PresetInputGate,WeaponHudIcons,NativeHudIcons,WeaponHud,HudLayout,HelpHud,SecondaryFire,DefaultsCapture,GlobalFlashlight,HelpModel)\n'
                                + coordinator + '\nend')
        self.state = wrapper(*modules, capture, global_light, help_model)
        self.advance(0)

    def advance(self, time, **values):
        self.env['time'] = time
        self.env['pressed'] = False
        for field in ('save_preset', 'preset_pressed', 'cycle_pressed', 'hud_select_pressed', 'hud_display_pressed', 'grenade_pressed', 'reset_pressed', 'clear_pressed', 'locale_pressed'):
            self.env[field] = None
        for name, value in values.items():
            self.env[name] = value
        self.lua.globals().update()
        self.assertNotEqual(self.state['status'], 'stopped', list(self.env['logs'].values()))

    def test_digit_captures_current_value_not_initial_p_value(self):
        self.advance(.1, pressed=True, held=True)
        self.assertEqual(self.env['saves'], 0)
        self.advance(.5, save_preset=1, slot=0)
        self.assertEqual(self.env['saves'], 1)
        self.advance(.6, held=False, card_open=False, slot=1)
        self.assertEqual(self.store['targets']['right']['value'], 2)
        self.assertEqual(self.store['targets']['right']['slot'], 1)
        self.assertEqual(self.env['cycles'], 0)

    def test_single_p_never_saves_without_number(self):
        self.advance(.1, pressed=True, held=True)
        self.advance(.6)
        self.assertEqual(self.env['saves'], 0)
        self.assertEqual(self.env['clears'], 0)


    def test_closed_card_or_unheld_reload_does_not_save(self):
        self.advance(.1, pressed=True, held=False)
        self.advance(.5)
        self.advance(.6, pressed=True, held=True, card_open=False)
        self.advance(1.)
        self.assertEqual(self.env['saves'], 0)
        self.assertEqual(self.env['clears'], 0)


    def test_none_profile_never_cycles_on_equip(self):
        self.advance(.2)
        self.advance(.4, eid=12)
        self.advance(.6)
        self.assertEqual(self.env['cycles'], 0)
        self.assertEqual(self.env['saves'], 0)
        self.assertGreaterEqual(self.env['ensures'], 2)

    def test_ammo_save_then_real_equip_applies_semantic_choice(self):
        self.advance(.1, pressed=True, held=True, save_preset=1, ammo=True)
        self.advance(.5, held=False)
        self.assertEqual(self.store['targets']['left']['value'], 325)
        self.assertEqual(self.store['targets']['left']['slot'], 2)
        self.advance(.6, ammo_slot=0)
        self.assertEqual(self.env['cycles'], 0)  # manual override remains
        self.advance(.7, eid=11)
        self.advance(.9)
        self.advance(1.0)
        self.assertEqual(self.env['cycles'], 1)
        self.assertEqual(self.env['ammo_slot'], 1)

    def test_unoffered_ammo_skips_without_rewriting_saved_choice(self):
        self.advance(.1, pressed=True, held=True, save_preset=1, ammo=True)
        self.advance(.5, held=False)
        self.advance(.7, eid=11, ammo_missing=True)
        self.advance(.9)
        self.assertEqual(self.env['cycles'], 0)
        self.assertEqual(self.store['targets']['left']['value'], 325)


    def prepare_manual_ammo_override(self):
        self.advance(.1, pressed=True, held=True, save_preset=1, ammo=True)
        self.advance(.5, held=False)
        self.advance(.6, ammo_slot=0)
        self.assertEqual(self.store['targets']['left']['value'], 325)
        self.assertEqual(self.env['cycles'], 0)

    def test_empty_hand_return_preserves_manual_modes(self):
        self.prepare_manual_ammo_override()
        self.advance(.7, eid=0)
        self.advance(.8)
        self.advance(.9, eid=10)
        self.advance(1.2)
        self.assertEqual(self.state['equips'], 1)
        self.assertEqual(self.env['ammo_slot'], 0)
        self.assertEqual(self.env['cycles'], 0)


    def test_drop_during_unchanged_utility_hand_then_repickup_same_instance(self):
        self.prepare_manual_ammo_override()
        self.advance(.7, eid=90, utility=True)
        self.advance(.8, removed=True)  # hand stays 90; main slot loses A
        self.advance(.9, removed=False)
        self.advance(1, eid=10, utility=False)
        self.advance(1.2)
        self.advance(1.4)
        self.assertEqual(self.state['equips'], 2)
        self.assertEqual(self.env['cycles'], 1)
        self.assertEqual(self.env['ammo_slot'], 1)


    def test_brief_real_switch_witness_survives_unready_b_and_empty_hand(self):
        self.prepare_manual_ammo_override()
        self.advance(.7, eid=0)
        self.advance(.705, eid=11, not_ready=True)
        self.advance(.71, eid=0)
        self.advance(.72, eid=10, not_ready=False)
        self.advance(.9)
        self.assertEqual(self.state['equips'], 2)
        self.assertEqual(self.env['cycles'], 1)


    def test_unknown_nonzero_item_is_not_a_weapon_switch_witness(self):
        self.prepare_manual_ammo_override()
        self.advance(.7, eid=90, unknown=True)
        self.advance(.8, eid=10, unknown=False)
        self.advance(1.)
        self.assertEqual(self.state['equips'], 1)
        self.assertEqual(self.env['cycles'], 0)

    def test_reinforcement_during_utility_gets_new_equip(self):
        self.prepare_manual_ammo_override()
        self.advance(.7, eid=90, utility=True)
        self.advance(.8, eid=10, utility=False, avatar='B')
        self.advance(1.)
        self.assertEqual(self.state['equips'], 2)
        self.assertEqual(self.env['cycles'], 1)

    def test_failed_utility_classification_cancels_job_without_resetting(self):
        self.prepare_manual_ammo_override()
        self.advance(.7, eid=11)  # automatic job is queued but not started
        self.advance(.72, eid=90, utility=True, context_fail=True)
        self.advance(.8, eid=11, utility=False, context_fail=False)
        self.advance(1.)
        self.assertEqual(self.state['equips'], 2)
        self.assertEqual(self.env['cycles'], 0)


    def preset(self, index, **targets):
        """Seed preferences, not a guessed game mode: the game is stubbed above."""
        fields = {}
        for side, value in targets.items():
            fields[side] = self.lua.table_from({
                'kind': 'programmable_ammo' if side == 'left' else 'firemode',
                'value': value, 'slot': 1 if value in (101, 2) else 2,
            })
        self.store['presets'][index]['targets'] = self.lua.table_from(fields)
        if index == 1:
            self.store['targets'] = self.store['presets'][index]['targets']

    def test_three_saves_are_independent_and_fast_chords_do_not_clear(self):
        self.advance(.1, held=True, pressed=True, save_preset=1, slot=0, scope=True)
        self.advance(.2, pressed=True, save_preset=2, slot=1)
        self.advance(.3, save_preset=3, slot=0)
        self.assertEqual(self.env['saves'], 3)
        self.assertEqual(self.env['clears'], 0)
        self.assertEqual([self.store['presets'][i]['targets']['right']['value']
                          for i in range(1, 4)], [2, 3, 2])
        self.assertEqual(self.env['cycles'], 0)


    def test_cycle_without_reload_skips_empty_and_wraps(self):
        self.advance(.2, ammo=True)
        self.preset(1, left=325)
        self.preset(3, left=101)
        self.advance(.3, cycle_pressed=True)
        self.advance(.4)
        self.assertEqual(self.env['ammo_slot'], 0)
        self.assertEqual(self.state['preset'], 3)
        self.advance(.5, cycle_pressed=True)
        self.advance(.6)
        self.assertEqual(self.env['ammo_slot'], 1)
        self.assertEqual(self.state['preset'], 1)
        self.assertEqual(self.state['equips'], 1)


    def test_real_equip_uses_one_after_cycling_to_two(self):
        self.advance(.2, ammo=True)
        self.preset(1, left=325)
        self.preset(2, left=101)
        self.advance(.3, cycle_pressed=True)
        self.advance(.4)
        self.advance(.5, eid=11)
        self.advance(.7)
        self.advance(.8)
        self.assertEqual(self.state['preset'], 1)
        self.assertEqual(self.env['ammo_slot'], 1)
        self.assertEqual(self.state['equips'], 2)

    def test_utility_return_preserves_preset_cursor_and_manual_value(self):
        self.advance(.2, ammo=True)
        self.preset(1, left=325)
        self.preset(2, left=101)
        self.advance(.3, cycle_pressed=True)
        self.advance(.4)
        self.advance(.5, ammo_slot=1, eid=90, utility=True)
        self.advance(.6, eid=10, utility=False)
        self.advance(.8)
        self.assertEqual(self.state['preset'], 2)
        self.assertEqual(self.env['ammo_slot'], 1)
        self.assertEqual(self.env['cycles'], 1)
        self.assertEqual(self.state['equips'], 1)

    def test_rapid_requests_wait_for_readback_then_latest_request_wins(self):
        self.advance(.2, ammo=True)
        self.preset(1, left=325, right=3)
        self.preset(2, left=101, right=2)
        self.preset(3, left=101, right=2)
        self.advance(.3, cycle_pressed=True)  # one native ammo action issued
        self.advance(.31, cycle_pressed=True)
        self.advance(.32, cycle_pressed=True)  # latest desired preset is 1
        self.assertEqual(self.env['cycles'], 1)
        self.advance(.4)  # readback of issued action; no stale right action
        self.advance(.5)
        self.advance(.6)
        self.assertEqual(self.state['preset'], 1)
        self.assertEqual(self.env['cycles'], 2)
        self.assertEqual(self.env['ammo_slot'], 1)
        self.assertEqual(self.env['slot'], 1)
        self.assertEqual(self.state['equips'], 1)

    def test_uncertain_action_discards_queued_preset_without_retry(self):
        self.advance(.2, ammo=True)
        self.preset(2, left=101)
        self.preset(3, right=2)
        self.advance(.3, cycle_pressed=True, no_transition=True)
        self.advance(.31, cycle_pressed=True)
        self.advance(.9)
        self.advance(1.0, no_transition=False)
        self.assertEqual(self.env['cycles'], 1)
        self.assertEqual(self.env['slot'], 1)

    def test_menu_chat_gate_discards_press_instead_of_delaying(self):
        self.advance(.2, ammo=True)
        self.preset(2, left=101)
        self.advance(.3, cycle_pressed=True, menu=True)
        self.advance(.4, menu=False)
        self.advance(.5)
        self.assertEqual(self.env['cycles'], 0)
        self.assertEqual(self.state['preset'], 1)


    def test_save_during_unverified_action_preserves_existing_preset(self):
        self.advance(.2, ammo=True)
        self.preset(2, left=101)
        self.preset(3, right=2)
        self.advance(.3, cycle_pressed=True, no_transition=True)
        self.advance(.31, held=True, save_preset=3)
        self.assertEqual(self.env['saves'], 0)
        self.assertIsNone(self.store['presets'][3]['targets']['left'])
        self.advance(.9)
        self.assertEqual(self.env['cycles'], 1)


class HudCoordinator(unittest.TestCase):
    diagnostics = False
    hud_enabled = True
    setUp = CoordinatorSave.setUp
    advance = CoordinatorSave.advance


    def test_shutdown_cleans_gui_and_logs_before_forwarding_with_original_return_tuple(self):
        result = self.lua.globals().shutdown('first', None, 7)
        self.assertEqual(result, ('first', None, 7))
        self.assertEqual(self.env['stock_saw_hud_shutdown'], 1)
        self.assertEqual(self.env['stock_saw_log_closes'], 1)
        self.assertEqual(self.state['status'], 'shutdown')
        body = self.env['files']['WeaponDefaults.log']
        self.assertIn('SHUTDOWN_BEGIN', body)
        self.assertIn('HUD_SHUTDOWN gui=destroyed', body)
        self.assertIn('SHUTDOWN_END addon_cleanup=true', body)

    def test_shutdown_stops_reentrant_and_later_native_work_and_cleanup_is_idempotent(self):
        self.env['shutdown_update'] = True
        self.env['save_preset'], self.env['held'] = 1, True
        reads = self.env['mode_reads']
        self.lua.globals().shutdown()
        self.lua.globals().update()
        self.lua.globals().shutdown()
        self.assertEqual(self.env['mode_reads'], reads)
        self.assertEqual(self.env['saves'], 0)
        self.assertEqual(self.env['hud_shutdowns'], 1)
        self.assertEqual(self.env['log_closes'], 1)
        self.assertEqual(self.env['stock_shutdowns'], 2)


    def test_only_offered_selections_hide_without_any_mode_or_preset_mutation(self):
        self.advance(.1, held=True, hud_select_pressed=True)
        self.assertIsNone(self.env['hud_selections'])
        for index, side in enumerate(('right','None','right','None'), 1):
            self.advance(index*.2, held=True, hud_select_pressed=True)
            self.assertEqual(self.env['hud_selection'], side)
            self.assertEqual(self.env['hud_presented_selection'], side)
        self.assertEqual(self.env['hud_selected_resource'], '361EFAD956A1F180')
        self.assertEqual(self.env['saves'], 0)
        self.assertEqual(self.env['clears'], 0)
        self.assertEqual(self.env['cycles'], 0)
        reads = self.env['hud_reads']
        self.advance(1.3)
        self.assertEqual(self.env['hud_reads'], reads, 'hidden choice needs no mode/icon reads')
        self.advance(1.5, hud_select_pressed=True)
        self.assertEqual(self.env['hud_selection'], 'right')


    def test_display_selection_does_not_abort_an_already_pending_native_application(self):
        self.advance(.1, held=True, save_preset=1, slot=1)
        self.advance(.2, eid=11, slot=0)
        self.advance(.21, hud_select_pressed=True)
        self.advance(.22, hud_select_pressed=True)
        self.advance(.5)
        self.assertEqual(self.env['cycles'], 1)
        self.assertEqual(self.env['hud_selection'], 'right')


    def test_property_arrows_move_without_p_and_p_stops_then_selects_presets(self):
        self.advance(.1, held=True, hud_select_pressed=True)
        self.advance(.15, hud_move_active=True, hud_move=self.lua.table_from({'x':1,'y':0}))
        self.assertEqual(self.env['hud_moves'], 1)
        self.advance(.2, pressed=True, down=True)
        self.assertEqual(self.env['hud_moves'], 1)
        self.assertEqual(self.env['hud_finishes'], 1)
        self.assertTrue(self.env['help_lines'][3].startswith('1.'))
        self.advance(.3, down=False, preset_pressed=1)
        self.assertEqual(self.env['saves'], 1)
        self.advance(.4, hud_select_pressed=True)
        self.assertIsNone(self.env['hud_selections'])
        self.advance(.45)
        self.assertEqual(self.env['hud_moves'], 2)
        self.advance(.5, held=False)
        self.assertEqual(self.env['hud_finishes'], 2)
        self.assertEqual(self.env['clears'], 0)

    def test_panel_activation_twice_does_not_clear_without_clear_command(self):
        self.advance(.1, pressed=True, held=True)
        self.advance(.2, pressed=True)
        self.assertEqual(self.env['clears'], 0)
        self.advance(.3, clear_pressed=True, ready=False)
        self.assertEqual(self.env['clears'], 1)

    def test_separate_clear_requires_card_and_prefers_numbered_save_on_same_frame(self):
        self.advance(.1, clear_pressed=True, held=False)
        self.advance(.2, clear_pressed=True, held=True, card_open=False)
        self.assertEqual(self.env['clears'], 0)
        self.advance(.3, clear_pressed=True, card_open=True, save_preset=1)
        self.assertEqual(self.env['clears'], 0);self.assertEqual(self.env['saves'], 1)
        self.assertEqual(self.env['consumed_clear'], 1)
        self.assertEqual(self.env['cycles'], 0)


    def test_first_h_preserves_each_existing_preference_and_reopening_never_cycles(self):
        for selected in (None, 'right', 'None'):
            with self.subTest(selected=selected):
                self.setUp()
                self.env['hud_selection']=selected
                self.advance(.1, held=True, hud_select_pressed=True)
                self.assertEqual(self.env['hud_selection'], selected)
                self.assertIsNone(self.env['hud_selections'])
                self.assertTrue(self.env['help_visible'])
                self.advance(.2, held=False)
                self.advance(.3, held=True, hud_select_pressed=True)
                self.assertEqual(self.env['hud_selection'], selected)
                self.assertIsNone(self.env['hud_selections'])
                self.assertEqual(self.env['saves'], 0)
                self.assertEqual(self.env['cycles'], 0)


    def test_utility_hand_departure_discards_property_latch_without_creating_equip(self):
        self.advance(.1, held=True, hud_select_pressed=True)
        self.advance(.2, hud_move_active=True, hud_move=self.lua.table_from({'x':0,'y':1}))
        self.advance(.3, eid=0)
        self.assertFalse(self.env['help_visible'])
        self.assertEqual(self.env['hud_finishes'], 1)
        self.advance(.4, eid=10)
        self.assertEqual(self.env['hud_moves'], 1)
        self.assertEqual(self.state['equips'], 1)
        self.advance(.5, hud_select_pressed=True)
        self.assertIsNone(self.env['hud_selections'])
        self.advance(.6)
        self.assertEqual(self.env['hud_moves'], 2)
        self.assertEqual(self.env['cycles'], 0)


    def test_unavailable_renderer_hides_instead_of_retaining_stale_icon(self):
        self.env['hud_hidden']=False
        self.advance(.2, hud_render_unavailable=True)
        self.assertTrue(self.env['hud_hidden'])
        self.advance(.3, held=True, save_preset=1)
        self.assertEqual(self.env['saves'], 1)


class IndependentFeatures(unittest.TestCase):
    def fixture(self, *, presets=False, broken_store=False):
        f=CoordinatorSave()
        f.presets_enabled=presets;f.hud_enabled=True;f.hud_display='text'
        f.store_open_failure=broken_store;f.setUp()
        return f

    def test_hud_only_never_opens_presets_or_changes_modes_despite_preset_commands(self):
        f=self.fixture()
        self.assertIsNone(f.env.store_opens)
        self.assertEqual(f.env.store_contexts,1)
        self.assertFalse(f.env.poll_presets)
        self.assertEqual(f.env.hud_display,'text')
        f.store.targets.right=f.lua.table_from({'kind':'firemode','slot':1,'value':2})
        for i in range(1,12):
            f.advance(i*.15,eid=10+i%2,held=True,pressed=True,down=True,
                      save_preset=2,cycle_pressed=True)
        for name in ('ensures','saves','clears','cycles'):
            self.assertEqual(f.env[name],0,name)
        self.assertGreater(f.env.hud_renders,0)

    def test_hud_only_selection_and_movement_still_work(self):
        f=self.fixture()
        f.advance(.1,held=True,hud_select_pressed=True)
        self.assertIsNone(f.env.hud_selections)
        f.advance(.15,hud_select_pressed=True)
        self.assertEqual(f.env.hud_selections,1)
        f.advance(.2,held=True,down=False,hud_move_active=True,hud_move=f.lua.table_from({'x':1,'y':0}))
        self.assertEqual(f.env.hud_moves,1)
        self.assertEqual(f.env.cycles,0)
        f.lua.globals().shutdown()
        self.assertEqual(f.env.hud_shutdowns,1)

    def test_corrupt_presets_do_not_disable_hud_when_both_features_selected(self):
        f=self.fixture(presets=True,broken_store=True)
        self.assertEqual(f.env.store_opens,1)
        self.assertEqual(f.env.store_contexts,1)
        self.assertFalse(f.env.poll_presets)
        f.advance(.1,held=True,hud_select_pressed=True)
        f.advance(.2,hud_select_pressed=True)
        self.assertEqual(f.env.hud_selections,1)
        self.assertEqual(f.env.ensures,0)


class FirstUsePresets(unittest.TestCase):
    def fixture(self, **options):
        f=CoordinatorSave()
        f.diagnostics=False;f.hud_enabled=options.pop('hud',False);f.setUp()
        f.env.store_unknown=True
        f.advance(.02,eid=11,**options)
        return f

    def test_unknown_type_is_registered_empty_without_observing_modes_or_cycling(self):
        f=self.fixture(slot=1,mode_failure=True)
        f.advance(.2)
        self.assertIsNone(f.env.initializations)
        self.assertEqual(f.env.cycles,0)
        self.assertFalse(f.env.store_unknown)
        self.assertEqual(len(list(f.store.presets[1].targets.items())),0)

    def test_manual_clear_wins_before_first_capture_and_stays_empty_on_reequip(self):
        f=self.fixture()
        f.advance(.04,pressed=True,held=True)
        f.advance(.1,clear_pressed=True)
        f.advance(.3)
        f.advance(.4,eid=12)
        f.advance(.7)
        self.assertEqual(f.env.clears,1)
        self.assertIsNone(f.env.initializations)
        self.assertEqual(f.env.cycles,0)
        self.assertFalse(list(f.store.targets.items()))


    def test_competing_clear_before_commit_is_preserved(self):
        f=self.fixture()
        f.store.clear_all(f.store)
        f.advance(.3)
        self.assertIsNone(f.env.initializations)
        self.assertFalse(list(f.store.targets.items()))
        self.assertEqual(f.env.cycles,0)


    def test_hud_cycle_uses_current_instance_modules_without_mutating_presets(self):
        f=CoordinatorSave();f.hud_enabled=True;f.diagnostics=False;f.setUp()
        f.advance(.1,held=True,hud_select_pressed=True)
        f.advance(.2,held=True,hud_select_pressed=True,no_right=True,laser=True,flashlight=True)
        self.assertEqual(list(f.env.hud_available.values()),['left'])
        self.assertEqual(f.env.hud_selection,'left')
        f.advance(.4,hud_select_pressed=True)
        self.assertEqual(f.env.hud_selection,'None')
        f.advance(.6,hud_select_pressed=True,light_absent=True)
        self.assertEqual(list(f.env.hud_available.values()),['left'])
        self.assertEqual(f.env.hud_selection,'left')
        f.advance(.8,hud_select_pressed=True)
        self.assertEqual(f.env.hud_selection,'None')
        self.assertEqual(f.env.saves,0)
        self.assertEqual(f.env.cycles,0)


class GlobalFlashlightIntegration(unittest.TestCase):
    def fixture(self, **options):
        f=CoordinatorSave();f.diagnostics=False;f.hud_enabled=options.pop('hud',False)
        f.presets_enabled=options.pop('presets',True);f.setUp()
        f.advance(.02,eid=11,flashlight=True,**options)
        return f

    def test_manual_mode_is_saved_without_p_then_applied_on_another_instance(self):
        f=self.fixture(light_value=0)
        f.advance(.2,light_value=2)
        self.assertEqual(f.env.global_light,2)
        self.assertEqual(f.env.light_saves,2)
        f.advance(.3,eid=12,light_value=0)
        f.advance(.5)
        self.assertEqual(f.env.light_value,1)
        self.assertEqual(f.env.global_light,2)
        f.advance(.6);f.advance(.7)
        self.assertEqual(f.env.light_value,2)
        self.assertEqual(f.env.light_saves,2)
        self.assertEqual(f.env.cycles,2)


    def test_clear_all_does_not_clear_or_rewrite_global_flashlight(self):
        f=self.fixture(light_value=1)
        f.advance(.2,held=True,pressed=True)
        f.advance(.3,clear_pressed=True)
        self.assertEqual(f.env.clears,1)
        self.assertEqual(f.env.global_light,1)
        self.assertEqual(f.env.light_saves,1)
        f.advance(.4,eid=12,light_value=0,held=False)
        f.advance(.6);f.advance(.7)
        self.assertEqual(f.env.light_value,1)

    def test_stim_grenade_return_preserves_manual_light_without_an_equip(self):
        f=self.fixture(light_value=2)
        f.advance(.2,light_value=1)
        equips=f.state.equips
        f.advance(.3,eid=90,utility=True)
        f.advance(.4,eid=11,utility=False)
        f.advance(.6)
        self.assertEqual(f.state.equips,equips)
        self.assertEqual(f.env.cycles,0)
        self.assertEqual(f.env.global_light,1)


    def test_hud_only_neither_reads_light_nor_changes_its_mode(self):
        f=self.fixture(hud=True,presets=False,global_light=2,light_value=0)
        f.advance(.2,held=True,hud_select_pressed=True)
        f.advance(.3,hud_select_pressed=True)
        f.advance(.4,light_value=1)
        self.assertIsNone(f.env.light_reads)
        self.assertIsNone(f.env.light_saves)
        self.assertEqual(f.env.cycles,0)
        self.assertNotIn('down',list(f.env.hud_available.values()))

    def test_light_failure_does_not_block_other_saved_modes_or_hud_selection(self):
        f=self.fixture(hud=True,light_failure=True)
        f.advance(.2,held=True,save_preset=1)
        self.assertEqual(f.env.saves,1)
        f.advance(.3,hud_select_pressed=True)
        f.advance(.4,hud_select_pressed=True)
        self.assertEqual(f.env.hud_selection,'right')
        self.assertIsNone(f.env.global_light)


class NormalizedSaveIntegration(unittest.TestCase):
    def fixture(self, **options):
        f=CoordinatorSave();f.real_store=True;f.diagnostics=False;f.setUp()
        f.advance(.02,eid=11,**options);f.advance(.2)
        return f

    def presets(self,f):
        return f.store.get_presets(f.store,'361EFAD956A1F180')

    def test_two_choices_normalize_one_two_and_reject_three(self):
        f=self.fixture()
        for time,index,slot,other,empty in ((.3,1,0,2,3),(.4,2,0,1,3)):
            f.advance(time,held=True,save_preset=index,slot=slot)
            rows=self.presets(f)
            self.assertEqual(rows[index].targets.right.value,2+slot)
            self.assertEqual(rows[other].targets.right.value,3-slot)
            self.assertFalse(list(rows[empty].targets.items()))
        previous=f.disk.data
        f.advance(.5,held=True,save_preset=3,slot=1)
        self.assertEqual(f.disk.data,previous)
        self.assertEqual(f.env.cycles,0)

    def test_three_choices_remove_old_duplicate_and_keep_other_preset(self):
        f=self.fixture(no_right=True,scope=True)
        # Existing presets are an explicit precondition. First-equip generation
        # was retired in favour of the importable starter pack.
        for index,slot,value in ((1,3,150),(3,2,75)):
            target=f.lua.table_from({'slot':slot,'kind':'zeroing','value':value})
            self.assertTrue(f.store.merge(f.store,'361EFAD956A1F180',f.lua.table_from({'up':target}),index))
        rows=self.presets(f)
        self.assertEqual(rows[1].targets.up.value,150)
        f.advance(.3,held=True,save_preset=2)
        rows=self.presets(f)
        self.assertFalse(list(rows[1].targets.items()))
        self.assertEqual(rows[2].targets.up.value,150)
        self.assertEqual(rows[3].targets.up.value,75)


class ContextHelpIntegration(unittest.TestCase):
    def test_display_changes_refresh_property_help_without_weapon_actions_and_require_valid_card(self):
        f=self.fixture()
        f.advance(.1,held=True,hud_display_pressed=True)
        self.assertIsNone(f.env.hud_display_changes)
        f.advance(.2,hud_select_pressed=True)
        before=(f.state.equips,f.env.saves,f.env.clears,f.env.cycles)
        for index,(style,label) in enumerate([('icon','ICON'),('text','TEXT'),('both','ICON AND TEXT')]):
            f.advance(.3+index*.01,hud_display_pressed=True)
            self.assertEqual(f.env.hud_display,style)
            self.assertIn('DISPLAY: ICON / TEXT / ICON AND TEXT',self.text(f))
            active=[run.text for run in f.env.help_lines.runs[5].values() if run.accent]
            self.assertEqual(active,[label])
            self.assertEqual((f.state.equips,f.env.saves,f.env.clears,f.env.cycles),before)
        f.advance(.34,hud_display_pressed=True,hud_display_failure=True)
        self.assertEqual(f.env.hud_display,'both')
        f.advance(.35,hud_display_pressed=True,hud_display_failure=False,invalid_profile=True)
        self.assertEqual(f.env.hud_display_changes,3)
        f.advance(.36,invalid_profile=False)
        f.advance(.37,hud_display_pressed=True,card_open=False)
        self.assertEqual(f.env.hud_display_changes,3)
        f.advance(.5,card_open=True,pressed=True)
        self.assertTrue(f.env.help_visible)
        f.advance(.51,hud_display_pressed=True)
        self.assertEqual(f.env.hud_display_changes,3)
        self.assertNotIn('F10',self.text(f))

    def fixture(self, hud=True, presets=True):
        f=CoordinatorSave();f.diagnostics=False;f.hud_enabled=hud;f.presets_enabled=presets;f.setUp()
        return f

    def text(self,f):
        return '\n'.join(f.env.help_lines[i] for i in range(1,len(f.env.help_lines)+1))

    def test_language_updates_visible_help_in_same_frame_and_closed_card_blocks_it(self):
        f=self.fixture()
        f.lua.globals().Text.register('fr',f.lua.table_from({'help.holding':'MAINTENU: {card}'}))
        f.advance(.1,held=True)
        f.advance(.2,pressed=True)
        f.advance(.22,locale_pressed=True)
        self.assertIn('LANGUAGE: ENGLISH',self.text(f))
        f.advance(.24,locale_pressed=True)
        self.assertEqual(f.env.help_lines[1],'MAINTENU: R')
        self.assertIn('LANGUAGE: FR',self.text(f))
        f.advance(.25,locale_pressed=True,card_open=False)
        self.assertEqual(f.lua.globals().Text.selected_language(),'fr')

    def test_presets_only_p_press_latches_until_actual_card_release(self):
        f=self.fixture(hud=False)
        f.advance(.1,held=True)
        self.assertFalse(f.env.help_visible)
        f.advance(.2,save_held=True,pressed=True,card_label='Mouse5',save_label='F8',cycle_label='Slash')
        self.assertTrue(f.env.help_visible)
        self.assertIn('CURRENTLY HOLDING: MOUSE5',self.text(f));self.assertNotIn('SAVE PRESETS',self.text(f))
        self.assertNotIn('F8',self.text(f).splitlines()[0])
        self.assertIn('CURRENT SWAP HOTKEY: PRESS SLASH',self.text(f))
        self.assertNotIn('3.',self.text(f))
        self.assertEqual(f.env.saves,0)
        f.advance(.3,save_held=False)
        self.assertTrue(f.env.help_visible)
        f.advance(.4,save_held=True,pressed=True,held=False)
        self.assertFalse(f.env.help_visible)
        f.advance(.5,save_held=False,held=True)
        self.assertFalse(f.env.help_visible)


    def test_p_must_be_accepted_before_released_modifier_numbers_can_save(self):
        f=self.fixture(hud=False)
        f.advance(.1,held=True,preset_pressed=1)
        self.assertEqual(f.env.saves,0)
        f.advance(.2,pressed=True,down=True)
        self.assertTrue(f.env.help_visible)
        f.advance(.3,down=False)
        f.advance(.4,preset_pressed=1,slot=0)
        self.assertEqual(f.env.saves,1)
        self.assertEqual(f.store.targets.right.value,2)
        self.assertEqual(f.env.cycles,0)
        f.advance(.5,held=False)
        self.assertFalse(f.env.help_visible)
        f.advance(.6,held=True,preset_pressed=2)
        self.assertEqual(f.env.saves,1)
        self.assertFalse(f.env.help_visible)

    def test_h_switches_away_from_preset_edit_latch(self):
        f=self.fixture()
        f.advance(.2,held=True,pressed=True,down=True)
        f.advance(.3,down=False,hud_select_pressed=True)
        self.assertIn('CURRENT PROPERTY',self.text(f))
        f.advance(.4,preset_pressed=1)
        self.assertEqual(f.env.saves,0)


    def test_new_weapon_cannot_inherit_released_p_save_latch(self):
        f=self.fixture()
        f.advance(.2,held=True,pressed=True)
        f.advance(.4,eid=11,preset_pressed=1)
        f.advance(.6,preset_pressed=1)
        self.assertEqual(f.env.saves,0)
        self.assertFalse(f.env.help_visible)


    def test_h_cycles_hidden_and_property_alternatives_with_current_values(self):
        f=self.fixture()
        f.advance(.2,held=True,hud_select_pressed=True,scope=True)
        self.assertIn('CURRENT PROPERTY: HIDE',self.text(f))
        f.advance(.205,hud_select_pressed=True)
        self.assertIn('OTHER AVAILABLE PROPERTIES: 150 M, HIDE',self.text(f))
        f.advance(.21,hud_select_pressed=True)
        self.assertIn('CURRENT PROPERTY: 150 M',self.text(f))
        f.advance(.22,hud_select_pressed=True)
        self.assertIn('CURRENT PROPERTY: HIDE',self.text(f))
        self.assertIn('OTHER AVAILABLE PROPERTIES: BURST, 150 M',self.text(f))


    def test_failed_help_renderer_does_not_stop_saving(self):
        f=self.fixture()
        f.advance(.2,held=True,save_held=True,pressed=True,help_set_throw=True)
        f.advance(.3,save_preset=1)
        self.assertEqual(f.env.saves,1)
        self.assertNotEqual(f.state.status,'stopped')

    def test_read_failure_hides_instead_of_leaving_stale_text(self):
        f=self.fixture()
        f.advance(.2,held=True,save_held=True,pressed=True)
        self.assertTrue(f.env.help_visible)
        f.advance(.4,mode_failure=True)
        self.assertFalse(f.env.help_visible)
        f.advance(.51,mode_failure=False)
        self.assertTrue(f.env.help_visible)


    def test_presets_only_help_receives_icons_for_saved_not_current_mode(self):
        f=self.fixture(hud=False)
        f.advance(.2,held=True,save_preset=1,slot=0)
        f.advance(.4,slot=1,save_held=True,pressed=True)
        self.assertTrue(f.env.help_has_icons)
        runs=f.env.help_lines.runs[3]
        icons=[run for _,run in runs.items() if run.kind=='icon']
        self.assertEqual(len(icons),1)
        self.assertEqual(icons[0].hash,'3efff09cd12fb89a')
        self.assertEqual(f.env.cycles,0)


class GrenadeObservationIntegration(unittest.TestCase):
    def fixture(self, diagnostics):
        f=CoordinatorSave();f.diagnostics=diagnostics;f.setUp()
        return f

    def test_diagnostic_key_observation_does_not_make_equip_save_or_native_action(self):
        f=self.fixture(True)
        before=(f.state.equips,f.env.saves,f.env.clears,f.env.cycles)
        f.advance(.2,grenade_pressed=True,grenade_label='LAlt')
        self.assertTrue(f.env.poll_diagnostics)
        self.assertEqual((f.state.equips,f.env.saves,f.env.clears,f.env.cycles),before)
        text='\n'.join(f.env.logs.values())
        self.assertIn('GRENADE_INPUT sequence=1 binding=LAlt source=thread_key_state observation_only=true',text)
        f.advance(.3,eid=22,utility=True)
        f.advance(.5,eid=10,utility=False)
        self.assertEqual((f.state.equips,f.env.saves,f.env.clears,f.env.cycles),before)
        self.assertIn('UTILITY_RETURN','\n'.join(f.env.logs.values()))


class CoordinatorSecondaryFire(unittest.TestCase):
    def fixture(self):
        f=CoordinatorSave();f.diagnostics=False;f.hud_enabled=True;f.setUp()
        f.advance(.1,secondary=True,secondary_slot=0,scope=True)
        return f

    def test_alternate_display_save_and_help_preserve_parent_record_and_right(self):
        f=self.fixture()
        f.advance(.2,held=True,save_held=True,pressed=True,save_preset=1,slot=0)
        f.advance(.4,secondary_slot=1,save_preset=1)
        targets=f.store.targets
        self.assertEqual((targets.left.kind,targets.left.value,targets.left.slot),('secondary_fire',1,2))
        self.assertEqual(targets.right.value,2)  # retained; inactive firemode was not invented
        self.assertEqual(f.env.cycles,0)
        self.assertEqual(f.state.equips,1)
        self.assertTrue(f.env.help_visible)
        self.assertIn('FLAMETHROWER','\n'.join(f.env.help_lines[i] for i in range(1,len(f.env.help_lines)+1)))


    def test_manual_alternate_toggle_is_not_an_equip_or_cursor_reset(self):
        f=self.fixture()
        f.advance(.2,held=True,save_preset=2)
        for t,slot in ((.3,1),(.4,0),(.5,1)):
            f.advance(t,held=False,secondary_slot=slot)
            self.assertEqual(f.state.preset,2)
            self.assertEqual(f.state.equips,1)
            self.assertEqual(f.env.cycles,0)


    def test_restoring_secondary_does_not_reapply_stored_ordinary_firemode(self):
        f=self.fixture()
        f.advance(.2,held=True,save_preset=1,slot=0)
        f.advance(.3,secondary_slot=1,save_preset=1)
        f.advance(.4,held=False,secondary_slot=0,slot=1)
        f.advance(.5,eid=11)
        for t in (.7,.9,1.1): f.advance(t)
        self.assertEqual(f.env.secondary_slot,1)
        self.assertEqual(f.env.slot,1)
        self.assertEqual(list(f.env.actions.values()),[11])
        self.assertEqual(f.state.equips,2)
        self.assertFalse(any('DEFER' in line or 'STOP' in line for line in f.env.logs.values()))

    def test_switching_to_normal_then_applies_the_ordinary_firemode(self):
        f=self.fixture()
        f.advance(.2,held=True,save_preset=1,slot=0)
        f.advance(.3,held=False,secondary_slot=1,slot=1)
        f.advance(.4,cycle_pressed=True)
        for t in (.6,.8,1.0): f.advance(t)
        self.assertEqual(f.env.secondary_slot,0)
        self.assertEqual(f.env.slot,0)
        self.assertEqual(list(f.env.actions.values()),[11,3])
        self.assertEqual(f.state.equips,1)


    def legacy(self, single=True, reverse=False, diagnostics=False):
        f=CoordinatorSave();f.diagnostics=diagnostics;f.hud_enabled=True;f.setUp()
        f.advance(.1,secondary=True,secondary_slot=1,slot=0 if single else 2,
                  single_fire=single,three_fire=not single,scope=True,reverse_secondary=reverse)
        side='left' if reverse else 'right'
        f.store.targets[side]=f.lua.table_from({'kind':'firemode','value':1 if single else 2,'slot':1 if single else 2})
        f.store.targets.up=f.lua.table_from({'kind':'zeroing','value':150,'slot':3})
        return f

    def test_legacy_single_ordinary_choice_returns_without_advancing_or_saving(self):
        for diagnostics in (False,True):
            f=self.legacy(diagnostics=diagnostics)
            f.advance(.2,held=True,save_held=True,pressed=True)
            self.assertTrue(f.env.help_visible)
            self.assertNotIn('UNAVAILABLE',f.env.help_lines[3])
            f.advance(.3,held=False,save_held=False,cycle_pressed=True)
            for t in (.5,.7,.9): f.advance(t)
            self.assertEqual(list(f.env.actions.values()),[3])
            self.assertEqual((f.env.secondary_slot,f.env.slot),(0,0))
            self.assertEqual(f.env.invalidated_display,f.env.eid)
            self.assertIsNone(f.store.targets.left)
            self.assertEqual(f.env.saves,0)
            self.assertEqual(f.state.equips,1)
            self.assertNotIn('STOP ',''.join(f.env.files.values()))

    def test_legacy_multiple_choices_verify_return_then_cycle_with_separate_budget(self):
        for reverse in (False,True):
            f=self.legacy(single=False,reverse=reverse)
            f.advance(.2,cycle_pressed=True)
            self.assertEqual((f.env.secondary_slot,f.env.slot),(0,2))
            for t in (.4,.6,.8,1.0): f.advance(t)
            self.assertEqual(list(f.env.actions.values()),[3,3,3])
            self.assertEqual((f.env.secondary_slot,f.env.slot),(0,1))
            self.assertIsNone(f.store.targets.right if reverse else f.store.targets.left)
            self.assertNotIn('STOP ',''.join(f.env.files.values()))


    def test_uncertain_primary_outcome_is_not_retried_and_discards_queued_preset(self):
        f=self.legacy()
        f.advance(.2,cycle_pressed=True,no_transition=True)
        f.store.presets[2].targets.left=f.lua.eval("{kind='secondary_fire',value=1,slot=2}")
        f.advance(.3,cycle_pressed=True)
        for t in (.5,.8,1.0,1.2): f.advance(t,no_transition=False)
        self.assertEqual(list(f.env.actions.values()),[3])
        self.assertEqual(f.env.secondary_slot,1)
        self.assertIn('action outcome unreadable; no repeat',f.env.files['WeaponDefaults.log'])

    def test_uncertain_explicit_selector_is_not_retried_via_firemode_activation(self):
        f=self.legacy()
        f.store.targets.left=f.lua.eval("{kind='secondary_fire',value=0,slot=1}")
        f.advance(.2,cycle_pressed=True,no_transition=True)
        for t in (.4,.8,1.0): f.advance(t)
        self.assertEqual(list(f.env.actions.values()),[11])
        self.assertEqual(f.env.secondary_slot,1)


class ResetCoordinatorTests(unittest.TestCase):
    def fixture(self, *, hud=True, presets=True, broken_store=False):
        f = CoordinatorSave()
        f.hud_enabled, f.presets_enabled = hud, presets
        f.store_open_failure = broken_store
        f.setUp()
        return f

    def test_reset_on_ship_has_no_active_weapon_requirement_and_reloads_once(self):
        f = self.fixture()
        old_input_opens = f.env.input_opens
        f.advance(.1, reader_failure='not in mission', reset_pressed=True)
        self.assertEqual(f.env.reset_prepares, 1)
        self.assertEqual(f.env.reset_backups, 1)
        self.assertEqual(f.env.reset_native_clears, 1)
        self.assertEqual(f.env.reset_commits, 1)
        self.assertEqual(f.env.input_opens, old_input_opens + 1)
        self.assertEqual(f.env.reset_profile, '76561198000000000')
        self.assertEqual(f.env.cycles, 0)
        f.advance(.2)
        self.assertEqual(f.env.reset_prepares, 1)
        self.assertIn('RESET completed', '\n'.join(f.env.logs.values()))

    def test_blocked_unknown_background_or_foreign_profile_never_prepare(self):
        for changed in ({'menu': True}, {'gate_failure': True}, {'foreground': False},
                        {'invalid_profile': True}, {'reset_ready': False}):
            with self.subTest(changed=changed):
                f = self.fixture()
                f.advance(.1, reset_pressed=True, **changed)
                self.assertIsNone(f.env.reset_prepares)
                self.assertIsNone(f.env.reset_native_clears)
                self.assertEqual(f.env.cycles, 0)

    def test_backup_failure_never_clears_native_or_commits_files(self):
        f = self.fixture()
        f.store.targets.right = f.lua.eval("{kind='firemode',slot=1,value=2}")
        f.advance(.1, reset_pressed=True, reset_backup_failure=True)
        self.assertEqual(f.env.reset_backups, 1)
        self.assertIsNone(f.env.reset_native_clears)
        self.assertIsNone(f.env.reset_commits)
        self.assertEqual(f.store.targets.right.value, 2)
        self.assertIn('native_cleared=false', '\n'.join(f.env.logs.values()))

    def test_native_clear_failure_never_commits_files(self):
        f = self.fixture()
        f.advance(.1, reset_pressed=True, reset_native_failure=True)
        self.assertEqual(f.env.reset_backups, 1)
        self.assertIsNone(f.env.reset_commits)
        self.assertIn('phase=native bindings', '\n'.join(f.env.logs.values()))
        self.assertIn('native_cleared=unknown', '\n'.join(f.env.logs.values()))


    def test_input_reload_failure_does_not_keep_stale_controls_or_mode_jobs(self):
        f = self.fixture()
        f.advance(.1, reset_pressed=True, reset_reload_failure=True)
        f.advance(.2, save_preset=1, held=True, cycle_pressed=True)
        self.assertEqual(f.env.saves, 0)
        self.assertEqual(f.env.cycles, 0)
        self.assertIn('phase=reload native_cleared=true', '\n'.join(f.env.logs.values()))


    def test_success_cancels_edits_flashlight_and_uncommitted_hud_move(self):
        f = self.fixture()
        f.store.targets.right = f.lua.eval("{kind='firemode',slot=1,value=2}")
        f.env.global_light = 1
        f.env.hud_selection = 'right'
        f.advance(.05, pressed=True, held=True)
        f.advance(.1, reset_pressed=True, hud_moving=True, held=False,
                  cycle_pressed=True, save_preset=2)
        self.assertEqual(f.env.cycles, 0)
        self.assertEqual(f.env.saves, 0)
        self.assertIsNone(f.store.targets.right)
        self.assertIsNone(f.env.global_light)
        self.assertIsNone(f.env.hud_selection)
        self.assertEqual(f.env.hud_cancel_moves, 1)
        self.assertFalse(f.env.hud_moving)
        self.assertIsNone(f.env.hud_finishes)
        self.assertEqual(f.env.hud_shutdowns, 1)
        self.assertFalse(f.env.help_visible)
        self.assertTrue(f.env.reset_defaults)


if __name__ == '__main__':
    unittest.main()

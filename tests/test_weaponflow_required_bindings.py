"""Game-owned WeaponFlow controls; fake native memory and files only."""
from pathlib import Path
import struct
import unittest
from lupa.luajit21 import LuaRuntime
from binding_fixtures import Fixture as MenuFixture

ROOT=Path(__file__).resolve().parents[1]
RECORDS=(ROOT/'src/weaponflow_game_controls.lua').read_text(encoding='utf-8')
MENU=(ROOT/'src/weaponflow_mod_bindings.lua').read_text(encoding='utf-8')
INPUT=(ROOT/'src/weaponflow_input.lua').read_text(encoding='utf-8')


def fixture(integrated=False, seeded=True):
    f=MenuFixture(integrated=integrated)
    f.lua.globals().Bindings=f.lua.execute(RECORDS)
    f.module=f.lua.execute(MENU)
    f.lua.globals().RequiredInput=f.lua.execute(INPUT)
    f.lua.globals().module=f.module
    f.lua.execute(r'''
state.allowed=true;state.card_held=true;state.keys={};state.event_reads={};state.config={}
state.editing=false
state.options.editor_open=function() if state.editor_unknown then return nil end;return state.editing end
state.context.resolve_key=function(key)
 local vk,why=RequiredInput.hotkey_vk(key);return vk,key,why
end
state.context.button_label=function(row)
 local vk=Bindings.native_vk(row)
 if vk and vk>=65 and vk<=90 then return string.char(vk) end
end
state.context.allowed=true;state.context.card_held=true;state.context.reset_enabled=true;state.context.preset_help_open=true
state.context.key_down=function(vk)return state.keys[vk]==true end
state.context.gameplay_allowed=function()return state.allowed end
state.context.validate_profile=function()return not state.bad_profile end
state.context.get_input_config=function()return state.config end
state.options.resolve_action=function(code)return {section="CinematicCamera",action="Action"..tostring(code%65536+1),
 inherited_count=state.inherited and 1 or 0}end
state.menu.is_down=function()error("Must not invoke sweeping MBM is_down")end
function set_native(index,key,trigger,threshold)
 local rows={};local mappings={};local ffi=require("ffi")
 if key then
  rows={{key=key,trigger=trigger or 0,threshold=threshold or 0}}
  local bits=ffi.new("float[1]",threshold or 0)
  local button=RequiredInput.hotkey_vk(key)
  mappings={{simple_button=true,device=3,button_id=button,trigger=trigger or 0,
   threshold_bits=tonumber(ffi.cast("uint32_t *",bits)[0]),combine=0}}
 end
 state.raw[index]={count=#mappings,unbound=#mappings==0,mappings=mappings,signature=Bindings.encode(rows)}
end
state.options.replace_binding=function(code,rows,validate,signature)
 local valid,why=validate()
 if not valid then return nil,why,{native_attempted=false} end
 if state.preflight_error then return nil,state.preflight_error,{native_attempted=false} end
 if state.publish_error then return nil,state.publish_error end
 local i=code%65536+1
 assert(state.raw[i].signature==signature)
 state.published=(state.published or 0)+1
 local row=rows[1]
 set_native(i,row and row.key,row and row.trigger,row and row.threshold)
 return {status="synchronized"}
end
state.options.read_event=function(previous)
 local raw,why=state.options.watch_binding(previous)
 if not raw then return nil,why end
 local name=({[0]="save",[2]="cycle",[3]="hud",[4]="reset"})[previous.code%65536]
 state.event_reads[#state.event_reads+1]=module.ids[name]
 if state.action_error then return nil,state.action_error end
 raw.game_event=state.down[module.ids[name]]==true;return raw
end
state.markers={};state.mark_count=0
state.marker={contains=function(_,name)
 if state.marker_error then return nil,state.marker_error end
 return state.markers[name]~=nil and state.markers[name]~=false
end,mark=function(_,name)
 if state.marker_error then return nil,state.marker_error end
 state.mark_count=state.mark_count+1;state.markers[name]=true;return true
end,begin=function(_,name)
 if state.marker_error then return nil,state.marker_error end
 state.markers[name]="pending";return true
end,cancel=function(_,name)
 assert(state.markers[name]=="pending");state.markers[name]=false;return true
end}
''')
    if seeded:
        for index,key,trigger,threshold in [(1,'P',0,0),(3,'V',0,0),(4,'H',0,0)]:
            f.lua.globals().set_native(index,key,trigger,threshold)
    f.obj=f.module.new(f.state.options)
    return f


def event(f,time=0,card=True,allowed=True,foreground=True):
    f.state.context.card_held=card;f.state.context.allowed=allowed
    return f.obj.events(f.obj,time,foreground,f.state.context)


def native_button(f,index,button_id,device=3,trigger=0,threshold=0):
    bits=struct.unpack('<I',struct.pack('<f',threshold))[0]
    f.state.raw[index]=f.lua.table_from(dict(count=1,unbound=False,
        signature=f'{device}:{button_id}:{trigger}:{bits}',
        mappings=f.lua.table_from([f.lua.table_from(dict(simple_button=True,
            device=device,button_id=button_id,trigger=trigger,threshold_bits=bits,combine=0))])))


class NativeControlTests(unittest.TestCase):
    def test_cold_start_uses_game_bindings_without_editor_or_controls_file(self):
        f=fixture();f.state.editor_unknown=True
        f.poll();event(f,0,card=False);f.signal('cycle',True)
        self.assertTrue(event(f,.016,card=False).cycle.pressed)
        self.assertIsNone(f.state.published)
        self.assertEqual(set(f.state.rows.keys()),set(f.module.ids.values()))

    def test_ordinary_launch_and_remap_never_write_native_mappings(self):
        f=fixture()
        for t in (0,.1,1,3,20,100):f.poll(t)
        f.lua.globals().set_native(3,'J',5,.4);f.state.editing=True;f.poll(101)
        f.state.editing=False;f.poll(101.1)
        self.assertIsNone(f.state.published)
        self.assertEqual(event(f,102,card=False).cycle.label,'J')
        self.assertEqual(event(f,102,card=False).cycle.trigger_label,'DoubleTap')

    def test_late_native_load_recovers_without_ever_opening_mods(self):
        f=fixture();raw=f.state.raw[3];f.state.raw[3]=None;f.poll()
        self.assertFalse(event(f,0,card=False).cycle.ready)
        f.state.raw[3]=raw;f.poll(.1);event(f,.1,card=False)
        f.signal('cycle',True)
        self.assertTrue(event(f,.116,card=False).cycle.pressed)
        self.assertIsNone(f.state.published)

    def test_game_unbind_and_config_reload_never_revive_previous_assignment(self):
        f=fixture();f.poll();f.lua.globals().set_native(3,None);f.poll(.1)
        result=event(f,.1,card=False).cycle
        self.assertFalse(result.ready);self.assertIn('unbound',result.reason)
        f.state['keys'][86]=True;f.signal('cycle',True)
        self.assertFalse(event(f,.116,card=False).cycle.pressed)
        self.assertIsNone(f.state.published)

    def test_native_event_is_seen_between_metadata_ticks_once(self):
        f=fixture();f.poll();event(f,0,card=False);reads=f.state.reads
        f.signal('cycle',True)
        self.assertTrue(event(f,.016,card=False).cycle.pressed)
        self.assertFalse(event(f,.032,card=False).cycle.pressed)
        f.signal('cycle',False);event(f,.048,card=False)
        self.assertEqual(f.state.reads,reads)

    def test_game_event_can_activate_with_physical_button_already_up(self):
        f=fixture();f.poll();event(f,0);f.signal('save',True)
        self.assertTrue(event(f,.016).save.pressed)

    def test_physical_button_alone_cannot_activate(self):
        f=fixture();f.poll();event(f,0);f.state['keys'][80]=True
        for time in (.016,.1,1,5):self.assertFalse(event(f,time).save.pressed)

    def test_all_eight_triggers_use_game_event_not_own_timing(self):
        for trigger in range(8):
            with self.subTest(trigger=trigger):
                f=fixture();f.lua.globals().set_native(1,'P',trigger,.3);f.poll();event(f,0)
                f.signal('save',True);result=event(f,.001).save
                self.assertTrue(result.pressed);self.assertTrue(result.down)
                self.assertEqual(result.bindings[1].trigger,trigger)
                self.assertAlmostEqual(result.bindings[1].threshold,.3,places=6)

    def test_hold_event_only_activates_once_until_game_releases(self):
        f=fixture();f.lua.globals().set_native(1,'P',2,0);f.poll();event(f,0)
        f.signal('save',True)
        self.assertTrue(event(f,.01).save.pressed)
        for t in (.1,.5,2):self.assertFalse(event(f,t).save.pressed)
        f.signal('save',False);event(f,3);f.signal('save',True)
        self.assertTrue(event(f,3.01).save.pressed)

    def test_focus_chat_or_card_loss_disarms_held_event(self):
        for kwargs in ({'foreground':False},{'allowed':False},{'card':False}):
            with self.subTest(kwargs=kwargs):
                f=fixture();native_button(f,1,193)
                f.lua.execute('state.engine.Keyboard.button_name=function()error("caption unavailable")end')
                f.poll();event(f,0);f.signal('save',True);f.state['keys'][193]=True
                self.assertFalse(event(f,.01,**kwargs).save.pressed)
                self.assertFalse(event(f,.02).save.pressed)
                f.signal('save',False);f.state['keys'][193]=False;event(f,.03)
                f.signal('save',True);self.assertTrue(event(f,.04).save.pressed)

    def test_event_signature_change_is_not_a_command_and_reacquires(self):
        f=fixture();f.poll();event(f,0,card=False)
        f.lua.globals().set_native(3,'J');f.signal('cycle',True)
        self.assertFalse(event(f,.01,card=False).cycle.pressed)
        f.signal('cycle',False);f.poll(.02);event(f,.02,card=False)
        f.signal('cycle',True);self.assertTrue(event(f,.03,card=False).cycle.pressed)

    def test_missing_dependency_or_bad_native_read_cannot_fall_back(self):
        for flag in ('missing','action_error'):
            with self.subTest(flag=flag):
                f=fixture();f.poll();event(f,0,card=False);f.state[flag]=True
                f.signal('cycle',True);f.state['keys'][86]=True
                self.assertFalse(event(f,.01,card=False).cycle.pressed)

    def test_sidecar_missing_duplicate_or_transferred_ownership_blocks(self):
        f=fixture();f.state.assignment_error=True;f.poll()
        self.assertFalse(event(f,0,card=False).cycle.ready)
        f.state.assignment_error=False
        f.state.assignments+='other.mod\t10\t2\n';f.poll(2)
        self.assertFalse(event(f,2,card=False).cycle.ready)
        self.assertIsNone(f.state.published)

    def test_disabled_features_query_no_events_or_reserve_buttons(self):
        f=fixture();f.poll();f.state.context.presets_enabled=False
        result=event(f,0)
        self.assertFalse(result.save.ready);self.assertEqual(len(result.save.vks),0)
        self.assertTrue(result.hud.ready)
        self.assertNotIn(f.module.ids.save,list(f.state.event_reads.values()))



class DefaultAndResetTests(unittest.TestCase):
    def new(self):
        f=fixture(seeded=False);f.state.context.default_state=f.state.marker;return f

    def test_first_use_registers_four_commands_and_sets_only_p_h_defaults(self):
        f=self.new();f.poll()
        self.assertEqual(f.state.published,2)
        self.assertEqual(f.state.raw[1].mappings[1].button_id,80)
        self.assertEqual(f.state.raw[4].mappings[1].button_id,72)
        for i in (3,5):self.assertTrue(f.state.raw[i].unbound)
        self.assertEqual(set(f.state.rows.keys()),set(f.module.ids.values()))
        self.assertEqual(len(list(f.state.rows.keys())),4)
        self.assertTrue(event(f,0).save.ready)

    def test_new_action_gets_defaults_despite_empty_dormant_overrides_saved_before_install(self):
        f=self.new()
        f.lua.execute('''
            state.assignments="other.mod\\t10\\t12\\n"
            state.config={CinematicCamera={Action1={},Action4={},Action6={}}}
            state.menu.register_binding=function(id,label,slot,options)
                state.rows[id]={label=label,category=options.category}
                local codes={save=0,cycle=2,hud=3,reset=4}
                for name,value in pairs(module.ids) do
                    if value==id then state.assignments=state.assignments..id.."\\t10\\t"..codes[name].."\\n" end
                end
                return true
            end
        ''')
        f.poll()
        self.assertEqual(f.state.published,2)
        self.assertEqual(f.state.raw[1].mappings[1].button_id,80)
        self.assertEqual(f.state.raw[4].mappings[1].button_id,72)

    def test_inherited_bindings_and_no_write_preflight_do_not_consume_first_install(self):
        f=self.new();f.state.inherited=True
        f.lua.globals().set_native(1,'J');f.poll()
        self.assertIsNone(f.state.published);self.assertEqual(f.state.mark_count,0)
        f.state.inherited=False;f.lua.globals().set_native(1,None)
        f.state.preflight_error='context changed before any write';f.poll(.1)
        self.assertIsNone(f.state.published);self.assertFalse(f.state.markers.save)
        f.state.preflight_error=None;f.poll(.2)
        self.assertEqual(f.state.published,2);self.assertTrue(f.state.markers.save)

    def test_initialization_waits_for_valid_gameplay_and_revalidates_before_write(self):
        f=self.new();f.state.allowed=False;f.poll();self.assertIsNone(f.state.published)
        self.assertEqual(f.state.mark_count,0)
        f.state.allowed=True;f.poll(.1);self.assertEqual(f.state.published,2)
        f=self.new();f.lua.execute('state.checks=0;state.context.gameplay_allowed=function() state.checks=state.checks+1;return state.checks==1 end')
        f.poll();self.assertIsNone(f.state.published)

    def test_explicit_saved_unbound_or_custom_binding_wins_on_initialization(self):
        f=self.new();f.state.config=f.lua.eval('{CinematicCamera={Action1={},Action6={},Action7={},Action8={}}}')
        f.lua.globals().set_native(4,'J',3,.4);f.poll()
        self.assertIsNone(f.state.published)
        self.assertTrue(f.state.raw[1].unbound)
        self.assertEqual(f.state.raw[4].mappings[1].button_id,74)

    def test_manual_unbind_not_seeded_again_after_restart(self):
        f=self.new();f.poll();f.lua.globals().set_native(1,None)
        f.obj=f.module.new(f.state.options);f.poll(1)
        self.assertEqual(f.state.published,2);self.assertTrue(f.state.raw[1].unbound)

    def test_marker_failure_never_publishes_or_blocks_existing_controls(self):
        f=self.new();f.state.marker_error='disk full';f.poll();self.assertIsNone(f.state.published)
        f.lua.globals().set_native(1,'J');f.poll(.1);event(f,.1);f.signal('save',True)
        self.assertTrue(event(f,.116).save.pressed)

    def test_uncertain_default_write_is_not_replayed(self):
        f=self.new();f.state.publish_error='write uncertain';f.poll()
        self.assertIsNone(f.state.published);f.state.publish_error=None
        f.poll(2);self.assertIsNone(f.state.published)

    def test_explicit_reset_reloads_fixed_defaults_without_controls_file(self):
        f=fixture();f.poll();f.lua.globals().set_native(1,'J')
        f.lua.globals().set_native(5,'B');f.obj.queue_reset_defaults(f.obj);f.poll(.1)
        self.assertEqual(f.state.raw[1].mappings[1].button_id,80)
        self.assertTrue(f.state.raw[3].unbound);self.assertTrue(f.state.raw[5].unbound)

    def test_reset_clears_current_owned_ids_and_preserves_other_mods(self):
        f=fixture();f.state.assignments+='other.mod\t10\t12\n'
        f.lua.execute('''state.options.clear_bindings=function(codes,backup)
          assert(backup());state.cleared=codes;return {status="cleared",actions=#codes} end''')
        f.obj=f.module.new(f.state.options)
        result=f.obj.reset(f.obj,f.lua.eval('function()return true end'))
        self.assertEqual(result.actions,4)
        self.assertEqual(set(f.state.cleared.values()),{10*65536+i for i in (0,2,3,4)})


class InputIntegrationTests(unittest.TestCase):

    def test_f10_requires_fresh_press_in_property_help_and_native_commands_win(self):
        f=self.fixture();f.ipoll(0)
        ctx=dict(help_instance='weapon-A',help_open=True,preset_help_open=False,hud_enabled=True)
        f.input.keys={82,121}
        self.assertFalse(f.ipoll(.01,help_instance='weapon-A').hud_display_pressed)
        self.assertFalse(f.ipoll(.02,**ctx).hud_display_pressed)
        f.input.keys={82};f.ipoll(.03,**ctx)
        f.input.keys={82,121};self.assertTrue(f.ipoll(.04,**ctx).hud_display_pressed)
        self.assertFalse(f.ipoll(.05,**ctx).hud_display_pressed)
        for index,change in enumerate(({'preset_help_open':True},{'help_instance':'weapon-B'},{'hud_enabled':False})):
            switched={**ctx,**change}
            f.input.keys={82};f.ipoll(.06+index*.02,**ctx)
            f.input.keys={82,121};self.assertFalse(f.ipoll(.07+index*.02,**switched).hud_display_pressed)
        f.input.keys={121};self.assertFalse(f.ipoll(.12,**ctx).hud_display_pressed)
        f.input.keys={82};f.ipoll(.13,**ctx)
        f.input.keys={82,121}
        self.assertFalse(f.input.poll(.14,foreground=False,controls=ctx).hud_display_pressed)
        self.assertFalse(f.ipoll(.15,**ctx).hud_display_pressed)
        f.input.keys={82};f.ipoll(.16,**ctx)
        f.input.keys={82,121};f.signal('cycle',True)
        result=f.ipoll(.17,**ctx)
        self.assertTrue(result.cycle_pressed);self.assertFalse(result.hud_display_pressed)
        self.assertIsNone(f.state.published)


    def fixture(self):
        f=fixture(integrated=True)
        f.lua.execute('native_reader={verify=function()return true end};gate={allowed=true}')
        opts=f.lua.table_from(dict(adapter=f.input.adapter,mod_bindings=f.module,
            native_reader=f.lua.globals().native_reader,input_context=f.lua.eval('function()return gate end'),
            get_menu=f.state.options.get_menu,get_loader=f.state.options.get_loader,get_engine=f.state.options.get_engine,
            editor_open=f.state.options.editor_open,read_menu_binding=f.state.options.read_binding,
            watch_menu_binding=f.state.options.watch_binding,read_menu_event=f.state.options.read_event,
            replace_menu_binding=f.state.options.replace_binding))
        f.input.files['X:/Logs/ModBindingsMenu.assignments']=f.state.assignments
        f.input.module=f.lua.globals().RequiredInput;f.input.obj=f.input.module.new(opts)
        self.assertTrue(f.input.obj.ensure_menu_state(f.input.obj,0))
        return f

    def test_fixed_keys_need_visible_help_fresh_press_and_card(self):
        f=self.fixture();f.ipoll(0)
        ctx=dict(help_instance='weapon-A',help_open=True,preset_help_open=True)
        f.input.keys={82,67,120};f.ipoll(.01,help_instance='weapon-A')
        result=f.ipoll(.02,**ctx)
        self.assertFalse(result.locale_pressed);self.assertFalse(result.export_pressed)
        f.input.keys={82};f.ipoll(.03,**ctx)
        f.input.keys={82,120};self.assertTrue(f.ipoll(.04,**ctx).locale_pressed)
        self.assertFalse(f.ipoll(.05,**ctx).locale_pressed)
        f.input.keys={82};f.ipoll(.06,**ctx)
        f.input.keys={82,67};self.assertTrue(f.ipoll(.07,**ctx).export_pressed)
        f.input.keys={82};f.ipoll(.08,**ctx)
        f.input.keys={82,86};self.assertTrue(f.ipoll(.09,**ctx).import_pressed)
        property_ctx=dict(help_instance='weapon-A',help_open=True,preset_help_open=False)
        f.input.keys={82};f.ipoll(.1,**property_ctx)
        f.input.keys={82,67,86,120};result=f.ipoll(.11,**property_ctx)
        self.assertTrue(result.locale_pressed)
        self.assertFalse(result.export_pressed);self.assertFalse(result.import_pressed)
        f.input.keys={82};f.ipoll(.12,**ctx)
        f.input.keys={67,120};result=f.ipoll(.13,**ctx)
        self.assertFalse(result.locale_pressed);self.assertFalse(result.export_pressed)
        f.state.missing=True;f.input.keys={82};f.ipoll(.14,**ctx)
        f.input.keys={82,120};self.assertFalse(f.ipoll(.15,**ctx).locale_pressed)

    def test_pressed_button_display_is_visible_scoped_read_only_and_cleared_on_loss(self):
        f=self.fixture();f.ipoll(0)
        self.assertEqual(f.input.diagnostic_reads,0)
        ctx=dict(help_instance='weapon-A',help_open=True,preset_help_open=True)
        f.input.keys={82,80};self.assertIsNone(f.ipoll(.01,**ctx).last_pressed_label)
        f.input.keys={82};f.ipoll(.02,**ctx)
        for index,(vk,label) in enumerate(((87,'W'),(120,'F9'),(6,'Mouse5'),(38,'Up'))):
            t=.1+index*.1;f.input.keys={82,vk};result=f.ipoll(t,**ctx)
            self.assertEqual(result.last_pressed_label,label)
            self.assertTrue(result.last_pressed_changed)
            self.assertFalse(result.cycle_pressed);self.assertFalse(result.reset_pressed)
            f.input.keys={82};result=f.ipoll(t+.01,**ctx)
            self.assertEqual(result.last_pressed_label,label)
            self.assertFalse(result.last_pressed_changed)
        self.assertNotIn(87,f.input.key_reads,'display must not add async polling of arbitrary keys')
        f.input.keys={82,16,160};self.assertEqual(f.ipoll(.6,**ctx).last_pressed_label,'LShift')
        f.input.keys={82};self.assertIsNone(f.ipoll(.7,help_instance='weapon-B',help_open=True,preset_help_open=True).last_pressed_label)
        self.assertIsNone(f.ipoll(.8,help_instance='weapon-B',help_open=True,preset_help_open=False).last_pressed_label)
        f.input.diagnostic_failure='incomplete';self.assertIsNone(f.ipoll(.9,**ctx).last_pressed_label)
        f.input.diagnostic_failure=None;f.input.keys={82};f.ipoll(1,**ctx)
        f.input.keys={82,87};self.assertEqual(f.ipoll(1.01,**ctx).last_pressed_label,'W')
        f.input.keys={87};self.assertIsNone(f.ipoll(1.1,**ctx).last_pressed_label)
        self.assertIsNone(f.input.poll(1.2,foreground=False,controls=ctx).last_pressed_label)

    def test_opening_menu_tap_then_second_tap_clears_once(self):
        f=self.fixture();f.ipoll(0);f.input.keys={82};f.ipoll(.01,help_instance='weapon-A')
        f.input.keys={82,80};f.signal('save',True)
        first=f.ipoll(.02,help_instance='weapon-A')
        self.assertTrue(first.pressed);self.assertFalse(first.clear_pressed)
        ctx=dict(help_instance='weapon-A',help_open=True,preset_help_open=True)
        f.signal('save',False);f.input.keys={82};f.ipoll(.04,**ctx)
        f.input.keys={82,80};f.signal('save',True)
        result=f.ipoll(.12,**ctx)
        self.assertTrue(result.clear_pressed);self.assertEqual(result.clear_label,'P')
        self.assertFalse(f.ipoll(.13,**ctx).clear_pressed)

    def test_clear_uses_remapped_menu_key_and_save_consumes_double_tap(self):
        f=self.fixture();f.lua.globals().set_native(1,'F8',2,.3)
        ctx=dict(help_instance='weapon-A',help_open=True,preset_help_open=True)
        f.ipoll(0);f.input.keys={82};f.ipoll(.01,**ctx)
        f.input.keys={82,119};self.assertFalse(f.ipoll(.04,**ctx).clear_pressed)
        f.input.keys={82};f.ipoll(.06,**ctx)
        f.input.obj.consume_clear(f.input.obj)
        f.input.keys={82,119};self.assertFalse(f.ipoll(.1,**ctx).clear_pressed)
        f.input.keys={82};f.ipoll(.12,**ctx)
        f.input.keys={82,119};self.assertTrue(f.ipoll(.18,**ctx).clear_pressed)
        f.input.keys={82};f.ipoll(.2,**ctx)
        f.input.keys={82,119};f.ipoll(.23,**ctx)
        f.input.keys={82};f.ipoll(.24,help_instance='weapon-B',help_open=True,preset_help_open=True)
        f.input.keys={82,119}
        self.assertFalse(f.ipoll(.26,help_instance='weapon-B',help_open=True,preset_help_open=True).clear_pressed)

    def test_language_in_hud_only_and_unknown_menu_devices_keep_native_events(self):
        f=self.fixture();f.lua.globals().set_native(1,None)
        ctx=dict(help_instance='weapon-A',help_open=True,preset_help_open=False,presets_enabled=False)
        f.ipoll(0);f.input.keys={82};f.ipoll(.01,**ctx)
        f.input.keys={82,120};self.assertTrue(f.ipoll(.04,**ctx).locale_pressed)
        f=self.fixture();native_button(f,1,7,device=1)
        ctx=dict(help_instance='weapon-A',help_open=True,preset_help_open=True)
        f.ipoll(0);f.input.keys={82};f.ipoll(.01,**ctx)
        f.signal('save',True);self.assertFalse(f.ipoll(.04,**ctx).clear_pressed)
        f.signal('save',False);f.ipoll(.06,**ctx)
        f.signal('save',True);self.assertTrue(f.ipoll(.15,**ctx).clear_pressed)

    def test_native_cycle_first_start_without_mods_or_binding_file(self):
        f=self.fixture();before=dict(f.input.files);f.ipoll(0);f.ipoll(.01)
        f.signal('cycle',True);self.assertTrue(f.ipoll(.026).cycle_pressed)
        self.assertEqual(dict(f.input.files),before);self.assertIsNone(f.state.published)

    def test_all_commands_accept_numbers_arrows_oem_mouse_axes_controller_and_chords(self):
        cases=[
            (3,49,4,255,0),(3,50,4,255,0),(3,51,4,255,0),(3,38,4,255,0),
            (3,254,4,255,0),(3,700,4,2,0),(4,15,4,255,0),(4,1,1,255,0),
            (1,7,4,0,0),(3,162,4,255,1),
        ]
        for name,index,field in [('save',1,'pressed'),('cycle',3,'cycle_pressed'),
                                 ('hud',4,'hud_select_pressed'),('reset',5,'reset_pressed')]:
            for device,button,kind,devindex,combine in cases:
                with self.subTest(action=name,device=device,button=button,kind=kind,combine=combine):
                    f=self.fixture()
                    for i in (1,3,4,5):f.lua.globals().set_native(i,None)
                    rows=[dict(simple_button=False,device=device,button_id=button,input_kind=kind,
                               device_index=devindex,combine=combine,trigger=0,threshold_bits=0)]
                    if combine:rows.append(dict(simple_button=False,device=3,button_id=193,
                                               input_kind=4,device_index=255,combine=0,trigger=0,threshold_bits=0))
                    f.state.raw[index]=f.lua.table_from(dict(count=len(rows),unbound=False,
                        signature='arbitrary-native',mappings=f.lua.table_from([f.lua.table_from(r) for r in rows])))
                    f.ipoll(0);f.input.keys={82};f.ipoll(.01)
                    if device==3 and button<256:f.input.keys={82,button}
                    f.signal(name,True);result=f.ipoll(.026)
                    self.assertTrue(result[field],result.reason)
                    self.assertIsNone(result.preset_pressed)
                    self.assertIsNone(f.state.published)

    def test_swap_can_use_the_card_key_and_is_not_blocked_while_card_is_held(self):
        f=self.fixture();f.lua.globals().set_native(3,'R');f.ipoll(0);f.ipoll(.01)
        f.input.keys={82};f.signal('cycle',True)
        self.assertTrue(f.ipoll(.026).cycle_pressed)
        self.assertIsNone(f.state.published)

    def test_number_with_a_delayed_menu_trigger_does_not_save_before_its_event(self):
        f=self.fixture();f.lua.globals().set_native(1,'1',1,0)
        f.ipoll(0);f.input.keys={82};f.ipoll(.01)
        f.input.keys={82,49};result=f.ipoll(.026)
        self.assertIsNone(result.preset_pressed);self.assertFalse(result.pressed)
        f.input.keys={82};f.signal('save',True)
        result=f.ipoll(.042)
        self.assertTrue(result.pressed);self.assertIsNone(result.preset_pressed)

    def test_all_commands_survive_unknown_or_failed_button_caption_providers(self):
        for mode in ('unknown_names', 'name_api_error', 'engine_api_missing', 'invalid_caption'):
            with self.subTest(mode=mode):
                f=self.fixture()
                for index,button in ((1,193),(3,194),(4,195),(5,196)):
                    native_button(f,index,button)
                if mode=='unknown_names':
                    f.lua.execute('state.engine.Keyboard.button_name=function(id)return "unknown/key+"..id end')
                elif mode=='name_api_error':
                    f.lua.execute('state.engine.Keyboard.button_name=function()error("caption unavailable")end')
                elif mode=='engine_api_missing':
                    f.lua.execute('state.engine=nil')
                else:
                    f.lua.execute(r'state.engine.Keyboard.button_name=function()return "\193" end')
                before=dict(f.input.files);f.ipoll(0);f.ipoll(.01)
                f.input.keys={194};result=f.ipoll(.018)
                self.assertTrue(result.cycle_ready);self.assertFalse(result.cycle_pressed)
                for action in ('cycle','reset'):f.signal(action,True)
                result=f.ipoll(.026)
                self.assertTrue(result.cycle_pressed);self.assertTrue(result.reset_pressed)
                for action in ('cycle','reset'):f.signal(action,False)
                f.input.keys={82};f.ipoll(.034)
                for action in ('save','hud'):f.signal(action,True)
                result=f.ipoll(.042)
                self.assertTrue(result.pressed);self.assertTrue(result.hud_select_pressed)
                self.assertTrue(result.cycle_label)
                self.assertEqual(dict(f.input.files),before);self.assertIsNone(f.state.published)

    def test_destructive_conflicts_use_native_identity_without_button_captions(self):
        f=self.fixture()
        f.lua.execute('state.engine.Keyboard.button_name=function()error("caption unavailable")end')
        native_button(f,1,193);native_button(f,5,193)
        f.ipoll(0);f.input.keys={82};f.ipoll(.01);f.signal('reset',True)
        result=f.ipoll(.026)
        self.assertFalse(result.reset_pressed);self.assertIn('overlaps',result.reset_reason)
        self.assertFalse(result.clear_ready)
        f=self.fixture()
        f.lua.execute('state.engine.Keyboard.button_name=function()return "same caption" end')
        native_button(f,3,193);native_button(f,5,194)
        f.ipoll(0);f.ipoll(.01);f.signal('reset',True)
        result=f.ipoll(.026)
        self.assertTrue(result.reset_pressed);self.assertIsNone(result.reset_reason)

    def test_tilde_names_accept_native_swap_without_physical_trigger_fallback(self):
        for name in ('tilde', 'grave', 'backtick', 'oem_3', '`', '~'):
            with self.subTest(name=name):
                f=self.fixture()
                f.state.tilde_name=name
                f.lua.execute('''local previous=state.engine.Keyboard.button_name
                  state.engine.Keyboard.button_name=function(id)
                    if id==192 then return state.tilde_name end;return previous(id) end''')
                f.state.raw[3]=f.lua.table_from(dict(count=1,unbound=False,signature=name+'-press',
                    mappings=f.lua.table_from([f.lua.table_from(dict(simple_button=True,
                        device=3,button_id=192,trigger=0,threshold_bits=0,combine=0))])))
                before=dict(f.input.files);f.ipoll(0);f.ipoll(.01)
                f.input.keys={192};result=f.ipoll(.018)
                self.assertTrue(result.cycle_ready);self.assertFalse(result.cycle_pressed)
                self.assertEqual(result.cycle_label,'Tilde')
                f.signal('cycle',True);result=f.ipoll(.026)
                self.assertTrue(result.cycle_pressed);self.assertIsNone(result.cycle_reason)
                self.assertEqual(dict(f.input.files),before);self.assertIsNone(f.state.published)

    def test_swap_accepts_game_event_on_buttons_shared_with_game_controls(self):
        for key, vk, button_id, device, game_action, game_input in (
            ('Mouse4', 5, 3, 4, 'WeaponFunctionRight', 'MouseButton4'),
            ('Mouse5', 6, 4, 4, 'WeaponFunctionLeft', 'MouseButton5'),
            ('F', 70, 70, 3, 'WeaponFire', 'f'),
        ):
            with self.subTest(key=key):
                f=self.fixture();p=f.input.obj.input_path
                device_name='Mouse' if device==4 else 'Keyboard'
                f.input.files[p]=f.input.files[p].replace('Avatar = {',
                    'Avatar = { '+game_action+' = [{ device_type="'+device_name+
                    '" input_type="Button" input="'+game_input+'" trigger="Press" }] ')
                f.lua.execute('''state.engine.Mouse.button_name=function(id)
                  return ({[3]="extra_1",[4]="extra_2"})[id] end''')
                f.state.raw[3]=f.lua.table_from(dict(count=1,unbound=False,signature=key+'-press',
                    mappings=f.lua.table_from([f.lua.table_from(dict(simple_button=True,
                        device=device,button_id=button_id,trigger=0,threshold_bits=0,combine=0))])))
                before=dict(f.input.files);f.ipoll(0);f.ipoll(.01)
                f.input.keys={vk};result=f.ipoll(.018)
                self.assertTrue(result.cycle_ready);self.assertFalse(result.cycle_pressed)
                f.signal('cycle',True);result=f.ipoll(.026)
                self.assertTrue(result.cycle_pressed);self.assertIsNone(result.cycle_reason)
                self.assertEqual(dict(f.input.files),before);self.assertIsNone(f.state.published)





    def test_remapped_card_key_comes_from_game_config(self):
        f=self.fixture();p=f.input.obj.input_path
        f.input.files[p]=f.input.files[p].replace('input="r"','input="t"').replace('fixed_layout_id=19','fixed_layout_id=20')
        f.ipoll(2);f.input.keys={84};f.ipoll(2.01);f.signal('save',True)
        result=f.ipoll(2.026);self.assertTrue(result.pressed);self.assertEqual(result.card_label,'T')

    def test_gameplay_settings_errors_remain_fail_closed(self):
        f=self.fixture();f.ipoll(0);f.input.files[f.input.obj.input_path]='invalid input config'
        f.input.keys={82};f.signal('save',True);result=f.ipoll(3)
        self.assertFalse(result.pressed);self.assertFalse(result.held_reload)


class PublicationOwnershipTests(unittest.TestCase):
    def publication_fixture(self):
        f=MenuFixture()
        f.lua.execute('''
state.options.native_reader={}
state.options.profile_id="76561198000000001"
state.snapshot={path="X:/Steam/input_settings.config",raw="original",profile_id=state.options.profile_id}
state.current_raw="original";state.snapshot_reads=0;state.validations={}
state.options.get_input_snapshot=function(config)
 state.snapshot_reads=state.snapshot_reads+1
 if state.snapshot_error then return nil,state.snapshot_error end
 return {path=state.snapshot.path,raw=state.current_raw,profile_id=state.snapshot.profile_id}
end
state.options.validate_input_snapshot=function(snapshot)
 state.validations[#state.validations+1]="validate"
 if state.validation_error then return nil,state.validation_error end
 if snapshot.path~=state.snapshot.path or snapshot.profile_id~=state.snapshot.profile_id then return nil,"identity changed" end
 if snapshot.raw~=state.current_raw then return nil,"preimage changed" end
 return true
end
state.options.scoped_input={prepare=function()error("game input writer must never be called")end}
NativeModBindingDefaults={new=function(options)
 assert(options.prepare_persistence==nil)
 state.prepare_publication=options.prepare_publication
 return {ensure=function()return nil,"unused" end,clear_many=function()return nil,"unused" end}
end}
function changes(code)
 return {{code=code or 655360,section="CinematicCamera",action="Fixture",key="p"}}
end
''')
        f.obj=f.module.new(f.state.options)
        return f

    def test_native_publication_rechecks_own_sidecar_without_file_commit(self):
        f=self.publication_fixture()
        plan=f.state.prepare_publication(f.lua.globals().changes())
        self.assertEqual(f.state.snapshot_reads,1)
        self.assertIsNone(plan.commit);self.assertIsNone(plan.rollback)
        self.assertTrue(plan.validate())
        # Same numeric code is transferred to another mod after prepare.
        f.state.assignments=f.state.assignments.replace(f.module.ids.save+'\t10\t0','other.mod\t10\t0')
        result=plan.validate()
        self.assertIsNone(result[0]);self.assertIn('ownership changed',result[1])
        self.assertEqual(list(f.state.validations.values()),['validate']*3)

    def test_native_publication_rejects_unowned_duplicate_and_sparse_codes(self):
        f=self.publication_fixture();f.state.assignments+='other.mod\t10\t9\n'
        for source in ('changes(655369)', '{changes()[1],changes()[1]}',
                       '{[1]=changes()[1],[3]=changes(655361)[1]}'):
            with self.subTest(source=source):
                result=f.state.prepare_publication(f.lua.eval(source))
                self.assertIsNone(result[0])
        self.assertEqual(f.state.snapshot_reads,0)

    def test_native_publication_fresh_profile_failure_prevents_prepare(self):
        f=self.publication_fixture();f.state.snapshot_error='active Steam account changed'
        result=f.state.prepare_publication(f.lua.globals().changes())
        self.assertIsNone(result[0]);self.assertIn('account changed',result[1])
        self.assertIsNone(f.state.prepared)

    def test_native_publication_revalidates_unchanged_file_and_ownership(self):
        f=self.publication_fixture();plan=f.state.prepare_publication(f.lua.globals().changes())
        self.assertTrue(plan.validate())
        f.state.current_raw='external edit'
        result=plan.validate();self.assertIsNone(result[0]);self.assertIn('preimage',result[1])
        f.state.current_raw='original'
        f.state.assignments=f.state.assignments.replace(f.module.ids.save+'\t10\t0','other.mod\t10\t0')
        result=plan.validate();self.assertIsNone(result[0]);self.assertIn('ownership',result[1])


if __name__=='__main__':unittest.main()

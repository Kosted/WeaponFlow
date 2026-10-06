"""Read-only native icon mapping and asset checks, not live HUD rendering."""
from pathlib import Path
import struct
import unittest
from test_native_programmable_ammo import Fixture

ROOT=Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'src/native_weapon_hud_icons.lua').read_bytes()

class HudFixture(Fixture):
    def __init__(self, *, slot=0, choices=(117,243), override=True, functions=(8,0,0,0), firemode=0):
        super().__init__(slot=slot, choices=choices, override=override, functions=functions)
        self.module=self.lua.execute(SOURCE)
        for _,anchor in self.module.anchors.items():
            address=self.game+anchor.rva
            if len(self.memory.get(address,b''))<len(anchor.bytes):
                self.memory[address]=anchor.bytes
        self.write(self.state,'<I',firemode)
        self.modes=self.lua.table_from({b'weapon_bytes':self.entity_bytes,
            b'functions':self.lua.table_from(dict(zip((b'left',b'right',b'up',b'down'),functions))),
            b'directions':self.lua.table()})
        for i,side in enumerate((b'left',b'right',b'up',b'down')):
            action=functions[i]
            self.modes.directions[side]=self.lua.table_from({b'present':bool(action),b'readable':bool(action),
                b'slot':slot if action==8 else 1,b'current':choices[slot] if action==8 and slot<2 else firemode})
        self.icon_record=0x2C000000
        self.icon_hash=0x9DCC0312A14E11E6
        for enum in choices:
            if enum:
                self.write(self.game+0x37C7670+enum*8,'<Q',self.icon_record)
        self.write(self.icon_record+0x10,'<Q',self.icon_hash)
        self.write(self.game+0x37C7560+0x10,'<Q',self.icon_hash)
    def inspect(self,selected=None,helpers=None):
        v=self.module.inspect(self.reader,self.snapshot,self.modes,helpers,selected)
        return v if isinstance(v,tuple) else (v,None)
    def helper(self,name,**fields):
        result=self.lua.table_from({k.encode():v for k,v in fields.items()})
        result.weapon_bytes=self.entity_bytes
        module=self.lua.eval(b'function(v) return {inspect=function() return v end} end')(result)
        return self.lua.table_from({name.encode():module}),result

class NativeHudIconTests(unittest.TestCase):
    def test_current_projectile_routes_to_native_icon_without_weapon_catalog(self):
        for slot in (0,1):
            f=HudFixture(slot=slot)
            value,why=f.inspect()
            self.assertIsNone(why)
            self.assertEqual(value.directions.left.hash_hex,b'9dcc0312a14e11e6')
            self.assertEqual(value.directions.left.current,(117,243)[slot])
    def label_helper(self,f):
        for _,anchor in f.module.label_anchors.items():
            f.memory[f.game+anchor.rva]=anchor.bytes
        return f.lua.eval(b'function() return {labels={get=function(id) return ({[17]="APHET",[18]="FLAK"})[id] end}} end')()
    def test_value_changed_after_mode_capture_is_not_displayed(self):
        f=HudFixture(); f.write(f.definition,'<I',10)
        d=f.inspect()[0].directions.left
        self.assertIsNone(d.hash_hex); self.assertIn(b'value changed',d.reason)
    def test_missing_or_zero_icon_is_unknown_not_default(self):
        f=HudFixture(); f.write(f.icon_record+0x10,'<Q',0)
        self.assertIsNone(f.inspect()[0].directions.left.hash_hex)
        del f.memory[f.icon_record+0x10]
        self.assertIsNone(f.inspect()[0].directions.left.hash_hex)
    def test_safety_only_is_not_generic_single_or_burst(self):
        for mode,expected in ((2,None),(3,None),(5,b'safe'),(6,b'unsafe')):
            f=HudFixture(functions=(3,0,0,0),firemode=mode)
            d=f.inspect()[0].directions.left
            self.assertEqual(d.kind if d else None,expected)
    def test_selected_missing_direction_does_not_substitute_another(self):
        f=HudFixture()
        value,_=f.inspect(b'up')
        self.assertEqual(len(list(value.directions.items())),0)
    def test_zeroing_uses_revalidated_value_and_native_slot(self):
        f=HudFixture(functions=(0,0,1,0))
        direction=f.modes.directions.up
        direction.kind=b'zeroing';direction.current=75
        helpers,result=f.helper('weapon_modes',directions=f.lua.table_from({b'up':direction}),functions=f.modes.functions)
        d=f.inspect(b'up',helpers)[0].directions.up
        self.assertEqual(d.kind,b'zeroing');self.assertEqual(d.current,75)
        self.assertEqual(d.hash_hex,b'46271d0b4ce4136c')
        other=f.lua.table_from({b'present':True,b'readable':True,b'kind':b'zeroing',b'current':150,b'slot':2})
        result.directions=f.lua.table_from({b'up':other})
        self.assertIsNone(f.inspect(b'up',helpers)[0].directions.up.hash_hex)

class NativeSecondaryFireIconTests(unittest.TestCase):
    """Presentation consumes a fresh validated kind-11 reader, not ammo enums."""
    def fixture(self, current=0):
        f=HudFixture(functions=(11,0,0,0))
        direction=f.modes.directions.left
        direction.kind=b'secondary_fire';direction.current=current;direction.slot=current
        helpers,result=f.helper('secondary_fire',present=True,readable=True,current=current,
            slot=current,functions=f.modes.functions,
            icon_hashes=f.lua.table_from({0:b'3efff09cd12fb89a',1:b'131742904d846798'}),
            label_keys=f.lua.table_from({0:777,1:778}))
        helpers.labels=f.lua.eval(b'''{get=function(id)
            label_calls=(label_calls or 0)+1
            return ({[777]='Primary fire',[778]='Flamethrower'})[id]
        end}''')
        return f,helpers,result

    def test_explicit_kind11_uses_current_secondary_reader_icon_and_localization_key(self):
        for current,icon,label in ((0,b'3efff09cd12fb89a',b'Primary fire'),
                                   (1,b'131742904d846798',b'Flamethrower')):
            with self.subTest(current=current):
                f,helpers,_=self.fixture(current)
                before=dict(f.memory)
                value,why=f.inspect(b'left',helpers)
                self.assertIsNone(why)
                direction=value.directions.left
                self.assertEqual((direction.kind,direction.current,direction.slot),
                                 (b'secondary_fire',current,current))
                self.assertEqual((direction.hash_hex,direction.label),(icon,label))
                self.assertEqual(f.lua.globals().label_calls,1)
                self.assertEqual(f.memory,before)

    def test_secondary_reader_mismatches_reject_icon_and_label_before_localization(self):
        for fault in ('absent','unreadable','value','slot','identity','functions','missing_helper'):
            with self.subTest(fault=fault):
                f,helpers,result=self.fixture(1)
                if fault=='absent': result.present=False
                elif fault=='unreadable': result.readable=False
                elif fault=='value': result.current=0
                elif fault=='slot': result.slot=0
                elif fault=='identity': result.weapon_bytes=b'X'*24
                elif fault=='functions':
                    result.functions=f.lua.table_from({b'left':11,b'right':2,b'up':0,b'down':0})
                else: helpers.secondary_fire=None
                direction=f.inspect(b'left',helpers)[0].directions.left
                self.assertIsNone(direction.hash_hex)
                self.assertIsNone(direction.label)
                self.assertIsNotNone(direction.reason)
                self.assertIsNone(f.lua.globals().label_calls)


class NativeAmmoLabelTests(unittest.TestCase):
    def fixture(self, **options):
        f = HudFixture(**options)
        choices = options.get('choices', (117, 243))
        for _, anchor in f.module.label_anchors.items():
            f.memory[f.game + anchor.rva] = anchor.bytes
        for index, enum in enumerate(choices):
            address = f.game + 0x37C7560 if enum == 0 else f.icon_record + index * 0x1000
            if enum:
                f.write(f.game + 0x37C7670 + enum * 8, '<Q', address)
            f.write(address + 0x0C, '<I', 17 + index)
        for side, direction in f.modes.directions.items():
            if f.modes.functions[side] == 8:
                direction.kind = b'programmable_ammo'
                direction.choices = f.lua.table_from(choices)
        f.labels = f.lua.eval(b'''function()
            return {calls=0,get=function(id)
                label_calls=(label_calls or 0)+1
                if on_label then on_label(id) end
                return ({[17]='APHET',[18]='FLAK'})[id]
            end}
        end''')()
        return f

    def labels(self, f):
        result = f.module.ammo_labels(f.reader, f.snapshot, f.modes, f.labels)
        return result if isinstance(result, tuple) else (result, None)

    def test_both_offered_labels_are_returned_independent_of_selected_slot_and_without_mutation(self):
        for slot in (0, 1):
            f = self.fixture(slot=slot)
            before = {address: bytes(data) for address, data in f.memory.items()}
            labels, why = self.labels(f)
            self.assertIsNone(why)
            self.assertEqual(dict(labels.items()), {117: b'APHET', 243: b'FLAK'})
            self.assertEqual(f.lua.globals().label_calls, 2)
            self.assertEqual(f.memory, before)
            self.assertEqual(f.modes.directions.left.current, (117, 243)[slot])
            self.assertEqual(f.modes.directions.left.choices[1], 117)


    def test_unreadable_second_record_or_failed_callback_does_not_publish_partial_map(self):
        for fault in ('pointer', 'id', 'callback'):
            f = self.fixture()
            if fault == 'pointer': del f.memory[f.game + 0x37C7670 + 243 * 8]
            elif fault == 'id': del f.memory[f.icon_record + 0x1000 + 0x0C]
            else: f.labels = f.lua.eval(b'{get=function() error("label failure") end}')
            labels, why = self.labels(f)
            self.assertIsNone(labels)
            self.assertIsNotNone(why)


class NativeChoiceIconTests(unittest.TestCase):
    """Saved-choice mapping uses actual native definitions, never saved slots."""
    def fixture(self, functions=(3,2,1,6), fire=(1,2,3), rpm=(700,850,1150), scope=(25,75,150), **options):
        f=HudFixture(functions=functions,firemode=fire[1],**options)
        f.fire_definition=0x2A000000
        f.rpm_address=0x2D000010
        f.write(f.fire_definition+0x90,'<III',*fire)
        f.write(f.fire_definition+0x154,'<fff',*scope)
        f.write(f.pm+0x70,'<Q',f.rpm_address-0x10)
        f.write(f.rpm_address,'<fffI',*rpm,1)
        f.write(f.pm+0x80,'<Q',0x2E000000)
        f.write(0x2E000004,'<f',rpm[1])
        # The real WeaponModes helper reads one 12-byte native state record.
        f.memory.pop(f.state+4)
        f.write(f.state,'<III',fire[1],(1<<12)|(1<<4),0)
        values={1:(b'zeroing',scope),2:(b'rpm',rpm),3:(b'firemode',fire),
                6:(b'laser_guide',(0,1)),8:(b'programmable_ammo',options.get('choices',(117,243))),
                11:(b'secondary_fire',(0,1))}
        for side,dir in f.modes.directions.items():
            action=f.modes.functions[side]
            dir.action_enum=action
            if action in values:
                kind,slots=values[action]
                dir.kind=kind
                dir.slot_values=f.lua.table_from(slots)
                dir.choices=f.lua.table_from([v for v in slots if v>0 or action in (6,8,11)])
        f.modes.weapon_eid=f.eid
        f.real_modes=f.lua.execute((ROOT/'src/native_weapon_modes.lua').read_bytes())
        f.helpers=f.lua.table_from({b'weapon_modes':f.real_modes})
        for index,enum in enumerate(options.get('choices',(117,243))):
            address=f.game+0x37C7560 if enum==0 else f.icon_record+index*0x1000
            if enum: f.write(f.game+0x37C7670+enum*8,'<Q',address)
            f.write(address+0x10,'<Q',0x9DCC0312A14E11E6+index)
        return f

    def icons(self,f):
        value=f.module.choice_icons(f.reader,f.snapshot,f.modes,f.helpers)
        return value if isinstance(value,tuple) else (value,None)

    def secondary(self,f,hashes=None):
        helpers,result=f.helper('secondary_fire',present=True,readable=True,kind=b'secondary_fire',
            action_enum=11,functions=f.modes.functions,
            choices=f.lua.table_from([0,1]),slot_values=f.lua.table_from([0,1]),
            icon_hashes=f.lua.table_from(hashes or {0:b'3efff09cd12fb89a',1:b'131742904d846798'}))
        f.helpers.secondary_fire=helpers.secondary_fire
        return result

    def test_all_offered_fire_rpm_zeroing_guidance_values_have_semantic_keys_and_native_slots(self):
        f=self.fixture()
        before={a:bytes(data) for a,data in f.memory.items()}
        # Saved/current cursor positions are deliberately irrelevant to this API.
        for _,dir in f.modes.directions.items(): dir.slot=99;dir.current=-1
        value,why=self.icons(f)
        self.assertIsNone(why)
        expected={b'left':[(1,0,b'6115051c9558c50e'),(2,1,b'3efff09cd12fb89a'),(3,2,b'131742904d846798')],
                  b'right':[(700,0,b'52bbfc5a70359393'),(850,1,b'c7546fc9c7b6db4e'),(1150,2,b'f03c671b15d01a6b')],
                  b'up':[(25,0,b'6be28cced767bb52'),(75,1,b'46271d0b4ce4136c'),(150,2,b'a2ab43e85546f79a')],
                  b'down':[(0,0,b'a9f9bf81827c51e5'),(1,1,b'c1028550c62fc4fa')]}
        for side,choices in expected.items():
            self.assertEqual(len(list(value[side].items())),len(choices))
            for number,slot,icon in choices:
                self.assertEqual((value[side][number].slot,value[side][number].hash_hex),(slot,icon))
                self.assertEqual(value[side][number].kind,f.modes.directions[side].kind)
        self.assertEqual(f.memory,before)

    def test_rpm_and_scope_use_current_module_native_order_not_numeric_sort_or_saved_slot(self):
        f=self.fixture(rpm=(1150,700,850),scope=(150,25,75))
        result,why=self.icons(f)
        self.assertIsNone(why)
        self.assertEqual((result.right[1150].slot,result.right[1150].hash_hex),(0,b'52bbfc5a70359393'))
        self.assertEqual((result.up[150].slot,result.up[150].hash_hex),(0,b'6be28cced767bb52'))
        f.write(f.fire_definition+0x154,'<fff',25,75,150)
        self.assertIn(b'native slots changed',self.icons(f)[1])


    def test_both_ammo_records_are_read_for_saved_choices_independently_of_selection(self):
        for override in (True,False):
            for choices in ((117,243),(0,350)):
                with self.subTest(override=override,choices=choices):
                    f=self.fixture(functions=(8,0,0,0),override=override,choices=choices)
                    f.write(f.state,'<III',0,3<<2,0)  # Selected slot is not used.
                    result,why=self.icons(f)
                    self.assertIsNone(why)
                    for index,enum in enumerate(choices):
                        self.assertEqual((result.left[enum].slot,result.left[enum].hash_hex),
                                         (index,f'{0x9DCC0312A14E11E6+index:016x}'.encode()))


    def wrap_modes(self,f,callback):
        f.lua.globals().on_saved_choices=callback
        f.helpers.weapon_modes=f.lua.eval(b'''function(native)
            return {inspect=function(...)
                saved_choice_calls=(saved_choice_calls or 0)+1
                if on_saved_choices then on_saved_choices(saved_choice_calls) end
                return native.inspect(...)
            end}
        end''')(f.real_modes)

    def test_helper_is_repeated_and_changed_current_module_slots_reject_the_map(self):
        f=self.fixture()
        self.wrap_modes(f,lambda _: None)
        self.assertIsNotNone(self.icons(f)[0])
        self.assertEqual(f.lua.globals().saved_choice_calls,2)
        f=self.fixture()
        self.wrap_modes(f,lambda call: f.write(f.fire_definition+0x154,'<fff',50,100,200) if call==2 else None)
        self.assertIn(b'native slots changed',self.icons(f)[1])


if __name__=='__main__': unittest.main()

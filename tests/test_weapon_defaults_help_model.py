"""Content semantics for player-facing contextual text; no native APIs."""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime
from text_fixtures import load_text

ROOT = Path(__file__).resolve().parents[1]

def array_values(table):
    return [table[index] for index in range(1,len(table)+1)]


class HelpModelTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        load_text(self.lua)
        self.model = self.lua.execute((ROOT/'src/weapon_defaults_help_model.lua').read_text())
        self.modes = self.lua.eval('''{directions={
            left={present=true,readable=true,kind='programmable_ammo',current=325,choices={101,325}},
            right={present=true,readable=true,kind='rpm',current=1150,choices={700,850,1150}},
            up={present=true,readable=true,kind='zeroing',current=150,choices={25,75,150}},
            down={present=true,readable=true,kind='flashlight',action_enum=5,current=0,choices={0,1,2}}}}''')
        self.ammo = self.lua.table_from({101: 'Armor piercing', 325: 'Flak'})
        self.controls = self.lua.table_from({'card_label':'Mouse5','save_label':'F8',
            'clear_label':'F8','clear_trigger':'DoubleTap','hud_label':'N','cycle_label':'Slash','cycle_trigger':'Press'})

    def lines(self, selected):
        return array_values(self.model.property(self.modes,self.ammo,selected,self.controls))

    def highlighted(self, lines):
        return {index: [lines[index][span[1]-1:span[2]] for span in array_values(ranges)]
                for index,ranges in lines.highlights.items()}

    def test_property_uses_values_not_direction_names(self):
        lines = self.lines('left')
        self.assertEqual(lines[0:2], ['CURRENT PROPERTY: FLAK', 'OTHER AVAILABLE PROPERTIES: 1150 RPM, 150 M, HIDE'])
        self.assertEqual(lines[2], 'DISPLAY: ICON / TEXT / ICON AND TEXT')
        self.assertEqual(lines[3], 'CHANGE DISPLAY: F10')
        self.assertEqual(lines[4], 'CHANGE PROPERTIES: HOLD MOUSE5 + PRESS N')
        self.assertNotIn('CURRENT PROPERTY: AUTO',' '.join(lines))

    def test_current_property_uses_actual_native_icon_and_keeps_numeric_captions(self):
        cases=[('programmable_ammo',325,'programmable_ammo',None),('firemode',5,'safe',None),
               ('firemode',6,'unsafe',None),('firemode',3,'firemode',None),
               ('rpm',1150,'rpm','1150'),('zeroing',150,'zeroing','150 M'),
               ('laser_guide',1,'laser_guide',None),('binary_10',0,'binary_10',None),
               ('secondary_fire',1,'secondary_fire',None)]
        self.ammo.secondary_fire=self.lua.table_from({1:'Flamethrower'})
        for kind,value,native_kind,caption in cases:
            with self.subTest(kind=kind,value=value):
                self.modes.directions.left=self.lua.table_from(dict(
                    present=True,readable=True,kind=kind,current=value))
                native=self.lua.table_from({'directions':{'left':dict(
                    kind=native_kind,current=value,hash_hex='131742904d846798')}},recursive=True)
                lines=self.model.property(self.modes,self.ammo,'left',self.controls,native)
                symbols=[r for r in array_values(lines.runs[1]) if r.kind=='icon']
                self.assertEqual(len(symbols),1)
                self.assertEqual((symbols[0].hash,symbols[0].caption),('131742904d846798',caption))
                self.assertEqual([r.text for r in array_values(lines.runs[1]) if r.kind=='text'],['CURRENT PROPERTY: '])
                for field,bad in [('current',value+1),('kind','flashlight'),('hash_hex','0000000000000000')]:
                    original=native.directions.left[field];native.directions.left[field]=bad
                    fallback=self.model.property(self.modes,self.ammo,'left',self.controls,native)
                    self.assertTrue(all(r.kind=='text' for r in array_values(fallback.runs[1])))
                    native.directions.left[field]=original
        hidden=self.model.property(self.modes,self.ammo,'None',self.controls,native)
        self.assertEqual(hidden[1],'CURRENT PROPERTY: HIDE')
        self.assertTrue(all(r.kind=='text' for r in array_values(hidden.runs[1])))

    def test_display_choices_highlight_only_current_style_without_keycap_boxes(self):
        for style, label in [('icon','ICON'),('text','TEXT'),('both','ICON AND TEXT')]:
            with self.subTest(style=style):
                self.controls.hud_display=style
                lines=self.model.property(self.modes,self.ammo,'left',self.controls)
                selected=[run.text for run in lines.runs[3].values() if run.accent]
                self.assertEqual(selected,[label])
                self.assertTrue(all(run.kind=='text' for run in lines.runs[3].values()))
                self.assertEqual([run.text for run in lines.runs[4].values() if run.kind=='key'],['F10'])
        lines=array_values(self.model.presets(None,self.modes,self.ammo,self.controls,3))
        self.assertNotIn('F10','\n'.join(lines))


    def test_legacy_flashlight_selection_is_hide(self):
        self.assertEqual(self.lines('down')[0], 'CURRENT PROPERTY: HIDE')


    def test_presets_show_saved_values_not_current_values(self):
        presets = self.lua.eval('''{{targets={left={kind='programmable_ammo',value=101},right={kind='rpm',value=700},
            up={kind='zeroing',value=75},down={kind='flashlight',value=1}}},{targets={}},{targets={}}}''')
        lines=array_values(self.model.presets(presets,self.modes,self.ammo,self.controls,3))
        self.assertFalse(any('SAVE PRESETS' in line for line in lines))
        self.assertEqual(lines[0], '1. ARMOR PIERCING, 700 RPM, 75 M (DEFAULT) | PRESS 1')
        self.assertEqual(lines[1], '2. EMPTY | PRESS 2')
        self.assertEqual(lines[2], '3. EMPTY | PRESS 3')
        self.assertEqual(lines[3], '')
        self.assertEqual(lines[5], 'CURRENT SWAP HOTKEY: PRESS SLASH')

    def test_two_choice_panel_has_no_third_row_or_shortcut(self):
        lines=array_values(self.model.presets(None,self.modes,self.ammo,self.controls,2))
        self.assertFalse(any(s.startswith('3.') or 'PRESS 3' in s for s in lines))
        self.assertEqual([index for index,line in enumerate(lines) if line==''],[2])
        self.assertTrue(lines[1].startswith('2.'))
        self.assertTrue(lines[4].startswith('CURRENT SWAP HOTKEY:'))


    def test_absent_module_preserves_saved_value_and_marks_unavailable(self):
        self.modes.directions.up.present = False
        preset=self.lua.eval("{targets={up={kind='zeroing',value=150}}}")
        self.assertEqual(self.model.preset_text(preset,self.modes,self.ammo), '150 M (UNAVAILABLE)')
        self.assertEqual(preset.targets.up.value,150)


    def test_help_omits_held_status_and_settings_route_while_welcome_keeps_actual_keys(self):
        self.controls.card_label='T';self.controls.save_label='F8';self.controls.hud_label='Mouse5'
        for lines in (self.model.presets(None,self.modes,self.ammo,self.controls,2),
                      self.model.property(self.modes,self.ammo,'right',self.controls)):
            text='\n'.join(array_values(lines))
            self.assertNotIn('CURRENTLY HOLDING',text);self.assertNotIn('SETTINGS:',text)
        welcome=self.model.onboarding(self.lua.table_from(dict(presets=True,hud=False,swap=False)),self.controls)
        text='\n'.join(array_values(welcome))
        self.assertIn('[X] OPEN PRESETS: HOLD T + F8 (PRESS)',text)
        self.assertIn('[ ] CONFIGURE HUD: HOLD T + MOUSE5 (PRESS)',text)
        self.assertEqual([r.text for r in welcome.runs[3].values() if r.accent],['X'])
        self.assertFalse(any(r.accent for r in welcome.runs[4].values()))
        self.assertIn('SETTINGS:',text);self.assertIn('SWAP PRESETS',text)


    def test_rich_presets_use_saved_value_icons_separated_by_plus(self):
        presets=self.lua.eval("{{targets={left={kind='programmable_ammo',value=101},right={kind='rpm',value=700},up={kind='zeroing',value=75}}}}")
        icons=self.lua.eval("{left={[101]={kind='programmable_ammo',hash_hex='123456789abcdef0'}},right={[700]={kind='rpm',hash_hex='1111111111111111'}},up={[75]={kind='zeroing',hash_hex='2222222222222222'}}}")
        lines=self.model.presets(presets,self.modes,self.ammo,self.controls,3,icons)
        runs=array_values(lines.runs[1])
        symbols=[run for run in runs if run.kind=='icon']
        self.assertEqual([run.hash for run in symbols],['123456789abcdef0','1111111111111111','2222222222222222'])
        self.assertEqual([run.caption for run in symbols],[None,'700','75 M'])
        self.assertEqual(sum(run.kind=='text' and run.text==' + ' for run in runs),2)
        self.assertEqual(runs[-1].kind,'key');self.assertEqual(runs[-1].text,'1')
        self.assertTrue(all(not run.unavailable for run in symbols))

    def test_wheel_marks_group_presets_by_semantic_choice_and_exclude_flashlight(self):
        presets=self.lua.eval("{{targets={right={kind='rpm',value=700},up={kind='zeroing',value=150}}},{targets={right={kind='rpm',value=700}}},{targets={right={kind='rpm',value=1150},down={kind='flashlight',value=0}}}}")
        geometry=self.lua.eval("{directions={right={{value=700,x=100,y=200,w=80,h=80},{value=1150,x=300,y=200,w=80,h=80}},up={{value=150,x=500,y=600,w=80,h=80}},down={{value=0,x=500,y=300,w=80,h=80}}}}")
        marks=self.model.wheel_marks(presets,self.modes,None,3,geometry,'presets')
        self.assertEqual([(r.x,r.label,r.side) for r in marks.values()],[(100,'P1 / P2','right'),(300,'P3','right'),(500,'P1','up')])
        limited=self.model.wheel_marks(presets,self.modes,None,2,geometry,'presets')
        self.assertFalse(any(r.label=='P3' for r in limited.values()))
        current=self.model.wheel_marks(presets,self.modes,'right',3,geometry,'property')
        self.assertEqual([(r.x,r.label,r.side) for r in current.values()],[(300,'HUD','right')])
        self.assertEqual(len(self.model.wheel_marks(presets,self.modes,'None',3,geometry,'property')),0)
        self.assertEqual(presets[3].targets.down.value,0)

    def test_wheel_help_keeps_actions_empty_and_unavailable_without_repeating_marked_values(self):
        presets=self.lua.eval("{{targets={right={kind='rpm',value=1150},up={kind='zeroing',value=150}}},{targets={}},{targets={right={kind='rpm',value=700}}}}")
        geometry=self.lua.eval("{directions={right={{value=700},{value=1150}}}}")
        self.modes.directions.up.present=False
        lines=self.model.presets(presets,self.modes,self.ammo,self.controls,3,None,geometry)
        self.assertIn('SAVE P1 (DEFAULT) | 150 M (UNAVAILABLE)',lines[1])
        self.assertIn('SAVE P2 (EMPTY)',lines[2])
        self.assertNotIn('1150','\n'.join(array_values(lines)))
        self.assertNotIn('700','\n'.join(array_values(lines)))
        self.assertTrue(any('CLEAR ALL' in row for row in lines.values() if isinstance(row,str)))
        property_lines=self.model.property(self.modes,self.ammo,'right',self.controls,None,geometry)
        self.assertEqual(len(property_lines),2)
        self.assertIn('F10',property_lines[1]);self.assertIn('HIDE',property_lines[2])
        self.assertFalse(any(word in '\n'.join(array_values(property_lines)) for word in ('1150','CURRENT PROPERTY','OTHER AVAILABLE','MOVE HUD')))


    def primary_return_fixture(self,choices=(1,),target=1):
        self.modes.directions.left=self.lua.eval("{kind='secondary_fire',action_enum=11,present=true,readable=true,cycle_supported=true,current=1,choices={0,1}}")
        self.modes.directions.right=self.lua.table_from({
            'kind':'firemode','action_enum':3,'present':True,'readable':False,'inactive':True,
            'choices':list(choices),'cycle_supported':len(choices)>1,
            'primary_activation':{'action_enum':3,'before':8,'next_value':choices[0],'selector_side':'left'}},recursive=True)
        self.ammo.secondary_fire=self.lua.table_from({0:'Primary',1:'Flamethrower'})
        preset=self.lua.table_from({'targets':{'right':{'kind':'firemode','value':target,'slot':1},
            'up':{'kind':'zeroing','value':150,'slot':3}}},recursive=True)
        icons=self.lua.table_from({'right':{target:{'kind':'firemode','hash_hex':'123456789abcdef0'}}},recursive=True)
        return preset,icons

    def test_legacy_none_selector_with_single_ordinary_choice_is_reachable_without_changing_saved_targets(self):
        preset,icons=self.primary_return_fixture()
        self.assertIsNone(preset.targets.left)
        self.assertFalse(self.modes.directions.right.cycle_supported)
        self.assertEqual(self.model.preset_text(preset,self.modes,self.ammo),'AUTO, 150 M')
        runs=array_values(self.model.preset_runs(preset,self.modes,self.ammo,icons))
        symbol=next(r for r in runs if r.kind=='icon')
        self.assertFalse(symbol.unavailable)
        self.assertNotIn('UNAVAILABLE',''.join(r.text for r in runs))
        self.assertIsNone(preset.targets.left,'presentation must not synthesize a Left=0 preference')
        self.assertEqual(preset.targets.right.value,1)
        self.assertEqual(self.modes.directions.left.current,1)
        self.assertIsNone(self.modes.directions.right.current)
        self.assertFalse(self.modes.directions.right.readable)
        self.assertEqual(self.lines('right')[0],'CURRENT PROPERTY: UNAVAILABLE',
                         'a reachable preset is not the current ordinary mode')


    def test_explicit_secondary_destination_keeps_ordinary_target_unavailable_in_both_current_modes(self):
        for current in (0,1):
            with self.subTest(current=current):
                preset,icons=self.primary_return_fixture((2,3),2)
                preset.targets.left=self.lua.table_from({'kind':'secondary_fire','value':1,'slot':2})
                self.modes.directions.left.current=current
                if current==0:
                    self.modes.directions.right.inactive=False
                    self.modes.directions.right.readable=True
                    self.modes.directions.right.current=2
                    self.modes.directions.right.primary_activation=None
                self.assertIn('SEMI (UNAVAILABLE)',self.model.preset_text(preset,self.modes,self.ammo))
                runs=array_values(self.model.preset_runs(preset,self.modes,self.ammo,icons))
                self.assertTrue(next(r for r in runs if r.kind=='icon').unavailable)
                self.assertEqual(sum(r.text==' (UNAVAILABLE)' for r in runs),1)


if __name__=='__main__':
    unittest.main()

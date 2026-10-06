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
        self.assertEqual(lines[2:4], ['CURRENT PROPERTY: FLAK', 'OTHER AVAILABLE PROPERTIES: 1150 RPM, 150 M, HIDE'])
        self.assertEqual(lines[4], 'DISPLAY: ICON / TEXT / ICON AND TEXT')
        self.assertEqual(lines[5], 'CHANGE DISPLAY: F10')
        self.assertEqual(lines[6], 'CHANGE PROPERTIES: HOLD MOUSE5 + PRESS N')
        self.assertNotIn('CURRENT PROPERTY: AUTO',' '.join(lines))

    def test_display_choices_highlight_only_current_style_without_keycap_boxes(self):
        for style, label in [('icon','ICON'),('text','TEXT'),('both','ICON AND TEXT')]:
            with self.subTest(style=style):
                self.controls.hud_display=style
                lines=self.model.property(self.modes,self.ammo,'left',self.controls)
                selected=[run.text for run in lines.runs[5].values() if run.accent]
                self.assertEqual(selected,[label])
                self.assertTrue(all(run.kind=='text' for run in lines.runs[5].values()))
                self.assertEqual([run.text for run in lines.runs[6].values() if run.kind=='key'],['F10'])
        lines=array_values(self.model.presets(None,self.modes,self.ammo,self.controls,3))
        self.assertNotIn('F10','\n'.join(lines))


    def test_legacy_flashlight_selection_is_hide(self):
        self.assertEqual(self.lines('down')[2], 'CURRENT PROPERTY: HIDE')


    def test_presets_show_saved_values_not_current_values(self):
        presets = self.lua.eval('''{{targets={left={kind='programmable_ammo',value=101},right={kind='rpm',value=700},
            up={kind='zeroing',value=75},down={kind='flashlight',value=1}}},{targets={}},{targets={}}}''')
        lines=array_values(self.model.presets(presets,self.modes,self.ammo,self.controls,3))
        self.assertFalse(any('SAVE PRESETS' in line for line in lines))
        self.assertEqual(lines[2], '1. ARMOR PIERCING, 700 RPM, 75 M (DEFAULT) | PRESS 1')
        self.assertEqual(lines[3], '2. EMPTY | PRESS 2')
        self.assertEqual(lines[4], '3. EMPTY | PRESS 3')
        self.assertEqual(lines[5], '')
        self.assertEqual(lines[7], 'CURRENT SWAP HOTKEY: PRESS SLASH')

    def test_two_choice_panel_has_no_third_row_or_shortcut(self):
        lines=array_values(self.model.presets(None,self.modes,self.ammo,self.controls,2))
        self.assertFalse(any(s.startswith('3.') or 'PRESS 3' in s for s in lines))
        self.assertEqual([index for index,line in enumerate(lines) if line==''],[1,4])
        self.assertTrue(lines[3].startswith('2.'))
        self.assertTrue(lines[6].startswith('CURRENT SWAP HOTKEY:'))


    def test_absent_module_preserves_saved_value_and_marks_unavailable(self):
        self.modes.directions.up.present = False
        preset=self.lua.eval("{targets={up={kind='zeroing',value=150}}}")
        self.assertEqual(self.model.preset_text(preset,self.modes,self.ammo), '150 M (UNAVAILABLE)')
        self.assertEqual(preset.targets.up.value,150)


    def test_both_panels_identify_held_card_but_only_presets_keep_settings_path(self):
        for card in ('R','T','LCtrl + Mouse5 / Backspace'):
            self.controls.card_label=card
            for presets,lines in ((True,self.model.presets(None,self.modes,self.ammo,self.controls,2)),
                                 (False,self.model.property(self.modes,self.ammo,'right',self.controls))):
                self.assertEqual(lines[1],'CURRENTLY HOLDING: '+card.upper())
                self.assertEqual(lines[2],'')
                keys=[r.text for r in array_values(lines.runs[1]) if r.kind=='key']
                self.assertEqual(keys,card.upper().replace(' / ',' + ').split(' + '))
                self.assertEqual(any(line.startswith('SETTINGS:') for line in array_values(lines)),presets)
                self.assertNotIn('THEN PRESS YOUR KEY',' '.join(array_values(lines)))
                self.assertNotIn('CONFIGURE RESET',' '.join(array_values(lines)))


    def test_rich_presets_use_saved_value_icons_separated_by_plus(self):
        presets=self.lua.eval("{{targets={left={kind='programmable_ammo',value=101},right={kind='rpm',value=700},up={kind='zeroing',value=75}}}}")
        icons=self.lua.eval("{left={[101]={kind='programmable_ammo',hash_hex='123456789abcdef0'}},right={[700]={kind='rpm',hash_hex='1111111111111111'}},up={[75]={kind='zeroing',hash_hex='2222222222222222'}}}")
        lines=self.model.presets(presets,self.modes,self.ammo,self.controls,3,icons)
        runs=array_values(lines.runs[3])
        symbols=[run for run in runs if run.kind=='icon']
        self.assertEqual([run.hash for run in symbols],['123456789abcdef0','1111111111111111','2222222222222222'])
        self.assertEqual([run.caption for run in symbols],[None,'700','75 M'])
        self.assertEqual(sum(run.kind=='text' and run.text==' + ' for run in runs),2)
        self.assertEqual(runs[-1].kind,'key');self.assertEqual(runs[-1].text,'1')
        self.assertTrue(all(not run.unavailable for run in symbols))


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
        self.assertEqual(self.lines('right')[2],'CURRENT PROPERTY: UNAVAILABLE',
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

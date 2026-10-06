"""Localization and UTF-8 presentation contracts. No game calls/user writes."""
import struct
import unittest
from text_fixtures import ROOT,load_text
from lupa.luajit21 import LuaRuntime
from test_native_mod_bindings import Fixture as NativeFixture,GAME
from test_weapon_defaults_help_hud import Fixture as HelpFixture


class LocalizationTests(unittest.TestCase):
    def test_bundled_russian_catalog_font_and_both_context_panels(self):
        f=HelpFixture();text=f.lua.globals().Text
        ru=f.lua.execute((ROOT/'src/locales/ru.lua').read_text(encoding='utf-8'))
        self.assertTrue(text.register(ru.language,ru.strings))
        self.assertTrue(set(f.lua.globals().EnglishText.strings.keys()) <= set(ru.strings.keys()))
        text.configure(f.lua.table_from({'font':f.font,
            'language_provider':f.lua.eval("function() return {tag='ru'} end")}))
        text.read_language()
        self.assertEqual(text.language(),'ru')
        self.assertEqual(list(text.available_languages()[0].values()),['auto','en','ru'])
        for key,value in ru.strings.items():
            if not key.startswith('menu.') and not key.startswith('input.'):
                self.assertTrue(text.supports(value),key)
        self.assertEqual(text.text('menu.save',f.lua.table_from({'card':'T'})),
                         'Меню наборов (удерживать T +)')
        self.assertEqual(text.hud('mode.unsafe'),'УБОЙНЫЙ')
        self.assertEqual(text.hud('mode.rpm',f.lua.table_from({'value':1150})),'1150 ОБ/М')
        self.assertEqual(text.native(0x9665AC41,'BURST'),'ОЧЕРЕДЬ')
        self.assertEqual(text.native(0x00776D12,'15X100 TOXIC'),'ЯДОВИТЫЕ 15X100 ММ')
        model=f.lua.execute((ROOT/'src/weapon_defaults_help_model.lua').read_text(encoding='utf-8'))
        modes=f.lua.eval("{directions={right={present=true,readable=true,kind='rpm',current=850,choices={700,850,1150}},up={present=true,readable=false,kind='zeroing',choices={25,75,150}}}}")
        presets=f.lua.eval("{{targets={right={kind='rpm',value=1150},up={kind='zeroing',value=150}}},{targets={right={kind='rpm',value=700}}},{targets={}}}")
        controls=f.lua.table_from({'card_label':'T','save_label':'P','hud_label':'H',
            'clear_label':'P','clear_trigger':'DoubleTap','cycle_label':'Mouse5',
            'cycle_trigger':'Press','export_label':'C','import_label':'V'})
        panels=(model.presets(presets,modes,None,controls,3),
                model.property(modes,None,'right',controls))
        self.assertIn('ПУСТО',panels[0][5])
        self.assertIn('НЕДОСТУПНО',panels[1][4])
        for lines in panels:
            self.assertEqual(lines[1],'УДЕРЖИВАЕТСЯ: T')
            for index in range(1,len(lines)+1):
                self.assertTrue(text.supports(lines[index]),lines[index])
            for time,width,height in ((0,1920,1080),(.6,1280,720)):
                f.clear_rectangles();f.env.rw,f.env.rh=width,height
                self.assertTrue(f.hud.set(f.hud,lines));self.assertTrue(f.render(time))
                rows=f.rectangles()
                self.assertTrue(any(row['r']==255 for row in rows))
                self.assertGreater(len({row['alpha'] for row in rows}),5)
                for row in rows:
                    self.assertGreaterEqual(min(row['x'],row['y']),0)
                    self.assertLessEqual(row['x']+row['w'],width+.00001)
                    self.assertLessEqual(row['y']+row['h'],height+.00001)
            f.hide()
        text.set_language('en')
        self.assertEqual(model.property(modes,None,'right',controls)[1],'CURRENTLY HOLDING: T')
        text.set_language('ru')
        self.assertEqual(model.property(modes,None,'right',controls)[1],'УДЕРЖИВАЕТСЯ: T')

    def test_auto_follows_game_with_english_fallback_and_cycle_starts_with_auto(self):
        lua=LuaRuntime(unpack_returned_tuples=True);text=load_text(lua)
        text.register('ru',lua.table_from({'menu.cycle':'Сменить язык','game.0123ABCD':'СНАРЯД'}))
        lua.execute('BingusTranslations={serial=1,game_language="ru",override="fr",packs={}}')
        self.assertEqual(text.language(),'ru')
        self.assertEqual(text.text('menu.cycle'),'Сменить язык')
        self.assertEqual(text.native(0x0123ABCD,'SHELL'),'СНАРЯД')
        self.assertEqual(list(text.available_languages()[0].values()),['auto','en','ru'])
        for current,wanted in [('auto','en'),('en','ru'),('ru','auto')]:
            text.set_language(current);self.assertEqual(text.next_language(),wanted)
        text.set_language('auto')
        lua.execute('BingusTranslations.game_language="fr";BingusTranslations.serial=2')
        self.assertEqual(text.language(),'en')
    def test_catalog_fallback_placeholders_and_live_language_do_not_touch_shared_registry(self):
        lua=LuaRuntime(unpack_returned_tuples=True);text=load_text(lua)
        lua.execute('BingusTranslations={serial=1,game_language="fr",packs={}}')
        strings=lua.table_from({'help.holding':'MAINTENU : {card}','menu.cycle':'Changer de préréglage'})
        self.assertTrue(text.register('fr',strings))
        self.assertEqual(text.text('menu.cycle'),'Changer de préréglage')
        self.assertEqual(text.hud('help.holding',lua.table_from({'card':'F8'})),'MAINTENU : F8')
        self.assertEqual(text.hud('state.empty'),'EMPTY')
        self.assertIsNone(text.register('fr',lua.table_from({'help.holding':'MAINTENU : {wrong}'}))[0])
        lua.execute('BingusTranslations.game_language="de";BingusTranslations.serial=2')
        self.assertEqual(text.text('menu.cycle'),'Swap presets')
        self.assertTrue(text.set_language('fr'))
        self.assertEqual(text.text('menu.cycle'),'Changer de préréglage')
        self.assertEqual(lua.globals().BingusTranslations.game_language,'de')
        text.register('fr',lua.table_from({'menu.cycle':'Changer de préréglage 🛰'}))
        font=lua.execute((ROOT/'src/weapon_defaults_hud_font.lua').read_text(encoding='utf-8'))
        text.configure(lua.table_from({'font':font}))
        self.assertEqual(text.hud('menu.cycle'),'SWAP PRESETS')  # unsupported glyphs fall back
        self.assertFalse(text.valid('\ud800'.encode('utf-8','surrogatepass')))

    def test_all_game_languages_cover_messages_and_render_both_live_help_panels(self):
        f=HelpFixture();text=f.lua.globals().Text
        messages=set(f.lua.globals().EnglishText.strings.keys())
        catalogs={}
        for path in (ROOT/'src/locales').glob('*.lua'):
            catalog=f.lua.execute(path.read_text(encoding='utf-8'))
            if catalog.language!='en':
                self.assertTrue(text.register(catalog.language,catalog.strings),path.name)
            self.assertTrue(messages <= set(catalog.strings.keys()),path.name)
            catalogs[catalog.language]=catalog
        self.assertEqual(set(catalogs),{'en','ru','fr','de','it','es','es-419','pt','pt-br','pl','ja','ko','zh-hans','zh-hant'})
        self.assertEqual(len(text.available_languages()[0]),15)
        text.configure(f.lua.table_from({'font':f.font}))
        model=f.lua.execute((ROOT/'src/weapon_defaults_help_model.lua').read_text(encoding='utf-8'))
        modes=f.lua.eval("{directions={right={present=true,readable=true,kind='rpm',current=850,choices={700,850,1150}},up={present=true,readable=true,kind='zeroing',current=75,choices={25,75,150}}}}")
        presets=f.lua.eval("{{targets={right={kind='rpm',value=1150},up={kind='zeroing',value=150}}},{targets={right={kind='rpm',value=700}}},{targets={}}}")
        controls=f.lua.table_from({'card_label':'R','save_label':'P','hud_label':'H',
            'clear_label':'P','clear_trigger':'DoubleTap','cycle_label':'None',
            'export_label':'C','import_label':'V','last_pressed_label':'Mouse5'})
        time=0
        for language,catalog in catalogs.items():
            with self.subTest(language=language):
                text.set_language(language)
                for key in messages:
                    self.assertTrue(text.supports(catalog.strings[key]),(language,key))
                self.assertTrue(text.supports(text.native(0x9665AC41,'BURST')),language)
                for preset_panel in (True,False):
                    lines=model.presets(presets,modes,None,controls,3) if preset_panel else model.property(modes,None,'right',controls)
                    self.assertIn('MOUSE5',lines[1])
                    self.assertEqual([r.text for r in lines.runs[1].values() if r.kind=='key'],['R','MOUSE5'])
                    self.assertEqual(any(lines[n]==text.hud('help.settings') for n in range(1,len(lines)+1)),preset_panel)
                    if preset_panel:
                        self.assertTrue(any(text.hud('state.assign_swap') in lines[n] for n in range(1,len(lines)+1)))
                        self.assertFalse(any(r.kind=='key' and text.hud('state.assign_swap') in r.text
                                             for runs in lines.runs.values() for r in runs.values()))
                    for width,height in ((1920,1080),(1280,720)):
                        f.env.rw,f.env.rh=width,height;f.clear_rectangles()
                        self.assertTrue(f.hud.set(f.hud,lines));time+=.6
                        self.assertTrue(f.render(time),(language,preset_panel,list(f.env.logs.values())))
                        for row in f.rectangles():
                            self.assertGreaterEqual(min(row['x'],row['y']),0)
                            self.assertLessEqual(row['x']+row['w'],width+.00001)
                            self.assertLessEqual(row['y']+row['h'],height+.00001)
                    f.hide()

    def test_translated_placeholders_keep_keycaps_when_word_order_changes(self):
        lua=LuaRuntime(unpack_returned_tuples=True);text=load_text(lua)
        text.register('fr',lua.table_from({'help.holding':'{card} : MAINTENU'}));text.set_language('fr')
        model=lua.execute((ROOT/'src/weapon_defaults_help_model.lua').read_text(encoding='utf-8'))
        lines=model.property(lua.eval('{directions={}}'),None,'None',lua.table_from({'card_label':'Mouse5'}))
        self.assertEqual(lines[1],'MOUSE5 : MAINTENU')
        self.assertEqual(lines.highlights[1][1][1],1)
        self.assertEqual(lines.highlights[1][1][2],6)
        self.assertEqual(lines.runs[1][1].kind,'key')

    def test_utf8_glyphs_are_not_split_in_keycaps_accent_masks_or_wrapping(self):
        f=HelpFixture()
        # Real renderer, deliberately synthetic glyph: this verifies Unicode
        # boundaries, not coverage/shaping of a particular translated font.
        f.font.glyphs['Ж']=f.font.glyphs['W']
        self.assertTrue(f.set(['Ж Ж Ж']))
        f.render()
        self.assertGreater(len(f.env.rects),0)
        lines=f.lua.table_from({1:'Ж F8', 'highlights':f.lua.table_from({1:f.lua.table_from([
            f.lua.table_from([4,5])])})})
        self.assertTrue(f.hud.set(f.hud,lines));f.render(.2)
        self.assertEqual(f.hud.accents[1],'00011')

    def test_native_language_is_read_only_and_failed_or_changed_settings_are_unknown(self):
        f=NativeFixture()
        module=f.lua.execute((ROOT/'src/native_text_language.lua').read_bytes())
        settings,record,text=0x423450000,0x523450000,0x623450000
        f.regions[GAME+0x3326340]=struct.pack('<Q',settings)
        f.regions[settings+705500+212]=bytearray(struct.pack('<I',0))
        f.regions[GAME+0x37c5650]=struct.pack('<Q',record)
        f.regions[record+8]=struct.pack('<Q',text)
        f.regions[text]=b'ru\0'.ljust(16,b'\0')
        value=module[b'read'](f.reader)
        self.assertEqual(value[b'tag'],b'ru')
        for code,tag in [(b'en-US',b'en'),(b'es-MX',b'es-419'),
                         (b'zh-CN',b'zh-Hans'),(b'zh-TW',b'zh-Hant'),
                         (b'bp',b'pt-BR'),(b'ms',b'es-419'),(b'tc',b'zh-Hant'),(b'sc',b'zh-Hans')]:
            f.regions[text]=(code+b'\0').ljust(16,b'\0')
            self.assertEqual(module[b'read'](f.reader)[b'tag'],tag)
        f.regions[text]=b'ru\0'.ljust(16,b'\0')
        f.calls.clear()
        f.hook=lambda a,n,c:struct.pack('<I',1) if a==settings+705500+212 and c==2 else False
        self.assertIsNone(module[b'read'](f.reader)[0])
        f.hook=None;f.regions[text]=b'bad!\0'.ljust(16,b'\0')
        self.assertIsNone(module[b'read'](f.reader)[0])


if __name__=='__main__':unittest.main()

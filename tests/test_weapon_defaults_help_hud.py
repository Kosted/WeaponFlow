"""Text-help GUI lifecycle/layout checks with rectangle-only fake engine APIs."""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime
from text_fixtures import load_text

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src/weapon_defaults_help_hud.lua").read_text(encoding="utf-8")
FONT = (ROOT / "src/weapon_defaults_hud_font.lua").read_text(encoding="utf-8")


class Fixture:
    def __init__(self,stock_icons=False):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        load_text(self.lua)
        self.env = self.lua.execute("""
            local e={worlds={'a'},units={a=100,b=200},rw=1920,rh=1080,created={},destroyed={},
                rects={},logs={},world_calls=0,size_calls=0}
            local function alive(world)
                for _,value in ipairs(e.worlds) do if value==world then return true end end
                return false
            end
            e.api={
                App={worlds=function()
                    e.world_calls=e.world_calls+1
                    if e.fail_worlds then error('world list unavailable') end
                    return e.worlds
                end},
                World={
                    num_units=function(world) assert(alive(world));return e.units[world] end,
                    create_screen_gui=function(world)
                        assert(alive(world),'create on dead world')
                        if e.fail_create then return nil end
                        local gui={id=#e.created+1,world=world};e.created[#e.created+1]=gui;return gui
                    end,
                    destroy_gui=function(world,gui)
                        assert(alive(world),'destroy on dead world')
                        assert(gui.world==world,'wrong GUI owner')
                        e.destroyed[#e.destroyed+1]=gui
                        if e.fail_destroy then error('destroy failed') end
                    end,
                },
                Gui={
                    render_resolution=function(gui)
                        assert(alive(gui.world),'resolution on dead world')
                        e.size_calls=e.size_calls+1;return e.rw,e.rh
                    end,
                    rect=function(...)
                        assert(select('#',...)==4,'proven rect API takes exactly four args')
                        local gui,pos,size,color=...
                        assert(alive(gui.world),'rect on dead world')
                        assert(pos.vector and size.vector and color.color,'invalid API argument')
                        e.rects[#e.rects+1]={gui=gui.id,x=pos.x,y=pos.y,w=size.x,h=size.y,
                            alpha=color.alpha,r=color.r,g=color.g,b=color.b}
                    end,
                },
                Vector2=function(x,y) return {vector=true,x=x,y=y} end,
                Color=function(alpha,r,g,b) return {color=true,alpha=alpha,r=r,g=g,b=b} end,
            }
            e.log=function(message)
                e.logs[#e.logs+1]=message
                if e.fail_log then error('console unavailable') end
            end
            return e
        """)
        self.module = self.lua.execute(SOURCE)
        self.font = self.lua.execute(FONT)
        self.icons=self.lua.execute((ROOT/'src/weapon_defaults_hud_icons.lua').read_text()) if stock_icons else self.lua.eval('''{
            get=function(hash)
                if hash=='0123456789abcdef' then
                    return {g=128,r={{40,50,20,255,10},{50,55,10,128,10}}}
                end
            end}''')
        self.options = self.lua.table_from({"api": self.env.api, "font": self.font, "log": self.env.log,'icons':self.icons})
        self.hud = self.module.new(self.options)

    def set(self, paragraphs):
        return self.hud.set(self.hud, self.lua.table_from(paragraphs,recursive=True))

    def render(self, time=0):
        return self.hud.render(self.hud, time)

    def hide(self):
        return self.hud.hide(self.hud)

    def shutdown(self):
        return self.hud.shutdown(self.hud)

    def rectangles(self):
        return [dict(row) for row in self.env.rects.values()]

    def text_rectangles(self):
        return [row for row in self.rectangles() if (row['r'],row['g'],row['b'])!=(10,13,15)]

    def clear_rectangles(self):
        self.env.rects = self.lua.table()


class HelpHudTests(unittest.TestCase):
    def test_active_style_text_uses_yellow_and_colour_only_change_repaints(self):
        f=Fixture()
        def show(first,second):
            lines=f.lua.table_from({1:'ICON / TEXT', 'runs':f.lua.table_from([
                f.lua.table_from([f.lua.table_from(dict(kind='text',text='ICON',accent=first)),
                                  f.lua.table_from(dict(kind='text',text=' / ')),
                                  f.lua.table_from(dict(kind='text',text='TEXT',accent=second))])])})
            self.assertTrue(f.hud.set(f.hud,lines));self.assertTrue(f.render())
        show(True,False)
        yellow=[r for r in f.text_rectangles() if (r['r'],r['g'],r['b'])==(255,220,90)]
        white=[r for r in f.text_rectangles() if (r['r'],r['g'],r['b'])==(240,240,226)]
        self.assertTrue(yellow and white)
        self.assertLess(max(r['x'] for r in yellow),max(r['x'] for r in white))
        old_yellow_right=max(r['x']+r['w'] for r in yellow)
        created=len(f.env.created);f.clear_rectangles();show(False,True)
        yellow=[r for r in f.text_rectangles() if (r['r'],r['g'],r['b'])==(255,220,90)]
        self.assertTrue(yellow)
        self.assertGreater(len(f.env.created),created)
        self.assertGreater(min(r['x'] for r in yellow),old_yellow_right)

    def test_accented_and_cyrillic_words_share_one_baseline(self):
        fixture=Fixture()
        # Repeated identical letters isolate the visible regression: the
        # accented word must not lower its neighboring ordinary letters.
        lines=fixture.lua.eval("{[1]='Е ЙЕ Е',runs={{{kind='text',text='Е ЙЕ Е'}}}}")
        self.assertTrue(fixture.hud.set(fixture.hud,lines));self.assertTrue(fixture.render())
        glyph=fixture.font.glyphs['Е'];other=fixture.font.glyphs['Й']
        cell=16.2/fixture.font.height;space=fixture.font.glyphs[' '].advance*cell
        start=fixture.env.rw*.52
        origins=[start,start+glyph.width*cell+space+(other.advance+glyph.bearing-other.bearing)*cell,
                 start+glyph.width*cell+space+(other.advance+glyph.bearing+glyph.width-other.bearing)*cell+space]
        shapes=[]
        for x in origins:
            rows=[r for r in fixture.text_rectangles() if x-.00001 <= r['x'] < x+glyph.width*cell-.00001]
            shapes.append(sorted((round(r['x']-x,6),round(r['y'],6),round(r['w'],6),round(r['h'],6),r['alpha']) for r in rows))
        self.assertTrue(shapes[0])
        self.assertEqual(shapes[0],shapes[1]);self.assertEqual(shapes[0],shapes[2])

    def assert_bounds(self, fixture):
        rects = fixture.rectangles()
        self.assertTrue(rects)
        for row in rects:
            self.assertGreaterEqual(row['x'], 0)
            self.assertGreaterEqual(row['y'], 0)
            self.assertGreater(row['w'], 0)
            self.assertGreater(row['h'], 0)
            self.assertLessEqual(row['x'] + row['w'], fixture.env.rw + 0.00001)
            self.assertLessEqual(row['y'] + row['h'], fixture.env.rh + 0.00001)


    def test_fixed_text_anchor_and_antialiasing_with_padded_translucent_background(self):
        fixture = Fixture()
        fixture.set(["Preset 1: 1150 RPM", "R + P + 1: SAVE"])
        self.assertTrue(fixture.render())
        self.assert_bounds(fixture)
        rects = fixture.text_rectangles()
        self.assertAlmostEqual(min(r['x'] for r in rects), 1920 * .52)
        self.assertAlmostEqual(min(r['y'] for r in rects), 24)
        self.assertGreater(len({r['alpha'] for r in rects}), 5)
        self.assertTrue(all((r['r'], r['g'], r['b']) == (240, 240, 226) for r in rects))
        background=fixture.rectangles()[0]
        self.assertEqual((background['alpha'],background['r'],background['g'],background['b']),(160,10,13,15))
        self.assertAlmostEqual(background['x'],min(r['x'] for r in rects)-14)
        self.assertAlmostEqual(background['y'],14)
        self.assertAlmostEqual(background['x']+background['w'],max(r['x']+r['w'] for r in rects)+14)
        self.assertAlmostEqual(background['y']+background['h'],max(r['y']+r['h'] for r in rects)+10)
        self.assertEqual(len(fixture.rectangles()),len(rects)+1)


    def test_keycaps_fit_any_supported_printable_binding_without_a_key_name_allowlist(self):
        for label in ('R','MOUSE5','PRINTSCREEN','NUMPADDIVIDE','BACKSPACE','CTRL + ALT + F12','[','/'):
            with self.subTest(label=label):
                fixture=Fixture()
                fixture.set({1:label,'runs':{1:[{'kind':'key','text':label}]}})
                self.assertTrue(fixture.render())
                self.assert_bounds(fixture)
                rows=fixture.rectangles()
                self.assertEqual((rows[1]['r'],rows[1]['g'],rows[1]['b']),(142,142,130))
                self.assertEqual((rows[2]['r'],rows[2]['g'],rows[2]['b']),(30,34,35))
                accent=[r for r in rows if r['r']==255]
                self.assertEqual(len(accent),sum(len(fixture.font.glyphs[ch].r) for ch in label))
                self.assertGreaterEqual(rows[1]['w'],26)
                self.assertAlmostEqual(rows[1]['y'],24)
                self.assertAlmostEqual(max(r['y']+r['h'] for r in accent)-min(r['y'] for r in accent),
                    (max(run[1]+(run[5] or 1) for ch in label for run in fixture.font.glyphs[ch].r.values())-
                     min(run[1] for ch in label for run in fixture.font.glyphs[ch].r.values()))*14.4/fixture.font.height)
                self.assertAlmostEqual((min(r['x'] for r in accent)+max(r['x']+r['w'] for r in accent))/2,
                    rows[1]['x']+rows[1]['w']/2)
                self.assertAlmostEqual((min(r['y'] for r in accent)+max(r['y']+r['h'] for r in accent))/2,
                    rows[1]['y']+rows[1]['h']/2)


    def test_unknown_unavailable_or_broken_graphics_use_only_provided_text_fallback(self):
        for graphics in ('unknown','missing_module','throws','invalid_sprite'):
            with self.subTest(graphics=graphics):
                fixture=Fixture()
                if graphics=='missing_module': fixture.options.icons=None
                elif graphics=='throws': fixture.icons.get=fixture.lua.eval("function() error('asset unavailable') end")
                elif graphics=='invalid_sprite': fixture.icons.get=fixture.lua.eval("function() return {g=128,r={{0,0,129,255,1}}} end")
                fixture.hud=fixture.module.new(fixture.options)
                fixture.set({1:'FLAK','runs':{1:[{'kind':'icon','text':'FLAK','hash':'ffffffffffffffff','unavailable':True}]}})
                self.assertTrue(fixture.render())
                rows=fixture.text_rectangles()
                self.assertEqual(len(rows),sum(len(fixture.font.glyphs[ch].r) for ch in 'FLAK'))
                self.assertAlmostEqual(max(r['y']+r['h'] for r in rows)-min(r['y'] for r in rows),16.2)


    def test_production_model_mixed_native_icons_plus_keys_survives_reflow_and_hiding(self):
        fixture=Fixture(stock_icons=True)
        model=fixture.lua.execute((ROOT/'src/weapon_defaults_help_model.lua').read_text())
        modes=fixture.lua.eval("{directions={right={present=true,kind='rpm',choices={700,850,1150}},up={present=true,kind='zeroing',choices={25,75,150}}}}")
        presets=fixture.lua.eval("{{targets={right={kind='rpm',value=1150},up={kind='zeroing',value=150}}},{targets={right={kind='rpm',value=850}}},{targets={}}}")
        mapping=fixture.lua.eval("{right={[1150]={kind='rpm',hash_hex='f03c671b15d01a6b'},[850]={kind='rpm',hash_hex='c7546fc9c7b6db4e'}},up={[150]={kind='zeroing',hash_hex='a2ab43e85546f79a'}}}")
        controls=fixture.lua.table_from({'card_label':'LeftControl + Mouse5 / Backspace','save_label':'PrintScreen',
            'bind_label':'PageDown','hud_label':'PageUp','cycle_label':'NumpadDivide'})
        lines=model.presets(presets,modes,None,controls,3,mapping)
        self.assertTrue(fixture.hud.set(fixture.hud,lines))
        for time,width,height in ((0,1920,1080),(.6,1280,720),(1.2,3440,1440)):
            fixture.clear_rectangles();fixture.env.rw,fixture.env.rh=width,height
            self.assertTrue(fixture.render(time))
            self.assert_bounds(fixture)
            self.assertTrue(any((r['r'],r['g'],r['b'])==(30,34,35) for r in fixture.rectangles()))
            self.assertTrue(any(r['r']==255 for r in fixture.rectangles()))
        fixture.hide()
        self.assertIsNone(fixture.hud.gui)
        self.assertEqual(len(fixture.hud.runs),0)


    def test_actual_help_model_maximum_fields_and_property_states_fit_and_cache(self):
        fixture = Fixture()
        model = fixture.lua.execute((ROOT / "src/weapon_defaults_help_model.lua").read_text(encoding="utf-8"))
        modes = fixture.lua.eval("""{directions={
            left={present=true,readable=true,kind='programmable_ammo',action_enum=8,current=325,choices={101,325}},
            right={present=true,readable=true,kind='rpm',action_enum=2,current=100000,choices={1,99999,100000}},
            up={present=true,readable=true,kind='zeroing',action_enum=1,current=10000,choices={1,9999,10000}},
            down={present=true,readable=true,kind='laser_guide',action_enum=6,current=1,choices={0,1}}}}""")
        # A 48-character unbroken label exercises the production stock-label
        # upper length bound without claiming a real projectile/name mapping.
        ammo = fixture.lua.table_from({101: "A" * 48, 325: "B" * 48})
        controls = fixture.lua.table_from({"card_label": "Mouse5", "save_label": "PageDown",
            "bind_label": "PageUp", "hud_label": "Backspace", "cycle_label": "PrintScreen"})
        presets = fixture.lua.eval("""{
            {targets={left={kind='programmable_ammo',value=101},right={kind='rpm',value=100000},
                up={kind='zeroing',value=10000},down={kind='laser_guide',value=1}}},
            {targets={left={kind='programmable_ammo',value=325},right={kind='rpm',value=99999},
                up={kind='zeroing',value=9999},down={kind='laser_guide',value=0}}},
            {targets={left={kind='programmable_ammo',value=101},right={kind='rpm',value=1},
                up={kind='zeroing',value=1},down={kind='laser_guide',value=1}}}}
        """)
        variants = [model.presets(presets, modes, ammo, controls, 3),
                    model.presets(presets, modes, ammo, controls, 2),
                    model.property(modes, ammo, "None", controls),
                    model.property(modes, ammo, "up", controls)]
        for paragraphs in variants:
            with self.subTest(lines=[paragraphs[i] for i in range(1,len(paragraphs)+1)]):
                fixture.clear_rectangles()
                self.assertTrue(fixture.hud.set(fixture.hud, paragraphs))
                self.assertTrue(fixture.render(0))
                self.assert_bounds(fixture)
                count = len(fixture.env.rects)
                fixture.hud.set(fixture.hud, paragraphs)
                fixture.render(.1)
                fixture.render(.6)
                self.assertEqual(len(fixture.env.rects), count)
                fixture.hide()


    def test_dead_world_is_never_destroyed_or_reused(self):
        fixture = Fixture()
        fixture.set(["SAFE"])
        fixture.render()
        fixture.env.worlds = fixture.lua.table_from(["b"])
        fixture.render(.6)
        self.assertEqual(len(fixture.env.created), 2)
        self.assertEqual(len(fixture.env.destroyed), 0)
        self.assertEqual(fixture.hud.owner, "b")
        fixture.env.worlds = fixture.lua.table()
        result = fixture.shutdown()
        self.assertEqual(result['status'], "owner_gone")
        self.assertEqual(len(fixture.env.destroyed), 0)


    def test_shutdown_is_idempotent_even_if_gui_destruction_fails(self):
        fixture = Fixture()
        fixture.set(["SAFE"])
        fixture.render()
        fixture.env.fail_destroy = True
        value, why = fixture.shutdown()
        self.assertIsNone(value)
        self.assertIn("destruction", why)
        self.assertIsNone(fixture.hud.gui)
        self.assertEqual(fixture.shutdown()['status'], "already_closed")
        self.assertEqual(len(fixture.env.destroyed), 1)
        fixture.render(1)
        value, why = fixture.set(["UNSAFE"])
        self.assertIsNone(value)
        self.assertIn("shut down", why)
        self.assertEqual(len(fixture.env.created), 1)


if __name__ == "__main__":
    unittest.main()

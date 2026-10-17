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
            local e={worlds={'scene','a'},units={scene=100000,a=100,b=200},rw=1920,rh=1080,created={},destroyed={},
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
                        assert(pos.vector and pos.z==1022 and size.vector and color.color,'invalid API argument')
                        e.rects[#e.rects+1]={gui=gui.id,x=pos.x,y=pos.y,w=size.x,h=size.y,
                            alpha=color.alpha,r=color.r,g=color.g,b=color.b}
                    end,
                },
                Vector2=function(x,y) return {vector=true,x=x,y=y} end,
                Vector3=function(x,y,z) return {vector=true,x=x,y=y,z=z} end,
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
        return [row for row in self.rectangles() if (row['r'],row['g'],row['b']) in ((240,240,226),(255,220,90))]

    def clear_rectangles(self):
        self.env.rects = self.lua.table()


class HelpHudTests(unittest.TestCase):
    def test_exo_faces_decode_on_demand_and_filtered_pixels_preserve_coverage_and_cache(self):
        f=Fixture()
        self.assertEqual(len(list(f.font.glyphs.keys())),0)
        self.assertIsNotNone(f.font.heading.glyphs['Ж'])
        glyph=f.lua.table_from(dict(r=[[0,0,2,255,2]]),recursive=True)
        small=f.font.pixels(glyph,.5)
        self.assertEqual([list(r.values()) for r in small.values()],[[0,0,1,255,1]])
        self.assertTrue(f.lua.eval('rawequal')(small,f.font.pixels(glyph,.5)))
        other=f.font.pixels(glyph,.75)
        coverage=sum(r[3]*r[4]*r[5] for r in other.values())
        self.assertAlmostEqual(coverage,4*255*.75*.75,delta=2)

    def test_edge_directions_hide_with_their_keycaps_and_hidden_hud_gets_a_beside_explanation(self):
        f=Fixture();f.set(['HELP'])
        for index,(x,y,count) in enumerate(((900,500,4),(900,0,3),(0,500,3),(1840,500,3),(900,990,3))):
            box=f.lua.table_from(dict(x=x,y=y,w=80,h=90,hidden=False))
            f.hud.set_overlay(f.hud,f.lua.table(),box);f.clear_rectangles();self.assertTrue(f.render(index*.1))
            self.assertEqual(sum((r['r'],r['g'],r['b'])==(30,34,35) for r in f.rectangles()),count)
            self.assert_bounds(f)
        box=f.lua.table_from(dict(x=900,y=500,w=80,h=90,hidden=True,key='K',trigger='Press'))
        f.hud.set_overlay(f.hud,f.lua.table(),box);f.clear_rectangles();self.assertTrue(f.render(.6))
        hints=[r for r in f.rectangles() if (r['r'],r['g'],r['b'])==(12,15,16) and r['w']>120]
        self.assertTrue(hints);self.assertGreater(min(r['x'] for r in hints),980)

    def test_wheel_frames_and_indicator_arrows_repaint_move_and_stay_inside_viewport(self):
        f=Fixture();f.set(['CURRENT PROPERTY: HIDE'])
        marks=f.lua.table_from([dict(x=850,y=500,w=80,h=80,label='P1 / P2',side='up'),
                               dict(x=650,y=500,w=120,h=80,label='P3',side='right'),
                               dict(x=450,y=500,w=120,h=80,label='P2',side='left')],recursive=True)
        indicator=f.lua.table_from(dict(x=1050,y=650,w=80,h=90,hidden=True,key='LCtrl + Mouse5'))
        self.assertTrue(f.hud.set_overlay(f.hud,marks,indicator));self.assertTrue(f.render())
        self.assert_bounds(f)
        self.assertTrue(any((r['r'],r['g'],r['b'])==(255,215,65) for r in f.rectangles()))
        for x,y in ((890,583),(890,497),(1090,743),(1090,647)):
            self.assertFalse(any(r['x']<=x<r['x']+r['w'] and r['y']<=y<r['y']+r['h']
                                 for r in f.rectangles() if (r['r'],r['g'],r['b'])==(255,215,65)),
                             'both wheel marks and the HUD must have open top/bottom bracket gaps')
        yellow=[r for r in f.rectangles() if (r['r'],r['g'],r['b'])==(255,215,65)]
        for x in (510,710):
            for y in (497,583):
                self.assertTrue(any(r['x']<=x<r['x']+r['w'] and r['y']<=y<r['y']+r['h'] for r in yellow),
                                'side properties have their long bracket strokes at the top and bottom')
        for x in (447,573,647,773):
            self.assertFalse(any(r['x']<=x<r['x']+r['w'] and r['y']<=540<r['y']+r['h'] for r in yellow),
                             'side-property brackets must stay open at the left and right')
        created=len(f.env.created);f.clear_rectangles()
        self.assertTrue(f.hud.set_overlay(f.hud,marks,indicator));f.render(.05)
        self.assertEqual(len(f.env.created),created);self.assertEqual(len(f.rectangles()),0)
        for time,x,y in ((.2,8,8),(.4,1820,970)):
            indicator.x,indicator.y=x,y;f.clear_rectangles()
            self.assertTrue(f.hud.set_overlay(f.hud,marks,indicator));self.assertTrue(f.render(time))
            self.assert_bounds(f)
        f.clear_rectangles();self.assertTrue(f.render(.65))
        self.assertTrue(any((r['r'],r['g'],r['b'],r['alpha'])==(255,215,65,145) for r in f.rectangles()))
        self.assertTrue(any((r['r'],r['g'],r['b'],r['alpha'])==(255,215,65,245) for r in f.rectangles()),'arrows remain steady')
        f.hide();self.assertEqual(len(f.hud.marks),0);self.assertIsNone(f.hud.indicator)

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
            rows=[r for r in fixture.text_rectangles() if x-.6 <= r['x'] < x+glyph.width*cell+.4]
            origin=min(r['x'] for r in rows)
            shapes.append(sorted((round(r['x']-origin,6),round(r['y'],6),round(r['w'],6),round(r['h'],6),r['alpha']) for r in rows))
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


    def test_fixed_text_anchor_and_antialiasing_with_styled_translucent_panel(self):
        fixture = Fixture()
        fixture.set(["Preset 1: 1150 RPM", "R + P + 1: SAVE"])
        self.assertTrue(fixture.render())
        self.assert_bounds(fixture)
        rects = fixture.text_rectangles()
        self.assertAlmostEqual(min(r['x'] for r in rects), 1920 * .52,delta=1)
        self.assertAlmostEqual(min(r['y'] for r in rects), 24,delta=1)
        self.assertGreater(len({r['alpha'] for r in rects}), 5)
        self.assertTrue(all((r['r'], r['g'], r['b']) == (240, 240, 226) for r in rects))
        panels=[r for r in fixture.rectangles() if r['alpha']==232]
        self.assertGreater(len({(r['r'],r['g'],r['b']) for r in panels}),5)
        self.assertAlmostEqual(min(r['x'] for r in panels),min(r['x'] for r in rects)-14,delta=1)
        self.assertAlmostEqual(min(r['y'] for r in panels),14)
        self.assertAlmostEqual(max(r['x']+r['w'] for r in panels),max(r['x']+r['w'] for r in rects)+14,delta=1)
        self.assertAlmostEqual(max(r['y']+r['h'] for r in panels),max(r['y']+r['h'] for r in rects)+10,delta=1)
        self.assertTrue(any((r['r'],r['g'],r['b'])==(113,119,111) for r in fixture.rectangles()))
        self.assertTrue(any((r['r'],r['g'],r['b'])==(255,233,0) for r in fixture.rectangles()))


    def test_keycaps_fit_any_supported_printable_binding_without_a_key_name_allowlist(self):
        for label in ('R','MOUSE5','PRINTSCREEN','NUMPADDIVIDE','BACKSPACE','CTRL + ALT + F12','[','/'):
            with self.subTest(label=label):
                fixture=Fixture()
                fixture.set({1:label,'runs':{1:[{'kind':'key','text':label}]}})
                self.assertTrue(fixture.render())
                self.assert_bounds(fixture)
                rows=fixture.rectangles()
                key_edge=next(r for r in rows if (r['r'],r['g'],r['b'])==(142,142,130))
                self.assertTrue(any((r['r'],r['g'],r['b'])==(30,34,35) for r in rows))
                accent=[r for r in fixture.text_rectangles() if r['r']==255]
                self.assertTrue(accent)
                self.assertGreaterEqual(key_edge['w'],26)
                self.assertAlmostEqual(key_edge['y'],24)
                self.assertAlmostEqual(max(r['y']+r['h'] for r in accent)-min(r['y'] for r in accent),
                    (max(run[1]+(run[5] or 1) for ch in label for run in fixture.font.glyphs[ch].r.values())-
                     min(run[1] for ch in label for run in fixture.font.glyphs[ch].r.values()))*14.4/fixture.font.height,delta=1)
                self.assertAlmostEqual((min(r['x'] for r in accent)+max(r['x']+r['w'] for r in accent))/2,
                    key_edge['x']+key_edge['w']/2,delta=1)
                self.assertAlmostEqual((min(r['y'] for r in accent)+max(r['y']+r['h'] for r in accent))/2,
                    key_edge['y']+key_edge['h']/2,delta=1)


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
                self.assertTrue(rows)
                self.assertAlmostEqual(max(r['y']+r['h'] for r in rows)-min(r['y'] for r in rows),16.2,delta=1)


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

    def test_property_panel_renders_stock_icon_with_numeric_caption_and_updates_it(self):
        f=Fixture(stock_icons=True)
        model=f.lua.execute((ROOT/'src/weapon_defaults_help_model.lua').read_text())
        modes=f.lua.eval("{directions={right={present=true,readable=true,kind='rpm',current=1150}}}")
        native=f.lua.eval("{directions={right={kind='rpm',current=1150,hash_hex='f03c671b15d01a6b'}}}")
        controls=f.lua.table_from({'card_label':'R','hud_label':'H'})
        for time,value,hash_hex,width,height in ((0,1150,'f03c671b15d01a6b',1920,1080),
                                               (.2,700,'52bbfc5a70359393',1280,720)):
            modes.directions.right.current=value
            native.directions.right.current=value;native.directions.right.hash_hex=hash_hex
            lines=model.property(modes,None,'right',controls,native)
            self.assertTrue(f.hud.set(f.hud,lines))
            self.assertEqual((f.hud.runs[1][2].kind,f.hud.runs[1][2].caption),('icon',str(value)))
            f.env.rw,f.env.rh=width,height;f.clear_rectangles()
            self.assertTrue(f.render(time));self.assert_bounds(f)
            self.assertEqual(f.hud.owner,'a')
            self.assertTrue(f.icons.get(hash_hex))


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
        fixture.env.worlds = fixture.lua.table_from(["scene","b"])
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

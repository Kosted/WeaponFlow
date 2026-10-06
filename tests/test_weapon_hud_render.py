"""Renderer/cache contract with an isolated GUI adapter; no live-game proof."""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime
from text_fixtures import load_text


SOURCE = (Path(__file__).resolve().parents[1] / "src/weapon_defaults_hud.lua").read_text(encoding="utf-8")
FONT_SOURCE = (Path(__file__).resolve().parents[1] / "src/weapon_defaults_hud_font.lua").read_text(encoding="utf-8")


class Fixture:
    def __init__(self, display=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        load_text(self.lua)
        self.module = self.lua.execute(SOURCE)
        self.env = self.lua.execute("""
          local e={worlds={'a'},units={a=100,b=200},rw=1920,rh=1080,created={},destroyed={},rects={},
            logs={},finish_calls=0,move_calls=0,bounds_calls=0,resolution_calls=0,cycle_calls=0,x=465,y=64}
          local function present(world)
            for _,w in ipairs(e.worlds) do if w==world then return true end end
            return false
          end
          e.api={
            App={worlds=function() if e.fail_worlds then error('worlds unavailable') end;return e.worlds end},
            World={
              num_units=function(world) assert(present(world),'stale world access');return e.units[world] end,
              create_screen_gui=function(world)
                assert(present(world),'create on stale world')
                if e.fail_create then return nil end
                local gui={id=#e.created+1,world=world}
                e.created[#e.created+1]=gui;return gui
              end,
              destroy_gui=function(world,gui)
                assert(present(world),'destroy on stale world')
                assert(gui.world==world,'destroy with wrong owner')
                if e.fail_destroy then error('fixture destroy error') end
                e.destroyed[#e.destroyed+1]=gui
              end,
            },
            Gui={
              render_resolution=function(gui)
                assert(gui and present(gui.world),'resolution on stale GUI')
                e.resolution_calls=e.resolution_calls+1;return e.rw,e.rh
              end,
              rect=function(...)
                assert(select('#',...)==4,'observed rect API takes GUI,position,size,color')
                local gui,position,size,color=...
                assert(gui and present(gui.world),'rect on stale GUI')
                assert(position.vector and size.vector and color.color,'wrong API argument type/order')
                e.rects[#e.rects+1]={gui=gui.id,world=gui.world,x=position.x,y=position.y,
                  w=size.x,h=size.y,alpha=color.alpha,r=color.r,g=color.g,b=color.b}
              end,
            },
            Vector2=function(x,y) return {vector=true,x=x,y=y} end,
            Color=function(alpha,r,g,b) return {color=true,alpha=alpha,r=r,g=g,b=b} end,
          }
          e.layout={
            cycle_display=function()
              if e.display_error then return nil,e.display_error end
              e.display=({icon='text',text='both',both='icon'})[e.display]
              return e.display
            end,
            selection=function() return e.selection end,
            cycle_selection=function(_,resource,available,initial)
              e.cycle_calls=e.cycle_calls+1
              e.cycle_resource,e.cycle_available,e.cycle_initial=resource,available,initial
              if e.cycle_error then return nil,e.cycle_error end
              e.selection=e.cycle_result
              return e.selection
            end,
            position=function() return e.x,e.y end,
            set_bounds=function(_,rw,rh,w,h)
              e.bounds_calls=e.bounds_calls+1;e.bounds={rw=rw,rh=rh,w=w,h=h}
              if e.fail_bounds then return nil,'bounds rejected' end
              if e.clamp then e.x=math.max(0,math.min(e.x,rw-w));e.y=math.max(0,math.min(e.y,rh-h)) end
              return true
            end,
            move=function(_,time,intent)
              e.move_calls=e.move_calls+1;e.x=e.x+intent.x;e.y=e.y+intent.y;return true
            end,
            finish=function()
              e.finish_calls=e.finish_calls+1
              if e.fail_finish then return nil,'disk unavailable' end
              return true
            end,
          }
          e.icons={band_alpha={60,180},shadow_alpha={25,50},sprites={}}
          e.icons.sprites.known={g=4,sg=2,s={{0,0,1,2,1}},r={{0,1,2,1,1},{2,0,1,2,2}}}
          e.icons.get=function(hash) return e.icons.sprites[hash] end
          e.log=function(message) e.logs[#e.logs+1]=message end
          return e
        """)
        self.options = self.lua.table_from({
            "api": self.env.api, "layout": self.env.layout, "icons": self.env.icons, "log": self.env.log,
            "font": self.lua.execute(FONT_SOURCE),
            "display": display,
        })
        self.hud = self.module.new(self.options)
        self.env.display=self.hud.display

    def table(self, value):
        return self.lua.table_from(value, recursive=True)

    def state(self, kind="programmable_ammo", value=25, side="left", native_kind=None,
              hash="known", present=True, readable=True, label=None, label_reason=None):
        modes = {"directions": {side: {"kind": kind, "current": value, "present": present, "readable": readable}}}
        native = {"directions": {side: {"kind": native_kind or kind, "current": value, "hash_hex": hash,
                                      "label": label, "label_reason": label_reason}}}
        return modes, native

    def set(self, modes=None, native=None, selected=None, **state):
        if modes is None:
            modes, native = self.state(**state)
        self.hud.set(self.hud, self.table(modes), self.table(native) if native is not None else None, selected)

    def render(self, time):
        return self.hud.render(self.hud, time)

    def move(self, time=0, x=1, y=0):
        return self.hud.move(self.hud, time, self.table({"x": x, "y": y}))

    def replace_worlds(self, worlds):
        self.env.worlds = self.table(worlds)


class HudRenderTests(unittest.TestCase):

    def test_same_renderer_switches_style_immediately_and_preserves_style_on_save_failure(self):
        f=Fixture()
        f.set(kind='rpm',value=1150);f.render(0)
        for index,style in enumerate(('icon','text','both')):
            self.assertEqual(f.hud.cycle_display(f.hud),(style,None))
            self.assertIsNone(f.hud.gui)
            f.set(kind='rpm',value=1150);f.render(.1*(index+1))
            self.assertEqual(f.hud.entries[1].text,'1150 RPM' if style!='icon' else None)
            self.assertEqual(f.hud.entries[1].sprite is not None,style!='text')
        f.env.display_error='disk unavailable'
        result,why=f.hud.cycle_display(f.hud)
        self.assertIsNone(result);self.assertEqual(why,'disk unavailable')
        self.assertEqual(f.hud.display,'both')
        self.assertEqual(f.hud.entries[1].text,'1150 RPM')


    def test_passive_instance_changes_hide_unavailable_choice_without_replacing_preference(self):
        f = Fixture()
        f.env.selection = "up"
        # This instance lacks the chosen optic. Its available RPM cannot replace it.
        f.set(kind="rpm", value=1150, side="right", selected=f.hud.selection(f.hud, "aabbccddeeff1234"))
        self.assertEqual(len(f.hud.entries), 0)
        self.assertEqual(f.env.selection, "up")
        self.assertEqual(f.env.cycle_calls, 0)
        # A later instance has the optic and uses the unchanged choice.
        f.set(kind="zeroing", value=150, side="up", selected=f.hud.selection(f.hud, "aabbccddeeff1234"))
        self.assertEqual(f.hud.entries[1].text, "150 M")
        f.env.selection = "None"
        f.set(kind="zeroing", value=150, side="up", selected=f.hud.selection(f.hud, "aabbccddeeff1234"))
        self.assertEqual(len(f.hud.entries), 0)
        self.assertEqual(f.env.selection, "None")
        self.assertEqual(f.env.cycle_calls, 0)


    def test_flashlight_on_any_side_is_hidden_without_lookup_or_preference_mutation(self):
        for display in ("icon", "text", "both"):
            for side in ("left", "right", "up", "down"):
                for value in (0, 1, 2):
                    with self.subTest(display=display, side=side, value=value):
                        f = Fixture(display)
                        f.env.selection = side
                        f.env.icons.get = f.lua.eval("function() error('flashlight icon lookup must not run') end")
                        f.set(kind="flashlight", value=value, side=side,
                              selected=f.hud.selection(f.hud, "aabbccddeeff1234"))
                        self.assertEqual(len(f.hud.entries), 0)
                        f.render(0)
                        self.assertEqual(len(f.env.created), 0)
                        self.assertEqual(len(f.env.logs), 0, "excluded flashlight is not an unreadable label error")
                        self.assertEqual(f.env.selection, side)
                        self.assertEqual(f.env.cycle_calls, 0)
                        self.assertEqual(f.env.finish_calls, 0)


    def test_hidden_absent_and_unreadable_selected_direction_never_fall_back_to_another(self):
        f = Fixture()
        modes, native = f.state(kind="rpm", value=1150, side="right")
        for selected in ("None", "left", "up", "down"):
            f.set(modes, native, selected=selected)
            self.assertEqual(len(f.hud.entries), 0)
        f.set(modes, native, selected="right")
        self.assertEqual(len(f.hud.entries), 1)
        modes["directions"]["right"]["readable"] = False
        f.set(modes, native, selected="right")
        self.assertEqual(len(f.hud.entries), 0)


    def test_icon_only_uses_stock_graphic_and_never_draws_any_mode_label(self):
        for kind, value, native_kind, label in (
            ("rpm", 1150, "rpm", None), ("firemode", 6, "unsafe", None),
            ("zeroing", 150, "zeroing", None),
            ("programmable_ammo", 284, "programmable_ammo", "Flak"),
        ):
            with self.subTest(kind=kind):
                f = Fixture("icon")
                f.set(kind=kind, value=value, native_kind=native_kind, selected="left", label=label)
                self.assertIsNone(f.hud.entries[1].text)
                self.assertIsNotNone(f.hud.entries[1].sprite)
                self.assertTrue(f.render(0))
                self.assertEqual(len(f.env.rects), 3, "only the fixture icon's three runs")
                self.assertEqual(f.env.bounds.h, 76)
        f.set(kind="rpm", value=700, hash="unmapped")
        self.assertEqual(len(f.hud.entries), 0, "icon-only never falls back to numbers")
        f.render(.1)
        self.assertIsNone(f.hud.gui)

    def test_text_only_shows_supported_semantic_labels_and_never_draws_icon(self):
        cases = (
            ("rpm", 1150, "rpm", None, "1150 RPM"),
            ("firemode", 5, "safe", None, "SAFE"),
            ("firemode", 6, "unsafe", None, "UNSAFE"),
            ("firemode", 1, "firemode", None, "AUTO"),
            ("firemode", 2, "firemode", None, "SEMI"),
            ("firemode", 3, "firemode", None, "BURST"),
            ("firemode", 4, "firemode", None, "VOLLEY"),
            ("firemode", 7, "firemode", None, "TOTAL"),
            ("zeroing", 150, "zeroing", None, "150 M"),
            ("laser_guide", 0, "laser_guide", None, "OFF"),
            ("laser_guide", 1, "laser_guide", None, "ON"),
            ("programmable_ammo", 284, "programmable_ammo", "Flak", "FLAK"),
        )
        for kind, value, native_kind, label, expected in cases:
            with self.subTest(kind=kind, value=value):
                f = Fixture("text")
                f.set(kind=kind, value=value, native_kind=native_kind, selected="left", label=label)
                self.assertEqual(f.hud.entries[1].text, expected)
                self.assertIsNone(f.hud.entries[1].sprite)
                self.assertTrue(f.render(0))
                self.assertGreater(len(f.env.rects), 3)
                self.assertTrue(all(r.r == 240 and 0 < r.alpha <= 235 for r in f.env.rects.values()))

    def test_both_is_default_and_unknown_display_is_normalized_without_guessing_labels(self):
        for display in (None, "both", "invalid"):
            f = Fixture(display)
            f.set(kind="programmable_ammo", value=330, label="  High  explosive  ")
            self.assertEqual(f.hud.display, "both")
            self.assertEqual(f.hud.entries[1].text, "HIGH EXPLOSIVE")
            self.assertIsNotNone(f.hud.entries[1].sprite)
            self.assertTrue(f.render(0))
            self.assertGreater(len(f.env.rects), 3)
        f.set(kind="programmable_ammo", value=330)
        self.assertIsNone(f.hud.entries[1].text, "a projectile ID/hash is never a mode label")
        self.assertIsNotNone(f.hud.entries[1].sprite)


    def test_text_only_does_not_request_or_depend_on_the_icon_asset(self):
        f = Fixture("text")
        f.env.icons.get = f.lua.eval("function() error('icon lookup must not run') end")
        f.set(label="FLAK")
        self.assertTrue(f.render(0))
        self.assertIsNone(f.hud.entries[1].sprite)


    def test_cancel_move_before_reset_does_not_save_or_mutate_layout_and_hide_stays_safe(self):
        f = Fixture()
        f.move()
        self.assertTrue(f.render(0))
        f.env.layout.dirty = True
        position = (f.env.x, f.env.y)
        calls = (f.env.move_calls, f.env.bounds_calls)
        self.assertTrue(f.hud.cancel_move(f.hud))
        self.assertFalse(f.hud.preview)
        self.assertFalse(f.hud.moving)
        self.assertTrue(f.env.layout.dirty)
        self.assertEqual((f.env.x, f.env.y), position)
        self.assertEqual((f.env.move_calls, f.env.bounds_calls), calls)
        self.assertEqual(f.env.finish_calls, 0)
        f.hud.hide(f.hud)
        f.hud.shutdown(f.hud)
        self.assertEqual(f.env.finish_calls, 0)
        self.assertEqual(len(f.env.destroyed), 1)


    def test_shutdown_destroys_only_own_gui_once_and_prevents_recreation(self):
        f = Fixture()
        f.set()
        f.render(0)
        result, reason = f.hud.shutdown(f.hud)
        self.assertEqual(result.status, 'destroyed')
        self.assertIsNone(reason)
        self.assertEqual(len(f.env.destroyed), 1)
        f.set()
        f.render(.2)
        self.assertEqual(f.hud.shutdown(f.hud).status, 'already_closed')
        self.assertEqual(len(f.env.created), 1)
        self.assertEqual(len(f.env.destroyed), 1)
        self.assertIsNone(f.hud.gui)

    def test_shutdown_after_world_disappears_forgets_gui_without_touching_dead_owner(self):
        f = Fixture()
        f.set()
        f.render(0)
        f.replace_worlds([])
        result, reason = f.hud.shutdown(f.hud)
        self.assertEqual(result.status, 'owner_gone')
        self.assertIsNone(reason)
        self.assertEqual(len(f.env.destroyed), 0)
        self.assertIsNone(f.hud.gui)


if __name__ == "__main__":
    unittest.main()

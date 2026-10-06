"""Optional HUD movement and sidecar checks with isolated fake I/O only."""
from pathlib import Path
import math
import unittest

from lupa.luajit21 import LuaRuntime


SOURCE = (Path(__file__).resolve().parents[1] / "src/weapon_defaults_hud_layout.lua").read_text(encoding="utf-8")
PROFILE = "76561198000000001"
WEAPON_PATH = "C:/isolated/" + PROFILE + ".ini"
HUD_PATH = "C:/isolated/" + PROFILE + "-HUD.ini"
DEFAULT_X, DEFAULT_Y = 1920 * .53, 1080 * .55


def sidecar(x="0.25", y="0.3", profile=PROFILE):
    return f"[hud]\nschema=1\nprofile_id={profile}\nx={x}\ny={y}\n"


class Fixture:
    def __init__(self, raw=None, read_error=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.module = self.lua.execute(SOURCE)
        self.env = self.lua.execute("""
            local env = {disk={}, logs={}, reads={}, writes=0}
            env.io = {
              read=function(path,limit)
                env.reads[#env.reads+1]={path=path,limit=limit}
                if env.throw_read then error('read exception') end
                if env.read_error then return nil,env.read_error end
                if env.disk[path] == nil then return nil,'missing' end
                return env.disk[path]
              end,
              atomic_write=function(path,data,expected)
                env.writes=env.writes+1
                env.write_path,env.write_expected=path,expected
                if env.throw_write then error('write exception') end
                if env.write_error then return nil,env.write_error end
                if env.disk[path]~=expected then return nil,'changed concurrently' end
                env.disk[path]=data
                return true
              end,
            }
            env.log=function(message) env.logs[#env.logs+1]=message end
            return env
        """)
        self.env.disk[WEAPON_PATH] = "original weapon presets"
        self.env.disk[HUD_PATH] = raw
        self.env.read_error = read_error
        self.store = self.lua.table_from({"profile_id": PROFILE, "path": WEAPON_PATH, "io": self.env.io})
        self.open()

    def open(self):
        result = self.module.new(self.store, self.env.log)
        if isinstance(result, tuple):
            self.layout, self.error = result
        else:
            self.layout, self.error = result, None
        return self.layout

    def move(self, time, x=1, y=0):
        return self.layout.move(self.layout, time, self.lua.table_from({"x": x, "y": y}))

    def position(self):
        return self.layout.position(self.layout)

    def bounds(self, rw, rh, w=256, h=80):
        return self.layout.set_bounds(self.layout, rw, rh, w, h)

    def finish(self):
        return self.layout.finish(self.layout)


class HudLayoutTests(unittest.TestCase):

    def test_display_cycles_persist_without_changing_weapon_choices_and_fail_closed(self):
        f=Fixture(sidecar())
        self.assertEqual(f.layout.display,'both')
        self.assertEqual(f.env.writes,0)
        for resource,direction in [('aabbccddeeff1234','up'),('8899aabbccdd1234','None')]:
            f.layout.set_selection(f.layout,resource,direction)
        position=f.position()
        for style in ('icon','text','both'):
            self.assertEqual(f.layout.cycle_display(f.layout),style)
            f.open()
            self.assertEqual(f.layout.display,style)
            self.assertEqual(f.layout.selection(f.layout,'aabbccddeeff1234'),'up')
            self.assertEqual(f.layout.selection(f.layout,'8899aabbccdd1234'),'None')
            self.assertEqual(f.position(),position)
            self.assertEqual(f.env.disk[WEAPON_PATH],'original weapon presets')
        original=f.env.disk[HUD_PATH]
        f.env.write_error='disk unavailable'
        result,why=f.layout.cycle_display(f.layout)
        self.assertIsNone(result);self.assertIn('disk unavailable',why)
        self.assertEqual(f.layout.display,'both')
        self.assertEqual(f.env.disk[HUD_PATH],original)
        f.env.write_error=None
        f.env.disk[HUD_PATH]=original+'; external change\n'
        result,why=f.layout.cycle_display(f.layout)
        self.assertIsNone(result);self.assertIn('changed concurrently',why)
        self.assertEqual(f.layout.display,'both')
        f.env.disk[HUD_PATH]=original.replace('display=both','display=invalid')
        self.assertIsNone(f.open())

    def test_save_occurs_once_on_finish_and_reopens_at_same_position(self):
        f = Fixture()
        f.move(0)
        for frame in range(1, 101):
            f.move(frame / 100)
        self.assertEqual(f.env.writes, 0)
        position = f.position()
        self.assertTrue(f.finish())
        self.assertEqual(f.env.writes, 1)
        self.assertEqual(f.env.write_path, HUD_PATH)
        self.assertIsNone(f.env.write_expected)
        self.assertIn("HUD_POSITION", f.env.logs[1])
        f.finish()
        self.assertEqual(f.env.writes, 1)
        self.assertEqual(f.env.disk[WEAPON_PATH], "original weapon presets")
        f.open()
        for actual, expected in zip(f.position(), position):
            self.assertAlmostEqual(actual, expected, places=8)


    def test_motion_is_frame_rate_independent_and_accelerates(self):
        positions = []
        for fps in (30, 60, 144):
            f = Fixture()
            f.move(0, -1)
            for frame in range(1, int(2.5 * fps) + 1):
                f.move(frame / fps, -1)
            positions.append(f.position()[0])
        expected = DEFAULT_X - (12 * 2 + 688 * 8 / 12 + 700 * .5)
        for x in positions:
            self.assertAlmostEqual(x, expected, places=7)
        f = Fixture()
        f.move(0)
        f.move(.1)
        first = f.position()[0] - DEFAULT_X
        for frame in range(2, 21):
            f.move(frame / 10)
        old = f.position()[0]
        f.move(2.1)
        self.assertLess(first, 2)
        self.assertAlmostEqual(f.position()[0] - old, 70, places=7)


    def test_complete_hud_box_stays_within_eight_pixel_margins(self):
        f = Fixture(sidecar("0.999", "0.999"))
        self.assertEqual(f.position(), (1920 - 256 - 8, 1080 - 80 - 8))
        f.move(0, 1, 1)
        self.assertFalse(f.move(.1, 1, 1))
        self.assertFalse(f.layout.dirty)
        f.move(.2, -1, -1)
        for frame in range(1, 601):
            f.move(.2 + frame / 60, -1, -1)
        self.assertEqual(f.position(), (8, 8))


    def test_invalid_or_foreign_file_fails_closed_without_any_write(self):
        for raw in ("", sidecar(profile="76561198000000002"), sidecar(x="NaN"),
                    sidecar(y="1.1"), sidecar(x="-0.1"), sidecar() + "x=0.5\n",
                    sidecar().replace("schema=1", "schema=3"), sidecar() + "z=1\n",
                    sidecar().replace("[hud]", "[settings]"), sidecar().replace("y=0.3\n", ""),
                    sidecar() + "\0", sidecar() + " " * 65536):
            with self.subTest(raw=raw[:100]):
                f = Fixture(raw)
                self.assertIsNone(f.layout)
                self.assertIsNotNone(f.error)
                self.assertEqual(f.env.writes, 0)
                self.assertEqual(f.env.disk[HUD_PATH], raw)
                self.assertIn("HUD_ERROR", f.env.logs[1])


    def test_atomic_concurrent_change_never_overwrites_external_position(self):
        original, external = sidecar(), sidecar("0.7", "0.7")
        f = Fixture(original)
        f.move(0)
        f.move(.1)
        f.env.disk[HUD_PATH] = external
        ok, reason = f.finish()
        self.assertIsNone(ok)
        self.assertIn("changed concurrently", reason)
        self.assertEqual(f.env.disk[HUD_PATH], external)
        self.assertEqual(f.env.disk[WEAPON_PATH], "original weapon presets")
        self.assertTrue(f.layout.dirty)
        self.assertIn("HUD_ERROR", f.env.logs[1])


class HudSelectionStoreTests(unittest.TestCase):
    weapon_a = "aabbccddeeff1234"
    weapon_b = "8899aabbccdd1234"

    def cycle(self, f, resource=None, initial=None, available=("left", "right", "up", "down")):
        if isinstance(available, (tuple, list)):
            available = f.lua.table_from(available)
        return f.layout.cycle_selection(f.layout, resource or self.weapon_a, available, initial)

    def selection(self, f, resource=None):
        return f.layout.selection(f.layout, resource or self.weapon_a)


    def test_explicit_hidden_is_distinct_from_unrecorded_and_survives_restart(self):
        f = Fixture()
        self.assertEqual(f.layout.set_selection(f.layout, self.weapon_a, "None"), "None")
        f.open()
        self.assertEqual(self.selection(f), "None")
        self.assertIsNone(self.selection(f, self.weapon_b))
        self.assertEqual(self.cycle(f), "left")
        self.assertEqual(f.env.logs[1], "HUD_SELECTION resource=" + self.weapon_a + " direction=None")


    def test_same_type_uses_each_instances_new_list_without_passive_preference_changes(self):
        f = Fixture()
        self.assertEqual(self.cycle(f, available=["left", "down"]), "left")
        # Another instance of the same type has a different combination.
        self.assertEqual(self.cycle(f, available=["up", "right"]), "right")
        self.assertEqual(self.cycle(f, available=["left", "down"]), "down")
        raw, writes = f.env.disk[HUD_PATH], f.env.writes
        f.open()
        self.assertEqual(self.selection(f), "down")
        self.assertEqual(f.env.disk[HUD_PATH], raw)
        self.assertEqual(f.env.writes, writes)
        # Down is unavailable on this instance: the explicit next press hides.
        self.assertEqual(self.cycle(f, available=["up", "left"]), "None")
        raw, writes = f.env.disk[HUD_PATH], f.env.writes
        f.open()
        self.assertEqual(self.selection(f), "None")
        self.assertEqual(f.env.disk[HUD_PATH], raw)
        self.assertEqual(f.env.writes, writes)
        self.assertEqual(self.cycle(f, available=["up", "left"]), "left")


    def test_missing_malformed_and_duplicate_lists_preserve_existing_preference_and_file(self):
        f = Fixture()
        self.assertEqual(self.cycle(f, available=["left"]), "left")
        f.move(0)
        f.move(.1)
        raw, writes, position = f.env.disk[HUD_PATH], f.env.writes, f.position()
        malformed = [None, False, "left", 1, ["left", "left"], ["LEFT"], ["None"],
                     ["right", "unknown"], ["left", "right", "up", "down", "left"],
                     f.lua.table_from({"left": True}), f.lua.table_from({0: "left"}),
                     f.lua.table_from({2: "down"}), f.lua.table_from({1: "left", 3: "down"}),
                     f.lua.table_from({1: "left", "extra": "down"}),
                     f.lua.eval("setmetatable({}, {__index=function() return 'left' end})")]
        for available in malformed:
            with self.subTest(available=str(available)):
                result, reason = self.cycle(f, available=available)
                self.assertIsNone(result)
                self.assertIsInstance(reason, str)
                self.assertEqual(self.selection(f), "left")
                self.assertEqual(f.env.disk[HUD_PATH], raw)
                self.assertEqual(f.env.writes, writes)
                self.assertEqual(f.position(), position)
                self.assertTrue(f.layout.dirty)


    def test_failed_write_or_concurrent_change_preserves_choice_and_pending_position(self):
        for failure in ("write", "concurrent", "exception"):
            with self.subTest(failure=failure):
                f = Fixture()
                self.assertEqual(self.cycle(f), "left")
                previous = f.env.disk[HUD_PATH]
                f.move(0)
                f.move(.1)
                if failure == "write":
                    f.env.write_error = "disk unavailable"
                elif failure == "concurrent":
                    previous += "; external edit\n"
                    f.env.disk[HUD_PATH] = previous
                else:
                    f.env.throw_write = True
                choice, reason = self.cycle(f)
                self.assertIsNone(choice)
                self.assertIsInstance(reason, str)
                self.assertEqual(self.selection(f), "left")
                self.assertTrue(f.layout.dirty)
                self.assertEqual(f.env.disk[HUD_PATH], previous)


if __name__ == "__main__":
    unittest.main()

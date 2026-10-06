"""Offline capture/serialization checks; no process access or game actions.

ReaderFixture checks that real reader output preserves the native slot even
when its public choices list omits zero entries. This is not a live save test.
"""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime
from test_native_weapon_modes import ReaderFixture

SOURCE = (Path(__file__).resolve().parents[1] / "src/weapon_defaults_capture.lua").read_bytes()


class WeaponDefaultsCapture(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.capture = self.lua.execute(SOURCE)[b"capture"]

    def evaluate(self, expression):
        return self.capture(self.lua.eval(expression))

    def test_rpm_hole_uses_native_third_slot_not_second_compressed_choice(self):
        fixture = ReaderFixture(functions=(0, 2, 0, 0))
        fixture.rpm(choices=(700, 0, 1150), selected=2)
        modes = fixture.inspect()
        direction = modes[b"directions"][b"right"]
        self.assertEqual(list(direction[b"choices"].values()), [700, 1150])
        self.assertEqual(list(direction[b"slot_values"].values()), [700, 0, 1150])
        capture = fixture.lua.execute(SOURCE)[b"capture"]
        updates, skips = capture(modes)
        self.assertEqual(dict(updates[b"right"]), {b"slot": 3, b"kind": b"rpm", b"value": 1150})
        self.assertIsNone(skips[b"right"])


    def test_absent_unreadable_and_unsupported_directions_are_not_updates(self):
        updates, skips = self.evaluate(b"""{directions={
            left={present=false,readable=false,kind='absent',reason='absent module'},
            up={present=true,readable=false,kind='zeroing',reason='read failed'},
            right={present=true,readable=true,kind='magazine',action_enum=4,slot=0,
                current=1,choices={1,2},slot_values={1,2,0}},
            down={present=true,readable=true,kind='flashlight',action_enum=5,
                slot=2,current=2,choices={0,1,2},slot_values={0,1,2}}
        }}""")
        self.assertEqual(dict(updates), {})
        self.assertEqual(set(skips.keys()), {b"left", b"up", b"right", b"down"})
        self.assertEqual(skips[b"up"], b"read failed")
        self.assertIn(b"flashlight", skips[b"down"])

    def test_flashlight_is_never_captured_by_enum_or_kind_in_any_direction(self):
        for side in (b"left", b"right", b"up", b"down"):
            for selected in (0, 1, 2):
                for action, kind in ((5, b"flashlight"), (5, b"unknown"), (0, b"flashlight")):
                    with self.subTest(side=side, selected=selected, action=action, kind=kind):
                        direction = self.lua.table_from({b"present": True, b"readable": True,
                            b"kind": kind, b"action_enum": action, b"slot": selected, b"current": selected,
                            b"choices": [0, 1, 2], b"slot_values": [0, 1, 2]}, recursive=True)
                        modes = self.lua.table_from({b"directions": self.lua.table_from({side: direction})})
                        updates, skips = self.capture(modes)
                        self.assertEqual(dict(updates), {})
                        self.assertIn(b"flashlight", skips[side])


    def test_two_slot_ammo_saves_semantic_projectile_and_zero_is_not_none(self):
        for slot, value in ((0, 0), (1, 325)):
            updates, skips = self.evaluate(("""{directions={left={present=true,readable=true,
                kind='programmable_ammo',action_enum=8,slot=%d,current=%d,
                choices={0,325},slot_values={0,325}}}}""" % (slot, value)).encode())
            self.assertEqual(dict(updates[b"left"]),
                             {b"slot": slot+1, b"kind": b"programmable_ammo", b"value": value})
            self.assertIsNone(skips[b"left"])


    def test_secondary_fire_captures_actual_binary_slot_without_inactive_right(self):
        for slot in (0,1):
            modes=self.lua.eval(("""{directions={left={present=true,readable=true,
                kind='secondary_fire',action_enum=11,slot=%d,current=%d,
                choices={0,1},slot_values={0,1},cycle_supported=false},
                right={present=true,readable=false,inactive=true,kind='firemode',action_enum=3,
                slot=0,choices={1,2},slot_values={1,2,0}}}}""" % (slot,slot)).encode())
            updates,skips=self.capture(modes)
            self.assertEqual(dict(updates[b'left']),{b'kind':b'secondary_fire',b'value':slot,b'slot':slot+1})
            self.assertIsNone(updates[b'right'])
            self.assertTrue(skips[b'right'])


class WeaponDefaultsSeed(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        module = self.lua.execute(SOURCE)
        self.seed = module[b"seed"]
        self.single = module[b"single_setting"]

    def direction(self, kind=b"rpm", values=(700, 850, 1150), selected=1):
        action, capacity = {
            b"zeroing": (1, 3), b"rpm": (2, 3), b"firemode": (3, 3),
            b"flashlight": (5, 3), b"laser_guide": (6, 2), b"programmable_ammo": (8, 2), b"secondary_fire": (11,2),
        }[kind]
        return self.lua.table_from({
            b"present": True, b"readable": True, b"kind": kind, b"action_enum": action,
            b"slot": selected, b"current": values[selected], b"choices": list(values),
            b"slot_values": list(values) + [0] * (capacity - len(values)),
            b"cycle_supported": True,
        }, recursive=True)

    def modes(self, direction=None, side=b"right", down=None):
        directions = self.lua.table_from({
            name: {b"present": False, b"readable": False, b"kind": b"absent", b"action_enum": 0}
            for name in (b"left", b"right", b"up", b"down")
        }, recursive=True)
        if direction is not None:
            directions[side] = direction
        if down is not None:
            directions[b"down"] = down
        return self.lua.table_from({b"directions": directions})

    def values(self, presets, side=b"right"):
        return [presets[index][b"targets"][side][b"value"] for index in range(1, 4)
                if presets[index][b"targets"][side] is not None]

    def plain(self, value):
        if hasattr(value, "items"):
            return {key: self.plain(item) for key, item in value.items()}
        return value

    def assert_deferred(self, modes):
        plan, plan_reason = self.single(modes)
        self.assertIsNone(plan)
        self.assertIsInstance(plan_reason, bytes)
        presets, reason = self.seed(modes)
        self.assertIsNone(presets)
        self.assertIsInstance(reason, bytes)
        self.assertTrue(reason)
        self.assertEqual(reason, plan_reason)
        return reason

    def test_rpm_current_then_native_order_and_wrap_not_numeric_sort(self):
        presets, info = self.seed(self.modes(self.direction()))
        self.assertEqual(self.values(presets), [850, 1150, 700])
        self.assertEqual([presets[i][b"targets"][b"right"][b"slot"] for i in range(1, 4)], [2, 3, 1])
        self.assertEqual(dict(info), {b"qualified": True, b"side": b"right", b"count": 3,
                                     b"available_count": 1,
                                     b"reason": b"current value followed by native cyclic slot order"})
        direction = self.direction(values=(900, 450, 600), selected=0)
        direction[b"choices"] = self.lua.table_from([450, 600, 900])
        presets, _ = self.seed(self.modes(direction))
        self.assertEqual(self.values(presets), [900, 450, 600], "native slots override public-list or numeric order")

    def test_two_choices_leave_third_preset_completely_empty_even_with_flashlight(self):
        modes = self.modes(self.direction(b"firemode", (5, 6), 1), side=b"left",
                           down=self.direction(b"flashlight", (0, 1, 2), 2))
        presets, info = self.seed(modes)
        self.assertEqual(self.values(presets, b"left"), [6, 5])
        self.assertEqual(info[b"count"], 2)
        self.assertEqual(self.plain(presets[3]), {b"targets": {}})
        for index in (1, 2):
            self.assertEqual(set(presets[index][b"targets"].keys()), {b"left"})


    def test_zero_or_multiple_known_present_candidates_return_only_empty_presets(self):
        modes = self.modes(down=self.direction(b"flashlight", (0, 1, 2), 0))
        for count in (0, 2, 3):
            if count:
                modes[b"directions"][b"left"] = self.direction(b"firemode", (5, 6), 1)
                modes[b"directions"][b"right"] = self.direction()
            if count == 3:
                modes[b"directions"][b"up"] = self.direction(b"zeroing", (25, 75, 150), 2)
            with self.subTest(count=count):
                presets, info = self.seed(modes)
                self.assertFalse(info[b"qualified"])
                self.assertEqual(info[b"available_count"], count)
                self.assertEqual(info[b"count"], 0)
                self.assertEqual(self.plain(presets), {1: {b"targets": {}}, 2: {b"targets": {}}, 3: {b"targets": {}}})


    def test_missing_or_unknown_presence_never_becomes_absent(self):
        self.assert_deferred(None)
        self.assert_deferred(self.lua.table())
        for side in (b"left", b"right", b"up", b"down"):
            for present in (None, 0, b"false"):
                with self.subTest(side=side, present=present):
                    modes = self.modes(self.direction())
                    modes[b"directions"][side][b"present"] = present
                    self.assert_deferred(modes)
            modes = self.modes(self.direction())
            modes[b"directions"][side] = None
            self.assert_deferred(modes)


    def test_down_nonflashlight_counts_and_sole_unreadable_down_defers(self):
        modes = self.modes(self.direction(), down=self.direction(b"laser_guide", (0, 1), 1))
        modes[b"directions"][b"down"][b"readable"] = False
        plan = self.single(modes)
        self.assertFalse(plan[b"qualified"])
        self.assertEqual(plan[b"count"], 2)
        modes[b"directions"][b"right"][b"present"] = False
        self.assertTrue(self.assert_deferred(modes).startswith(b"down:"))


if __name__ == "__main__":
    unittest.main()

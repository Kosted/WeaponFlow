"""Isolated native flashlight read/cache boundaries, not live-game evidence.

Uses the real bounded transaction and hash parser. Active-avatar validation is
an explicit fixture guard; no process, native game call or file write occurs.
"""
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src/native_flashlight_state.lua").read_bytes()
READER = (ROOT / "src/native_equipment_reader.lua").read_bytes()


class FlashlightFixture:
    def __init__(self, selected=0, present=True):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.module = self.lua.execute(SOURCE)
        self.memory, self.reads, self.read_counts = {}, [], {}
        self.mutate_on = None
        self.unreadable = None
        self.game = 0x10000000
        self.parts, self.lights = 0x20000000, 0x21000000
        self.part_entities, self.part_states = 0x22000000, 0x23000000
        self.light_entities, self.light_states = 0x24000000, 0x25000000
        self.weapon_pointer, self.module_pointer, self.avatar_pointer = 0x26000000, 0x27000000, 0x28000000
        self.selection_address = 0x29000000
        self.part_hash, self.light_hash = 0x2A000000, 0x2B000000
        self.eid, self.module_eid, self.part_index, self.light_index = 321, 654, 2, 3
        self.invalid = 0xFFFFFFFF
        self.weapon_bytes = struct.pack("<QIIII", 0xF123456789ABCDEF, self.eid, 41, 57, 0)
        self.module_bytes = struct.pack("<QIIII", 0xF223456789ABCDEF, self.module_eid, 42, 58, 0)
        self.avatar_bytes = struct.pack("<QIIII", 0xF323456789ABCDEF, 123, 43, 59, 0)
        self.write(self.game + 0x3483C34, "<I", self.invalid)
        self.write(self.game + 0x3326A38, "<Q", self.parts)
        self.write(self.game + 0x3326910, "<Q", self.lights)
        for offset, value in ((0x258, 8), (0x264, 4), (0x268, 4)):
            self.write(self.parts + offset, "<I", value)
        for offset, value in ((0x08, 8), (0x10, 6), (0x14, 6)):
            self.write(self.lights + offset, "<I", value)
        self.write(self.parts + 0x290, "<Q", self.part_entities)
        self.write(self.parts + 0x2A0, "<Q", self.part_states)
        self.write(self.lights + 0x40, "<Q", self.light_entities)
        self.write(self.lights + 0x50, "<Q", self.light_states)
        self.write(self.part_entities + self.part_index * 8, "<Q", self.weapon_pointer)
        self.write(self.light_entities + self.light_index * 8, "<Q", self.module_pointer)
        self.put(self.weapon_pointer, self.weapon_bytes)
        self.put(self.module_pointer, self.module_bytes)
        self.put(self.avatar_pointer, self.avatar_bytes)
        self.write(self.selection_address, "<I", self.eid)
        self.relation_address = self.part_states + self.part_index * 128 + 0x64
        self.state_address = self.light_states + self.light_index * 8 + 4
        self.write(self.relation_address, "<I", self.module_eid if present else self.invalid)
        self.write(self.state_address, "<I", selected)
        self.hash(self.parts + 0x278, self.part_hash, self.eid, self.part_index)
        self.hash(self.lights + 0x28, self.light_hash, self.module_eid, self.light_index)
        reader_module = self.lua.execute(READER)
        self.reader = reader_module[b"new"](self.lua.table_from({b"read": self.read}))
        self.reader[b"game"] = self.game
        self.guard = self.lua.table_from({b"calls": 0, b"verify_calls": 0})
        configure = self.lua.eval(b"""function(reader, e, avatar_address, weapon_address, selected_address)
            reader.verify=function()
                e.verify_calls=e.verify_calls+1
                if e.fail_verify then return nil,'fixture unsupported build' end
                return true
            end
            reader.guard_active=function(_,s,read)
                e.calls=e.calls+1
                assert(not e.fail_guard,'fixture active guard refused')
                assert(read(avatar_address,24)==s.avatar_bytes,'fixture active avatar changed')
                assert(read(weapon_address,24)==s.active_weapon.bytes,'fixture active weapon changed')
                local selected=read(selected_address,4)
                local a,b,c,d=selected:byte(1,4)
                assert(a+b*256+c*65536+d*16777216==s.active_weapon.entity.eid,
                    'fixture another weapon selected')
                return s.active_weapon
            end
        end""")
        configure(self.reader, self.guard, self.avatar_pointer, self.weapon_pointer, self.selection_address)
        self.snapshot = self.lua.table_from({
            b"active_weapon_verified": True, b"avatar_bytes": self.avatar_bytes,
            b"active_weapon": {b"entity": {b"eid": self.eid}, b"bytes": self.weapon_bytes},
        }, recursive=True)

    def put(self, address, data):
        self.memory.update((address + i, byte) for i, byte in enumerate(data))

    def write(self, address, fmt, *values):
        self.put(address, struct.pack(fmt, *values))

    def hash(self, header, storage, eid, index):
        self.write(header, "<QIII", storage, 8, self.invalid, 1)
        self.put(storage, struct.pack("<II", self.invalid, self.invalid) * 8)
        self.write(storage + (eid % 8) * 8, "<II", eid, index)

    def read(self, address, size):
        address, size = int(address), int(size)
        self.reads.append((address, size))
        self.read_counts[address] = self.read_counts.get(address, 0) + 1
        if self.mutate_on and self.mutate_on[:2] == (address, self.read_counts[address]):
            self.put(address, self.mutate_on[2])
        if self.unreadable == address:
            return None
        try:
            return bytes(self.memory[address + i] for i in range(size))
        except KeyError:
            return None

    def inspect(self):
        return self.module[b"inspect"](self.reader, self.snapshot)

    def watch(self, previous):
        self.reads.clear()
        self.read_counts.clear()
        return self.module[b"watch"](self.reader, self.snapshot, previous)


class NativeFlashlightWatchChecks(unittest.TestCase):
    def assert_rejected(self, result, contains):
        self.assertIsInstance(result, tuple)
        self.assertIsNone(result[0])
        self.assertIn(contains, result[1])

    def test_inspect_supplies_full_attachment_cache_and_three_real_values(self):
        for value, label in ((0, b"Auto"), (1, b"On"), (2, b"Off")):
            with self.subTest(value=value):
                f = FlashlightFixture(value)
                result = f.inspect()
                self.assertTrue(result[b"present"])
                self.assertEqual(result[b"selected"], value)
                self.assertEqual(result[b"selected_name"], label)
                for key, expected in ((b"game_module", f.game), (b"avatar_bytes", f.avatar_bytes),
                                      (b"parts_entity_array", f.part_entities),
                                      (b"parts_state_array", f.part_states),
                                      (b"parts_entity_pointer", f.weapon_pointer),
                                      (b"flashlight_entity_array", f.light_entities),
                                      (b"flashlight_state_array", f.light_states),
                                      (b"module_bytes", f.module_bytes), (b"state_address", f.state_address)):
                    self.assertEqual(result[key], expected)
                self.assertEqual(list(result[b"offered_values"].values()), [0, 1, 2])


    def test_parts_compaction_refuses_old_index_then_inspect_resolves_new_row(self):
        f = FlashlightFixture()
        previous = f.inspect()
        new_index, other_weapon = 3, 0x2C000000
        f.put(other_weapon, struct.pack("<QIIII", 99, 999, 0, 0, 0))
        f.write(f.part_entities + f.part_index * 8, "<Q", other_weapon)
        f.write(f.part_entities + new_index * 8, "<Q", f.weapon_pointer)
        f.write(f.part_states + new_index * 128 + 0x64, "<I", f.module_eid)
        f.hash(f.parts + 0x278, f.part_hash, f.eid, new_index)
        self.assert_rejected(f.watch(previous), b"parts entity pointer changed")
        current = f.inspect()
        self.assertEqual(current[b"parts_index"], new_index)
        self.assertEqual(f.watch(current)[b"selected"], 0)


    def test_attachment_change_or_removal_never_becomes_an_off_value(self):
        for eid in (655, 0xFFFFFFFF):
            with self.subTest(eid=eid):
                f = FlashlightFixture()
                previous = f.inspect()
                f.write(f.relation_address, "<I", eid)
                self.assert_rejected(f.watch(previous), b"attachment changed")


    def test_full_active_avatar_weapon_and_selected_eid_are_still_guarded(self):
        for changed in ("avatar", "weapon", "selected", "guard"):
            with self.subTest(changed=changed):
                f = FlashlightFixture()
                previous = f.inspect()
                if changed == "avatar":
                    f.put(f.avatar_pointer, b"X" + f.avatar_bytes[1:])
                elif changed == "weapon":
                    f.put(f.weapon_pointer, b"Y" + f.weapon_bytes[1:])
                elif changed == "selected":
                    f.write(f.selection_address, "<I", f.eid + 1)
                else:
                    f.guard[b"fail_guard"] = True
                self.assert_rejected(f.watch(previous), b"fixture")
                self.assertNotIn((f.state_address, 4), f.reads)


    def test_selected_enum_outside_known_values_is_not_coerced(self):
        for value in (3, 0xFFFFFFFF):
            with self.subTest(value=value):
                f = FlashlightFixture()
                previous = f.inspect()
                f.write(f.state_address, "<I", value)
                self.assert_rejected(f.watch(previous), b"outside Auto/On/Off")
                self.assertEqual(previous[b"selected"], 0)


    def test_transaction_race_rejects_value_and_identity_changes_during_readback(self):
        for field, replacement in (("state_address", struct.pack("<I", 1)),
                                    ("relation_address", struct.pack("<I", 777)),
                                    ("module_pointer", b"X" * 24)):
            with self.subTest(field=field):
                f = FlashlightFixture()
                previous = f.inspect()
                f.mutate_on = (getattr(f, field), 2, replacement)
                self.assert_rejected(f.watch(previous), b"snapshot changed while reading")
                self.assertEqual(previous[b"selected"], 0)


if __name__ == "__main__":
    unittest.main()

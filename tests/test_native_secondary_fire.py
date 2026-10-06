"""Isolated kind-11 state/label guards; these are not gameplay proof.

The real NativeReader transaction and hash parser check binary fixtures. The
active-avatar guard is explicit test scaffolding; no process or input is used.
"""
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src/native_secondary_fire.lua").read_bytes()
READER = (ROOT / "src/native_equipment_reader.lua").read_bytes()


class Fixture:
    def __init__(self, selected=0, functions=(11, 3, 1, 0), override=True):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.module = self.lua.execute(SOURCE)
        self.memory, self.reads, self.read_counts = {}, [], {}
        self.mutate_on, self.unreadable = None, None
        self.game, self.manager, self.entity_pointer = 0x10000000, 0x20000000, 0x21000000
        self.entities, self.runtime, self.state = 0x22000000, 0x23000000, 0x24000000
        self.override_defs, self.registry, self.owner = 0x25000000, 0x26000000, 0x27000000
        self.avatar_pointer, self.selection_address = 0x28000000, 0x29000000
        self.main_hash, self.override_hash = 0x2A000000, 0x2B000000
        self.eid, self.index, self.invalid = 943, 2, 0xFFFFFFFF
        self.resource = 0xF123456789ABCDEF
        self.weapon_bytes = struct.pack("<QIIII", self.resource, self.eid, 77, 88, 0)
        self.avatar_bytes = struct.pack("<QIIII", 0xF223456789ABCDEF, 11, 33, 44, 1)
        self.put(self.entity_pointer, self.weapon_bytes)
        self.put(self.avatar_pointer, self.avatar_bytes)
        self.write(self.selection_address, "<I", self.eid)
        for group in (self.module.anchors, self.module.presentation_anchors):
            for _, anchor in group.items():
                self.put(self.game + anchor.rva, anchor.bytes)
        self.write(self.game + 0x3326CE0, "<Q", self.manager)
        self.hash(self.manager + 0x30, self.main_hash, self.eid, self.index)
        self.write(self.manager + 0x48, "<Q", self.entities)
        self.write(self.entities + self.index * 8, "<Q", self.entity_pointer)
        self.write(self.manager + 0x58, "<Q", self.runtime)
        self.function_address = self.runtime + self.index * 0x3F0 + 0x350
        self.write(self.function_address, "<IIII", *functions)
        self.write(self.manager + 0x60, "<Q", self.state)
        self.state_address = self.state + self.index * 12
        self.mode, self.mask = (8 if selected else 1), (selected << 10) | (1 << 12)
        self.write(self.state_address, "<III", self.mode, self.mask, 0)
        self.hash(self.manager + 0x70, self.override_hash, self.eid, 1)
        if not override:
            self.write(self.manager + 0x70, "<QIII", self.override_hash, 0, self.invalid, 1)
        self.write(self.manager + 0xB0, "<Q", self.override_defs)
        self.definition = self.override_defs + 0x4D0
        self.write(self.definition + 0x90, "<III", 2, 1, 0)
        self.write(self.definition + 0xA0, "<QQII", 100, 200, 300, 400)
        self.write(self.game + 0x346BF98, "<Q", self.owner)
        self.write(self.owner + 0xF12BD8, "<Q", self.registry)
        self.put(self.registry, b"\0" * 0x2DA0)
        self.first = self.resource % 0x2DA
        self.write(self.registry + self.first * 16, "<QII", self.resource, 13, 0)
        self.base_definition = self.registry + 0x2DA0 + 13 * 0x4D0
        self.write(self.base_definition + 0x90, "<III", 2, 1, 0)
        self.write(self.base_definition + 0xA0, "<QQII", 0x07D9E4C091930DA7,
                   0xCD87FDDDEC2A6BFC, 0x77B68EAD, 0x3BF9DCD9)
        reader_module = self.lua.execute(READER)
        self.reader = reader_module[b"new"](self.lua.table_from({b"read": self.read}))
        self.reader[b"game"] = self.game
        self.guard = self.lua.table_from({b"calls": 0})
        configure = self.lua.eval(b"""function(reader, e, avatar, weapon, selection)
            reader.verify=function() return not e.bad_build,'fixture unsupported build' end
            reader.guard_active=function(_,s,read)
                e.calls=e.calls+1
                assert(not e.fail_guard,'fixture active guard refused')
                assert(read(avatar,24)==s.avatar_bytes,'fixture active avatar changed')
                assert(read(weapon,24)==s.active_weapon.bytes,'fixture active weapon changed')
                local a,b,c,d=read(selection,4):byte(1,4)
                assert(a+b*256+c*65536+d*16777216==s.active_weapon.entity.eid,
                    'fixture another weapon selected')
                return s.active_weapon
            end
        end""")
        configure(self.reader, self.guard, self.avatar_pointer, self.entity_pointer, self.selection_address)
        self.snapshot = self.lua.table_from({b"active_weapon_verified": True,
            b"avatar_bytes": self.avatar_bytes,
            b"active_weapon": {b"entity": {b"eid": self.eid}, b"bytes": self.weapon_bytes}}, recursive=True)
        self.modes = self.lua.table_from({b"weapon_eid": self.eid, b"weapon_bytes": self.weapon_bytes,
            b"functions": dict(zip((b"left", b"right", b"up", b"down"), functions)),
            b"fire_mode_raw": self.mode, b"mask_raw": self.mask}, recursive=True)

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
        result = self.module.inspect(self.reader, self.snapshot, self.modes)
        return result if isinstance(result, tuple) else (result, None)


class SecondaryFireChecks(unittest.TestCase):
    def rejected(self, f, message):
        value, reason = f.inspect()
        self.assertIsNone(value)
        self.assertIn(message, reason)

    def test_binary_semantics_match_mask_and_special_fire_enum(self):
        for selected in (0, 1):
            f = Fixture(selected)
            before = dict(f.memory)
            result, reason = f.inspect()
            self.assertIsNone(reason)
            self.assertEqual(result.kind, b"secondary_fire")
            self.assertEqual(result.action_enum, 11)
            self.assertEqual((result.current, result.slot), (selected, selected))
            self.assertEqual([result.choices[i] for i in (1, 2)], [0, 1])
            self.assertTrue(result.readable and result.capture_supported and result.cycle_supported)
            self.assertEqual(result.ordinary_fire_mode, 1)
            self.assertEqual(f.memory, before)
            self.assertEqual(f.guard.calls, 1)
            self.assertGreater(result.read_calls, 0)

    def test_primary_activation_is_metadata_not_a_fabricated_selected_firemode(self):
        for selected in (0, 1):
            f = Fixture(selected=selected)
            before = dict(f.memory)
            result, reason = f.inspect()
            self.assertIsNone(reason)
            self.assertEqual((result.current, result.slot), (selected, selected))
            self.assertEqual(result.fire_mode_raw, 8 if selected else 1)
            if selected:
                activation = result.primary_activation
                self.assertEqual(dict(activation.items()), {
                    b"action_enum": 3, b"before": 8, b"next_value": 1,
                    b"ordinary_slot": 1})
            else:
                self.assertIsNone(result.primary_activation)
            self.assertEqual(f.memory, before)


    def test_primary_activation_rejects_holes_duplicate_and_invalid_return_choices(self):
        cases = ((1, (0, 1, 0), True), (2, (1, 0, 2), True),
                 (1, (1, 1, 0), True), (1, (1, 0, 0), False),
                 (1, (1, 8, 0), False), (3, (1, 2, 3), False))
        for slot, values, cycle_supported in cases:
            with self.subTest(slot=slot, values=values):
                f = Fixture(selected=1)
                f.mask = (1 << 10) | (slot << 12)
                f.write(f.state_address, "<III", 8, f.mask, 0)
                f.modes.mask_raw = f.mask
                f.write(f.definition + 0x90, "<III", *values)
                result, reason = f.inspect()
                self.assertIsNone(reason)
                self.assertTrue(result.readable and result.capture_supported)
                self.assertEqual(result.cycle_supported, cycle_supported)
                self.assertIsNone(result.primary_activation)


    def test_native_fallback_uses_full_resource_hash_and_ordinary_slot(self):
        f = Fixture(override=False)
        result, _ = f.inspect()
        self.assertTrue(result.cycle_supported)
        self.assertEqual(result.cycle_definition_source, b"native_resource_fallback")
        self.assertEqual(result.cycle_definition_address, f.base_definition)


    def test_unreadable_override_does_not_fall_through_to_base_cycle(self):
        f = Fixture()
        f.unreadable = f.definition + 0x90
        result, reason = f.inspect()
        self.assertIsNone(reason)
        self.assertTrue(result.readable and result.capture_supported)
        self.assertFalse(result.cycle_supported)
        self.assertIsNotNone(result.cycle_guard_error)
        self.assertEqual(result.label_keys[0], 0x77B68EAD)


    def test_function11_is_generic_on_any_direction(self):
        for side in range(4):
            functions = [0, 0, 0, 0]
            functions[side] = 11
            result, reason = Fixture(functions=functions).inspect()
            self.assertIsNone(reason)
            self.assertTrue(result.present and result.readable)


    def test_other_mode_snapshot_identity_functions_or_state_fail_closed(self):
        for field in ("eid", "bytes", "functions", "mask", "enum"):
            f = Fixture()
            if field == "eid":
                f.modes.weapon_eid = f.eid + 1
            elif field == "bytes":
                f.modes.weapon_bytes = f.weapon_bytes[:-1] + b"\x01"
            elif field == "functions":
                f.modes.functions[b"up"] = 2
            elif field == "mask":
                f.modes.mask_raw = 0
            else:
                f.modes.fire_mode_raw = 3
            value, reason = f.inspect()
            self.assertIsNone(value)
            self.assertIsNotNone(reason)


    def test_real_transaction_rechecks_identity_state_functions_and_labels(self):
        for field in ("selection", "avatar", "weapon", "state", "functions", "labels", "buckets"):
            f = Fixture()
            address, changed = {
                "selection": (f.selection_address, struct.pack("<I", f.eid + 1)),
                "avatar": (f.avatar_pointer, f.avatar_bytes[:-1] + b"\x01"),
                "weapon": (f.entity_pointer, f.weapon_bytes[:-1] + b"\x01"),
                "state": (f.state_address, struct.pack("<III", 8, f.mask | 1024, 0)),
                "functions": (f.function_address, struct.pack("<IIII", 11, 2, 1, 0)),
                "labels": (f.base_definition + 0xA0, b"\0" * 24),
                "buckets": (f.registry, b"\0" * 0x2DA0),
            }[field]
            # guard reads the entity before the component registry, so the
            # second entity read is an immediate consistency check as well.
            f.mutate_on = (address, 2, changed)
            value, reason = f.inspect()
            self.assertIsNone(value, field)
            self.assertIsNotNone(reason, field)


if __name__ == "__main__":
    unittest.main()

"""Selection/inventory transaction boundaries; no game or native calls.

These fixtures test classification and stale-read rejection, not live equip
behavior. The production NativeReader transaction/map implementation is used.
"""
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


class Fixture:
    def __init__(self, selected=591, slots=(427, 428, 429, 600, 591)):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.module = self.lua.execute((ROOT / "src/native_equip_context.lua").read_bytes())
        native = self.lua.execute((ROOT / "src/native_equipment_reader.lua").read_bytes())
        self.native = native
        self.memory, self.reads, self.hook = {}, [], None
        self.game, self.mode, self.player = 0x10000000, 0x20000000, 0x21000000
        self.owner, self.avatar_manager = 0x23000000, 0x25000000
        self.equipment, self.equipment_entities, self.row = 0x26000000, 0x27000000, 0x28000000
        self.wielder, self.wielder_entities, self.selection = 0x29000000, 0x2A000000, 0x2B000000
        self.player_entity, self.next_map = 0x22000000, 0x40000000
        self.avatar_bytes = bytes.fromhex("97FA4D294D331C4D") + struct.pack("<IIII", 424, 700, 55, 1)
        self.avatar_address = self.owner + 0xF32F18
        for _, anchor in self.module.anchors.items():
            self.memory[self.game + anchor.rva] = anchor.bytes
        self.write(self.game + 0x33266A0, "<Q", self.mode)
        mode = bytearray(0x44)
        struct.pack_into("<I", mode, 8, 1)
        struct.pack_into("<I", mode, 0x40, 2)
        self.memory[self.mode] = bytes(mode)
        self.write(self.game + 0x3326468, "<Q", self.player)
        self.write(self.player + 0x84, "<II", 1, 1)
        self.write(self.player + 0xE8, "<Q", self.player_entity)
        self.write(self.player_entity, "<QIIII", 0xEEFF, 500, 50, 50, 1)
        self.write(self.player + 0x3A8, "<I", 55)
        self.write(self.game + 0x346BF98, "<Q", self.owner)
        self.map(self.owner + 0xF22EC8, {55: 0})
        self.entity_map = self.owner + 0xF1AEB0
        self.map(self.entity_map, {424: 0, 427: 1, 591: 2, 429: 3})
        self.memory[self.avatar_address] = self.avatar_bytes
        for i, eid in ((1, 427), (2, 591), (3, 429)):
            self.write(self.avatar_address + i * 24, "<QIIII", 0xF12345678900 + eid, eid, 888, 55 + i, 0)
        self.write(self.game + 0x3326D20, "<Q", self.avatar_manager)
        self.map(self.avatar_manager + 0xF8, {424: 0})
        self.write(self.avatar_manager + 0x6C, "<I", 1)
        self.write(self.avatar_manager + 0x110, "<Q", self.avatar_address)
        self.write(self.game + 0x3326738, "<Q", self.equipment)
        self.map(self.equipment + 0x28, {424: 0})
        self.write(self.equipment + 0x40, "<Q", self.equipment_entities)
        self.write(self.equipment + 0x50, "<Q", self.row)
        self.write(self.equipment_entities, "<Q", self.avatar_address)
        self.write(self.row, "<12I", *slots, *([0] * 7))
        self.write(self.game + 0x3326420, "<Q", self.wielder)
        self.map(self.wielder + 0x30, {424: 0})
        self.write(self.wielder + 0x18, "<I", 1)
        self.write(self.wielder + 0x48, "<Q", self.wielder_entities)
        self.write(self.wielder_entities, "<Q", self.avatar_address)
        self.write(self.wielder + 0x60, "<Q", self.selection)
        self.write(self.selection, "<II", selected, 0)
        self.write(self.game + 0x3483C34, "<I", 0)
        self.write(self.game + 0x3483C4C, "<I", 0xEEEEEEEE)
        api = self.lua.table()
        api[b"read"] = self.read
        self.reader = native.new(api)
        self.reader.game = self.game
        self.reader.verify = self.lua.eval(b"function() return true end")
        self.baseline = self.reader.snapshot(self.reader)
        self.baseline.active_weapon = self.lua.table_from({b"entity": self.lua.table_from({b"eid": 427})})
        self.reads.clear()

    def write(self, address, fmt, *values):
        self.memory[address] = struct.pack(fmt, *values)

    def patch(self, address, offset, fmt, *values):
        data = bytearray(self.memory[address])
        struct.pack_into(fmt, data, offset, *values)
        self.memory[address] = bytes(data)

    def map(self, header, entries):
        data = self.next_map
        self.next_map += 0x1000
        self.write(header, "<QIII", data, 16, 0xFFFFFFFF, 1)
        buckets = bytearray(struct.pack("<II", 0xFFFFFFFF, 0xFFFFFFFF) * 16)
        for key, index in entries.items():
            slot = key % 16
            while struct.unpack_from("<I", buckets, slot * 8)[0] != 0xFFFFFFFF:
                slot = (slot + 1) % 16
            struct.pack_into("<II", buckets, slot * 8, key, index)
        self.memory[data] = bytes(buckets)

    def read(self, address, size):
        self.reads.append((address, size))
        if self.hook:
            self.hook(address, size)
        for start, data in self.memory.items():
            offset = int(address) - start
            if 0 <= offset and offset + size <= len(data):
                return data[offset:offset + size]
        return None

    def inspect(self, expected=None):
        result = self.module.inspect(self.reader, self.baseline, expected)
        return result if isinstance(result, tuple) else (result, None)

    def watch(self, context):
        return self.module.watch(self.reader, context)

    def enable_native_watch(self):
        """Form a real NativeReader.active_weapon snapshot for original A."""
        self.reader.exe = 0x140000000
        self.reader.api[b"module"] = lambda name=None: self.game if name == b"game.dll" else self.reader.exe
        globals_block = bytearray(0x50)
        struct.pack_into("<Q", globals_block, 0, self.wielder)
        struct.pack_into("<Q", globals_block, 0x48, self.player)
        self.memory[self.game + 0x3326420] = bytes(globals_block)
        header = bytearray(0x50)
        struct.pack_into("<I", header, 0, 1)
        header[0x18:0x2C] = self.memory[self.wielder + 0x30]
        struct.pack_into("<Q", header, 0x30, self.wielder_entities)
        struct.pack_into("<Q", header, 0x48, self.selection)
        self.memory[self.wielder + 0x18] = bytes(header)
        self.card, self.card_row, self.card_entities = 0x2C000000, 0x2D000000, 0x2E000000
        self.write(self.game + 0x3326688, "<Q", self.card)
        self.map(self.card + 0x1030, {424: 0})
        card_header = bytearray(0x44)
        struct.pack_into("<I", card_header, 0, 1)
        card_header[0x14:0x28] = self.memory[self.card + 0x1030]
        struct.pack_into("<Q", card_header, 0x2C, self.card_entities)
        struct.pack_into("<Q", card_header, 0x3C, self.card_row)
        self.memory[self.card + 0x101C] = bytes(card_header)
        self.write(self.card_entities, "<Q", self.avatar_address)
        self.write(self.card_row + 0x19C, "<I", 0)
        weapon_manager, weapon_entities = 0x2F000000, 0x30000000
        holder, holder_rows = 0x31000000, 0x32000000
        self.write(self.game + 0x3326CE0, "<Q", weapon_manager)
        self.map(weapon_manager + 0x30, {427: 0})
        self.write(weapon_manager + 0x48, "<Q", weapon_entities)
        self.write(weapon_entities, "<Q", self.avatar_address + 24)
        self.write(self.game + 0x3326DC0, "<Q", holder)
        self.map(holder + 0x20, {427: 0})
        self.write(holder + 0x40, "<Q", holder_rows)
        self.write(holder_rows + 4, "<I", 424)
        self.write(self.selection, "<II", 427, 0)
        self.baseline, error = self.reader.active_weapon(self.reader, self.baseline)
        assert self.baseline is not None, error
        self.reads.clear()

    def native_watch(self, cursor=None):
        return self.reader.watch(self.reader, self.baseline, cursor)

    def enable_underbarrel(self):
        """Add a proven parent/child chain to the real active-reader fixture."""
        self.enable_native_watch()
        self.child_eid, self.child_address = 431, self.avatar_address + 4 * 24
        self.write(self.child_address, "<QIIII", 0xE12345678900, self.child_eid, 900, 0x7FFF, 0)
        self.map(self.entity_map, {424: 0, 427: 1, 591: 2, 429: 3, self.child_eid: 4})
        self.map(0x2F000000 + 0x30, {427: 0, self.child_eid: 1})
        self.write(0x30000000 + 8, "<Q", self.child_address)
        self.runtime, self.states = 0x33000000, 0x34000000
        self.write(0x2F000000 + 0x58, "<Q", self.runtime)
        self.write(0x2F000000 + 0x60, "<Q", self.states)
        self.write(self.runtime + 0x350, "<4I", 11, 3, 1, 0)
        self.write(self.states, "<II", 8, 1 << 10)
        self.parts, self.parts_rows, self.parts_entities = 0x35000000, 0x36000000, 0x36100000
        self.write(self.game + 0x3326A38, "<Q", self.parts)
        self.write(self.parts + 0x258, "<I", 4)
        self.write(self.parts + 0x264, "<I", 1)
        self.write(self.parts + 0x268, "<I", 1)
        self.map(self.parts + 0x278, {427: 0})
        self.write(self.parts + 0x290, "<Q", self.parts_entities)
        self.write(self.parts_entities, "<Q", self.avatar_address + 24)
        self.write(self.parts + 0x2A0, "<Q", self.parts_rows)
        self.write(self.parts_rows + 0x64, "<I", self.child_eid)
        self.associations, self.association_rows = 0x37000000, 0x38000000
        self.write(self.game + 0x3326730, "<Q", self.associations)
        self.map(self.associations + 0x18, {427: 0, self.child_eid: 1})
        self.write(self.associations + 0x38, "<Q", self.association_rows)
        self.write(self.association_rows, "<II", 424, 424)
        for _, anchor in self.native.alternate_anchors.items():
            self.memory[self.game + anchor.rva] = anchor.bytes
        self.write(self.selection, "<II", 427, self.child_eid)
        self.reads.clear()

    def active(self):
        return self.reader.active_weapon(self.reader, self.baseline)

    def guarded(self, snapshot):
        return self.lua.eval(b'''function(r,s)
            return r:transaction(function(read,ptr,lookup)
                return r:guard_active(s,read,ptr,lookup)
            end)
        end''')(self.reader, snapshot)


class UnderbarrelIdentityTests(unittest.TestCase):
    def test_verified_child_is_display_only_parent_remains_equip_and_resource_key(self):
        f = Fixture(selected=427)
        f.enable_underbarrel()
        value, reason = f.active()
        self.assertIsNone(reason)
        self.assertEqual(value.active_weapon_eid, 427)
        self.assertEqual(value.active_weapon.entity.resource_hex_le, f.baseline.active_weapon.entity.resource_hex_le)
        self.assertEqual(value.active_weapon.display_eid, f.child_eid)
        self.assertEqual(value.active_weapon.display_child.entity.eid, f.child_eid)
        # Attached entities need not have a network object or local authority.
        self.assertEqual(value.active_weapon.display_child.entity.network_object_id, 0x7FFF)
        self.assertEqual(value.active_weapon.display_child.entity.flags, 0)
        self.assertEqual(f.guarded(value).display_eid, f.child_eid)

    def test_unrelated_or_unproven_alternate_is_rejected(self):
        cases = [
            ("function", b"offers no secondary", lambda f: f.write(f.runtime + 0x350, "<4I", 0, 3, 1, 0)),
            ("inactive", b"secondary state", lambda f: f.write(f.states, "<II", 1, 0)),
            ("wrong_enum", b"secondary state", lambda f: f.write(f.states, "<II", 1, 1 << 10)),
            ("wrong_bits", b"secondary state", lambda f: f.write(f.states, "<II", 8, 2 << 10)),
            ("other_attachment", b"not current parent attachment", lambda f: f.write(f.parts_rows + 0x64, "<I", 429)),
            ("parts_parent", b"parts parent identity", lambda f: f.write(f.parts_entities, "<Q", f.child_address)),
            ("native_child", b"child native identity differs", lambda f: f.patch(f.child_address, 8, "<I", 429)),
            ("child_component", b"child weapon-data identity", lambda f: f.write(0x30000008, "<Q", f.avatar_address + 24)),
            ("parent_owner", b"association differs", lambda f: f.patch(f.association_rows, 0, "<I", 999)),
            ("child_owner", b"association differs", lambda f: f.patch(f.association_rows, 4, "<I", 999)),
            ("parts_count", b"count/capacity", lambda f: f.write(f.parts + 0x264, "<I", 5)),
            ("parts_absent", b"parent parts entry", lambda f: f.map(f.parts + 0x278, {})),
            ("association_absent", b"association unavailable", lambda f: f.map(f.associations + 0x18, {427: 0})),
            ("child_component_absent", b"child weapon-data unavailable", lambda f: f.map(0x2F000030, {427: 0})),
            ("anchor", b"anchor mismatch", lambda f: f.memory.__setitem__(
                f.game + f.native.alternate_anchors[1].rva, b"\0" * len(f.native.alternate_anchors[1].bytes))),
        ]
        for name, expected, mutate in cases:
            with self.subTest(name=name):
                f = Fixture(selected=427)
                f.enable_underbarrel()
                mutate(f)
                result, error = f.active()
                self.assertIsNone(result)
                self.assertIn(expected, error)


    def test_changed_child_full_identity_rejects_previous_snapshot_even_with_same_pair(self):
        f = Fixture(selected=427)
        f.enable_underbarrel()
        previous, _ = f.active()
        f.patch(f.child_address, 12, "<I", 901)
        result, error = f.guarded(previous)
        self.assertIsNone(result)
        self.assertIn(b"display child identity changed", error)


    def test_old_child_snapshot_cannot_authorize_after_parent_restored(self):
        f = Fixture(selected=427)
        f.enable_underbarrel()
        previous, _ = f.active()
        f.write(f.selection, "<II", 427, 0)
        f.write(f.states, "<II", 1, 0)
        result, error = f.guarded(previous)
        self.assertIsNone(result)
        self.assertIn(b"active weapon changed", error)


class EquipContextTests(unittest.TestCase):
    def test_grenade_retains_primary_and_is_not_weapon_even_if_nonzero(self):
        f = Fixture()
        result, error = f.inspect()
        self.assertIsNone(error)
        self.assertEqual(result.candidate_kind, b"utility")
        self.assertEqual(result.candidate_slot, b"grenade")
        self.assertEqual(result.candidate_entity.eid, 591)
        self.assertTrue(result.previous_in_main)
        self.assertFalse(any(a == f.game + 0x3326CE0 for a, _ in f.reads))

    def test_real_support_selection_needs_no_weapondata_or_local_authority(self):
        f = Fixture(selected=429)
        value, error = f.inspect()
        self.assertIsNone(error)
        self.assertEqual(value.candidate_kind, b"weapon")
        self.assertEqual(value.candidate_slot, b"support")
        self.assertEqual(value.candidate_entity.flags, 0)
        self.assertTrue(value.previous_in_main)


    def test_dropped_previous_weapon_is_absent_without_inventing_new_equip(self):
        f = Fixture(selected=0, slots=(0xEEEEEEEE, 428, 429, 600, 591))
        value, _ = f.inspect()
        self.assertFalse(value.previous_in_main)
        self.assertEqual(value.candidate_kind, b"empty")

    def test_non_inventory_entity_is_unknown(self):
        f = Fixture(selected=591, slots=(427, 428, 429, 600, 0))
        value, _ = f.inspect()
        self.assertEqual(value.candidate_kind, b"unknown")
        self.assertEqual(value.candidate_entity.eid, 591)


    def test_contradictory_main_and_utility_membership_is_unknown(self):
        f = Fixture(selected=429, slots=(427, 428, 429, 600, 429))
        self.assertEqual(f.inspect()[0].candidate_kind, b"unknown")


    def test_selection_torn_between_transaction_passes_rejected(self):
        f = Fixture(selected=429)
        count = 0
        def hook(address, size):
            nonlocal count
            if address == f.selection:
                count += 1
                if count == 2:
                    f.write(f.selection, "<II", 591, 0)
        f.hook = hook
        value, error = f.inspect()
        self.assertIsNone(value)
        self.assertIn(b"changed while reading", error)


    def test_watch_detects_main_removal_but_does_not_claim_it_on_failure(self):
        f = Fixture()
        context, _ = f.inspect()
        f.patch(f.row, 0, "<I", 0xEEEEEEEE)
        same, reason = f.watch(context)
        self.assertFalse(same)
        self.assertIn(b"main equipment slots", reason)
        fresh, error = f.inspect()
        self.assertIsNone(error)
        self.assertFalse(fresh.previous_in_main)


    def test_native_watch_cursor_tracks_empty_and_utility_then_actual_return_or_swap(self):
        for temporary in (0, 591):
            for next_eid in (427, 429):
                with self.subTest(temporary=temporary, next_eid=next_eid):
                    f = Fixture(selected=427)
                    f.enable_native_watch()
                    cursor = struct.pack("<II", temporary, 0)
                    f.memory[f.selection] = cursor
                    same, _, metrics = f.native_watch()
                    self.assertFalse(same)
                    self.assertTrue(metrics.authoritative_selection_change)
                    self.assertEqual(metrics.observed_selection_bytes, cursor)
                    self.assertEqual((metrics.previous_eid, metrics.observed_eid), (427, temporary))
                    same, reason, metrics = f.native_watch(cursor)
                    self.assertTrue(same)
                    self.assertIsNone(reason)
                    self.assertIsNone(metrics.authoritative_selection_change)
                    self.assertEqual(f.baseline.active_weapon.entity.eid, 427)
                    f.write(f.selection, "<II", next_eid, 0)
                    same, _, metrics = f.native_watch(cursor)
                    self.assertFalse(same)
                    self.assertTrue(metrics.authoritative_selection_change)
                    self.assertEqual((metrics.previous_eid, metrics.observed_eid), (temporary, next_eid))


    def test_native_watch_cursor_does_not_bypass_avatar_or_mission_lifecycle(self):
        for change, expected in (("avatar", b"owner changed"), ("network", b"avatar changed"),
                                 ("mission", b"mission ended"), ("card", b"blocks action")):
            with self.subTest(change=change):
                f = Fixture(selected=427)
                f.enable_native_watch()
                cursor = struct.pack("<II", 0, 0)
                f.memory[f.selection] = cursor
                if change == "avatar":
                    f.patch(f.avatar_address, 12, "<I", 999)
                elif change == "network":
                    f.write(f.player + 0x3A8, "<I", 77)
                elif change == "mission":
                    f.patch(f.mode, 8, "<I", 0)
                else:
                    f.write(f.card_row + 0x19C, "<I", 2)
                same, reason, metrics = f.native_watch(cursor)
                self.assertFalse(same)
                self.assertIn(expected, reason)
                self.assertIsNone(metrics.authoritative_selection_change)


if __name__ == "__main__":
    unittest.main()

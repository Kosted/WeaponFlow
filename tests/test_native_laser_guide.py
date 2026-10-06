"""Parser/guard checks against binary fixtures, not a live game validation."""
from pathlib import Path
import os
import struct
import unittest

from test_native_weapon_modes import ReaderFixture

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src/native_laser_guide.lua").read_bytes()


class LaserFixture(ReaderFixture):
    def __init__(self, *, selected=1, authority=True, functions=(6, 3, 0, 0)):
        super().__init__(functions=functions)
        self.module = self.lua.execute(SOURCE)
        self.entity_bytes = struct.pack("<QIIII", self.resource, self.eid, 741, 57, int(authority))
        self.memory[self.entity] = self.entity_bytes
        self.snapshot[b"active_weapon"][b"bytes"] = self.entity_bytes
        self.laser, self.state = 0x39000000, 0x3A000000
        self.write(self.game + 0x3483C34, "<I", 0xFFFFFFFF)
        for _, anchor in self.module[b"anchors"].items():
            self.memory[self.game + anchor[b"rva"]] = anchor[b"bytes"]
        self.write(self.game + 0x3326960, "<Q", self.laser)
        self.write(self.laser + 0x10, "<I", 4096)
        self.write(self.laser + 0x18, "<I", 1234)
        self.write(self.laser + 0x1C, "<I", 1000)
        self.write(self.laser + 0x30, "<QIII", 0x3B000000, 8192, 0xFFFFFFFF, 1)
        self.write(self.laser + 0x48, "<Q", 0x3C000000)
        self.laser_entity = 0x3C001000
        self.write(0x3C000000, "<Q", self.laser_entity)
        self.memory[self.laser_entity] = self.entity_bytes
        self.write(self.laser + 0x60, "<Q", self.state)
        self.write(self.state, "<B", selected)
        self.owner, self.registry = 0x3D000000, 0x3E000000
        self.write(self.game + 0x346BF98, "<Q", self.owner)
        self.write(self.owner + 0xF129A8, "<Q", self.registry)
        buckets = bytearray(128)
        struct.pack_into("<QII", buckets, (self.resource % 8) * 16, self.resource, 7, 0)
        self.memory[self.registry] = bytes(buckets)
        self.write(self.registry + 128 + 7 * 64 + 0x10, "<II", 123, 456)


class LaserGuideReaderChecks(unittest.TestCase):
    def test_selected_boolean_and_semantic_slots_both_states(self):
        for value in (0, 1):
            fixture = LaserFixture(selected=value)
            result = fixture.inspect()
            direction = result[b"directions"][b"left"]
            self.assertEqual(direction[b"current"], value)
            self.assertEqual(direction[b"slot"], value)
            self.assertEqual(list(direction[b"slot_values"].values()), [0, 1])
            self.assertTrue(direction[b"readable"])
            self.assertTrue(direction[b"cycle_supported"])
            self.assertEqual(result[b"definition_address"], fixture.registry + 128 + 7 * 64)
            self.assertEqual(result[b"on_event"], 123)
            self.assertEqual(result[b"off_event"], 456)
            for field in (b"kind", b"action_enum", b"current", b"slot", b"cycle_supported", b"cycle_pending"):
                self.assertEqual(result[field], direction[field])


    def test_foreign_authority_is_readable_saveable_but_not_yet_callable(self):
        fixture = LaserFixture(authority=False)
        direction = fixture.inspect()[b"directions"][b"left"]
        self.assertEqual(direction[b"current"], 1)
        self.assertTrue(direction[b"readable"])
        self.assertFalse(direction[b"cycle_supported"])
        self.assertTrue(direction[b"cycle_pending"])
        self.assertIn(b"authority", direction[b"reason"])

    def test_invalid_byte_never_becomes_on_or_off(self):
        fixture = LaserFixture(selected=255)
        result, reason = fixture.inspect()
        self.assertIsNone(result)
        self.assertIn(b"not a boolean", reason)


    def test_expected_mode_snapshot_rejects_changed_capability_or_identity(self):
        fixture = LaserFixture()
        previous = fixture.inspect()
        # Same left kind, but a module change removes another setting.
        previous[b"functions"][b"up"] = 1
        result, reason = fixture.module[b"inspect"](fixture.reader, fixture.snapshot, previous)
        self.assertIsNone(result)
        self.assertIn(b"capability changed", reason)
        previous[b"functions"][b"up"] = 0
        previous[b"weapon_eid"] = fixture.eid + 1
        result, reason = fixture.module[b"inspect"](fixture.reader, fixture.snapshot, previous)
        self.assertIsNone(result)
        self.assertIn(b"identity changed", reason)


if __name__ == "__main__":
    unittest.main()

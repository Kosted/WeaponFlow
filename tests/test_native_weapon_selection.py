"""Direct state/publication boundaries in fake memory, not live-engine proof."""
from pathlib import Path
import struct
import unittest

from test_native_weapon_modes import ReaderFixture

SOURCE = (Path(__file__).resolve().parents[1] / "src/native_weapon_selection.lua").read_bytes()


class SelectionFixture(ReaderFixture):
    def __init__(self, action=1):
        super().__init__(functions=(0, action, 0, 0), fire=1, fire_slot=0)
        self.write(self.definition + 0x90, "<III", 1, 2, 3)
        self.write(0x27000000, "<III", 1, 0xA5000088, 0x12345678)
        self.rpm(selected=0, effective=700)
        self.selection = self.lua.execute(SOURCE)
        for anchor in self.selection[b"anchors"].values():
            self.memory[self.game + anchor[b"rva"]] = anchor[b"bytes"]
        self.reader[b"api"] = self.lua.eval(b"function(read)return{read=function(...)return read(...)end}end")(self.read)
        self.reader[b"verify"] = self.lua.eval(b"function()return true end")
        self.events, self.writes = [], []
        self.fail_write = None
        self.api = self.lua.eval(b"""function(write,publish,fire,remember)return{
            write=function(...)return write(...)end,publish=function(...)publish(...)end,
            fire=function(...)fire(...)end,remember=function(...)remember(...)end}end""")(
            self.change, self.publish, self.fire, self.remember)
        self.controller = self.selection[b"new"](self.lua.table_from({b"modes": self.module, b"api": self.api}))

    def replace(self, address, data):
        for start, original in self.memory.items():
            offset = int(address) - start
            if 0 <= offset and offset + len(data) <= len(original):
                self.memory[start] = original[:offset] + data + original[offset + len(data):]
                return
        raise AssertionError("write outside an existing native record")

    def change(self, address, data):
        self.writes.append((address, data))
        if self.fail_write == len(self.writes):
            return False
        self.replace(address, data)
        return True

    def publish(self, network, field, address):
        self.events.append(("publish", network, field, self.read(address, 4)))

    def fire(self, manager, eid, value):
        self.events.append(("fire", manager, eid, value))
        self.replace(0x27000000, struct.pack("<I", value))

    def remember(self, manager, eid, action, value):
        self.events.append(("remember", manager, eid, action, value))

    def apply(self, target, expected=None):
        expected = expected if expected is not None else self.inspect()
        return self.controller[b"apply"](self.controller, self.reader, self.snapshot, b"right", target, expected)


class NativeDirectSelectionTests(unittest.TestCase):
    def test_final_slot_and_game_field_jump_to_third_without_a_second_value(self):
        for action, target in ((1, 150), (2, 1150), (3, 3)):
            with self.subTest(action=action):
                f = SelectionFixture(action)
                before = dict(f.memory)
                selected = f.apply(target)
                self.assertEqual((selected[b"slot"], selected[b"value"]), (2, target))
                actual = f.inspect()[b"directions"][b"right"]
                self.assertEqual((actual[b"slot"], actual[b"current"]), (2, target))
                self.assertEqual(f.events[-1], ("remember", f.manager, f.eid, action, target if action == 3 else 2))
                self.assertEqual(sum(event[0] == "publish" for event in f.events), 1)
                field = 0x4CBCC2A2 if action == 2 else 0x31F86165
                published = f.events[0]
                self.assertEqual(published[:3], ("publish", 57, field))
                if action == 2:
                    self.assertEqual(struct.unpack("<f", published[3])[0], target)
                    self.assertEqual(actual[b"effective_rpm"], target)
                    changed = {0x37000010, 0x38000004}
                else:
                    shift = 4 if action == 1 else 12
                    mask = struct.unpack("<I", published[3])[0]
                    self.assertEqual(mask, 0xA5000088 + (2 << shift))
                    self.assertEqual(struct.unpack("<I", f.read(0x27000008, 4))[0], 0x12345678)
                    changed = {0x27000000}
                for address, payload in before.items():
                    if address not in changed:
                        self.assertEqual(f.memory[address], payload, hex(address))

    def test_saved_float_precision_uses_exact_offered_rate_bytes(self):
        f=SelectionFixture(2)
        f.rpm(choices=(700,850,739.1304321289062),selected=0,effective=700)
        selected=f.apply(739.130432)
        self.assertEqual(selected[b'value'],739.1304321289062)
        self.assertEqual(f.events[0][3],struct.pack('<f',739.1304321289062))
        self.assertEqual(f.inspect()[b'directions'][b'right'][b'effective_rpm'],739.1304321289062)

    def test_unoffered_ambiguous_inactive_and_changed_values_never_write(self):
        for fault in ("unoffered", "duplicate", "inactive", "changed"):
            with self.subTest(fault=fault):
                f = SelectionFixture(3)
                expected = f.inspect()
                target = 99 if fault == "unoffered" else 3
                if fault == "duplicate":
                    f.write(f.definition + 0x90, "<III", 1, 1, 3)
                elif fault == "inactive":
                    f.write(0x27000000, "<III", 8, 1024, 0)
                elif fault == "changed":
                    f.write(0x27000000, "<III", 2, 1 << 12, 0)
                result = f.apply(target, expected)
                self.assertIsNone(result[0])
                self.assertFalse(f.writes or f.events)

    def test_code_identity_and_definition_races_reject_before_writes(self):
        for fault in ("code", "identity", "definition"):
            with self.subTest(fault=fault):
                f = SelectionFixture(1)
                expected = f.inspect()
                if fault == "code":
                    f.memory[f.game + 0xFD97E0] = b"\0" * 24
                else:
                    old_transaction = f.reader[b"transaction"]
                    def race(reader, callback, label=None):
                        if label == b"before-direct-weapon-selection":
                            if fault == "identity":
                                f.memory[f.entity] = bytes(24)
                            else:
                                f.write(f.manager + 0xB0, "<Q", f.definition + 0x1000)
                        return old_transaction(reader, callback)
                    f.reader[b"transaction"] = race
                result = f.apply(150, expected)
                self.assertIsNone(result[0])
                self.assertFalse(f.writes or f.events)

    def test_failed_commit_or_publisher_never_cycles_or_replays(self):
        for fault in ("write", "publish"):
            with self.subTest(fault=fault):
                f = SelectionFixture(2)
                if fault == "write":
                    f.fail_write = 2
                else:
                    f.api[b"publish"] = f.lua.eval(b"function()error('uncertain publish')end")
                result = f.apply(1150)
                self.assertIsNone(result[0])
                self.assertTrue(result[2])
                self.assertEqual(len(f.writes), 2)
                self.assertFalse(f.events)


if __name__ == "__main__":
    unittest.main()

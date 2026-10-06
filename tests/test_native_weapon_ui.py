"""Exercise the actual UI dirty-byte writer against canaries in this process.

No game process is opened, read, or written. The native reader's transaction
and the module's Windows WriteProcessMemory implementation are real. Only the
game identity/build boundary and anchor bytes are supplied locally. These tests establish write scope and rejection, not game behavior.
"""
from pathlib import Path
import ctypes
import os
import struct
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
GAME = 0x50000000
CARD = 0x257F78
FIELDS = CARD + 0xBCD0
ACTIVE_EID = 404


@unittest.skipUnless(os.name == "nt", "own-process Windows API ABI regression")
class NativeWeaponUICanary(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.ui = self.lua.execute((ROOT / "src/native_weapon_ui.lua").read_bytes())
        reader_module = self.lua.execute((ROOT / "src/native_equipment_reader.lua").read_bytes())
        self.root_buffer = ctypes.create_string_buffer(b"\xA5" * (FIELDS + 32), FIELDS + 32)
        self.context_buffer = ctypes.create_string_buffer(b"\x5A" * 0xAC230, 0xAC230)
        self.root_address = ctypes.addressof(self.root_buffer)
        self.context_address = ctypes.addressof(self.context_buffer)
        self.write_local(self.root_buffer, FIELDS, struct.pack("<BBBBII", 1, 0, 0xA5, 0xA5,
                                                            ACTIVE_EID, ACTIVE_EID))
        self.write_local(self.context_buffer, 0xAC21C, struct.pack("<I", 4))
        self.regions = {
            GAME + 0x346D538: struct.pack("<Q", self.root_address),
            GAME + 0x3326340: struct.pack("<Q", self.context_address),
        }
        for _, anchor in self.ui[b"anchors"].items():
            rva, expected = anchor[b"rva"], anchor[b"bytes"]
            self.regions[GAME + rva] = expected

        def read(address, size):
            data = self.regions.get(address)
            if data is not None:
                return data[:size] if size <= len(data) else None
            # This adapter only exposes our explicitly allocated local buffers.
            for buf, base in [(self.root_buffer, self.root_address),
                              (self.context_buffer, self.context_address)]:
                offset = int(address) - base
                if 0 <= offset and offset + size <= len(buf):
                    return buf.raw[offset:offset + size]
            return None

        api = self.lua.table()
        api[b"read"] = read
        self.reader = reader_module[b"new"](api)
        self.reader[b"game"] = GAME
        self.reader[b"verify"] = self.lua.eval(b"function() return true end")
        self.reader[b"guard_active"] = self.lua.eval(b"""function(self, snapshot)
            assert(snapshot.token == 'local-canary-identity')
            return {entity={eid=404},bytes=string.rep('E',24),entity_address=0x10000}
        end""")
        self.snapshot = self.lua.table_from({b"token": b"local-canary-identity"})

    @staticmethod
    def write_local(buffer, offset, data):
        ctypes.memmove(ctypes.addressof(buffer) + offset, data, len(data))

    def invalidate(self):
        return self.ui[b"invalidate"](self.reader, self.snapshot)

    def assert_only_dirty_byte_changed(self, before):
        expected = bytearray(before)
        expected[FIELDS + 1] = 1
        self.assertEqual(self.root_buffer.raw, bytes(expected))

    def test_real_writer_invalidates_hidden_card_and_preserves_all_other_bytes(self):
        before = self.root_buffer.raw
        context_before = self.context_buffer.raw
        result = self.invalidate()
        self.assertEqual(result[b"status"], b"invalidated")
        self.assertTrue(result[b"hidden"])
        self.assert_only_dirty_byte_changed(before)
        self.assertEqual(self.context_buffer.raw, context_before)


    def test_same_cached_weapon_but_wrong_display_is_rejected_without_writing(self):
        self.write_local(self.root_buffer, FIELDS + 8, struct.pack("<I", 439))
        before = self.root_buffer.raw
        result, reason = self.invalidate()
        self.assertIsNone(result)
        self.assertIn(b"display identity differs", reason)
        self.assertEqual(self.root_buffer.raw, before)

    def set_child_guard(self, selected):
        self.reader[b"guard_active"] = self.lua.eval(b'''function(self,snapshot)
            assert(snapshot.token == 'local-canary-identity')
            local child={entity={eid=405},bytes=string.rep('C',24)}
            return {entity={eid=404},bytes=string.rep('E',24),entity_address=0x10000,
                display_eid=self.child_selected and 405 or 404,
                display_child=self.child_selected and child or nil}
        end''')
        self.reader[b"child_selected"] = selected
        self.reader[b"guard_display_child"] = self.lua.eval(b'''function(self,snapshot,active,candidate)
            assert(candidate==405 and not self.invalid_attachment,'unverified attachment')
            return {entity={eid=405},bytes=string.rep('C',24)}
        end''')

    def test_verified_child_card_inspects_and_invalidates_parent_cache(self):
        self.set_child_guard(True)
        self.write_local(self.root_buffer, FIELDS + 8, struct.pack("<I", 405))
        info = self.ui[b"inspect"](self.reader, self.snapshot)
        self.assertEqual(info[b"cached_eid"], 404)
        self.assertEqual(info[b"display_eid"], 405)
        before = self.root_buffer.raw
        self.assertEqual(self.invalidate()[b"status"], b"invalidated")
        self.assert_only_dirty_byte_changed(before)


    def test_stale_child_after_module_replacement_does_not_write(self):
        self.set_child_guard(False)
        self.reader[b"invalid_attachment"] = True
        self.write_local(self.root_buffer, FIELDS + 8, struct.pack("<I", 405))
        before = self.root_buffer.raw
        value, error = self.invalidate()
        self.assertIsNone(value)
        self.assertIn(b"unverified attachment", error)
        self.assertEqual(self.root_buffer.raw, before)


if __name__ == "__main__":
    unittest.main()

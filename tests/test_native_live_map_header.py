"""Replay the actual avatar-map header read from live PID 25188.

This checks the pointer parser that rejected the v0.4.0 session. It does not
model or establish equipment behavior. No process or native game calls occur.
"""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

READER = (Path(__file__).resolve().parents[1] / "src/native_equipment_reader.lua").read_bytes()
AVATAR_MANAGER = 0x1B46660ABD8
HEADER_ADDRESS = AVATAR_MANAGER + 0xF8
LIVE_HEADER = bytes.fromhex("4cac6066b4010000100000000000000002000000")
LIVE_MAP_STORAGE = 0x1B46660AC4C


class NativeLiveMapHeader(unittest.TestCase):
    def test_live_avatar_inline_map_pointer_is_valid_at_four_mod_eight(self):
        lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        module = lua.execute(READER)
        reads = []

        def read(address, size):
            reads.append((address, size))
            if address == HEADER_ADDRESS and size == 8:
                return LIVE_HEADER[:8]
            return None

        api = lua.table()
        api[b"read"] = read
        reader = module[b"new"](api)
        # Narrow parser regression: module/build verification is outside this
        # captured-header test, and no live process adapter is instantiated.
        reader[b"verify"] = lua.eval(b"function() return true end")
        decode = lua.eval(b"""function(reader, address)
            return reader:transaction(function(read, ptr)
                return {storage=ptr(address)}
            end)
        end""")
        result = decode(reader, HEADER_ADDRESS)
        self.assertNotIsInstance(result, tuple, "actual live pointer must not be rejected")
        self.assertEqual(result[b"storage"], LIVE_MAP_STORAGE)
        self.assertEqual(result[b"storage"] % 8, 4)
        self.assertEqual(result[b"storage"], AVATAR_MANAGER + 0x74)


if __name__ == "__main__":
    unittest.main()

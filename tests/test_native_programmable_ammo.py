"""Captured-layout bounds/identity tests. These do not prove in-game application."""
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = (Path(__file__).resolve().parents[1] / "src/native_programmable_ammo.lua").read_bytes()


class Fixture:
    def __init__(self, *, slot=0, choices=(117, 243), override=True, functions=(8, 3, 0, 0)):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.module = self.lua.execute(SOURCE)
        self.memory = {}
        self.game = 0x10000000
        self.wm, self.pm, self.entity = 0x20000000, 0x21000000, 0x22000000
        self.runtime, self.state = 0x23000000, 0x24000000
        self.override_defs, self.registry = 0x25000000, 0x26000000
        self.eid, self.resource = 943, 0xF123456789ABCDEF
        self.entity_bytes = struct.pack("<QIIII", self.resource, self.eid, 557, 88, 0)
        self.memory[self.entity] = self.entity_bytes
        for _, anchor in self.module.anchors.items():
            self.memory[self.game + anchor.rva] = anchor.bytes
        self.write(self.game + 0x3326CE0, "<Q", self.wm)
        self.write(self.game + 0x33266D8, "<Q", self.pm)
        self.write(self.wm + 0x30, "<QIII", 1, 8, 0xFFFFFFFF, 1)
        self.write(self.wm + 0x48, "<Q", 0x27000000)
        self.write(0x27000000, "<Q", self.entity)
        self.write(self.wm + 0x58, "<Q", self.runtime)
        self.write(self.runtime + 0x350, "<IIII", *functions)
        self.write(self.wm + 0x60, "<Q", self.state)
        self.write(self.state + 4, "<I", (slot << 2) | (1 << 12))
        self.write(self.wm + 0x70, "<QIII", 4, 8, 0xFFFFFFFF, 1)
        self.write(self.wm + 0xB0, "<Q", 0x2A000000)
        self.write(0x2A000000 + 0x4B4, "<I", 0)
        self.write(self.pm + 0x50, "<QIII", 2, 8, 0xFFFFFFFF, 1)
        self.write(self.pm + 0x68, "<Q", 0x28000000)
        self.write(0x28000000, "<Q", self.entity)
        self.write(self.pm + 0x90, "<QIII", 3, 8 if override else 0, 0xFFFFFFFF, 1)
        self.write(self.pm + 0xD0, "<Q", self.override_defs)
        self.definition = self.override_defs + 0x268
        if not override:
            self.write(self.game + 0x346BF98, "<Q", 0x29000000)
            self.write(0x29000000 + 0xF12E80, "<Q", self.registry)
            self.buckets = bytearray(0x21E0)
            self.first = self.resource % 0x21E
            struct.pack_into("<QII", self.buckets, self.first * 16, self.resource, 13, 0)
            self.memory[self.registry] = self.buckets
            self.definition = self.registry + 0x21E0 + 13 * 0x268
        self.write(self.definition, "<I", choices[0])
        self.write(self.definition + 0x240, "<I", choices[1])
        setup = self.lua.eval(b'''function(read_bytes, game, entity_bytes, eid)
            local snapshot={active_weapon_verified=true,
                active_weapon={entity={eid=eid},bytes=entity_bytes}}
            local reader={game=game}
            local function u32(s,o)
              local a,b,c,d=s:byte(o+1,o+4); return a+b*256+c*65536+d*16777216
            end
            function reader:guard_active(s) return s.active_weapon end
            function reader:transaction(callback)
              local function read(a,n)
                local s=read_bytes(a,n); assert(s and #s==n,'fixture unavailable read')
                return s
              end
              local function ptr(a) local s=read(a,8); return u32(s,0)+u32(s,4)*4294967296 end
              local function lookup(header,key)
                if u32(header,8)==0 then return nil end
                assert(key==eid,'fixture wrong entity lookup')
                return u32(header,0)==3 and 1 or 0
              end
              local ok,value=pcall(callback,read,ptr,lookup)
              if ok then return value end
              return nil,tostring(value)
            end
            return reader,snapshot
        end''')
        self.reader, self.snapshot = setup(self.read, self.game, self.entity_bytes, self.eid)

    def write(self, address, fmt, *values):
        self.memory[address] = struct.pack(fmt, *values)

    def read(self, address, length):
        for start, data in self.memory.items():
            if start <= address and address + length <= start + len(data):
                return bytes(data[address - start:address - start + length])
        return None

    def inspect(self, expected=None):
        result = self.module.inspect(self.reader, self.snapshot, expected)
        if isinstance(result, tuple):
            return result
        return result, None


class AmmoTests(unittest.TestCase):
    def test_both_slots_read_actual_projectile_enums(self):
        for slot in (0, 1):
            with self.subTest(slot=slot):
                f = Fixture(slot=slot)
                value, reason = f.inspect()
                self.assertIsNone(reason)
                self.assertEqual(value.slot, slot)
                self.assertEqual(value.current, (117, 243)[slot])
                self.assertEqual([value.choices[i] for i in (1, 2)], [117, 243])
                self.assertTrue(value.cycle_supported)
                self.assertTrue(value.capture_supported)
                self.assertEqual(value.definition_source, b"instance_override")

    def test_resource_fallback_keeps_all_hash_bits(self):
        f = Fixture(override=False)
        value, reason = f.inspect()
        self.assertIsNone(reason)
        self.assertEqual(value.definition_source, b"native_resource_fallback")
        self.assertEqual(value.definition_address, f.definition)


    def test_unknown_binary_slot_and_out_of_range_enum_fail(self):
        for f in (Fixture(slot=2), Fixture(slot=3), Fixture(choices=(351, 3)), Fixture(choices=(1, 0xFFFFFFFF))):
            value, reason = f.inspect()
            self.assertIsNone(value)
            self.assertIsNotNone(reason)


    def test_different_native_entity_fails_full_identity_check(self):
        f = Fixture()
        f.write(0x28000000, "<Q", 0x30000000)
        f.memory[0x30000000] = struct.pack("<QIIII", f.resource, f.eid, 999, 88, 0)
        value, reason = f.inspect()
        self.assertIsNone(value)
        self.assertIn(b"identity", reason)


    def test_unreadable_override_fails_instead_of_base_fallback(self):
        f = Fixture()
        del f.memory[f.definition]
        self.assertIsNone(f.inspect()[0])

    def test_cycle_dependency_failure_preserves_readable_save_state(self):
        f = Fixture()
        del f.memory[0x2A000000 + 0x4B4]
        value, reason = f.inspect()
        self.assertIsNone(reason)
        self.assertTrue(value.readable)
        self.assertTrue(value.capture_supported)
        self.assertFalse(value.cycle_supported)
        self.assertIn(b"cycle dependency", value.reason)


if __name__ == "__main__":
    unittest.main()

"""Read-only binding snapshots with the production NativeReader transaction.

Fixtures verify parsing and rejection, not live engine activation. Anchors are
also checked against the existing original-code capture when it is available.
"""
from collections import Counter
from pathlib import Path
import os
import struct
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
GAME, OWNER, BUCKETS = 0x50000000, 0x123450000, 0x223450000
CODE = 10 * 65536
CAPTURE = Path(os.environ.get("LOCALAPPDATA", "")) / (
    "CowboyBingus/Helldivers2/Logs/WeaponModesNative-20260926-192554-3280/section-01-rva-00001000.bin")


def mapping(button=9, device=3, kind=4, trigger=0, device_index=255, combine=0, auxiliary=58):
    flags = device | kind << 4 | device_index << 8 | trigger << 16 | button << 20
    return struct.pack("<IHHIII", flags, auxiliary, 0xA5A5, trigger, combine, 0)


class Fixture:
    def __init__(self, code=CODE, mappings=None, slot=None, multiplier=2654435761):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.module = self.lua.execute((ROOT / "src/native_mod_bindings.lua").read_bytes())
        reader_module = self.lua.execute((ROOT / "src/native_equipment_reader.lua").read_bytes())
        self.code, self.calls = code, Counter()
        self.owner_pointer = bytearray(struct.pack("<Q", OWNER))
        self.header = bytearray(struct.pack("<QIII", BUCKETS, 256, 0xFFFFFFFF, multiplier))
        self.buckets = bytearray(b"\xFF" * (256 * 328))
        self.slot = slot if slot is not None else (code * multiplier) % 256
        self.bucket = BUCKETS + self.slot * 328
        self.set_bucket(code, [mapping()] if mappings is None else mappings)
        self.regions = {GAME + 0x347CF18: self.owner_pointer, OWNER + 686800: self.header,
                        BUCKETS: self.buckets}
        for anchor in self.module[b"anchors"].values():
            self.regions[GAME + anchor[b"rva"]] = anchor[b"bytes"]
        self.hook = None

        def read(address, size):
            self.calls[(address, size)] += 1
            if self.hook:
                replacement = self.hook(address, size, self.calls[(address, size)])
                if replacement is not False:
                    return replacement
            for base, data in self.regions.items():
                offset = int(address) - base
                if 0 <= offset and offset + size <= len(data):
                    return bytes(data[offset:offset + size])
            return None

        self.reader = reader_module[b"new"](self.lua.table_from({b"read": read}))
        self.reader[b"game"] = GAME
        self.reader[b"verify"] = self.lua.eval(b"""function(self)
            self.verifications=(self.verifications or 0)+1
            if self.reject_build then return nil,'unsupported game.dll SHA256' end
            if self.verify_error then error('module identity unavailable') end
            return true
        end""")
        self.reader[b"guard_active"] = self.lua.eval(b"function() error('weapon gate must not run') end")

    def set_bucket(self, code, mappings):
        data = struct.pack("<II", code, len(mappings)) + b"".join(mappings)
        self.buckets[self.slot * 328:(self.slot + 1) * 328] = data.ljust(328, b"\0")

    def inspect(self, code=None):
        return self.module[b"inspect"](self.reader, self.code if code is None else code)


class NativeModBindingsTests(unittest.TestCase):
    def test_game_event_reads_engine_byte_with_own_mapping_and_no_mutation(self):
        f=Fixture()
        previous=f.inspect()
        address=OWNER+808+32*(97*10)
        state=bytearray(b'\0');f.regions[address]=state
        before=(bytes(f.owner_pointer),bytes(f.header),bytes(f.buckets))
        for byte,expected in ((0,False),(1,True),(255,True),(0,False)):
            state[0]=byte
            result=f.module[b'event'](f.reader,previous)
            self.assertEqual(result[b'game_event'],expected)
            self.assertEqual(result[b'signature'],previous[b'signature'])
        self.assertEqual(before,(bytes(f.owner_pointer),bytes(f.header),bytes(f.buckets)))

    def test_game_event_is_unknown_when_state_unreadable_or_changes_in_transaction(self):
        f=Fixture();previous=f.inspect()
        address=OWNER+808+32*(97*10)
        self.assertIsNone(f.module[b'event'](f.reader,previous)[0])
        f.regions[address]=b'\1';f.calls.clear()
        f.hook=lambda a,n,c: b'\0' if a==address and c==2 else False
        self.assertIsNone(f.module[b'event'](f.reader,previous)[0])


    def failure(self, fixture, text, code=None):
        value, reason = fixture.inspect(code)
        self.assertIsNone(value)
        self.assertIn(text.encode(), reason)

    def test_real_logged_tab_record_uses_packed_input_id_not_adjacent_word(self):
        # Existing MBM log independently prints Keyboard.button_id('tab')=9.
        raw = bytes.fromhex("43FF90003A000000000000000000000000000000")
        f = Fixture(mappings=[raw])
        value = f.inspect()
        row = value[b"mappings"][1]
        self.assertEqual((row[b"device"], row[b"input_kind"], row[b"button_id"], row[b"auxiliary_id"]),
                         (3, 4, 9, 58))
        self.assertTrue(row[b"simple_button"])
        self.assertEqual(row[b"raw"], raw)
        self.assertFalse(value[b"unbound"])
        self.assertEqual(value[b"count"], 1)

    def test_real_logged_mouse_record_uses_device4_button0(self):
        f = Fixture(mappings=[bytes.fromhex("44FF000020000000000000000000000000000000")])
        row = f.inspect()[b"mappings"][1]
        self.assertEqual((row[b"device"], row[b"button_id"], row[b"auxiliary_id"]), (4, 0, 32))
        self.assertTrue(row[b"simple_button"])


    def test_zero_count_is_unbound_only_for_verified_existing_bucket(self):
        f = Fixture(mappings=[])
        result = f.inspect()
        self.assertTrue(result[b"unbound"])
        self.assertEqual(result[b"count"], 0)
        self.assertEqual(len(result[b"mappings"]), 0)
        self.assertEqual(len(result[b"signature"]), 16)


    def test16_mappings_accepted_and17_refused_without_reading_outside_bucket(self):
        f = Fixture(mappings=[mapping(i) for i in range(16)])
        self.assertEqual(f.inspect()[b"count"], 16)
        struct.pack_into('<I', f.buckets, f.slot * 328 + 4, 17)
        self.failure(f, 'count exceeds 16')


    def test_supported_press_hold_and_other_native_triggers_preserve_raw_enums(self):
        f = Fixture(mappings=[mapping(trigger=i) for i in range(9)])
        result = f.inspect()
        for i in range(9):
            row = result[b"mappings"][i + 1]
            self.assertEqual((row[b"trigger"], row[b"trigger_flags"]), (i, i))
            self.assertTrue(row[b"simple_button"])


    def test_composite_modifier_never_exposes_terminal_or_unrelated_key_as_independent(self):
        for combine in (1, 2, 0xFFFFFFFF):
            result = Fixture(mappings=[mapping(17, combine=combine), mapping(80), mapping(75)]).inspect()
            self.assertTrue(result[b"composite"])
            self.assertTrue(all(not row[b"simple_button"] for row in result[b"mappings"].values()))
            self.assertFalse(result[b"unbound"])


    def test_watch_compaction_fails_cache_and_full_inspect_reacquires(self):
        f = Fixture()
        previous = f.inspect()
        f.buckets[328:656] = f.buckets[:328]
        struct.pack_into('<I', f.buckets, 0, 0xFFFFFFFF)
        value, reason = f.module[b"watch"](f.reader, previous)
        self.assertIsNone(value)
        self.assertIn(b'watched bucket moved', reason)
        self.assertEqual(f.inspect()[b"bucket"], BUCKETS+328)


    def test_verify_exception_and_anchor_mismatch_fail_closed(self):
        f = Fixture()
        f.reader[b"verify_error"] = True
        self.failure(f, 'module identity unavailable')
        f = Fixture()
        first = f.module[b"anchors"][1]
        f.regions[GAME + first[b"rva"]] = bytes(len(first[b"bytes"]))
        self.failure(f, 'code anchor mismatch')


if __name__ == '__main__':
    unittest.main()

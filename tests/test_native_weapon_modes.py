"""Binary-reader boundary checks, not evidence of live equip correctness.

Offsets come from the captured native instructions documented in
analysis/native-mode-handlers-192554.md. No process or input API is used.
"""
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = (Path(__file__).resolve().parents[1] / "src/native_weapon_modes.lua").read_bytes()


class ReaderFixture:
    def __init__(self, *, override=True, functions=(0, 3, 1, 5), fire=3,
                 fire_slot=1, scope=(25, 75, 150), scope_slot=2):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.module = self.lua.execute(SOURCE)
        self.memory = {}
        self.game, self.manager, self.entity = 0x10000000, 0x20000000, 0x21000000
        self.definition = 0x23000000
        self.resource = 0xF123456789ABCDEF  # beyond exact Lua double integers
        self.eid = 321
        self.entity_bytes = struct.pack("<QIIII", self.resource, self.eid, 741, 57, 0)
        self.write(self.game + 0x3326CE0, "<Q", self.manager)
        self.write(self.manager + 0x30, "<QIII", 0x24000000, 8, 0xFFFFFFFF, 1)
        self.write(self.manager + 0x48, "<Q", 0x25000000)
        self.write(0x25000000, "<Q", self.entity)
        self.memory[self.entity] = self.entity_bytes
        self.write(self.manager + 0x58, "<Q", 0x26000000)
        self.write(0x26000350, "<IIII", *functions)
        self.write(self.manager + 0x60, "<Q", 0x27000000)
        self.write(0x27000000, "<III", fire, (fire_slot << 12) | (scope_slot << 4), 0)
        self.write(self.manager + 0x70, "<QIII", 0x28000000, 8 if override else 0, 0xFFFFFFFF, 1)
        self.write(self.manager + 0xB0, "<Q", self.definition)
        if not override:
            owner, registry = 0x30000000, 0x32000000
            self.write(self.game + 0x346BF98, "<Q", owner)
            self.write(owner + 0xF12BD8, "<Q", registry)
            buckets = bytearray(730 * 16)
            struct.pack_into("<QII", buckets, (self.resource % 730) * 16, self.resource, 17, 0)
            self.memory[registry] = bytes(buckets)
            self.definition = registry + 730 * 16 + 17 * 0x4D0
        self.write(self.definition + 0x90, "<III", 2, 3, 0)
        self.write(self.definition + 0x154, "<fff", *scope)
        constructor = self.lua.eval(b"""function(read_bytes, game, entity_bytes, eid)
            local snapshot={active_weapon_verified=true,
                active_weapon={entity={eid=eid},bytes=entity_bytes}}
            local reader={game=game}
            function reader:guard_active(s) return s.active_weapon end
            function reader:transaction(callback)
                local function read(address,n)
                    local bytes=read_bytes(address,n)
                    assert(type(bytes)=='string' and #bytes==n,'fixture read unavailable')
                    return bytes
                end
                local function ptr(address)
                    local b=read(address,8)
                    local result=0
                    for i=8,1,-1 do result=result*256+b:byte(i) end
                    return result
                end
                local ok,result=pcall(callback,read,ptr,function() return 0 end)
                if not ok then return nil,result end
                return result
            end
            return reader,snapshot
        end""")
        self.reader, self.snapshot = constructor(self.read, self.game, self.entity_bytes, self.eid)

    def write(self, address, fmt, *values):
        self.memory[address] = struct.pack(fmt, *values)

    def read(self, address, size):
        for start, data in self.memory.items():
            offset = int(address) - start
            if 0 <= offset and offset + size <= len(data):
                return data[offset:offset + size]
        raise ValueError(f"unexpected fixture read {address:x}+{size}")

    def inspect(self):
        return self.module[b"inspect"](self.reader, self.snapshot)

    def rpm(self, choices=(700, 850, 1150), selected=2, effective=900):
        pm = 0x34000000
        self.write(self.game + 0x33266D8, "<Q", pm)
        self.write(pm + 0x50, "<QIII", 0x35000000, 8, 0xFFFFFFFF, 1)
        self.write(pm + 0x68, "<Q", 0x36000000)
        self.write(0x36000000, "<Q", self.entity)
        self.write(pm + 0x70, "<Q", 0x37000000)
        self.write(0x37000010, "<fffI", *choices, selected)
        self.write(pm + 0x80, "<Q", 0x38000000)
        self.write(0x38000004, "<f", effective)


class NativeModeReaderBoundaries(unittest.TestCase):
    def test_secondary_fire_keeps_ordinary_slot_but_does_not_report_it_selected(self):
        fixture=ReaderFixture(functions=(11,3,1,5),fire=8,fire_slot=1)
        fixture.write(0x27000000,'<III',8,(1<<10)|(1<<12)|(2<<4),0)
        directions=fixture.inspect()[b'directions']
        self.assertEqual(directions[b'left'][b'kind'],b'secondary_fire')
        right=directions[b'right']
        self.assertTrue(right[b'inactive'])
        self.assertFalse(right[b'readable'])
        self.assertFalse(right[b'cycle_supported'])
        self.assertIsNone(right[b'current'])
        self.assertEqual(right[b'slot'],1)
        self.assertTrue(directions[b'up'][b'readable'])


    def test_current_instance_scope_values_and_direction_order(self):
        fixture = ReaderFixture()
        result = fixture.inspect()
        directions = result[b"directions"]
        self.assertEqual(directions[b"right"][b"current"], 3)
        self.assertEqual(directions[b"up"][b"current"], 150)
        self.assertTrue(directions[b"up"][b"cycle_supported"])
        self.assertEqual(directions[b"down"][b"action_enum"], 5)
        self.assertFalse(directions[b"down"][b"readable"])
        self.assertIsNone(directions[b"down"][b"current"])

    def test_no_optic_never_becomes_previous_scope_default(self):
        fixture = ReaderFixture(functions=(0, 3, 0, 0), scope=(0, 0, 0))
        up = fixture.inspect()[b"directions"][b"up"]
        self.assertFalse(up[b"present"])
        self.assertFalse(up[b"readable"])
        self.assertIsNone(up[b"current"])


    def test_rpm_uses_real_selected_choice_and_keeps_effective_value_separate(self):
        fixture = ReaderFixture(functions=(0, 2, 0, 0), fire=1, fire_slot=0, scope=(0, 0, 0))
        fixture.rpm()
        rpm = fixture.inspect()[b"directions"][b"right"]
        self.assertEqual(rpm[b"current"], 1150)
        self.assertEqual(rpm[b"effective_rpm"], 900)
        self.assertTrue(rpm[b"cycle_supported"])


    def test_mismatched_registry_entity_rejected(self):
        fixture = ReaderFixture()
        fixture.memory[fixture.entity] = bytes(24)
        result, reason = fixture.inspect()
        self.assertIsNone(result)
        self.assertIn(b"identity differs", reason)


    def test_bad_scope_float_does_not_hide_readable_fire_or_offered_flashlight(self):
        fixture = ReaderFixture()
        fixture.write(fixture.definition + 0x154, "<fff", 25, 75, float("nan"))
        directions = fixture.inspect()[b"directions"]
        self.assertFalse(directions[b"up"][b"readable"])
        self.assertIsNone(directions[b"up"][b"current"])
        self.assertIn(b"non-finite", directions[b"up"][b"reason"])
        self.assertEqual(directions[b"right"][b"current"], 3)
        self.assertTrue(directions[b"down"][b"present"])


class NativeBinary10Contract(unittest.TestCase):
    """C4 native modes/capture/icons share one guarded current-instance reader."""

    def fixture(self, slot=0):
        f=ReaderFixture(functions=(10,0,0,0),fire=0)
        for _,anchor in f.module[b'binary10_anchors'].items():
            f.memory[f.game+anchor[b'rva']]=anchor[b'bytes']
        owner,registry=0x30000000,0x32000000
        f.write(f.game+0x346BF98,'<Q',owner)
        f.write(owner+0xF12CD0,'<Q',registry)
        buckets=bytearray(18*16)
        # Collision probing must compare all resource bits, not a rounded Lua
        # number, and must not accidentally use the neighbouring definition.
        start=f.resource%18
        struct.pack_into('<QII',buckets,start*16,f.resource^0x8000000000000000,2,0)
        struct.pack_into('<QII',buckets,((start+1)%18)*16,f.resource,7,0)
        f.memory[registry]=bytes(buckets)
        record=bytearray(0x58)
        struct.pack_into('<Q',record,0x18,0x38ADABC6A32AF014)
        struct.pack_into('<Q',record,0x40,0x55374383474193F8)
        f.binary_definition=registry+0x120+7*0x58
        f.memory[f.binary_definition]=bytes(record)
        f.write(0x27000000,'<III',0,slot<<8,0)
        return f

    def test_both_slots_capture_complement_and_actual_saved_selected_icons(self):
        root=Path(__file__).resolve().parents[1]
        for slot in (0,1):
            with self.subTest(slot=slot):
                f=self.fixture(slot);before=dict(f.memory);modes=f.inspect()
                direction=modes[b'directions'][b'left']
                self.assertEqual((direction[b'kind'],direction[b'current'],direction[b'slot']),
                                 (b'binary_10',slot,slot))
                capture=f.lua.execute((root/'src/weapon_defaults_capture.lua').read_bytes())
                plan=capture[b'single_setting'](modes)
                self.assertTrue(plan[b'qualified']);self.assertEqual(plan[b'count'],2)
                presets,_=capture[b'seed'](modes)
                self.assertEqual(presets[1][b'targets'][b'left'][b'value'],slot)
                self.assertEqual(presets[2][b'targets'][b'left'][b'value'],1-slot)
                self.assertEqual(len(list(presets[3][b'targets'].keys())),0)
                icons=f.lua.execute((root/'src/native_weapon_hud_icons.lua').read_bytes())
                for _,anchor in icons[b'anchors'].items():
                    f.memory[f.game+anchor[b'rva']]=anchor[b'bytes']
                helper=f.lua.table_from({b'weapon_modes':f.module})
                offered=icons[b'choice_icons'](f.reader,f.snapshot,modes,helper)[b'left']
                self.assertEqual(offered[0][b'hash_hex'],b'38adabc6a32af014')
                self.assertEqual(offered[1][b'hash_hex'],b'55374383474193f8')
                selected=icons[b'inspect'](f.reader,f.snapshot,modes,helper,b'left')[b'directions'][b'left']
                self.assertEqual(selected[b'hash_hex'],offered[slot][b'hash_hex'])
                self.assertEqual(selected[b'label_message'],(b'mode.c4_deploy',b'mode.c4_detonate')[slot])
                # Static code fixtures were the only additions to fake memory.
                for address,value in before.items(): self.assertEqual(f.memory[address],value)

    def test_invalid_or_failed_reads_never_capture_or_invent_a_mode(self):
        root=Path(__file__).resolve().parents[1]
        for fault in ('slot2','slot3','definition','code','identity'):
            with self.subTest(fault=fault):
                f=self.fixture()
                if fault.startswith('slot'): f.write(0x27000000,'<III',0,int(fault[-1])<<8,0)
                elif fault=='definition': del f.memory[f.binary_definition]
                elif fault=='code': del f.memory[f.game+0x755F1A]
                else: f.memory[f.entity]=b'\0'*24
                modes=f.inspect()
                if fault=='identity': self.assertIsNone(modes[0]);continue
                direction=modes[b'directions'][b'left']
                self.assertFalse(direction[b'readable']);self.assertIsNone(direction[b'current'])
                capture=f.lua.execute((root/'src/weapon_defaults_capture.lua').read_bytes())
                self.assertIsNone(capture[b'single_setting'](modes)[0])
                self.assertEqual(len(list(capture[b'capture'](modes)[0].keys())),0)


if __name__ == "__main__":
    unittest.main()

"""UI gate boundaries with real reader transactions and supplied anchor fixtures.

No game process or input is used. These tests validate decoding, rejection,
and repeated-read consistency; they do not replace the mission check.
"""
from pathlib import Path
import os
import struct
import unittest

from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
GAME,UI,INPUT=0x50000000,0x60000000,0x70000000


class NativePresetInputGate(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True,encoding=None)
        self.gate=self.lua.execute((ROOT/'src/native_preset_input_gate.lua').read_bytes())
        reader_module=self.lua.execute((ROOT/'src/native_equipment_reader.lua').read_bytes())
        self.fields=bytearray(0x90)
        self.mask=0
        self.reads=[]
        self.mutate_after=None
        self.regions={GAME+0x347ce28:struct.pack('<Q',UI),GAME+0x347cf18:struct.pack('<Q',INPUT)}
        for _,a in self.gate[b'anchors'].items():
            rva,data=a[b'rva'],a[b'bytes']
            self.regions[GAME+rva]=data
        def read(address,size):
            self.reads.append((address,size))
            if self.mutate_after and len(self.reads)==self.mutate_after:
                self.put(0,1)
            if address==UI+0x4294:return bytes(self.fields[:size])
            if address==INPUT+0xa7c1c:return struct.pack('<I',self.mask)[:size]
            data=self.regions.get(address)
            return data[:size] if data is not None and len(data)>=size else None
        self.reader=reader_module[b'new'](self.lua.table_from({b'read':read}))
        self.reader[b'game']=GAME
        self.reader[b'verify']=self.lua.eval(b'function()return true end')
        self.reader[b'guard_active']=self.lua.eval(b'''function(self,snapshot)
            assert(snapshot.identity=='actual-weapon','unverified weapon')
            return {}
        end''')
        self.snapshot=self.lua.table_from({b'identity':b'actual-weapon'})

    def put(self,offset,value):struct.pack_into('<I',self.fields,offset,value)
    def inspect(self):return self.gate[b'inspect'](self.reader,self.snapshot)

    def test_gameplay_no_screens_popups_or_chat_is_allowed(self):
        result=self.inspect()
        self.assertTrue(result[b'allowed'])
        self.assertIsNone(result[b'reason'])
        self.assertEqual(self.reads.count((UI+0x4294,0x90)),2)
        self.assertEqual(self.reads.count((INPUT+0xa7c1c,4)),2)

    def test_chat_keyboard_block_is_rejected_even_without_screen(self):
        self.mask=8
        result=self.inspect()
        self.assertFalse(result[b'allowed'])
        self.assertTrue(result[b'keyboard_blocked'])
        self.assertIn(b'chat',result[b'reason'])

    def test_any_current_or_pending_native_screen_is_rejected(self):
        for offset in (0,4):
            for value in (1,5,14,15,20,26,52):
                with self.subTest(offset=offset,value=value):
                    self.fields=bytearray(0x90);self.put(offset,value)
                    self.assertFalse(self.inspect()[b'allowed'])

    def test_remaining_stack_or_popup_also_blocks(self):
        for offset,value in ((0x1c,1),(0x1c,5),(0x84,1),(0x84,25),(0x8c,1)):
            with self.subTest(offset=offset):
                self.fields=bytearray(0x90);self.put(offset,value)
                self.assertFalse(self.inspect()[b'allowed'])


    def test_screen_change_during_revalidation_is_not_allowed(self):
        # Eight anchors + UI root + fields + input root + mask, then repeat.
        self.mutate_after=13
        result,why=self.inspect()
        self.assertIsNone(result);self.assertIn(b'changed',why)

    def context(self):return self.gate[b'context'](self.reader)


    def test_profile_context_preserves_all_screen_popup_and_chat_gates(self):
        for offset,value,reason in ((0,26,b'screen'),(4,1,b'screen'),(0x1c,1,b'screen'),
                                    (0x84,1,b'popup'),(0x8c,1,b'popup')):
            self.fields=bytearray(0x90);self.put(offset,value)
            result=self.context()
            self.assertFalse(result[b'allowed']);self.assertIn(reason,result[b'reason'])
        self.fields=bytearray(0x90);self.mask=8
        result=self.context();self.assertFalse(result[b'allowed']);self.assertTrue(result[b'keyboard_blocked'])


if __name__=='__main__':unittest.main()

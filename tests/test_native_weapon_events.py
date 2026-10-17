"""Native game API forwarding runs only in this private Python process.

This verifies Windows ABI/notifications; it is not HD2 mission acceptance.
"""
from pathlib import Path
import ctypes as C
import json
import os
import struct
import threading
import unittest

from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
TEST_DLL=ROOT/'analysis/events-native-20261017/weaponflow-events-test.dll'
U=C.c_uint32
P=C.c_size_t


class Event(C.Structure):
    _fields_=[('sequence',C.c_uint64),*( (n,U) for n in
              ('kind','action','flags','before_eid','eid','alternate')),
             ('slots',U*3),*((n,U) for n in ('before_holder','holder','before_light','light')),
             *((n,C.c_ubyte*24) for n in ('avatar','weapon','module'))]


class NativeMemory:
    def __init__(self):
        self.storage=[]
        self.game=self.alloc(0x3484000)
        self.owner=self.alloc(0xf34000)
        self.set_ptr(self.game+0x346bf98,self.owner)
        resource=bytes.fromhex('97fa4d294d331c4d')
        identities=[resource+struct.pack('<4I',100,200,300,1)]
        identities += [bytes([n])*8+struct.pack('<4I',n,n+100,n+200,1) for n in (10,11,90,77,78)]
        self.identities={100:identities[0],**dict(zip((10,11,90,77,78),identities[1:]))}
        self.entity={key:self.owner+0xf32f18+i*24 for i,key in enumerate(self.identities)}
        for key,address in self.entity.items():self.put(address,self.identities[key])
        self.table(self.owner+0xf1aeb0,dict(zip(self.identities,range(6))))
        self.table(self.owner+0xf22ec8,{300:0,210:1,211:2,290:3,277:4,278:5})
        self.player=self.alloc(0x400);self.set_ptr(self.game+0x3326468,self.player)
        self.put(self.player+0x84,struct.pack('<II',1,1))
        self.set_ptr(self.player+0xe8,self.entity[100]);self.set_u32(self.player+0x3a8,300)
        self.wielder=self.alloc(0x100);self.set_ptr(self.game+0x3326420,self.wielder)
        self.table(self.wielder+0x30,{100:0});self.set_u32(self.wielder+0x18,1)
        self.selection=self.alloc(0x1d0);self.set_ptr(self.wielder+0x60,self.selection)
        self.set_ptr(self.wielder+0x48,self.pointers([self.entity[100]]))
        self.equipment=self.alloc(0x100);self.set_ptr(self.game+0x3326738,self.equipment)
        self.table(self.equipment+0x28,{100:0})
        self.inventory=self.alloc(48);self.put(self.inventory,struct.pack('<5I',10,11,0,0,90))
        self.set_ptr(self.equipment+0x50,self.inventory)
        self.set_ptr(self.equipment+0x40,self.pointers([self.entity[100]]))
        self.holder=self.alloc(0x100);self.set_ptr(self.game+0x3326dc0,self.holder)
        self.table(self.holder+0x20,{10:0,11:1});self.holder_rows=self.alloc(96)
        self.set_ptr(self.holder+0x40,self.holder_rows)
        self.set_ptr(self.holder+0x38,self.pointers([self.entity[10],self.entity[11]]))
        self.parts=self.alloc(0x300);self.set_ptr(self.game+0x3326a38,self.parts)
        for offset,value in ((0x258,4),(0x264,2),(0x268,2)):self.set_u32(self.parts+offset,value)
        self.table(self.parts+0x278,{10:0,11:1})
        self.part_rows=self.alloc(256);self.set_ptr(self.parts+0x2a0,self.part_rows)
        self.set_ptr(self.parts+0x290,self.pointers([self.entity[10],self.entity[11]]))
        self.set_u32(self.part_rows+0x64,77);self.set_u32(self.part_rows+128+0x64,78)
        self.lights=self.alloc(0x100);self.set_ptr(self.game+0x3326910,self.lights)
        for offset,value in ((8,4),(0x10,2),(0x14,2)):self.set_u32(self.lights+offset,value)
        self.table(self.lights+0x28,{77:0,78:1})
        self.light_rows=self.alloc(16);self.set_ptr(self.lights+0x50,self.light_rows)
        self.set_ptr(self.lights+0x40,self.pointers([self.entity[77],self.entity[78]]))
        self.weapon_data=self.alloc(0x100);self.projectile=self.alloc(0x100);self.guide=self.alloc(0x100)
        self.mode_rows=self.alloc(24);self.rate_rows=self.alloc(24);self.guide_rows=self.alloc(2)
        for global_,manager,map_,owners,rows,storage in (
            (0x3326ce0,self.weapon_data,0x30,0x48,0x60,self.mode_rows),
            (0x33266d8,self.projectile,0x50,0x68,0x80,self.rate_rows),
            (0x3326960,self.guide,0x30,0x48,0x60,self.guide_rows)):
            self.set_ptr(self.game+global_,manager);self.table(manager+map_,{10:0,11:1})
            self.set_ptr(manager+owners,self.pointers([self.entity[10],self.entity[11]]))
            self.set_ptr(manager+rows,storage)
        self.reset()

    def alloc(self,n):
        buffer=C.create_string_buffer(n);self.storage.append(buffer);return C.addressof(buffer)

    def put(self,address,bytes_):C.memmove(address,bytes_,len(bytes_))
    def set_ptr(self,address,value):self.put(address,struct.pack('<Q',value))
    def set_u32(self,address,value):self.put(address,struct.pack('<I',value))
    def pointers(self,values):
        address=self.alloc(len(values)*8);self.put(address,struct.pack('<'+'Q'*len(values),*values));return address

    def table(self,address,values):
        slots=[[0xffffffff,0xffffffff] for _ in range(8)]
        for key,value in values.items():
            at=key&7
            while slots[at][0]!=0xffffffff:at=(at+1)&7
            slots[at]=[key,value]
        entries=self.alloc(64);self.put(entries,b''.join(struct.pack('<II',*row) for row in slots))
        self.put(address,struct.pack('<QIII',entries,8,0xffffffff,1))

    def reset(self):
        for key,address in self.entity.items():self.put(address,self.identities[key])
        self.put(self.selection,struct.pack('<II',10,0))
        self.set_u32(self.holder_rows+4,100);self.set_u32(self.holder_rows+48+4,100)
        self.set_u32(self.light_rows+4,2);self.set_u32(self.light_rows+12,0)
        self.set_u32(self.part_rows+0x64,77)
        self.set_u32(self.player+0x3a8,300)
        self.put(self.mode_rows,bytes(24));self.put(self.rate_rows,bytes(24));self.put(self.guide_rows,bytes(2))



@unittest.skipUnless(os.name=='nt' and TEST_DLL.is_file(),'build the separate native test helper first')
class NativeObserver(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from build_native_events import source_digest
        metadata=json.loads(TEST_DLL.with_suffix('.json').read_text(encoding='utf-8'))
        assert metadata['source_sha256']==source_digest(), 'native test helper is stale; rebuild with --test'
        cls.memory=NativeMemory();cls.dll=C.WinDLL(str(TEST_DLL));dll=cls.dll
        for name,args,result in (
            ('WF_Init',[P],C.c_int),('WF_TestInstall',[P],C.c_int),('WF_InitInfo',[U],U),
            ('WF_TestObserve',[U,U,U],None),('WF_TestPending',[U,C.c_int],None),
            ('WF_TestArgument',[U],P),('WF_TestSend',[U,U,P,U,P,U],None),
            ('WF_TestUnit',[U,P],C.c_uint8),
            ('WF_TestField',[P,U,U,P],None),('WF_TestReceive',[C.c_float,P],None),
            ('WF_TestCaller',[P],U),('WF_TestHolderItem',[P],U),('WF_TestSlot',[U,C.c_int],P),
            ('WF_TestReturnSlotMatches',[],C.c_int),
            ('WF_Tracked',[U,U,U],None),('WF_Own',[C.c_int],None),
            ('WF_Drain',[C.POINTER(Event),U],C.c_int),('WF_EventSize',[],U),
            ('WF_Shutdown',[],C.c_int),('WF_TestReset',[],None),('WF_TestEmit',[U,U],None),
            ('WF_TestReads',[],U)):
            fn=getattr(dll,name);fn.argtypes=args;fn.restype=result
        assert dll.WF_Init(cls.memory.game)==-2,'production accepted a non-game module'
        assert dll.WF_EventSize()==C.sizeof(Event),'copied event ABI differs'
        assert dll.WF_TestInstall(cls.memory.game)==1,'private game API publication failed'
        assert dll.WF_InitInfo(0)==8,'publication did not reach ready stage'

    @classmethod
    def tearDownClass(cls):cls.dll.WF_Shutdown()

    def setUp(self):
        self.memory.reset();self.dll.WF_TestReset();self.dll.WF_Tracked(100,10,10);self.dll.WF_Own(0)

    def observe(self,kind,item=10,caller=0):self.dll.WF_TestObserve(kind,item,caller)

    def drain(self):
        events=(Event*512)();n=self.dll.WF_Drain(events,512)
        self.assertGreaterEqual(n,0);return list(events[:n])

    def test_rapid_main_and_retained_utility_history_are_actual_selections(self):
        m=self.memory
        for selected in (11,10,90,10):
            m.put(m.selection,struct.pack('<II',selected,0));self.observe(1)
        rows=self.drain()
        self.assertEqual([r.eid for r in rows],[11,10,90,10])
        self.assertEqual([bool(r.flags&2) for r in rows],[True,True,False,True])
        self.assertEqual([r.sequence for r in rows],[1,2,3,4])
        self.observe(1);self.assertEqual(self.drain(),[])

    def test_confirmed_drop_and_repick_survive_one_lua_frame(self):
        m=self.memory
        for held in (0,100):m.set_u32(m.holder_rows+4,held);self.observe(2)
        self.assertEqual([(r.kind,r.before_holder,r.holder) for r in self.drain()],[(2,100,0),(2,0,100)])

    def test_light_manual_site_origin_initialization_and_read_failure(self):
        m=self.memory
        m.set_u32(m.light_rows+4,0);self.observe(3,caller=0x74d61d)
        row,=self.drain();self.assertEqual((row.kind,row.action,row.before_light,row.light),(3,5,2,0));self.assertTrue(row.flags&16)
        self.dll.WF_Own(1);m.set_u32(m.light_rows+4,1);self.observe(3,caller=0x74d61d);self.dll.WF_Own(0)
        row,=self.drain();self.assertTrue(row.flags&8)
        m.set_u32(m.light_rows+4,2);self.observe(3)
        row,=self.drain();self.assertEqual(row.action,0,'initialization was labelled manual')
        m.set_ptr(m.lights+0x50,0x1234)
        try:
            self.observe(3,caller=0x74d61d);row,=self.drain();self.assertEqual((row.kind,row.action),(5,5))
        finally:m.set_ptr(m.lights+0x50,m.light_rows)

    def test_game_api_forwarding_keeps_pointer_stack_and_float_arguments(self):
        peer=0x123456789abcdef0;params=self.memory.alloc(32)
        self.dll.WF_TestSend(0,77,peer,0,params,2)
        self.assertEqual([self.dll.WF_TestArgument(i) for i in range(4)],[77,peer,params,2])
        self.dll.WF_TestSend(1,78,peer,3,params,2)
        self.assertEqual([self.dll.WF_TestArgument(i) for i in range(5)],[78,peer,3,params,2])
        self.dll.WF_TestReceive(C.c_float(0.03125),params)
        self.assertEqual(self.dll.WF_TestArgument(0),struct.unpack('<I',struct.pack('<f',0.03125))[0])
        self.assertEqual(self.dll.WF_TestArgument(1),params)
        self.assertEqual(self.drain(),[])
        m=self.memory;stack=m.alloc(0xe0);m.set_ptr(stack,m.game+0xbde506);m.set_ptr(stack+0xd0,m.game+0x74d61d)
        self.assertEqual(self.dll.WF_TestCaller(stack),0x74d61d)
        m.set_ptr(stack,m.game+0xbde507);self.assertEqual(self.dll.WF_TestCaller(stack),0)
        m.set_ptr(stack+0x50,m.entity[10]);self.assertEqual(self.dll.WF_TestHolderItem(stack),10)
        # Exercise the compiled callbacks' real return-slot address. A fake
        # stack passed to WF_TestCaller cannot detect an ABI/compiler mistake.
        for many in (0,1):
            self.dll.WF_TestSend(many,0x61ec4b6e,peer,3,params,2)
            self.assertEqual(self.dll.WF_TestReturnSlotMatches(),1)

    def test_field_publications_filter_object_and_exact_setting_hash(self):
        for field,action in [(0x31f86165,0),(0x49c250a6,3),(0x4cbcc2a2,2),(0xf8d23bd2,6)]:
            self.dll.WF_TestField(1,210,field,7)
            row,=self.drain();self.assertEqual((row.kind,row.eid,row.action),(4,10,action))
        self.dll.WF_TestField(1,210,0x1234,7);self.dll.WF_TestField(1,211,0x49c250a6,7)
        self.assertEqual(self.drain(),[])

    def test_equipment_unit_callback_reads_local_selection_not_avatar_unit(self):
        m=self.memory;stack=m.alloc(0x68)
        m.set_ptr(stack,m.game+0x79b7a5);m.set_ptr(stack+0x60,m.game+0x785ecd)
        m.put(m.selection,struct.pack('<II',11,0))
        # Unit 111 is weapon B's visual unit. The avatar's Unit is 200.
        self.assertEqual(self.dll.WF_TestUnit(111,stack),0x5a)
        self.assertEqual(self.dll.WF_TestArgument(0),111)
        row,=self.drain();self.assertEqual((row.kind,row.eid),(1,11));self.assertTrue(row.flags&2)
        self.dll.WF_TestUnit(999,stack)
        self.assertEqual(self.drain(),[],'another visual update invented an equip')
        m.put(m.selection,struct.pack('<II',90,0));self.dll.WF_TestUnit(190,stack)
        row,=self.drain();self.assertFalse(row.flags&2,'inventory utility became a main weapon')

    def test_replication_result_checks_ignore_counters_and_optional_absence(self):
        m=self.memory
        for storage,offset,value in [(m.mode_rows,0,struct.pack('<I',2)),(m.rate_rows,4,struct.pack('<f',1150)),(m.guide_rows,0,b'\x01')]:
            self.dll.WF_TestPending(10,0);m.put(storage+offset,value)
            row,=self.drain();self.assertEqual((row.kind,row.eid),(4,10));self.assertTrue(row.flags&32)
        self.dll.WF_TestPending(10,0);m.set_u32(m.mode_rows+8,91);m.set_u32(m.rate_rows+8,92)
        self.assertEqual(self.drain(),[],'unrelated counters invalidated mode')
        m.table(m.guide+0x30,{11:1})
        self.dll.WF_TestPending(10,0);m.set_u32(m.mode_rows+8,93)
        self.assertEqual(self.drain(),[],'absent optional component became a read failure')
        m.table(m.guide+0x30,{10:0,11:1})

    def test_avatar_replication_before_resolution_and_uncertain_modes(self):
        m=self.memory;self.dll.WF_TestPending(100,1);m.set_u32(m.player+0x3a8,310)
        row,=self.drain();self.assertEqual((row.kind,row.before_holder,row.holder),(7,300,310));self.assertTrue(row.flags&16)
        m.set_u32(m.player+0x3a8,300);self.dll.WF_TestPending(10,0);m.set_ptr(m.weapon_data+0x60,0x1234)
        try:
            row,=self.drain();self.assertEqual(row.kind,4);self.assertFalse(row.flags&1)
        finally:m.set_ptr(m.weapon_data+0x60,m.mode_rows)

    def test_quiet_drains_do_not_read_game_and_queue_failure_is_closed(self):
        before=self.dll.WF_TestReads()
        for _ in range(100):self.assertEqual(self.drain(),[])
        self.assertEqual(self.dll.WF_TestReads(),before)
        self.dll.WF_Own(1)
        thread=threading.Thread(target=lambda:self.dll.WF_TestEmit(4,10));thread.start();thread.join()
        self.dll.WF_TestEmit(4,10);self.dll.WF_Own(0)
        rows=self.drain();self.assertFalse(rows[0].flags&8);self.assertTrue(rows[1].flags&8)
        for _ in range(513):self.dll.WF_TestEmit(4,10)
        self.assertEqual(self.dll.WF_Drain((Event*512)(),512),-1)
        self.dll.WF_TestReset()

    def test_z_shutdown_restores_owned_slots_and_preserves_foreign_changes(self):
        before=[self.dll.WF_TestSlot(i,0) for i in range(7)]
        foreign=self.dll.WF_TestSlot(4,1)
        self.assertEqual(self.dll.WF_Shutdown(),0)
        self.assertEqual(self.dll.WF_TestSlot(4,0),foreign)
        for i in (0,1,2,3,5,6):self.assertNotEqual(self.dll.WF_TestSlot(i,0),before[i])
        self.dll.WF_TestSend(0,1,2,0,0,0)
        self.assertEqual(self.drain(),[])


class EventAdapter(unittest.TestCase):
    def test_queue_gap_stops_and_own_scope_is_released_after_failure(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        module=lua.execute((ROOT/'src/native_weapon_events.lua').read_text())
        api=lua.eval('''{install=function()return true end,shutdown=function()return true end,
            track=function()end,matches=function()return true end,
            own=function(value)_G.own=value end,
            drain=function()return {{sequence=2,kind=4,flags=0}}end}''')
        reader=lua.eval('{game=0,verify=function()return true end}')
        observer=module.new(reader,lua.table_from({'api':api}))
        result=observer.drain(observer);self.assertIsNone(result[0]);self.assertIn('sequence',result[1])
        lua.globals().observer=observer
        self.assertFalse(lua.execute('return pcall(function()observer:own_call(function()error("stop")end)end)')[0])
        self.assertFalse(lua.globals().own)


if __name__=='__main__':unittest.main()

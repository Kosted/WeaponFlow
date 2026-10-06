"""Guarded default seeding: production reader + byte-addressed fixtures.

Native-only writes on fake memory; no game serialization or live proof.
"""
import struct
import unittest
from test_native_mod_bindings import Fixture, ROOT, GAME, OWNER, CAPTURE, mapping

DEFAULTS=0x323450000

class DefaultsFixture(Fixture):
    def __init__(self, code=10*65536+2, mappings=None):
        super().__init__(code, [] if mappings is None else mappings)
        self.defaults=self.lua.execute((ROOT/'src/native_mod_binding_defaults.lua').read_bytes())
        self.writes=[];self.preparations=[]
        for a in self.defaults[b'anchors'].values():self.regions[GAME+a[b'rva']]=a[b'bytes']
        # Names below are fixture identifiers at proven native string RVAs.
        # They deliberately don't claim unknown strings from the game capture.
        self.name_region=bytearray(0x3000)
        self.regions[GAME+0x2255000]=self.name_region
        for c,e in self.defaults[b'names'].items():
            for key,text in ((b'section',f'G{int(c)//65536}'),(b'action',f'A{int(c)//65536}_{int(c)%65536}')):
                o=int(e[key])-0x2255000;raw=text.encode()+b'\0';self.name_region[o:o+len(raw)]=raw
        self.default_buckets=bytearray(b'\xff'*(256*328))
        self.default_header=bytearray(struct.pack('<QIII',DEFAULTS,256,0xffffffff,2654435761))
        self.regions[OWNER+686968]=self.default_header;self.regions[DEFAULTS]=self.default_buckets
        self.set_shipped([])
        self.regions[GAME+0x263d1f0]=bytearray(4096)
        self.keyboard=self.lua.eval(b"{button_id=function(n)return ({p=80,h=72,k=75})[n] end,button_name=function(n)return ({[80]='p',[72]='h',[75]='k'})[n] end}")
        self.write_hook=None
        def write(at,raw):
            self.writes.append((at,raw))
            if self.write_hook:
                result=self.write_hook(at,raw)
                if result is not None:return result
            offset=int(at)-self.bucket+self.slot*328
            self.buckets[offset:offset+len(raw)]=raw
            return True
        self.lua.globals()[b'Bindings']=self.lua.execute((ROOT/'src/weaponflow_game_controls.lua').read_bytes())
        self.validations=0;self.guard_error=None
        def validate():
            self.validations+=1
            return (None,self.guard_error) if self.guard_error else True
        self.lua.globals()[b'fixture_validate']=validate
        def prepare_owned(changes):
            self.preparations.append(changes)
            return self.lua.table_from({b'validate':self.lua.eval(b'function()return fixture_validate()end')})
        self.lua.globals()[b'fixture_owned_prepare']=prepare_owned
        self.options=self.lua.table_from({b'engine':self.lua.table_from({b'Keyboard':self.keyboard}),
            b'bindings':self.module,b'write':write,b'prepare_publication':self.lua.eval(b'function(changes)return fixture_owned_prepare(changes)end')})
        self.instance=self.defaults[b'new'](self.options)
        self.before_write=self.lua.eval(b'function()return true end')
    def set_shipped(self,rows):
        data=struct.pack('<II',self.code,len(rows))+b''.join(rows)
        self.default_buckets[self.slot*328:(self.slot+1)*328]=data.ljust(328,b'\0')
    def add_action(self,code,rows):
        slot=(code*2654435761)%256
        data=struct.pack('<II',code,len(rows))+b''.join(rows)
        self.buckets[slot*328:(slot+1)*328]=data.ljust(328,b'\0')
        return slot
    def clear(self,codes=None,callback=True):
        code_array=self.lua.table_from(codes or [self.code])
        return self.instance[b'clear_many'](self.instance,self.reader,code_array,self.before_write if callback else None)
    def replace(self,key=b'P',trigger=0,threshold=0):
        rows=self.lua.table_from([self.lua.table_from({b'key':key,b'trigger':trigger,b'threshold':threshold})])
        return self.instance[b'replace'](self.instance,self.reader,self.code,rows,self.before_write,self.inspect()[b'signature'])

class NativeBindingPublicationTests(unittest.TestCase):
    def test_first_use_distinguishes_inherited_records_without_writing_or_guessing_names(self):
        f=DefaultsFixture(mappings=[mapping(button=80),mapping(button=72)])
        f.set_shipped([mapping(button=80)])
        before=bytes(f.buckets),bytes(f.default_buckets)
        value=f.defaults[b'initial_state'](f.reader,f.inspect())
        self.assertEqual(value[b'inherited_count'],1)
        self.assertEqual(value[b'action'],b'A10_2')
        self.assertEqual(before,(bytes(f.buckets),bytes(f.default_buckets)))
        self.assertFalse(f.writes)
        previous=f.inspect();f.set_bucket(f.code,[])
        value,why=f.defaults[b'initial_state'](f.reader,previous)
        self.assertIsNone(value);self.assertIn(b'records changed',why)

    def test_replace_preserves_every_other_bucket_and_never_commits_a_file(self):
        f=DefaultsFixture();before=bytes(f.buckets);shipped=bytes(f.default_buckets)
        result,reason,*_=f.replace(trigger=5,threshold=.3)
        self.assertIsNone(reason)
        self.assertTrue(result[b'native_only']);self.assertFalse(result[b'persisted'])
        offset=f.slot*328
        self.assertEqual(bytes(f.buckets[:offset+4]),before[:offset+4])
        self.assertEqual(bytes(f.buckets[offset+328:]),before[offset+328:])
        self.assertEqual(bytes(f.default_buckets),shipped)
        value=f.inspect();self.assertEqual(value[b'mappings'][1][b'button_id'],80)
        self.assertEqual(value[b'mappings'][1][b'trigger'],5)

    def test_reset_clears_full_empty_row_and_tail_but_preserves_foreign_actions(self):
        f=DefaultsFixture(mappings=[]);foreign=10*65536+6;slot=f.add_action(foreign,[mapping(button=72)])
        f.buckets[f.slot*328+8:f.slot*328+328]=b'x'*320
        other=bytes(f.buckets[slot*328:(slot+1)*328]);result=f.clear()
        self.assertTrue(result[b'native_only'])
        self.assertEqual(bytes(f.buckets[f.slot*328+4:(f.slot+1)*328]),bytes(324))
        self.assertEqual(bytes(f.buckets[slot*328:(slot+1)*328]),other)

    def test_failed_context_guard_never_writes(self):
        f=DefaultsFixture(mappings=[mapping()]);before=bytes(f.buckets);f.guard_error=b'profile changed'
        result,why=f.clear();self.assertIsNone(result);self.assertFalse(f.writes)
        self.assertEqual(bytes(f.buckets),before);self.assertIn(b'profile changed',why)

    def test_binding_changed_during_backup_aborts_before_write(self):
        f=DefaultsFixture(mappings=[mapping()])
        def changed():f.set_bucket(f.code,[mapping(button=72)]);return True
        f.lua.globals()[b'fixture_changed']=changed
        f.before_write=f.lua.eval(b'function()return fixture_changed()end');result,why=f.clear()
        self.assertIsNone(result);self.assertFalse(f.writes)
        self.assertEqual(f.inspect()[b'mappings'][1][b'button_id'],72)

    def test_partial_write_is_uncertain_and_never_retried_or_overwritten(self):
        f=DefaultsFixture(mappings=[mapping()])
        def partial(at,raw):
            offset=int(at)-(f.bucket-f.slot*328);f.buckets[offset:offset+8]=raw[:8];return False
        f.write_hook=partial;result,why=f.clear();self.assertIsNone(result)
        after=bytes(f.buckets);count=len(f.writes)
        result,why=f.clear();self.assertIsNone(result)
        self.assertIn(b'no mutation replay',why);self.assertEqual(len(f.writes),count)
        self.assertEqual(bytes(f.buckets),after)

    def test_later_write_failure_rolls_back_only_exact_owned_payloads(self):
        f=DefaultsFixture(mappings=[mapping()]);second=10*65536+6;f.add_action(second,[mapping(button=72)])
        before=bytes(f.buckets);failed=False
        def fail_second(at,raw):
            nonlocal failed
            if len(f.writes)==2 and not failed:failed=True;return False
        f.write_hook=fail_second
        result,why=f.clear([f.code,second]);self.assertIsNone(result)
        self.assertIn(b'original owned mappings restored',why);self.assertEqual(bytes(f.buckets),before)

    def test_inherited_default_and_stale_signature_refuse_replacement(self):
        f=DefaultsFixture();encoded=f.defaults[b'encode_buttons'](f.code,
            f.lua.table_from([f.lua.table_from({b'key':b'P',b'trigger':0,b'threshold':0})]),f.options[b'engine'])[0]
        f.set_shipped([encoded[8:28]]);result,why,*_=f.replace()
        self.assertIsNone(result);self.assertIn(b'inherited',why);self.assertFalse(f.writes)
        f=DefaultsFixture();snapshot=f.inspect();f.set_bucket(f.code,[mapping(button=72)])
        result,why,*_=f.instance[b'replace'](f.instance,f.reader,f.code,f.lua.table(),f.before_write,snapshot[b'signature'])
        self.assertIsNone(result);self.assertFalse(f.writes)

    def test_unsupported_build_or_unknown_codes_never_write(self):
        for codes in ([0],[655362,655362],[655362]*7):
            f=DefaultsFixture();result,why=f.clear(codes);self.assertIsNone(result);self.assertFalse(f.writes)
        f=DefaultsFixture();f.reader[b'reject_build']=True
        result,why=f.clear();self.assertIsNone(result);self.assertFalse(f.writes)

if __name__=='__main__':unittest.main()

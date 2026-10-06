"""Portable account replacement with fake files/clipboard; no game or OS I/O."""
import unittest
import test_weapon_defaults_store as store_fixtures
ROOT=store_fixtures.ROOT


class PresetsTransferTests(unittest.TestCase):
    def setUp(self):
        self.fixture=store_fixtures.DefaultsStore();self.fixture.setUp();self.lua=self.fixture.lua
        self.lua.globals()[b'Transfer']=self.lua.execute((ROOT/'src/weaponflow_presets_transfer.lua').read_bytes())

    def check(self,code): self.lua.execute(code.encode('utf-8'))

    def test_bundled_pack_seeds_new_profile_and_reset_but_never_overwrites_existing(self):
        self.lua.globals()[b'DefaultPresets']=self.lua.execute((ROOT/'src/weaponflow_default_presets.lua').read_bytes())
        self.lua.globals()[b'DefaultsStore']=self.lua.globals()[b'Store']
        self.lua.globals()[b'ModReset']=self.lua.execute((ROOT/'src/weapon_defaults_reset.lua').read_bytes())
        self.check('''
            local expected=assert(Store.encode_presets(assert(Store.decode_presets(DefaultPresets))))
            profile='76561198000000002';path='C:\\\\fixture\\\\'..profile..'.ini'
            local st=assert(open());local ok,detail=st:import_presets(DefaultPresets,function()return true end,true)
            assert(ok and detail.installed and st:export_presets()==expected and st:get_flashlight()==nil)
            assert(st:merge(jar,{right=target(1,'firemode',2)},1));assert(st:set_flashlight(1))
            local raw,count=files[path],writes
            assert(st:import_presets(DefaultPresets,function()error('existing profile must not reseed')end,true))
            assert(files[path]==raw and writes==count)
            local unrelated='C:\\\\fixture\\\\76561198000000003.ini';files[unrelated]='UNRELATED'
            local plan=assert(ModReset.prepare(profile,{io=api,path=path,timestamp='seed-contract'}))
            assert(plan:backup());assert(plan:commit())
            local reset=assert(open());assert(reset:export_presets()==expected)
            assert(reset:get_flashlight()==nil and files[unrelated]=='UNRELATED')
        ''')

    def test_full_replacement_is_portable_and_preserves_light_other_profiles_and_empty_records(self):
        self.check('''
            local st=assert(open());assert(st:merge(jar,{right=target(2,'firemode',3)},1))
            assert(st:merge(jar,{up=target(3,'zeroing',150)},3));assert(st:ensure(stalwart))
            local data=assert(st:export_presets());assert(not data:find(profile,1,true))
            assert(not data:find('flashlight_mode',1,true))
            profile='76561198000000002';path='second.ini'
            local other=assert(open());assert(other:set_flashlight(2))
            assert(other:merge('0123456789ABCDEF',{left=target(1,'firemode',5)},1))
            local before=files[path];assert(other:import_presets(data,function()return true end))
            assert(files[path..'.bak']==before and other:get_flashlight()==2)
            assert(other:get('0123456789ABCDEF')==nil)
            assert(other:get(jar,3).targets.up.value==150 and other:get(jar,1).targets.right.value==3)
            assert(next(other:get(stalwart).targets)==nil)
            assert(st:get(jar,3).targets.up.value==150)
        ''')

    def test_bad_clipboard_data_never_reloads_writes_or_changes_store(self):
        self.check('''
            local st=assert(open());assert(st:ensure(jar))
            local valid=assert(st:export_presets());local raw,config=st.raw,st.config
            local file=files[path];local original_reads,original_writes=reads,writes
            local guard_calls=0
            local bad={'','return os.remove("profile.ini")',valid:gsub('PRESETS/1','PRESETS/2'),
                valid..'[settings]\\nschema=3\\n',valid..'[weapon:'..jar..':preset:1]\\n',
                valid:gsub('preset:3','preset:4'),valid:gsub(jar,'WRONGID'),
                valid:gsub('right=None','right=1\\nright_kind=flashlight\\nright_value=0'),
                valid:sub(1,#valid-10)}
            for _,data in ipairs(bad) do
                assert(st:import_presets(data,function()guard_calls=guard_calls+1;return true end)==nil)
                assert(st.config==config and st.raw==raw and files[path]==file)
            end
            assert(guard_calls==0 and reads==original_reads and writes==original_writes)
        ''')

    def test_guard_and_write_failures_preserve_account_and_seed_only_installs_once(self):
        self.check('''
            local st=assert(open());assert(st:merge(jar,{right=target(3,'rpm',1150)}))
            local data=assert(st:export_presets());local file=files[path]
            assert(st:import_presets('WEAPONFLOW-PRESETS/1\\n',function()return false end)==nil)
            fail_write=true;assert(st:import_presets('WEAPONFLOW-PRESETS/1\\n',function()return true end)==nil)
            assert(files[path]==file and st:get(jar).targets.right.value==1150)
            fail_write=false;profile='76561198000000002';path='fresh.ini'
            local fresh=assert(open());local ok,detail=fresh:import_presets(data,function()return true end,true)
            assert(ok and detail.installed and fresh:get(jar).targets.right.value==1150)
            local before=files[path];local count=writes
            assert(fresh:import_presets('WEAPONFLOW-PRESETS/1\\n',function()error('must not publish')end,true))
            assert(files[path]==before and writes==count)
        ''')

    def test_copy_and_paste_are_explicit_and_invalid_paste_has_no_account_effects(self):
        self.check('''
            local st=assert(open());assert(st:ensure(jar));local file=files[path]
            local calls=0;local clip={read=function()calls=calls+1;return 'bad text' end,
                write=function(_,data)calls=calls+1;assert(Store.decode_presets(data));return true end}
            local transfer=Transfer.new({clipboard=clip})
            assert(transfer:run(st,{},function()return true end)==nil and calls==0)
            assert(transfer:run(st,{import_pressed=true},function()return false end)==nil and calls==0)
            assert(transfer:run(st,{import_pressed=true},function()return true end)==nil and files[path]==file)
            assert(transfer:run(st,{export_pressed=true},function()return true end)=='copied')
            assert(calls==2 and files[path]==file)
        ''')

if __name__=='__main__':unittest.main()

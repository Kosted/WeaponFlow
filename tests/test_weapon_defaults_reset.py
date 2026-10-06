"""Recoverable profile-only reset transactions; all filesystem I/O is fake."""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]


class ResetTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        for name,path in [('DefaultsStore','weapon_defaults_store'),('MenuState','weapon_defaults_menu_state'),
                          ('HudLayout','weapon_defaults_hud_layout'),('ModReset','weapon_defaults_reset')]:
            self.lua.globals()[name]=self.lua.execute((ROOT/'src'/f'{path}.lua').read_text())
        self.lua.execute(r'''
            profile='76561198000000001';directory='C:\\fixture';prefix=directory..'\\'..profile
            files={};reads={};writes={};original={}
            active={[prefix..'.ini']='presets',[prefix..'-HUD.ini']='hud',[prefix..'-Menu.ini']='menu'}
            for path,name in pairs(active) do
                files[path]='[old]\r\nprofile_id='..profile..'\r\nvalue='..name..'\r\n'
                original[path]=files[path]
            end
            other=directory..'\\76561198000000002.ini';files[other]='OTHER PROFILE'
            oldbackup=prefix..'.ini.schema1.bak';files[oldbackup]='OLD SCHEMA BACKUP'
            api={read=function(path,max)
                reads[#reads+1]={path=path,max=max}
                if read_fail==path then return nil,'read denied' end
                if read_throw==path then error('read exception') end
                local raw=files[path]
                if raw==nil then return nil,'missing' end
                if #raw>max then return nil,'oversize' end
                return raw
            end,atomic_write=function(path,data,expected)
                writes[#writes+1]={path=path,data=data,expected=expected}
                if before_write then before_write(path,data,expected) end
                if write_fail==path then return nil,'disk full' end
                if write_throw==path then error('write exception') end
                if files[path]~=expected then return nil,'concurrent edit' end
                if files[path]~=nil then files[path..'.bak']=files[path] end
                files[path]=data;return true
            end,default_directory=function() return directory end}
            function prepare() return ModReset.prepare(profile,{io=api,timestamp='20261003T120000Z'}) end
            function active_writes()
                local n=0;for _,entry in ipairs(writes) do if active[entry.path] then n=n+1 end end;return n
            end
            function all_original()
                for path,raw in pairs(original) do assert(files[path]==raw,path) end
                assert(files[other]=='OTHER PROFILE' and files[oldbackup]=='OLD SCHEMA BACKUP')
            end
        ''')

    def check(self,code):
        self.lua.execute(code)


    def test_reset_backs_up_three_own_files_and_ignores_retired_control_file(self):
        self.lua.globals().Bindings=self.lua.execute((ROOT/'src/weaponflow_game_controls.lua').read_text())
        self.check('''
            local path=prefix..'-Bindings.ini';files[path]='RETIRED FILE'
            plan=assert(prepare());assert(#plan.files==3 and active_writes()==0)
            assert(plan:backup());assert(active_writes()==0)
            local ok,info=plan:commit();assert(ok and info.files_written==3)
            assert(files[path]=='RETIRED FILE')
            for _,entry in ipairs(reads) do assert(entry.path~=path) end
            for _,entry in ipairs(writes) do assert(entry.path~=path) end
            for _,file in ipairs(plan.files) do
                assert(files[plan.backup_directory..'/'..profile..file.suffix]==original[file.path])
            end
            assert(files[other]=='OTHER PROFILE' and files[oldbackup]=='OLD SCHEMA BACKUP')
        ''')


    def test_backup_failure_never_mutates_active_files(self):
        self.check('''
            plan=assert(prepare());write_fail=plan.backup_directory..'/'..profile..'-HUD.ini'
            local ok,why,detail=plan:commit();assert(ok==nil and why:find('backup',1,true))
            assert(detail.active_files_written==0 and detail.partial==false and active_writes()==0)
            all_original();local n=#writes;assert(plan:commit()==nil and #writes==n)
        ''')


    def test_third_write_failure_rolls_back_prior_files_and_keeps_backups(self):
        self.check('''
            plan=assert(prepare());write_fail=prefix..'-Menu.ini'
            local ok,why,detail=plan:commit();assert(ok==nil and detail.partial==false)
            assert(detail.rollback.presets=='original restored' and detail.rollback.hud=='original restored')
            assert(detail.rollback.menu=='original retained');all_original()
            assert(files[plan.backup_directory..'/manifest.ini'])
        ''')

    def test_concurrent_change_is_retained_during_rollback(self):
        self.check('''
            plan=assert(prepare());write_fail=prefix..'-Menu.ini'
            before_write=function(path)
                if path==prefix..'-Menu.ini' then files[prefix..'.ini']='EXTERNAL SAVE' end
            end
            local ok,why,detail=plan:commit();assert(ok==nil and detail.partial==true)
            assert(detail.rollback.presets=='external change retained' and files[prefix..'.ini']=='EXTERNAL SAVE')
            assert(files[prefix..'-HUD.ini']==original[prefix..'-HUD.ini'])
        ''')


    def test_foreign_profile_missing_identity_and_read_errors_refuse_prepare(self):
        self.check('''
            local path=prefix..'-HUD.ini'
            for _,value in ipairs({'[hud]','profile_id=76561198000000002',
                'profile_id='..profile..'\\nprofile_id='..profile}) do
                files[path]=value;assert(prepare()==nil and #writes==0)
            end
            files[path]=original[path];read_fail=path;assert(prepare()==nil)
            read_fail=nil;read_throw=path;assert(prepare()==nil)
        ''')

    def test_wrong_path_profile_and_timestamp_cannot_target_other_files(self):
        self.check(r'''
            assert(ModReset.prepare('123',{io=api})==nil)
            assert(ModReset.prepare(profile,{io=api,path=directory..'\\76561198000000002.ini'})==nil)
            assert(ModReset.prepare(profile,{io=api,timestamp='../elsewhere'})==nil)
            assert(ModReset.prepare(profile,false)==nil)
            assert(#writes==0)
        ''')


if __name__=='__main__':
    unittest.main()

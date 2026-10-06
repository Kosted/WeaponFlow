"""Required menu initialization markers; fake I/O only, no user settings."""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]


class MenuStateTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().DefaultsStore=self.lua.execute((ROOT/'src/weapon_defaults_store.lua').read_text())
        self.lua.globals().MenuState=self.lua.execute((ROOT/'src/weapon_defaults_menu_state.lua').read_text())
        self.lua.execute(r'''
            profile='76561198000000001';directory='C:\\fixture'
            marker=directory..'\\'..profile..'-Menu.ini'
            preset=directory..'\\'..profile..'.ini'
            files={[preset]='CORRUPT PRESET MUST NOT BE READ'}
            reads={};writes={}
            api={read=function(path,max)
                reads[#reads+1]={path=path,max=max}
                assert(path~=preset,'presets file was read')
                if read_throw then error('read exception') end
                if read_fail then return nil,read_fail end
                if files[path]==nil then return nil,'missing' end
                if #files[path]>max then return nil,'size bound' end
                return files[path]
            end,atomic_write=function(path,data,expected)
                assert(path==marker,'unrelated file write')
                writes[#writes+1]={path=path,data=data,expected=expected}
                if write_throw then error('write exception') end
                if write_fail then return nil,write_fail end
                if concurrent then files[path]=concurrent;concurrent=nil end
                if files[path]~=expected then return nil,'changed concurrently' end
                files[path]=data;return true
            end,default_directory=function() return directory end}
            function opened() return MenuState.open(profile,{io=api}) end
            function text(save,cycle,hud,reset,other)
                return '[menu]\r\nschema=1\r\nprofile_id='..(other or profile)..'\r\n'..
                    'save='..tostring(save)..'\r\ncycle='..tostring(cycle)..'\r\nhud='..tostring(hud)..
                    '\r\nreset='..tostring(reset or false)..'\r\n'
            end
        ''')

    def run_lua(self,code):
        self.lua.execute(code)

    def test_retired_markers_are_ignored_on_read_and_omitted_on_mutation(self):
        self.run_lua(r"""
            files[marker]=text(true,false,true,false)..'clear=true\r\nexport=pending\r\nimport=true\r\nlocale=true\r\n'
            local before=files[marker];state=assert(opened())
            assert(state:contains('save') and #writes==0 and files[marker]==before)
            assert(state:contains('clear')==nil)
            assert(state:mark('cycle'))
            assert(files[marker]==text(true,true,true,false))
        """)

    def test_first_mark_commits_before_success_and_is_restart_persistent(self):
        self.run_lua('''
            state=assert(opened());local ok,changed=state:mark('save')
            assert(ok and changed and #writes==1 and writes[1].expected==nil)
            assert(files[marker]==text(true,false,false,false))
            local fresh=assert(opened());assert(fresh:contains('save')==true)
            assert(fresh:contains('cycle')==false)
            ok,changed=fresh:mark('save');assert(ok and changed==false and #writes==1)
        ''')

    def test_pending_reservation_is_durable_and_only_known_no_write_can_cancel_it(self):
        self.run_lua('''
            state=assert(opened());assert(state:begin('save'))
            assert(state:contains('save') and assert(opened()):contains('save'))
            assert(state:begin('save')==nil)
            assert(state:cancel('save') and not state:contains('save'))
            assert(state:cancel('save')==nil)
            assert(state:begin('save') and state:mark('save'))
            assert(state:contains('save') and not files[marker]:find('pending',1,true))
        ''')

    def test_language_is_optional_read_only_and_survives_marker_updates(self):
        self.run_lua('''
            state=assert(opened());assert(state:language()=='auto' and #writes==0)
            files[marker]=text(false,false,false,false)..'language=pt-BR\\r\\n'
            state=assert(opened());assert(state:language()=='pt-br' and #writes==0)
            assert(state:begin('save') and state:mark('save'))
            assert(state:language()=='pt-br')
            local before=files[marker]
            assert(state:set_language('ru',function()return false end)==nil and files[marker]==before)
            assert(state:set_language('ru',function()return true end) and state:language()=='ru')
            assert(state:contains('save'))
        ''')


    def test_io_failure_is_unknown_and_never_allows_a_seed(self):
        self.run_lua('''
            state=assert(opened())
            for _,reason in ipairs({'denied','size bound',''}) do
                read_fail=reason
                local value,why=state:contains('save');assert(value==nil and why)
                local ok,why=state:mark('save');assert(ok==nil and why)
                local missing,why=opened();assert(missing==nil and why)
            end
            read_fail=nil;read_throw=true
            assert(state:contains('save')==nil and state:mark('save')==nil and opened()==nil)
            assert(#writes==0)
        ''')


    def test_concurrent_update_is_not_overwritten_and_retry_merges(self):
        self.run_lua('''
            state=assert(opened());concurrent=text(false,true,false,false)
            local ok,why=state:mark('save');assert(ok==nil and why:find('concurrently',1,true))
            assert(files[marker]==text(false,true,false,false))
            assert(state:mark('save'));assert(files[marker]==text(true,true,false,false))
        ''')

    def test_foreign_profile_corruption_duplicates_unknown_fields_refuse_writes(self):
        self.run_lua(r'''
            local values={'',text(false,false,false,false,'76561198000000002'),
                text(false,false,false,false):gsub('schema=1','schema=2'),
                text(false,false,false,false)..'save=true\r\n',
                text(false,false,false,false)..'[other]\r\n',
                text(false,false,false,false)..'alien=true\r\n',
                text(false,false,false,false):gsub('cycle=false\r\n',''),
                text(false,false,false,false):gsub('hud=false','hud=0'),
                text(false,false,false,false)..'\0',string.rep('x',4097)}
            state=assert(opened())
            for _,raw in ipairs(values) do
                files[marker]=raw
                assert(opened()==nil and state:contains('save')==nil and state:mark('save')==nil)
                assert(files[marker]==raw)
            end
            assert(#writes==0)
        ''')


if __name__=='__main__':
    unittest.main()

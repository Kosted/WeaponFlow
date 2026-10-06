"""Persistence/merge checks; no game state or game actions are simulated here."""
from pathlib import Path
import os
import tempfile
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "src/weapon_defaults_store.lua").read_bytes()


class DefaultsStore(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        self.lua.globals()[b"Store"] = self.lua.execute(SOURCE)
        self.lua.execute(br"""
            files={}; reads=0; writes=0; fail_write=false; race=false
            profile='76561198000000001'; path='profile.ini'
            jar='361EFAD956A1F180'; stalwart='7F324ACBAC35A7A6'
            api={
                read=function(p,max)
                    reads=reads+1
                    if read_failure then return nil,'access denied' end
                    if files[p]==nil then return nil,'missing' end
                    if #files[p]>max then return nil,'settings file exceeds size limit' end
                    return files[p]
                end,
                atomic_write=function(p,data,expected,legacy_profile)
                    if fail_write then return nil,'disk full' end
                    if race then files[p]=files[p]..'; external edit\n' end
                    if files[p]~=expected then return nil,'settings changed concurrently; retry save' end
                    if legacy_profile then
                        local schema=type(legacy_profile)=='table' and legacy_profile.schema or 1
                        local backup=p..'.schema'..schema..'.bak'
                        if files[backup]==nil then files[backup]=files[p] end
                    end
                    if files[p] then files[p..'.bak']=files[p] end
                    files[p]=data;writes=writes+1;return true
                end,
            }
            function open()
                return Store.open(profile,{io=api,path=path})
            end
            function target(slot,kind,value) return {slot=slot,kind=kind,value=value} end
            function initial_presets()
                return {
                    {targets={right=target(2,'firemode',3),up=target(3,'zeroing',150),down=target(3,'test_mode',2)}},
                    {targets={right=target(1,'firemode',2),up=target(1,'zeroing',25),down=target(1,'test_mode',0)}},
                    {targets={left=target(2,'programmable_ammo',284)}},
                }
            end
            function legacy()
                return '[settings]\r\nschema=1\r\nprofile_id='..profile..'\r\nhotkey=F8\r\ndouble_tap_ms=400\r\n'..
                    '[weapon:'..jar..']\r\nleft=None\r\nright=2\r\nright_kind=firemode\r\nright_value=3\r\n'..
                    'up=3\r\nup_kind=zeroing\r\nup_value=150\r\ndown=1\r\ndown_kind=flashlight\r\ndown_value=0\r\n'
            end
            function legacy2()
                local text='[settings]\r\nschema=2\r\nprofile_id='..profile..
                    '\r\nhotkey=F8\r\nbind_hotkey=K\r\ncycle_hotkey=F9\r\ndouble_tap_ms=400\r\n'
                for preset=1,3 do
                    text=text..'[weapon:'..jar..':preset:'..preset..']\r\n'..
                        'left=None\r\nright=2\r\nright_kind=firemode\r\nright_value=3\r\n'..
                        'up='..preset..'\r\nup_kind=zeroing\r\nup_value='..(preset*25)..'\r\n'..
                        'down='..preset..'\r\ndown_kind=flashlight\r\ndown_value='..(preset-1)..'\r\n'
                end
                return text
            end
            store=assert(open())
        """)

    def check(self, code):
        self.lua.execute(code.encode("utf-8"))

    def test_unknown_weapon_is_empty_and_ensure_writes_none_once(self):
        self.check(r"""
            assert(store:get(jar)==nil and writes==0)
            assert(store:ensure(jar))
            assert(next(store:get(jar).targets)==nil)
            for _,side in ipairs({'left','right','up','down'}) do
                assert(files[path]:find(side..'=None',1,true))
            end
            assert(store:ensure(jar) and writes==1)
            local fresh=assert(open());assert(next(fresh:get(jar).targets)==nil)
        """)


    def test_initialize_never_replaces_existing_nonempty_empty_or_cleared_records(self):
        self.check(r"""
            for _,kind in ipairs({'populated','empty','clear_one','clear_all'}) do
                files={};store=assert(open())
                if kind=='empty' then assert(store:ensure(jar))
                else
                    for preset=1,3 do assert(store:merge(jar,{up=target(2,'zeroing',75)},preset)) end
                    if kind=='clear_one' then assert(store:clear(jar,2)) end
                    if kind=='clear_all' then assert(store:clear_all(jar)) end
                end
                local previous=files[path];local parsed=store.config
                local before_reads,before_writes=reads,writes
                local ok,created=store:initialize(jar,initial_presets())
                assert(ok and created==false and writes==before_writes and reads==before_reads+1)
                assert(files[path]==previous and store.config==parsed)
                for preset=1,3 do
                    local targets=store:get(jar,preset).targets
                    if kind=='empty' or kind=='clear_all' or (kind=='clear_one' and preset==2) then
                        assert(next(targets)==nil)
                    else assert(targets.up.value==75 and targets.right==nil) end
                end
            end
        """)


    def test_initialize_refuses_racing_save_or_clear_and_retry_preserves_winner(self):
        self.check(r"""
            for _,clear in ipairs({false,true}) do
                files={};store=assert(open())
                local original_read,original_write=api.read,api.atomic_write
                local other=assert(open())
                assert(other:merge(jar,{up=target(2,'zeroing',75)},2))
                if clear then assert(other:clear_all(jar)) end
                local winning=files[path];files[path]=nil
                local before=writes
                api.atomic_write=function(p,data,expected,legacy_profile)
                    assert(expected==nil and store:get(jar)==nil)
                    files[p]=winning
                    return original_write(p,data,expected,legacy_profile)
                end
                local ok,reason=store:initialize(jar,initial_presets())
                assert(not ok and reason:find('concurrently',1,true))
                assert(files[path]==winning and writes==before and store:get(jar)==nil)
                api.atomic_write=original_write
                local created;ok,created=store:initialize(jar,initial_presets())
                assert(ok and created==false and files[path]==winning and writes==before)
                if clear then assert(next(store:get(jar,2).targets)==nil)
                else assert(store:get(jar,2).targets.up.value==75) end
            end
        """)


    def test_partial_merge_preserves_absent_modules_and_other_weapon(self):
        self.check(r"""
            assert(store:merge(jar,{right=target(2,'firemode',3),up=target(3,'zeroing',150),down=target(3,'test_mode',2)}))
            assert(store:merge(stalwart,{right=target(3,'rpm',1150)}))
            assert(store:merge(jar,{right=target(1,'firemode',2)}))
            local saved=store:get(jar).targets
            assert(saved.right.slot==1 and saved.up.value==150 and saved.down.value==2)
            assert(store:get(stalwart).targets.right.value==1150)
            assert(store:merge(jar,{}))
            local reopened=assert(open())
            assert(reopened:get(jar).targets.up.slot==3)
            assert(reopened:get(jar).targets.down.kind=='test_mode')
            local before=writes;assert(store:ensure(jar));assert(writes==before)
        """)


    def test_corruption_read_failure_and_missing_existing_file_fail_closed(self):
        self.check(r"""
            assert(store:merge(jar,{down=target(2,'test_mode',1)}))
            local good=files[path];local before=writes
            files[path]=good:gsub('schema=3','schema=999')
            assert(not open());assert(not store:clear(jar));assert(writes==before)
            assert(store:get(jar).targets.down.value==1)
            files[path]=good;read_failure=true
            assert(not store:merge(jar,{}));assert(not open());assert(writes==before)
            read_failure=false;files[path]=nil
            assert(not store:ensure(jar));assert(writes==before)
            files[path]=good;assert(store:reload())
        """)


    def test_mutations_preserve_external_valid_edits_and_refuse_races(self):
        self.check(r"""
            assert(store:merge(jar,{down=target(3,'test_mode',2)}))
            local other=assert(open())
            assert(other:merge(stalwart,{right=target(3,'rpm',1150)}))
            files[path]=files[path]:gsub('schema=3','schema=3\r\nhotkey=invalid retired key\r\ncycle_hotkey=invalid\r\ndouble_tap_ms=invalid')
            assert(store:merge(jar,{up=target(3,'zeroing',150)}))
            assert(store:get(stalwart).targets.right.value==1150)
            assert(store.hotkey==nil and store.cycle_hotkey==nil and store.double_tap_ms==nil)
            assert(not files[path]:find('hotkey=',1,true))
            race=true;local ok,err=store:clear(jar)
            assert(not ok and err:find('concurrently',1,true))
            assert(store:get(jar).targets.up.value==150)
        """)


    def test_three_presets_merge_independently_and_return_detached_records(self):
        self.check(r"""
            assert(store:merge(jar,{right=target(2,'firemode',3),up=target(3,'zeroing',150)}))
            assert(store:merge(jar,{right=target(1,'firemode',2),down=target(1,'test_mode',0)},2))
            assert(store:merge(jar,{left=target(2,'programmable_ammo',284)},3))
            assert(store:merge(stalwart,{right=target(3,'rpm',1150)},2))
            assert(store:merge(jar,{right=target(2,'firemode',3)},2))
            assert(store:get(jar).targets.up.value==150)
            assert(store:get(jar,2).targets.down.value==0)
            assert(store:get(jar,3).targets.left.value==284)
            assert(store:get(stalwart,2).targets.right.value==1150)
            local presets=store:get_presets(jar)
            assert(#presets==3 and presets[1].targets.right.value==3)
            presets[2].targets.down.value=2;presets[3].targets={}
            assert(store:get(jar,2).targets.down.value==0 and store:get(jar,3).targets.left.value==284)
            local reopened=assert(open())
            for preset=1,3 do
                assert(files[path]:find('[weapon:'..jar..':preset:'..preset..']',1,true))
            end
            assert(reopened:get(jar,2).targets.down.value==0)
            assert(reopened:get(jar,3).targets.left.value==284)
        """)


    def test_schema1_read_only_open_then_known_ensure_migrates_once_with_backup(self):
        self.check(r"""
            local old=legacy();files[path]=old;store=assert(open())
            assert(writes==0 and files[path]==old and store.migration_pending)
            assert(store:get(jar).targets.right.value==3 and store:get(jar).targets.down==nil)
            assert(next(store:get(jar,2).targets)==nil and next(store:get(jar,3).targets)==nil)
            local before=reads;assert(store:ensure(jar))
            assert(reads==before+1 and writes==1 and not store.migration_pending)
            assert(files[path]:find('schema=3',1,true) and files[path..'.bak']==old)
            assert(files[path..'.schema1.bak']==old)
            local migrated=files[path];local parsed=store.config
            assert(store:ensure(jar) and writes==1 and files[path]==migrated and store.config==parsed)
            assert(store:merge(jar,{down=target(3,'test_mode',2)},2))
            assert(store:set_flashlight(1) and files[path..'.schema1.bak']==old)
            local fresh=assert(open())
            assert(fresh:get(jar).targets.up.value==150 and fresh:get(jar,2).targets.down.value==2)
        """)


    def test_migration_failure_and_race_keep_legacy_profile_usable(self):
        self.check(r"""
            files[path]=legacy();store=assert(open());local old=files[path]
            fail_write=true
            assert(not store:ensure(jar) and store.migration_pending and writes==0 and files[path]==old)
            assert(store:get(jar).targets.up.value==150 and next(store:get(jar,2).targets)==nil)
            fail_write=false;race=true
            assert(not store:merge(jar,{up=target(1,'zeroing',25)},2))
            assert(store.migration_pending and writes==0 and next(store:get(jar,2).targets)==nil)
            race=false;assert(store:ensure(jar) and writes==1)
            assert(files[path..'.schema1.bak']==old..'; external edit\n')
        """)


    def test_global_flashlight_none_and_all_modes_survive_restart_without_weapon_records(self):
        self.check(r"""
            assert(store:get_flashlight()==nil and store.flashlight_mode=='None')
            assert(writes==0 and next(store.config.weapons)==nil)
            for value=0,2 do
                assert(store:set_flashlight(value))
                local fresh=assert(open());assert(fresh:get_flashlight()==value)
                assert(next(fresh.config.weapons)==nil)
                local before=writes;assert(store:set_flashlight(value) and writes==before)
            end
            assert(store:set_flashlight(nil))
            assert(assert(open()):get_flashlight()==nil and files[path]:find('flashlight_mode=None',1,true))
        """)


    def test_schema2_read_only_strips_lights_without_inference_and_migrates_all_presets_once(self):
        self.check(r"""
            local old=legacy2();files[path]=old;files[path..'.schema1.bak']='preserve earlier backup'
            store=assert(open())
            assert(writes==0 and files[path]==old and store.migration_pending)
            assert(store:get_flashlight()==nil and store.flashlight_mode=='None')
            for index,preset in ipairs(store:get_presets(jar)) do
                assert(preset.targets.down==nil and preset.targets.up.value==index*25)
                assert(preset.targets.right.value==3)
            end
            assert(store:ensure(jar) and writes==1 and not store.migration_pending)
            assert(files[path..'.schema2.bak']==old and files[path..'.schema1.bak']=='preserve earlier backup')
            assert(not files[path]:find('kind=flashlight',1,true))
            assert(store:get_flashlight()==nil)
            assert(store:set_flashlight(2) and store:merge(jar,{up=target(3,'zeroing',150)},3))
            assert(files[path..'.schema2.bak']==old and assert(open()):get_flashlight()==2)
        """)


    def test_two_choice_normalized_save_handles_each_selected_preset_and_merges_absent_modules(self):
        self.check(r"""
            for index=1,2 do
                for selected=1,2 do
                    files={};store=assert(open());assert(store:initialize(jar,initial_presets()))
                    for preset=1,3 do assert(store:merge(jar,{up=target(preset,'zeroing',preset*25)},preset)) end
                    assert(store:merge(stalwart,{right=target(3,'rpm',1150)}))
                    assert(store:set_flashlight(2))
                    local choices={target(1,'firemode',2),target(2,'firemode',3)}
                    local plan={qualified=true,side='right',count=2,available_count=1,choices=choices,selected=choices[selected]}
                    local before=writes
                    local ok,info=store:merge(jar,{right=choices[selected]},index,plan)
                    local complement=index==1 and 2 or 1;local cleared=3
                    assert(ok and writes==before+1 and info.complement==complement)
                    assert(#info.cleared==1 and info.cleared[1]==cleared)
                    assert(store:get(jar,index).targets.right.value==selected+1)
                    assert(store:get(jar,complement).targets.right.value==4-selected)
                    assert(store:get(jar,index).targets.up.value==index*25)
                    assert(store:get(jar,complement).targets.up.value==complement*25)
                    assert(next(store:get(jar,cleared).targets)==nil)
                    assert(store:get(stalwart).targets.right.value==1150 and store:get_flashlight()==2)
                    choices[selected].value=999;info.cleared[1]=index
                    assert(assert(open()):get(jar,index).targets.right.value==selected+1)
                end
            end
        """)

    def test_two_choice_save3_refuses_without_reload_or_mutation_and_preserves_dormant_module_preferences(self):
        self.check(r"""
            local choices={target(1,'firemode',2),target(2,'firemode',3)}
            local plan={qualified=true,side='right',count=2,available_count=1,choices=choices,selected=choices[2]}
            local before_reads=reads
            local ok,reason=store:merge(jar,{right=choices[2]},3,plan)
            assert(not ok and reason:find('only presets 1 and 2',1,true))
            assert(reads==before_reads and writes==0 and files[path]==nil and store:get(jar)==nil)
            assert(store:initialize(jar,initial_presets()))
            assert(store:merge(jar,{right=choices[2],up=target(3,'zeroing',150)},3))
            assert(store:set_flashlight(2))
            local previous=files[path];local before_writes=writes;before_reads=reads
            ok,reason=store:merge(jar,{right=choices[2]},3,plan)
            assert(not ok and reason:find('only presets 1 and 2',1,true))
            assert(reads==before_reads and writes==before_writes and files[path]==previous)
            assert(store:get(jar,3).targets.up.value==150 and store:get(jar,3).targets.right.value==3)
            assert(store:get(jar,3).targets.left.value==284 and store:get_flashlight()==2)
            local fresh=assert(open())
            assert(fresh:get(jar,3).targets.up.value==150 and files[path]==previous and writes==before_writes)
            -- An explicit allowed save may clear the old third record.
            local saved,info=store:merge(jar,{right=choices[2]},2,plan)
            assert(saved and info.complement==1 and info.cleared[1]==3)
            assert(next(store:get(jar,3).targets)==nil and store:get(jar,1).targets.up.value==150)
        """)

    def test_three_choice_save_clears_whole_duplicate_presets_by_semantic_value_only(self):
        self.check(r"""
            local choices={target(1,'rpm',700),target(2,'rpm',850),target(3,'rpm',1150)}
            for index=1,3 do
                files={};store=assert(open());assert(store:initialize(jar,initial_presets()))
                for preset=1,3 do assert(store:merge(jar,{right=target(1,'rpm',1150)},preset)) end
                local plan={qualified=true,side='right',count=3,choices=choices,selected=choices[3]}
                local ok,info=store:merge(jar,{right=choices[3]},index,plan)
                assert(ok and info.complement==nil and #info.cleared==2)
                for preset=1,3 do
                    if preset==index then assert(store:get(jar,preset).targets.right.value==1150)
                    else assert(next(store:get(jar,preset).targets)==nil) end
                end
            end
            assert(store:merge(jar,{right=target(2,'rpm',850)},1))
            assert(store:merge(jar,{right=target(3,'other_kind',1150)},2))
            local plan={qualified=true,side='right',count=3,choices=choices,selected=choices[3]}
            local ok,info=store:merge(jar,{right=choices[3]},3,plan)
            assert(ok and #info.cleared==0 and store:get(jar,1).targets.right.value==850)
            assert(store:get(jar,2).targets.right.kind=='other_kind')
            assert(store:clear(jar,1));assert(store:merge(jar,{right=choices[3]},3,plan))
            assert(next(store:get(jar,1).targets)==nil)
        """)


    @unittest.skipUnless(os.name == "nt", "Windows wide-character atomic file backend")
    def test_actual_unicode_file_create_replace_backup_and_reload(self):
        with tempfile.TemporaryDirectory(prefix="hd2-store-") as tmp:
            path = Path(tmp) / "профиль" / "76561198000000001.ini"
            self.lua.globals()[b"real_path"] = str(path).encode("utf-8")
            self.check(r"""
                real=assert(Store.open(profile,{path=real_path}))
                assert(real:ensure(jar))
                assert(real:merge(jar,{up=target(3,'zeroing',150)}))
                assert(real:merge(stalwart,{right=target(3,'rpm',1150)}))
                real=assert(Store.open(profile,{path=real_path}))
                assert(real:get(jar).targets.up.value==150)
                assert(real:clear(jar))
            """)
            self.assertTrue(path.exists())
            data = path.read_text(encoding="utf-8")
            backup = path.with_suffix(".ini.bak").read_text(encoding="utf-8")
            self.assertNotIn("up_kind=zeroing", data)
            self.assertIn("up_kind=zeroing", backup)
            self.assertIn("right_value=1150", data)
            self.assertEqual(list(path.parent.glob("*.tmp-*")), [])


    @unittest.skipUnless(os.name == "nt", "Windows invalid migration backup protection")
    def test_actual_migration_refuses_invalid_or_foreign_backup_without_overwrite(self):
        with tempfile.TemporaryDirectory(prefix="hd2-store-migrate-invalid-") as tmp:
            path = Path(tmp) / "76561198000000001.ini"
            backup = Path(str(path) + ".schema1.bak")
            old = self.lua.eval(b"legacy()")
            self.lua.globals()[b"real_path"] = str(path).encode("utf-8")
            for bad in [b"broken", old.replace(b"76561198000000001", b"76561198000000002")]:
                path.write_bytes(old)
                backup.write_bytes(bad)
                self.check(r"""
                    real=assert(Store.open(profile,{path=real_path}))
                    local ok,reason=real:ensure(jar)
                    assert(not ok and reason:find('backup is invalid',1,true))
                    assert(real.migration_pending and real:get(jar).targets.up.value==150)
                """)
                self.assertEqual(path.read_bytes(), old)
                self.assertEqual(backup.read_bytes(), bad)
                self.assertEqual(list(path.parent.glob("*.tmp-*")), [])


if __name__ == "__main__":
    unittest.main()

"""Pure flashlight controller scenarios; callbacks do not access the game."""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime


SOURCE = (Path(__file__).resolve().parents[1] / "src/weapon_defaults_flashlight.lua").read_text(encoding="utf-8")


class Fixture:
    def __init__(self, stored=None, selected=0):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.env = self.lua.execute("""
            local e={selected=0,present=true,module_bytes=string.rep('a',24),
                reads=0,loads=0,saves={},applies={},logs={},snapshot={active=true}}
            e.options={
                load=function()
                    e.loads=e.loads+1
                    return e.stored,e.load_error
                end,
                save=function(value)
                    e.saves[#e.saves+1]=value
                    if e.save_error then return nil,e.save_error end
                    e.stored=value;return true
                end,
                read=function(snapshot,sample)
                    assert(snapshot==e.snapshot,'wrong snapshot forwarded')
                    e.reads=e.reads+1;e.last_sample=sample
                    if e.read_error then return nil,e.read_error end
                    if e.observation_override~=nil then return e.observation_override end
                    return {present=e.present,selected=e.selected,module_bytes=e.module_bytes},e.partial_read_error
                end,
                apply=function(snapshot,observation,next_value,sequence)
                    assert(snapshot==e.snapshot,'wrong apply snapshot')
                    e.applies[#e.applies+1]={before=observation.selected,next_value=next_value,
                        module_bytes=observation.module_bytes,sequence=sequence}
                    if e.apply_error then return nil,e.apply_error end
                    if e.auto_apply then e.selected=next_value end
                    return true
                end,
                log=function(message)
                    e.logs[#e.logs+1]=message
                    if e.log_error then error(e.log_error) end
                end,
            }
            return e
        """)
        self.env.stored = stored
        self.env.selected = selected
        self.controller = self.lua.execute(SOURCE).new(self.env.options)
        self.identity = "weapon-a"
        self.equip()

    def equip(self, identity="weapon-a", sequence=1, time=0):
        self.identity = identity
        self.controller.equip(self.controller, identity, sequence, time)

    def step(self, time, can_apply=True, identity=None):
        self.controller.step(self.controller, self.env.snapshot,
                             self.identity if identity is None else identity, time, can_apply)

    def pause(self):
        self.controller.pause(self.controller)

    def reset(self, discard_pending=False):
        self.controller.reset(self.controller, discard_pending)

    def saves(self):
        return list(self.env.saves.values())

    def applies(self):
        return [dict(value) for value in self.env.applies.values()]

    def logs(self):
        return list(self.env.logs.values())


class FlashlightControllerTests(unittest.TestCase):

    def test_bootstrap_uses_each_actual_enum_not_assumed_off(self):
        for value in (0, 1, 2):
            with self.subTest(value=value):
                fixture = Fixture(selected=value)
                fixture.step(0)
                self.assertEqual(fixture.saves(), [value])
                self.assertEqual(fixture.applies(), [])

    def test_manual_observed_changes_replace_global_preference_once(self):
        fixture = Fixture(stored=2, selected=2)
        fixture.step(0)
        fixture.env.selected = 0
        fixture.step(0.2)
        fixture.step(0.3)
        fixture.env.selected = 1
        fixture.step(0.5)
        fixture.step(1)
        self.assertEqual(fixture.saves(), [0, 1])
        self.assertEqual(fixture.env.stored, 1)
        self.assertEqual(fixture.applies(), [])

    def test_already_correct_never_cycles_or_writes(self):
        fixture = Fixture(stored=1, selected=1)
        for time in (0, 0.11, 1, 9):
            fixture.step(time)
        self.assertEqual(fixture.applies(), [])
        self.assertEqual(fixture.saves(), [])
        self.assertEqual(fixture.env.loads, 1)


    def test_restore_uses_at_most_two_cycles_and_does_not_learn_own_intermediate(self):
        for initial in (0, 1, 2):
            for target in (0, 1, 2):
                with self.subTest(initial=initial, target=target):
                    fixture = Fixture(stored=target, selected=initial)
                    fixture.env.auto_apply = True
                    for time in (0, 0.11, 0.18, 0.25, 0.32, 0.40):
                        fixture.step(time)
                    expected_count = (target - initial) % 3
                    self.assertEqual(len(fixture.applies()), expected_count)
                    self.assertEqual(fixture.env.selected, target)
                    self.assertEqual(fixture.saves(), [])
                    self.assertEqual(fixture.env.stored, target)
                    self.assertIsNone(fixture.controller.current.awaiting)


    def test_third_value_after_single_issued_cycle_is_external_change_not_own_readback(self):
        fixture = Fixture(stored=1, selected=0)
        fixture.step(0.11)  # Own transition can produce only 1, not 2.
        fixture.env.selected = 2
        fixture.step(0.2)
        fixture.step(0.4)
        self.assertEqual(fixture.saves(), [2])
        self.assertEqual(fixture.env.stored, 2)
        self.assertEqual(len(fixture.applies()), 1)
        self.assertIsNone(fixture.controller.current.awaiting)

    def test_no_change_after_deadline_blocks_repeat_and_learning_for_this_equip(self):
        fixture = Fixture(stored=2, selected=0)
        fixture.step(0.11)
        fixture.step(0.4)
        fixture.step(0.62)
        fixture.env.selected = 1
        fixture.step(0.8)
        self.assertTrue(fixture.controller.current.blocked)
        self.assertEqual(len(fixture.applies()), 1)
        self.assertEqual(fixture.saves(), [])


    def test_absent_module_does_not_invent_preference(self):
        fixture = Fixture(stored=None)
        fixture.env.present = False
        fixture.step(0)
        fixture.step(1)
        self.assertEqual(fixture.saves(), [])
        self.assertEqual(fixture.applies(), [])
        fixture.env.present = True
        fixture.env.selected = 1
        fixture.step(2.1)
        self.assertEqual(fixture.saves(), [1])


    def test_wrong_identity_and_reset_cannot_read_or_apply_old_snapshot(self):
        fixture = Fixture(stored=2)
        fixture.step(0.11, identity="weapon-b")
        self.assertEqual(fixture.env.loads, 0)
        self.assertEqual(fixture.env.reads, 0)
        fixture.reset()
        fixture.step(0.2)
        self.assertEqual(fixture.env.reads, 0)
        self.assertEqual(fixture.applies(), [])


    def test_failed_pending_write_survives_real_equip_and_blocks_native_until_committed(self):
        fixture = Fixture(stored=2, selected=2)
        fixture.step(0)
        fixture.env.save_error = "disk full"
        fixture.env.selected = 1
        fixture.step(0.1)
        fixture.equip("weapon-b", 2, 0.2)
        fixture.env.selected = 0
        fixture.env.module_bytes = "b" * 24
        fixture.step(0.21)
        fixture.step(0.4)
        self.assertEqual(fixture.controller.pending, 1)
        self.assertEqual(fixture.controller.current.target, 1)
        self.assertEqual(fixture.applies(), [])
        self.assertEqual(fixture.saves(), [1, 1])
        fixture.env.save_error = None
        fixture.step(0.7)
        self.assertEqual(fixture.env.stored, 1)
        self.assertIsNone(fixture.controller.pending)
        self.assertEqual([row['next_value'] for row in fixture.applies()], [1])


    def test_unknown_foreground_gate_never_authorizes_native_action(self):
        fixture = Fixture(stored=2)
        fixture.step(0.11, can_apply=None)
        fixture.step(0.2, can_apply=1)
        self.assertEqual(fixture.applies(), [])


if __name__ == "__main__":
    unittest.main()

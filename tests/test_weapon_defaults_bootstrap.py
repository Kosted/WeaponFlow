"""Deferred feature registration and callback-chain checks, not gameplay tests."""
from itertools import permutations
import importlib.util
from pathlib import Path
import tempfile
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = (Path(__file__).resolve().parents[1] / "src/weapon_defaults_bootstrap.lua").read_text(encoding="utf-8")
DIAGNOSTICS_SOURCE = (Path(__file__).resolve().parents[1] / "src/weapon_defaults_diagnostics.lua").read_text(encoding="utf-8")
SPEC = importlib.util.spec_from_file_location(
    "weapon_defaults_bootstrap_builder", Path(__file__).resolve().parents[1] / "build_weapon_modes_release.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)

HARNESS = r'''
env={events={},initializations=0,updates=0,core_updates=0,shutdowns=0,logs={}}
function print(message) env.logs[#env.logs+1]=message end
function update(value)
 env.events[#env.events+1]='previous_update';env.updates=env.updates+1
 return value,nil,'tail'
end
function shutdown(value)
 env.events[#env.events+1]='previous_shutdown';env.shutdowns=env.shutdowns+1
 return 'closed',nil,value
end
function fixture_factory(selected)
 env.initializations=env.initializations+1;env.selected=selected
 env.events[#env.events+1]='factory'
 if env.factory_failure then error('fixture init failure') end
 local before=update
 local function after(...)
  env.events[#env.events+1]='core_update';env.core_updates=env.core_updates+1
  return ...
 end
 update=function(...) return after(before(...)) end
 local close=shutdown
 shutdown=function(...)
  env.events[#env.events+1]='core_shutdown'
  return close(...)
 end
 return {factory=true}
end
'''


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.env = self.lua.globals().env
        self.bootstrap = self.lua.execute(SOURCE)

    def register(self, feature="weaponflow", version="1.9.8", flavor="release", factory=None):
        # Each payload evaluates its own pure module, as BSL require does.
        module = self.lua.execute(SOURCE)
        return module.register(self.lua.table_from({
            "feature": feature, "version": version, "flavor": flavor,
            "factory": factory or self.lua.globals().fixture_factory,
        }))

    def events(self):
        return list(self.env.events.values())

    def update(self, value=17):
        return self.lua.globals().update(value)

    def diagnostics(self):
        return self.lua.execute(DIAGNOSTICS_SOURCE)

    def test_unified_addon_and_duplicate_discovery_start_exactly_once(self):
        self.register()
        self.register()
        self.assertEqual(self.env.initializations, 0)
        self.assertEqual(self.update(), (17, None, "tail"))
        self.assertTrue(self.env.selected.presets)
        self.assertTrue(self.env.selected.hud)
        self.assertFalse(self.env.selected.diagnostics)
        self.assertEqual(self.events()[:2], ["previous_update", "factory"])
        for value in (23, 31):
            self.assertEqual(self.update(value), (value, None, "tail"))
        self.assertEqual(self.env.updates, 3)
        self.assertEqual(self.env.initializations, 1)
        self.assertEqual(self.env.core_updates, 2)


    def test_mixed_versions_or_flavors_fail_closed_in_either_order(self):
        for field, value in (("version", "1.9.7"), ("flavor", "diagnostic")):
            with self.subTest(field=field):
                self.setUp()
                state = self.register()
                result, reason = self.register(**{field: value})
                self.assertIsNone(result)
                self.assertIn("mixed", reason)
                self.update()
                self.assertEqual(self.env.initializations, 0)
                self.assertEqual(state.status, "inactive")


    def test_existing_and_later_addon_wrappers_preserve_order_and_return_tuples(self):
        self.lua.execute("""
         local before=update
         update=function(...) env.events[#env.events+1]='outer_before';return before(...) end
        """)
        self.register()
        self.lua.execute("""
         local before=update
         update=function(...) env.events[#env.events+1]='outer_after';return before(...) end
        """)
        self.register()
        self.assertEqual(self.update(71), (71, None, "tail"))
        self.assertEqual(self.events(), ["outer_after", "outer_before", "previous_update", "factory"])
        self.assertEqual(self.update(72), (72, None, "tail"))
        self.assertEqual(self.events()[4:], ["outer_after", "outer_before", "previous_update", "core_update"])
        self.assertEqual(self.lua.globals().shutdown(73), ("closed", None, 73))
        self.assertEqual(self.events()[-2:], ["core_shutdown", "previous_shutdown"])


    def test_factory_failure_is_not_retried_or_allowed_to_change_previous_return(self):
        state = self.register()
        self.env.factory_failure = True
        self.assertEqual(self.update(9), (9, None, "tail"))
        self.assertEqual(state.status, "failed")
        self.env.factory_failure = False
        self.update()
        self.assertEqual(self.env.initializations, 1)
        self.assertEqual(self.env.core_updates, 0)


    def test_same_stable_companion_enables_current_and_future_main_in_all_discovery_orders(self):
        for version in ("1.9.8", "2.0.0"):
            for order in permutations(("diagnostics", "weaponflow")):
                with self.subTest(version=version, order=order):
                    self.setUp()
                    for feature in order:
                        if feature == "diagnostics":
                            marker = self.diagnostics()
                            self.assertEqual(dict(marker), {"api": 1, "enabled": True, "version": "1.0.0"})
                        else:
                            self.register(feature, version=version)
                    self.assertEqual(self.env.initializations, 0)
                    self.assertEqual(self.update(84), (84, None, "tail"))
                    self.assertEqual(self.events()[:2], ["previous_update", "factory"])
                    self.assertTrue(self.env.selected.diagnostics)
                    self.assertTrue(self.env.selected.presets)
                    self.assertTrue(self.env.selected.hud)
                    self.update()
                    self.assertEqual(self.env.initializations, 1)


if __name__ == "__main__":
    unittest.main()

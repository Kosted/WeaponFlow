"""Run only the changed WeaponFlow area. Fake game data; no live-game proof."""
from pathlib import Path
import argparse
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
sys.path.insert(0,str(ROOT/'tests'))
GROUPS={
    'controls':('weaponflow_required_bindings','native_mod_bindings','native_mod_binding_defaults',
                'native_preset_input_gate','weapon_defaults_menu_state','weapon_defaults_reset'),
    'presets':('native_saved_defaults','weapon_defaults_store','weaponflow_presets_transfer','weapon_defaults_capture',
               'weapon_defaults_flashlight','native_flashlight_state','native_weapon_modes',
               'native_programmable_ammo','native_laser_guide','native_secondary_fire',
               'native_equip_context','native_live_map_header'),
    'hud':('weapon_hud_layout','weapon_hud_render','weapon_defaults_help_model',
           'weapon_defaults_help_hud','native_weapon_hud_icons','native_weapon_ui','weaponflow_text'),
    'packaging':('weapon_modes_release','weapon_defaults_bootstrap'),
}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('areas',nargs='+',choices=(*GROUPS,'all'))
    args=p.parse_args()
    areas=tuple(GROUPS) if 'all' in args.areas else args.areas
    names=list(dict.fromkeys('test_'+module for area in areas for module in GROUPS[area]))
    suite=unittest.defaultTestLoader.loadTestsFromNames(names)
    result=unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() else 1

if __name__=='__main__':raise SystemExit(main())

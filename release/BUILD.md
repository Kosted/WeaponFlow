# WeaponFlow 1.9.9: build and diagnostics

Run commands from this project's
source checkout. Python 3.10+ and a separate checkout of
CowboyBingus/BingusSharedLoader containing `scripts/build_addon.py` are required.
The main mod's production Lua remains embedded in its deployable patch
resources, without an additional source bundle. The companion includes its own
single source file, not the main mod's implementation. The loader and its
implementation are not redistributed here.

```powershell
python build_weapon_modes_release.py --bsl-source 'C:\path\to\BingusSharedLoader'
```

The default `--flavor both` produces **WeaponFlow-v1.9.9.zip** and the
separately versioned **Weapon-Defaults-Diagnostics-Addon-v1.0.0.zip** in `dist/`.
Use `--flavor release` for the main mod only or `--flavor diagnostics-addon`
for the companion only. Combined sources are generated locally for the single
main payload (`weaponflow`) and the small companion.
Existing ZIPs are never overwritten; previous releases remain preserved.
Archive timestamps and file order are deterministic.

The main Arsenal display name is **WeaponFlow**. The diagnostics companion
keeps its existing archive name and version; the stable API 1 protocol has not
changed. Runtime resource names and the existing profile directory remain
compatible with earlier Weapon Defaults releases.

The main ZIP has one top-level manifest option, **WeaponFlow**, including
`Addon/` with no suboptions. Presets and HUD share one runtime resource,
`mods/constantin/weapon_modes_trial`, retaining its hash, package GUID and
duplicate-load sentinel. Disabling this option deploys nothing. Icon, Text and
Icon and text are runtime presentation choices, not repeated install payloads.

The one main resource embeds each production component once. It is encoded
once before publication.
The main ZIP retains `THIRD-PARTY-NOTICES.md`, `FONT-LICENSE.txt` and
`CJK-FONT-LICENSE.txt` for its
embedded production assets. No core source bundle, game textures, shaders,
user settings, logs or research captures are copied into either ZIP. The
generated icon masks and localization lookup remain embedded production data.

## Current runtime

Mod Bindings Menu v2.1 is required. The game owns hotkey assignments,
persistence and all eight trigger types. Opening MODS is for editing controls,
never a startup gate. WeaponFlow does not import or synchronize a controls INI.

- `weaponflow_game_controls.lua`: native record normalization, descriptions and
  initial defaults. No file reader/writer or Windows trigger reconstruction.
- `weaponflow_mod_bindings.lua`: four stable public actions, guarded native
  snapshots, engine events and scoped initial/default Reset publication. No retired assignment action.
- `weaponflow_input.lua`: actual remapped card control, native event guards,
  numbered capture and indicator movement. All four commands use native events;
  game-control overlaps do not reject them. Swap assignment is MODS-only.
  A scoped physical-key handler supplies fixed F9 in either visible panel,
  F10 in property help and C/V in preset help. Double pressing the preset-menu button clears presets.
  A GetKeyboardState observer runs only with visible, current help and updates
  the last-pressed label. Accepted mapped native action labels cover inputs
  without a Windows key state. This observer never emits commands.
- `native_weapon_defaults.lua`: equipment identity, preset application and
  shared flashlight orchestration. Utility returns preserve current modes.
- `weapon_defaults_store.lua`: three partial-merge presets by weapon resource,
  persistent global flashlight, schema migration and atomic own-file writes.
- `weaponflow_presets_transfer.lua`, `weaponflow_clipboard.lua`: validated
  account-wide preset replacement and Unicode clipboard access. Parse failure
  changes no profile data. The bundled `weaponflow_default_presets.lua` contains
  the approved starter presets. Only a missing profile or explicit Reset loads
  this pack; normal startup preserves existing preferences.
- `weapon_defaults_capture.lua`: available current-instance choices and saved
  semantic targets, including modular optics and secondary fire.
- `weapon_defaults_hud.lua`, `weapon_defaults_help_model.lua` and
  `weapon_defaults_help_hud.lua`: indicator and contextual panels. Shared
  stock-icon masks, 14 locale catalogs and antialiased Latin/Cyrillic/Asian
  fonts are embedded Lua assets. Asian masks decode lazily from immutable packed
  data, with regional glyph forms. Native weapon captions are matched by exact ID.

Presets, HUD and one-time initialization state use the profile's `.ini`,
`-HUD.ini` and `-Menu.ini`. Existing schema-compatible retired metadata may
remain in those files but never controls game actions. Reset backs up/replaces only these three files and clears the four owned native
IDs. Preset/HUD files contain preferences and the menu file contains one-time
initialization markers and the selected language. Controls come only from the game through MBM; obsolete
control headers are ignored on read and omitted on the next own-file save.

Initial actions are P/Press and H/Press. Swap and Reset
start unassigned. The actual game card key gates menus and numbered saving.
The first card+H opens property help; later accepted H presses cycle available
non-light values. Arrows move only the separate indicator while property help
and the held card remain valid. Contextual help is fixed and uses actual
keycaps and semantic saved-choice icons. Only preset help retains the MODS
settings route. System keys
require actual visible help, card, focus and equipped-instance evidence.
F9 rebuilds visible help immediately; F10 cycles the indicator's display format
only in property help, updates its yellow selection immediately and saves the
global `display=icon/text/both` preference in the existing `-HUD.ini` schema2.
An absent field defaults to both without a write; failed saves preserve the
current format. Per-weapon property choices and position remain intact.
C/V require the preset panel. V validates
the entire clipboard before replacing account presets; flashlight/HUD stay separate.

## Preservation and native evidence

Do not write game input files or call the whole-input serializer/reset API.
Any explicit native publication verifies ownership, the active profile and
complete 328-byte owned buckets; unknown reads and foreign changes abort.
Unbinding zeros all 16 records. Ordinary startups and remaps make no writes.
Initial defaults require the durable own marker, confirmed unbound actions,
absence of an explicit game override and fresh gameplay/profile guards.

The native readers carry build fingerprints, offsets and validation guards.
A game update requires re-establishing these contracts against the game.
Do not infer live semantics from mocked memory or a passing package check.

Rebuilding a package uses the existing embedded Lua icon, font and localization
assets. Pillow and original font sources are not build or runtime dependencies.
The glyph masks derive from Liberation Sans Bold and regional Noto Sans CJK Bold;
their licenses and provenance are described in the included third-party notices.
Local research captures, game disassembly and source-asset extraction are not
part of this repository.
The optional diagnostics companion keeps its stable API and version; enable it
beside the main mod for local logs without replacing the release package.

## Development checks

Run the changed area once: `python tests/run_checks.py controls`, `presets`,
`hud` or `packaging`. A coordinated release can use `all`. These checks use fake
native memory/files and do not establish in-game success. Do not reset the real
player profile or repeat already confirmed game scenarios for routine builds.

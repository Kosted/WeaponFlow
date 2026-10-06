# Asset origins

## Required key-binding integration

WeaponFlow integrates with **Mod Bindings Menu v2.1**, by **CowboyBingus**,
through its addon API. Install it separately to use and configure WeaponFlow controls
in the game's MODS tab. The dependency itself is not bundled with WeaponFlow.

- https://www.nexusmods.com/helldivers2/mods/16478
- https://github.com/CowboyBingus/ModBindingsMenu

## Game icon assets

The optional HUD uses stock Helldivers 2 weapon-function icon shapes from
`content/ui/mission/hud/weapon_function/`. The lookup contains all 42 extracted
symbols because ammunition choices can use icons such as airstrike or burst.
The HUD displays fire mode, ammunition, RPM, optic distance, secondary fire or
laser guidance. Flashlight is excluded. A graphic in this lookup does not establish that a setting is
available or readable on the current weapon.
The underlying designs belong to Arrowhead Game
Studios and Sony Interactive Entertainment/their respective rights holders.
They are not original artwork created for Weapon Defaults.

The icons were extracted from the installed game using Filediver and converted
into rectangle data for the game's Lua screen GUI. The green fill channel is
used as a monochrome mask, preserving its original pixels and alpha values
without resizing or quantization. The original material's shader appearance
and blue-channel outline are not reproduced. The two rectangular source
symbols receive transparent padding to preserve their proportions.

The drawing approach was informed by **HD2 Weapon HUD 0.0.2**, by **DDRK1NG**:
https://www.nexusmods.com/helldivers2/mods/15298
No source code or icon data from that mod is included in Weapon Defaults.

This is an unofficial modification and is not endorsed by the game's creators.

## HUD labels

The numeric and short text labels use **Weapon Defaults HUD Label**, a baked
antialiased Latin/Cyrillic subset derived from Liberation Sans Bold. This derivative name
does not use the original font's reserved name. The original font is by the
Liberation Fonts project, with digitized-data copyright 2010 Google Corporation
and copyright 2012 Red Hat, Inc. The masks are distributed under the SIL Open
Font License 1.1; the full notices and license are in `FONT-LICENSE.txt`.
These labels are separate from the game icons described above. No font
installation is needed and the game's font/material loader is not used.

Japanese, Korean, Simplified Chinese and Traditional Chinese use regional
**Noto Sans CJK Bold** masks, aligned to the same text baseline. Noto CJK is
Copyright 2014–2021 Adobe (http://www.adobe.com/) and licensed under the SIL Open
Font License 1.1. The complete notices and license are in
`CJK-FONT-LICENSE.txt`. Only the needed raster glyphs are embedded; original
font files are not bundled. Source: https://github.com/notofonts/noto-cjk

## HUD text labels

A bounded lookup of short labels for all supported game text languages was extracted from the installed
game's localization resources using Filediver. The addon looks up the native
localization ID of the actually selected ammunition record; it does not
substitute projectile numbers or texture filenames. The original strings
belong to the game's respective rights holders, as do the stock icons above.

# WeaponFlow

Package: **WeaponFlow-v1.9.9.zip**. Русская инструкция: **README-RU.md**.

**Your settings when you equip. One button to switch them in combat.**

- **Your defaults.** Return to your chosen fire mode, ammo and RPM whenever you equip a weapon.
- **One button in combat.** Switch up to three presets—even while aiming in first or third person, or while firing.
- **Your mode at a glance.** An optional HUD shows ammo, Safe/Unsafe, RPM or another setting you choose.

## Quick start

Install **WeaponFlow** through **HD2 Arsenal** with **Bingus Shared Loader v17**
and **[Mod Bindings Menu v2.1](https://www.nexusmods.com/helldivers2/mods/16478)**.
Enable **WeaponFlow**. Controls work at startup;
open **Options → Mouse & Keyboard → MODS → WeaponFlow** to change them.

**R means your weapon-menu button**—use your own binding if you changed it. Wait for the menu to open and keep holding the button.

**Preset 1 is your default on equip.** Use the other available presets for alternatives.

1. **Save:** equip a weapon and choose its settings. Hold **R**, tap **P**, then press an available number: **1**, **2** or **3**.
2. **Switch:** assign **Swap presets** in **Options → Mouse & Keyboard → MODS → WeaponFlow**. Press your chosen button to cycle presets—**without R**.
3. **Clear:** hold R and **double-tap P within 0.3 seconds**. This clears **all three presets for this weapon type**, including its default.

Clearing leaves the weapon's current settings unchanged. It does not clear your shared flashlight preference.

## Help while you configure

**Hold R and tap P** to see saved values, the default preset, your swap hotkey and the settings path. P can be released; number keys save while R stays held. Release R to close help.

**Hold R and tap H** to open HUD help without changing the indicator. Further H presses choose its displayed setting or **Hide**. While this help is open, use the **arrow keys** to move the indicator; H need not stay held. This help stays until you release R. Both panels show the held weapon-menu button and the last button you press while help is open. Values update as settings change. An unassigned swap button is marked **Assign it in settings!** in preset help.

The fixed help panel sits near the bottom of the screen, separate from the movable mode indicator.

Saved preset values appear as game icons joined by **+**, with RPM and scope numbers kept beside them. Missing icons fall back to readable values. A dark translucent background keeps the help readable; yellow button badges show your actual keyboard and mouse bindings, including remapped keys.

## Choose what you see

Choose which setting to show for each weapon, or hide the HUD. Selection skips the flashlight and settings the weapon in your hands doesn't have, including missing attachments. Each weapon type remembers your choice.

Show **Safe/Unsafe on your Railgun**, **ammo on your Autocannon**, or **RPM on your machine gun**. The indicator follows the actual current mode, including manual changes.

With HUD help open, press **F10** to cycle **Icon**, **Text**, or **Icon and text**. All three are listed; your current format is yellow. This choice is saved for your profile. Choose a text option to see numeric RPM and scope values. All game text languages are included.

Reposition the indicator with the shortcut below: tap for small adjustments, hold to move faster. Its position is saved. You can hide it for any weapon without clearing that weapon's presets.

## Controls at a glance

For shortcuts that include R, keep it held so the weapon menu stays open.

| Action | Controls |
| --- | --- |
| Save or replace a preset | Hold **R**, tap **P**, then press an available **1**, **2** or **3** |
| Clear all three presets, including the default | Hold **R**, double-tap **P** within 0.3 seconds |
| Switch presets | Your assigned button, **without R** |
| Open HUD help / change its setting | Hold **R**: first **H** opens help, further taps change the setting |
| Change Icon / Text / Icon and text | **F10**, only while HUD help is open and **R** stays held |
| Move the HUD | Hold **R**, tap **H**, then use **arrow keys** |

## Your weapons, your settings

- **Starter presets are included.** A new profile starts with the bundled pack; you can replace or clear any weapon's presets.
- **Every copy uses your presets**, including weapons picked up from other players. Your choices persist between missions and game sessions.
- **Manual changes last until the next equip or preset switch.** Stims and grenade throws don't reset them while the weapon stays in your inventory.
- **Missing attachments preserve saved choices.** Updating a preset without an adjustable scope keeps its saved scope setting for a compatible attachment.
- **Empty presets are skipped.** Clear all three to stop preset restoration for that weapon; its current modes stay unchanged. The shared flashlight preference still applies when you equip.

Presets support fire mode, Safe/Unsafe, primary/secondary or underbarrel fire selection, ammo and detonation type, RPM, scope distance and laser guidance.

**One flashlight preference for all weapons.** Select Auto, On or Off normally in the game. WeaponFlow remembers your latest choice and applies it whenever you equip a weapon with a flashlight. No save shortcut is needed. The flashlight is separate from presets and the HUD; switching or clearing presets does not reset it.

**A weapon with just one setting besides the flashlight:** with two choices, use only presets **1 and 2**. Saving either fills the other with the opposite choice; preset 3 is unavailable. With three choices, saving clears any other preset containing the same value; different values stay as they were. These rules use the attachments currently on the weapon.

## Language and sharing presets

**Auto** follows the game's text language and uses English when that language is
unavailable. With either help panel open, **F9** cycles **Auto**, English and the other available languages.
HUD text and WeaponFlow's action names in MODS change immediately. The choice is saved.

Included: English, Russian, French, German, Italian, Polish, Japanese, Korean,
Spanish (Spain and Latin America), Portuguese (Portugal and Brazil), and
Simplified/Traditional Chinese. Weapon settings use their localized game names.

With **preset help open**, **C** copies all account presets to the clipboard.
**V** imports from the clipboard, **replacing all account presets**. Invalid
preset text is ignored without changing anything. Flashlight and HUD preferences
are separate from transferred presets. F9, C and V are fixed shortcuts, active
only in their respective help panels.

## Hotkeys and settings

Requires **[Mod Bindings Menu v2.1](https://www.nexusmods.com/helldivers2/mods/16478)**.
Open **Options → Mouse & Keyboard → MODS → WeaponFlow** to set your controls.
The four actions are **Preset menu**, **Swap presets**, **HUD menu** and **Reset mod**.
Preset/HUD menus default to **P/H, Press**. Clear uses a double press of your
current Preset menu button; it has no separate MODS row.

Choose a button and its activation type: Press, Release, Hold, Long Press,
Tap, Double Tap, Long Hold or Long Release. The game processes these inputs.
Held actions activate once per hold. Clearing a binding disables that action.
Swap presets and Reset mod start unassigned. Assign the swap button in MODS.

WeaponFlow uses the bindings accepted by Mod Bindings Menu v2.1 and evaluated
by the game. Help displays your actual bindings.

**Reset mod** restores the bundled starter presets, clears the shared flashlight
preference and HUD settings, and resets WeaponFlow controls, including its own
assignment. P/H return to their initial bindings. A backup is kept; game and
other-mod controls are preserved.

Your presets, HUD choices and hotkeys persist between sessions.
The game stores hotkeys; WeaponFlow reads its current assignments.
Existing choices are retained when updating WeaponFlow.

The optional **Weapon-Defaults-Diagnostics-Addon-v1.0.0.zip** enables detailed
logs alongside WeaponFlow and is not needed for normal play.

## Credits

**CowboyBingus** — Bingus Shared Loader. **DDRK1NG** — rendering inspiration. **Filediver** — resource extraction. **Liberation Fonts and Noto** — HUD fonts. Game icons and strings belong to the Helldivers 2 rights holders. Full notices and font licenses are included in the download.

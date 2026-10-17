# Changelog

## 2.1.5

### Changes since 2.0.0

- Added Mod Bindings Menu 2.2 support, fixing inactive hotkeys and blank labels; 2.1 remains supported.
- Improved default restoration after rapid weapon switches, drops and pickups.
- Preserved flashlight changes made immediately before switching weapons.
- Improved HUD accuracy after delayed mode changes.
- Reduced background checks during gameplay.

## 2.1.4

- Fixed shared flashlight settings not applying after weapon switches and pickups.
- Added compact flashlight application details to the normal log.

## 2.1.3

- Fixed shared flashlight memory missing manual changes when switching to another weapon.
- Fixed missed equipment notifications in the new event handling.

## 2.1.2

- Fixed the startup failure that prevented WeaponFlow's presets and HUD from appearing.
- Retained game-event updates for equipment, flashlight memory and the indicator, without background equipment scanning.

## 2.1.1

- Report the exact event-observer startup stage, Windows API and error instead of a generic failure.

## 2.1.0

- Weapon equips, shared flashlight memory and the mode indicator now react to game events, reducing background reads.
- Track rapid weapon switches and drop/pickup transitions between updates.
- Preserve a flashlight selection made immediately before switching weapons.
- Refresh the indicator after delayed network mode changes without polling unchanged settings.

## 2.0.0

- Jump straight to the saved RPM, scope distance or fire mode when a three-choice setting would otherwise need two steps. Two-choice and adjacent selections keep their single native action.
- Verify the final slot and actual RPM after a direct selection; stop uncertain actions without cycling or retrying them.

## 1.11.1

- Style the welcome and both help panels with a charcoal gradient, clipped corners, a fine border, yellow accent and section dividers.

## 1.11.0

- Added a first-run checklist in missions: open presets, open HUD settings, assign Swap presets. Progress persists; the window disappears after all three steps and hides in game menus.
- Hide movement arrows that point beyond the screen and explain how to reveal a hidden HUD beside its preview.
- Briefly flash the mode indicator gold when its actual displayed value changes during gameplay.
- Removed held-button status and the settings route from contextual help. The welcome window includes the settings route.
- Refined the new instructions across all 14 languages; localized arrow labels and combined trigger descriptions.
- Use Exo 2 Medium/Bold with cached pixel filtering. Completed checklist crosses are gold.

## 1.10.2

- Highlight saved choices directly on the weapon wheel with P1/P2/P3 tags.
- Highlight the displayed property and HUD while configuring it, with arrow-key hints and a translucent hidden-HUD preview.
- Use rounded yellow brackets with a gentle periodic shimmer: top/bottom for side properties, left/right for vertical properties and the HUD. Keep the help panels compact without repeating wheel values or movement hints.

## 1.9.10

- Language now follows the game automatically; removed manual language switching.
- HUD help shows the current property as its game icon, with numeric RPM and scope captions.
- Improved HUD colors and layering.
- Reduced repeated profile discovery and input parsing; improved compatibility with other mods.
- Added native Steam profile detection for Proton.

## 1.9.9

- Read native function 10 (C4) for preset capture/restoration and both HUD panels; use its actual resource icons and localized captions.
- Include the approved saved preset pack for new profiles and Reset. Existing profiles keep their presets on ordinary startup.
- Report unreadable preset capabilities in diagnostics instead of silently hiding the panel.

## 1.9.8

- Combine presets and HUD into one Arsenal option and one addon payload.
- Choose Icon, Text or Icon and text with F10 while HUD help is open. Show all formats and highlight the current one in yellow.
- Save the display format per profile, separately from weapon presets and displayed-property choices. Localize the new controls in all 14 languages.

## 1.9.7

- Align words on a shared baseline, including Cyrillic accents and descenders.
- Localize HUD/help and MODS labels for all 14 game text languages. Use matching stock choice captions and regional antialiased Japanese, Korean and Chinese glyphs.
- Remove the settings-path hint from HUD configuration help; retain it in preset help.
- Show a localized instruction to assign the swap button when it is unbound.
- Show the last keyboard/mouse button pressed after opening help beside the held-card button. Accepted mapped game actions also supply their button labels.

## 1.9.6

- Add Russian HUD/help and MODS labels, stock Russian weapon-choice captions and an antialiased Cyrillic font.
- Add automatic game-text language detection for HUD and action names.
- Reduce MODS to four actions. Clear presets uses a double press of the Preset menu button.
- Add C/V clipboard export/import in preset help. Valid imports replace all account presets; invalid text changes nothing.
- Correct first-use P/H initialization while preserving existing and explicitly cleared game assignments.
- Accept verified native bindings without key-name restrictions, within Mod Bindings Menu v2.1's own filtering.
- Replace first-equip preset generation with the importable defaults mechanism; the bundled defaults pack is empty.

## 1.9.5

- Read command bindings and compare conflicting mod actions by native device/button IDs.
- Keep HUD captions independent: unknown names or failed caption APIs cannot disable commands.
- Preserve game-evaluated triggers and physical release guards without resolving button names.

## 1.9.4

- Accept the Tilde key and its Grave, Backtick and OEM3 aliases for MODS bindings.
- Show the unsupported native button's device, name and ID in binding diagnostics.

## 1.9.3

- Remove game-control conflict filters, including the Mouse4/Mouse5 Swap rejection.
- Use one required Mod Bindings Menu path for all five commands.
- Remove retired key assignment, standalone gestures, input-file persistence and hotkey metadata writers.
- Keep presets, HUD preferences and safe native Reset; Reset clears the five current actions.

## 1.9.2

- Use game-owned assignments directly; remove file imports and the MODS startup gate.
- Observe native remaps, unbinding and input reloads without restoring stale buttons.
- Keep one-time initial P/H/Clear and explicit owned Reset; never seed Swap or Reset.
- Remove the redundant SAVE PRESETS: HOLD line from preset help.

## 1.9.1

- Assign the swap button only through MODS; remove R + K capture and Set swap key.
- Show the actual held weapon-menu key and the settings path in both help panels.
- Clarify property and swap-hotkey labels; retain existing saved controls and presets.

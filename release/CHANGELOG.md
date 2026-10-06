# Changelog

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
- Follow the game's text language by default; F9 cycles Auto, English and Russian while help is open.
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

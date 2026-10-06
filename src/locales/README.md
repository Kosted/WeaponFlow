# WeaponFlow locale catalogs

`en.lua` contains the stable English message IDs. Additional catalogs use the
same shape: `{mod="weaponflow", language="fr", strings={...}}`. Place them
beside it; the source assembler includes them. Missing strings fall back to
English. Keep every named placeholder (`{card}`, `{key}`, `{preset}`, etc.).
Placeholders may be reordered; hotkey/keycap highlighting is retained.

MBM2.1 translation add-ons can also provide strings under
`BingusTranslations.packs[].mods.weaponflow`. Language tags are compared
without case; WeaponFlow reads the shared registry without changing it.
Native choice captions may be translated by their exact string ID, for example
`game.0123ABCD`. These are display strings, not weapon IDs or preset values.

All 14 game text languages are bundled: `en`, `ru`, `fr`, `de`, `it`, `es`,
`es-419`, `pt`, `pt-br`, `pl`, `ja`, `ko`, `zh-hans`, `zh-hant`. English UK/US
use the same English catalog. Both HUD renderers validate UTF-8 and measure/wrap
whole glyphs. Rich words share a common baseline, including accents.

Latin/Cyrillic glyphs derive from Liberation Sans Bold; Japanese, Korean and
Chinese use their regional Noto Sans CJK Bold forms. The latter are packed
immutable masks and decode only when used. The prepared masks are embedded in
`weapon_defaults_hud_font.lua`; normal builds do not regenerate them.
Keep both font licenses. Unsupported translated HUD lines fall back to English.
Native MODS labels use the game's fonts. Complex shaping and right-to-left
layout require a separate renderer step; they are not implemented.

Language defaults to the game's **Text Language**, read before MODS opens.
Auto uses English when there is no catalog for that language; a translation
pack's forced override does not change WeaponFlow's Auto selection. The
fixed F9 key cycles Auto, English and the other available catalogs only while
one of WeaponFlow's contextual help panels is visible and the actual card
control stays held. It has no MODS assignment. Its choice is stored in the own
Menu.ini; HUD text rebuilds in the same accepted frame. MODS captions use that
choice when the bindings page opens. C/V are likewise fixed keys, available
only in the visible preset panel for account preset copy/replacement.
F10 is fixed too: it cycles Icon, Text and Icon and text only in visible property
help. Those choices use localized labels, with the current choice highlighted
yellow. The format is stored separately in the HUD profile.
An optional `language=auto` / `language=en` / another language tag in
`<SteamID64>-Menu.ini` selects it at startup. Change that field with the game
closed. It contains no hotkey assignments. Reset mod restores Auto. Only tags
with actual catalogs produce translated text.

## Adding another language

Copy `en.lua` to `<language>.lua`, change its language tag, and
translate every value in `strings`. Keep the message IDs and named placeholders
unchanged; `{card}` and `{key}` still describe the player's actual assignments.
Add any missing glyphs with the font generator before publishing the catalog.
The assembler includes the new file on the next build; putting an unpackaged
Lua catalog beside an already deployed addon does not update its payload.

For ammunition/secondary-mode names, add their actual game string IDs as
`["game.0123ABCD"]="..."`. These translations can live in the same catalog.
They are looked up against a verified native offered choice, not a weapon-name
or slot guess. UI key names retain the actual remapped input labels.

Every translated catalog contains WeaponFlow's own messages and stock
choice captions matched by their exact game IDs. When adding captions,
preserve these IDs, use the game's wording and check embedded font coverage.
Keep own
messages and native captions in the same catalog: registering a second catalog
with the same language tag replaces the previous one.

from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def load_text(lua):
    lua.globals().EnglishText=lua.execute((ROOT/'src/locales/en.lua').read_text(encoding='utf-8'))
    lua.globals().Text=lua.execute((ROOT/'src/weaponflow_text.lua').read_text(encoding='utf-8'))
    return lua.globals().Text

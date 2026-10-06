"""Input parser/gating checks with fake registry/files/keys; no game input sent."""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime
from text_fixtures import load_text

SOURCE = (Path(__file__).resolve().parents[1] / "src/weaponflow_input.lua").read_text(encoding="utf-8")
LOGIN = '"users" { "76561198000000001" { "AccountName" "player" } }'
CONFIG = '''// override
Avatar = { WeaponFunctionOpen = [
 { device_type="Keyboard" input_type="Button" input="r" trigger="LongPress" fixed_layout_id=19 }
] }'''


class Fixture:
    def __init__(self, config=CONFIG, login=LOGIN, active=39734273):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        load_text(self.lua)
        self.lua.globals().Bindings=self.lua.execute((Path(__file__).resolve().parents[1]/"src/weaponflow_game_controls.lua").read_text(encoding="utf-8"))
        self.module = self.lua.execute(SOURCE)
        self.keys = set()
        self.active = active
        self.errors = {}
        self.file_reads = []
        self.registry_reads = 0
        self.key_reads = []
        self.diagnostic_reads = 0
        self.diagnostic_failure = None
        self.files = {
            r"C:\Steam\config\loginusers.vdf": login,
            r"C:\Steam\userdata\39734273\553850\remote\input_settings.config": config,
        }
        self.scans = []
        self.scan_mapping = {19: 82, 20: 84, 0xE01D: 163}
        adapter = self.lua.table_from({
            "registry_string": lambda key, name: r"C:\Steam" if name == "SteamPath" else None,
            "registry_dword": self.registry_dword,
            "getenv": lambda name: r"C:\Roaming",
            "read_file": self.read_file,
            "map_scan": self.map_scan,
            "key_down": self.key_down,
            "diagnostic_keys": self.diagnostic_keys,
        })
        self.adapter = adapter
        result = self.module.new(self.lua.table_from({"adapter": adapter}))
        if isinstance(result, tuple):
            self.obj, self.error = result
        else:
            self.obj, self.error = result, None

    def read_file(self, path):
        self.file_reads.append(path)
        if path in self.errors:
            return None, self.errors[path]
        if path not in self.files or self.files[path] is None:
            return None, "missing"
        return self.files[path]

    def map_scan(self, scan):
        self.scans.append(scan)
        return self.scan_mapping.get(scan, 0)

    def registry_dword(self, key, name):
        self.registry_reads += 1
        return self.active

    def key_down(self, vk):
        self.key_reads.append(vk)
        return vk in self.keys

    def diagnostic_keys(self):
        self.diagnostic_reads += 1
        if self.diagnostic_failure == "exception":
            raise RuntimeError("snapshot failed")
        if self.diagnostic_failure == "missing":
            return None, "thread key state unavailable"
        if self.diagnostic_failure == "incomplete":
            return self.lua.table_from({})
        return self.lua.table_from({vk: vk in self.keys for vk in range(1, 256)})

    def poll(self, time=0, foreground=True, controls=None):
        options = self.lua.table_from(controls) if controls is not None else None
        return self.obj.poll(self.obj, time, foreground, options)

"""Distribution-builder invariants; not an in-game behavior test.

The injected test encoder emits synthetic Addon bytes. Game archive encoding
belongs to BSL's external build_addon, not these packaging fixtures.
"""
from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock
import zipfile

try:
    from lupa.luajit21 import LuaRuntime
except ImportError:
    LuaRuntime = None

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("weapon_defaults_release_builder", ROOT / "build_weapon_modes_release.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


def fake_encoder(name, source, guid, output, title):
    """Package structure only; synthetic source bytes replace game encoding."""
    manifest = {"Version": 1, "Guid": guid, "Name": title,
                "Options": [{"Name": title, "Include": ["Addon"]}]}
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("manifest.json", json.dumps(manifest))
        archive.writestr("Addon/" + BUILD.ARCHIVE, source)
        archive.writestr("Addon/" + BUILD.ARCHIVE + ".stream", b"")
        archive.writestr("Addon/" + BUILD.ARCHIVE + ".gpu_resources", b"")


class ReleaseBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="weapon-defaults-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("src", "release", "tests", "generated", "private"):
            (self.root / directory).mkdir()
        for label, filename in BUILD.COMPONENTS:
            (self.root / "src" / filename).parent.mkdir(parents=True,exist_ok=True)
            (self.root / "src" / filename).write_text(f'return {{component="{label}"}}\n', encoding="utf-8")
        shutil.copyfile(ROOT / "src/weapon_defaults_bootstrap.lua", self.root / "src/weapon_defaults_bootstrap.lua")
        shutil.copyfile(ROOT / "src" / BUILD.DIAGNOSTICS_SOURCE, self.root / "src" / BUILD.DIAGNOSTICS_SOURCE)
        (self.root / "src/native_weapon_defaults.lua").write_text(
            'if rawget(_G,"ConstantinWeaponModesTrial") then return rawget(_G,"ConstantinWeaponModesTrial") end\n'
            'local state={version=BuildConfig.version,diagnostics=BuildConfig.diagnostics}\n'
            'rawset(_G,"ConstantinWeaponModesTrial",state)\nreturn state\n', encoding="utf-8")
        for name in BUILD.DOCUMENTS:
            (self.root / "release" / name).write_text("Public documentation: " + name + "\n", encoding="utf-8")
        (self.root / "release/BUILD.md").write_text("Use an external BSL v17 source checkout.\n", encoding="utf-8")
        shutil.copyfile(ROOT / "build_weapon_modes_release.py", self.root / "build_weapon_modes_release.py")
        shutil.copyfile(Path(__file__), self.root / "tests/test_weapon_modes_release.py")
        # Deliberate privacy canaries beside eligible directories.
        self.private_canary = b"DO-NOT-SHIP" + bytes(range(32))
        for name in ("private/WeaponDefaultsNative.log", "src/private-settings.json",
                     "generated/game-code.bin", "tests/unrelated-private-test.py",
                     "release/private-note.md"):
            (self.root / name).write_bytes(self.private_canary)

    def build(self, **kwargs):
        return BUILD.build_variants(self.root / "unused-bsl", root=self.root, builder=fake_encoder, **kwargs)

    def distribution(self, **kwargs):
        return BUILD.build_distribution(self.root / "unused-bsl", root=self.root, builder=fake_encoder, **kwargs)

    def archive_files(self, path):
        with zipfile.ZipFile(path) as archive:
            self.assertIsNone(archive.testzip())
            return {name: archive.read(name) for name in archive.namelist()}


    def test_release_has_only_one_install_payload_and_public_documents(self):
        path = self.build(flavors=("release",))[0]
        self.assertEqual(set(self.archive_files(path)), {
            "manifest.json", *BUILD.DOCUMENTS,
            *(folder + "/" + BUILD.ARCHIVE + suffix
              for _, folder, _, _, _ in BUILD.PAYLOAD_OPTIONS for suffix in ("", ".stream", ".gpu_resources")),
        })

    def test_single_arsenal_option_encodes_and_deploys_one_resource(self):
        encoded = []
        def encoder(*args):
            encoded.append(args[0])
            fake_encoder(*args)
        path = BUILD.build_variants(self.root / "unused-bsl", root=self.root,
                                    builder=encoder, flavors=("release",))[0]
        files = self.archive_files(path)
        option, = json.loads(files["manifest.json"])["Options"]
        self.assertEqual(option["Name"], "WeaponFlow")
        self.assertEqual(option["Include"], ["Addon"])
        self.assertNotIn("SubOptions", option)
        self.assertEqual(encoded, [BUILD.NAME])
        deployed = {name: data for name, data in files.items() if name.startswith("Addon/")}
        self.assertEqual(len(deployed), 3)
        self.assertTrue(deployed["Addon/" + BUILD.ARCHIVE].startswith(("-- HD2-Addon: " + BUILD.NAME).encode()))
        self.assertFalse(any(".patch_" in name for name in files if "/" not in name))

    def test_diagnostic_contains_rebuildable_production_sources_and_no_private_files(self):
        path = self.build(flavors=("diagnostic",))[0]
        files = self.archive_files(path)
        production = ("native_weapon_defaults.lua", "weapon_defaults_bootstrap.lua", BUILD.DIAGNOSTICS_SOURCE,
                      *(filename for _, filename in BUILD.COMPONENTS))
        for filename in production:
            self.assertEqual(files[f"Source/src/{filename}"], (self.root / "src" / filename).read_bytes())
        self.assertEqual(files["Source/build_weapon_modes_release.py"], (self.root / "build_weapon_modes_release.py").read_bytes())
        self.assertIn("Source/tests/test_weapon_modes_release.py", files)
        self.assertIn("Source/release/BUILD.md", files)
        for name in BUILD.DOCUMENTS:
            self.assertEqual(files[name], files["Source/release/" + name])
        for flavor in BUILD.FLAVORS:
            for feature in BUILD.FEATURES:
                self.assertEqual(files["Source/generated/" + BUILD.generated_name(flavor, feature)],
                                 BUILD.make_source(flavor, root=self.root, feature=feature).encode())
        self.assertEqual(len([name for name in files if name.startswith("Source/generated/")]), 2)
        for filename in ("weapon_defaults_scoped_input.lua", "weapon_defaults_input.lua",
                         "weapon_defaults_mod_bindings.lua", "weaponflow_binding_records.lua"):
            self.assertNotIn("Source/src/" + filename, files)
        for name, data in files.items():
            if name.startswith("Source/generated/"):
                self.assertNotIn(b"0x1377bb0", data.lower())
            self.assertNotIn(self.private_canary, data, name)
            self.assertFalse(name.endswith((".log", ".bin")), name)
            self.assertNotIn("private", name.lower())
        self.assertNotIn("Source/build_weapon_modes_trial.py", files)


    def test_previous_versioned_archives_are_preserved(self):
        previous = self.root / "dist" / BUILD.output_name("release", "1.1.0")
        previous.parent.mkdir()
        previous.write_bytes(b"confirmed-previous-release")
        self.build()
        self.assertEqual(previous.read_bytes(), b"confirmed-previous-release")


    def test_exclusive_publication_preserves_racing_archive_and_rolls_back_own_files(self):
        racing = self.root / "dist" / BUILD.output_name("diagnostic")
        def race(*args):
            fake_encoder(*args)
            if "Diagnostics" in args[-1]:
                racing.write_bytes(b"another-builder")
        with self.assertRaises(FileExistsError):
            BUILD.build_variants(self.root, root=self.root, builder=race)
        self.assertEqual(racing.read_bytes(), b"another-builder")
        self.assertFalse((racing.parent / BUILD.output_name("release")).exists())


    def test_stable_companion_is_reused_unchanged_across_main_upgrades(self):
        main, companion = self.distribution(version="1.4.0")
        original_main, original_companion = main.read_bytes(), companion.read_bytes()
        original_mtime = companion.stat().st_mtime_ns
        # Neither changing main source/docs nor version should alter the companion.
        with (self.root / "src/native_weapon_defaults.lua").open("a", encoding="utf8") as stream:
            stream.write("\n-- next main release\n")
        (self.root / "release/README.md").write_text("New main documentation\n", encoding="utf8")
        updated, retained = self.distribution(version="1.6.0")
        self.assertEqual(retained, companion)
        self.assertEqual(companion.read_bytes(), original_companion)
        self.assertEqual(companion.stat().st_mtime_ns, original_mtime)
        self.assertEqual(main.read_bytes(), original_main)
        self.assertNotEqual(updated.read_bytes(), original_main)
        self.assertEqual(len(list(main.parent.glob("*Diagnostics*"))), 1)


    def test_mismatched_existing_companion_blocks_main_publication(self):
        companion = self.root / "dist" / BUILD.diagnostics_output_name()
        companion.parent.mkdir()
        companion.write_bytes(b"preserved-different-companion")
        with self.assertRaises(FileExistsError):
            self.distribution()
        self.assertEqual(companion.read_bytes(), b"preserved-different-companion")
        self.assertEqual(list(companion.parent.iterdir()), [companion])
        self.assertEqual(list((self.root / "generated").glob("*.lua")), [])


if __name__ == "__main__":
    unittest.main()

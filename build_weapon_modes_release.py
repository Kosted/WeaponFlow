"""Build WeaponFlow and its optional diagnostics companion for BSL v17.

The main package retains the Trial preset resource and package GUID. The small,
separately versioned diagnostics marker runs alongside it and does not contain
a second coordinator. An external BSL source checkout provides the encoder;
neither its source nor private settings, logs or captured game code are shipped.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent
NAME = "mods/constantin/weapon_modes_trial"
GUID = "c559d47d-474a-4e6c-a827-35deaa7fac0f"
VERSION = "1.9.9"
SENTINEL = "ConstantinWeaponModesTrial"
ARCHIVE = "9ba626afa44a3aa3.patch_0"
FLAVORS = ("release", "diagnostic")
DISTRIBUTION_FLAVORS = ("release", "diagnostics-addon", "both")
DIAGNOSTICS_NAME = "mods/constantin/weapon_defaults_diagnostics"
DIAGNOSTICS_GUID = "3f5b0a8f-f320-4084-9715-e9677063c8cd"
DIAGNOSTICS_VERSION = "1.0.0"
DIAGNOSTICS_API = 1
DIAGNOSTICS_RESOURCE_HASH = 0x7554E4BD5E0B8A3E
DIAGNOSTICS_SOURCE = "weapon_defaults_diagnostics.lua"
DIAGNOSTICS_GENERATED = "weapon_defaults_diagnostics_addon.lua"
# Stable companion documentation must not inherit the current main version.
DIAGNOSTICS_README = """# Weapon Defaults Diagnostics Addon 1.0.0

Optional companion for Weapon Defaults 1.4.0 or newer supporting diagnostics
API 1. Requires Bingus Shared Loader v17 and the main Weapon Defaults mod.
Enable this addon alongside the main mod in HD2 Arsenal, then Purge/Deploy.
It enables detailed logs and bounded read-only diagnostic observations in the
main mod. It contains no weapon logic, HUD, fonts, player settings or loader.
Alone, it does nothing. Disable it and Purge/Deploy to return to compact logs.
Restart the game after changing the selection; it is read once at startup.

Keep this same addon when updating a compatible main version. It does not need
to be replaced for every Weapon Defaults update. Do not enable old full
Weapon-Defaults-Diagnostics-v*.zip packages alongside the main mod.

Logs: %LOCALAPPDATA%\\CowboyBingus\\Helldivers2\\Logs
Keep WeaponDefaultsNative-YYYYMMDD-HHMMSS-PID.log for the affected session.
Source/weapon_defaults_diagnostics.lua is this companion's complete source.
"""
DOCUMENTS = ("README.md", "README-RU.md", "CHANGELOG.md", "THIRD-PARTY-NOTICES.md", "FONT-LICENSE.txt", "CJK-FONT-LICENSE.txt")
# One resource contains presets and HUD. Presentation is chosen in the game.
PAYLOAD_OPTIONS = (
    ("weaponflow", "Addon", "WeaponFlow", NAME, 0x19835EDEC4CB1343),
)
FEATURES = tuple(option[0] for option in PAYLOAD_OPTIONS)
# Independent frozen production list: Source/ can rebuild without the Trial
# builder, and legacy archives/generated Trial source remain untouched.
COMPONENTS = (
    ("EnglishText", "locales/en.lua"),
    ("Text", "weaponflow_text.lua"),
    ("NativeReader", "native_equipment_reader.lua"),
    ("NativeTextLanguage", "native_text_language.lua"),
    ("EquipContext", "native_equip_context.lua"),
    ("WeaponModes", "native_weapon_modes.lua"),
    ("Flashlight", "native_flashlight_state.lua"),
    ("ProgrammableAmmo", "native_programmable_ammo.lua"),
    ("LaserGuide", "native_laser_guide.lua"),
    ("SecondaryFire", "native_secondary_fire.lua"),
    ("WeaponUI", "native_weapon_ui.lua"),
    ("PresetInputGate", "native_preset_input_gate.lua"),
    ("DefaultPresets", "weaponflow_default_presets.lua"),
    ("DefaultsStore", "weapon_defaults_store.lua"),
    ("PresetsClipboard", "weaponflow_clipboard.lua"),
    ("PresetsTransfer", "weaponflow_presets_transfer.lua"),
    ("Bindings", "weaponflow_game_controls.lua"),
    ("MenuState", "weapon_defaults_menu_state.lua"),
    ("ModReset", "weapon_defaults_reset.lua"),
    ("NativeModBindings", "native_mod_bindings.lua"),
    ("NativeModBindingDefaults", "native_mod_binding_defaults.lua"),
    ("ModBindings", "weaponflow_mod_bindings.lua"),
    ("DefaultsInput", "weaponflow_input.lua"),
    ("DefaultsCapture", "weapon_defaults_capture.lua"),
    ("GlobalFlashlight", "weapon_defaults_flashlight.lua"),
    ("WeaponHudIcons", "weapon_defaults_hud_icons.lua"),
    ("NativeHudIcons", "native_weapon_hud_icons.lua"),
    ("HudFont", "weapon_defaults_hud_font.lua"),
    ("HudLabels", "weapon_defaults_hud_labels.lua"),
    ("WeaponHud", "weapon_defaults_hud.lua"),
    ("HudLayout", "weapon_defaults_hud_layout.lua"),
    ("HelpModel", "weapon_defaults_help_model.lua"),
    ("HelpHud", "weapon_defaults_help_hud.lua"),
)
def _validate(flavor: str, version: str) -> None:
    if flavor not in FLAVORS:
        raise ValueError(f"Unknown build flavor: {flavor}")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Version must be three dot-separated nonnegative integers")


def make_source(flavor: str, *, root: Path = ROOT, version: str = VERSION,
                feature: str = "weaponflow") -> str:
    _validate(flavor, version)
    if feature not in FEATURES:
        raise ValueError("Unknown payload feature")
    root = Path(root)
    coordinator = (root / "src/native_weapon_defaults.lua").read_text(encoding="utf-8")
    if "BuildConfig" not in coordinator or SENTINEL not in coordinator:
        raise ValueError("Coordinator must consume BuildConfig and preserve the Trial duplicate-load sentinel")
    resource = next(option[3] for option in PAYLOAD_OPTIONS if option[0] == feature)
    diagnostics = "true" if flavor == "diagnostic" else "selected.diagnostics==true"
    runtime_flavor = '"diagnostic"' if flavor == "diagnostic" else '(selected.diagnostics==true and "diagnostic" or "release")'
    lines = [f"-- HD2-Addon: {resource}",
             "-- WeaponFlow. One deferred runtime for presets and HUD.",
             "local Bootstrap = (function()",
             (root / "src/weapon_defaults_bootstrap.lua").read_text(encoding="utf-8"), "end)()",
             "local function start_weapon_defaults(selected)",
             f'local BuildConfig = {{version="{version}", flavor={runtime_flavor}, diagnostics={diagnostics}, '
             'presets=true, hud=true}']
    for label, filename in COMPONENTS:
        lines.extend((f"local {label} = (function()",
                      (root / "src" / filename).read_text(encoding="utf-8"), "end)()"))
        if label == "Text":
            for locale in sorted((root / "src/locales").glob("*.lua")):
                if locale.name == "en.lua":
                    continue
                lines.extend(("do local catalog=(function()", locale.read_text(encoding="utf-8"),
                              "end)(); assert(Text.register(catalog.language,catalog.strings)) end"))
    labels = ", ".join(("BuildConfig", *(label for label, _ in COMPONENTS)))
    lines.extend((f"return (function({labels})", coordinator, f"end)({labels})", "end",
                  f'return Bootstrap.register({{version="{version}",flavor="{flavor}",feature="{feature}",factory=start_weapon_defaults}})'))
    return "\n".join(lines) + "\n"


def output_name(flavor: str, version: str = VERSION) -> str:
    _validate(flavor, version)
    brand = "Weapon-Defaults-Diagnostics" if flavor == "diagnostic" else "WeaponFlow"
    return f"{brand}-v{version}.zip"


def generated_name(flavor: str, feature: str = "weaponflow") -> str:
    _validate(flavor, VERSION)
    if feature not in FEATURES:
        raise ValueError("Unknown payload feature")
    return f"weapon_defaults_{flavor}_{feature}.lua"


def diagnostics_output_name() -> str:
    return f"Weapon-Defaults-Diagnostics-Addon-v{DIAGNOSTICS_VERSION}.zip"


def make_diagnostics_source(*, root: Path = ROOT) -> str:
    source = (Path(root) / "src" / DIAGNOSTICS_SOURCE).read_text(encoding="utf-8")
    declaration = "-- HD2-Addon: " + DIAGNOSTICS_NAME
    if source.startswith("-- HD2-Addon:"):
        first, separator, rest = source.partition("\n")
        if first != declaration or not separator:
            raise ValueError("Diagnostics companion declaration does not match its resource")
        source = rest
    if source.startswith("\ufeff") or "\0" in source:
        raise ValueError("Diagnostics companion must be plaintext Lua without a BOM or nulls")
    return declaration + "\n" + source.rstrip("\n") + "\n"


def _load_bsl_builder(source: Path):
    scripts = (Path(source) / "scripts").resolve()
    if not (scripts / "build_addon.py").is_file() or not (scripts / "archive.py").is_file():
        raise ValueError("Bingus Shared Loader source must contain scripts/build_addon.py and archive.py")
    # build_addon imports a sibling named archive. Avoid accidentally reusing
    # an unrelated module from another checkout in a long-running Python host.
    old_path = sys.path[:]
    missing = object()
    old_archive = sys.modules.pop("archive", missing)
    try:
        sys.path.insert(0, str(scripts))
        spec = importlib.util.spec_from_file_location("_weapon_defaults_bsl_builder", scripts / "build_addon.py")
        if spec is None or spec.loader is None:
            raise ValueError("Cannot load BSL addon builder")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.build_addon
    finally:
        sys.path[:] = old_path
        sys.modules.pop("archive", None)
        if old_archive is not missing:
            sys.modules["archive"] = old_archive


def _bsl_files(archive: Path) -> dict[str, bytes]:
    expected = {"manifest.json", *(f"Addon/{ARCHIVE}{suffix}" for suffix in ("", ".stream", ".gpu_resources"))}
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        if set(names) != expected or len(names) != len(expected):
            raise ValueError("BSL builder emitted an unexpected or duplicate package member")
        if package.testzip() is not None:
            raise ValueError("BSL package integrity check failed")
        return {name: package.read(name) for name in names}


def _write_zip(destination: Path, files: dict[str, bytes]) -> None:
    with zipfile.ZipFile(destination, "w") as package:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            package.writestr(info, content)


def _attachments(root: Path, flavor: str, sources: dict[tuple[str, str], bytes]) -> dict[str, bytes]:
    files = {name: (root / "release" / name).read_bytes() for name in DOCUMENTS}
    if flavor == "release":
        return files
    # Explicit allowlist only: do not recursively archive the working directory.
    production = ("native_weapon_defaults.lua", "weapon_defaults_bootstrap.lua", DIAGNOSTICS_SOURCE,
                  *(filename for _, filename in COMPONENTS))
    for filename in production:
        files[f"Source/src/{filename}"] = (root / "src" / filename).read_bytes()
    for locale in sorted((root / "src/locales").glob("*.lua")):
        files[f"Source/src/locales/{locale.name}"] = locale.read_bytes()
    locale_help = root / "src/locales/README.md"
    if locale_help.is_file():
        files["Source/src/locales/README.md"] = locale_help.read_bytes()
    files["Source/build_weapon_modes_release.py"] = (root / "build_weapon_modes_release.py").read_bytes()
    files["Source/tests/test_weapon_modes_release.py"] = (root / "tests/test_weapon_modes_release.py").read_bytes()
    for name in DOCUMENTS:
        files[f"Source/release/{name}"] = files[name]
    if (root / "release/BUILD.md").is_file():
        files["Source/release/BUILD.md"] = (root / "release/BUILD.md").read_bytes()
    for (source_flavor, feature), source in sources.items():
        files[f"Source/generated/{generated_name(source_flavor, feature)}"] = source
    return files


def _encode_entry(build_addon, name: str, source: bytes, guid: str,
                  destination: Path, title: str) -> tuple[dict[str, bytes], dict]:
    build_addon(name, source, guid, destination, title)
    files = _bsl_files(destination)
    manifest = json.loads(files["manifest.json"])
    if manifest.get("Guid") != guid or manifest.get("Version") != 1:
        raise ValueError("BSL builder changed addon identity or manifest format")
    options = manifest.get("Options")
    if not isinstance(options, list) or len(options) != 1 or options[0].get("Include") != ["Addon"]:
        raise ValueError("BSL manifest must deploy only one Addon option")
    return files, manifest


def _stage_main(build_addon, temporary: Path, flavor: str, version: str,
                sources: dict[tuple[str, str], bytes], attachments: dict[str, bytes]) -> Path:
    title = f"{'Weapon Defaults Diagnostics' if flavor == 'diagnostic' else 'WeaponFlow'} v{version}"
    files, manifest = {}, None
    for feature, folder, _, resource, _ in PAYLOAD_OPTIONS:
        encoded_files, manifest = _encode_entry(
            build_addon, resource, sources[flavor, feature], GUID,
            temporary / f"{flavor}-{folder}.zip", title)
        for name, content in encoded_files.items():
            if name.startswith("Addon/"):
                files[folder + name[len("Addon"):]] = content
    description = ("Save three presets per weapon and cycle between them. Requires Bingus Shared Loader v17. "
                   "Requires Mod Bindings Menu v2.1 for in-game hotkeys and native input events. "
                   "Choose Icon, Text, or Icon and text with F10 in the HUD menu. "
                   "Deploy only one main WeaponFlow version. Disable older Weapon Defaults, Trials and full diagnostic builds. "
                   "The separate Diagnostics Addon may be enabled alongside this main mod.")
    if flavor == "diagnostic":
        description += " Internal full diagnostic build with reproducible production sources."
    manifest["Name"], manifest["Description"] = title, description
    manifest["Options"] = [
        {"Name": "WeaponFlow", "Description": "Weapon presets and configurable HUD.", "Include": ["Addon"]},
    ]
    files["manifest.json"] = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    files.update(attachments)
    stage = temporary / output_name(flavor, version)
    _write_zip(stage, files)
    return stage


def _stage_diagnostics(build_addon, temporary: Path, source: bytes) -> Path:
    title = f"Weapon Defaults Diagnostics Addon v{DIAGNOSTICS_VERSION}"
    files, manifest = _encode_entry(build_addon, DIAGNOSTICS_NAME, source, DIAGNOSTICS_GUID,
                                     temporary / "diagnostics-marker-encoded.zip", title)
    description = ("Optional diagnostics API 1 marker for Weapon Defaults 1.4.0 or newer. "
                   "Requires Bingus Shared Loader v17. Enable alongside the main Weapon Defaults mod; "
                   "this addon contains no second weapon or HUD implementation.")
    manifest["Name"], manifest["Description"] = title, description
    manifest["Options"] = [{"Name": "Detailed diagnostics", "Description": description, "Include": ["Addon"]}]
    files["manifest.json"] = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    files["README.md"] = DIAGNOSTICS_README.encode("utf-8")
    files["Source/" + DIAGNOSTICS_SOURCE] = source
    stage = temporary / diagnostics_output_name()
    _write_zip(stage, files)
    return stage


def _publish_staged(staged: list[tuple[Path, Path, bool]]) -> None:
    # Check every permitted reuse before publishing any new archive. A stable
    # companion is reusable only when the complete ZIP is byte-identical.
    for stage, destination, reusable in staged:
        if destination.exists() and (not reusable or destination.read_bytes() != stage.read_bytes()):
            raise FileExistsError(f"Refusing to overwrite preserved release: {destination}")
    created = []
    try:
        for stage, destination, reusable in staged:
            try:
                target = destination.open("xb")
            except FileExistsError:
                if reusable and destination.read_bytes() == stage.read_bytes():
                    continue
                raise
            with target:
                created.append(destination)
                with stage.open("rb") as source:
                    shutil.copyfileobj(source, target)
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        raise


def build_variants(bsl_source: Path, *, flavors: tuple[str, ...] = FLAVORS,
                   root: Path = ROOT, output_dir: Path | None = None,
                   version: str = VERSION, builder=None) -> list[Path]:
    """Legacy development-only full variants; public CLI uses build_distribution.

    ``builder`` is an injected encoder only for isolated packaging tests. Normal
    CLI builds always call the supplied BSL checkout's build_addon function.
    """
    root = Path(root)
    if not flavors or len(set(flavors)) != len(flavors):
        raise ValueError("Choose one or both distinct flavors")
    for flavor in flavors:
        _validate(flavor, version)
    output_dir = Path(output_dir) if output_dir is not None else root / "dist"
    destinations = [output_dir / output_name(flavor, version) for flavor in flavors]
    for path in destinations:
        if path.exists():
            raise FileExistsError(f"Refusing to overwrite preserved release: {path}")
    sources = {(flavor, feature): make_source(flavor, root=root, version=version, feature=feature).encode("utf-8")
               for flavor in FLAVORS for feature in FEATURES}
    # Read every required attachment before asking the external builder to run.
    attachments = {flavor: _attachments(root, flavor, sources) for flavor in flavors}
    build_addon = builder or _load_bsl_builder(bsl_source)
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="weapon-defaults-build-", dir=output_dir) as temporary:
        staged = []
        for flavor, destination in zip(flavors, destinations):
            stage = _stage_main(build_addon, Path(temporary), flavor, version, sources, attachments[flavor])
            staged.append((stage, destination, False))
        _publish_staged(staged)
    generated = root / "generated"
    generated.mkdir(parents=True, exist_ok=True)
    for flavor in flavors:
        for feature in FEATURES:
            (generated / generated_name(flavor, feature)).write_bytes(sources[flavor, feature])
    return destinations


def build_distribution(bsl_source: Path, *, flavor: str = "both", root: Path = ROOT,
                       output_dir: Path | None = None, version: str = VERSION, builder=None) -> list[Path]:
    """Publish the main mod and/or independent stable diagnostics companion.

    Main archives are never replaced or reused. An existing companion can be
    retained only if its newly encoded complete archive is byte-identical.
    All requested encodes and reuse checks finish before publication starts.
    """
    if flavor not in DISTRIBUTION_FLAVORS:
        raise ValueError("Choose release, diagnostics-addon or both")
    _validate("release", version)
    root = Path(root)
    output_dir = Path(output_dir) if output_dir is not None else root / "dist"
    main_requested = flavor in ("release", "both")
    companion_requested = flavor in ("diagnostics-addon", "both")
    main_destination = output_dir / output_name("release", version)
    companion_destination = output_dir / diagnostics_output_name()
    if main_requested and main_destination.exists():
        raise FileExistsError(f"Refusing to overwrite preserved release: {main_destination}")
    sources = {("release", feature): make_source("release", root=root, version=version, feature=feature).encode("utf-8")
               for feature in FEATURES} if main_requested else {}
    attachments = _attachments(root, "release", sources) if main_requested else {}
    companion_source = make_diagnostics_source(root=root).encode("utf-8") if companion_requested else None
    build_addon = builder or _load_bsl_builder(bsl_source)
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="weapon-defaults-distribution-", dir=output_dir) as temporary:
        directory = Path(temporary)
        staged = []
        if main_requested:
            stage = _stage_main(build_addon, directory, "release", version, sources, attachments)
            staged.append((stage, main_destination, False))
        if companion_requested:
            stage = _stage_diagnostics(build_addon, directory, companion_source)
            staged.append((stage, companion_destination, True))
        _publish_staged(staged)
    generated = root / "generated"
    generated.mkdir(parents=True, exist_ok=True)
    for (source_flavor, feature), source in sources.items():
        (generated / generated_name(source_flavor, feature)).write_bytes(source)
    if companion_source is not None:
        (generated / DIAGNOSTICS_GENERATED).write_bytes(companion_source)
    return [destination for _, destination, _ in staged]


def build_diagnostics_addon(bsl_source: Path, *, root: Path = ROOT,
                            output_dir: Path | None = None, builder=None) -> Path:
    return build_distribution(bsl_source, flavor="diagnostics-addon", root=root,
                              output_dir=output_dir, builder=builder)[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bsl-source", required=True, type=Path)
    parser.add_argument("--flavor", choices=DISTRIBUTION_FLAVORS, default="both")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--version", default=VERSION)
    args = parser.parse_args()
    try:
        paths = build_distribution(args.bsl_source, flavor=args.flavor, output_dir=args.output_dir, version=args.version)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.error(str(error))
    for path in paths:
        print(path)


if __name__ == "__main__":
    main()

# WeaponFlow checks

Run the changed area, once:

```powershell
python tests/run_checks.py controls
python tests/run_checks.py presets
python tests/run_checks.py hud
python tests/run_checks.py packaging
```

Use `python tests/run_checks.py all` for a coordinated release or a change that
actually crosses all areas. Do not follow a successful area check with repeated
full runs. Ordinary builds use the existing BSL encoder once; a second identical
build and every startup-order permutation are not routine release requirements.

The suite keeps user-visible contracts and guards against stale native identity,
unknown reads, unwanted mode changes, profile loss and foreign input writes.
Fixtures are fake registry/files/keys or byte-addressed native memory; a passing
check does not demonstrate actual in-game input, weapon behavior or engine safety.
Game validation is reserved for the changed behavior, not old confirmed baselines.

Old standalone input, Bindings.ini synchronization, shared-input editing and
legacy native serialization checks were removed. Shared data fixtures are in
`input_fixtures.py` and `binding_fixtures.py`, not imported from retired tests.

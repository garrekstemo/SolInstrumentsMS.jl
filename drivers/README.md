# Instrument Driver Presets (SolInstrumentsMS)

Hardware preset JSON for the monochromators supported by this package.
Consumed by QPSDrive's config loader, which resolves the `"driver"` key in
an instrument block against all registered driver-source packages.

| File              | Model                         |
|-------------------|-------------------------------|
| `ms3501i.json`    | SOL Instruments MS3501i       |

## `${pkgdir:SolInstrumentsMS}` substitution

`cfg_path` may use the token `${pkgdir:SolInstrumentsMS}`; QPSDrive's config
loader replaces it with the absolute path to this package's root at load
time. This lets the preset reference the .cfg file shipped in `cfg/` without
hard-coding a user-specific filesystem path.

See the parent QPSDrive repo's `docs/config.md` for how drivers, config
files, and the `~/Library/Application Support/QPSDrive/config.json` user
config fit together.

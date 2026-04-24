# Driver presets (SolInstrumentsMS)

QPSDrive-compatible JSON presets for the monochromators supported by this
package. Consumed by QPSDrive's config loader, which resolves the `"driver"`
key in a config block against every registered driver-source package.

| File              | Model                         |
|-------------------|-------------------------------|
| `ms3501i.json`    | SOL Instruments MS3501i       |

## This folder vs `../cfg/`

Two folders, two very different file formats, both needed:

| Folder      | Format         | Audience          | Purpose                                                     |
|-------------|----------------|-------------------|-------------------------------------------------------------|
| `drivers/`  | JSON           | Humans + QPSDrive | High-level preset: model, metadata, field notes, defaults.  |
| `../cfg/`   | INI-style `.cfg` | The driver only | Low-level manufacturer calibration (grating tables, steps). |

A driver preset in `drivers/` points at a `.cfg` file in `../cfg/` via the
`cfg_path` field, so together they describe everything the driver needs to
open a monochromator:

```
drivers/ms3501i.json  ──cfg_path──►  cfg/MS3501.cfg
      (human-readable)                   (manufacturer blob)
```

At runtime the loader reads the JSON, expands the `${pkgdir:SolInstrumentsMS}`
token in `cfg_path`, and hands the resulting absolute path to
`SolInstrumentsMS.load_config(...)`. You edit the JSON; you do **not**
hand-edit the `.cfg`.

## `${pkgdir:SolInstrumentsMS}` substitution

`cfg_path` uses the token `${pkgdir:SolInstrumentsMS}`, which QPSDrive
replaces with the absolute path to this package's root at load time. That
keeps the preset portable across machines where the package may live in
`~/.julia/packages/...`, `~/Developer/...`, or anywhere else.

See QPSDrive's `docs/config.md` for how drivers, user configs, and the
`~/Library/Application Support/QPSDrive/config.json` user config fit
together.

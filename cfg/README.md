# Manufacturer .cfg files

This folder holds the **manufacturer's INI-style configuration files** for
specific monochromator models — the same binary-ish `.cfg` format that SOL
Instruments' own software uses. Each file bakes in the grating table,
step-to-wavelength calibration, reset positions, and other unit-specific
hardware parameters.

These are consumed at runtime by `SolInstrumentsMS.load_config(path)`,
which parses them into a `MonochromatorConfig` for the `Monochromator`
driver.

| File           | Model   | Notes                                             |
|----------------|---------|---------------------------------------------------|
| `MS3501.cfg`   | MS3501i | Shipped default; adequate for most installations. |

## Relationship to `drivers/`

Two folders, two purposes:

- **`cfg/`** *(this folder)* — raw manufacturer calibration files in SOL's
  native format. Low-level, model-specific, opaque to anything other than
  the driver itself. You generally do **not** hand-edit these.
- **`drivers/`** — QPSDrive-compatible JSON presets. Describe a monochromator
  at a higher level (model, default serial behavior, field notes) and
  *point at* one of the `.cfg` files in this folder via the
  `${pkgdir:SolInstrumentsMS}/cfg/<file>.cfg` token. A human can read and
  edit these.

Normal flow: QPSDrive's config loader reads a driver preset from
`drivers/`, the preset tells it which `.cfg` file to pass to
`SolInstrumentsMS.load_config(...)`, and the driver feeds that into the
`Monochromator`.

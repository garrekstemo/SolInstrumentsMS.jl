# SOL instruments MS-series — Serial Protocol Reference

Reverse-engineered from DevCtrl serial captures on MS3501i (S/N 11076), 2026-02-12.
Hardware-verified with SolInstrumentsMS.jl.

## Serial Port Settings

| Parameter    | Value  |
|-------------|--------|
| Baud rate   | 9600   |
| Data bits   | 8      |
| Parity      | None   |
| Stop bits   | **2**  |
| Flow control | None (DTR+RTS asserted) |

**Important**: The stop bits setting is **2**, not 1. Confirmed from the
IOCTL_SERIAL_SET_LINE_CONTROL call in the DevCtrl IRP capture. Using 1 stop bit
causes framing errors on multi-byte commands (single-byte ACK works by luck).


## Nibble Encoding

All data values are encoded as variable-length ASCII nibbles. Each hex nibble (0-15)
is represented as a byte with 0x30 added:

```
0→'0'  1→'1'  2→'2'  3→'3'  4→'4'  5→'5'  6→'6'  7→'7'
8→'8'  9→'9'  A→':'  B→';'  C→'<'  D→'='  E→'>'  F→'?'
```

Examples: 2000 = 0x7D0 → `7=0`, 33949 = 0x849D → `849=`


## Frame Format

All commands are terminated with `\n` (0x0a).

```
Move command:    [cmd_string] [nibble_data (variable length)] \n → ACK
No-data command: [cmd_string] \n → ACK
A-query:         [cmd_string] \n → [nibble_data] \n ACK
SS/G-query:      [cmd_string] \n → [nibble_data] \n  (no trailing ACK)
```

### Pre-command handshake

Every command is preceded by:
1. Purge RX buffer
2. ACK handshake (send 0x06, expect 0x06)
3. Purge RX buffer
4. Send command bytes one at a time
5. Read response

### Connectivity check

Send single byte `0x06`, expect `0x06` back.


## Command Reference

**Naming convention**: `I` = increase (forward), `D` = decrease (backward),
`R` = reset/home. The character after I/D/R identifies the device.

**All motor moves are RELATIVE** — I increases position by N steps, D decreases by N steps.

### Grating (device '1') — motorized

| Command | Data | Description |
|---------|------|-------------|
| `I1[nibbles]\n` | step count | Move grating forward by N steps |
| `D1[nibbles]\n` | step count | Move grating backward by N steps |
| `R1\n` | (none) | Reset grating to home position (~9 sec) |

Backlash compensation for backward moves: `D(|delta| + backlash)` then `I(backlash)`.
Backlash is clamped to `min(backlash, target_position)` to avoid overshooting past zero.

### Shutter (device '8') — motorized

| Command | Data | Description |
|---------|------|-------------|
| `I81\n` | (none) | Open shutter (index 1) |
| `D81\n` | (none) | Close shutter (index 1) |

Shutter index is **1-indexed** and part of the command string (not nibble data).

### Slits (device '9', ':')

| Command | Data | Description |
|---------|------|-------------|
| `I9[nibbles]\n` | step count | Move slit 1 forward by N steps |
| `D9[nibbles]\n` | step count | Move slit 1 backward by N steps |
| `R9\n` | (none) | Reset slit 1 to home |
| `I:[nibbles]\n` | step count | Move slit 2 forward by N steps |
| `R:\n` | (none) | Reset slit 2 to home |

Whether slits are motorized depends on the model. Our MS3501i has manual knobs only
(DeviceType=0). Models with motorized slits will report a non-zero DeviceType.

### Turret (device '5')

| Command | Data | Description |
|---------|------|-------------|
| `I5[nibbles]\n` | position | Move turret to position |
| `R5\n` | (none) | Reset turret |

MS3501i has no turret motor. Grating changes require manual physical swap.

### Queries (read-only)

| Command | Response format | Description |
|---------|----------------|-------------|
| `A[dev][reg]\n` | `[nibbles]\n` ACK | Read device register |
| `SS[params]\n` | `[nibbles]\n` *(no ACK)* | Subsystem state query |
| `G[params]\n` | `[nibbles]\n` *(no ACK)* | Config query |

**Note**: A-queries return a trailing ACK byte after the newline. SS and G queries do NOT.

### Device motor probing

Query DeviceType register with `A[dev]0` — DeviceType=0 means no motor.

| Device | ID | Char | DeviceType (MS3501i) | Motor |
|--------|----|------|---------------------|-------|
| Grating | 49 | `1` | 255 | Yes (stepper) |
| Turret | 53 | `5` | 0 | No |
| Shutter | 56 | `8` | 15 | Yes (solenoid) |
| Slit 1 (entrance) | 57 | `9` | 0 | No |
| Slit 2 (detector) | 58 | `:` | 0 | No |


## Wavelength Conversion

Position (steps) ↔ wavelength (nm) via the diffraction grating equation:

```
Wavelength to position:
    position = asin(λ_nm × 1e-6 × d / (2 cos θ₂)) / Δθ

Position to wavelength:
    λ_nm = 2 × sin(Δθ × position) × cos(θ₂) / d × 1e6
```

Parameters from the `.cfg` file:
- `Δθ` (`StepSize`) — angular step size per motor step (radians)
- `d` (`LineCount` / `ShtrichCount`) — groove density (lines/mm, stored as lines/m in .cfg)
- `θ₂` (`Theta2` / `Tetta2`) — fixed grating mount angle (radians)

Position 0 = **zero order** — grating acts as a mirror, all wavelengths pass.


## DevCtrl Startup Sequence

Captured from serial monitor on lab Windows PC (2026-02-12):

1. **Device discovery**: `A80`, `A84`-`A87`, `A8<`-`A8?` register queries
2. **Port close/reopen**, repeat queries (DevCtrl re-enumerates)
3. **Config queries**: `G` and `SS` commands to read subsystem state
4. **Grating reset**: `R1\n` (takes ~9 sec, motor homes)
5. **Position restore**: `I1[position]\n` (reads saved position from EEPROM via `SS0107`)
6. **User operations**: grating moves, shutter toggle, etc.

Implemented in SolInstrumentsMS.jl as `find_previous_position!`.


## Configuration File (.cfg)

INI-style file exported by DevCtrl. Must be obtained from the instrument's Windows PC.

Sections are 1-indexed (`[Grating1]`, `[Slit1]`). The `SlitCount` in `[Device]` may be
0 even when `[Slit1]`/`[Slit2]` sections exist — the parser discovers sections by
scanning, not by trusting Device counts.

### Unit conversions (SI in .cfg → practical units)

| Key | .cfg units | Driver units |
|-----|-----------|-------------|
| `LineCount` / `ShtrichCount` | lines/m | lines/mm (÷1000) |
| `BlazeWave` | m | nm (×1e9) |
| `Focus` / `Fokus` | m | cm (×100) |
| `StepSize` (grating) | rad/step | rad/step (no conversion) |
| `StepSize` (slit) | m/step | um/step (×1e6) |
| `Theta2` / `Tetta2` | rad | rad (no conversion) |


## Related Models

| Model    | Focal Length | Gratings | Notes |
|----------|-------------|----------|-------|
| MS2001   | 200 mm      | 1        | Manual grating change |
| MS2004   | 200 mm      | 4-turret | |
| MS2001i  | 200 mm      | 1        | Imaging |
| MS2004i  | 200 mm      | 4-turret | Imaging |
| MS3501   | 350 mm      | 1        | Non-imaging |
| MS3504   | 350 mm      | 4-turret | |
| MS3501i  | 350 mm      | 1        | Imaging |
| MS3504i  | 350 mm      | 4-turret | Imaging |

**Note**: The plasmapper LabVIEW driver was tested on MS3504i and MS2001i and uses a
binary Int32 protocol. This does NOT work on our MS3501i, which requires the nibble-encoded
DevCtrl protocol. It's unclear whether this is a firmware version difference or a model
family difference.


## References

- plasmapper LabVIEW driver (binary protocol, does NOT work on MS3501i): https://github.com/plasmapper/sol-instruments-ms-labview
- SOL instruments MS350 specs: https://solinstruments.com/products/spectroscopy/monochromator-spectrographs/ms350/specification-ms350/

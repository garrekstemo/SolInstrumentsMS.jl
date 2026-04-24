# SolInstrumentsMS.jl — Usage Tutorial

## Setup

```julia
using SolInstrumentsMS

config = load_config("path/to/MS3501.cfg")
mono = Monochromator("/dev/tty.usbserial-XXXX", config)
connect!(mono)
```

On first connect, synchronize the driver's internal position tracking with the
physical grating by running `find_previous_position!`. This resets the grating
to the home limit switch and then moves to the position saved in EEPROM —
the same procedure DevCtrl performs on startup. Takes ~14 seconds.

```julia
result = find_previous_position!(mono)
# (position = 32458, wavelength_nm = 5000.0)
```

`position` is the physical firmware step counter, not the raw EEPROM value.
The two differ by `|NullPosition|` because `R1` homes the firmware to
`-|NullPosition|` before the restore move (see `monochromator.jl` for the
full derivation).


## Moving to a Wavelength

```julia
wl = set_wavelength!(mono, 5000.0)   # returns actual wavelength (nm)
get_wavelength(mono)                  # read current wavelength without moving
```

Backward moves automatically apply backlash compensation (overshoot + correction).
The driver tracks position internally — all moves are relative to the current position.


## Zero Order

Zero order (position 0) sets the grating to act as a flat mirror. All wavelengths
are reflected equally with no dispersion. This is useful for alignment or measuring
overall broadband intensity.

```julia
# Save current wavelength
original_wl = get_wavelength(mono)

# Move to zero order
set_wavelength!(mono, 0.0)

# ... do your measurement ...

# Return to the original wavelength
set_wavelength!(mono, original_wl)
```

Large moves (e.g. 5000 nm → zero order) take about 6 seconds. The driver
automatically scales the serial timeout to accommodate the move distance.

Backlash compensation is clamped near zero order so the motor never overshoots
past position 0.


## Shutter

```julia
open_shutter!(mono)    # opens shutter 1
close_shutter!(mono)   # closes shutter 1
```


## Disconnecting

```julia
disconnect!(mono)
```

The controller saves the current grating position to EEPROM automatically.
On the next session, `find_previous_position!` will restore it.

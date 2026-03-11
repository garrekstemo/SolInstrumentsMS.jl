# SolInstrumentsMS.jl

[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

Julia driver for SOL instruments (Solar TII) MS-series monochromators and spectrographs.

Supports MS2001, MS2004, MS3501, MS3504, and their imaging ("i") variants. Protocol reverse-engineered from DevCtrl serial captures.

## Quick Start

```julia
using SolInstrumentsMS

config = load_config("MS3501i.cfg")
mono = Monochromator("/dev/tty.usbserial-XXXX", config)
connect!(mono)

set_wavelength!(mono, 500.0)   # nm
set_slit!(mono, 1, 100.0)     # slit 1, 100 um
open_shutter!(mono)
```

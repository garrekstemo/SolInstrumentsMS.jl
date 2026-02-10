"""
# SolInstrumentsMS.jl

Julia driver for SOL instruments (Solar TII) MS-series monochromators/spectrographs.

Supports: MS2001, MS2004, MS3501, MS3504, and their imaging ("i") variants.
Protocol reverse-engineered from the plasmapper LabVIEW driver.

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
"""
module SolInstrumentsMS

using LibSerialPort

include("config.jl")
include("protocol.jl")
include("monochromator.jl")

export Monochromator, MonochromatorConfig
export GratingConfig, SlitConfig, MirrorConfig, MirrorPosition
export load_config
export connect!, disconnect!, isconnected, identify
export set_wavelength!, get_wavelength, reset_grating!
export set_slit!, get_slit, reset_slit!
export set_mirror!, reset_mirror!
export open_shutter!, close_shutter!
export wavelength_to_position, position_to_wavelength

end # module SolInstrumentsMS

# SolInstrumentsMS.jl — SOL Instruments Monochromator Driver

Julia driver for SOL instruments (Solar TII) MS-series monochromators. Protocol
reverse-engineered from DevCtrl serial captures (nibble-encoded ASCII, 9600/8N2).

## Architecture

```
src/
  SolInstrumentsMS.jl    # Module, includes, exports
  config.jl              # Load/parse DevCtrl .cfg files
  protocol.jl            # Nibble encoding, frame construction, serial I/O
  monochromator.jl       # High-level API (set_wavelength!, open_shutter!, etc.)
  mock.jl                # MockConnection for testing without hardware
```

## Protocol

- DevCtrl nibble-encoded ASCII over RS-232C at 9600/8N2 (2 stop bits)
- Commands: `I` (increase/open), `D` (decrease/close), `S` (query), `R` (reset)
- Device IDs are single ASCII characters: Grating='1', Shutter='8', Slit1='9', Slit2=':', Turret='5'
- Motor moves are relative: I = increase by N steps, D = decrease by N steps
- Backlash compensation: D(|delta| + backlash) then I(backlash) for backward moves

## Conventions

- Mutating methods use `!` suffix (`connect!`, `set_wavelength!`, `open_shutter!`)
- `isconnected(mono) || error(...)` before any I/O
- MockConnection implements the same serial interface for testing

## Agent Policy

This is a hardware driver for a physical instrument. Follow these rules:

**Plan mode** — enter plan mode before changing `protocol.jl` or `monochromator.jl`.

**Post-implementation review** — after changes to protocol or motor control code,
spawn the `instrument-safety` agent (global, in `~/.claude/agents/`).

**Tests** — run `julia --project=. test/runtests.jl` after any code change.

## Development

```bash
julia --project=.
```

```julia
using Revise
using SolInstrumentsMS

config = load_config("cfg/MS3501.cfg")
mono = Monochromator("/dev/tty.usbserial-1110", config)
connect!(mono)
```

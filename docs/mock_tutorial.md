# Using the Mock Monochromator

The `MockConnection` is a digital twin of the MS-series controller.
It simulates the serial protocol in memory, so you can develop and test
scripts without physical hardware.


## Walkthrough

Set up a monochromator with a mock connection. The port name is just a
label — `MockConnection` doesn't touch any serial ports.

```julia
using SolInstrumentsMS

config = load_config("cfg/MS3501.cfg")
mono = Monochromator("/dev/mock", config)
conn = MockConnection()
connect!(mono, conn)
```

All the same commands work, just instantly:

```julia
set_wavelength!(mono, 5200.0)
open_shutter!(mono)
close_shutter!(mono)
```

### Inspecting commands

The mock logs every command it receives:

```julia
last_command(conn)    # ("D81", 0) — the close_shutter! above
command_count(conn)   # 3
```

The full log is in `conn.command_log`, a vector of `(cmd, data)` tuples.

Use `reset!(conn)` to clear the log between operations. This only clears
the log and I/O buffers — motor positions carry over.

```julia
reset!(conn)
set_wavelength!(mono, 6000.0)
command_count(conn)   # 1 — only counts since reset!

last_command(conn)    # ("I1", 5346) — forward move, no backlash
```

### Backlash compensation

Moving backward triggers two commands (overshoot + correction):

```julia
reset!(conn)
set_wavelength!(mono, 4000.0)

command_count(conn)   # 2
conn.command_log[1]   # ("D1", ...) — decrease by delta + backlash
conn.command_log[2]   # ("I1", 2000) — backlash correction
```

### Twin state

The mock tracks internal state just like the real controller:

```julia
conn.grating_position   # accumulated step position
conn.shutter_open        # true/false
conn.slit_positions      # Dict('9' => steps, ':' => steps)
```

The mock's `grating_position` starts at 0 and accumulates relative moves,
while `mono.grating_position` tracks absolute position from the config.
They won't match unless the mock was initialized to the same starting
position.

```julia
open_shutter!(mono)
conn.shutter_open   # true

close_shutter!(mono)
conn.shutter_open   # false
```

```julia
disconnect!(mono)
```


## Simulating a Saved Position

Pass `grating_position` to the constructor to simulate the value stored in the
controller's EEPROM (what `find_previous_position!` reads via `SS0107`). To
match real-hardware behavior, also pass `grating_reset_position` — the DevCtrl
convention is that `R1` homes the firmware counter to `-|NullPosition|`, so the
post-restore position ends up `|NullPosition|` lower than the EEPROM value.

```julia
g = config.gratings[3]  # MIR grating on CurGrating=3 in the shipped cfg

mono = Monochromator("/dev/mock", config)
conn = MockConnection(
    grating_position=Int32(33949),
    grating_reset_position=g.reset_position,  # = -1491 in MS3501.cfg
)
connect!(mono, conn)

result = find_previous_position!(mono)
# (position = 32458, wavelength_nm = 5000.0)

# The mock simulated the full sequence:
#   1. SS0107 query        → returned 33949 (EEPROM value)
#   2. R1 reset            → firmware counter = grating_reset_position = -1491
#   3. I1 move by 33949    → firmware counter = -1491 + 33949 = 32458

disconnect!(mono)
```

If `grating_reset_position` is left at the default (0), the mock uses a
simpler "firmware counter = 0 at reset" convention — fine for exercising
protocol mechanics but it will not reproduce the `|NullPosition|` offset
that the real controller applies.


## Writing Tests

Each test should create its own `Monochromator` and `MockConnection` for
a clean starting state.

```julia
using Test

config = load_config("cfg/MS3501.cfg")

@testset "Backlash compensation" begin
    mono = Monochromator("/dev/mock", config)
    conn = MockConnection()
    connect!(mono, conn)

    # Move forward (no backlash)
    set_wavelength!(mono, 6000.0)
    reset!(conn)

    # Move backward (triggers backlash)
    set_wavelength!(mono, 4000.0)
    @test command_count(conn) == 2
    @test conn.command_log[1][1] == "D1"  # overshoot backward
    @test conn.command_log[2][1] == "I1"  # correct forward

    disconnect!(mono)
end
```


## API Reference

| Function | Description |
|---|---|
| `MockConnection()` | Create mock at grating position 0 |
| `MockConnection(grating_position=Int32(n))` | Create mock with saved EEPROM position |
| `MockConnection(grating_reset_position=Int32(n))` | Position the firmware counter snaps to on `R1` (defaults to 0) |
| `last_command(conn)` | Last `(cmd, data)` tuple, or `nothing` |
| `command_count(conn)` | Number of commands since last `reset!` |
| `reset!(conn)` | Clear command log and I/O buffers (keeps positions) |
| `conn.command_log` | Full command history as `Vector{Tuple{String, Int32}}` |
| `conn.grating_position` | Twin grating step position |
| `conn.shutter_open` | Twin shutter state |
| `conn.slit_positions` | Twin slit positions by device char |

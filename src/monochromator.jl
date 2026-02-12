# High-level monochromator interface
#
# Wraps the low-level protocol with wavelength conversion, backlash
# compensation, position tracking, and bounds checking.
#
# All motor moves are RELATIVE: I = increase by N steps, D = decrease by N steps.
# Backlash compensation for backward moves: D(|delta| + backlash) then I(backlash).
#
# Commands are constructed from the DeviceID in the .cfg file:
#   DeviceID=49 → '1' → "I1" (grating), DeviceID=57 → '9' → "I9" (slit 1), etc.

mutable struct Monochromator
    port_name::String
    connection::Union{IO, Nothing}
    config::MonochromatorConfig
    timeout_ms::UInt32
    current_grating::Int        # 1-based index into config.gratings
    grating_position::Int32     # current step position (tracked internally)
    slit_positions::Vector{Int32}
    mirror_indices::Vector{Int}  # 1-based index into mirror config positions
    shutter_open::Vector{Bool}
end

function Monochromator(port::String, config::MonochromatorConfig;
                       timeout_ms::UInt32=UInt32(5000))
    # Initialize current grating from turret's CurGrating
    cur_grating = config.turret !== nothing ? config.turret.current_grating : 1
    cur_grating = clamp(cur_grating, 1, max(1, length(config.gratings)))

    # Initialize positions from CurStepPosition in the .cfg
    grating_pos = isempty(config.gratings) ? Int32(0) : config.gratings[cur_grating].initial_position
    slit_pos = Int32[s.initial_position for s in config.slits]

    return Monochromator(
        port, nothing, config, timeout_ms,
        cur_grating, grating_pos,
        slit_pos,
        ones(Int, length(config.mirrors)),
        fill(false, config.shutter_count)
    )
end

# --- Connection ---

function connect!(m::Monochromator)
    # 9600 baud, 8 data bits, no parity, 2 stop bits (8N2)
    m.connection = LibSerialPort.open(m.port_name, 9600; nstopbits=2)
    if !_check_connection(m.connection; timeout_ms=m.timeout_ms)
        close(m.connection)
        m.connection = nothing
        error("Monochromator did not respond to connectivity check")
    end
    return nothing
end

function connect!(m::Monochromator, conn::IO)
    m.connection = conn
    if !_check_connection(m.connection; timeout_ms=m.timeout_ms)
        m.connection = nothing
        error("Monochromator did not respond to connectivity check")
    end
    return nothing
end

function disconnect!(m::Monochromator)
    if m.connection !== nothing
        close(m.connection)
        m.connection = nothing
    end
    return nothing
end

isconnected(m::Monochromator) = m.connection !== nothing

function identify(m::Monochromator)
    g = m.config.gratings[m.current_grating]
    return "SOL instruments MS on $(m.port_name) ($(g.name), $(g.groove_density) g/mm)"
end

# --- Helpers ---

_dev_char(id::UInt8) = String([Char(id)])

function _cmd!(m::Monochromator, cmd::String, data::Integer; timeout_ms::Integer=0)
    @assert isconnected(m) "Monochromator not connected"
    t = timeout_ms > 0 ? timeout_ms : m.timeout_ms
    _command(m.connection, cmd, data; timeout_ms=t)
end

function _cmd_nodata!(m::Monochromator, cmd::String; timeout_ms::Integer=0)
    @assert isconnected(m) "Monochromator not connected"
    t = timeout_ms > 0 ? timeout_ms : m.timeout_ms
    _command_nodata(m.connection, cmd; timeout_ms=t)
end

# --- Relative motor move with backlash ---

function _move_relative!(m::Monochromator, dev::String, delta::Int32, backlash::Int32)
    if delta == 0
        return
    elseif delta > 0
        _cmd!(m, "I$dev", delta)
    else
        if backlash > 0
            _cmd!(m, "D$dev", Int32(abs(delta) + backlash))
            _cmd!(m, "I$dev", backlash)
        else
            _cmd!(m, "D$dev", Int32(abs(delta)))
        end
    end
end

# --- Grating / wavelength ---

function set_wavelength!(m::Monochromator, wavelength_nm::Real)
    g = m.config.gratings[m.current_grating]
    target = wavelength_to_position(g, wavelength_nm)
    if target < 0 || target > g.max_position
        error("Wavelength $(wavelength_nm) nm maps to position $target, " *
              "outside [0, $(g.max_position)]")
    end
    dev = _dev_char(g.device_id)
    delta = Int32(target - m.grating_position)
    _move_relative!(m, dev, delta, Int32(g.backlash))
    m.grating_position = target
    return position_to_wavelength(g, target)
end

function get_wavelength(m::Monochromator)
    g = m.config.gratings[m.current_grating]
    return position_to_wavelength(g, m.grating_position)
end

function reset_grating!(m::Monochromator)
    g = m.config.gratings[m.current_grating]
    dev = _dev_char(g.device_id)
    _cmd_nodata!(m, "R$dev"; timeout_ms=g.reset_timeout_ms)
    m.grating_position = g.reset_position
    return nothing
end

"""
    find_previous_position!(m::Monochromator) → (position, wavelength_nm)

Query the saved grating position from the controller's EEPROM, reset the
grating motor to home, then move to the saved position. This synchronizes
the software's internal position tracking with the physical grating.

Equivalent to DevCtrl's "Find Previous Position" dialog on startup.
Takes ~15 seconds (reset ~9s + move ~6s).
"""
function find_previous_position!(m::Monochromator)
    @assert isconnected(m) "Monochromator not connected"
    g = m.config.gratings[m.current_grating]
    dev = _dev_char(g.device_id)

    # Query saved position from EEPROM (SS query, no trailing ACK)
    saved_pos = Int32(_query_noack(m.connection, "SS0107"))

    # Reset grating to home (limit switch)
    _cmd_nodata!(m, "R$dev"; timeout_ms=15_000)

    # Move from home to saved position
    _cmd!(m, "I$dev", saved_pos; timeout_ms=15_000)

    # Update internal tracking
    m.grating_position = saved_pos

    wl = position_to_wavelength(g, saved_pos)
    return (position=saved_pos, wavelength_nm=wl)
end

# --- Slits ---

function set_slit!(m::Monochromator, slit_index::Int, width_um::Real)
    @assert 1 <= slit_index <= length(m.config.slits) "Slit index $slit_index out of range"
    s = m.config.slits[slit_index]
    target = round(Int32, width_um / s.step_size_um)
    if target < 0 || target > s.max_position
        error("Slit width $(width_um) um maps to position $target, " *
              "outside [0, $(s.max_position)]")
    end
    dev = _dev_char(s.device_id)
    delta = Int32(target - m.slit_positions[slit_index])
    _move_relative!(m, dev, delta, Int32(s.backlash))
    m.slit_positions[slit_index] = target
    return target * s.step_size_um
end

function get_slit(m::Monochromator, slit_index::Int)
    @assert 1 <= slit_index <= length(m.config.slits) "Slit index $slit_index out of range"
    return m.slit_positions[slit_index] * m.config.slits[slit_index].step_size_um
end

function reset_slit!(m::Monochromator, slit_index::Int)
    @assert 1 <= slit_index <= length(m.config.slits) "Slit index $slit_index out of range"
    s = m.config.slits[slit_index]
    dev = _dev_char(s.device_id)
    _cmd_nodata!(m, "R$dev"; timeout_ms=10_000)
    m.slit_positions[slit_index] = s.null_position
    return nothing
end

# --- Mirrors ---

function set_mirror!(m::Monochromator, mirror_index::Int, position_index::Int)
    @assert 1 <= mirror_index <= length(m.config.mirrors) "Mirror index $mirror_index out of range"
    mir = m.config.mirrors[mirror_index]
    @assert 1 <= position_index <= length(mir.positions) "Position index $position_index out of range"
    dev = _dev_char(mir.device_id)
    _cmd!(m, "I$dev", mir.positions[position_index].position)
    m.mirror_indices[mirror_index] = position_index
    return mir.positions[position_index].name
end

function reset_mirror!(m::Monochromator, mirror_index::Int)
    @assert 1 <= mirror_index <= length(m.config.mirrors) "Mirror index $mirror_index out of range"
    mir = m.config.mirrors[mirror_index]
    dev = _dev_char(mir.device_id)
    _cmd_nodata!(m, "R$dev")
    m.mirror_indices[mirror_index] = 1
    return nothing
end

# --- Shutter ---

function open_shutter!(m::Monochromator, shutter_index::Int=1)
    @assert 1 <= shutter_index <= m.config.shutter_count "Shutter index $shutter_index out of range"
    dev = _dev_char(m.config.shutter_device_id)
    _cmd_nodata!(m, "I$dev$shutter_index")
    m.shutter_open[shutter_index] = true
    return nothing
end

function close_shutter!(m::Monochromator, shutter_index::Int=1)
    @assert 1 <= shutter_index <= m.config.shutter_count "Shutter index $shutter_index out of range"
    dev = _dev_char(m.config.shutter_device_id)
    _cmd_nodata!(m, "D$dev$shutter_index")
    m.shutter_open[shutter_index] = false
    return nothing
end

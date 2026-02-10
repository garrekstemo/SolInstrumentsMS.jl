# High-level monochromator interface
#
# Wraps the low-level protocol with wavelength conversion, backlash
# compensation, position tracking, and bounds checking.

mutable struct Monochromator
    port_name::String
    connection::Union{LibSerialPort.SerialPort, Nothing}
    config::MonochromatorConfig
    timeout_ms::UInt32
    current_grating::Int        # 1-based index
    grating_position::Int32     # current step position
    slit_positions::Vector{Int32}
    mirror_indices::Vector{Int}  # 1-based index into mirror config positions
    shutter_open::Vector{Bool}
end

function Monochromator(port::String, config::MonochromatorConfig;
                       timeout_ms::UInt32=UInt32(5000))
    return Monochromator(
        port, nothing, config, timeout_ms,
        1, Int32(0),
        zeros(Int32, length(config.slits)),
        ones(Int, length(config.mirrors)),
        fill(false, config.shutter_count)
    )
end

# --- Connection ---

function connect!(m::Monochromator)
    m.connection = LibSerialPort.open(m.port_name, 9600)
    if !_check_connection(m.connection)
        close(m.connection)
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

function _cmd!(m::Monochromator, cmd::String, data::Int32)
    @assert isconnected(m) "Monochromator not connected"
    _command(m.connection, cmd, data)
end

# --- Grating / wavelength ---

function set_wavelength!(m::Monochromator, wavelength_nm::Real)
    g = m.config.gratings[m.current_grating]
    target = wavelength_to_position(g, wavelength_nm)
    if target < 0 || target > g.max_position
        error("Wavelength $(wavelength_nm) nm maps to position $target, outside [0, $(g.max_position)]")
    end
    if target < m.grating_position && g.backlash > 0
        overshoot = max(Int32(0), target - g.backlash)
        _cmd!(m, "I1", overshoot)
    end
    _cmd!(m, "I1", target)
    m.grating_position = target
    return position_to_wavelength(g, target)
end

function get_wavelength(m::Monochromator)
    g = m.config.gratings[m.current_grating]
    return position_to_wavelength(g, m.grating_position)
end

function reset_grating!(m::Monochromator)
    g = m.config.gratings[m.current_grating]
    _cmd!(m, "R1", Int32(0))
    m.grating_position = g.reset_position
    return nothing
end

# --- Slits ---

function set_slit!(m::Monochromator, slit_index::Int, width_um::Real)
    @assert 1 <= slit_index <= length(m.config.slits) "Slit index $slit_index out of range"
    s = m.config.slits[slit_index]
    target = round(Int32, width_um / s.step_size_um)
    if target < 0 || target > s.max_position
        error("Slit width $(width_um) um maps to position $target, outside [0, $(s.max_position)]")
    end
    if target < m.slit_positions[slit_index] && s.backlash > 0
        overshoot = max(Int32(0), target - s.backlash)
        _cmd!(m, "I9", overshoot)
    end
    _cmd!(m, "I9", target)
    m.slit_positions[slit_index] = target
    return target * s.step_size_um
end

function get_slit(m::Monochromator, slit_index::Int)
    @assert 1 <= slit_index <= length(m.config.slits) "Slit index $slit_index out of range"
    return m.slit_positions[slit_index] * m.config.slits[slit_index].step_size_um
end

function reset_slit!(m::Monochromator, slit_index::Int)
    @assert 1 <= slit_index <= length(m.config.slits) "Slit index $slit_index out of range"
    _cmd!(m, "R9", Int32(0))
    m.slit_positions[slit_index] = m.config.slits[slit_index].null_position
    return nothing
end

# --- Mirrors ---

function set_mirror!(m::Monochromator, mirror_index::Int, position_index::Int)
    @assert 1 <= mirror_index <= length(m.config.mirrors) "Mirror index $mirror_index out of range"
    mir = m.config.mirrors[mirror_index]
    @assert 1 <= position_index <= length(mir.positions) "Position index $position_index out of range"
    _cmd!(m, "I6", mir.positions[position_index].position)
    m.mirror_indices[mirror_index] = position_index
    return mir.positions[position_index].name
end

function reset_mirror!(m::Monochromator, mirror_index::Int)
    @assert 1 <= mirror_index <= length(m.config.mirrors) "Mirror index $mirror_index out of range"
    _cmd!(m, "R6", Int32(0))
    m.mirror_indices[mirror_index] = 1
    return nothing
end

# --- Shutter ---

function open_shutter!(m::Monochromator, shutter_index::Int=1)
    @assert 1 <= shutter_index <= m.config.shutter_count "Shutter index $shutter_index out of range"
    _cmd!(m, "I8$shutter_index", Int32(0))
    m.shutter_open[shutter_index] = true
    return nothing
end

function close_shutter!(m::Monochromator, shutter_index::Int=1)
    @assert 1 <= shutter_index <= m.config.shutter_count "Shutter index $shutter_index out of range"
    _cmd!(m, "D8$shutter_index", Int32(0))
    m.shutter_open[shutter_index] = false
    return nothing
end

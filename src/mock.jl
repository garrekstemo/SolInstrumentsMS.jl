# Mock serial connection — digital twin of the MS-series controller
#
# MockConnection simulates the monochromator controller's serial behavior:
# it parses incoming command frames, tracks motor positions, and returns
# correctly formatted responses (ACK for commands, nibble data for queries).
#
# Wire protocol (nibble-encoded ASCII, confirmed from DevCtrl capture):
#   Handshake:  host sends 0x06, controller replies 0x06
#   Command:    [cmd_string][nibble_data]\n → ACK
#   No-data:    [cmd_string]\n → ACK
#   A-query:    [cmd_string]\n → [nibble_data]\n ACK
#   SS/G-query: [cmd_string]\n → [nibble_data]\n  (no trailing ACK)
#
# Usage:
#   config = load_config("cfg/MS3501.cfg")
#   mono = Monochromator("/dev/mock", config)
#   conn = MockConnection()
#   connect!(mono, conn)
#   set_wavelength!(mono, 5200.0)
#   last_command(conn)  # → ("I1", 385)

mutable struct MockConnection <: IO
    input::Vector{UInt8}        # bytes from host (accumulates until processed)
    response::Vector{UInt8}     # response bytes queued for host to read
    open::Bool
    command_log::Vector{Tuple{String, Int32}}

    # Digital twin state — tracks what the real controller would track
    grating_position::Int32
    slit_positions::Dict{Char, Int32}
    shutter_open::Bool
    device_types::Dict{Char, Int}
end

function MockConnection(; grating_position::Int32=Int32(0),
                          device_types::Dict{Char, Int}=Dict(
                              '1' => 255,  # grating: stepper motor
                              '5' => 0,    # turret: no motor
                              '8' => 15,   # shutter: solenoid
                              '9' => 0,    # slit 1: no motor (MS3501i)
                              ':' => 0,    # slit 2: no motor (MS3501i)
                          ))
    MockConnection(
        UInt8[], UInt8[], true,
        Tuple{String, Int32}[],
        grating_position,
        Dict{Char, Int32}('9' => Int32(0), ':' => Int32(0)),
        false,
        device_types
    )
end

# --- IO interface ---

Base.isopen(mc::MockConnection) = mc.open

function Base.close(mc::MockConnection)
    mc.open = false
    return nothing
end

function Base.write(mc::MockConnection, data::Vector{UInt8})
    append!(mc.input, data)
    _process_input!(mc)
    return length(data)
end

Base.bytesavailable(mc::MockConnection) = length(mc.response)

function Base.read!(mc::MockConnection, buf::Vector{UInt8})
    for i in eachindex(buf)
        buf[i] = isempty(mc.response) ? ACK : popfirst!(mc.response)
    end
    return buf
end

Base.eof(mc::MockConnection) = false

# --- Command log ---

"""
    last_command(mc::MockConnection) → (cmd::String, data::Int32) or nothing

Return the most recently logged command, or `nothing` if no commands yet.
"""
last_command(mc::MockConnection) = isempty(mc.command_log) ? nothing : mc.command_log[end]

"""
    command_count(mc::MockConnection) → Int

Number of commands received so far.
"""
command_count(mc::MockConnection) = length(mc.command_log)

"""
    reset!(mc::MockConnection)

Clear the command log and I/O buffers. Does NOT reset twin state
(positions, shutter) — those carry over between test sections.
"""
function reset!(mc::MockConnection)
    empty!(mc.input)
    empty!(mc.response)
    empty!(mc.command_log)
    return nothing
end

# --- Input processing ---
#
# Called after every write. Checks if the input buffer contains a complete
# message and, if so, parses it and queues the appropriate response.
#
# Message types:
#   0x06           → handshake ACK, reply with ACK
#   [frame]\n      → command or query, reply depends on frame type

function _process_input!(mc::MockConnection)
    while !isempty(mc.input)
        # Standalone ACK = handshake
        if mc.input[1] == ACK
            push!(mc.response, ACK)
            popfirst!(mc.input)
            continue
        end

        # Look for complete frame (newline-terminated)
        nl_idx = findfirst(==(NEWLINE), mc.input)
        nl_idx === nothing && return  # incomplete frame, wait for more bytes

        frame = mc.input[1:nl_idx-1]
        mc.input = mc.input[nl_idx+1:end]

        isempty(frame) && continue
        _handle_frame!(mc, frame)
    end
end

# --- Frame dispatch ---
#
# Determines the frame type and delegates to the appropriate handler.
# Each handler updates twin state, logs the command, and queues response bytes.

function _handle_frame!(mc::MockConnection, frame::Vector{UInt8})
    cmd_char = Char(frame[1])

    if cmd_char == 'A'
        _handle_a_query!(mc, frame)
    elseif length(frame) >= 2 && cmd_char == 'S' && Char(frame[2]) == 'S'
        _handle_ss_query!(mc, frame)
    elseif cmd_char == 'G'
        _handle_g_query!(mc, frame)
    elseif cmd_char == 'R'
        _handle_reset_cmd!(mc, frame)
    elseif cmd_char in ('I', 'D')
        if length(frame) >= 2 && frame[2] == UInt8('8')
            _handle_shutter_cmd!(mc, frame)
        else
            _handle_motor_cmd!(mc, cmd_char, frame)
        end
    else
        # Unknown — log and ACK
        push!(mc.command_log, (String(Char.(frame)), Int32(0)))
        push!(mc.response, ACK)
    end
end

# --- Command handlers ---

function _handle_motor_cmd!(mc::MockConnection, cmd_char::Char, frame::Vector{UInt8})
    cmd = String(Char.(frame[1:min(2, length(frame))]))
    data_bytes = length(frame) > 2 ? frame[3:end] : UInt8[]
    steps = isempty(data_bytes) ? Int32(0) : Int32(_decode_nibbles(data_bytes))
    push!(mc.command_log, (cmd, steps))

    # Update twin position
    dev = length(frame) >= 2 ? Char(frame[2]) : '?'
    if dev == '1'
        mc.grating_position += cmd_char == 'I' ? steps : -steps
    elseif haskey(mc.slit_positions, dev)
        mc.slit_positions[dev] += cmd_char == 'I' ? steps : -steps
    end

    push!(mc.response, ACK)
end

function _handle_shutter_cmd!(mc::MockConnection, frame::Vector{UInt8})
    cmd = String(Char.(frame))
    push!(mc.command_log, (cmd, Int32(0)))
    mc.shutter_open = (Char(frame[1]) == 'I')
    push!(mc.response, ACK)
end

function _handle_reset_cmd!(mc::MockConnection, frame::Vector{UInt8})
    cmd = String(Char.(frame[1:min(2, length(frame))]))
    push!(mc.command_log, (cmd, Int32(0)))

    dev = length(frame) >= 2 ? Char(frame[2]) : '?'
    if dev == '1'
        mc.grating_position = Int32(0)
    elseif haskey(mc.slit_positions, dev)
        mc.slit_positions[dev] = Int32(0)
    end

    push!(mc.response, ACK)
end

# --- Query handlers ---

function _handle_a_query!(mc::MockConnection, frame::Vector{UInt8})
    cmd = String(Char.(frame))
    push!(mc.command_log, (cmd, Int32(0)))

    val = 0
    if length(frame) >= 3
        dev = Char(frame[2])
        reg = Char(frame[3])
        if reg == '0'  # DeviceType register
            val = get(mc.device_types, dev, 0)
        end
    end

    # A-query response: [nibble_data] \n ACK
    append!(mc.response, _encode_nibbles(val))
    push!(mc.response, NEWLINE)
    push!(mc.response, ACK)
end

function _handle_ss_query!(mc::MockConnection, frame::Vector{UInt8})
    cmd = String(Char.(frame))
    push!(mc.command_log, (cmd, Int32(0)))

    val = Int32(0)
    if cmd == "SS0107"
        val = mc.grating_position
    end

    # SS-query response: [nibble_data] \n  (no trailing ACK)
    append!(mc.response, _encode_nibbles(val))
    push!(mc.response, NEWLINE)
end

function _handle_g_query!(mc::MockConnection, frame::Vector{UInt8})
    cmd = String(Char.(frame))
    push!(mc.command_log, (cmd, Int32(0)))

    # G-query response: [nibble_data] \n  (no trailing ACK)
    append!(mc.response, _encode_nibbles(0))
    push!(mc.response, NEWLINE)
end

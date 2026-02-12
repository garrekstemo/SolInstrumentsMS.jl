# Mock serial connection for testing without hardware
#
# MockConnection simulates the monochromator's serial protocol: it captures
# all sent bytes and responds with ACK (0x06) to every command. This lets
# you exercise the full driver stack — config, commands, wavelength math,
# backlash compensation — without a physical device.
#
# Wire protocol (nibble-encoded ASCII, confirmed from DevCtrl capture):
#   ACK handshake (0x06) before each command
#   Command frame: [cmd_string][nibble_data]\n → response: ACK
#   No-data frame: [cmd_string]\n → response: ACK
#
# Usage:
#   config = load_config("cfg/MS3501.cfg")
#   mono = Monochromator("/dev/mock", config)
#   conn = MockConnection()
#   connect!(mono, conn)
#   set_wavelength!(mono, 5200.0)
#   last_command(conn)  # → ("I1", 385)

mutable struct MockConnection <: IO
    input::IOBuffer     # bytes sent by host (write target)
    open::Bool
    command_log::Vector{Tuple{String, Int32}}
end

MockConnection() = MockConnection(IOBuffer(), true, Tuple{String, Int32}[])

# --- IO interface ---

Base.isopen(mc::MockConnection) = mc.open

function Base.close(mc::MockConnection)
    mc.open = false
    return nothing
end

function Base.write(mc::MockConnection, data::Vector{UInt8})
    write(mc.input, data)
    return length(data)
end

# Always have ACK ready — the mock never stalls
Base.bytesavailable(mc::MockConnection) = 1

function Base.read!(mc::MockConnection, buf::Vector{UInt8})
    # Before returning ACK, try to parse any complete command from the input
    _try_parse_command!(mc)
    fill!(buf, ACK)
    return buf
end

Base.eof(mc::MockConnection) = false

# --- Command log ---

"""
    last_command(mc::MockConnection) → (cmd::String, data::Int32)

Return the most recently parsed command, or `nothing` if no commands yet.
"""
last_command(mc::MockConnection) = isempty(mc.command_log) ? nothing : mc.command_log[end]

"""
    command_count(mc::MockConnection) → Int

Number of commands received so far.
"""
command_count(mc::MockConnection) = length(mc.command_log)

"""
    reset!(mc::MockConnection)

Clear the command log and input buffer.
"""
function reset!(mc::MockConnection)
    mc.input = IOBuffer()
    empty!(mc.command_log)
    return nothing
end

# --- Internal: parse commands from the input buffer ---
#
# Frame format (nibble-encoded ASCII with \n terminator):
#   Motor move:  [I/D] [device] [nibble_data...] \n
#   Shutter:     [I/D] [8] [index] \n              (no data payload)
#   Reset:       [R] [device] \n                    (no data payload)
#
# The device character '8' is special-cased for shutter commands which
# carry the shutter index as part of the command string, not as nibble data.

function _try_parse_command!(mc::MockConnection)
    data = take!(mc.input)
    isempty(data) && return nothing

    # Single ACK byte = handshake, not a command
    if length(data) == 1 && data[1] == ACK
        return nothing
    end

    # Look for newline-terminated command frame
    nl_idx = findfirst(==(NEWLINE), data)
    nl_idx === nothing && return nothing

    frame = data[1:nl_idx-1]
    isempty(frame) && return nothing

    cmd_char = Char(frame[1])

    if cmd_char == 'R'
        # Reset: R + device, no data
        cmd = String(Char.(frame[1:min(2, length(frame))]))
        push!(mc.command_log, (cmd, Int32(0)))
    elseif cmd_char in ('I', 'D')
        if length(frame) >= 2 && frame[2] == UInt8('8')
            # Shutter: I/D + '8' + index, no data payload
            cmd = String(Char.(frame))
            push!(mc.command_log, (cmd, Int32(0)))
        else
            # Motor move: I/D + device + nibble_data
            cmd = String(Char.(frame[1:min(2, length(frame))]))
            data_bytes = length(frame) > 2 ? frame[3:end] : UInt8[]
            val = isempty(data_bytes) ? Int32(0) : Int32(_decode_nibbles(data_bytes))
            push!(mc.command_log, (cmd, val))
        end
    else
        # Unknown command — log entire string
        cmd = String(Char.(frame))
        push!(mc.command_log, (cmd, Int32(0)))
    end

    return nothing
end

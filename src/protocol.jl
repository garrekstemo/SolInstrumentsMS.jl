# Low-level serial protocol for SOL instruments MS-series
#
# Wire protocol (DevCtrl format, confirmed from serial capture 2026-02-12):
#
# All commands use ASCII nibble-encoded data with \n terminator.
# Each nibble (0-15) is encoded as byte value + 0x30:
#   0→'0', 1→'1', ..., 9→'9', A→':', B→';', C→'<', D→'=', E→'>', F→'?'
#
# Move command frame: [cmd_string] [nibble_data (variable)] \n
# No-data command:    [cmd_string] \n
# Response (move):    ACK (0x06)
# Response (query):   [nibble_data] \n ACK
#
# Every command is preceded by:
#   1. Purge RX buffer
#   2. ACK handshake (send 0x06, expect 0x06)
#   3. Purge RX buffer
#   4. Send command bytes one at a time
#   5. Read response
#
# Serial config: 9600 baud, 8 data bits, no parity, 2 stop bits (8N2)
# DTR and RTS asserted.

const ACK = 0x06
const NEWLINE = 0x0a

# --- Nibble encoding ---

function _encode_nibbles(val::Integer)
    val == 0 && return UInt8[0x30]
    nibbles = UInt8[]
    v = abs(val)
    while v > 0
        pushfirst!(nibbles, UInt8((v & 0x0f) + 0x30))
        v >>= 4
    end
    return nibbles
end

function _decode_nibbles(bytes::Vector{UInt8})
    val = 0
    for b in bytes
        val = (val << 4) | Int(b - 0x30)
    end
    return val
end

# --- Low-level serial I/O ---

function _send_bytes(conn::IO, bytes::Vector{UInt8})
    for b in bytes
        write(conn, [b])
    end
end

function _read_byte(conn::IO, timeout_ms::Integer=5000)
    deadline = time_ns() + timeout_ms * 1_000_000
    while time_ns() < deadline
        if bytesavailable(conn) > 0
            buf = zeros(UInt8, 1)
            read!(conn, buf)
            return buf[1]
        end
        sleep(0.001)
    end
    error("Serial read timed out after $(timeout_ms) ms — check connection")
end

function _purge(conn::IO)
    n = bytesavailable(conn)
    buf = zeros(UInt8, 1)
    for _ in 1:n
        read!(conn, buf)
    end
end

function _handshake(conn::IO; timeout_ms::Integer=3000)
    _send_bytes(conn, [ACK])
    resp = _read_byte(conn, timeout_ms)
    if resp != ACK
        error("Device handshake failed (expected ACK 0x06, got 0x$(string(resp, base=16)))")
    end
    return nothing
end

# --- Command functions ---

"""
Send a move command with nibble-encoded data.
Frame: [cmd] [nibble_data] \\n → response: ACK
"""
function _command(conn::IO, cmd::String, data::Integer;
                  timeout_ms::Integer=5000)
    _purge(conn)
    _handshake(conn)
    _purge(conn)
    frame = vcat(Vector{UInt8}(cmd), _encode_nibbles(data), [NEWLINE])
    _send_bytes(conn, frame)
    resp = _read_byte(conn, timeout_ms)
    if resp != ACK
        error("SOL MS command '$cmd' failed (expected ACK 0x06, got 0x$(string(resp, base=16)))")
    end
    return nothing
end

"""
Send a command with no data payload (shutter, reset).
Frame: [cmd] \\n → response: ACK
"""
function _command_nodata(conn::IO, cmd::String;
                         timeout_ms::Integer=5000)
    _purge(conn)
    _handshake(conn)
    _purge(conn)
    frame = vcat(Vector{UInt8}(cmd), [NEWLINE])
    _send_bytes(conn, frame)
    resp = _read_byte(conn, timeout_ms)
    if resp != ACK
        error("SOL MS command '$cmd' failed (expected ACK 0x06, got 0x$(string(resp, base=16)))")
    end
    return nothing
end

"""
Send a query command that returns nibble-encoded data with trailing ACK.
Frame: [cmd] \\n → response: [nibble_data] \\n ACK

Used for A-type register queries (e.g. `A80`).
"""
function _query(conn::IO, cmd::String; timeout_ms::Integer=5000)
    _purge(conn)
    _handshake(conn)
    _purge(conn)
    frame = vcat(Vector{UInt8}(cmd), [NEWLINE])
    _send_bytes(conn, frame)
    response_bytes = UInt8[]
    while true
        b = _read_byte(conn, timeout_ms)
        b == NEWLINE && break
        push!(response_bytes, b)
    end
    ack = _read_byte(conn, timeout_ms)
    if ack != ACK
        error("SOL MS query '$cmd' missing trailing ACK (got 0x$(string(ack, base=16)))")
    end
    return _decode_nibbles(response_bytes)
end

"""
Send a query command that returns nibble-encoded data WITHOUT trailing ACK.
Frame: [cmd] \\n → response: [nibble_data] \\n

Used for G and SS subsystem queries (e.g. `SS0107`).
"""
function _query_noack(conn::IO, cmd::String; timeout_ms::Integer=5000)
    _purge(conn)
    _handshake(conn)
    _purge(conn)
    frame = vcat(Vector{UInt8}(cmd), [NEWLINE])
    _send_bytes(conn, frame)
    response_bytes = UInt8[]
    while true
        b = _read_byte(conn, timeout_ms)
        b == NEWLINE && break
        push!(response_bytes, b)
    end
    return _decode_nibbles(response_bytes)
end

function _check_connection(conn::IO; timeout_ms::Integer=3000)
    _purge(conn)
    _send_bytes(conn, [ACK])
    try
        resp = _read_byte(conn, timeout_ms)
        return resp == ACK
    catch
        return false
    end
end

# --- Wavelength conversion ---

"""
    wavelength_to_position(g::GratingConfig, wavelength_nm::Real) → Int32

Convert a wavelength (nm) to a motor step position using the diffraction grating equation:

    position = asin(λ × 10⁻⁶ × d / (2 cos θ₂)) / Δθ

where `d` is the groove density (lines/mm), `θ₂` is the fixed grating mount angle (rad),
and `Δθ` is the angular step size (rad/step).

Throws an error if the wavelength is outside the grating's angular range (|sin⁻¹ arg| > 1).
"""
function wavelength_to_position(g::GratingConfig, wavelength_nm::Real)
    arg = wavelength_nm * 1e-6 * g.groove_density / 2.0 / cos(g.theta2)
    if abs(arg) > 1.0
        error("Wavelength $(wavelength_nm) nm is outside range for grating $(g.name)")
    end
    return round(Int32, asin(arg) / g.step_size)
end

"""
    position_to_wavelength(g::GratingConfig, position::Integer) → Float64

Convert a motor step position to a wavelength (nm) using the inverse grating equation:

    λ_nm = 2 sin(Δθ × position) × cos(θ₂) / d × 10⁶

where `d` is the groove density (lines/mm), `θ₂` is the fixed grating mount angle (rad),
and `Δθ` is the angular step size (rad/step).

Position 0 corresponds to zero order (all wavelengths reflected).
"""
function position_to_wavelength(g::GratingConfig, position::Integer)
    return 2.0 * sin(g.step_size * position) * cos(g.theta2) / g.groove_density * 1e6
end

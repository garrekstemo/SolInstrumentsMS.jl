# Low-level serial protocol for SOL instruments MS-series
#
# Frame: [ASCII command string] [4-byte big-endian Int32 data]
# Response: 0x06 (ACK) on success
# Must send byte-by-byte — bulk send fails on this device.
# See docs/protocol.md for full specification.

const ACK = 0x06

function _send_bytes(conn::LibSerialPort.SerialPort, bytes::Vector{UInt8})
    for b in bytes
        write(conn, [b])
    end
end

function _read_byte(conn::LibSerialPort.SerialPort)
    buf = zeros(UInt8, 1)
    read!(conn, buf)
    return buf[1]
end

function _int32_bytes(val::Int32)
    return UInt8[
        (val >> 24) & 0xff,
        (val >> 16) & 0xff,
        (val >> 8)  & 0xff,
        val         & 0xff,
    ]
end

function _command(conn::LibSerialPort.SerialPort, cmd::String, data::Int32)
    frame = vcat(Vector{UInt8}(cmd), _int32_bytes(data))
    _send_bytes(conn, frame)
    resp = _read_byte(conn)
    if resp != ACK
        error("SOL MS command '$cmd' failed (expected ACK 0x06, got 0x$(string(resp, base=16)))")
    end
    return nothing
end

function _check_connection(conn::LibSerialPort.SerialPort)
    _send_bytes(conn, [ACK])
    resp = _read_byte(conn)
    return resp == ACK
end

# --- Wavelength conversion ---

function wavelength_to_position(g::GratingConfig, wavelength_nm::Real)
    arg = wavelength_nm * 1e-6 * g.groove_density / 2.0 / cos(g.theta2)
    if abs(arg) > 1.0
        error("Wavelength $(wavelength_nm) nm is outside range for grating $(g.name)")
    end
    return round(Int32, asin(arg) / g.step_size)
end

function position_to_wavelength(g::GratingConfig, position::Integer)
    return 2.0 * sin(g.step_size * position) * cos(g.theta2) / g.groove_density * 1e6
end

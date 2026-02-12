# Configuration types and .cfg file parser
#
# Parses the INI-style .cfg files exported by the manufacturer's DevCtrl software.
#
# Unit conventions in DevCtrl .cfg files (SI units):
#   LineCount / ShtrichCount  → lines/meter  (e.g. 1800000 = 1800 g/mm)
#   BlazeWave                 → meters        (e.g. 5E-7 = 500 nm)
#   Focus / Fokus             → meters        (e.g. 0.346 = 346 mm)
#   StepSize                  → radians/step
#   Theta2 / Tetta2           → radians
#   Slit StepSize             → meters/step   (e.g. 5E-7 = 0.5 um)
#
# All values are converted to practical units on load (lines/mm, nm, cm, um).
# Key names have Russian-influenced variants — both forms are accepted.
#
# DeviceID: Each hardware subsystem has an ASCII device ID that becomes the
# command character in the serial protocol. E.g. DeviceID=57 → '9' → "I9".

struct GratingConfig
    name::String
    device_id::UInt8            # ASCII code for command char (e.g. 49 = '1')
    step_timeout_ms::UInt32
    reset_timeout_ms::UInt32
    turret_position::Int32
    reset_position::Int32
    max_position::Int32
    backlash::Int32
    step_size::Float64          # radians per step
    groove_density::Float64     # grooves/mm
    theta2::Float64             # mount angle (radians)
    blaze_wavelength::Float64   # nm
    focal_length::Float64       # cm
    manual_change::Bool
    manual_change_position::Int32
    initial_position::Int32     # CurStepPosition from .cfg at export time
end

struct SlitConfig
    name::String
    device_id::UInt8            # ASCII code for command char (57='9', 58=':', ...)
    step_timeout_ms::UInt32
    null_position::Int32
    max_position::Int32
    backlash::Int32
    step_size_um::Float64       # um per step
    initial_position::Int32     # CurStepPosition from .cfg at export time
end

struct MirrorPosition
    name::String
    position::Int32
end

struct MirrorConfig
    name::String
    device_id::UInt8
    step_timeout_ms::UInt32
    reset_timeout_ms::UInt32
    positions::Vector{MirrorPosition}
end

struct TurretConfig
    device_id::UInt8
    grating_indices::Vector{Int}    # which grating at each position (1-based)
    turret_positions::Vector{Int32} # step position for each slot
    current_grating::Int            # CurGrating from .cfg (1-based)
end

struct MonochromatorConfig
    gratings::Vector{GratingConfig}
    slits::Vector{SlitConfig}
    mirrors::Vector{MirrorConfig}
    turret::Union{TurretConfig, Nothing}
    shutter_count::Int
    shutter_device_id::UInt8    # ASCII code for shutter command char (default '8')
end

function load_config(cfg_path::String)
    cfg = _parse_ini(cfg_path)

    device = get(cfg, "Device", Dict{String,String}())
    n_shutters = parse(Int, get(device, "ShutterCount", "0"))

    # Discover sections by scanning keys — don't trust Device counts
    # (e.g. DevCtrl may report SlitCount=0 while [Slit1], [Slit2] exist)
    grating_sections = _find_sections(cfg, "Grating")
    slit_sections = _find_sections(cfg, "Slit")
    mirror_sections = _find_sections(cfg, "Mirror")
    turret_sections = _find_sections(cfg, "Turret")
    shutter_sections = _find_sections(cfg, "Shutter")

    gratings = [_parse_grating(s) for s in grating_sections]
    slits = [_parse_slit(s, i) for (i, s) in enumerate(slit_sections)]
    mirrors = [_parse_mirror(s) for s in mirror_sections]
    turret = isempty(turret_sections) ? nothing : _parse_turret(turret_sections[1])

    shutter_dev_id = if !isempty(shutter_sections)
        parse(UInt8, get(shutter_sections[1], "DeviceID", "56"))
    else
        UInt8('8')
    end

    return MonochromatorConfig(gratings, slits, mirrors, turret, n_shutters, shutter_dev_id)
end

# --- Section discovery ---

function _find_sections(cfg::Dict{String, Dict{String,String}}, prefix::String)
    found = Pair{Int, Dict{String,String}}[]
    for (name, data) in cfg
        m = match(Regex("^$(prefix)(\\d+)\$"), name)
        if m !== nothing
            push!(found, parse(Int, m[1]) => data)
        end
    end
    sort!(found, by=first)
    return [p.second for p in found]
end

# --- Section parsers ---

function _parse_grating(section::Dict{String,String})
    name = get(section, "CaptionWork", "Grating")
    dev_id = parse(UInt8, get(section, "DeviceID", "49"))  # default '1'
    step_timeout = parse(UInt32, get(section, "StepTimeOut", "100"))
    reset_timeout = parse(UInt32, get(section, "ResetTimeOut", "60000"))
    reset_pos = parse(Int32, get(section, "ResetPosition1", "0"))
    max_pos = parse(Int32, get(section, "MaxMayStepCount", "500000"))
    backlash = parse(Int32, get(section, "RollToBack", "0"))
    manual = _parse_bool(get(section, "ManualChange", "0"))
    manual_pos = parse(Int32, get(section, "ManualChangePosition", "0"))
    cur_pos = parse(Int32, get(section, "CurStepPosition", "0"))

    step_size = parse(Float64, get(section, "StepSize", "0.0"))
    groove_raw = _get_groove_raw(section)
    theta2 = parse(Float64, something(
        _tryget(section, "Theta2"), _tryget(section, "Tetta2"), "0.0"))
    blaze_raw = parse(Float64, get(section, "BlazeWave", "0.0"))
    focal_raw = parse(Float64, something(
        _tryget(section, "Focus"), _tryget(section, "Fokus"), "0.35"))

    # Convert from DevCtrl SI units to practical units
    groove_density = groove_raw > 10000 ? groove_raw / 1000.0 : groove_raw  # → lines/mm
    blaze_nm = blaze_raw < 0.001 ? blaze_raw * 1e9 : blaze_raw             # → nm
    focal_cm = focal_raw < 1.0 ? focal_raw * 100.0 : focal_raw             # → cm

    return GratingConfig(
        name, dev_id, step_timeout, reset_timeout, Int32(0),
        reset_pos, max_pos, backlash, step_size, groove_density, theta2,
        blaze_nm, focal_cm, manual, manual_pos, cur_pos
    )
end

function _get_groove_raw(section::Dict{String,String})
    for key in ("LineCount", "ShtrichCount")
        if haskey(section, key)
            return parse(Float64, section[key])
        end
    end
    return 0.0
end

function _parse_slit(section::Dict{String,String}, index::Int)
    name = get(section, "CaptionWork", "Slit")
    # Default device ID: '9' for first slit, ':' for second, etc.
    default_dev_id = string(UInt8('9') + index - 1)
    dev_id = parse(UInt8, get(section, "DeviceID", default_dev_id))
    step_timeout = parse(UInt32, get(section, "StepTimeOut", "100"))
    null_pos = parse(Int32, get(section, "NullPosition", "0"))
    max_pos = parse(Int32, get(section, "MaxMayStepCount", "4000"))
    backlash = parse(Int32, get(section, "RollToBack", "0"))
    step_size_m = parse(Float64, get(section, "StepSize", "0.5e-6"))
    cur_pos = parse(Int32, get(section, "CurStepPosition", "0"))
    # StepSize is always in meters in DevCtrl .cfg files
    return SlitConfig(name, dev_id, step_timeout, null_pos, max_pos, backlash,
                      step_size_m * 1e6, cur_pos)
end

function _parse_mirror(section::Dict{String,String})
    name = get(section, "CaptionWork", "Mirror")
    dev_id = parse(UInt8, get(section, "DeviceID", "54"))  # default '6'
    step_timeout = parse(UInt32, get(section, "StepTimeOut", "1000"))
    reset_timeout = parse(UInt32, get(section, "ResetTimeOut", "10000"))
    n_positions = parse(Int, get(section, "PositionCount", "1"))
    positions = MirrorPosition[]
    for p in 0:(n_positions - 1)
        # Try both 0-indexed and 1-indexed keys
        pos_str = something(
            _tryget(section, "MirrorPosition$p"),
            _tryget(section, "MirrorPosition$(p+1)"),
            "0")
        cap_str = something(
            _tryget(section, "PosCaption$p"),
            _tryget(section, "PosCaption$(p+1)"),
            "Position $(p+1)")
        push!(positions, MirrorPosition(cap_str, parse(Int32, pos_str)))
    end
    return MirrorConfig(name, dev_id, step_timeout, reset_timeout, positions)
end

function _parse_turret(section::Dict{String,String})
    dev_id = parse(UInt8, get(section, "DeviceID", "53"))  # default '5'
    n_positions = parse(Int, get(section, "PositionCount", "1"))
    grating_indices = Int[]
    turret_positions = Int32[]
    for p in 1:n_positions
        # Try 1-indexed first (DevCtrl), then 0-indexed
        gi_str = something(
            _tryget(section, "NumGrating$p"),
            _tryget(section, "NumGrating$(p-1)"),
            "0")
        tp_str = something(
            _tryget(section, "TurretPosition$p"),
            _tryget(section, "TurretPosition$(p-1)"),
            "0")
        gi = parse(Int, gi_str)
        # 255 is a sentinel meaning "no grating at this position"
        if gi != 255
            push!(grating_indices, gi)
            push!(turret_positions, parse(Int32, tp_str))
        end
    end
    cur_grating = parse(Int, get(section, "CurGrating", "1"))
    return TurretConfig(dev_id, grating_indices, turret_positions, cur_grating)
end

# --- Helpers ---

function _parse_bool(s::String)
    lower = lowercase(strip(s))
    return lower == "true" || lower == "1"
end

function _parse_ini(path::String)
    sections = Dict{String, Dict{String,String}}()
    current_section = ""
    for line in readlines(path)
        stripped = strip(line)
        isempty(stripped) && continue
        stripped[1] == ';' && continue
        stripped[1] == '#' && continue
        if startswith(stripped, '[') && endswith(stripped, ']')
            current_section = stripped[2:end-1]
            sections[current_section] = Dict{String,String}()
        elseif contains(stripped, '=') && !isempty(current_section)
            key, val = split(stripped, '='; limit=2)
            sections[current_section][strip(String(key))] = strip(String(val))
        end
    end
    return sections
end

_tryget(d::Dict{String,String}, key::String) = haskey(d, key) ? d[key] : nothing

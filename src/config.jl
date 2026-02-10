# Configuration types and .cfg file parser
#
# Parses the INI-style .cfg files from the manufacturer's DevCtrl software.
# Key names have Russian-influenced variants (ShtrichCount/LineCount,
# Tetta2/Theta2, Fokus/Focus) — both forms are accepted.

struct GratingConfig
    name::String
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
end

struct SlitConfig
    name::String
    step_timeout_ms::UInt32
    null_position::Int32
    max_position::Int32
    backlash::Int32
    step_size_um::Float64       # um per step
end

struct MirrorPosition
    name::String
    position::Int32
end

struct MirrorConfig
    name::String
    step_timeout_ms::UInt32
    reset_timeout_ms::UInt32
    positions::Vector{MirrorPosition}
end

struct MonochromatorConfig
    gratings::Vector{GratingConfig}
    slits::Vector{SlitConfig}
    mirrors::Vector{MirrorConfig}
    shutter_count::Int
end

function load_config(cfg_path::String)
    cfg = _parse_ini(cfg_path)

    device = cfg["Device"]
    n_turrets = parse(Int, device["TurretCount"])
    n_shutters = parse(Int, device["ShutterCount"])
    n_mirrors = parse(Int, device["MirrorCount"])
    n_slits = parse(Int, device["SlitCount"])

    gratings = GratingConfig[]
    for t in 0:(n_turrets - 1)
        turret = cfg["Turret$t"]
        n_positions = parse(Int, turret["PositionCount"])
        for p in 0:(n_positions - 1)
            n_gratings_at_pos = parse(Int, turret["NumGrating$p"])
            turret_pos = parse(Int32, turret["TurretPosition$p"])
            for g in 0:(n_gratings_at_pos - 1)
                grating_section = cfg["Grating$g"]
                push!(gratings, _parse_grating(grating_section, turret_pos))
            end
        end
    end

    slits = SlitConfig[]
    for s in 0:(n_slits - 1)
        push!(slits, _parse_slit(cfg["Slit$s"]))
    end

    mirrors = MirrorConfig[]
    for mi in 0:(n_mirrors - 1)
        push!(mirrors, _parse_mirror(cfg["Mirror$mi"]))
    end

    return MonochromatorConfig(gratings, slits, mirrors, n_shutters)
end

# --- Section parsers ---

function _parse_grating(section::Dict{String,String}, turret_position::Int32)
    name = get(section, "CaptionWork", "Grating")
    step_timeout = parse(UInt32, get(section, "StepTimeOut", "100"))
    reset_timeout = parse(UInt32, get(section, "ResetTimeOut", "60000"))
    reset_pos = parse(Int32, get(section, "ResetPosition1", "0"))
    max_pos = parse(Int32, get(section, "MaxMayStepCount", "500000"))
    backlash = parse(Int32, get(section, "RollToBack", "0"))
    manual = lowercase(get(section, "ManualChange", "FALSE")) == "true"
    manual_pos = parse(Int32, get(section, "ManualChangePosition", "0"))

    step_size = parse(Float64, get(section, "StepSize", "0.0"))
    groove = _get_groove_density(section)
    theta2 = parse(Float64, something(
        _tryget(section, "Theta2"), _tryget(section, "Tetta2"), "0.0"))
    blaze = parse(Float64, get(section, "BlazeWave", "0.0"))
    focal = parse(Float64, something(
        _tryget(section, "Focus"), _tryget(section, "Fokus"), "35.0"))

    return GratingConfig(
        name, step_timeout, reset_timeout, turret_position,
        reset_pos, max_pos, backlash, step_size, groove, theta2,
        blaze, focal, manual, manual_pos
    )
end

function _get_groove_density(section::Dict{String,String})
    for key in ("LineCount", "ShtrichCount")
        if haskey(section, key)
            return parse(Float64, section[key])
        end
    end
    return 0.0
end

function _parse_slit(section::Dict{String,String})
    name = get(section, "CaptionWork", "Slit")
    step_timeout = parse(UInt32, get(section, "StepTimeOut", "100"))
    null_pos = parse(Int32, get(section, "NullPosition", "0"))
    max_pos = parse(Int32, get(section, "MaxMayStepCount", "4000"))
    backlash = parse(Int32, get(section, "RollToBack", "0"))
    step_size_m = parse(Float64, get(section, "StepSize", "0.5e-6"))
    return SlitConfig(name, step_timeout, null_pos, max_pos, backlash, step_size_m * 1e6)
end

function _parse_mirror(section::Dict{String,String})
    name = get(section, "CaptionWork", "Mirror")
    step_timeout = parse(UInt32, get(section, "StepTimeOut", "1000"))
    reset_timeout = parse(UInt32, get(section, "ResetTimeOut", "10000"))
    n_positions = parse(Int, get(section, "PositionCount", "1"))
    positions = MirrorPosition[]
    for p in 0:(n_positions - 1)
        pos = parse(Int32, get(section, "MirrorPosition$p", "0"))
        cap = get(section, "PosCaption$p", "Position $p")
        push!(positions, MirrorPosition(cap, pos))
    end
    return MirrorConfig(name, step_timeout, reset_timeout, positions)
end

# --- Simple INI parser ---

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

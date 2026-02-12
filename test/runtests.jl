using Test
using SolInstrumentsMS

const CFG_PATH = joinpath(@__DIR__, "..", "cfg", "MS3501.cfg")

@testset "SolInstrumentsMS" begin

    @testset "Config parsing" begin
        config = load_config(CFG_PATH)

        @testset "Gratings" begin
            @test length(config.gratings) == 3
            g1, g2, g3 = config.gratings

            # UV-Vis gratings
            @test g1.groove_density == 1800.0
            @test g2.groove_density == 1800.0
            @test g1.blaze_wavelength == 500.0
            @test g1.device_id == UInt8('1')
            @test g1.initial_position == 33142

            # MIR grating
            @test g3.groove_density == 100.0
            @test g3.blaze_wavelength == 4160.0
            @test g3.device_id == UInt8('1')

            # Common parameters
            @test g1.theta2 == 0.1391
            @test abs(g1.focal_length - 34.6) < 0.1
            @test g1.backlash == 2000
            @test g1.reset_position == -1491
            @test g1.manual_change == true
        end

        @testset "Slits" begin
            @test length(config.slits) == 2
            s1, s2 = config.slits

            @test s1.name == "Entrance Slit S1"
            @test s2.name == "Exit Slit S2"
            @test s1.device_id == UInt8('9')   # DeviceID=57
            @test s2.device_id == UInt8(':')   # DeviceID=58
            @test s1.step_size_um == 0.5
            @test s2.step_size_um == 0.5
            @test s1.initial_position == -185
            @test s2.initial_position == -320
            @test s1.backlash == 200
        end

        @testset "Turret" begin
            @test config.turret !== nothing
            t = config.turret
            @test t.device_id == UInt8('5')
            @test length(t.grating_indices) == 2
            @test t.grating_indices == [1, 2]
            @test t.current_grating == 3
        end

        @testset "Shutter" begin
            @test config.shutter_count == 1
            @test config.shutter_device_id == UInt8('8')
        end

        @test length(config.mirrors) == 0
    end

    @testset "Wavelength conversion" begin
        config = load_config(CFG_PATH)

        @testset "UV-Vis grating (1800 g/mm)" begin
            g = config.gratings[1]
            for wl in [300.0, 400.0, 500.0, 600.0, 700.0]
                pos = wavelength_to_position(g, wl)
                wl_back = position_to_wavelength(g, pos)
                @test abs(wl_back - wl) < 0.5
                @test pos > 0
                @test pos <= g.max_position
            end
        end

        @testset "MIR grating (100 g/mm)" begin
            g = config.gratings[3]
            for wl in [2000.0, 4000.0, 5000.0, 6000.0, 8000.0]
                pos = wavelength_to_position(g, wl)
                wl_back = position_to_wavelength(g, pos)
                @test abs(wl_back - wl) < 0.5
                @test pos > 0
                @test pos <= g.max_position
            end
        end

        @testset "Out of range" begin
            g = config.gratings[1]  # 1800 g/mm, max ~1100 nm
            @test_throws ErrorException wavelength_to_position(g, 1200.0)
        end
    end

    @testset "MockConnection" begin
        conn = MockConnection()
        @test isopen(conn)
        @test command_count(conn) == 0
        @test last_command(conn) === nothing
        close(conn)
        @test !isopen(conn)
    end

    @testset "Monochromator with MockConnection" begin
        config = load_config(CFG_PATH)
        mono = Monochromator("/dev/mock", config)
        conn = MockConnection()

        @testset "Connect" begin
            connect!(mono, conn)
            @test isconnected(mono)
            # CurGrating=3 in .cfg → initializes to MIR grating (100 g/mm)
            @test identify(mono) == "SOL instruments MS on /dev/mock (WaveLength, 100.0 g/mm)"
        end

        @testset "Initial state from .cfg" begin
            @test mono.current_grating == 3
            @test mono.grating_position == 33142
            @test mono.slit_positions == Int32[-185, -320]
            @test abs(get_wavelength(mono) - 5103.0) < 1.0
        end

        @testset "Grating forward move" begin
            reset!(conn)
            g = config.gratings[3]

            # Move to 5200 nm (forward from ~5103 nm initial)
            wl = set_wavelength!(mono, 5200.0)
            @test abs(wl - 5200.0) < 0.5

            expected_pos = wavelength_to_position(g, 5200.0)
            delta = expected_pos - Int32(33142)
            @test delta > 0  # confirm forward

            @test command_count(conn) == 1
            cmd, data = last_command(conn)
            @test cmd == "I1"
            @test data == delta
            @test mono.grating_position == expected_pos
        end

        @testset "Grating backlash compensation" begin
            # mono is now at position(5200) from previous test
            g = config.gratings[3]
            pos_before = mono.grating_position

            # First move further forward (no backlash)
            reset!(conn)
            set_wavelength!(mono, 6000.0)
            @test command_count(conn) == 1  # single I command

            pos_6000 = mono.grating_position
            reset!(conn)

            # Move backward — triggers backlash (2 commands: D then I)
            set_wavelength!(mono, 4000.0)
            @test command_count(conn) == 2

            expected_pos = wavelength_to_position(g, 4000.0)
            backward_delta = pos_6000 - expected_pos

            cmd1, data1 = conn.command_log[1]
            cmd2, data2 = conn.command_log[2]
            @test cmd1 == "D1"  # decrease
            @test data1 == backward_delta + g.backlash
            @test cmd2 == "I1"  # backlash correction
            @test data2 == g.backlash
            @test mono.grating_position == expected_pos
        end

        @testset "Backlash clamped at zero order" begin
            # mono is at position(4000) from backlash test above
            g = config.gratings[3]
            pos_before = mono.grating_position
            @test pos_before > g.backlash  # sanity: well above backlash

            reset!(conn)

            # Move to zero order — backlash clamped to 0 (target),
            # so only a single D command (no overshoot)
            set_wavelength!(mono, 0.0)
            @test mono.grating_position == 0
            @test command_count(conn) == 1

            cmd, data = last_command(conn)
            @test cmd == "D1"
            @test data == pos_before  # backward by exactly pos_before steps
        end

        @testset "Slit 1 commands (DeviceID=57 → '9')" begin
            reset!(conn)
            s1 = config.slits[1]

            # Initial position: -185, target: 100 um → 200 steps
            actual_um = set_slit!(mono, 1, 100.0)
            @test abs(actual_um - 100.0) < 0.5

            target = round(Int32, 100.0 / 0.5)  # 200
            delta = target - Int32(-185)  # 385 (forward)
            @test delta > 0

            cmd, data = last_command(conn)
            @test cmd == "I9"
            @test data == delta
        end

        @testset "Slit 2 commands (DeviceID=58 → ':')" begin
            reset!(conn)

            # Initial position: -320, target: 50 um → 100 steps
            actual_um = set_slit!(mono, 2, 50.0)
            @test abs(actual_um - 50.0) < 0.5

            target = round(Int32, 50.0 / 0.5)  # 100
            delta = target - Int32(-320)  # 420 (forward)
            @test delta > 0

            cmd, data = last_command(conn)
            @test cmd == "I:"
            @test data == delta
        end

        @testset "Shutter commands (1-indexed, no data)" begin
            reset!(conn)
            open_shutter!(mono)
            cmd, data = last_command(conn)
            @test cmd == "I81"  # shutter 1 → protocol index 1
            @test data == 0
            @test mono.shutter_open[1] == true

            reset!(conn)
            close_shutter!(mono)
            cmd, data = last_command(conn)
            @test cmd == "D81"
            @test data == 0
            @test mono.shutter_open[1] == false
        end

        @testset "Reset grating" begin
            reset!(conn)
            reset_grating!(mono)
            cmd, data = last_command(conn)
            @test cmd == "R1"
            @test data == 0
            @test mono.grating_position == config.gratings[3].reset_position
        end

        @testset "Reset slits" begin
            reset!(conn)
            reset_slit!(mono, 1)
            cmd, data = last_command(conn)
            @test cmd == "R9"
            @test data == 0
            @test mono.slit_positions[1] == config.slits[1].null_position

            reset!(conn)
            reset_slit!(mono, 2)
            cmd, data = last_command(conn)
            @test cmd == "R:"
            @test data == 0
            @test mono.slit_positions[2] == config.slits[2].null_position
        end

        @testset "Disconnect" begin
            disconnect!(mono)
            @test !isconnected(mono)
        end
    end

    @testset "Twin state tracking" begin
        config = load_config(CFG_PATH)
        mono = Monochromator("/dev/mock", config)
        conn = MockConnection()
        connect!(mono, conn)

        g = config.gratings[3]

        @testset "Grating position tracks moves" begin
            @test conn.grating_position == 0  # mock starts at 0

            # Forward move: mono thinks it's at 33142, sends I1[delta]
            set_wavelength!(mono, 5200.0)
            expected_pos = wavelength_to_position(g, 5200.0)
            delta = expected_pos - Int32(33142)
            @test conn.grating_position == delta  # mock accumulated delta from 0

            # Another forward move
            prev_mock_pos = conn.grating_position
            set_wavelength!(mono, 6000.0)
            pos_6000 = wavelength_to_position(g, 6000.0)
            delta2 = pos_6000 - expected_pos
            @test conn.grating_position == prev_mock_pos + delta2
        end

        @testset "Backward move with backlash" begin
            mock_before = conn.grating_position
            pos_6000 = mono.grating_position

            # Backward move → D(delta+backlash) then I(backlash)
            set_wavelength!(mono, 4000.0)
            pos_4000 = wavelength_to_position(g, 4000.0)
            backward_delta = pos_6000 - pos_4000

            # Mock: subtracted (backward_delta + backlash), then added backlash
            @test conn.grating_position == mock_before - backward_delta
        end

        @testset "Shutter state" begin
            @test conn.shutter_open == false
            open_shutter!(mono)
            @test conn.shutter_open == true
            close_shutter!(mono)
            @test conn.shutter_open == false
        end

        @testset "Reset zeroes position" begin
            reset_grating!(mono)
            @test conn.grating_position == 0
        end

        disconnect!(mono)
    end

    @testset "find_previous_position! with mock" begin
        config = load_config(CFG_PATH)
        mono = Monochromator("/dev/mock", config)
        # Mock starts with a known "saved" position
        conn = MockConnection(grating_position=Int32(33949))
        connect!(mono, conn)

        result = find_previous_position!(mono)

        # Driver queried SS0107 → got 33949
        @test result.position == 33949

        # Driver should have: queried, reset (R1), then moved (I1)
        @test any(c -> c[1] == "SS0107", conn.command_log)
        @test any(c -> c[1] == "R1", conn.command_log)

        # After R1, mock position was 0. After I1[33949], mock position is 33949.
        @test conn.grating_position == 33949

        # Driver's internal tracking should match
        @test mono.grating_position == 33949

        # Wavelength should be consistent
        g = config.gratings[mono.current_grating]
        expected_wl = position_to_wavelength(g, 33949)
        @test abs(result.wavelength_nm - expected_wl) < 0.1
        @test abs(get_wavelength(mono) - expected_wl) < 0.1

        disconnect!(mono)
    end

    @testset "MIR grating workflow" begin
        config = load_config(CFG_PATH)
        mono = Monochromator("/dev/mock", config)
        conn = MockConnection()
        connect!(mono, conn)

        # Already on MIR grating (CurGrating=3 in .cfg)
        @test mono.current_grating == 3
        g = config.gratings[3]

        # Sweep the MIR range — verify wavelength roundtrip accuracy
        for target_wl in 3000.0:500.0:7000.0
            wl = set_wavelength!(mono, target_wl)
            @test abs(wl - target_wl) < 1.0
        end

        disconnect!(mono)
    end
end

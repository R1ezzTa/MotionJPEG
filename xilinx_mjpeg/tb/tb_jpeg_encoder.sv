`timescale 1ns / 1ps
module tb_jpeg_encoder #(
    parameter WRAPPER = 0,
    QUICK = 0,
    INJECT_ERRORS = 0
);
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0;
    reg [15:0] cfg_width = 8, cfg_height = 8;
    reg cfg_gray = 1;
    reg cfg_q_valid = 0;
    wire cfg_q_ready;
    reg [6:0] cfg_q_addr = 0;
    reg [7:0] cfg_q_value = 0;
    reg [20:0] cfg_q_recip = 0;
    wire tables_ready;
    reg [15:0] s_data = 0;
    reg s_valid = 0, s_sof = 0, s_eol = 0, s_eof = 0;
    wire s_ready;
    wire [127:0] m_data;
    wire [4:0] m_bytes;
    wire m_valid, m_last, busy, protocol_error, config_error, coefficient_error;
    reg m_ready = 0;
    generate
        if (!WRAPPER) begin : wide_core
            jpeg_encoder dut (.*);
        end else begin : narrow_core
            wire [31:0] narrow_data;
            wire [2:0] narrow_bytes;
            assign m_data = {96'd0, narrow_data};
            assign m_bytes = {2'd0, narrow_bytes};
            jpeg_synth_top dut (
                .clk              (clk),
                .rst_n            (rst_n),
                .cfg_width        (cfg_width),
                .cfg_height       (cfg_height),
                .cfg_gray         (cfg_gray),
                .cfg_q_valid      (cfg_q_valid),
                .cfg_q_ready      (cfg_q_ready),
                .cfg_q_addr       (cfg_q_addr),
                .cfg_q_value      (cfg_q_value),
                .cfg_q_recip      (cfg_q_recip),
                .tables_ready     (tables_ready),
                .s_data           (s_data),
                .s_valid          (s_valid),
                .s_ready          (s_ready),
                .s_sof            (s_sof),
                .s_eol            (s_eol),
                .s_eof            (s_eof),
                .m_data           (narrow_data),
                .m_bytes          (narrow_bytes),
                .m_valid          (m_valid),
                .m_ready          (m_ready),
                .m_last           (m_last),
                .busy             (busy),
                .protocol_error   (protocol_error),
                .config_error     (config_error),
                .coefficient_error(coefficient_error)
            );
        end
    endgenerate
    reg [15:0] pixels[0:2073599];
    reg [7:0] expected[0:4194303];
    reg [28:0] quant_config[0:127];
    integer
        cases,
        code,
        w,
        h,
        gray,
        nbytes,
        p,
        i,
        j,
        seen,
        cycles = 0,
        start_cycle,
        stall_cycles,
        report_file,
        actual_file;
    string name, path;
    reg checking = 0, done = 0, random_ready = 1;
    reg [31:0] lfsr = 32'h1234abcd;
    reg expected_protocol = 0, inject_marker = 0;
    reg held = 0;
    reg [127:0] held_data;
    reg [4:0] held_bytes;
    reg held_last;
    always @(negedge clk) begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        m_ready = rst_n && (random_ready ? (lfsr[2:0] != 0) : 1);
        if (INJECT_ERRORS && random_ready && cycles % 2000 >= 1000 && cycles % 2000 < 1100)
            m_ready = 0;
    end
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 20000000) $fatal(1, "WATCHDOG");
        if (rst_n) begin
            if (held && (!m_valid || m_data !== held_data || m_bytes !== held_bytes ||
                         m_last !== held_last))
                $fatal(1, "Output changed while stalled");
            held = m_valid && !m_ready;
            held_data = m_data;
            held_bytes = m_bytes;
            held_last = m_last;
            if (checking && m_valid && m_ready) begin
                if (m_bytes == 0 || m_bytes > 16) $fatal(1, "Invalid byte count");
                for (j = 0; j < m_bytes; j = j + 1) begin
                    if (seen >= nbytes || m_data[j*8+:8] !== expected[seen])
                        $fatal(
                            1,
                            "%s byte %0d got %02x expected %02x",
                            name,
                            seen,
                            m_data[j*8+:8],
                            expected[seen]
                        );
                    $fwrite(actual_file, "%c", m_data[j*8+:8]);
                    seen = seen + 1;
                end
                if (m_last) begin
                    if (seen != nbytes) $fatal(1, "Premature frame end");
                    if (protocol_error !== expected_protocol || config_error || coefficient_error)
                        $fatal(1, "Unexpected error flag");
                    done = 1;
                end
            end
        end else held = 0;
    end
    task load_quant;
        begin
            for (i = 0; i < 128; i = i + 1) begin
                @(negedge clk);
                cfg_q_valid = 1;
                cfg_q_addr = i;
                cfg_q_value = quant_config[i][7:0];
                cfg_q_recip = quant_config[i][28:8];
                @(posedge clk);
                if (!cfg_q_ready) $fatal(1, "Table not ready while idle");
            end
            @(negedge clk);
            cfg_q_valid = 0;
            repeat (3) @(negedge clk);
            if (!tables_ready) $fatal(1, "Table loading failed");
        end
    endtask
    task send_frame;
        begin
            stall_cycles = 0;
            start_cycle = cycles;
            for (p = 0; p < w * h; p = p + 1) begin
                @(negedge clk);
                if (name != "fhd" && lfsr[3:0] == 0) begin
                    s_valid = 0;
                    @(negedge clk);
                end
                s_valid = 1;
                s_data = pixels[p];
                s_sof = p == 0;
                s_eol = p % w == w - 1;
                s_eof = p == w * h - 1;
                if (inject_marker && p == 5) s_eol = 1;
                if (INJECT_ERRORS && p == 20) begin
                    cfg_q_valid = 1;
                    cfg_q_addr = 0;
                    cfg_q_value = 255;
                    cfg_q_recip = 4113;
                end
                if (INJECT_ERRORS && p == 30) cfg_q_valid = 0;
                // Configuration is latched at SOF; changes during a frame must not
                // alter pixel counting, sampling or the dimensions in the JPEG header.
                if (INJECT_ERRORS && p == 100) begin
                    cfg_width = 1936;
                    cfg_height = 9;
                    cfg_gray = !gray;
                end
                if (INJECT_ERRORS && p == 200) begin
                    cfg_width = w;
                    cfg_height = h;
                    cfg_gray = gray;
                end
                @(posedge clk);
                while (!s_ready) begin
                    stall_cycles = stall_cycles + 1;
                    @(posedge clk);
                end
                if (p == 20) begin
                    if (cfg_q_ready) $fatal(1, "Quant table writable in frame");
                end
            end
            @(negedge clk);
            s_valid = 0;
            s_sof = 0;
            s_eol = 0;
            s_eof = 0;
            cfg_q_valid = 0;
        end
    endtask
    initial begin
        report_file = $fopen("simulation_results.csv", "w");
        $fwrite(report_file, "case,width,height,bytes,cycles,input_stall_cycles\n");
        cases = $fopen("data/cases.txt", "r");
        if (!cases) $fatal(1, "Missing cases");
        repeat (5) @(negedge clk);
        rst_n = 1;
        // Invalid dimensions and absent tables must reject input.
        cfg_width = 9;
        s_valid = 1;
        s_sof = 1;
        repeat (3) @(posedge clk);
        if (s_ready) $fatal(1, "Invalid configuration accepted");
        @(negedge clk);
        s_valid = 0;
        s_sof = 0;
        while (!$feof(
            cases
        )) begin
            code = $fscanf(cases, "%s %d %d %d %d\n", name, w, h, gray, nbytes);
            if (code == 5 && (QUICK == 0 || name != "fhd") &&
                (QUICK < 2 || (name != "wide" && name != "tall"))) begin
                path = $sformatf("data/%s/pixels.mem", name);
                $readmemh(path, pixels, 0, w * h - 1);
                path = $sformatf("data/%s/expected.mem", name);
                $readmemh(path, expected, 0, nbytes - 1);
                path = $sformatf("data/%s/quant.mem", name);
                $readmemh(path, quant_config);
                cfg_width = w;
                cfg_height = h;
                cfg_gray = gray;
                random_ready = name != "fhd";
                load_quant();
                seen = 0;
                done = 0;
                checking = 1;
                path = $sformatf("%s_rtl.jpg", name);
                actual_file = $fopen(path, "wb");
                send_frame();
                wait (done);
                @(negedge clk);
                checking = 0;
                $fclose(actual_file);
                if (busy) $fatal(1, "Busy not released after EOI");
                $display("CASE_PASS %s bytes=%0d cycles=%0d stalls=%0d", name, seen,
                         cycles - start_cycle, stall_cycles);
                $fwrite(report_file, "%s,%0d,%0d,%0d,%0d,%0d\n", name, w, h, seen,
                        cycles - start_cycle, stall_cycles);
                if (name == "fhd" && (cycles - start_cycle) > 3333333)
                    $fatal(1, "FHD input throughput below 60 fps at 200 MHz");
                repeat (4) @(negedge clk);
            end
        end
        // Reset during a partial frame; subsequent complete JPEG must match again.
        name = "gray_ramp";
        w = 16;
        h = 16;
        gray = 1;
        nbytes = 622;
        cfg_width = w;
        cfg_height = h;
        cfg_gray = 1;
        random_ready = 1;
        $readmemh("data/gray_ramp/pixels.mem", pixels, 0, 255);
        $readmemh("data/gray_ramp/expected.mem", expected, 0, 621);
        $readmemh("data/gray_ramp/quant.mem", quant_config);
        load_quant();
        for (p = 0; p < 20; p = p + 1) begin
            @(negedge clk);
            s_valid = 1;
            s_data = pixels[p];
            s_sof = p == 0;
            s_eol = p % 16 == 15;
            s_eof = 0;
            @(posedge clk);
            while (!s_ready) @(posedge clk);
        end
        @(negedge clk);
        rst_n = 0;
        s_valid = 0;
        s_sof = 0;
        s_eol = 0;
        checking = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        load_quant();
        actual_file = $fopen("reset_recovery_rtl.jpg", "wb");
        seen = 0;
        done = 0;
        checking = 1;
        send_frame();
        wait (done);
        @(negedge clk);
        checking = 0;
        $fclose(actual_file);
        $display("RESET_RECOVERY_PASS");
        if (INJECT_ERRORS) begin
            inject_marker = 1;
            expected_protocol = 1;
            seen = 0;
            done = 0;
            checking = 1;
            actual_file = $fopen("bad_marker_rtl.jpg", "wb");
            send_frame();
            wait (done);
            @(negedge clk);
            checking = 0;
            $fclose(actual_file);
            inject_marker = 0;
            expected_protocol = 0;
            seen = 0;
            done = 0;
            checking = 1;
            actual_file = $fopen("marker_recovery_rtl.jpg", "wb");
            send_frame();
            wait (done);
            @(negedge clk);
            checking = 0;
            $fclose(actual_file);
            $display("PROTOCOL_AND_CONFIG_LOCK_PASS");
        end
        $fclose(report_file);
        $fclose(cases);
        report_file = $fopen("SIM_PASS.txt", "w");
        $fwrite(report_file,
                "All byte comparisons, stalls, continuous frames and reset recovery passed.\n");
        $fclose(report_file);
        $display("ALL_TESTS_PASS");
        $finish;
    end
endmodule

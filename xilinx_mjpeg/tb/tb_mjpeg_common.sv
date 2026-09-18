`timescale 1ns / 1ps
// Test the public transport boundary, not internal JPEG state. Each channel
// is reconstructed independently and compared byte-for-byte with our CPU model.
module tb_mjpeg_common #(
    parameter CHANNELS = 2,
    BOARD = 0,
    FHD = 0,
    WIDE = 0,
    CAPTURE = 0
);
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0;
    reg [CHANNELS*16-1:0] s_data = 0;
    reg [CHANNELS-1:0] s_valid = 0, s_sof = 0, s_eol = 0, s_eof = 0, s_abort = 0;
    wire [CHANNELS-1:0] s_ready, busy, tables_ready, config_error;
    reg [CHANNELS-1:0] enable = 0, cfg_gray = 0, cfg_q_valid = 0;
    reg [CHANNELS*16-1:0] cfg_width = 0, cfg_height = 0;
    reg [CHANNELS*7-1:0] cfg_q_addr = 0;
    reg [CHANNELS*8-1:0] cfg_q_value = 0;
    reg [CHANNELS*21-1:0] cfg_q_recip = 0;
    reg [CHANNELS*64-1:0] s_timestamp = 0;
    reg [2:0] cfg_cmd = 0;
    reg [1:0] cfg_channel = 0;
    reg [31:0] cfg_data = 0;
    reg cfg_valid = 0;
    wire cfg_ready;
    wire [31:0] m_data;
    wire [2:0] m_bytes;
    wire m_valid, m_packet_last;
    reg m_ready = 0, random_ready = 1, force_stall = 0;
    generate
        if (BOARD) begin : board
            mjpeg_synth_top dut (
                .clk          (clk),
                .rst_n        (rst_n),
                .cfg_cmd      (cfg_cmd),
                .cfg_channel  (cfg_channel),
                .cfg_data     (cfg_data),
                .cfg_valid    (cfg_valid),
                .cfg_ready    (cfg_ready),
                .s_data       (s_data),
                .s_valid      (s_valid),
                .s_ready      (s_ready),
                .s_sof        (s_sof),
                .s_eol        (s_eol),
                .s_eof        (s_eof),
                .s_abort      (s_abort),
                .m_data       (m_data),
                .m_bytes      (m_bytes),
                .m_valid      (m_valid),
                .m_ready      (m_ready),
                .m_packet_last(m_packet_last),
                .busy         (busy),
                .tables_ready (tables_ready),
                .config_error (config_error)
            );
        end else begin : ip
            wire [CHANNELS-1:0] cfg_q_ready;
            wire [127:0] payload;
            wire [4:0] payload_bytes;
            wire payload_first, payload_last, payload_valid, payload_ready;
            wire [1:0] payload_channel, desc_channel;
            wire [31:0] payload_id, desc_frame_id, desc_length;
            wire desc_valid, desc_ready, desc_gray;
            wire [63:0] desc_timestamp;
            wire [15:0] desc_width, desc_height;
            wire [7:0] desc_status;
            mjpeg_encoder #(
                .CHANNELS(CHANNELS)
            ) dut (
                .clk           (clk),
                .rst_n         (rst_n),
                .enable        (enable),
                .cfg_gray      (cfg_gray),
                .cfg_width     (cfg_width),
                .cfg_height    (cfg_height),
                .cfg_q_valid   (cfg_q_valid),
                .cfg_q_ready   (cfg_q_ready),
                .cfg_q_addr    (cfg_q_addr),
                .cfg_q_value   (cfg_q_value),
                .cfg_q_recip   (cfg_q_recip),
                .tables_ready  (tables_ready),
                .config_error  (config_error),
                .busy          (busy),
                .s_data        (s_data),
                .s_valid       (s_valid),
                .s_ready       (s_ready),
                .s_sof         (s_sof),
                .s_eol         (s_eol),
                .s_eof         (s_eof),
                .s_abort       (s_abort),
                .s_timestamp   (s_timestamp),
                .m_data        (payload),
                .m_bytes       (payload_bytes),
                .m_first       (payload_first),
                .m_last        (payload_last),
                .m_valid       (payload_valid),
                .m_ready       (payload_ready),
                .m_channel     (payload_channel),
                .m_frame_id    (payload_id),
                .desc_valid    (desc_valid),
                .desc_ready    (desc_ready),
                .desc_channel  (desc_channel),
                .desc_frame_id (desc_frame_id),
                .desc_length   (desc_length),
                .desc_timestamp(desc_timestamp),
                .desc_width    (desc_width),
                .desc_height   (desc_height),
                .desc_gray     (desc_gray),
                .desc_status   (desc_status)
            );
            mjpeg_packetizer packetizer (
                .clk           (clk),
                .rst_n         (rst_n),
                .s_data        (payload),
                .s_bytes       (payload_bytes),
                .s_first       (payload_first),
                .s_last        (payload_last),
                .s_valid       (payload_valid),
                .s_ready       (payload_ready),
                .s_channel     (payload_channel),
                .s_frame_id    (payload_id),
                .desc_valid    (desc_valid),
                .desc_ready    (desc_ready),
                .desc_channel  (desc_channel),
                .desc_frame_id (desc_frame_id),
                .desc_length   (desc_length),
                .desc_timestamp(desc_timestamp),
                .desc_width    (desc_width),
                .desc_height   (desc_height),
                .desc_gray     (desc_gray),
                .desc_status   (desc_status),
                .m_data        (m_data),
                .m_bytes       (m_bytes),
                .m_valid       (m_valid),
                .m_ready       (m_ready),
                .m_packet_last (m_packet_last)
            );
        end
    endgenerate
    reg [15:0] pixels[0:(FHD?2073599 : (WIDE?32767 : 2047))];
    reg [7:0] expected[0:(FHD?1048575 : 8191)];
    reg [28:0] quant[0:127];
    integer cycles = 0, w, h, gray, nbytes, round_no = 0, report_file, c, j;
    integer capture_file = 0;
    string name;
    integer seen[0:CHANNELS-1], next_id[0:CHANNELS-1], expected_id[0:CHANNELS-1];
    integer start_cycle[0:CHANNELS-1], file_handle[0:CHANNELS-1];
    reg completed[0:CHANNELS-1], ended[0:CHANNELS-1], opened[0:CHANNELS-1];
    reg [7:0] expected_status[0:CHANNELS-1];
    reg [63:0] expected_ts[0:CHANNELS-1];
    reg [63:0] reference_ticks = 0;
    reg [31:0] lfsr = 32'h8c73e051;
    integer
        packet_index = 0, packet_channel = 0, packet_bytes = 0, packet_type = 0, packet_words = 0;
    reg packet_first, packet_last, packet_abort;
    reg [31:0] words[0:6];
    reg held = 0, check_packets = 1;
    reg [31:0] held_data;
    reg [2:0] held_bytes;
    reg held_last;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reference_ticks <= 0;
        else reference_ticks <= reference_ticks + 1'b1;
    end
    always @(negedge clk) begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        m_ready = rst_n && !force_stall &&
            (!random_ready || (lfsr[2:0] != 0 && !(cycles % 1700 >= 900 && cycles % 1700 < 1000)));
    end
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 18000000) $fatal(1, "WATCHDOG");
        if (!rst_n) begin
            held = 0;
            packet_index = 0;
        end else begin
            if (held && (!m_valid || m_data !== held_data || m_bytes !== held_bytes ||
                         m_packet_last !== held_last))
                $fatal(1, "Transport changed under backpressure");
            held = m_valid && !m_ready;
            held_data = m_data;
            held_bytes = m_bytes;
            held_last = m_packet_last;
            if (m_valid && m_ready && check_packets) begin
                if (CAPTURE)
                    $fwrite(capture_file, "%08x,%0d,%0d\n", m_data, m_bytes, m_packet_last);
                words[packet_index] = m_data;
                if (packet_index == 0) begin
                    if (m_data[31:16] != 16'h4d4a || m_data[15:12] != 1) $fatal(1, "Bad header");
                    packet_type = m_data[11:10];
                    packet_channel = m_data[9:8];
                    packet_bytes = m_data[4:0];
                    packet_first = m_data[7];
                    packet_last = m_data[6];
                    packet_abort = m_data[5];
                    if (packet_channel >= CHANNELS || packet_type > 1 || packet_bytes > 16)
                        $fatal(1, "Invalid packet tag");
                    if (packet_type == 0) begin
                        packet_words = 2 + (packet_bytes + 3) / 4;
                        if (packet_abort !== (packet_bytes == 0) ||
                            packet_bytes == 0 && !packet_last)
                            $fatal(1, "Invalid abort token");
                        if (packet_first !== !opened[packet_channel] || ended[packet_channel])
                            $fatal(1, "SOI/EOI sequence");
                        opened[packet_channel] = 1;
                    end else begin
                        packet_words = 7;
                        if (packet_first || packet_last || packet_abort || packet_bytes)
                            $fatal(1, "Descriptor header flags");
                    end
                end
                if (packet_index == 1 && m_data !== expected_id[packet_channel])
                    $fatal(
                        1,
                        "Frame ID ch%0d got%0d expected%0d",
                        packet_channel,
                        m_data,
                        expected_id[packet_channel]
                    );
                if (packet_type == 0 && packet_index >= 2) begin
                    if (m_bytes !== ((packet_bytes - (packet_index - 2) * 4) >= 4 ? 4 :
                                     packet_bytes - (packet_index - 2) * 4))
                        $fatal(1, "Partial word length");
                    for (j = 0; j < m_bytes; j = j + 1) begin
                        if (seen[packet_channel] >= nbytes ||
                            m_data[j*8+:8] !== expected[seen[packet_channel]])
                            $fatal(
                                1,
                                "%s ch%0d frame%0d byte%0d got%02x expected%02x",
                                name,
                                packet_channel,
                                expected_id[packet_channel],
                                seen[packet_channel],
                                m_data[j*8+:8],
                                expected[seen[packet_channel]]
                            );
                        if (file_handle[packet_channel])
                            $fwrite(file_handle[packet_channel], "%c", m_data[j*8+:8]);
                        seen[packet_channel] = seen[packet_channel] + 1;
                    end
                end else if (m_bytes !== 4) $fatal(1, "Header/descriptor byte count");
                if (m_packet_last !== (packet_index == packet_words - 1))
                    $fatal(1, "Packet boundary");
                if (m_packet_last) begin
                    if (packet_type == 0 && packet_last) begin
                        ended[packet_channel] = 1;
                        if (!expected_status[packet_channel][0] &&
                            (packet_abort || seen[packet_channel] != nbytes))
                            $fatal(1, "Incomplete normal JPEG");
                        if (expected_status[packet_channel][0] && !packet_abort)
                            $fatal(1, "Missing abort marker");
                    end
                    if (packet_type == 1) begin
                        if (!ended[packet_channel] || completed[packet_channel])
                            $fatal(1, "Descriptor before EOI or duplicated");
                        if ({words[3], words[2]} !== expected_ts[packet_channel] ||
                            words[4] !== seen[packet_channel] || words[5] !== {16'(h), 16'(w)} ||
                            words[6] !== {23'd0, 1'(gray), expected_status[packet_channel]})
                            $fatal(
                                1,
                                "Descriptor mismatch ch%0d time=%h/%h len=%0d/%0d dimensions=%h status=%h"
                                    ,
                                packet_channel,
                                {
                                    words[3], words[2]
                                },
                                expected_ts[packet_channel],
                                words[4],
                                seen[packet_channel],
                                words[5],
                                words[6]
                            );
                        completed[packet_channel] = 1;
                        $display("FRAME_PASS %s ch=%0d id=%0d bytes=%0d cycles=%0d status=%02x",
                                 name, packet_channel, expected_id[packet_channel],
                                 seen[packet_channel], cycles - start_cycle[packet_channel],
                                 expected_status[packet_channel]);
                        $fwrite(report_file, "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n", name,
                                packet_channel, expected_id[packet_channel], w, h,
                                seen[packet_channel], cycles - start_cycle[packet_channel],
                                expected_status[packet_channel]);
                        if (FHD && cycles - start_cycle[packet_channel] > 3333333)
                            $fatal(1, "Dual FHD60 deadline missed");
                    end
                    packet_index = 0;
                end else packet_index = packet_index + 1;
            end
        end
    end
    task automatic command(input integer ch, cmd, input reg [31:0] value);
        begin
            @(negedge clk);
            cfg_valid = 1;
            cfg_channel = ch;
            cfg_cmd = cmd;
            cfg_data = value;
            @(posedge clk);
            while (!cfg_ready) @(posedge clk);
            @(negedge clk);
            cfg_valid = 0;
        end
    endtask
    task configure;
        integer k, ch;
        begin
            for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                wait (!busy[ch]);
                if (BOARD) begin
                    command(ch, 0, {16'(h), 16'(w)});
                    command(ch, 1, {30'd0, 1'(gray), 1'b1});
                end else begin
                    @(negedge clk);
                    cfg_width[ch*16+:16] = w;
                    cfg_height[ch*16+:16] = h;
                    cfg_gray[ch] = gray;
                    enable[ch] = 1;
                end
                for (k = 0; k < 128; k = k + 1) begin
                    if (BOARD) begin
                        command(ch, 2, {17'd0, quant[k][7:0], 7'(k)});
                        command(ch, 3, {11'd0, quant[k][28:8]});
                    end else begin
                        @(negedge clk);
                        cfg_q_valid[ch] = 1;
                        cfg_q_addr[ch*7+:7] = k;
                        cfg_q_value[ch*8+:8] = quant[k][7:0];
                        cfg_q_recip[ch*21+:21] = quant[k][28:8];
                        @(posedge clk);
                    end
                end
                @(negedge clk);
                cfg_q_valid[ch] = 0;
                repeat (3) @(negedge clk);
                if (!tables_ready[ch] || config_error[ch]) $fatal(1, "Table load");
            end
        end
    endtask
    task fixture(input string fixture_name, input integer width, height, mode, byte_count);
        begin
            name = fixture_name;
            w = width;
            h = height;
            gray = mode;
            nbytes = byte_count;
            $readmemh($sformatf("data/%s/pixels.mem", name), pixels, 0, w * h - 1);
            $readmemh($sformatf("data/%s/expected.mem", name), expected, 0, nbytes - 1);
            $readmemh($sformatf("data/%s/quant.mem", name), quant);
            configure();
        end
    endtask
    task automatic send(input integer ch, status, abort_after);
        integer p, limit;
        begin
            wait (!busy[ch] && tables_ready[ch]);
            seen[ch] = 0;
            opened[ch] = 0;
            ended[ch] = 0;
            completed[ch] = 0;
            expected_status[ch] = status;
            expected_id[ch] = next_id[ch];
            next_id[ch] = next_id[ch] + 1;
            expected_ts[ch] = 64'h1234567800000000 + expected_id[ch] * 16 + ch;
            if (status == 0)
                file_handle[ch] = $fopen(
                    $sformatf("%s_ch%0d_f%0d_rtl.jpg", name, ch, expected_id[ch]), "wb"
                );
            else file_handle[ch] = 0;
            limit = abort_after ? abort_after : w * h;
            for (p = 0; p < limit; p = p + 1) begin
                @(negedge clk);
                s_valid[ch] = 1;
                s_data[ch*16+:16] = pixels[p];
                s_sof[ch] = p == 0;
                s_eol[ch] = p % w == w - 1;
                s_eof[ch] = p == w * h - 1;
                if (status == 2 && p == 5) s_eol[ch] = 1;
                s_timestamp[ch*64+:64] = expected_ts[ch];
                @(posedge clk);
                while (!s_ready[ch]) @(posedge clk);
                if (p == 0) begin
                    start_cycle[ch] = cycles;
                    if (BOARD) expected_ts[ch] = reference_ticks;
                end
            end
            @(negedge clk);
            s_valid[ch] = 0;
            s_sof[ch] = 0;
            s_eol[ch] = 0;
            s_eof[ch] = 0;
            if (abort_after) begin
                s_abort[ch] = 1;
                @(negedge clk);
                s_abort[ch] = 0;
            end
            wait (completed[ch]);
            @(negedge clk);
            if (file_handle[ch]) begin
                $fclose(file_handle[ch]);
                file_handle[ch] = 0;
            end
        end
    endtask
    task all_channels;
        begin
            fork
                send(0, 0, 0);
                send(1, 0, 0);
                begin
                    if (CHANNELS > 2) send(2, 0, 0);
                end
                begin
                    if (CHANNELS > 3) send(3, 0, 0);
                end
            join
        end
    endtask
    initial begin
        report_file = $fopen("mjpeg_results.csv", "w");
        $fwrite(report_file, "case,channel,frame_id,width,height,bytes,cycles,status\n");
        if (CAPTURE) begin
            capture_file = $fopen("transport_words.csv", "w");
            $fwrite(capture_file, "data,bytes,last\n");
        end
        for (c = 0; c < CHANNELS; c = c + 1) begin
            next_id[c] = 0;
            file_handle[c] = 0;
            completed[c] = 0;
            opened[c] = 0;
            ended[c] = 0;
        end
        repeat (5) @(negedge clk);
        rst_n = 1;
        if (FHD || WIDE) begin
            random_ready = 0;
            if (WIDE) fixture("wide", 1920, 16, 0, 6878);
            else fixture("fhd", 1920, 1080, 0, 516557);
            all_channels();
            all_channels();
            all_channels();
        end else begin
            fixture("gray_ramp", 16, 16, 1, 622);
            if (BOARD) begin
                // A valid command can wait through an active frame without stopping it.
                fork
                    begin
                        wait (busy[0]);
                        command(0, 0, {16'(h), 16'(w)});
                    end
                    all_channels();
                join
                // An invalid channel must not block either pixel lane.
                @(negedge clk);
                cfg_valid = 1;
                cfg_channel = 3;
                cfg_cmd = 0;
                @(posedge clk);
                if (cfg_ready) $fatal(1, "Invalid config channel accepted");
                all_channels();
                @(negedge clk);
                cfg_valid = 0;
            end
            repeat (6) all_channels();
            // One stream aborts while the other continues; no software table reload.
            fork
                send(0, 1, 1);
                send(1, 0, 0);
            join
            all_channels();
            fork
                send(0, 1, 200);
                send(1, 2, 0);
            join
            all_channels();
            // Long downstream pause must retain data and postpone new-frame admission.
            fork
                begin
                    force_stall = 1;
                    repeat (2000) @(negedge clk);
                    force_stall = 0;
                end
                all_channels();
            join
            fixture("color_noise", 32, 24, 0, 1752);
            repeat (3) all_channels();
            fixture("color_flat", 16, 8, 0, 615);
            all_channels();
            // Global reset flushes partial transport packets and requires tables again.
            // A bus-capture file covers one reset epoch; C resets its receiver at reset.
            if (!CAPTURE) begin
                @(negedge clk);
                check_packets = 0;
                s_valid = '1;
                s_sof = '1;
                s_data = 0;
                repeat (10) @(negedge clk);
                rst_n = 0;
                s_valid = 0;
                s_sof = 0;
                repeat (4) @(negedge clk);
                for (c = 0; c < CHANNELS; c = c + 1) begin
                    next_id[c] = 0;
                    opened[c] = 0;
                    ended[c] = 0;
                    completed[c] = 0;
                end
                rst_n = 1;
                @(negedge clk);
                if (tables_ready) $fatal(1, "Tables survived global reset");
                fixture("gray_ramp", 16, 16, 1, 622);
                check_packets = 1;
                all_channels();
            end
        end
        repeat (20) @(negedge clk);
        if (busy || m_valid) $fatal(1, "Residual busy/output");
        $fclose(report_file);
        report_file = $fopen("SIM_PASS.txt", "w");
        $fwrite(report_file,
                "Continuous MJPEG, packet reassembly, byte comparisons and recovery passed.\n");
        $fclose(report_file);
        if (CAPTURE) $fclose(capture_file);
        $display("MJPEG_ALL_PASS CHANNELS=%0d BOARD=%0d FHD=%0d", CHANNELS, BOARD, FHD);
        $finish;
    end
endmodule

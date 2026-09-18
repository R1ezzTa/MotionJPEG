`timescale 1ns / 1ps
module tb_mjpeg_mixed;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0;
    reg [1:0] enable = 3, cfg_gray = 1, cfg_q_valid = 0;
    reg [31:0] cfg_width = {16'd32, 16'd32}, cfg_height = {16'd24, 16'd24};
    reg [13:0] cfg_q_addr = 0;
    reg [15:0] cfg_q_value = 0;
    reg [41:0] cfg_q_recip = 0;
    wire [1:0] cfg_q_ready, tables_ready, config_error, busy;
    reg [31:0] s_data = 0;
    reg [1:0] s_valid = 0, s_sof = 0, s_eol = 0, s_eof = 0, s_abort = 0;
    wire [1:0] s_ready;
    reg [127:0] s_timestamp = 0;
    wire [127:0] m_data;
    wire [4:0] m_bytes;
    wire m_first, m_last, m_valid;
    reg m_ready = 0;
    wire [1:0] m_channel, desc_channel;
    wire [31:0] m_frame_id, desc_frame_id, desc_length;
    wire [63:0] desc_timestamp;
    wire [15:0] desc_width, desc_height;
    wire desc_gray;
    wire [7:0] desc_status;
    wire desc_valid;
    reg desc_ready = 1;
    mjpeg_encoder dut (.*);
    reg [15:0] pixels[0:2047];
    reg [7:0] expected[0:8191];
    reg [28:0] quant[0:255];
    integer cycles = 0, c, k, j, ch, length, report_file;
    integer seen[0:1], ended[0:1], described[0:1], out_file[0:1], start_cycle[0:5];
    string fixture_name[0:1];
    reg [31:0] lfsr = 32'h9863712a;
    reg held = 0;
    reg [168:0] held_payload;
    wire [168:0] payload = {m_channel, m_frame_id, m_first, m_last, m_bytes, m_data};
    always @(negedge clk) begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        m_ready = rst_n && lfsr[1:0] != 0;
    end
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 100000) $fatal(1, "Mixed watchdog");
        if (rst_n) begin
            if (held && (!m_valid || payload !== held_payload)) $fatal(1, "Mixed payload stall");
            held = m_valid && !m_ready;
            held_payload = payload;
            if (m_valid && m_ready) begin
                ch = m_channel;
                length = ch == 0 ? 1820 : 1752;
                if (ch > 1 || m_frame_id != ended[ch] || m_first !== (seen[ch] == 0) ||
                    m_bytes == 0 || m_bytes > 16)
                    $fatal(1, "Mixed tags");
                if (seen[ch] == 0)
                    out_file[ch] = $fopen(
                        $sformatf("%s_ch%0d_f%0d_rtl.jpg", fixture_name[ch], ch, ended[ch]), "wb"
                    );
                for (j = 0; j < m_bytes; j = j + 1) begin
                    if (seen[ch] >= length || m_data[j*8+:8] !== expected[ch*4096+seen[ch]])
                        $fatal(1, "Mixed byte ch%0d at%0d", ch, seen[ch]);
                    $fwrite(out_file[ch], "%c", m_data[j*8+:8]);
                    seen[ch] = seen[ch] + 1;
                end
                if (m_last) begin
                    if (seen[ch] != length) $fatal(1, "Mixed length");
                    $fclose(out_file[ch]);
                    seen[ch] = 0;
                    ended[ch] = ended[ch] + 1;
                end
            end
            if (desc_valid && desc_ready) begin
                ch = desc_channel;
                length = ch == 0 ? 1820 : 1752;
                if (ch > 1 || desc_frame_id != described[ch] || described[ch] >= ended[ch] ||
                    desc_width != 32 || desc_height != 24 || desc_gray !== (ch == 0) ||
                    desc_status || desc_length != length ||
                    desc_timestamp !== 64'h1234987600000000 + described[ch] * 16 + ch)
                    $fatal(1, "Mixed descriptor");
                $fwrite(report_file, "%s,%0d,%0d,32,24,%0d,%0d,0\n", fixture_name[ch], ch,
                        described[ch], length, cycles - start_cycle[ch*3+described[ch]]);
                described[ch] = described[ch] + 1;
            end
        end
    end
    task automatic send(input integer lane);
        integer f, p;
        begin
            for (f = 0; f < 3; f = f + 1) begin
                wait (!busy[lane]);
                start_cycle[lane*3+f] = cycles;
                for (p = 0; p < 768; p = p + 1) begin
                    @(negedge clk);
                    s_valid[lane] = 1;
                    s_data[lane*16+:16] = pixels[lane*1024+p];
                    s_sof[lane] = p == 0;
                    s_eol[lane] = p % 32 == 31;
                    s_eof[lane] = p == 767;
                    s_timestamp[lane*64+:64] = 64'h1234987600000000 + f * 16 + lane;
                    @(posedge clk);
                    while (!s_ready[lane]) @(posedge clk);
                end
                @(negedge clk);
                s_valid[lane] = 0;
                s_sof[lane] = 0;
                s_eol[lane] = 0;
                s_eof[lane] = 0;
            end
        end
    endtask
    initial begin
        fixture_name[0] = "gray_noise";
        fixture_name[1] = "color_noise";
        $readmemh("data/gray_noise/pixels.mem", pixels, 0, 767);
        $readmemh("data/color_noise/pixels.mem", pixels, 1024, 1791);
        $readmemh("data/gray_noise/expected.mem", expected, 0, 1819);
        $readmemh("data/color_noise/expected.mem", expected, 4096, 5847);
        $readmemh("data/gray_noise/quant.mem", quant, 0, 127);
        $readmemh("data/color_noise/quant.mem", quant, 128, 255);
        for (c = 0; c < 2; c = c + 1) begin
            seen[c] = 0;
            ended[c] = 0;
            described[c] = 0;
        end
        report_file = $fopen("mjpeg_results.csv", "w");
        $fwrite(report_file, "case,channel,frame_id,width,height,bytes,cycles,status\n");
        repeat (5) @(negedge clk);
        rst_n = 1;
        for (c = 0; c < 2; c = c + 1)
        for (k = 0; k < 128; k = k + 1) begin
            @(negedge clk);
            cfg_q_valid = 1 << c;
            cfg_q_addr[c*7+:7] = k;
            cfg_q_value[c*8+:8] = quant[c*128+k][7:0];
            cfg_q_recip[c*21+:21] = quant[c*128+k][28:8];
            @(posedge clk);
            if (!cfg_q_ready[c]) $fatal(1, "Mixed table handshake");
        end
        @(negedge clk);
        cfg_q_valid = 0;
        repeat (3) @(negedge clk);
        if (tables_ready != 3) $fatal(1, "Mixed table load");
        fork
            send(0);
            send(1);
        join
        wait (described[0] == 3 && described[1] == 3);
        repeat (10) @(negedge clk);
        if (busy || config_error || m_valid || desc_valid) $fatal(1, "Mixed drain");
        $fclose(report_file);
        report_file = $fopen("SIM_PASS.txt", "w");
        $fwrite(
            report_file,
            "Independent gray_noise and color_noise channels, three frames per channel, byte comparisons, tags, timestamps and stalls passed.\n"
                );
        $fclose(report_file);
        $display("MJPEG_MIXED_CHANNEL_PASS");
        $finish;
    end
endmodule

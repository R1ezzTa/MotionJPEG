`timescale 1ns / 1ps
module tb_mjpeg_packetizer;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0, s_valid = 0, desc_valid = 0, m_ready = 0;
    reg [127:0] s_data = 0;
    reg [4:0] s_bytes = 0;
    reg s_first = 0, s_last = 0;
    reg [1:0] s_channel = 0, desc_channel = 0;
    reg [31:0] s_frame_id = 0, desc_frame_id = 0, desc_length = 0;
    reg [63:0] desc_timestamp = 0;
    reg [15:0] desc_width = 0, desc_height = 0;
    reg desc_gray = 0;
    reg [7:0] desc_status = 0;
    wire s_ready, desc_ready, m_valid, m_packet_last;
    wire [31:0] m_data;
    wire [2:0] m_bytes;
    mjpeg_packetizer dut (.*);
    reg [31:0] expected_data[0:19999];
    reg [2:0] expected_bytes[0:19999];
    reg expected_last[0:19999];
    integer
        queued = 0, seen = 0, payloads = 0, descriptors = 0, cycles = 0, k, remaining, file_handle;
    reg [31:0] lfsr = 32'h3731ab91, held_data;
    reg [2:0] held_bytes;
    reg held_last, held = 0;
    task add(input reg [31:0] data, input integer bytes, input reg last);
        begin
            expected_data[queued] = data;
            expected_bytes[queued] = bytes;
            expected_last[queued] = last;
            queued = queued + 1;
        end
    endtask
    always @(negedge clk) begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        m_ready = rst_n && lfsr[1:0] != 0 && !(cycles % 300 >= 200 && cycles % 300 < 230);
    end
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 100000) $fatal(1, "Packet watchdog");
        if (!rst_n) begin
            queued = 0;
            seen = 0;
            held = 0;
        end else begin
            if (held && (!m_valid || m_data !== held_data || m_bytes !== held_bytes ||
                         m_packet_last !== held_last))
                $fatal(1, "Packet stall");
            held = m_valid && !m_ready;
            held_data = m_data;
            held_bytes = m_bytes;
            held_last = m_packet_last;
            if (s_valid && s_ready) begin
                add(
                    32'h4d4a1000 | (s_channel << 8) | (s_first << 7) | (s_last << 6) |
                        ((s_bytes == 0) << 5) | s_bytes,
                    4, 0);
                add(s_frame_id, 4, s_bytes == 0);
                for (k = 0; k < (s_bytes + 3) / 4; k = k + 1) begin
                    remaining = s_bytes - k * 4;
                    add(s_data[k*32+:32], remaining >= 4 ? 4 : remaining,
                        k == (s_bytes + 3) / 4 - 1);
                end
                payloads = payloads + 1;
            end
            if (desc_valid && desc_ready) begin
                add(32'h4d4a1400 | (desc_channel << 8), 4, 0);
                add(desc_frame_id, 4, 0);
                add(desc_timestamp[31:0], 4, 0);
                add(desc_timestamp[63:32], 4, 0);
                add(desc_length, 4, 0);
                add({desc_height, desc_width}, 4, 0);
                add({23'd0, desc_gray, desc_status}, 4, 1);
                descriptors = descriptors + 1;
            end
            if (m_valid && m_ready) begin
                if (seen >= queued || m_data !== expected_data[seen] ||
                    m_bytes !== expected_bytes[seen] || m_packet_last !== expected_last[seen])
                    $fatal(1, "Packet word%0d mismatch", seen);
                seen = seen + 1;
            end
        end
    end
    task drive_payloads;
        integer i, b;
        begin
            for (i = 0; i < 1000; i = i + 1) begin
                @(negedge clk);
                s_valid = 1;
                s_channel = i % 4;
                s_frame_id = 32'h80000000 + i;
                s_bytes = i % 17;
                s_first = i % 2;
                s_last = s_bytes == 0 || i % 3 == 0;
                for (b = 0; b < 16; b = b + 1) s_data[b*8+:8] = i + b * 37;
                @(posedge clk);
                while (!s_ready) @(posedge clk);
            end
            @(negedge clk);
            s_valid = 0;
        end
    endtask
    task drive_descriptors;
        integer i;
        begin
            for (i = 0; i < 1000; i = i + 1) begin
                @(negedge clk);
                desc_valid = 1;
                desc_channel = (i + 1) % 4;
                desc_frame_id = 32'h70000000 + i;
                desc_timestamp = 64'h123456789a000000 + i;
                desc_width = 1920 - i;
                desc_height = 1080 + i;
                desc_length = 500000 + i;
                desc_gray = i % 2;
                desc_status = i;
                @(posedge clk);
                while (!desc_ready) @(posedge clk);
            end
            @(negedge clk);
            desc_valid = 0;
        end
    endtask
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        // Reset with an active partially accepted packet.
        @(negedge clk);
        s_valid = 1;
        s_bytes = 16;
        s_data = '1;
        @(posedge clk);
        while (!s_ready) @(posedge clk);
        @(negedge clk);
        s_valid = 0;
        repeat (2) @(negedge clk);
        rst_n = 0;
        repeat (3) @(negedge clk);
        payloads = 0;
        descriptors = 0;
        rst_n = 1;
        fork
            drive_payloads();
            drive_descriptors();
        join
        wait (seen == queued);
        @(negedge clk);
        if (m_valid || payloads != 1000 || descriptors != 1000) $fatal(1, "Packet accounting");
        file_handle = $fopen("SIM_PASS.txt", "w");
        $fwrite(
            file_handle,
            "1000 payload packets (0..16 bytes), 1000 descriptors, arbitration, stalls and reset passed.\n"
                );
        $fclose(file_handle);
        $display("MJPEG_PACKET_PASS words=%0d", seen);
        $finish;
    end
endmodule

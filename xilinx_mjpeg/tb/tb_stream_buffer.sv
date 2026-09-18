`timescale 1ns / 1ps
module tb_stream_buffer;
    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst_n = 0;
    reg [136:0] s_data = 0;
    reg s_valid = 0;
    wire s_ready;
    wire [136:0] m_data;
    wire m_valid;
    reg m_ready = 0;
    jpeg_stream_buffer #(.WIDTH(137)) dut (.*);
    reg [136:0] expected[0:5999];
    reg [136:0] held;
    reg was_stalled = 0, accepted = 0;
    integer sent = 0, received = 0, cycles = 0, epoch = 0, pass_file;
    reg [31:0] random_state = 32'h7bc28194;
    function [31:0] next_random(input [31:0] value);
        begin
            next_random = (value ^ (value << 13));
            next_random = next_random ^ (next_random >> 17);
            next_random = next_random ^ (next_random << 5);
        end
    endfunction
    always @(posedge clk)
        if (rst_n) begin
            cycles = cycles + 1;
            accepted = s_valid && s_ready;
            if (was_stalled && (!m_valid || m_data !== held)) $fatal(1, "Stalled payload changed");
            was_stalled = m_valid && !m_ready;
            if (was_stalled) held = m_data;
            if (s_valid && s_ready) begin
                expected[sent] = s_data;
                sent = sent + 1;
            end
            if (m_valid && m_ready) begin
                if (received >= sent || m_data !== expected[received])
                    $fatal(1, "Lost/reordered beat %0d", received);
                received = received + 1;
            end
            if (cycles > 60000) $fatal(1, "Buffer watchdog");
        end
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        // Random traffic, long pauses, simultaneous transfers and two full drains.
        for (epoch = 0; epoch < 2; epoch = epoch + 1) begin
            while (received < 5000) begin
                @(negedge clk);
                random_state = next_random(random_state);
                m_ready = cycles % 500 >= 100 && (random_state[3:0] != 0);
                if (!s_valid || accepted) begin
                    s_valid = sent < 5000 && random_state[6:4] != 0;
                    s_data = {9'h1ed, random_state, ~random_state, 32'(sent), 32'(epoch)};
                end
            end
            @(negedge clk);
            s_valid = 0;
            m_ready = 1;
            repeat (4) @(negedge clk);
            if (m_valid) $fatal(1, "Unexpected beat after drain");
            // Flush two pending beats with reset, then run a fresh scoreboard epoch.
            m_ready = 0;
            s_valid = 1;
            s_data = 137'h123;
            @(negedge clk);
            s_data = 137'h456;
            @(negedge clk);
            s_valid = 0;
            if (s_ready) $fatal(1, "Full buffer still ready");
            rst_n = 0;
            repeat (3) @(negedge clk);
            sent = 0;
            received = 0;
            cycles = 0;
            was_stalled = 0;
            accepted = 0;
            rst_n = 1;
        end
        pass_file = $fopen("SIM_PASS.txt", "w");
        $fwrite(pass_file,
                "10000 ordered beats; long stalls; full occupancy; reset flush passed.\n");
        $fclose(pass_file);
        $display("STREAM_BUFFER_PASS 10000 beats, long stalls and reset flush");
        $finish;
    end
endmodule
